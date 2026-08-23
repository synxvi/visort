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
import 'package:photo_view/src/core/photo_view_core.dart'
    show PhotoViewCoreState;
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

  /// 页索引（顶层双击路由注册键；null 时不参与顶层分发）。
  final int? pageIndex;
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
    this.pageIndex,
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
  /// PhotoViewCore 全局键：顶层双击 → doubleTapZoom 入口。
  final GlobalKey<PhotoViewCoreState> _coreKey =
      GlobalKey<PhotoViewCoreState>();
  InheritedDetailPageState? _inherited;

  /// 加载代际：换图（didUpdateWidget）时自增；旧图 precache 回调按代际
  /// 丢弃，防止删除补位后旧图 large/final 迟到覆盖新图 provider。
  int _loadGeneration = 0;
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

  @override
  void didUpdateWidget(covariant ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.id == widget.photo.id) return;
    // 删除补位：PageView 同 index 复用本 state 但 photo 已换——必须整体
    // 重置三级加载链与缩放，否则沿用旧 provider = 主图停留被删那张。
    // 起始 provider 按 ImageCache 分级取最高可用级：补位图（原下一张）
    // 通常已完成三级加载（原图在 cache）→ 直接原图，同帧显示、无
    // "缩略图回退再渐进"闪烁；未命中则退 512/cell，观感同首次渐进。
    _loadGeneration++;
    // 复位三级链状态（复用 State 上残留旧图的 provider/加载 flag 会阻塞
    // _loadLocalImage 对缺失级别的重启加载；miss 时旧 provider 还会继续
    // 显示被删那张图）。_pickCachedProvider 按 cache 重新分级。
    _imageProvider = null;
    _loadedSmallThumbnail = false;
    _loadedLargeThumbnail = false;
    _loadedFinalImage = false;
    _loadingLargeThumbnail = false;
    _loadingFinalImage = false;
    _pickCachedProvider(allowCellThumb: false);
    _showingThumbnailFallback = false;
    _firedOnReady = false;
    _initialScale = null;
    _photoViewController.reset();
    _scaleStateController.reset();
    // 补位换图：_isZooming 是本 State 字段，控制器 reset 不会经
    // scaleStateChangedCallback 带回回调（setInvisibly/reset 均不通知）——
    // 被删图若处于放大态，残留 true 会锁 PageView 翻页（shouldDisableScroll）
    // 并禁用上下滑手势。与 initState postFrame 的初始上报对齐，同步复位。
    if (_isZooming) {
      _isZooming = false;
      widget.shouldDisableScroll?.call(false);
      final state = _inherited;
      state?.isZoomedNotifier.value = false;
      state?.zoomTransformNotifier.value = ZoomTransform.identity;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 无条件设 cell 同款缩略图 provider → PhotoView（含 Hero）首帧必存在，
    // push 飞行层才能启动（否则 imageProvider 未就绪时 build 的是 loading，
    // 无 Hero → flight 不启动 → 黑屏后加载，真机复现）。
    // ImageCache 命中（网格刚显示过 cell）立即有图；miss 时 loadingBuilder
    // 显示占位，大图渐进。
    // 注意：_cellThumbSize 依赖 MediaQuery——initState 里调用会触发
    // dependOnInheritedWidgetOfExactType assert（红屏）；didChangeDependencies
    // 在 initState 之后、首帧 build 之前执行，Hero 首帧不受影响。
    if (_imageProvider == null) {
      _pickCachedProvider();
      _notifyReadyOnce();
    }
    _inherited = InheritedDetailPageState.maybeOf(context);
    final idx = widget.pageIndex;
    if (idx != null) {
      _inherited?.doubleTapHandlers[idx] = _handleTopDoubleTap;
    }
  }

  /// 初始 provider 按 ImageCache 分级取最高可用级（原图 > 512 > cell）。
  /// 删除补位/翻页切到已加载过的图时，若从 cell 缩略图起步再升级原图，
  /// 会有一帧"糊图→清晰图"跳变闪烁；cache 命中直接同帧显示最高级。
  /// didChangeDependencies（新 element）与 didUpdateWidget（复用 element）
  /// 共用。
  ///
  /// ⚠️ 必须判「已完成」（statusProvider().completed）而非 containsKey：
  /// _openViewer 在 push 前发起原图 precache，push 时 cache 里已有 full 的
  /// 【pending】条目——containsKey 误判为可用 → 起始 provider 指向解码中
  /// 的原图 → photo_view wrapper 的 _loading 分支【没有 Hero】（heroAttributes
  /// 挂在 PhotoViewCore 上）→ HeroController 首帧找不到目标端 Hero →
  /// flight 不启动，第一次打开只剩路由 200ms 淡入（无飞行动画的根因）。
  /// 只有「已完成」条目 resolve 才同步回调（synchronousCall）→ 首帧
  /// _loading=false → Hero 在树。pending 一律不选，回落 cell（正在网格
  /// 显示中 = live 条目，必已完成）。
  void _pickCachedProvider({bool allowCellThumb = true}) {
    final full = buildImageProvider(
      _ref,
      targetWidth: computeViewerTargetWidth(
        MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context),
      ),
    );
    // large 用【等比】请求框（squareCrop:false）：childSize 宽高比与原图
    // 一致 → 补位/慢图过渡期 contain 视觉与原图完全相同（仅清晰度差），
    // 原图到货后无大小跳变。方形版（centerCrop 裁切 + 方形 childSize）会让
    // 过渡期横图视野变小/竖图裁切放大，宽高比交替的序列（竖→横→竖连续
    // 删除）频繁可见（真机实证）。
    final large = buildThumbnailProvider(_ref, size: 512, squareCrop: false);
    final cell = buildThumbnailProvider(_ref, size: _cellThumbSize(), squareCrop: true);
    bool completed(ImageProvider p) => _probeSyncComplete(p);
    if (completed(full)) {
      _imageProvider = full;
      _loadedFinalImage = true;
      _loadedSmallThumbnail = true;
      _loadedLargeThumbnail = true;
    } else if (completed(large)) {
      _imageProvider = large;
      _loadedLargeThumbnail = true;
      _loadedSmallThumbnail = true;
    } else if (allowCellThumb) {
      // cell 兜底：网格正在显示 = live 条目（已完成），首帧同步有图；
      // 极端场景（占位图都未出就点开）loading 一帧、无 flight，可接受。
      _imageProvider = cell;
      _loadedSmallThumbnail = true;
    }
    // 补位路径（allowCellThumb=false）full/large 均未就绪时不落方形 cell：
    // 保持 null 走 loadingBuilder（按 _photo 宽高比显示占位框，无裁切
    // 变形），large 很快到货（翻页预加载已发起）替换——方形裁剪图的
    // childSize 会造成过渡期大小跳变。
    _loadingLargeThumbnail = false;
    // 保持 false：让 _loadLocalImage 正常启动缺失级别的加载（若置 true
    // 会阻塞对应分支的 precache，又没有实际加载在跑 → 缩略图永不清晰）。
    _loadingFinalImage = false;
  }

  /// 探测 provider 在 ImageCache 中是否已有【已完成】的解码条目。
  ///
  /// ImageCache 无公开的 pending/completed 状态查询（statusProvider 非公开
  /// API），利用机制本身判定：已完成 completer 的 addListener 会【同步】
  /// 回调（synchronousCall=true）；pending 条目（如 _openViewer push 前
  /// precache 刚发起的原图）不会同步回调 → false。探测 listener 无论同步/
  /// 异步/出错触发都立即摘除，不留悬挂监听（挂着的 listener 会阻止
  /// completer 释放）。
  bool _probeSyncComplete(ImageProvider provider) {
    final stream = provider.resolve(const ImageConfiguration());
    final completer = stream.completer;
    if (completer == null) return false;
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
    return syncDone;
  }

  /// 顶层双击（global）→ core 局部坐标 → 精准缩放。
  void _handleTopDoubleTap(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    _coreKey.currentState?.doubleTapZoom(box.globalToLocal(globalPosition));
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
    final idx = widget.pageIndex;
    if (idx != null) {
      _inherited?.doubleTapHandlers.remove(idx);
    }
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
          // 双击由 detail_page 顶层捕获分发（ballistic 中 ignorePointer
          // 屏蔽页内 tap）→ core 内不注册双击手势，防双重触发。
          enableDoubleTap: false,
          coreKey: _coreKey,
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
          // 等比（同 large key），错误兜底显示也不裁切变形。
          image: buildThumbnailProvider(_ref, size: 512, squareCrop: false),
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
      final cellThumb = buildThumbnailProvider(_ref, size: _cellThumbSize(), squareCrop: true);
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
      final gen = _loadGeneration;
      // 等比 512（与 _pickCachedProvider 的 large 同 key，翻页预加载即补位
      // 缓存命中）：过渡期 childSize 宽高比与原图一致，无大小跳变。
      final large = buildThumbnailProvider(_ref, size: 512, squareCrop: false);
      precacheImage(large, context)
          .then((_) {
            if (!mounted || gen != _loadGeneration) return;
            if (!_loadedFinalImage) {
              setState(() {
                _imageProvider = large;
                _loadedLargeThumbnail = true;
              });
              _notifyReadyOnce();
            }
          })
          .catchError((_) {
            if (gen == _loadGeneration) _loadingLargeThumbnail = false;
          });
    }
    if (!_loadingFinalImage && !_loadedFinalImage) {
      _loadingFinalImage = true;
      final gen = _loadGeneration;
      final full = buildImageProvider(
        _ref,
        targetWidth: computeViewerTargetWidth(
          MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context),
        ),
      );
      precacheImage(full, context)
          .then((_) {
            if (!mounted || gen != _loadGeneration) return;
            if (!_loadedFinalImage) {
              _updateViewWithFinalImage(full);
            }
          })
          .catchError((Object e) {
            if (gen != _loadGeneration) return;
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
    // 仅【真放大态】（用户主动 zoomedIn）才做 ente 式尺寸修正保持视角；
    // 其余态静默把 scaleState 归位 initial（setInvisibly 无通知、零副作用）。
    //
    // 归位原因：起始 provider 是方形裁剪缩略图（cell/large 均 squareCrop），
    // core 按方形 contain 写回过很大的绝对 scale（竖屏约屏高/300≈8），且
    // _blindScaleListener 把初始 contain 误标 zoomedOut。该残留若带到
    // PhotoView key 重建（ValueKey(_loadedFinalImage)）之后：新 core 的
    // markNeedsScaleRecalc 被 isScaleStateZooming（含 zoomedOut）抑制 →
    // 沿用方形时代绝对 scale × 等比 childSize = 巨图（删除补位、原图未
    // 缓存的下一张真机实证）。归位 initial 让新 core 按 initial 重算
    // contain(等比)。
    // ⚠️ 不可用 _scaleStateController.reset()/控制器 reset()：reset 是普通
    // 通知，会同步触发 _blindScaleStateListener → setScaleInvisibly(旧值)
    // 与 scaleStateChangedCallback 链，首开慢图（precache 未完成、有方形
    // 过渡）实证引入显示放大回归。
    if (_scaleStateController.scaleState == PhotoViewScaleState.zoomedIn) {
      await _updatePhotoViewController(
        previewImageProvider: _imageProvider,
        finalImageProvider: imageProvider,
      );
    } else {
      _scaleStateController.setInvisibly(PhotoViewScaleState.initial);
    }
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
    // 真放大态判据用 zoomedIn 而非 _isZooming：后者被 photo_view 把初始
    // contain 误标的 zoomedOut 污染（zoomedOut≠initial → _isZooming=true），
    // 而本修正公式隐含按宽适配，方形 contain 实为按高适配 → 换算错数倍。
    final bool shouldFixPosition =
        previewImageProvider != null &&
        _scaleStateController.scaleState == PhotoViewScaleState.zoomedIn &&
        _photoViewController.scale != null;
    if (!shouldFixPosition) return;
    final prevImageInfo = await _resolveImageInfo(previewImageProvider);
    final finalImageInfo = await _resolveImageInfo(finalImageProvider);
    final previousScale = _photoViewController.scale!;
    final previousRelativeScale = _initialScale != null && _initialScale! > 0
        ? previousScale / _initialScale!
        : null;
    final scale =
        previousScale /
        (finalImageInfo.image.width / prevImageInfo.image.width);
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
        if (!completer.isCompleted)
          completer.completeError(e, s ?? StackTrace.empty);
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
    final cellW =
        (mq.size.width - 8 - (cols - 1) * GalleryGroups.spacing) / cols;
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
