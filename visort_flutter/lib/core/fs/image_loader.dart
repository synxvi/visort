// 平台无关的图片加载辅助 —— 统一 Windows (Image.file) 与安卓 (MediaStore readBytes)
//
// Sort/Review 屏的图片显示统一走这里，避免在各处重复 Platform.isAndroid 判断。
//   - Windows: Image.file(File(join(root, relativePath)))
//   - 安卓 MediaStore: 经 FileSystemRepository.readBytes 读字节 + 下采样

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'android_mediastore_file_system.dart';
import 'file_system_repository.dart';
import 'image_ref.dart';
import 'mediastore_channel.dart';
import 'service_policy.dart';

/// 构建当前平台的 ImageProvider。
/// 安卓端 root=authority、relativePath=_ID；Windows 端 root=源目录、relativePath=相对路径。
/// [targetWidth]（物理像素）：预览类场景（Sort 屏）应传入——全分辨率解码
/// （12MP ≈ 48MB ARGB）在键盘连按时每键双份解码会瞬间塞满 ImageCache；
/// 下采样后 ~7MB/张。GIF 跳过缩放（ResizeImage 对多帧动图不可靠，
/// 安卓侧 _AndroidBytesImageProvider 同样对 GIF 走全量保多帧）。
ImageProvider buildImageProvider(ImageRef ref, {int? targetWidth}) {
  if (Platform.isAndroid) {
    return _AndroidBytesImageProvider(ref: ref, targetWidth: targetWidth);
  }
  final file = FileImage(File(p.join(ref.root, ref.relativePath)));
  if (targetWidth != null &&
      targetWidth > 0 &&
      ref.extension.toLowerCase() != '.gif') {
    return ResizeImage(file, width: targetWidth, policy: ResizeImagePolicy.fit);
  }
  return file;
}

/// 预加载下一张图片到缓存（跨平台）。Sort 屏调用时传 [targetWidth]，
/// 与显示用 provider 的 key 一致才能命中缓存。
Future<void> precacheNextImage(
  BuildContext context,
  ImageRef ref, {
  int? targetWidth,
}) {
  return precacheImage(
    buildImageProvider(ref, targetWidth: targetWidth),
    context,
  );
}

/// 清理指定 MediaStore _ID 的所有图片缓存（缩略图 + 全图）。
///
/// 删除/移动/恢复图片后调用，避免旧缩略图残留。ImageCache 无公开 key
/// 遍历 API（cache.keys 不存在），只能按 key 构造逐个 evict——而 key 是
/// (id, size, dateModifiedMs, squareCrop) 四元组：真实条目遍布
/// 96(filmstrip)/256/512(网格)/300(封面)/动态 cell size × 两种 squareCrop
///（旧固定表 [200,256,300,384]+squareCrop:false 与真实 key 0% 命中，
/// 删除后旧缩略图永不清理）。改用注册表：buildThumbnailProvider 把
/// (size, squareCrop) 变体记入 _usedThumbVariants，evict 全量重放。
/// dateModifiedMs 当前无调用者传值（恒 null），不参与变体注册。
final Set<(int, bool)> _usedThumbVariants = {};

void evictImageCache(String mediaStoreId) {
  if (!Platform.isAndroid) return;
  final cache = PaintingBinding.instance.imageCache;
  final ref = imageRefFromMediaStoreId(mediaStoreId);
  for (final (size, crop) in _usedThumbVariants) {
    cache.evict(_AndroidThumbnailProvider(
      ref: ref,
      size: size,
      squareCrop: crop,
    ));
  }
  // 全图：无 targetWidth 条目（带 targetWidth 的 viewer 变体由
  // evictViewerImageCache 在关闭时按具体宽度清理）。
  cache.evict(_AndroidBytesImageProvider(ref: ref));
}

