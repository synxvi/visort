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
import 'cache_aware_listener_tracker.dart';
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
    // 放大升档渐进条目（2304/4096 帧在 _ProgressiveViewerImageCompleter
    // 内部，无独立键——evict 渐进 provider 单键整体回收）。⚠️ includeLive
    // 必须 false：默认 true 会 dispose live completer 的 keepAlive handle，
    // 之后任何一次 resolve 都造出第二个 completer——屏上听旧的、
    // _progressiveStream 持旧的、新请求推给无人观看的新实例（immich 对照
    // 实锤的「推给空气」分裂根因，2026-09-08）。pop 时 viewer 已关无 live，
    // false 与 true 等效。
    cache.evict(
      _AndroidProgressiveImageProvider(ref: ref, baseTargetWidth: 1152),
      includeLive: false,
    ),
  ];
  cachePerfEvict('viewer', mediaStoreId, results);
}

/// 只清放大升档条目（渐进 provider 单键：2304/4096 帧在 completer 内部，
/// 无独立 ImageCache 键）。独立于 [evictViewerImageCache]：翻页窄窗 trim
///（detail_page _trimDistantHdCache）只应逐出升档——宽窗函数会顺带清
/// 1152 预取档，误伤 ±6 窗口的「掠过即 full」成果（快甩残余 miss 的
/// 历史教训）。在屏条目 evict 后由引用计数自然回收（live completer
/// 持有 listener，页 dispose 后无引用即释放）。
void evictViewerUpgradeCache(String mediaStoreId) {
  if (!Platform.isAndroid) return;
  final cache = PaintingBinding.instance.imageCache;
  final ref = imageRefFromMediaStoreId(mediaStoreId);
  final results = <bool>[
    // includeLive:false（同 evictViewerImageCache 的渐进键注释）：翻页窄窗
    // trim 只清 cache 持仓，绝不杀在用 completer 的 keepAlive——否则造出
    // 双 completer 分裂（推给空气）。
    cache.evict(
      _AndroidProgressiveImageProvider(ref: ref, baseTargetWidth: 1152),
      includeLive: false,
    ),
  ];
  cachePerfEvict('viewerHd', mediaStoreId, results);
}

