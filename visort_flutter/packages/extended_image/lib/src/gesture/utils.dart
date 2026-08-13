import 'dart:math';
import 'package:extended_image/src/typedef.dart';
import 'package:flutter/material.dart';
import '../utils.dart';
import 'slide_page.dart';

///
///  extended_image_gesture_utils.dart
///  create by zmtzawqlp on 2019/4/3
///

///gesture

class Boundary {
  Boundary({
    this.left = false,
    this.right = false,
    this.top = false,
    this.bottom = false,
  });

  bool left;
  bool right;
  bool bottom;
  bool top;

  @override
  String toString() {
    return 'left:$left,right:$right,top:$top,bottom:$bottom';
  }

  @override
  int get hashCode => Object.hash(left, right, top, bottom);

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is Boundary &&
        left == other.left &&
        right == other.right &&
        top == other.top &&
        bottom == other.bottom;
  }
}

//enum InPageView {
//  ///image is not in pageview
//  none,
//
//  ///image is in horizontal pageview
//  horizontal,
//
//  ///image is in vertical pageview
//  vertical
//}

class GestureDetails {
  GestureDetails({
    this.offset,
    this.totalScale,
    GestureDetails? gestureDetails,
    this.actionType = ActionType.pan,
    this.userOffset = true,
    this.initialAlignment,
    this.slidePageOffset,
    this.rawDestinationRect,
  }) {
    if (gestureDetails != null) {
      _computeVerticalBoundary = gestureDetails._computeVerticalBoundary;
      _computeHorizontalBoundary = gestureDetails._computeHorizontalBoundary;
      _center = gestureDetails._center;
      layoutRect = gestureDetails.layoutRect;
      destinationRect = gestureDetails.destinationRect;

      ///zoom end will call twice
      /// zoom end
      /// zoom start
      /// zoom update
      /// zoom end
    }
  }

  ///scale center delta
  Offset? offset;

  ///total scale of image
  final double? totalScale;

  final ActionType actionType;

  bool _computeVerticalBoundary = false;
  bool get computeVerticalBoundary => _computeVerticalBoundary;

  bool _computeHorizontalBoundary = false;
  bool get computeHorizontalBoundary => _computeHorizontalBoundary;

  Boundary _boundary = Boundary();
  Boundary get boundary => _boundary;

  //true: user zoom/pan
  //false: animation
  final bool userOffset;

  //pre
  Offset? _center;

  Rect? layoutRect;
  Rect? destinationRect;

  ///from
  Rect? rawDestinationRect;

  final InitialAlignment? initialAlignment;

  ///slide page offset
  Offset? slidePageOffset;

