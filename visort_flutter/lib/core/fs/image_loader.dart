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
import 'cache_perf.dart';
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
/// [priority]（安卓）：ServicePolicy 入队优先级——预取场景（filmstrip
/// p250）须低于用户当前页（p50），防止抢队（当年「主图黑屏」根因）。
/// 不参与 ImageCache key（相同 id+tw 的实例等值，先到的 load 生效）。
ImageProvider buildImageProvider(ImageRef ref,
    {int? targetWidth, int priority = RequestPriority.viewerImage}) {
  if (Platform.isAndroid) {
    return _AndroidBytesImageProvider(
      ref: ref,
      targetWidth: targetWidth,
      priority: priority,
    );
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
  final results = <bool>[];
  for (final (size, crop) in _usedThumbVariants) {
    results.add(
      cache.evict(
        _AndroidThumbnailProvider(ref: ref, size: size, squareCrop: crop),
      ),
    );
  }
  // 全图：无 targetWidth 条目（带 targetWidth 的 viewer 变体由
  // evictViewerImageCache 在关闭时按具体宽度清理）。
  results.add(cache.evict(_AndroidBytesImageProvider(ref: ref)));
  cachePerfEvict('media', mediaStoreId, results);
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
  final results = <bool>[
    cache.evict(_AndroidBytesImageProvider(ref: ref)),
    cache.evict(_AndroidBytesImageProvider(ref: ref, targetWidth: targetWidth)),
    // large640 等比档（= detail_page_state.kViewerLargeThumbSize，core 层
    // 不可 import UI 常量故写字面值）：此前只进不出，长会话逐张累积
    //（竖图 ~2.9MB/条）挤占网格档 → pop 落位黑格的元凶之一，一并清理。
    cache.evict(
      _AndroidThumbnailProvider(ref: ref, size: 640, squareCrop: false),
    ),
    // mid900 自产档（= detail_page_state.kViewerMidThumbSize 字面值）：
    // 条快甩远邻预取（dist1~2）走的 readSampledImage 下采样档，随走随清。
    cache.evict(_AndroidBytesImageProvider(ref: ref, targetWidth: 900)),
  ];
  cachePerfEvict('viewer', mediaStoreId, results);
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
///
/// 2026-08-28 打点实测（PJZ110 23GB / 18s 窗口）：160MB 全程贴满，viewer
/// 压力轮一次 open（3 张 full ≈9MB）即挤出 23 条网格缩略图 → thumb 档
/// 100% 重解码（115/115 RE）、网格命中率 25/25→0/25。23GB 档上调 256MB
///（23GB 设备内存余量充足），6GB 档维持 96MB 不动。
Future<void> initMaxDecodePixels() async {
  final ramMb = await MediaStoreChannel().totalRamMb();
  if (ramMb == null) return;
  final base = ramMb < 5 * 1024 ? 24000000 : 100000000;
  _cachedMaxDecodePixels = base < 50000000 ? base : 50000000; // min(50MP, base)
  final cache = PaintingBinding.instance.imageCache;
  // 条数同步 500→800：256MB 下混合条目（thumb96 0.04MB / full 3.4MB）
  // 平均 ~0.5MB，500 条会先于字节到顶、架空「字节为准」语义。
  cache.maximumSize = 800;
  cache.maximumSizeBytes = ramMb < 6 * 1024 ? 96 << 20 : 256 << 20;
  cachePerfEvent(
    'config ram=${ramMb}MB maxPixels=$_cachedMaxDecodePixels '
    'limit=${cache.maximumSize}n/${cache.maximumSizeBytes >> 20}MB',
  );
}

/// 安卓端从 MediaStore 读字节的 ImageProvider。
class _AndroidBytesImageProvider
    extends ImageProvider<_AndroidBytesImageProvider> {
  const _AndroidBytesImageProvider({
    required this.ref,
    this.targetWidth,
    this.priority = RequestPriority.viewerImage,
  });

  final ImageRef ref;
  final int? targetWidth;

  /// ServicePolicy 入队优先级（预取 vs 用户当前页）。不参与 ==/hashCode
  ///（相同 id+tw 等值共享缓存条目，先发起的 load 决定实际优先级）。
  final int priority;

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
    // 【raw 直路】viewer full（targetWidth 非 GIF）：native readSampledImage
    // 返回的已是最终 ARGB 像素——decodeImageFromPixels 同步建 ui.Image，
    // 完全绕开 ImageDescriptor.raw→codec→getNextFrame 的引擎 io worker
    // 解码队列。真机实证（2026-09-06）：盘缓存 30ms 出像素后，帧生产在
    // codec 队列排 ~700ms =「翻页糊半秒以上」的根因（窗口内 Dart isolate
    // 全程空闲在等 getNextFrame 的 Future）；raw 描述符的 desc/buffer
    // 生命周期纠缠（855ms 停摆事件，见下方注释）也一并消除。
    // GIF/全分辨率（HD 放大）路径保持 MultiFrame（多帧语义必须 codec）。
    final tw = key.targetWidth;
    final isRawPath =
        tw != null && tw > 0 && key.ref.extension.toLowerCase() != '.gif';
    if (isRawPath) {
      return _RawImageStreamCompleter(
        _loadRawImage(key, decode),
        // [RAW] 排查打点标识（id）。
        debugLabel: 'id: ${key.ref.relativePath}',
        informationCollector: () sync* {
          yield ErrorDescription('id: ${key.ref.relativePath}');
        },
      );
    }
    // 【initialImage 同步回退机制已撤销】试验版在真机上引发"第二次打开
    // 同图时 855ms 全管线停摆"（帧数据：两线程 busy 均 <10ms 但 855ms
    // 无帧提交，停摆窗内零日志）——高度疑似回退帧与 640 档 completer
    // 共享 ui.Image 的生命周期纠缠（evict/换帧 double-dispose → raster
    // 层阻塞恢复）。immich 的 OneFrame completer 体系自管理帧生命周期，
    // 直接嫁接到 MultiFrame completer 上不可行，需整套移植才安全。
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield ErrorDescription('id: ${key.ref.relativePath}');
      },
    );
  }

  /// raw 直路的帧生产（与 _loadAsync 的 raw 分支同源，但直接产 ui.Image）：
  /// readSampledImage（ServicePolicy 限流）→ decodeImageFromPixels 同步建帧；
  /// 失败（超时/channel/解码）回退 readBytes + decode codec 单帧转 image。
  Future<ui.Image> _loadRawImage(
    _AndroidBytesImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final tw = key.targetWidth!;
    try {
      // [RAW] 排查打点：channel 回传时刻（与 [SP] 的任务完成时刻对齐——
      // 二者应同刻；[RAW] px 晚于 [SP] done = Dart→native 发起或回传被延迟）。
      final rawT0 = DateTime.now().microsecondsSinceEpoch ~/ 1000;
      final r = await ServicePolicy.instance
          .run(
            key.priority,
            () => _msChannel.readSampledImage(
              key.ref.relativePath,
              targetWidth: tw,
            ),
            tag: 'full${tw}:${key.ref.id}',
          )
          .timeout(const Duration(seconds: 5));
      debugPrint(
        '[RAW] px id=${key.ref.id} dt=${(DateTime.now().microsecondsSinceEpoch ~/ 1000) - rawT0}ms t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
      );
      // 同步直建（decodeImageFromPixelsSync）：不走 instantiateCodec/
      // getNextFrame 的引擎 io worker 队列（decodeImageFromPixels 异步版
      // 内部仍是 codec+getNextFrame，绕不开）；像素拷贝在当前线程
      //（~3MB 几 ms）。
      final img = ui.decodeImageFromPixelsSync(
        r.pixels,
        r.width,
        r.height,
        ui.PixelFormat.rgba8888,
      );
      cachePerfDecode(
        cacheLevelFull(tw),
        key.ref.id,
        r.width,
        r.height,
        via: 'direct',
      );
      return img;
    } catch (_) {
      cachePerfEvent('fallback L=${cacheLevelFull(tw)} id=${key.ref.id}');
    }
    // 兜底：readBytes 全图 + dart 侧下采样解码（codec 单帧转 image；非
    // GIF——GIF 已在 loadImage 分流到 MultiFrame 路径）。
    final bytes = await _fs.readBytes(key.ref);
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    final codec = await decode(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        cachePerfDecodeIntrinsic(
          '${cacheLevelFull(tw)}FB',
          key.ref.id,
          intrinsicWidth,
          intrinsicHeight,
        );
        return ui.TargetImageSize(width: tw);
      },
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<ui.Codec> _loadAsync(
    _AndroidBytesImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    // raw ARGB 路径（targetWidth 非 GIF）已在 loadImage 分流到
    // _loadRawImage 直路——本方法只剩 GIF 多帧与全分辨率（HD）两类。
    final tw = key.targetWidth;
    // GIF:跳过 readSampledImage——Kotlin 侧 BitmapFactory 采样解码只取首帧,
    // 返回 raw ARGB 单帧,MultiFrameImageStreamCompleter 拿到的 codec 无后续帧
    // → viewer 里 GIF 永远停在第一帧。走 readBytes 全量 + dart 解码保持多帧。
    final isGif = key.ref.extension == '.gif';
    final bytes = await _fs.readBytes(key.ref);
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    if (tw != null && tw > 0) {
      if (isGif) {
        // GIF:不降采样,全尺寸解码保全部帧(GIF 文件通常几 MB,可接受)。
        cachePerfDecode('gif$tw', key.ref.id, null, null, via: 'bytes');
        return decode(buffer);
      }
      return decode(
        buffer,
        getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
          cachePerfDecodeIntrinsic(
            '${cacheLevelFull(tw)}FB',
            key.ref.id,
            intrinsicWidth,
            intrinsicHeight,
          );
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
        int outW;
        int outH;
        if (px <= max) {
          outW = intrinsicWidth;
          outH = intrinsicHeight;
        } else {
          final aspect = intrinsicWidth / intrinsicHeight;
          final targetH = math.sqrt(max / aspect);
          outW = (aspect * targetH).round();
          outH = targetH.round();
        }
        // 打最终解码尺寸（进缓存的真实字节）；intrinsic 在 via 里留档。
        cachePerfDecode(
          'hd',
          key.ref.id,
          outW,
          outH,
          via: 'bytes(${intrinsicWidth}x$intrinsicHeight)',
        );
        return ui.TargetImageSize(width: outW, height: outH);
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

/// raw ARGB 单帧 completer（viewer full 直路，见 _AndroidBytesImageProvider
/// .loadImage 的 raw 直路注释）：Future<ui.Image> 完成 → setImage 同步通知。
/// 生命周期沿用基类协议（listeners 空 + keepAlive 0 → onDisposed 释放
/// ui.Image；各 listener 拿的是 clone，dispose 只减引用计数）。
class _RawImageStreamCompleter extends ImageStreamCompleter {
  /// ⚠️ ui.Image 所有权归基类：setImage 传入的实例存入基类 `_currentImage`，
  /// 基类 `_maybeDispose()` 在 onDisposed() **之前**已 `_currentImage?.dispose()`
  ///（image_stream.dart:709-712）——子类不得再持引用二次 dispose（真机切后台
  /// 实证 "native peer has been collected" 崩溃，抛在帧回调里中断当帧回调链）。
  /// 迟到图（completer 已 dispose 时 future 才完成）自行释放防泄漏。
  _RawImageStreamCompleter(
    Future<ui.Image> image, {
    String? debugLabel,
    InformationCollector? informationCollector,
  }) : _informationCollector = informationCollector {
    image.then(
      (img) {
        if (_dead) {
          img.dispose(); // completer 已回收：无人接盘，自释放防泄漏
          return;
        }
        // [RAW] 排查打点：setImage 实际生效时刻（与 [RAW] px 间隔 = future
        // 续体延迟；与 [PROBE] 行对齐看翻页 740ms 窗口内它落在哪）。
        debugPrint(
          '[RAW] set id=$debugLabel t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
        );
        setImage(ImageInfo(image: img));
      },
      onError: (Object exception, StackTrace stackTrace) {
        reportError(
          context: ErrorDescription('解析 raw ARGB 图片'),
          exception: exception,
          stack: stackTrace,
          informationCollector: _informationCollector,
          silent: true,
        );
      },
    );
  }

  final InformationCollector? _informationCollector;

  /// 已 dispose（onDisposed 置位）：迟到的 future 结果丢弃。
  bool _dead = false;

  @override
  void onDisposed() {
    _dead = true;
    debugPrint(
      '[RAW] disposed t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
    );
    super.onDisposed();
  }
}

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
/// [squareCrop]（Android）：仅参与 ImageCache key（同档两种语义不混存，
/// 历史上 true=方形裁切/false=等比）——native 已统一为【等比请求框】
/// 解码：方形请求框在 ColorOS 上会被系统吐 mini 缓存（固定 3:4/4:3，
/// 与源图比例不符），错比例缩略图会固化进磁盘缓存并导致 viewer Hero
/// 飞行终点比例错误（真机实证 2304×4608 图拿到 3:4 缩略图）。等比版
/// 全端一致：网格 cover 裁中、Hero 飞行 aspect 连续、viewer contain
/// 无跳变。
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

  /// 历史语义（true=方形裁切/false=等比）已废弃——native 统一等比请求框
  /// 解码（见 buildThumbnailProvider doc）。仅参与缓存 key：同 size 两种
  /// 语义不混存。
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
      // 回退：全图字节 + targetWidth 下采样。同样走 ServicePolicy 限流
      // （审查 F12）：兜底读是整图 IO，量级远大于缩略图通道，裸跑绕过
      // 并发门会与正常管线抢带宽；优先级沿用本请求档位（滚动中清晰层
      // 仍可被挂起，语义不变）。
      final raw = await ServicePolicy.instance.run(
        key.size <= kThumbnailPlaceholderSize
            ? RequestPriority.fastThumbnail
            : RequestPriority.sizedThumbnail,
        () => _fs.readBytes(key.ref),
        tag: 'thumbFallback:${key.ref.id}',
      );
      bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        cachePerfDecodeIntrinsic(
          cacheLevelThumb(key.size, key.squareCrop),
          key.ref.id,
          intrinsicWidth,
          intrinsicHeight,
          via: 'thumb',
        );
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
