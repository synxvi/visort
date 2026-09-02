// 智能识别索引服务 —— 搜索页多维度分类的数据源与进度载体
//
// [aves 对齐] Aves 的 CollectionFilter 体系按日期/地点/相册/格式过滤,
// 其数据底座是全量条目 EXIF 元数据缓存;visort 的照片数据源是
// MediaStore(无 DATE_TAKEN/GPS 列),本服务补齐该底座:
//   - 开启「智能识别索引」后后台分批扫描全部照片,每批一次 EXIF pass
//     经 Kotlin `indexSearchMeta` 同时提取拍摄时间/GPS/相机
//     (读文件头,单张几 ms,不卡主线程);
//   - 地名解析随索引恒开(2026-09 地点识别分开关并入总开关):批次内
//     新坐标(0.02° 网格去重,Kotlin 侧仅缓存成功结果)经 `geocodePlaces`
//     反地理编码为国家/省/市地名([aves 对齐] Aves GeocodingHandler 的
//     系统 Geocoder 方案);Geocoder 暂时不可用(无网/服务未就绪)时字段
//     为 null 且不落缓存,搜索页数据就绪后经 [resolvePendingPlaces]
//     惰性补解析,无地名时降级坐标分组;
//   - 产物写 SQLite `search_index` 表(SearchIndexStore),冷启动恢复;
//     进度(done/total)持久化 SharedPreferences,设置页轮询展示;
//   - 关闭总开关清空表([ente 对齐] ENTE 关 ML 清库语义)。
// 索引表只是 id → EXIF 富化缓存:照片本体增删以 MediaStore 为准,
// 残留行按 id 查不到自然失效;新增照片由 [syncNewPhotos] 前台增量
// 对账补录([precache 对齐] 缩略图缓存「前台增量」模式,2026-09)。
//
// 历史:v1(已移除)只索引 GPS 存 SharedPreferences('ml_locations'),
// 搜索页位置分类只能按坐标网格分组;v2 扩展为多维度并迁 SQLite,
// 旧 SP 键在 [load] 时清理。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async' show unawaited;

import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/search_index_store.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart' show configProvider;

/// 全量照片分页拉取（空 bucketIds = 全部相册；Kotlin 侧查询已显式排除
/// 回收站项）。搜索页与索引服务共用——全库扫描只做一次。
Future<List<MsImageInfo>> scanAllImages(MediaStoreChannel channel) async {
  final out = <MsImageInfo>[];
  var cursor = '';
  while (true) {
    final page = await channel.scanImages(
      const [],
      afterCursor: cursor.isEmpty ? null : cursor,
      limit: 500,
    );
    out.addAll(page.images);
    if (page.nextCursor == null || page.nextCursor!.isEmpty) break;
    cursor = page.nextCursor!;
  }
  return out;
}

/// 索引运行态（设置页「索引」区与搜索页 banner 共用）。
class SearchIndexState {
  const SearchIndexState({
    this.running = false,
    this.processed = 0,
    this.total = 0,
    this.metaCount = 0,
    this.ranOnce = false,
  });

  final bool running;

  /// EXIF pass 进度分子（已处理照片数）。
  final int processed;
  final int total;

  /// 当前索引条目数（= `_metas.length`）。与 processed/total 分开：
  /// 增量对账（syncNewPhotos）不动首轮进度，但张数要跟着涨——设置页
  /// 进度行靠它观察增量变化。
  final int metaCount;

  /// 本轮安装生命周期内已完整跑过一轮（start 正常结束，或 SP 进度
  /// 恢复出 "done/total"）。空库（total=0）跑完也算——否则 done 恒
  /// false、设置页进度永远「…」（审查 P2）。
  final bool ranOnce;

  /// 是否已完整跑过一轮。
  bool get done => ranOnce && processed >= total;
}

/// 搜索索引 store(单例,服务与测试共用)。
final searchIndexStoreProvider = Provider<SearchIndexStore>(
  (ref) => SearchIndexStore(ref.watch(databaseServiceProvider).database),
);

/// 智能识别索引服务：全库扫描 + EXIF 提取 + 地名解析 + SQLite 落盘。
final searchIndexServiceProvider =
    NotifierProvider<SearchIndexService, SearchIndexState>(
        SearchIndexService.new);