  @override
  int get hashCode => Object.hash(
    offset,
    totalScale,
    computeVerticalBoundary,
    computeHorizontalBoundary,
    boundary,
    actionType,
    userOffset,
    layoutRect,
    destinationRect,
    _center,
    slidePageOffset,
  );

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }

    return other is GestureDetails &&
        offset == other.offset &&
        totalScale == other.totalScale &&
        computeVerticalBoundary == other.computeVerticalBoundary &&
        computeHorizontalBoundary == other.computeHorizontalBoundary &&
        boundary == other.boundary &&
        actionType == other.actionType &&
        userOffset == other.userOffset &&
        layoutRect == other.layoutRect &&
        destinationRect == other.destinationRect &&
        _center == other._center &&
        slidePageOffset == other.slidePageOffset;
  }

  Offset? _getCenter(Rect destinationRect) {
    if (!userOffset && _center != null) {
      return _center;
    }
    //var offset = editAction.paintOffset(this.offset);
    if (totalScale! > 1.0) {
      // [visort patch] 仅当 boundary flag 全为 false(即双击动画帧——app 侧
      // photo_viewer 的 tick 故意不传 prev gestureDetails)时双轴应用 offset。
      // 原实现在 flag 全 false 时 return destinationRect.center,会丢弃 offset,
      // 导致双击锚点(尤其 letterbox 轴/垂直锚点)失效。
      // 用 flag 而非 actionType 区分:双指捏合也是 ActionType.zoom,但其 flag 由
      // prev 复制(通常 true),必须走下方原库分轴+clamp 逻辑,否则捏合 offset 双轴
      // 无约束 → 图像被拖出视口/映射到空白、多次捏合乱跳。
      if (!_computeHorizontalBoundary && !_computeVerticalBoundary) {
        return destinationRect.center * totalScale! + offset!;
      }
      if (_computeHorizontalBoundary && _computeVerticalBoundary) {
        return destinationRect.center * totalScale! + offset!;
      } else if (_computeHorizontalBoundary) {
        //only scale Horizontal
        return Offset(
              destinationRect.center.dx * totalScale!,
              destinationRect.center.dy,
            ) +
            Offset(offset!.dx, 0.0);
      } else if (_computeVerticalBoundary) {
        //only scale Vertical
        return Offset(
              destinationRect.center.dx,
              destinationRect.center.dy * totalScale!,
            ) +
            Offset(0.0, offset!.dy);
      } else {
        return destinationRect.center;
      }
    } else {
      return destinationRect.center;
    }
  }

  Offset _getFixedOffset(Rect destinationRect, Offset center) {
    if (totalScale! > 1.0) {
      // [visort patch] 与 _getCenter 配套:仅 flag 全 false(双击动画帧)时双轴
      // 写回 offset(恒等保持,因 center = Dc·s + offset)。原 else 分支返回
      // center - destinationRect.center 会把 offset 改写成 Dc·(s-1)+offset 破坏
      // 双击终态。双指捏合(flag true)走下方原库分轴写回。
      if (!_computeHorizontalBoundary && !_computeVerticalBoundary) {
        return center - destinationRect.center * totalScale!;
      }
      if (_computeHorizontalBoundary && _computeVerticalBoundary) {
        return center - destinationRect.center * totalScale!;
      } else if (_computeHorizontalBoundary) {
        //only scale Horizontal
        return center -
            Offset(
              destinationRect.center.dx * totalScale!,
              destinationRect.center.dy,
            );
      } else if (_computeVerticalBoundary) {
        //only scale Vertical
        return center -
            Offset(
              destinationRect.center.dx,
              destinationRect.center.dy * totalScale!,
            );
      } else {
        return center - destinationRect.center;
      }
    } else {
      return center - destinationRect.center;
    }
  }

  Rect _getDestinationRect(Rect destinationRect, Offset center) {
    final double width = destinationRect.width * totalScale!;
    final double height = destinationRect.height * totalScale!;
    return Rect.fromLTWH(
      center.dx - width / 2.0,
      center.dy - height / 2.0,
      width,
      height,
    );
  }

  Rect calculateFinalDestinationRect(Rect layoutRect, Rect destinationRect) {
    final bool destinationRectChanged = rawDestinationRect != destinationRect;

    rawDestinationRect = destinationRect;

    final Offset? temp = offset;
    // [visort patch] 记住进入时的 boundary flag:双击动画帧(app 侧 tick 不传 prev
    // → flag 全 false)。第一次 _innerCalculate 会按铺满情况重算 flag(可能变 true),
    // 若第二次沿用,会走原库分轴 _getCenter——在垂直铺满临界点(h·s==layoutH)
    // fv 翻转时丢弃 off.y → rect.y 跳变,表现为「放大快结束时往下掉/往上弹」。
    // 方形图 dest 短,临界 s≈layoutH/destH≈2.25 < target 2.5 → 必跨临界 → 必触发;
    // 扁图 dest 更扁,临界 s≈4.0 > target 2.5 → 全程不翻转 → 不触发。双指捏合帧
    // flag 非 false,不进此分支,保留原库 clamp 行为。
    final bool initNoBoundary =
        !_computeHorizontalBoundary && !_computeVerticalBoundary;
    _innerCalculateFinalDestinationRect(layoutRect, destinationRect);
    offset = temp;
    if (initNoBoundary) {
      _computeHorizontalBoundary = false;
      _computeVerticalBoundary = false;
    }
    Rect result = _innerCalculateFinalDestinationRect(
      layoutRect,
      destinationRect,
    );

    ///first call,initial image rect with alignment
    if (totalScale! > 1.0 &&
        destinationRectChanged &&
        initialAlignment != null) {
      offset = _getFixedOffset(
        destinationRect,
        result.center + _getCenterDif(result, layoutRect, initialAlignment),
      );
      result = _innerCalculateFinalDestinationRect(layoutRect, destinationRect);
      //initialAlignment = null;
    }
    this.destinationRect = result;
    this.layoutRect = layoutRect;
    return result;
  }

  Offset _getCenterDif(Rect result, Rect layout, InitialAlignment? alignment) {
    switch (alignment) {
      case InitialAlignment.topLeft:
        return layout.topLeft - result.topLeft;
      case InitialAlignment.topCenter:
        return layout.topCenter - result.topCenter;
      case InitialAlignment.topRight:
        return layout.topRight - result.topRight;
      case InitialAlignment.centerLeft:
        return layout.centerLeft - result.centerLeft;
      case InitialAlignment.center:
        return layout.center - result.center;
      case InitialAlignment.centerRight:
        return layout.centerRight - result.centerRight;
      case InitialAlignment.bottomLeft:
        return layout.bottomLeft - result.bottomLeft;
      case InitialAlignment.bottomCenter:
        return layout.bottomCenter - result.bottomCenter;
      case InitialAlignment.bottomRight:
        return layout.bottomRight - result.bottomRight;
      default:
        return Offset.zero;
    }
  }

  Rect _innerCalculateFinalDestinationRect(
    Rect layoutRect,
    Rect destinationRect,
  ) {
    _boundary = Boundary();
    final Offset center = _getCenter(destinationRect)!;
    Rect result = _getDestinationRect(destinationRect, center);

    if (_computeHorizontalBoundary) {
      //move right
      if (result.left.greaterThanOrEqualTo(layoutRect.left)) {
        result = Rect.fromLTWH(
          layoutRect.left,
          result.top,
          result.width,
          result.height,
        );
        _boundary.left = true;
      }

      ///move left
      if (result.right.lessThanOrEqualTo(layoutRect.right)) {
        result = Rect.fromLTWH(
          layoutRect.right - result.width,
          result.top,
          result.width,
          result.height,
        );
        _boundary.right = true;
      }
    }

    if (_computeVerticalBoundary) {
      //move down
      if (result.bottom.lessThanOrEqualTo(layoutRect.bottom)) {
        result = Rect.fromLTWH(
          result.left,
          layoutRect.bottom - result.height,
          result.width,
          result.height,
        );
        _boundary.bottom = true;
      }

      //move up
      if (result.top.greaterThanOrEqualTo(layoutRect.top)) {
        result = Rect.fromLTWH(
          result.left,
          layoutRect.top,
          result.width,
          result.height,
        );
        _boundary.top = true;
      }
    }

    _computeHorizontalBoundary =
        result.left.lessThanOrEqualTo(layoutRect.left) &&
        result.right.greaterThanOrEqualTo(layoutRect.right);

    _computeVerticalBoundary =
        result.top.lessThanOrEqualTo(layoutRect.top) &&
        result.bottom.greaterThanOrEqualTo(layoutRect.bottom);

    ///fix offset
    ///fix offset when it's not slide page
    //if (!isSliding)

    offset = _getFixedOffset(destinationRect, result.center);
    _center = result.center;

    return result;
  }

  bool movePage(Offset delta, Axis axis) {
    if (totalScale! <= 1.0) {
      // [visort patch] 未放大时单指水平/垂直滑动也转交 pageview 翻页。
      // 原本 return false:ExtendedImage 的 scale recognizer 赢手势竞技场时,
      // handleScaleUpdate 的 movePage 判定 false → 手势被吞 → 间歇性翻页失败。
      switch (axis) {
        case Axis.horizontal:
          return delta.dx != 0 && delta.dx.abs() > delta.dy.abs();
        case Axis.vertical:
          return delta.dy != 0 && delta.dy.abs() > delta.dx.abs();
      }
    }
    switch (axis) {
      case Axis.horizontal:
        return delta.dx != 0 &&
            delta.dx.abs() > delta.dy.abs() &&
            ((delta.dx < 0 && boundary.right) ||
                (delta.dx > 0 && boundary.left) ||
                !_computeHorizontalBoundary);

      case Axis.vertical:
        return delta.dy != 0 &&
            delta.dy.abs() > delta.dx.abs() &&
            ((delta.dy < 0 && boundary.bottom) ||
                (delta.dy > 0 && boundary.top) ||
                !_computeVerticalBoundary);
    }
  }

  GestureDetails copy() {
    return GestureDetails(
      offset: offset,
      totalScale: totalScale,
      gestureDetails: this,
      actionType: actionType,
      userOffset: userOffset,
      initialAlignment: initialAlignment,
      slidePageOffset: slidePageOffset,
      rawDestinationRect: rawDestinationRect,
    ).._boundary = _boundary;
  }
}

