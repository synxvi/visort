// [ente 移植] 大图缩放组件 —— 基于 ente zoomable_image.dart（photo_view 0.15）
//
// 保留（与 ente 完全一致）：
//   - PhotoView 配置：minScale contained / maxScale covered×3 / strictScale
//   - PhotoViewGestureDetectorScope(axis: vertical) 垂直手势轴裁决
//   - scaleStateChangedCallback：缩放中禁用翻页 + isZoomedNotifier
//   - outputStateStream → zoomTransformNotifier（浮层跟手）
//   - _updatePhotoViewController：缩放中切原图按尺寸比修正防跳变
//   - loadingBuilder 按图片在屏最终尺寸渲染（Hero 动画期占位不跳变）
//   - 垂直拖拽：下滑 >8px → pop（Navigator.maybePop）；上滑 >8px → 详情
//
// 适配 visort：
//   - EnteFile → MsImageInfo；tag = 'photo_${id}'（与网格 cell Hero 配对）
//   - 加载管线：缩略图/原图用 visort buildThumbnailProvider/buildImageProvider
//     （MediaStore 通道，无服务端下载/加密/Rust/EXIF 特判）
//   - 删除：memories/live photo/QR/服务端/DB/事件总线/共享/guest view

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

import '../screens/album_common.dart' show extOf;
import 'detail_page_state.dart';
import 'gallery_groups.dart' show GalleryGroups;

/// ente 常量（core/constants.dart dragSensitivity = 8）：上滑详情/下滑关闭阈值。
const double _kDragSensitivity = 8.0;

class ZoomableImage extends StatefulWidget {
  final MsImageInfo photo;
  final Function(bool)? shouldDisableScroll;
  final String? tagPrefix;
  final Decoration? backgroundDecoration;
  /// 上滑（>8px）→ 详情面板（visort 适配：外层 DetailPage 决定展示）。
  final VoidCallback? onSwipeUp;
  /// [photo_view fork] X 边缘溢出回调：放大后平移到 X 边缘继续拖
  /// （+1 右拖→上一张，-1 左拖→下一张，由外层 DetailPage 翻页）。
  final ValueChanged<int>? onEdgeX;
  /// 下滑（>8px）→ 返回（visort 适配：外层 DetailPage 面板打开时改为收面板）。
  final VoidCallback? onSwipeDown;
  /// 原图（下采样）就绪回调（外层记录 id，退出时 evict 缓存）。
  final ValueChanged<String>? onFullLoaded;

  /// 网格列数：cell 缩略图尺寸与网格 cell 完全一致（ImageCache key 命中，
  /// 飞行层/Hero shuttle 首帧不重新解码）。
  final int gridCols;

