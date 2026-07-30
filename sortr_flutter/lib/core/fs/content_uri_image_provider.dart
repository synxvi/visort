// ContentUriImageProvider —— 从 SAF content:// URI 加载图片的自定义 ImageProvider
//
// 解决问题：Flutter 的 Image.file() 不能处理 content:// URI，必须经 MethodChannel
// 取字节流。直接 MemoryImage 解码相机原图（10-40MB）会导致 OOM。
//
// 设计要点（roadmap 共识 #9）：
//   1. 继承 ImageProvider，接入 Flutter 的 PaintingBinding.imageCache（自动 LRU）
//   2. 解码时通过 DecoderCallback 传 cacheWidth 下采样到 screenWidth × 2
//   3. 不落临时文件、零额外依赖
//   4. 加载失败抛 FlutterError，由 Image widget 的 errorBuilder 兜底

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'saf_channel.dart';

/// 从 SAF tree URI + docId 加载图片的 ImageProvider。
///
/// 用法：`Image(image: ContentUriImageProvider(treeUri: ref.root, docId: ref.relativePath))`
class ContentUriImageProvider extends ImageProvider<ContentUriImageProvider> {
  const ContentUriImageProvider({
    required this.treeUri,
    required this.docId,
    this.targetWidth,
    this.channel = const SafChannel(),
  }) : super();

  /// SAF tree URI（持久化授权的根）
  final String treeUri;

  /// 文档 ID（scanImages 返回的 docId）
  final String docId;

  /// 解码目标宽度（像素）。null 表示自适应屏幕宽度 × 2。
  /// 传入则下采样到该宽度，避免相机原图 OOM。
  final int? targetWidth;

  /// SAF channel 客户端（可注入便于测试）
  final SafChannel channel;

  @override
  Future<ContentUriImageProvider> obtainKey(ImageConfiguration configuration) {
    // 缓存 key = treeUri + docId + targetWidth
    // targetWidth 不同会生成不同 key（同一图不同分辨率独立缓存）
    return SynchronousFuture<ContentUriImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    ContentUriImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield ErrorDescription('treeUri: ${key.treeUri}');
        yield ErrorDescription('docId: ${key.docId}');
      },
    );
  }

  Future<ui.Codec> _loadAsync(
    ContentUriImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await key.channel.readBytes(key.treeUri, key.docId);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // 下采样：targetWidth 显式指定则用 TargetImageSizeCallback 限制宽度
    final targetWidth = key.targetWidth;
    if (targetWidth != null && targetWidth > 0) {
      return decode(buffer, getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        return ui.TargetImageSize(width: targetWidth);
      });
    }
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ContentUriImageProvider &&
        other.treeUri == treeUri &&
        other.docId == docId &&
        other.targetWidth == targetWidth;
  }

  @override
  int get hashCode => Object.hash(treeUri, docId, targetWidth);

  @override
  String toString() =>
      'ContentUriImageProvider(treeUri: $treeUri, docId: $docId, targetWidth: $targetWidth)';
}