/// init image rect with alignment when initialScale > 1.0
/// see https://github.com/fluttercandies/extended_image/issues/66
enum InitialAlignment {
  /// The top left corner.
  topLeft,

  /// The center point along the top edge.
  topCenter,

  /// The top right corner.
  topRight,

  /// The center point along the left edge.
  centerLeft,

  /// The center point, both horizontally and vertically.
  center,

  /// The center point along the right edge.
  centerRight,

  /// The bottom left corner.
  bottomLeft,

  /// The center point along the bottom edge.
  bottomCenter,

  /// The bottom right corner.
  bottomRight,
}

class GestureConfig {
  GestureConfig({
    this.minScale = 0.8,
    this.maxScale = 5.0,
    this.speed = 1.0,
    this.cacheGesture = false,
    this.inertialSpeed = 100.0,
    this.initialScale = 1.0,
    this.inPageView = false,
    double? animationMinScale,
    double? animationMaxScale,
    this.initialAlignment = InitialAlignment.center,
    this.gestureDetailsIsChanged,
    this.hitTestBehavior = HitTestBehavior.deferToChild,
    this.reverseMousePointerScrollDirection = false,
  }) : assert(minScale <= maxScale),
       animationMinScale = animationMinScale ??= minScale * 0.8,
       animationMaxScale = animationMaxScale ??= maxScale * 1.2,
       assert(animationMinScale <= animationMaxScale),
       assert(animationMinScale <= minScale),
       assert(animationMaxScale >= maxScale),
       assert(minScale <= initialScale && initialScale <= maxScale),
       assert(speed > 0),
       assert(inertialSpeed > 0);

