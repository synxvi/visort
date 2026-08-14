import 'package:flutter/widgets.dart';
import 'package:photo_view/photo_view.dart'
    show
        PhotoViewScaleState,
        PhotoViewHeroAttributes,
        PhotoViewImageTapDownCallback,
        PhotoViewImageTapUpCallback,
        PhotoViewImageScaleEndCallback,
        ScaleStateCycle;
import 'package:photo_view/src/controller/photo_view_controller.dart';
import 'package:photo_view/src/controller/photo_view_controller_delegate.dart';
import 'package:photo_view/src/controller/photo_view_scalestate_controller.dart';
import 'package:photo_view/src/core/photo_view_gesture_detector.dart';
import 'package:photo_view/src/core/photo_view_hit_corners.dart';
import 'package:photo_view/src/utils/photo_view_utils.dart';

const _defaultDecoration = const BoxDecoration(
  color: const Color.fromRGBO(0, 0, 0, 1.0),
);

/// Internal widget in which controls all animations lifecycle, core responses
/// to user gestures, updates to  the controller state and mounts the entire PhotoView Layout
class PhotoViewCore extends StatefulWidget {
  const PhotoViewCore({
    Key? key,
    required this.imageProvider,
    required this.backgroundDecoration,
    required this.semanticLabel,
    required this.gaplessPlayback,
    required this.heroAttributes,
    required this.enableRotation,
    required this.onTapUp,
    required this.onTapDown,
    required this.onScaleEnd,
    this.onEdgeX,
    required this.gestureDetectorBehavior,
    required this.controller,
    required this.scaleBoundaries,
    required this.scaleStateCycle,
    required this.scaleStateController,
    required this.basePosition,
    required this.tightMode,
    required this.filterQuality,
    required this.disableGestures,
    required this.enablePanAlways,
    required this.strictScale,
  })  : customChild = null,
        super(key: key);

  const PhotoViewCore.customChild({
    Key? key,
    required this.customChild,
    required this.backgroundDecoration,
    this.heroAttributes,
    required this.enableRotation,
    this.onTapUp,
    this.onTapDown,
    this.onScaleEnd,
    this.onEdgeX,
    this.gestureDetectorBehavior,
    required this.controller,
    required this.scaleBoundaries,
    required this.scaleStateCycle,
    required this.scaleStateController,
    required this.basePosition,
    required this.tightMode,
    required this.filterQuality,
    required this.disableGestures,
    required this.enablePanAlways,
    required this.strictScale,
  })  : imageProvider = null,
        semanticLabel = null,
        gaplessPlayback = false,
        super(key: key);

  final Decoration? backgroundDecoration;
  final ImageProvider? imageProvider;
  final String? semanticLabel;
  final bool? gaplessPlayback;
  final PhotoViewHeroAttributes? heroAttributes;
  final bool enableRotation;
  final Widget? customChild;

  final PhotoViewControllerBase controller;
  final PhotoViewScaleStateController scaleStateController;
  final ScaleBoundaries scaleBoundaries;
  final ScaleStateCycle scaleStateCycle;
  final Alignment basePosition;

  final PhotoViewImageTapUpCallback? onTapUp;
  final PhotoViewImageTapDownCallback? onTapDown;
  final PhotoViewImageScaleEndCallback? onScaleEnd;

  /// [visort fork] X 边缘溢出回调（+1 右拖溢出→上一张，-1 左拖溢出→下一张）。
  final ValueChanged<int>? onEdgeX;

  final HitTestBehavior? gestureDetectorBehavior;
  final bool tightMode;
  final bool disableGestures;
  final bool enablePanAlways;
  final bool strictScale;

  final FilterQuality filterQuality;

  @override
  State<StatefulWidget> createState() {
    return PhotoViewCoreState();
  }

  bool get hasCustomChild => customChild != null;
}