  const ZoomableImage(
    this.photo, {
    super.key,
    this.gridCols = 4,
    this.shouldDisableScroll,
    this.tagPrefix,
    this.backgroundDecoration,
    this.onSwipeUp,
    this.onSwipeDown,
    this.onEdgeX,
    this.onFullLoaded,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  ImageProvider? _imageProvider;
  bool _loadedSmallThumbnail = false;
  bool _loadingLargeThumbnail = false;
  bool _loadedLargeThumbnail = false;
  bool _loadingFinalImage = false;
  bool _loadedFinalImage = false;
  bool _showingThumbnailFallback = false;
  bool _firedOnReady = false;
  ValueChanged<PhotoViewScaleState>? _scaleStateChangedCallback;
  bool _isZooming = false;
  PhotoViewController _photoViewController = PhotoViewController();
  final _scaleStateController = PhotoViewScaleStateController();
  StreamSubscription<dynamic>? _zoomStreamSubscription;

  /// 切原图防跳变的基准：photo_view scale 是绝对像素比，
  /// 换 provider 时按 preview/final 尺寸比修正。
  double? _initialScale;

  MsImageInfo get _photo => widget.photo;
  ImageRef get _ref =>
      imageRefFromMediaStoreId(_photo.id, extension: extOf(_photo.name));

  @override
  void initState() {
    super.initState();
    // 无条件设 cell 同款缩略图 provider → PhotoView（含 Hero）首帧必存在，
    // push 飞行层才能启动（否则 imageProvider 未就绪时 build 的是 loading，
    // 无 Hero → flight 不启动 → 黑屏后加载，真机复现）。
    // ImageCache 命中（网格刚显示过 cell）立即有图；miss 时 loadingBuilder
    // 显示占位，大图渐进。
    _imageProvider = buildThumbnailProvider(_ref, size: _cellThumbSize());
    _loadedSmallThumbnail = true;
    _notifyReadyOnce();
    _scaleStateChangedCallback = (value) {
      if (widget.shouldDisableScroll != null) {
        widget.shouldDisableScroll!(value != PhotoViewScaleState.initial);
      }
      _isZooming = value != PhotoViewScaleState.initial;
      final state = InheritedDetailPageState.maybeOf(context);
      state?.isZoomedNotifier.value = _isZooming;
      if (!_isZooming) {
        _initialScale = _photoViewController.scale ?? _initialScale;
        state?.zoomTransformNotifier.value = ZoomTransform.identity;
      }
    };
    // 新页初始上报（scaleStateChangedCallback 只在状态变化时触发，新页
    // initial 不回调 → 上一页放大标志跨页残留 = 翻页失灵/沉浸模式不退出）。
    // postFrame 覆盖所有翻页路径（filmstrip 跳转/删除补位/边缘翻页）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.shouldDisableScroll?.call(false);
      InheritedDetailPageState.maybeOf(context)?.isZoomedNotifier.value = false;
    });
    _subscribeToZoomStream();
  }

  void _subscribeToZoomStream() {
    _zoomStreamSubscription = _photoViewController.outputStateStream.listen((
      value,
    ) {
      if (!mounted) return;
      final state = InheritedDetailPageState.maybeOf(context);
      if (value.scale == null) return;
      if (!_isZooming) {
        _initialScale = value.scale;
        state?.zoomTransformNotifier.value = ZoomTransform.identity;
        return;
      }
      _initialScale ??= value.scale;
      state?.zoomTransformNotifier.value = ZoomTransform(
        scale: value.scale! / _initialScale!,
        offset: value.position,
      );
    });
  }

