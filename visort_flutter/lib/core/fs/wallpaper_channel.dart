// 壁纸 MethodChannel 客户端 —— Dart 侧对 Kotlin WallpaperPlugin 的薄封装
//
// channel: visort/wallpaper
//
// 照抄 Aves（WallpaperService / WallpaperHandler.kt）：像素工作全在 Dart
// 裁剪页完成（预览所见区域 → Canvas 渲染 → PNG bytes），原生只
// setStream(bytes, null, true, flags)——哑管道保证所见即所得。

import 'package:flutter/services.dart';

const _kChannel = 'visort/wallpaper';

/// MethodChannel 单例（整个 app 共享一个 channel，底层无状态）。
final MethodChannel wallpaperMethodChannel = const MethodChannel(_kChannel);

/// 壁纸目标（与 WallpaperManager flag 对齐）。
enum WallpaperTarget {
  /// 主屏（FLAG_SYSTEM）。
  system(1),

  /// 锁屏（FLAG_LOCK）。
  lock(2),

  /// 主屏 + 锁屏（flags 组合一次 setStream，Aves 同款）。
  both(3);

  const WallpaperTarget(this.flag);
  final int flag;
}

/// 壁纸设置异常（message 透传原生侧错误描述）。
class WallpaperException implements Exception {
  const WallpaperException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'WallpaperException($code): $message';
}

/// 把 [bytes]（裁剪页渲染好的 PNG）设为 [target] 壁纸。
///
/// 抛 [WallpaperException]；调用方负责 toast 成败。
Future<void> setWallpaper(Uint8List bytes, WallpaperTarget target) async {
  try {
    await wallpaperMethodChannel.invokeMethod<void>('setWallpaper', {
      'bytes': bytes,
      'which': target.flag,
    });
  } on PlatformException catch (e) {
    throw WallpaperException(e.code, e.message ?? '');
  }
}