  /// How to behave during hit tests.
  final HitTestBehavior hitTestBehavior;

  /// Call when GestureDetails is changed
  final GestureDetailsIsChanged? gestureDetailsIsChanged;

  /// The min scale for zooming then animation back to minScale when scale end
  final double animationMinScale;

  // Min scale
  final double minScale;

  /// The max scale for zooming then animation back to maxScale when scale end
  final double animationMaxScale;

  /// Max scale
  final double maxScale;

  /// Speed for zoom/pan
  final double speed;

  /// Save Gesture state (for example in page view, so that the state will not change when scroll back),
  /// Remember clearGestureDetailsCache  at right time
  final bool cacheGesture;

  /// Whether in page view
  final bool inPageView;

  /// final double magnitude = details.velocity.pixelsPerSecond.distance;
  /// final Offset direction = details.velocity.pixelsPerSecond / magnitude * _gestureConfig.inertialSpeed;
  final double inertialSpeed;

  /// Initial scale of image
  final double initialScale;

  /// Init image rect with alignment when initialScale > 1.0
  /// see https://github.com/fluttercandies/extended_image/issues/66
  final InitialAlignment initialAlignment;

  /// reverse mouse pointer scroll deirection
  /// false: zoom int => down, zoom out => up
  /// true: zoom int => up, zoom out => down
  /// default is false
  final bool reverseMousePointerScrollDirection;
}

double roundAfter(double number, int position) {
  final double shift = pow(10, position).toDouble();
  return (number * shift).roundToDouble() / shift;
}

enum ActionType {
  /// zoom in/ zoom out
  zoom,

  /// horizontal and vertical move
  pan,