  @override
  void dispose() {
    _zoomStreamSubscription?.cancel();
    _photoViewController.dispose();
    _scaleStateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _loadLocalImage(context);
    Widget content;

    if (_imageProvider != null) {
      content = PhotoViewGestureDetectorScope(
        axis: Axis.vertical,
        child: PhotoView(
          // 切原图时 key 变化强制重建 PhotoView，让调整后的 zoom 生效
          //（ente 同款；gaplessPlayback 让同尺寸替换不闪底层）。
          key: ValueKey(_loadedFinalImage),
          imageProvider: _imageProvider,
          controller: _photoViewController,
          filterQuality: FilterQuality.high,
          scaleStateController: _scaleStateController,
          scaleStateChangedCallback: _scaleStateChangedCallback,
          minScale: PhotoViewComputedScale.contained,
          onEdgeX: widget.onEdgeX,
          gaplessPlayback: true,
          heroAttributes: PhotoViewHeroAttributes(
            tag: 'photo_${_photo.id}',
            transitionOnUserGestures: true,
          ),
          backgroundDecoration:
              (widget.backgroundDecoration as BoxDecoration?) ??
              const BoxDecoration(color: Colors.black),
          loadingBuilder: (context, event) {
            // 与 Hero 动画期图片在屏尺寸一致：loading 层按 contain 尺寸渲染，
            // 避免飞行中占位尺寸跳变（ente 同款公式）。
            final screenDimensions = MediaQuery.sizeOf(context);
            final screenWidth = screenDimensions.width;
            final screenHeight = screenDimensions.height;
            final aspectRatioOfScreen = screenWidth / screenHeight;
            final aspectRatioOfImage = _photo.width / _photo.height;
            final double screenRelativeImageWidth;
            final double screenRelativeImageHeight;
            if (aspectRatioOfImage > aspectRatioOfScreen) {
              screenRelativeImageWidth = screenWidth;
              screenRelativeImageHeight = screenWidth / aspectRatioOfImage;
            } else if (aspectRatioOfImage < aspectRatioOfScreen) {
              screenRelativeImageHeight = screenHeight;
              screenRelativeImageWidth = screenHeight * aspectRatioOfImage;
            } else {
              screenRelativeImageWidth = screenWidth;
              screenRelativeImageHeight = screenHeight;
            }
            return Center(
              child: SizedBox(
                width: screenRelativeImageWidth,
                height: screenRelativeImageHeight,
                child: const _DelayedLoadingIndicator(),
              ),
            );
          },
        ),
      );
    } else if (_showingThumbnailFallback) {
      content = Center(
        child: Image(
          image: buildThumbnailProvider(_ref, size: 512),
          fit: BoxFit.contain,
        ),
      );
    } else {
      content = const Center(child: _DelayedLoadingIndicator());
    }

    // 垂直手势（ente 原版）：缩放中禁用；下滑关闭、上滑详情。阈值 8px。
    final GestureDragUpdateCallback? verticalDragCallback = _isZooming
        ? null
        : (d) {
            if (!_isZooming) {
              if (d.delta.dy > _kDragSensitivity) {
                if (widget.onSwipeDown != null) {
                  widget.onSwipeDown!();
                } else {
                  unawaited(Navigator.maybePop(context));
                }
              } else if (d.delta.dy < (_kDragSensitivity * -1)) {
                widget.onSwipeUp?.call();
              }
            }
          };
    return GestureDetector(
      onVerticalDragUpdate: verticalDragCallback,
      child: content,
    );
  }

  void _notifyReadyOnce() {
    if (_firedOnReady) return;
    _firedOnReady = true;
    scheduleMicrotask(() {
      if (!mounted) return;
      widget.onFullLoaded?.call(_photo.id);
    });
  }

