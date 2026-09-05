// 分享 MethodChannel 客户端 —— Dart 侧对 Kotlin SharePlugin 的薄封装
//
// channel: visort/share
//
// 照抄 Aves（app_service.shareEntries / AppAdapterHandler.share）：Dart 侧
// 只负责 MIME 松弛（image/jpeg → image/*，让声明不全的接收方如 Google
// Lens 也能出现在 chooser），URI 由原生侧按 MediaStore _ID 构造
// （ContentUris.withAppendedId，content:// 本就可授权分享，无需拷贝）。

import 'package:flutter/services.dart';

import 'mediastore_channel.dart' show MsImageInfo;

const _kChannel = 'visort/share';

/// MethodChannel 单例（整个 app 共享一个 channel，底层无状态）。
final MethodChannel _channel = const MethodChannel(_kChannel);

/// 分享异常（message 透传原生侧错误描述）。
class ShareException implements Exception {
  const ShareException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'ShareException($code): $message';
}

/// 唤起系统分享面板分享 [images]。
///
/// 返回是否成功唤起（false = 无应用可接收，调用方 toast）。
/// 抛 [ShareException]（原生侧启动异常）。
Future<bool> shareImages(List<MsImageInfo> images) async {
  if (images.isEmpty) return false;
  try {
    final started = await _channel.invokeMethod<bool>('share', {
      'ids': images.map((e) => e.id).toList(),
      // MIME 松弛成大类型（Aves mimeTypeAnySubtype 同思路）：chooser 按
      // image/* 匹配，所有图片应用可见；精确 subtype 反而滤掉声明不全的。
      'mimes': images.map((e) => '${e.mime.split('/').first}/*').toList(),
    });
    return started ?? false;
  } on PlatformException catch (e) {
    throw ShareException(e.code, e.message ?? '');
  }
}