/// 清理 viewer 浏览用的图片缓存（1024 垫底缩略图 + 全图），**不动网格 300
/// 缩略图**。PhotoViewer 关闭时对本次浏览过的照片逐个调用：原图/1024 缩略图
/// 体积大（12MP ≈ 48MB/张），若留在全局 ImageCache 会把缓存占满、迫使网格
/// 缩略图反复 evict + GC —— 表现为“打开关闭几次后滚动变卡”。
void evictViewerImageCache(String mediaStoreId, int targetWidth) {
  if (!Platform.isAndroid) return;
  final cache = PaintingBinding.instance.imageCache;
  final ref = imageRefFromMediaStoreId(mediaStoreId);
  // viewer 只按 computeViewerTargetWidth（960/动态）解码，从不直接建
  // 768/1024 条目——旧固定 evict 是空转（Cache.evict 对不存在 key 返回
  // false，白付 2 次对象构造 + key 哈希）。改只清真实键：无 targetWidth
  //（旧条目）与带 targetWidth（下采样）都清。
  cache.evict(_AndroidBytesImageProvider(ref: ref));
  cache.evict(_AndroidBytesImageProvider(ref: ref, targetWidth: targetWidth));
}

/// viewer 原图下采样目标宽度（物理像素）：对齐系统相册 by70.c() = max(960, 屏宽×0.8)。
/// 屏宽物理 = 逻辑宽 × devicePixelRatio。打开瞬间解码到此宽度：对 12MP 图约 ~1MP，
/// 解码快、能压进 250ms 飞行动画窗；全屏 contain（屏宽 ≤1440）0.8× 略欠采样但视觉
/// 可接受（系统相册同策略）；放大 scale>1.3 由 _hdTriggered 加载原片全像素覆盖。
/// precache/_BigImage/evict 三处都用本函数算同一值，否则 ImageCache key 不匹配。
int computeViewerTargetWidth(double screenWidthPx) {
  final target = (screenWidthPx * 0.8).round();
  return target < 960 ? 960 : target;
}

/// [ente 对齐] 超大图解码防崩阈值（flutter/flutter#110331）：
/// RAM < 5GB → 24MP，否则 100MP；再 clamp 到 50MP（ente zoomable_image
/// _maxImagePixels + min(50MP) 同款）。超过阈值的图在 decode getTargetSize
/// 中等比降采样，避免超大图（如 200MP 全景）全分辨率解码 OOM/崩溃。
/// RAM 查询失败（null）时按高内存设备处理（100MP）。
int _cachedMaxDecodePixels = 100000000; // 100MP 默认，首次解码前刷新

/// main() 后台预热（不阻塞首帧）；RAM 查询失败时保持默认（幂等跳过）。
/// 顺带显式配置 ImageCache 上限：raw ARGB 管线的条目普遍 1~7MB/张，
/// 框架默认 1000 条 / 100MB 的「条数先到」语义会把字节上限架空
///（万张相册滚动时反复 evict + 重解码）。按 RAM 档位给字节上限、
/// 条数收敛到 500，让 LRU 以字节为准。
Future<void> initMaxDecodePixels() async {
  final ramMb = await MediaStoreChannel().totalRamMb();
  if (ramMb == null) return;
  final base = ramMb < 5 * 1024 ? 24000000 : 100000000;
  _cachedMaxDecodePixels = base < 50000000 ? base : 50000000; // min(50MP, base)
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSize = 500;
  cache.maximumSizeBytes = ramMb < 6 * 1024 ? 96 << 20 : 160 << 20;
}