  /// flip,rotate
  edit,
}

const double minMagnitude = 400.0;
const double velocity = minMagnitude / 1000.0;
const double minGesturePageDelta = 5.0;

class GestureAnimation {
  GestureAnimation(
    TickerProvider vsync, {
    GestureOffsetAnimationCallBack? offsetCallBack,
    GestureScaleAnimationCallBack? scaleCallBack,
  }) {
    if (offsetCallBack != null) {
      _offsetController = AnimationController(vsync: vsync);
      _offsetController!.addListener(() {
        //print(_animation.value);
        offsetCallBack(_offsetAnimation.value);
      });
    }

    if (scaleCallBack != null) {
      _scaleController = AnimationController(vsync: vsync);
      _scaleController!.addListener(() {
        scaleCallBack(_scaleAnimation.value);
      });
    }
  }

  AnimationController? _offsetController;
  late Animation<Offset> _offsetAnimation;

  AnimationController? _scaleController;
  late Animation<double> _scaleAnimation;

  void animationOffset(Offset? begin, Offset end) {
    if (_offsetController == null) {
      return;
    }
    _offsetAnimation = _offsetController!.drive(
      Tween<Offset>(begin: begin, end: end),
    );
    _offsetController!
      ..value = 0.0
      ..fling(velocity: velocity);
  }

  void animationScale(double? begin, double end, double velocity) {
    if (_scaleController == null) {
      return;
    }
    _scaleAnimation = _scaleController!.drive(
      Tween<double>(begin: begin, end: end),
    );
    _scaleController!
      ..value = 0.0
      ..fling(velocity: velocity);
  }

  void dispose() {
    _offsetController?.dispose();
    _offsetController = null;

    _scaleController?.dispose();
    _scaleController = null;
  }

  void stop() {
    _offsetController?.stop();
    _scaleController?.stop();
  }
}

///ExtendedImageGesturePage

Color defaultSlidePageBackgroundHandler({
  Offset offset = Offset.zero,
  Size pageSize = const Size(100, 100),
  required Color color,
  SlideAxis pageGestureAxis = SlideAxis.both,
}) {
  double opacity = 0.0;
  if (pageGestureAxis == SlideAxis.both) {
    opacity =
        offset.distance /
        (Offset(pageSize.width, pageSize.height).distance / 2.0);
  } else if (pageGestureAxis == SlideAxis.horizontal) {
    opacity = offset.dx.abs() / (pageSize.width / 2.0);
  } else if (pageGestureAxis == SlideAxis.vertical) {
    opacity = offset.dy.abs() / (pageSize.height / 2.0);
  }
  return color.withValues(alpha: min(1.0, max(1.0 - opacity, 0.0)));
}

bool defaultSlideEndHandler({
  Offset offset = Offset.zero,
  Size pageSize = const Size(100, 100),
  SlideAxis pageGestureAxis = SlideAxis.both,
}) {
  const int parameter = 6;
  if (pageGestureAxis == SlideAxis.both) {
    return offset.distance.greaterThan(
      Offset(pageSize.width, pageSize.height).distance / parameter,
    );
  } else if (pageGestureAxis == SlideAxis.horizontal) {
    return offset.dx.abs().greaterThan(pageSize.width / parameter);
  } else if (pageGestureAxis == SlideAxis.vertical) {
    return offset.dy.abs().greaterThan(pageSize.height / parameter);
  }
  return true;
}

double defaultSlideScaleHandler({
  Offset offset = Offset.zero,
  Size pageSize = const Size(100, 100),
  SlideAxis pageGestureAxis = SlideAxis.both,
}) {
  double scale = 0.0;
  if (pageGestureAxis == SlideAxis.both) {
    scale = offset.distance / Offset(pageSize.width, pageSize.height).distance;
  } else if (pageGestureAxis == SlideAxis.horizontal) {
    scale = offset.dx.abs() / (pageSize.width / 2.0);
  } else if (pageGestureAxis == SlideAxis.vertical) {
    scale = offset.dy.abs() / (pageSize.height / 2.0);
  }
  return max(1.0 - scale, 0.8);
}