class SearchIndexService extends Notifier<SearchIndexState> {
  static const _kProgressKey = 'search_index_progress';
  // v1 遗留键(纯 GPS 时代),load 时清理。
  static const _kLegacyKeys = ['ml_locations', 'ml_index_progress'];
  static const _kBatchSize = 300;

  /// 地名坐标去重网格(度),与 Kotlin geocodePlaces 一致。
  static const _kGeocodeGrid = 0.02;

  final MediaStoreChannel _channel = const MediaStoreChannel();
  Map<String, MsSearchMeta> _metas = const {};

  /// 提取时各图 DATE_MODIFIED(id → ms)。增量对账第二判据：id 已知但
  /// mtime 变 → 照片被外部编辑（EXIF 可能已变）→ 重提取（审查 P1-3）。
  /// 与 `_metas` 分开存——meta 行可能是「无 EXIF 空行」（tombstone，
  /// P1-4），mtime 对空行同样有效。
  Map<String, int> _mtimes = {};
  bool _cancel = false;

  /// run 世代：每次新跑批（start/syncNewPhotos/resolvePendingPlaces）
  /// 自增并在循环开始时快照，检查点同时校验 `_cancel` 与世代——快速
  /// 「关→开」时新 run 复位 `_cancel` 也不会让旧循环复活（旧世代 ≠
  /// 当前世代即退出，审查 P1-2 双循环并发）。
  int _runSeq = 0;

  /// 本进程已完成一次 DB 恢复。此后 `_metas` 是唯一写方（service 自身）
  /// 的内存权威副本，load() 秒回——进搜索页/设置页不再每次全表重读
  /// （审查 H2：对账路径叠加路由转场的隐性成本）。
  bool _restored = false;

  /// 数据变化回调（searchData store 注册）：首轮完成/增量落地/补地名/
  /// 清库四条路径统一通知，store 据此 rebuildFilters（用户停在搜索页时
  /// 索引完成地点/相机 chips 即时出现，审查 P2「索引完成无通知」）。
  /// 同层方法注入，避免 service ↔ dataStore 循环 import。
  void Function()? onDataChanged;

  /// 补地名轮冷却：Geocoder 持续离线的设备每次进页对全部 pending 串行
  /// 重试网络调用——5 分钟冷却 + 每轮限量 100 张渐进收敛（审查 P2）。
  DateTime? _pendingLastAt;
  static const _kPendingPerRound = 100;
  static const _kPendingCooldown = Duration(minutes: 5);

  /// id → 索引元数据（启动时 [load] 恢复；索引完成后更新）。
  Map<String, MsSearchMeta> get metas => _metas;

  @override
  SearchIndexState build() => const SearchIndexState();

  SearchIndexStore get _store => ref.read(searchIndexStoreProvider);

  /// 启动/切页时从 SQLite 恢复索引与进度（设置页、搜索页 initState 调）。
  /// 保留 running 态：索引循环跑批中进搜索页会触发 load，若把 running
  /// 覆写为 false，搜索页自愈逻辑会并发拉起第二个 start()（双循环并发，
  /// 子代理审查 P1）。
  ///
  /// 全进程只真正执行一次（`_restored` 门禁）：此后 `_metas` 即权威副本，
  /// 重读整表是纯浪费；SP 遗留键清理同样只跑一次。
  ///
  /// 恢复完成必须触发 [onDataChanged]：warmUp 首载的 rebuildFilters 先于
  /// 本 load 执行（此刻 _metas 还是空——地点/相机/元数据维度缺席），恢复
  /// 后靠本通知补一次重建；增量对账空差集不触发，所以这是冷启动/直接
  /// 进搜索页唯一让索引维度 chips 出现的路径（2026-09 回归修复：删
  /// _syncIndex 末尾 rebuildFilters 改 onDataChanged 时漏了「纯恢复」
  /// 这条路径，导致必须重索引一遍才出现）。
  Future<void> load() async {
    if (_restored) return;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    // v1 SP 数据迁移清理:数据不可比(EXIF pass 会产出更全字段),直接弃。
    for (final k in _kLegacyKeys) {
      await prefs.remove(k);
    }
    _metas = await _store.loadAll();
    _mtimes = await _store.loadMtimes();
    debugPrint('[SIDX] load: metas=${_metas.length} mtimes=${_mtimes.length}');
    final prog = prefs.getString(_kProgressKey);
    if (prog != null) {
      final parts = prog.split('/');
      if (parts.length == 2) {
        state = SearchIndexState(
          running: state.running,
          processed: int.tryParse(parts[0]) ?? 0,
          total: int.tryParse(parts[1]) ?? 0,
          metaCount: _metas.length,
          // SP 有进度 = 跑过一轮（含 "0/0" 空库跑完）。
          ranOnce: true,
        );
      }
    } else if (_metas.isNotEmpty) {
      // 无进度但表有数据(异常中断/清进度):按行数近似恢复,允许复用。
      state = SearchIndexState(
        running: state.running,
        processed: _metas.length,
        total: _metas.length,
        metaCount: _metas.length,
        ranOnce: true,
      );
    }
    onDataChanged?.call();
    // 断点续跑：跑批中杀进程→重开，SP 进度恢复了一半但无人再触发
    // start()（原来只有设置页手动开开关才启动）——进度卡死，必须手动
    // 关-开一次才恢复（2026-09 用户实证）。开关开着且首轮未完成时自动
    // 拉起 start()（差集续跑：跳过已索引 id，进度从断点继续）。running
    // 时跳过（load 保留 running 态防双循环）。
    if (ref.read(configProvider).mlIndexEnabled &&
        !state.running &&
        !state.done) {
      debugPrint('[SIDX] resume after restore: '
          'processed=${state.processed}/${state.total}');
      unawaited(start());
    }
  }

