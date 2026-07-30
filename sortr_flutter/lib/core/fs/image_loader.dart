// 平台无关的图片加载辅助 —— 统一 Windows (Image.file) 与安卓 (MediaStore readBytes)
//
// Sort/Review 屏的图片显示统一走这里，避免在各处重复 Platform.isAndroid 判断。
//   - Windows: Image.file(File(join(root, relativePath)))
//   - 安卓 MediaStore: 经 FileSystemRepository.readBytes 读字节 + 下采样

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'android_mediastore_file_system.dart';
import 'file_system_repository.dart';
import 'image_ref.dart';
import 'mediastore_channel.dart';

/// 构建当前平台的 ImageProvider。
/// 安卓端 root=authority、relativePath=_ID；Windows 端 root=源目录、relativePath=相对路径。
ImageProvider buildImageProvider(ImageRef ref, {int? targetWidth}) {
  if (Platform.isAndroid) {
    return _AndroidBytesImageProvider(ref: ref, targetWidth: targetWidth);
  }
  return FileImage(File(p.join(ref.root, ref.relativePath)));
}

/// 预加载下一张图片到缓存（跨平台）。
Future<void> precacheNextImage(BuildContext context, ImageRef ref) {
  return precacheImage(buildImageProvider(ref), context);
}

/// 清理指定 MediaStore _ID 的所有图片缓存（缩略图 + 全图）。
///
/// 删除图片后调用，避免旧缩略图残留。在安卓端遍历常见缩略图 size +
/// 全图 provider 逐个 evict；Windows 端 FileImage 按 ref evict。
void evictImageCache(String mediaStoreId) {
  final cache = PaintingBinding.instance.imageCache;
  if (Platform.isAndroid) {
    // 缩略图：常见 size 逐个清理（_AndroidThumbnailProvider key = id+size）
    for (final size in const [200, 256, 300, 384]) {
      cache.evict(_AndroidThumbnailProvider(
          ref: imageRefFromMediaStoreId(mediaStoreId), size: size));
    }
    // 全图（_AndroidBytesImageProvider key = id+targetWidth，targetWidth=null）
    cache.evict(_AndroidBytesImageProvider(
        ref: imageRefFromMediaStoreId(mediaStoreId)));
  }
}

/// 安卓端从 MediaStore 读字节的 ImageProvider。
class _AndroidBytesImageProvider
    extends ImageProvider<_AndroidBytesImageProvider> {
  const _AndroidBytesImageProvider({required this.ref, this.targetWidth});

  final ImageRef ref;
  final int? targetWidth;

  @override
  Future<_AndroidBytesImageProvider> obtainKey(
      ImageConfiguration configuration) {
    return SynchronousFuture<_AndroidBytesImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _AndroidBytesImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield ErrorDescription('id: ${key.ref.relativePath}');
      },
    );
  }

  Future<ui.Codec> _loadAsync(
    _AndroidBytesImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await _fs.readBytes(key.ref);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    final tw = key.targetWidth;
    if (tw != null && tw > 0) {
      return decode(buffer,
          getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        return ui.TargetImageSize(width: tw);
      });
    }
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _AndroidBytesImageProvider &&
        other.ref.id == ref.id &&
        other.targetWidth == targetWidth;
  }

  @override
  int get hashCode => Object.hash(ref.id, targetWidth);
}

/// 全局 FS 实例（避免每个 ImageProvider 重复创建）
final FileSystemRepository _fs = AndroidMediaStoreFileSystem();

/// 全局 MediaStoreChannel 实例（缩略图用）
const MediaStoreChannel _msChannel = MediaStoreChannel();

// ───────────────────────── 缩略图 Provider（相册网格用） ─────────────────────────

/// 构建缩略图 ImageProvider（相册网格 cell 用）。
///
/// 安卓端优先走 MediaStore loadThumbnail（API 29+，系统级高效缩略图），
/// 低版本回退 readBytes 全图 + targetWidth 下采样。
/// Windows 端用 ResizeImage 包 FileImage 做下采样。
ImageProvider buildThumbnailProvider(ImageRef ref, {int size = 256}) {
  if (Platform.isAndroid) {
    return _AndroidThumbnailProvider(ref: ref, size: size);
  }
  return ResizeImage(FileImage(File(p.join(ref.root, ref.relativePath))),
      width: size);
}

/// 由 MediaStore _ID 直接构造 ImageRef（供相册网格临时包装用）。
///
/// 相册浏览持有的是 MsImageInfo，渲染缩略图时用它快速包成 ImageRef，
/// 无需经过 FileSystemRepository 扫描流程。
ImageRef imageRefFromMediaStoreId(String id, {String extension = '.jpg'}) {
  return ImageRef(
    root: kImagesAuthority,
    relativePath: id,
    extension: extension,
  );
}

/// 安卓缩略图 Provider：先试 loadThumbnail，空（API<29）回退 readBytes 下采样。
class _AndroidThumbnailProvider
    extends ImageProvider<_AndroidThumbnailProvider> {
  const _AndroidThumbnailProvider({required this.ref, required this.size});

  final ImageRef ref;
  final int size;

  @override
  Future<_AndroidThumbnailProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_AndroidThumbnailProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _AndroidThumbnailProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield ErrorDescription('thumbnail id: ${key.ref.relativePath}');
      },
    );
  }

  Future<ui.Codec> _loadAsync(
    _AndroidThumbnailProvider key,
    ImageDecoderCallback decode,
  ) async {
    // 先试系统缩略图（API 29+）。空数组 = 低版本不支持，回退全图。
    Uint8List bytes;
    try {
      bytes = await _msChannel.readThumbnail(key.ref.id,
          width: key.size, height: key.size);
    } catch (_) {
      bytes = Uint8List(0);
    }
    if (bytes.isEmpty) {
      // 回退：全图字节 + targetWidth 下采样
      final raw = await _fs.readBytes(key.ref);
      bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer,
        getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
      return ui.TargetImageSize(width: key.size);
    });
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _AndroidThumbnailProvider &&
        other.ref.id == ref.id &&
        other.size == size;
  }

  @override
  int get hashCode => Object.hash(ref.id, size);
}