class PhotoViewCoreState extends State<PhotoViewCore>
    with
        TickerProviderStateMixin,
        PhotoViewControllerDelegate,
        HitCornersDetector {
  Offset? _normalizedPosition;
  double? _scaleBefore;
  double? _rotationBefore;

  late final AnimationController _scaleAnimationController;
  Animation<double>? _scaleAnimation;

  late final AnimationController _positionAnimationController;
  Animation<Offset>? _positionAnimation;

  late final AnimationController _rotationAnimationController =
      AnimationController(vsync: this)..addListener(handleRotationAnimation);
  Animation<double>? _rotationAnimation;

  PhotoViewHeroAttributes? get heroAttributes => widget.heroAttributes;

  /// [visort fork] 精准双击：scale 与 position 同步插值的专用动画
  /// （300ms decelerate，主分支算法）。
  late final AnimationController _doubleTapController;
  Tween<double>? _doubleTapScaleTween;
  Tween<Offset>? _doubleTapPositionTween;

  late ScaleBoundaries cachedScaleBoundaries = widget.scaleBoundaries;
  void handleScaleAnimation() {
    scale = _scaleAnimation!.value;
  }

  void handlePositionAnimate() {
    controller.position = _positionAnimation!.value;
  }

  void handleRotationAnimation() {
    controller.rotation = _rotationAnimation!.value;
  }

  void onScaleStart(ScaleStartDetails details) {
    _rotationBefore = controller.rotation;
    _scaleBefore = scale;
    _normalizedPosition = details.focalPoint - controller.position;
    _scaleAnimationController.stop();
    _positionAnimationController.stop();
    _rotationAnimationController.stop();
    _doubleTapController.stop();
  }

  void onScaleUpdate(ScaleUpdateDetails details) {
    final double newScale = _scaleBefore! * details.scale;
    final Offset delta = details.focalPoint - _normalizedPosition!;

    if (widget.strictScale &&
        (newScale > widget.scaleBoundaries.maxScale ||
            newScale < widget.scaleBoundaries.minScale)) {
      return;
    }

    updateScaleStateFromNewScale(newScale);

    final Offset targetPosition = delta * details.scale;
    final Offset clampedPosition = widget.enablePanAlways
        ? targetPosition
        : clampPosition(position: targetPosition);
    // [visort fork] X 边缘溢出翻页：放大态且无缩放变化(纯平移)时，图片在
    // X 边界继续拖动（目标 position 超出 clamp 边界）→ 回调外层翻页。
    // 旧版 arena 裁决无法实现"手势中途到边释放"（Scale recognizer accept 后
    // 垄断事件流，PageView 的 drag recognizer 已被 reject）。
    // 容差条件：|scale-1|<0.01（双指微动不算缩放）+ scaleState≠initial
    // （放大态判定，photo_view scale 是绝对像素比不能用 newScale>1.0）+
    // 溢出 >0.5px（浮点噪声不算）。
    final edgeCb = widget.onEdgeX;
    if (edgeCb != null &&
        (details.scale - 1.0).abs() < 0.01 &&
        scaleStateController.scaleState != PhotoViewScaleState.initial &&
        (targetPosition.dx - clampedPosition.dx).abs() > 0.5) {
      edgeCb(targetPosition.dx > clampedPosition.dx ? 1 : -1);
    }

    updateMultiple(
      scale: newScale,
      position: clampedPosition,
      rotation:
          widget.enableRotation ? _rotationBefore! + details.rotation : null,
      rotationFocusPoint: widget.enableRotation ? details.focalPoint : null,
    );
  }

  void onScaleEnd(ScaleEndDetails details) {
    final double _scale = scale;
    final Offset _position = controller.position;
    final double maxScale = scaleBoundaries.maxScale;
    final double minScale = scaleBoundaries.minScale;

    widget.onScaleEnd?.call(context, details, controller.value);

    //animate back to maxScale if gesture exceeded the maxScale specified
    if (_scale > maxScale) {
      final double scaleComebackRatio = maxScale / _scale;
      animateScale(_scale, maxScale);
      final Offset clampedPosition = clampPosition(
        position: _position * scaleComebackRatio,
        scale: maxScale,
      );
      animatePosition(_position, clampedPosition);
      return;
    }

    //animate back to minScale if gesture fell smaller than the minScale specified
    if (_scale < minScale) {
      final double scaleComebackRatio = minScale / _scale;
      animateScale(_scale, minScale);
      animatePosition(
        _position,
        clampPosition(
          position: _position * scaleComebackRatio,
          scale: minScale,
        ),
      );
      return;
    }
    // get magnitude from gesture velocity
    final double magnitude = details.velocity.pixelsPerSecond.distance;

    // animate velocity only if there is no scale change and a significant magnitude
    if (_scaleBefore! / _scale == 1.0 && magnitude >= 400.0) {
      final Offset direction = details.velocity.pixelsPerSecond / magnitude;
      animatePosition(
        _position,
        clampPosition(position: _position + direction * 100.0),
      );
    }
  }

  /// [visort fork] 精准双击缩放（主分支 extended_image 算法移植）：
  /// - 2 段循环：未放大 → 放大；已放大 → 缩回 initial。
  /// - 目标倍率 = initialScale × max(2.5, cover)：cover 铺满视口消除黑边。
  /// - 锚点：双击落点的像素钉在屏幕原位（点击角落 → 角落滑到屏幕边缘后
  ///   铺满无黑边），endPos 由"该像素屏幕位置不变"反解 + clampPosition
  ///   铺满 clamp（图像 ≥ 视口的轴贴边）。
  /// - 动画：300ms decelerate，scale 与 position 同一进度线性插值
  ///   （屏幕像素轨迹随进度线性滑动，无整幅跳变/飞出）。
  ///
  /// 坐标系（useImageScale=true，filterQuality≠none）：
  /// child 视觉中心 = 视口中心 + position，视觉尺寸 = childSize×scale；
  /// 屏幕像素位置 = c + p + (q - C/2)·s（c=视口中心，q=子图像素）。
  void onDoubleTap() {
    final tap = _doubleTapDownPosition;
    final box = context.findRenderObject();
    if (tap == null || box is! RenderBox || !box.hasSize) {
      nextScaleState();
      return;
    }
    _doubleTapDownPosition = null;

    final double begin = scale;
    final double initial = scaleBoundaries.initialScale;
    final bool zooming = begin <= initial * 1.01;
    final double target = zooming ? _doubleTapTargetScale() : initial;
    final Offset endPos = zooming
        ? clampPosition(
            position: _doubleTapEndPosition(tap, box.size, begin, target),
            scale: target,
          )
        : Offset.zero;

    // 放大分支：立即上报 zoomedIn（动画帧走 setScaleInvisibly，不触发
    // _blindScaleListener；外层 shouldDisableScroll/isZoomedNotifier 依赖
    // stream 通知禁翻页+进沉浸模式，不能等动画结束）。
    // setInvisibly 不触发 _blindScaleStateListener（ignorable）→ 无二次动画。
    if (zooming) {
      scaleStateController.setInvisibly(PhotoViewScaleState.zoomedIn);
    }
    _doubleTapScaleTween = Tween<double>(begin: begin, end: target);
    _doubleTapPositionTween = Tween<Offset>(
      begin: controller.position,
      end: endPos,
    );
    _doubleTapController
      ..stop()
      ..value = 0.0
      ..animateTo(
        1.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.decelerate,
      );
  }

  /// 双击落点（onDoubleTapDown 记录，core 局部坐标）。
  Offset? _doubleTapDownPosition;

  /// 目标倍率：max(2.5, cover)（cover = 铺满视口，与主分支
  /// _computeDoubleTapTarget 的 coverRatio=max(layout/dest) 一致）。
  double _doubleTapTargetScale() {
    final Size child = scaleBoundaries.childSize;
    final Size view = scaleBoundaries.outerSize;
    // cover = 铺满视口的绝对 scale；与 initial×2.5 取大
    // （主分支：relative target = max(2.5, coverRatio=cover/initial)）。
    final double cover = view.width / child.width > view.height / child.height
        ? view.width / child.width
        : view.height / child.height;
    final double zoomed = scaleBoundaries.initialScale * 2.5;
    return cover > zoomed ? cover : zoomed;
  }

  /// 锚点终态偏移：tap 像素屏幕位置保持不变。
  /// q = (tap - c - p0)/begin → p' = tap - c - q·target
  /// （等价主分支 tapLocal·(1−s) 锚点公式在 photo_view 坐标系的推导）。
  Offset _doubleTapEndPosition(
    Offset tap,
    Size viewSize,
    double begin,
    double target,
  ) {
    final Offset c = Offset(viewSize.width / 2, viewSize.height / 2);
    if (begin <= 0) return Offset.zero;
    final Offset q = (tap - c - controller.position) / begin;
    return tap - c - q * target;
  }

  void _handleDoubleTapTick() {
    final Animation<double> t = _doubleTapController.view;
    scale = _doubleTapScaleTween!.evaluate(t);
    controller.position = _doubleTapPositionTween!.evaluate(t);
  }

  void _onDoubleTapStatus(AnimationStatus status) {
    // 缩回动画结束：scale==initialScale 时状态归 initial（否则 _blindScaleListener
    // 报 zoomedOut → 外层 shouldDisableScroll/isZoomed 残留 true）。
    if (status == AnimationStatus.completed && scale == scaleBoundaries.initialScale) {
      scaleStateController.setInvisibly(PhotoViewScaleState.initial);
    }
  }


  void animateScale(double from, double to) {
    _scaleAnimation = Tween<double>(
      begin: from,
      end: to,
    ).animate(_scaleAnimationController);
    _scaleAnimationController
      ..value = 0.0
      ..fling(velocity: 0.4);
  }

  void animatePosition(Offset from, Offset to) {
    _positionAnimation = Tween<Offset>(begin: from, end: to)
        .animate(_positionAnimationController);
    _positionAnimationController
      ..value = 0.0
      ..fling(velocity: 0.4);
  }

  void animateRotation(double from, double to) {
    _rotationAnimation = Tween<double>(begin: from, end: to)
        .animate(_rotationAnimationController);
    _rotationAnimationController
      ..value = 0.0
      ..fling(velocity: 0.4);
  }

  void onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      onAnimationStatusCompleted();
    }
  }

  /// Check if scale is equal to initial after scale animation update
  void onAnimationStatusCompleted() {
    if (scaleStateController.scaleState != PhotoViewScaleState.initial &&
        scale == scaleBoundaries.initialScale) {
      scaleStateController.setInvisibly(PhotoViewScaleState.initial);
    }
  }

  @override
  void initState() {
    super.initState();
    initDelegate();
    addAnimateOnScaleStateUpdate(animateOnScaleStateUpdate);

    cachedScaleBoundaries = widget.scaleBoundaries;

    _scaleAnimationController = AnimationController(vsync: this)
      ..addListener(handleScaleAnimation)
      ..addStatusListener(onAnimationStatus);
    _positionAnimationController = AnimationController(vsync: this)
      ..addListener(handlePositionAnimate);
    _doubleTapController = AnimationController(vsync: this)
      ..addListener(_handleDoubleTapTick)
      ..addStatusListener(_onDoubleTapStatus);
  }

  void animateOnScaleStateUpdate(double prevScale, double nextScale) {
    animateScale(prevScale, nextScale);
    animatePosition(controller.position, Offset.zero);
    animateRotation(controller.rotation, 0.0);
  }

  @override
  void dispose() {
    _scaleAnimationController.removeStatusListener(onAnimationStatus);
    _scaleAnimationController.dispose();
    _positionAnimationController.dispose();
    _rotationAnimationController.dispose();
    _doubleTapController.dispose();
    super.dispose();
  }

  void onTapUp(TapUpDetails details) {
    widget.onTapUp?.call(context, details, controller.value);
  }

  void onTapDown(TapDownDetails details) {
    widget.onTapDown?.call(context, details, controller.value);
  }

  @override
  Widget build(BuildContext context) {
    // Check if we need a recalc on the scale
    if (widget.scaleBoundaries != cachedScaleBoundaries) {
      markNeedsScaleRecalc = true;
      cachedScaleBoundaries = widget.scaleBoundaries;
    }

    return StreamBuilder(
        stream: controller.outputStateStream,
        initialData: controller.prevValue,
        builder: (
          BuildContext context,
          AsyncSnapshot<PhotoViewControllerValue> snapshot,
        ) {
          if (snapshot.hasData) {
            final PhotoViewControllerValue value = snapshot.data!;
            final useImageScale = widget.filterQuality != FilterQuality.none;

            final computedScale = useImageScale ? 1.0 : scale;

            final matrix = Matrix4.identity()
              ..translate(value.position.dx, value.position.dy)
              ..scale(computedScale)
              ..rotateZ(value.rotation);

            final Widget customChildLayout = CustomSingleChildLayout(
              delegate: _CenterWithOriginalSizeDelegate(
                scaleBoundaries.childSize,
                basePosition,
                useImageScale,
              ),
              child: _buildHero(),
            );

            final child = Container(
              constraints: widget.tightMode
                  ? BoxConstraints.tight(scaleBoundaries.childSize * scale)
                  : null,
              child: Center(
                child: Transform(
                  child: customChildLayout,
                  transform: matrix,
                  alignment: basePosition,
                ),
              ),
              decoration: widget.backgroundDecoration ?? _defaultDecoration,
            );

            if (widget.disableGestures) {
              return child;
            }

            return PhotoViewGestureDetector(
              child: child,
              onDoubleTap: onDoubleTap,
              onDoubleTapDown: (TapDownDetails details) {
                final box = context.findRenderObject();
                _doubleTapDownPosition = box is RenderBox && box.hasSize
                    ? box.globalToLocal(details.globalPosition)
                    : null;
              },
              onScaleStart: onScaleStart,
              onScaleUpdate: onScaleUpdate,
              onScaleEnd: onScaleEnd,
              hitDetector: this,
              onTapUp: widget.onTapUp != null
                  ? (details) => widget.onTapUp!(context, details, value)
                  : null,
              onTapDown: widget.onTapDown != null
                  ? (details) => widget.onTapDown!(context, details, value)
                  : null,
            );
          } else {
            return Container();
          }
        });
  }

  Widget _buildHero() {
    return heroAttributes != null
        ? Hero(
            tag: heroAttributes!.tag,
            createRectTween: heroAttributes!.createRectTween,
            flightShuttleBuilder: heroAttributes!.flightShuttleBuilder,
            placeholderBuilder: heroAttributes!.placeholderBuilder,
            transitionOnUserGestures: heroAttributes!.transitionOnUserGestures,
            child: _buildChild(),
          )
        : _buildChild();
  }

  Widget _buildChild() {
    return widget.hasCustomChild
        ? widget.customChild!
        : Image(
            image: widget.imageProvider!,
            semanticLabel: widget.semanticLabel,
            gaplessPlayback: widget.gaplessPlayback ?? false,
            filterQuality: widget.filterQuality,
            width: scaleBoundaries.childSize.width * scale,
            fit: BoxFit.contain,
          );
  }
}

