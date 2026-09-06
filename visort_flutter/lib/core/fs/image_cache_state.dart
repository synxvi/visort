// 图片缓存三态探测（只读，miss 不发起解码）——gallery_file_widget 的
// Hero shuttle 图源选择用：complete=解码完成（shuttle 首帧同步显示）、
// pending=在途（等待期用网格档垫底）、miss=无条目。
// （2026-09 自 hero_flight_probe.dart 拆出并保留——同文件的飞行性能打点
// 属排查期临时，已随 probe.log 基建落地移除。）
import 'package:flutter/painting.dart';

/// 缩略图 provider 的缓存三态（只读探测）。
String imageCacheState(ImageProvider provider) {
  // containsKey 不查 liveImages（切后台 imageCache.clear() 后在屏图仍活
  // 但 containsKey=false → 假 miss，首开黑块根因）：statusForKey 含 live，
  // live 命中时 resolve 会在 putIfAbsent 内零解码复活 completer。
  final status = PaintingBinding.instance.imageCache.statusForKey(provider);
  if (!status.live && !status.keepAlive && !status.pending) {
    return 'miss';
  }
  final stream = provider.resolve(const ImageConfiguration());
  final completer = stream.completer;
  if (completer == null) return 'pending';
  var syncDone = false;
  late final ImageStreamListener probe;
  probe = ImageStreamListener(
    (_, synchronousCall) {
      if (synchronousCall) syncDone = true;
      completer.removeListener(probe);
    },
    onError: (_, _) => completer.removeListener(probe),
  );
  completer.addListener(probe);
  return syncDone ? 'complete' : 'pending';
}