  /// 开启索引：全量扫描提取 EXIF + 地名解析（随总开关恒开）。
  /// 已完整跑过一轮且表非空时直接复用（增量重建留待后续版本）。
  /// 断点续跑（2026-09）：load 恢复的 [_metas] 是权威副本——已索引 id
  /// 直接跳过，进度从断点继续而非重头（跑批中杀进程→重开的场景，
  /// 用户实证期望续跑而非全量重跑）。mtime 变化的重提取不在此处理
  /// （属 [syncNewPhotos] 对账职责），已删残留 id 同样由对账反向收敛。
  Future<void> start() async {
    debugPrint('[SIDX] start enter: running=${state.running} '
        'done=${state.done} metas=${_metas.length} cancel=$_cancel');
    if (state.running) return;
    if (state.done && _metas.isNotEmpty) return;
    // 保留断点进度显示（扫描期间不闪回 0），扫描完成后按交集校正。
    state = SearchIndexState(
      running: true,
      processed: state.processed,
      total: state.total,
      metaCount: _metas.length,
      ranOnce: state.ranOnce,
    );
    _runSeq++;
    final mySeq = _runSeq;
    _cancel = false;
    try {
      // ACCESS_MEDIA_LOCATION（Android 10+ 未授权时系统剥离 MediaStore
      // 流的 EXIF GPS——真机实证：pm clear 撤销后索引 0 坐标）。跟随
      // 「智能识图索引」总开关在开跑前申请一次（用户定稿：地点识别子
      // 开关不单独触发权限弹窗）；拒绝则照常索引（地点维度无数据，
      // 不阻塞其余维度）。
      try {
        await _channel.requestAccessMediaLocation();
      } catch (_) {
        // 无 Activity/失败不阻塞索引
      }
      final photos = await scanAllImages(_channel);
      debugPrint('[SIDX] scanned ${photos.length} photos');
      final total = photos.length;
      final mtimeById = {
        for (final p in photos) p.id: p.dateModifiedMs,
      };
      // 差集 = 未索引的照片；已索引数即进度起点。
      final known = _metas.keys.toSet();
      final pending =
          photos.where((p) => !known.contains(p.id)).map((p) => p.id).toList();
      var done = total - pending.length;
      debugPrint('[SIDX] resume: skip=$done pending=${pending.length}');
      final metas = <String, MsSearchMeta>{};
      for (var i = 0; i < pending.length; i += _kBatchSize) {
        if (_isStale(mySeq)) return;
        final batch = pending.skip(i).take(_kBatchSize).toList();
        final r = await _channel.indexSearchMeta(batch);
        debugPrint('[SIDX] batch $i/${pending.length}: meta=${r.length}');
        if (_isStale(mySeq)) return; // 清库竞态：关开关后不再写
        var batchOut = r.values.toList();
        // 地名解析随索引恒开（用户定稿：地点识别开关已并入总开关）。
        batchOut = await _resolvePlaces(batchOut);
        // _resolvePlaces 是长 await（Kotlin 串行 geocode，首批可达数十秒），
        // 其后必须复查：关开关已 clear() 时继续执行会把该批写回已清空的
        // 表并覆写 state/进度 SP（清库复活，子代理审查 P1）。
        if (_isStale(mySeq)) return;
        for (final m in batchOut) {
          metas[m.id] = m;
        }
        await _store.putAll(batchOut, mtimes: mtimeById);
        if (_isStale(mySeq)) {
          // 落地后复查的完全体：本批可能在清库（clear）之后才写入——
          // 补偿删除，堵住「落地后复查只防后续批不防本批」的残留窗
          //（审查 P2 clear 竞态）。
          await _store
              .deleteByIds({for (final m in batchOut) m.id});
          return;
        }
        done += batch.length;
        state = SearchIndexState(
          running: true,
          processed: done,
          total: total,
          metaCount: state.metaCount,
          ranOnce: state.ranOnce,
        );
        await _saveProgress(done, total);
      }
      // 合并非覆盖：差集模式下 metas 只含本轮新增，存量来自 _metas。
      // 全量首轮时 _metas 为空，合并结果与原覆盖语义一致。
      _metas = {..._metas, ...metas};
      _mtimes = mtimeById;
      // 收敛 SP（pending 为空时循环零次，此处是唯一收敛点——否则每次
      // 冷启都会因 SP 进度未满而空转一轮全量扫描）。
      await _saveProgress(done, total);
      debugPrint('[SIDX] finished: rows=${_metas.length} (+${metas.length})');
    } catch (e, s) {
      // 不 rethrow：调用方（设置页 unawaited / 搜索页 .then）均无 catch，
      // rethrow 会成 unhandled async exception（子代理审查 P3）。
      debugPrint('[SIDX] FAILED: $e\n$s');
    } finally {
      // 世代校验后才能复位 state：跑批中「关→开」时，旧循环的 finally
      // 会晚于新 start() 执行（新 start 已 ++_runSeq 并置 running:true），
      // 无条件复位会把新 run 覆写成 running:false + ranOnce:true——设置页
      // 假「已完成」，running 闸门失效可再拉起并发循环（审查 P1）。
      // cancel()/clear() 不推进 _runSeq，纯取消场景仍走下方复位（保留
      // 「cancel 不再把 running 卡 true」的原修复语义）。
      if (mySeq == _runSeq) {
        final finished = !_cancel;
        state = SearchIndexState(
          running: false,
          processed: _cancel ? 0 : state.processed,
          total: _cancel ? 0 : state.total,
          metaCount: _metas.length,
          ranOnce: finished || state.ranOnce,
        );
        if (finished) onDataChanged?.call();
      }
      debugPrint('[SIDX] finally: seq=$mySeq/$_runSeq cancel=$_cancel '
          'state=${state.processed}/${state.total}');
    }
  }