/// viewer 原图下采样目标宽度（物理像素）：对齐系统相册 by70.c() = max(960, 屏宽×0.8)。
/// 屏宽物理 = 逻辑宽 × devicePixelRatio。打开瞬间解码到此宽度：对 12MP 图约 ~1MP，
/// 解码快、能压进 250ms 飞行动画窗；全屏 contain（屏宽 ≤1440）0.8× 略欠采样但视觉
/// 可接受（系统相册同策略）；放大 scale>1.3 由 zoomable_image._maybeTriggerHdUpgrade
/// 加载 2304 档（kViewerHdThumbSize，2026-09-08 补实曾经的 _hdTriggered 死注释）
/// 覆盖——不落原片全像素：无 targetWidth 的 HD 通道绕过 ServicePolicy 门且
/// 48MB/张 会挤爆内存缓存（网格缩略图连锁 RE 重解码）。
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

  /// 升档加载入口（_ProgressiveViewerImageCompleter 专用）：raw 直建档
  ///（2304 级以下用）。
  Future<ui.Image> loadRawImageForUpgrade(ImageDecoderCallback decode) =>
      _loadRawImage(this, decode);

  /// 升档加载入口（_ProgressiveViewerImageCompleter 专用）：4096 档必须走
  /// **JPEG bytes→引擎 codec**（readSampledJpeg 通道）——⚠️ 不可用
  /// readSampledImage raw 回传：48MB 像素过 MethodChannel 时 main 线程
  /// StandardMessageCodec 序列化扩容翻倍再拷一份（96MB 分配）→ OOM
  /// 闪退 + 每张 100ms+ main 线程卡顿（真机 23:03 FATAL 实证，2026-09-08）。
  ///
  /// 【完全对齐 immich·2026-09-09】≤25MP 图 Kotlin 侧直回**原图 bytes**
  /// （零解码零重压缩，immich 本地相册同款单步链）：引擎单次解码，替换
  /// 发生在飞行动画内。>25MP 超大图 Kotlin 侧降级采样重压缩慢链（OOM
  /// 防）。
  Future<ui.Image> loadJpegImageForUpgrade(ImageDecoderCallback decode) async {
    final tw = targetWidth!;
    final r = await ServicePolicy.instance.run(
      priority,
      // ⚠️ timeout 必须在 job 内（channel 调用上）：裹在 run 外会把
      // 4096 单飞排队（40ms 轮询）+ ServicePolicy 排队都计入 8s——
      // 连发时等待者被误杀 TimeoutException，该图 4096 请求已消费
      // 永不再发 = 永久停 1152（审查 P2）。job 内计时 = 只量
      // channel+解码本身；且超时抛出必走 _run4096Exclusive 的 finally
      // 清 owner——连带根治「owner 卡死无超时 → 等待者死循环」。
      () => _msChannel
          .readSampledJpeg(
            ref.relativePath,
            targetWidth: tw,
          )
          .timeout(const Duration(seconds: 8)),
      // ⚠️ tag 必须与 _handleAbandoned 的压级匹配串
      //（'full4096:${id}'）一致：缺 tag 时三处 deprioritizeQueued
      // 永不命中 = 快速翻页离屏压级死代码，在途 4096 全 p150 挤占
      // 邻取预取（2026-09-11 审查 P1）。
      tag: 'full4096:${ref.id}',
    );
    final buffer = await ui.ImmutableBuffer.fromUint8List(r.bytes);
    // 原图 bytes 原样（EXIF orientation 由引擎 SkCodec 应用）：原尺寸解。
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  ImageStreamCompleter loadImage(
    _AndroidBytesImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // 【raw 直路】viewer full（targetWidth 非 GIF，含 2304/4096 升档）：
    // native readSampledImage 返回的已是最终 ARGB 像素——
    // decodeImageFromPixelsSync 同步建 ui.Image，一遍到位（immich 同款
    // native 解码→raw 包装语义）。4096 档曾走「JPEG bytes→引擎 codec
    // 再解」——compress+二次解码双重 codec 往返 400-800ms =「压根没
    // 解码」体感（2026-09-08 真机实证），已废除；48MB raw 回传的一次
    // 分配（~30-80ms）发生在推帧时刻（远离手势），单帧可接受。
    // GIF/全分辨率（HD 放大）路径保持 MultiFrame（多帧语义必须 codec）。
    final tw = key.targetWidth;
    final isGif = key.ref.extension.toLowerCase() == '.gif';
    final isRawPath = tw != null && tw > 0 && !isGif;
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

// ───────────────────────── viewer 渐进升档（immich 同款架构） ─────────────────────────
//
// 此前「放大升档」是换 provider：setState → 新 provider → cache 查询 →
// RawImage 重建 → 纹理上传全挤一帧 = 卡顿/跳变的结构性根源（静止门/预上传
// 只是补偿）。现为单 completer 串流推帧：resolve 一次，2304/4096 解码完成
// 后由 completer 内部 setImage 推进——widget 不 rebuild、不换 provider，
// 高分辨率位图渲染进同一尺寸框（PhotoView 布局用 ratio 补偿保持视觉恒定），
// 「换源」动作整体消失。

/// 渐进升档能力接口（zoomable_image 经 `stream.completer as?` 使用，不暴露
/// 私有实现类型）。
abstract class ProgressiveImageCompleter extends ImageStreamCompleter {
  /// 请求解码到 [targetWidth] 档。重复/降级请求幂等。
  /// [priority] 可指定 ServicePolicy 优先级（构造并行发起用 p150）。
  void requestUpTo(int targetWidth, {int? priority});

  /// 暂缓推帧（解码照常进行）：帧解完暂存 completer 内，不 setImage。
  /// 供 widget 控制「替换时机」——飞行中/手势中推帧会有视觉跳变。
  void holdFrames();

  /// 释放暂存帧立即推（幂等：无暂存帧时 no-op）。此后新帧不再 hold
  ///（直到再次 holdFrames）。
  void flushHeldFrame();

  /// 帧解完且被 hold 时回调（widget 检查时机后决定 flush）。置 null 摘除。
  void setOnFrameReady(void Function()? callback);

  /// 是否已有可显示帧（推帧或暂存）——widget 换链守卫：【实验·打开即
  /// 原图】跳过 1152 首帧后 completer 首帧即 4096，帧就绪前换上渐进
  /// provider = PhotoView 黑底。
  bool get hasFrame;

  /// 是否已被 evict 置死（_dead）：死 completer 的 requestUpTo/flush 全
  /// 无效。翻回当前页时据此判断渐进链是否需要重建（真机实证
  /// 2026-09-11：拖动跨页触发 evict，拖回后 _loadedFinalImage 标志仍在
  /// → 不重发 → 图停留 1152「不再变清晰」）。
  bool get isDead;
}

/// 双桶缓存判据标记（visort_image_cache 的 _cacheForKey 用对象模式匹配）：
/// progressive 升档条目进大图桶，与网格缩略图互不驱逐。
abstract interface class ProgressiveImageKey {}

/// viewer 渐进升档 provider：1152 显示档就绪后由 zoomable_image 换上
///（这是最后一次换 provider，且发生在未放大态——key 重建链路已验证），
/// 此后放大升档全部走 completer 内推帧。
class _AndroidProgressiveImageProvider
    extends ImageProvider<_AndroidProgressiveImageProvider>
    implements ProgressiveImageKey {
  const _AndroidProgressiveImageProvider({
    required this.ref,
    required this.baseTargetWidth,
    this.priority = RequestPriority.viewerImage,
  });

  final ImageRef ref;

  /// 首帧基准档（= computeViewerTargetWidth，偷帧源与 PhotoView 初始布局）。
  final int baseTargetWidth;
  final int priority;

  @override
  Future<_AndroidProgressiveImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<_AndroidProgressiveImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _AndroidProgressiveImageProvider key,
    ImageDecoderCallback decode,
  ) {
    debugPrint('[PVP] new completer id=${key.ref.id}');
    return _ProgressiveViewerImageCompleter(key: key, decode: decode);
  }

  @override
  bool operator ==(Object other) =>
      other is _AndroidProgressiveImageProvider && other.ref.id == ref.id;

  @override
  int get hashCode => Object.hash(ref.id, 'progressive');
}

class _ProgressiveViewerImageCompleter extends ImageStreamCompleter
    with CacheAwareListenerTrackerMixin
    implements ProgressiveImageCompleter {
  _ProgressiveViewerImageCompleter({
    required _AndroidProgressiveImageProvider key,
    required ImageDecoderCallback decode,
  }) : _key = key,
       _decode = decode {
    // 【immich 同款构造三步】（one_frame_multi_image_stream_completer）：
    // ① listener 追踪初始化（hadInitialImage 兜底「initialImage 同步
    //    setImage → cache pending listener attach→收帧→detach」的假死亡）；
    // ② initialImage 同步偷 1152 帧 setImage——1152 是 immich 的 preview
    //    显示档语义：flight 起点/预建兜底全靠它清晰上屏（2026-09-09 实验
    //    「跳过 1152 直接原图」证伪：flight 全程只剩 300px 网格小图放大 4 倍
    //    = 超糊，比 immich 差一档——immich 飞行起点就是 preview。1152 恢复
    //    显示档地位，4096 是唯一升档帧）；
    // ③ 升档推帧（immich 是 images.listen(setImage) 流，visort 为命令式
    //    requestUpTo/_pump——推帧机制同源）。
    final initial = _stealBaseFrame();
    setupListenerTracking(
      hadInitialImage: initial != null,
      onLastListenerRemoved: _handleAbandoned,
    );
    if (initial != null) {
      _hasImage = true;
      setImage(initial);
    }
    debugPrint(
        '[PVP] new completer id=${key.ref.id} initial=${initial != null}');
    // 【飞行窗让空·2026-09-10】构造只 hold 不发起 4096——由 widget 在
    // 路由 settled 后延迟 600ms 发起（见 zoomable_image._scheduleHdStart）。
    // 原图直出帧成本已变重（≤25MP 直回 bytes ~7MB IO + 引擎全解 48MB
    // bitmap），与当前页 1152、±1 邻页预取同窗并行 = 四个大任务挤飞行
    // 300ms 窗口 =「飞行动画顿挫」（真机时间线实证，immich 打开仅解
    // 当前页一个）。发起后 p50 不变。
    holdFrames();
  }

  final _AndroidProgressiveImageProvider _key;
  final ImageDecoderCallback _decode;

  /// 档位阶梯：仅 4096（= kViewerUltraThumbSize，原图等效档）。1152 显示
  /// 档即 immich 的 preview 语义（视口像素级），2304 中间档已废除（多一次
  /// 解码 + 多一档内存，收益被 4096 覆盖）。core 层不 import UI 常量，
  /// 字面量 + 注释对齐（同 evictViewerImageCache 约定）。
  static const List<int> _levels = [4096];

  /// 当前请求目标在 [_levels] 中的索引（-1 = 未请求升档）。
  int _targetIndex = -1;

  /// 已完成（推帧或失败跳过）的最高档索引：游标推进制，防重复重解。
  int _loadedIndex = -1;

  /// 在途档索引（-1 = 空闲）。
  int _loadingIndex = -1;

  /// 当前解码优先级（requestUpTo 可升级，如放大触发 → viewerHd）。
  late int _priority = _key.priority;

  /// 推帧闸（见构造注释）：true 时解完的帧暂存 [_heldImage] 不推。
  bool _hold = false;
  ui.Image? _heldImage;
  void Function()? _onFrameReady;
  bool _dead = false;

  /// 是否已产出可显示帧（推帧/暂存/兜底偷帧任一）——hasFrame 的实现
  /// 基础，widget 换链时机守卫。
  bool _hasImage = false;

  @override
  bool get hasFrame => _hasImage;

  @override
  bool get isDead => _dead;

  /// 零 listener：**不置死**（immich 语义——abandoned 只取消网络在途请求，
  /// completer 留在 cache 里继续服务）。真机/模拟器实证：UI 树重建
  ///（PhotoView ValueKey 翻转、页重建）会让 listener 短暂全退——置死会让
  /// 36ms 后回来的 listener 挂在死 completer 上，requestUpTo 永远哑火
  ///（「反复双击死活不清楚」的最终根因）。帧继续解、继续推，无人观看的
  /// 推帧落在 _currentImage 里，listener 回来时同步回放最新档，零浪费。
  /// _dead 仅在基类 onDisposed（cache evict 且零引用的真 dispose）置位。
  ///
  /// 在途任务压级（快速翻页防堆积）：连续翻页会积累多个在途 4096
  ///（每页一个），全 p150 会挤占邻取 1152 预取 → 掠过页 miss → 快甩/
  /// 翻页模糊。离屏即压到全队列最低（解完照推、翻回命中 blob 不变）。
  void _handleAbandoned() {
    debugPrint('[PVP] abandoned (deprioritize) id=${_key.ref.id}');
    ServicePolicy.instance.deprioritizeQueued(
      (t) => t.tag == 'full4096:${_key.ref.id}',
    );
  }

  /// 首帧同步偷取（immich getInitialImage 同款，image_provider.dart:27-55）：
  /// resolve 基准档（1152）→ addListener——其 completer 已有 current 时
  /// 【同步】回调，取 clone 立刻移除返回；不同步（解码在途，理论不可达
  /// ——1152 刚显示完毕）返回 null，放弃首帧。clone 与 1152 条目共享
  /// ui.Image（引用计数），不额外占内存。
  ImageInfo? _stealBaseFrame() {
    final base = _AndroidBytesImageProvider(
      ref: _key.ref,
      targetWidth: _key.baseTargetWidth,
      priority: _key.priority,
    );
    final completer = base.resolve(const ImageConfiguration()).completer;
    if (completer == null) return null;
    ImageInfo? stolen;
    late final ImageStreamListener probe;
    probe = ImageStreamListener((ImageInfo? info, bool synchronousCall) {
      if (info != null && synchronousCall) stolen = info.clone();
    });
    completer.addListener(probe);
    completer.removeListener(probe);
    return stolen;
  }

  @override
  void requestUpTo(int targetWidth, {int? priority}) {
    if (_dead) {
      debugPrint('[HD] req-skip dead tw=$targetWidth id=${_key.ref.id}');
      return;
    }
    final idx = _levels.indexOf(targetWidth);
    if (idx < 0 || idx <= _targetIndex) return; // 未定义/已覆盖：幂等
    if (priority != null) _priority = priority;
    debugPrint('[HD] req tw=$targetWidth p=$_priority id=${_key.ref.id}');
    _targetIndex = idx;
    scheduleMicrotask(_pump);
  }

  /// 串行渐进加载（游标推进）：2304（raw blob ~125ms，先上屏把清晰度
  /// 翻倍）→ 4096（JPEG ~300-500ms，补满）。真机实证单目标直达的 4096
  /// 解码总延迟近 1s =「压根没解码」体感；两级渐进让第一级 ~125ms 就
  /// 明显变清楚。失败也推进游标（跳过该档防死循环重试）。
  void _pump() {
    if (_dead || _loadingIndex >= 0) return;
    final next = _loadedIndex + 1;
    if (next > _targetIndex) return;
    _loadingIndex = next;
    final tw = _levels[next];
    // 复用 _AndroidBytesImageProvider 的加载实现，临时实例只作参数载体。
    // 4096 走 JPEG bytes→引擎 codec（io worker，UI 零大拷贝——滑动帧
    // 30-80ms 尖峰的根治；解码慢无妨，帧早已并行发起并 hold）。
    final delegate = _AndroidBytesImageProvider(
      ref: _key.ref,
      targetWidth: tw,
      priority: _priority,
    );
    final Future<ui.Image> future = tw >= 4096
        ? _run4096Exclusive(() => delegate.loadJpegImageForUpgrade(_decode))
        : delegate.loadRawImageForUpgrade(_decode);
    future.then((img) {
      _loadingIndex = -1;
      if (_dead) {
        debugPrint('[HD] push-skip dead tw=$tw id=${_key.ref.id}');
        img.dispose();
        return;
      }
      _loadedIndex = next;
      if (_hold) {
        // 闸门关闭（飞行/手势中）：帧暂存，widget 在合适时机 flush。
        _heldImage?.dispose();
        _heldImage = img;
        _hasImage = true;
        debugPrint('[HD] hold tw=$tw id=${_key.ref.id}');
        _onFrameReady?.call();
      } else {
        debugPrint('[HD] push tw=$tw id=${_key.ref.id}');
        _hasImage = true;
        setImage(ImageInfo(image: img));
      }
      if (_targetIndex > _loadedIndex) scheduleMicrotask(_pump);
    }).catchError((Object e, StackTrace? st) {
      _loadingIndex = -1;
      debugPrint('[HD] level fail tw=$tw id=${_key.ref.id} err=$e');
      if (_dead) return;
      _loadedIndex = next;
      if (_targetIndex > _loadedIndex) scheduleMicrotask(_pump);
      // 【实验兜底】唯一帧（4096）失败（损坏/异常）：偷 1152 帧垫底防
      // 灰屏死等（原机制 1152 首帧先在无此风险；1152 也失败则保持空帧
      // 由 widget 层 _showingThumbnailFallback 兜）。
      if (!_hasImage) {
        final fallback = _stealBaseFrame();
        if (fallback != null) {
          _hasImage = true;
          setImage(fallback);
        }
      }
    });
  }

  @override
  void holdFrames() {
    _hold = true;
  }

  @override
  void flushHeldFrame() {
    _hold = false;
    final img = _heldImage;
    _heldImage = null;
    if (img == null || _dead) {
      img?.dispose();
      return;
    }
    debugPrint('[HD] flush id=${_key.ref.id}');
    setImage(ImageInfo(image: img));
  }

  @override
  void setOnFrameReady(void Function()? callback) {
    _onFrameReady = callback;
  }

  /// 【4096 全局单飞】整个 app 同时只允许一个 4096 解码在 ServicePolicy
  /// 门内。结构性隔离：4096 是 400-600ms 的独占型长任务，无此约束时
  /// 滚动积压的多个会占满 6 门 → 条 96px/网格 cell/1152 预取全部排队
  /// 饿死（「甩动全残留同一张缩略图」「返回网格全占位几秒」的真机根因，
  /// 连续两轮回归）。等待在 ServicePolicy.run 之前（等待者不占门槽）；
  /// 锁按 ref.id 认主，同图重复请求直通；等待中 completer 死亡即让出。
  static String? _activeHdDecodeOwner;

  Future<ui.Image> _run4096Exclusive(Future<ui.Image> Function() job) async {
    while (_activeHdDecodeOwner != null && _activeHdDecodeOwner != _key.ref.id) {
      if (_dead) throw StateError('4096 等待中 completer 已弃置');
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    _activeHdDecodeOwner = _key.ref.id;
    try {
      return await job();
    } finally {
      if (_activeHdDecodeOwner == _key.ref.id) _activeHdDecodeOwner = null;
    }
  }

  @override
  void onDisposed() {
    debugPrint('[PVP] disposed id=${_key.ref.id}');
    _dead = true;
    _heldImage?.dispose();
    _heldImage = null;
    super.onDisposed();
  }
}

/// 构建 viewer 渐进升档 provider（安卓）：1152 显示档就绪后由
/// zoomable_image 换上（最后一次换 provider），2304/4096 由 completer
/// 内部推帧。GIF 不使用（readBytes 多帧已是无损原图）。
ImageProvider buildProgressiveViewerProvider(
  ImageRef ref, {
  required int baseTargetWidth,
  int priority = RequestPriority.viewerImage,
}) {
  return _AndroidProgressiveImageProvider(
    ref: ref,
    baseTargetWidth: baseTargetWidth,
    priority: priority,
  );
}

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