/// 安卓端从 MediaStore 读字节的 ImageProvider。
class _AndroidBytesImageProvider
    extends ImageProvider<_AndroidBytesImageProvider> {
  const _AndroidBytesImageProvider({required this.ref, this.targetWidth});

  final ImageRef ref;
  final int? targetWidth;

  @override
  Future<_AndroidBytesImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
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
    final tw = key.targetWidth;
    // GIF:跳过 readSampledImage——Kotlin 侧 BitmapFactory 采样解码只取首帧,
    // 返回 raw ARGB 单帧,MultiFrameImageStreamCompleter 拿到的 codec 无后续帧
    // → viewer 里 GIF 永远停在第一帧。走 readBytes 全量 + dart 解码保持多帧。
    final isGif = key.ref.extension == '.gif';
    // targetWidth 指定(viewer 全图):优先走 native readSampledImage(下采样解码,快)。
    // 失败(超时/channel/解码异常)→ 回退 readBytes 全图,保证可用(诊断期)。
    if (tw != null && tw > 0 && !isGif) {
      try {
        // raw ARGB 像素(不经 JPEG):ImmutableBuffer + ImageDescriptor.raw 直接
        // instantiateCodec,跳过 dart 侧二次 JPEG 解码(原 P0 根因)。
        // ServicePolicy 优先级 150:用户正看的大图,压过网格清晰层(200),
        // 不低于占位层(100)。
        final r = await ServicePolicy.instance
            .run(
              RequestPriority.viewerImage,
              () => _msChannel.readSampledImage(
                key.ref.relativePath,
                targetWidth: tw,
              ),
              tag: 'full${tw}:${key.ref.id}',
            )
            .timeout(const Duration(seconds: 5));
        final sBuffer = await ui.ImmutableBuffer.fromUint8List(r.pixels);
        final desc = ui.ImageDescriptor.raw(
          sBuffer,
          width: r.width,
          height: r.height,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        // 必须 await：否则 instantiateCodec 的异步错误逃出 catch，
        // 不落 readBytes 兜底（3.47 unawaited_return_in_try_block 揪出）。
        return await desc.instantiateCodec();
      } catch (_) {
        // readSampledImage 失败(超时/channel/解码)→ 落到下面 readBytes 兜底
      }
    }
    final bytes = await _fs.readBytes(key.ref);
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    if (tw != null && tw > 0) {
      if (isGif) {
        // GIF:不降采样,全尺寸解码保全部帧(GIF 文件通常几 MB,可接受)。
        return decode(buffer);
      }
      return decode(
        buffer,
        getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
          return ui.TargetImageSize(width: tw);
        },
      );
    }
    // [ente 对齐] 全分辨率路径（HD/GIF）解码兜底：超过防崩阈值
    //（RAM 相关，见 _initMaxDecodePixels）等比降采样；未超阈值返回原始
    // 尺寸（getTargetSize 非空返回，等效全分辨率解码）。
    return decode(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        final px = intrinsicWidth * intrinsicHeight;
        final max = _cachedMaxDecodePixels;
        if (px <= max) {
          return ui.TargetImageSize(
            width: intrinsicWidth,
            height: intrinsicHeight,
          );
        }
        final aspect = intrinsicWidth / intrinsicHeight;
        final targetH = math.sqrt(max / aspect);
        final targetW = (aspect * targetH).round();
        return ui.TargetImageSize(width: targetW, height: targetH.round());
      },
    );
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

/// 缩略图占位层尺寸（px）：两级渐进的第一级。
/// Kotlin readThumbnail 对 ≤128 的请求优先解 EXIF 内嵌缩略图（~5ms），
/// 占位秒显后再由清晰层替换（对标系统相册 xqip/EXIF 占位 → 清晰渐进）。
const int kThumbnailPlaceholderSize = 128;