  /// 检查点：被取消，或已被更新世代取代（新 run 已起，本循环必须退出）。
  bool _isStale(int mySeq) => _cancel || mySeq != _runSeq;

  /// 前台增量对账（[precache 对齐] 缩略图缓存「前台增量」同款模式）：
  /// MediaStore 实时列表与索引表比对 → 新照片 / mtime 变化的照片补一轮
  /// EXIF+地名解析 → 落库合并。搜索页每次数据就绪后调用（开关开启时）；
  /// 空差集一趟 Set 扫描零成本。
  ///
  /// 对账三判据（2026-09 审查 P1-3/P1-4）：
  ///   - id 未知 → 新照片，提取（含「无 EXIF 空行」tombstone——Kotlin
  ///     返回全部请求项，空数据也落行，差集从此可收敛，截图不再每进页
  ///     重扫）；
  ///   - id 已知但 mtime 变 → 照片被外部编辑（EXIF 可能已变）→ 重提取
  ///     （replace 覆盖；编辑后 EXIF 变空则行被洗成空行，正确）；
  ///   - id 已知但 mtime 列为 null（schema v3 升级前的存量行）→ 回填
  ///     当前 mtime 不重扫——接受升级前历史现状，避免一次性全库重提取。
  ///
  /// 设计边界：首轮全量仍由开关驱动（done/SP 进度语义不动）；首轮跑批
  /// 中跳过（循环自身覆盖全库）；应用内删除由 forgetIds 级联清理；
  /// 应用外删除（系统相册/文件管理器等）由本对账的反向收敛兜底——
  /// photos 是全量扫描（scanAllImages），差集即已删照片的残留行。
  Future<void> syncNewPhotos(List<MsImageInfo> photos) async {
    if (state.running) return;
    final known = _metas.keys.toSet();
    final fresh = <String>[];
    final backfill = <String, int>{};
    final mtimeById = <String, int>{};
    for (final p in photos) {
      mtimeById[p.id] = p.dateModifiedMs;
      if (!known.contains(p.id)) {
        fresh.add(p.id);
      } else {
        final m = _mtimes[p.id];
        if (m == null) {
          backfill[p.id] = p.dateModifiedMs;
        } else if (m != p.dateModifiedMs) {
          fresh.add(p.id);
        }
      }
    }
    if (backfill.isNotEmpty) {
      await _store.updateMtimes(backfill);
      _mtimes.addAll(backfill);
      debugPrint('[SIDX] syncNewPhotos: backfill mtimes +${backfill.length}');
    }
    // 反向收敛：索引有、照片库无 → 外部删除的残留行，级联清理
    // （内存 + DB + 张数 state；复用 forgetIds 的安全语义）。放在
    // fresh 提前返回之前——只删行不补录的轮次也要收敛。
    final gone = known.difference(mtimeById.keys.toSet());
    if (gone.isNotEmpty) {
      await forgetIds(gone);
      debugPrint('[SIDX] syncNewPhotos: gc ${gone.length} stale rows');
    }
    if (fresh.isEmpty) return;
    debugPrint('[SIDX] syncNewPhotos: ${fresh.length} new/changed');
    _runSeq++;
    final mySeq = _runSeq;
    _cancel = false;
    final out = <MsSearchMeta>[];
    for (var i = 0; i < fresh.length; i += _kBatchSize) {
      if (_isStale(mySeq)) return;
      final batch = fresh.skip(i).take(_kBatchSize).toList();
      final r = await _channel.indexSearchMeta(batch);
      if (_isStale(mySeq)) return;
      var batchOut = r.values.toList();
      batchOut = await _resolvePlaces(batchOut);
      if (_isStale(mySeq)) return;
      await _store.putAll(batchOut, mtimes: mtimeById);
      if (_isStale(mySeq)) {
        await _store
            .deleteByIds({for (final m in batchOut) m.id}); // 清库补偿删除
        return;
      }
      out.addAll(batchOut);
    }
    for (final m in out) {
      _metas[m.id] = m;
      final mt = mtimeById[m.id];
      if (mt != null) _mtimes[m.id] = mt;
    }
    // 张数进 state：增量落地后设置页进度行立即反映（processed/total 是
    // 首轮进度语义，不动）。
    state = SearchIndexState(
      running: state.running,
      processed: state.processed,
      total: state.total,
      metaCount: _metas.length,
      ranOnce: state.ranOnce,
    );
    onDataChanged?.call();
    debugPrint('[SIDX] syncNewPhotos done: +${out.length}');
  }

