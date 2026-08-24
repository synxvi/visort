// 壁纸 MethodChannel 客户端 —— Dart 侧对 Kotlin WallpaperPlugin 的薄封装
//
// channel: visort/wallpaper
// 对接 Android WallpaperManager.setStream（对标 ColorOS 系统相册
// SetAsWallpaperActivity，考古见 WallpaperPlugin.kt 文件头）。
//
// 像素工作全在原生侧完成（BitmapRegionDecoder 裁剪解码 → CenterCrop 屏
// 尺寸 → JPEG → setStream），Dart 只传 MediaStore id + 目标。

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

  /// 主屏 + 锁屏（依次各设一次）。
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

/// 把 [id]（MediaStore _ID）的图片 CenterCrop 后设为 [target] 壁纸。
///
/// 抛 [WallpaperException]（解码失败 / setStream IOException 等）；
/// 调用方负责 toast 成败。
Future<void> setWallpaper(String id, WallpaperTarget target) async {
  try {
    await wallpaperMethodChannel.invokeMethod<void>('setWallpaper', {
      'id': id,
      'which': target.flag,
    });
  } on PlatformException catch (e) {
    throw WallpaperException(e.code, e.message ?? '');
  }
}