/// 构建缩略图 ImageProvider（相册网格 cell 用）。
///
/// 安卓端优先走 MediaStore loadThumbnail（API 29+，系统级高效缩略图），
/// 低版本回退 readBytes 全图 + targetWidth 下采样。
/// Windows 端用 ResizeImage 包 FileImage 做下采样。
///
/// [squareCrop]（Android）：true = 方形 cover 显示场景（网格 cell/封面/
/// 缩略图条）——长图走 centerCrop 解码（横向保真实像素，对标系统相册）；
/// false（默认）= contain 显示场景（大图渐进链）——走系统 fit-inside，
/// 缩略图与原图同 aspect，避免 Hero 落位时几何突变（真机实证：方形
/// crop 占位在大图 contain 位被拉伸，原图解完瞬间变回）。
ImageProvider buildThumbnailProvider(
  ImageRef ref, {
  int size = 256,
  int? dateModifiedMs,
  bool squareCrop = false,
}) {
  if (Platform.isAndroid) {
    // 注册 (size, squareCrop) 变体——evictImageCache 按注册表重放构造
    // key 逐出（动态 cell size 等无法枚举的档位自动入表）。
    _usedThumbVariants.add((size, squareCrop));
    return _AndroidThumbnailProvider(
      ref: ref,
      size: size,
      dateModifiedMs: dateModifiedMs,
      squareCrop: squareCrop,
    );
  }
  return ResizeImage(
    FileImage(File(p.join(ref.root, ref.relativePath))),
    width: size,
  );
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
  const _AndroidThumbnailProvider({
    required this.ref,
    required this.size,
    this.dateModifiedMs,
    this.squareCrop = false,
  });

  final ImageRef ref;
  final int size;

  /// 源图 DATE_MODIFIED（毫秒）：① 参与 ImageCache key —— 图片被编辑后
  /// dateModified 变化 → 新 key 自动重取；② 透传 Kotlin 磁盘缓存校验。
  final int? dateModifiedMs;

  /// 方形 cover 显示（true）→ 长图 centerCrop；contain 显示（false）→
  /// fit-inside（全图 aspect）。参与缓存 key：同 size 两种语义不混存。
  final bool squareCrop;

  @override
  Future<_AndroidThumbnailProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<_AndroidThumbnailProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _AndroidThumbnailProvider key,
    ImageDecoderCallback decode,
  ) {
    final completer = MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield ErrorDescription('thumbnail id: ${key.ref.relativePath}');
      },
    );
    // ⚠️ 关键：provider 是整体解码（无渐进 chunk），若不发 chunk 事件，
    // Image.loadingBuilder 永远不会被调用（它挂在 onChunk 回调上）——
    // 两级渐进的占位层（小图/灰底）就全部失效。发一个初始 chunk 事件
    // 让 loadingBuilder 在解码完成前插入占位层；完成帧到达后自动替换。
    // 时序安全：Image 添加 listener 是同步的，microtask 在 listener 之后执行。
    scheduleMicrotask(() {
      // ignore: invalid_use_of_protected_member
      completer.reportImageChunkEvent(
        const ImageChunkEvent(
          cumulativeBytesLoaded: 1,
          expectedTotalBytes: null,
        ),
      );
    });
    return completer;
  }

  Future<ui.Codec> _loadAsync(
    _AndroidThumbnailProvider key,
    ImageDecoderCallback decode,
  ) async {
    // 先试系统缩略图（API 29+）。空数组 = 低版本不支持，回退全图。
    // ServicePolicy：占位层(≤128)优先级 100 滚动中不暂停秒显；清晰层 200
    // 滚动中挂起、停稳集中补（对标 aves getFastThumbnail/getSizedThumbnail）。
    Uint8List bytes;
    try {
      bytes = await ServicePolicy.instance.run(
        key.size <= kThumbnailPlaceholderSize
            ? RequestPriority.fastThumbnail
            : RequestPriority.sizedThumbnail,
        () => _msChannel.readThumbnail(
          key.ref.id,
          width: key.size,
          height: key.size,
          dateModifiedMs: key.dateModifiedMs,
          squareCrop: key.squareCrop,
        ),
        tag: 'thumb${key.size}${key.squareCrop ? 's' : ''}:${key.ref.id}',
      );
    } catch (_) {
      bytes = Uint8List(0);
    }
    if (bytes.isEmpty) {
      // 回退：全图字节 + targetWidth 下采样
      final raw = await _fs.readBytes(key.ref);
      bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        return ui.TargetImageSize(width: key.size);
      },
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _AndroidThumbnailProvider &&
        other.ref.id == ref.id &&
        other.size == size &&
        other.dateModifiedMs == dateModifiedMs &&
        other.squareCrop == squareCrop;
  }

  @override
  int get hashCode => Object.hash(ref.id, size, dateModifiedMs, squareCrop);
}