  /// 三级加载（ente 同款顺序）：
  /// 1) cell 同款缩略图（cache 命中首帧）→ 2) 大缩略图(512) → 3) 下采样原图。
  void _loadLocalImage(BuildContext context) {
    if (!_loadedSmallThumbnail &&
        !_loadedLargeThumbnail &&
        !_loadedFinalImage) {
      final cellThumb = buildThumbnailProvider(_ref, size: _cellThumbSize());
      if (PaintingBinding.instance.imageCache.containsKey(cellThumb)) {
        _imageProvider = cellThumb;
        _loadedSmallThumbnail = true;
        _notifyReadyOnce();
      }
    }
    if (!_loadingLargeThumbnail &&
        !_loadedLargeThumbnail &&
        !_loadedFinalImage) {
      _loadingLargeThumbnail = true;
      final large = buildThumbnailProvider(_ref, size: 512);
      precacheImage(large, context).then((_) {
        if (mounted && !_loadedFinalImage) {
          setState(() {
            _imageProvider = large;
            _loadedLargeThumbnail = true;
          });
          _notifyReadyOnce();
        }
      }).catchError((_) {
        _loadingLargeThumbnail = false;
      });
    }
    if (!_loadingFinalImage && !_loadedFinalImage) {
      _loadingFinalImage = true;
      final full = buildImageProvider(
        _ref,
        targetWidth: computeViewerTargetWidth(
          MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context),
        ),
      );
      precacheImage(full, context).then((_) {
        if (mounted && !_loadedFinalImage) {
          _updateViewWithFinalImage(full);
        }
      }).catchError((Object e) {
        _loadingFinalImage = false;
        if (mounted) {
          // 原图解码失败（损坏/超时）：回退大缩略图显示，不崩不黑屏。
          setState(() => _showingThumbnailFallback = true);
          _notifyReadyOnce();
        }
      });
    }
  }

  Future<void> _updateViewWithFinalImage(ImageProvider imageProvider) async {
    await _updatePhotoViewController(
      previewImageProvider: _imageProvider,
      finalImageProvider: imageProvider,
    );
    if (!mounted) return;
    setState(() {
      _imageProvider = imageProvider;
      _loadedFinalImage = true;
    });
    _notifyReadyOnce();
    widget.onFullLoaded?.call(_photo.id);
  }

  /// 缩放中切原图的位置修正（ente 原版）：
  /// photo_view 的 scale 是绝对像素比，preview→final 尺寸比变化时按
  /// previousScale / (finalW/prevW) 修正，避免切换瞬间跳变。
  Future<void> _updatePhotoViewController({
    required ImageProvider? previewImageProvider,
    required ImageProvider finalImageProvider,
  }) async {
    final bool shouldFixPosition =
        previewImageProvider != null &&
        _isZooming &&
        _photoViewController.scale != null;
    if (!shouldFixPosition) return;
    final prevImageInfo = await _resolveImageInfo(previewImageProvider);
    final finalImageInfo = await _resolveImageInfo(finalImageProvider);
    final previousScale = _photoViewController.scale!;
    final previousRelativeScale = _initialScale != null && _initialScale! > 0
        ? previousScale / _initialScale!
        : null;
    final scale =
        previousScale / (finalImageInfo.image.width / prevImageInfo.image.width);
    final currentPosition = _photoViewController.value.position;
    unawaited(_zoomStreamSubscription?.cancel());
    _photoViewController = PhotoViewController(
      initialPosition: currentPosition,
      initialScale: scale,
    );
    if (previousRelativeScale != null &&
        previousRelativeScale.isFinite &&
        previousRelativeScale > 0) {
      _initialScale = scale / previousRelativeScale;
    } else {
      _initialScale = null;
    }
    _subscribeToZoomStream();
    // 防止原图就绪后自动缩放（双击状态保持）。
    _scaleStateController.scaleState = PhotoViewScaleState.zoomedIn;
  }

  /// 解析 ImageProvider 首帧拿尺寸（ente 用 Flutter getImageInfo 顶层函数，
  /// 3.44 已移除，改用 resolve + listener 等价实现）。
  Future<ImageInfo> _resolveImageInfo(ImageProvider provider) {
    final stream = provider.resolve(ImageConfiguration.empty);
    final completer = Completer<ImageInfo>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info);
        stream.removeListener(listener);
      },
      onError: (Object e, StackTrace? s) {
        if (!completer.isCompleted) completer.completeError(e, s ?? StackTrace.empty);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// 与相册网格 cell 完全一致的缩略图尺寸（cell 宽 × dpr，clamp 160~512）。
  /// ImageCache key = provider+size —— 与 cell 同款才能命中已加载缩略图，
  /// 避免飞行层/Hero shuttle 首帧重新解码。
  int _cellThumbSize() {
    final mq = MediaQuery.of(context);
    final cols = widget.gridCols;
    // 与 album_screen 网格一致：4×2 padding + (cols-1)*2 间距（ente Gallery）。
    final cellW = (mq.size.width - 8 - (cols - 1) * GalleryGroups.spacing) / cols;
    return (cellW * mq.devicePixelRatio).round().clamp(160, 512);
  }
}

/// 延迟 spinner：prefetch 的图在页间切换时不闪 loading（ente 同款）。
class _DelayedLoadingIndicator extends StatefulWidget {
  const _DelayedLoadingIndicator();

  @override
  State<_DelayedLoadingIndicator> createState() =>
      _DelayedLoadingIndicatorState();
}

class _DelayedLoadingIndicatorState extends State<_DelayedLoadingIndicator> {
  static const Duration _delay = Duration(milliseconds: 400);
  Timer? _timer;
  bool _showSpinner = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _showSpinner = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSpinner) return const SizedBox.expand();
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
      ),
    );
  }
}