class _CenterWithOriginalSizeDelegate extends SingleChildLayoutDelegate {
  const _CenterWithOriginalSizeDelegate(
    this.subjectSize,
    this.basePosition,
    this.useImageScale,
  );

  final Size subjectSize;
  final Alignment basePosition;
  final bool useImageScale;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final childWidth = useImageScale ? childSize.width : subjectSize.width;
    final childHeight = useImageScale ? childSize.height : subjectSize.height;

    final halfWidth = (size.width - childWidth) / 2;
    final halfHeight = (size.height - childHeight) / 2;

    final double offsetX = halfWidth * (basePosition.x + 1);
    final double offsetY = halfHeight * (basePosition.y + 1);
    return Offset(offsetX, offsetY);
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return useImageScale
        ? const BoxConstraints()
        : BoxConstraints.tight(subjectSize);
  }

  @override
  bool shouldRelayout(_CenterWithOriginalSizeDelegate oldDelegate) {
    return oldDelegate != this;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _CenterWithOriginalSizeDelegate &&
          runtimeType == other.runtimeType &&
          subjectSize == other.subjectSize &&
          basePosition == other.basePosition &&
          useImageScale == other.useImageScale;

  @override
  int get hashCode =>
      subjectSize.hashCode ^ basePosition.hashCode ^ useImageScale.hashCode;
}
