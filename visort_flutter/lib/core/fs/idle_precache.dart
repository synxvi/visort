// 空闲预缓存服务（全相册 screenNail 预生成，对标系统相册「全相册 MINI
// 预生成」思想 + visort full 档落盘管线）。
//
// 让路策略（2026-08-29 用户定调：常驻低频扫，不要求交互静默）：
//   - 扫描走 p300 最低优先级——用户解码（50/100/200）天然插队，滚动时
//     扫描自动排在队尾等待，不挡任何用户请求；
//   - 单张间隔 200ms + ServicePolicy 6 并发门内只占 1 槽：资源占用
//     ≈10% 单核，滚动期间 Kotlin ioExecutor 12 线程仍有 11 个余量；
//   - 仅在「管线空闲」时启动新会话（避免把扫描任务灌进正忙的队列积压），
//     会话中途不再因用户活动退出——让路完全交给优先级调度；
//   - 退后台/开关关闭 → 会话作废。
//
// 全库分页扫描（scanImages 空 bucketIds，DATE_ADDED 倒序：最新最可能
// 被看）；GIF 跳过（viewer 走 readBytes 多帧路径，不读 full 盘缓存）。
// 每 16 张自查配额（fullCacheBytes），写满即停本轮。

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/cache_perf.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/fs/service_policy.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';

/// 周期检查间隔（启动新会话用；会话中途不靠 tick 驱动）。
const Duration _kTick = Duration(seconds: 2);

/// 单张间隔（低频节流）。
const Duration _kPerImageGap = Duration(milliseconds: 200);

/// 已缓存跳过项（code=1）的间隔：仅 channel 节流，不付满额让路成本——
/// 重扫段的吞吐瓶颈在等待而非解码。
const Duration _kSkipGap = Duration(milliseconds: 20);

/// 配额满检测间隔（每 N 张查一次目录大小，walkTopDown 有成本）。
const int _kQuotaCheckEvery = 16;

class IdlePrecacheService with WidgetsBindingObserver {
  IdlePrecacheService._();

  static final IdlePrecacheService instance = IdlePrecacheService._();

  final MediaStoreChannel _channel = const MediaStoreChannel();

  /// 周期 tick 与扫描会话代际（配置/条件变化时作废旧会话）。
  Timer? _tickTimer;
  int _session = 0;
  bool _scanning = false;
  bool _attached = false;
  Ref? _ref;

  /// 绑定 provider（main 完成后调用一次激活；重复调用幂等）。
  /// 配置变化由 idlePrecacheProvider 的 ref.listen 转发到 onConfigChanged。
  void attach(Ref ref) {
    if (_attached) return;
    _attached = true;
    _ref = ref;
    WidgetsBinding.instance.addObserver(this);
    _tickTimer = Timer.periodic(_kTick, (_) => _tick());
    // 启动即把持久化配额推给 Kotlin（进程重启后 Kotlin 侧回到默认 128MB）。
    _pushQuota(ref.read(configProvider));
    // WorkManager 全库任务排队（KEEP 幂等；已排队/运行中不叠加）。
    _syncWorkSchedule(ref.read(configProvider));
  }

  /// 配置变化（idlePrecacheProvider 转发）：开关关 → 作废在跑扫描 +
  /// 取消 WorkManager 任务；配额变 → 推送 Kotlin（缩档立即 LRU 收紧）。
  void onConfigChanged(AppConfig config) {
    _pushQuota(config);
    _syncWorkSchedule(config);
    if (!config.precacheEnabled) {
      _session++; // 作废在跑扫描
    }
  }

  void _pushQuota(AppConfig config) {
    unawaited(_channel.setFullCacheQuota(config.precacheQuotaMb << 20));
  }

  /// WorkManager 全库任务与开关同步：开 → 排队（充电+存储不低约束，
  /// 插电即跑，不占交互用电）；关 → 取消（含运行中的，防边关边写）。
  void _syncWorkSchedule(AppConfig config) {
    if (config.precacheEnabled) {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      unawaited(_channel.schedulePrecacheWork(
        targetWidth: computeViewerTargetWidth(view.physicalSize.width),
      ));
    } else {
      unawaited(_channel.cancelPrecacheWork());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _session++; // 退后台/失焦：作废在跑扫描
    }
  }