  /// 惰性补解析：首索引时无网/Geocoder 异常的行（有坐标但地名三元组
  /// 空）原本无恢复路径（补轮已随地点识别开关移除；Kotlin 侧失败已不
  /// 落缓存）。搜索页数据就绪后调用：pending 为空时 no-op（一趟 where
  /// 扫描），有则分批补 geocode 落库，通知方刷新分组。
  Future<void> resolvePendingPlaces() async {
    if (state.running) return;
    // 冷却：Geocoder 持续离线时每轮重试全部 pending 是白付网络调用，
    // 5 分钟一轮 + 每轮限量 [_kPendingPerRound] 渐进收敛（审查 P2）。
    final now = DateTime.now();
    if (_pendingLastAt != null &&
        now.difference(_pendingLastAt!) < _kPendingCooldown) {
      return;
    }
    final pending = _metas.values
        .where((m) => m.lat != null && m.lng != null && m.placeLabel.isEmpty)
        .take(_kPendingPerRound)
        .toList();
    if (pending.isEmpty) return;
    debugPrint('[SIDX] resolvePendingPlaces: ${pending.length}');
    _runSeq++;
    final mySeq = _runSeq;
    _cancel = false;
    var wrote = false;
    for (var i = 0; i < pending.length; i += _kBatchSize) {
      if (_isStale(mySeq)) return;
      final chunk = pending.skip(i).take(_kBatchSize).toList();
      final resolved = await _resolvePlaces(chunk);
      if (_isStale(mySeq)) return;
      // 带 _mtimes：REPLACE 会整行覆盖，不带会把已记录的提取时间戳
      // 洗成 null（下次对账误判为待回填）。
      await _store.putAll(resolved, mtimes: _mtimes);
      if (_isStale(mySeq)) {
        await _store
            .deleteByIds({for (final m in resolved) m.id}); // 清库补偿删除
        return;
      }
      for (final m in resolved) {
        _metas[m.id] = m;
      }
      wrote = wrote || resolved.isNotEmpty;
    }
    _pendingLastAt = DateTime.now();
    if (wrote) onDataChanged?.call();
    debugPrint('[SIDX] resolvePendingPlaces done');
  }

