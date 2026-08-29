// 图片缓存性能打点（排查期临时基建，与 ServicePolicy.kServicePolicyPerfLog
// 同款编译期开关模式；排查完置 false 全部 tree-shake）。
//
// 输出统一 [CACHE] 前缀，logcat grep 即得完整时间线：
//   [CACHE] decode L=full1152 id=xx 1152x2573 11.2MB via=raw | cur=87.3/96MB n=412/500
//     —— 一次真实解码（进 ImageCache 的唯一入口）。L=级别（full{tw}/
//     full{tw}FB(读字节兜底)/hd/thumb{size}s(方形)/thumb{size}c(等比)），
//     via=raw(readSampledImage ARGB)/bytes(readBytes)/thumb(readThumbnail)。
//     RE 标记 = 同级别同 id 历史已解过 = 被 LRU 逐出/其它路径清掉后的
//     【重解码】（回看慢的直接量化）。
//   [CACHE] hm(hit/total) grid398s:18/25 strip96s:5/25 | cur=..MB n=..
//     —— 探测命中/未命中聚合（每 25 次输出一批）。thumbnail_widget /
//     zoomable_image 的 containsKey 探测走这里。
//   [CACHE] evict R=viewerPop id=xx ok=2/2 | cur=..MB n=..
//     —— 主动逐出（R=viewerPop/trim/media）及真实命中率。
//   [CACHE] page idx=12 id=xx / open id=xx tw=1152 / pick id=xx L=full1152
//     —— 时间线锚点（翻页/开图/起始级别选择），把解码流和用户操作对上。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart' show PaintingBinding;

/// 排查开关（真机装机排查期 true；平时 false）。
const bool kCachePerfLog = true;

String _snap() {
  final c = PaintingBinding.instance.imageCache;
  final curMb = (c.currentSizeBytes / 1048576).toStringAsFixed(1);
  final maxMb = c.maximumSizeBytes >> 20;
  return 'cur=$curMb/${maxMb}MB n=${c.currentSize}/${c.maximumSize}';
}

/// 重解码检测表：level → 已解码过的 id 集。evict 主动清理时同步移除
/// （主动清后的重解是预期行为，不计 RE；只有 LRU 挤出的意外重解才标）。
final Map<String, Set<String>> _seenLevelIds = {};

/// 解码完成打点（[w]/[h] 已知时带尺寸与估算字节）。
void cachePerfDecode(
  String level,
  String id,
  int? w,
  int? h, {
  String via = 'raw',
}) {
  if (!kCachePerfLog) return;
  final re = !(_seenLevelIds[level] ??= {}).add(id);
  final dim = w != null && h != null
      ? ' ${w}x$h ${((w * h * 4) / 1048576).toStringAsFixed(1)}MB'
      : '';
  debugPrint(
    '[CACHE] decode L=$level id=$id$dim via=$via${re ? ' RE' : ''} | ${_snap()}',
  );
}

/// 解码完成但最终尺寸不可知（getTargetSize 闭包外拿不到 target）时的
/// 简化打点：intrinsic 尺寸 + 请求宽度。
void cachePerfDecodeIntrinsic(
  String level,
  String id,
  int intrinsicW,
  int intrinsicH, {
  String via = 'bytes',
}) {
  cachePerfDecode(level, id, intrinsicW, intrinsicH, via: via);
}

/// 主动逐出打点：[results] 为各 key 的 cache.evict 返回值（true=真有条目）。
/// 同步清重解码表（预期内重解不标 RE）。
void cachePerfEvict(String op, String id, List<bool> results) {
  if (!kCachePerfLog) return;
  final ok = results.where((b) => b).length;
  if (ok > 0) {
    for (final ids in _seenLevelIds.values) {
      ids.remove(id);
    }
  }
  debugPrint('[CACHE] evict R=$op id=$id ok=$ok/${results.length} | ${_snap()}');
}

class _HM {
  int hit = 0;
  int total = 0;
}

final Map<String, _HM> _probes = {};
int _probeAcc = 0;

/// 只读探测（containsKey）命中计数，每 25 次聚合输出一批。
void cachePerfProbe(String level, bool hit) {
  if (!kCachePerfLog) return;
  final c = _probes[level] ??= _HM();
  if (hit) c.hit++;
  c.total++;
  if (++_probeAcc < 25) return;
  _probeAcc = 0;
  final parts = _probes.entries
      .map((e) => '${e.key}:${e.value.hit}/${e.value.total}')
      .join(' ');
  for (final v in _probes.values) {
    v.hit = 0;
    v.total = 0;
  }
  debugPrint('[CACHE] hm(hit/total) $parts | ${_snap()}');
}

/// 时间线锚点 / 其它事件（翻页、开图、pick 结果、配置等）。
void cachePerfEvent(String msg) {
  if (!kCachePerfLog) return;
  debugPrint('[CACHE] $msg | ${_snap()}');
}

/// 供 image_loader 构造与 provider 一致的 level 名。
String cacheLevelFull(int targetWidth) => 'full$targetWidth';
String cacheLevelThumb(int size, bool squareCrop) =>
    'thumb$size${squareCrop ? 's' : 'c'}';