  void _tick() {
    final ref = _ref;
    if (ref == null || _scanning) return;
    final config = ref.read(configProvider);
    if (!config.precacheEnabled) return;
    // 仅启动时看一眼管线空闲（防灌积压队列）；会话中途让路交给 p300
    // 优先级调度，不再因用户活动退出。
    if (!ServicePolicy.instance.idle) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _startScan();
  }

  Future<void> _startScan() async {
    _scanning = true;
    final session = ++_session;
    try {
      final ref = _ref!;
      // 全库分页扫描（scanImages 空 bucketIds = 全部非回收站图片，
      // DATE_ADDED 倒序 keyset 分页）——不依赖当前 UI 视图（首页相册
      // 列表态 photos 恒空，依赖它会永远不跑）。
      const pageSize = 200;
      String? cursor;
      var generated = 0;
      var skipped = 0;
      var quotaFull = false;
      // 当前屏宽算 targetWidth（与 viewer computeViewerTargetWidth 同源；
      // 旋转后 tw 变化走新目录，旧文件由 LRU 回收）。
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final tw = computeViewerTargetWidth(view.physicalSize.width);
      while (true) {
        // 会话作废（退后台/开关关）退出；用户活动不退出——p300 排队让路。
        if (session != _session) return;
        final page = await ServicePolicy.instance.run(
          RequestPriority.idlePrecache,
          () => _channel.scanImages(const [], afterCursor: cursor, limit: pageSize),
        );
        if (page.images.isEmpty) break;
        for (final info in page.images) {
          if (session != _session) return;
          // GIF 跳过：viewer GIF 走 readBytes 多帧，不读 full 盘缓存。
          if (info.mime == 'image/gif') continue;
          final code = await ServicePolicy.instance.run(
            RequestPriority.idlePrecache,
            () => _channel.precacheFullImage(
              info.id,
              targetWidth: tw,
              dateModifiedMs: info.dateModifiedMs,
            ),
            tag: 'precachefull:${info.id}',
          );
          if (code == 0) {
            generated++;
          } else if (code == 1) {
            skipped++;
          }
          // 每 16 张查配额：写满即停本轮（静默条件持续则等下轮 tick
          // 重扫，已缓存段秒级越过）。
          if ((generated + skipped) % _kQuotaCheckEvery == 0 &&
              generated > 0) {
            final bytes = await ServicePolicy.instance.run(
              RequestPriority.idlePrecache,
              () => _channel.imageCacheBytes(),
            );
            if (bytes.full >=
                (ref.read(configProvider).precacheQuotaMb << 20)) {
              quotaFull = true;
              break;
            }
          }
          // skip（已缓存）不睡满 200ms：会话重启重扫已缓存段（上千张 ×
          // 200ms = 数分钟纯等待）摸不到未缓存尾部——真机实证 8.5h 仅
          // 爬 63% 的主因之一。skip 只留 20ms channel 节流；生成保持
          // 200ms 让路节奏不变。
          await Future<void>.delayed(
            code == 1 ? _kSkipGap : _kPerImageGap,
          );
        }
        if (quotaFull) break;
        cursor = page.nextCursor;
        if (cursor == null) break; // 全库扫完
      }
      cachePerfEvent(
        'precacheSession gen=$generated skip=$skipped'
        '${quotaFull ? ' QUOTA_FULL' : ''}',
      );
    } catch (e) {
      debugPrint('[CACHE] precache 会话异常: $e');
    } finally {
      _scanning = false;
    }
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;
    _session++;
    _tickTimer?.cancel();
    _tickTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }
}

/// Provider 注册：app 启动后 read 一次激活；配置变化自动转发
/// （开关停扫 / 配额推送 Kotlin）。
final idlePrecacheProvider = Provider<IdlePrecacheService>((ref) {
  final svc = IdlePrecacheService.instance;
  svc.attach(ref);
  ref.listen<AppConfig>(configProvider, (_, next) {
    svc.onConfigChanged(next);
  });
  ref.onDispose(svc.dispose);
  return svc;
});