  /// 批内地名解析:收集批内新坐标(0.02° 网格键去重)→ geocodePlaces →
  /// 填回各条目。同网格多张照片共享一次 Geocoder 调用(Kotlin 侧还有
  /// 跨批缓存,这里去重只为省通道数据量)。
  Future<List<MsSearchMeta>> _resolvePlaces(List<MsSearchMeta> batch) async {
    final needs = <String, (double, double)>{};
    for (final m in batch) {
      final lat = m.lat, lng = m.lng;
      if (lat == null || lng == null || m.placeLabel.isNotEmpty) continue;
      final key = '${(lat / _kGeocodeGrid).round()}:${(lng / _kGeocodeGrid).round()}';
      needs.putIfAbsent(key, () => (lat, lng));
    }
    if (needs.isEmpty) return batch;
    try {
      final places = await _channel
          .geocodePlaces(needs.values.map((e) => [e.$1, e.$2]).toList());
      final byKey = <String, MsSearchMeta>{};
      var j = 0;
      for (final key in needs.keys) {
        byKey[key] = j < places.length
            ? MsSearchMeta(
                id: key,
                country: places[j].country,
                adminArea: places[j].adminArea,
                locality: places[j].locality,
              )
            : const MsSearchMeta(id: '');
        j++;
      }
      return batch.map((m) {
        final lat = m.lat, lng = m.lng;
        if (lat == null || lng == null || m.placeLabel.isNotEmpty) return m;
        final key =
            '${(lat / _kGeocodeGrid).round()}:${(lng / _kGeocodeGrid).round()}';
        final place = byKey[key];
        if (place == null ||
            (place.country == null &&
                place.adminArea == null &&
                place.locality == null)) {
          return m; // Geocoder 无结果:保留坐标,搜索页降级坐标分组
        }
        return MsSearchMeta(
          id: m.id,
          dateTakenMs: m.dateTakenMs,
          lat: lat,
          lng: lng,
          camera: m.camera,
          country: place.country,
          adminArea: place.adminArea,
          locality: place.locality,
        );
      }).toList();
    } catch (_) {
      return batch; // geocode 整批失败:坐标照存,地名后续可补
    }
  }

  /// 取消当前索引（开关关闭时先 cancel 再 clear，避免清完又被写回）。
  void cancel() => _cancel = true;

  /// 照片被删除后的索引级联清理（内存 `_metas` + DB 行 + 张数 state）。
  /// 坐标/地名属位置数据，照片删除后不应留库（安全审查：此前唯一清除
  /// 路径是关开关）。跑批中调用也安全：正在写的批只含当时仍存在的 id，
  /// 且各循环检查点会在下一 async gap 退出。
  Future<void> forgetIds(Set<String> ids) async {
    if (ids.isEmpty || _metas.isEmpty) return;
    final hit = _metas.keys.where(ids.contains).toSet();
    if (hit.isEmpty) return;
    for (final id in hit) {
      _metas.remove(id);
      _mtimes.remove(id);
    }
    await _store.deleteByIds(hit);
    state = SearchIndexState(
      running: state.running,
      processed: state.processed,
      total: state.total,
      metaCount: _metas.length,
      ranOnce: state.ranOnce,
    );
    onDataChanged?.call();
    debugPrint('[SIDX] forgetIds: -${hit.length}');
  }

  /// 关闭索引：清空索引表与进度（[ente 对齐] 关 ML 清库语义）。
  Future<void> clear() async {
    _cancel = true;
    _metas = const {};
    _mtimes = {};
    await _store.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kProgressKey);
    state = const SearchIndexState();
    onDataChanged?.call();
  }

  Future<void> _saveProgress(int done, int total) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProgressKey, '$done/$total');
  }
}
