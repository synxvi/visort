// [ente 移植] 滑动多选手势层 —— 原文件：ente .../ui/viewer/gallery/swipe_selection_wrapper.dart
//
// 裸 Listener（不参与手势竞技场）包整个网格，负责：
//   - 激活判定：长按选中首个后拖动（任意方向超 4px）即激活；已有选中时
//     轻扫须首次显著移动为水平（dx>dy）且当前仍水平才激活——竖直移动留给
//     列表滚动。激活标志（swipeActiveNotifier）由 Gallery 消费切换
//     NeverScrollableScrollPhysics（拖选期间禁滚动）。
//   - 自动滚动：指针越过上边界（PinnedGroupHeader 上报）或下边界（视口底
//     ——visort 批量栏是 bottomNavigationBar 垫高 body，视口底即批量栏顶，
//     无需像 ente 那样由悬浮操作栏上报）时按穿透深度加速滚动；滚动不产生
//     指针移动，每累计 10px 合成一个 PointerMoveEvent 注回手势系统，让新
//     滚入的 tile 被命中、选择延伸。
//
// 适配 visort：删除 logging（assert 级问题静默降级即可）；边界 null 兜底
// （上→0 / 下→wrapper 自身 viewport 底 / controller→构造传入）。

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'gallery_boundaries_provider.dart';
import 'gallery_swipe_helper.dart';
import 'selected_files.dart';
import 'swipe_to_select_helper.dart';

class SwipeSelectionWrapper extends StatefulWidget {
  final Widget child;
  final SwipeToSelectHelper? swipeHelper;
  final SelectedFiles? selectedFiles;
  final bool isEnabled;
  final ValueNotifier<bool> swipeActiveNotifier;
  final ScrollController scrollController;

  const SwipeSelectionWrapper({
    super.key,
    required this.child,
    required this.swipeHelper,
    required this.selectedFiles,
    required this.isEnabled,
    required this.swipeActiveNotifier,
    required this.scrollController,
  });

  @override
  State<SwipeSelectionWrapper> createState() => _SwipeSelectionWrapperState();
}

class _SwipeSelectionWrapperState extends State<SwipeSelectionWrapper>
    with TickerProviderStateMixin {
  bool? _initialMovementWasHorizontal;

  Ticker? _autoScrollTicker;
  double _currentPointerY = 0;
  double _currentPointerX = 0;
  int? _activePointer;
  double? _cachedScreenHeight;
  double _accumulatedScrollDelta = 0;

  int? _currentScrollDirection;
  double _currentScrollSpeed = 0;
  ScrollController? _activeScrollController;
  Duration _lastElapsed = Duration.zero;

  late double _maxScrollSpeed;

  static const double _syntheticEventThreshold = 10.0;
  static const double _minAvailableSpace = 30.0;
  static const double _baselineRefreshRate = 120.0;
  static const double _baselineMaxScrollSpeed = 12.0; // px/frame at 120 Hz
  static const double _speedExponent = 1.20;
  static const double _movementThreshold = 4.0;

  @override
  void initState() {
    super.initState();
    _initializeFrameRateConstants();
  }

  void _initializeFrameRateConstants() {
    _maxScrollSpeed = _baselineMaxScrollSpeed * _baselineRefreshRate;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newHeight = MediaQuery.of(context).size.height;
    if (_cachedScreenHeight != newHeight) {
      _cachedScreenHeight = newHeight;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isEnabled) {
      return widget.child;
    }

    return GallerySwipeHelper(
      helper: widget.swipeHelper,
      swipeActiveNotifier: widget.swipeActiveNotifier,
      child: Listener(
        onPointerDown: (event) {
          _currentPointerX = event.position.dx;
          _currentPointerY = event.position.dy;
          _activePointer = event.pointer;
          _initialMovementWasHorizontal = null;
        },
        onPointerMove: (event) {
          _currentPointerX = event.position.dx;
          _currentPointerY = event.position.dy;
          _activePointer = event.pointer;
          // 路径 A（长按锚定）：tile 长按回调已 startSelection 锚定会话
          //（isActive），拖选尚未激活 → 任意方向超阈值即激活。不看选择集
          // 数量——勾选态内重新长按拖选时 files 可能多张（首张被取消后
          // 重选、或已有批量选中再长按追加）。
          if (widget.swipeHelper != null &&
              widget.swipeHelper!.isActive &&
              !widget.swipeActiveNotifier.value) {
            final dx = event.delta.dx.abs();
            final dy = event.delta.dy.abs();
            if (dx > _movementThreshold || dy > _movementThreshold) {
              debugPrint('[SWIPE] activated pathA(长按锚定)');
              widget.swipeActiveNotifier.value = true;
            }
          }
          // 路径 B：已有选中（勾选态内轻扫）→ 仅水平起手才激活，竖直留给滚动。
          else if (!widget.swipeActiveNotifier.value &&
              widget.selectedFiles != null &&
              widget.selectedFiles!.files.isNotEmpty) {
            final dx = event.delta.dx.abs();
            final dy = event.delta.dy.abs();

            if (_initialMovementWasHorizontal == null &&
                (dx > _movementThreshold || dy > _movementThreshold)) {
              _initialMovementWasHorizontal = dx > dy;
            }

            if (_initialMovementWasHorizontal == true && dx > dy && dx > 0.1) {
              debugPrint('[SWIPE] activated pathB(水平轻扫)');
              widget.swipeActiveNotifier.value = true;
            }
          }

          if (widget.swipeActiveNotifier.value) {
            _checkAndHandleAutoScroll();
          }
        },
        onPointerUp: (_) {
          _stopAutoScroll();
          widget.swipeHelper?.endSelection();
          widget.swipeActiveNotifier.value = false;
          _initialMovementWasHorizontal = null;
          _activePointer = null;
        },
        onPointerCancel: (_) {
          _stopAutoScroll();
          widget.swipeHelper?.endSelection();
          widget.swipeActiveNotifier.value = false;
          _initialMovementWasHorizontal = null;
          _activePointer = null;
        },
        child: widget.child,
      ),
    );
  }

  double _calculateScrollSpeed(
    double distanceFromBoundary,
    double boundaryPosition,
    bool scrollingUp,
  ) {
    if (distanceFromBoundary <= 0) return 0;

    final screenHeight =
        _cachedScreenHeight ?? MediaQuery.of(context).size.height;

    final widgetHeight = scrollingUp
        ? boundaryPosition
        : (screenHeight - boundaryPosition);

    final safeWidgetHeight = math.max(
      _minAvailableSpace,
      math.min(150.0, widgetHeight),
    );

    final penetration = math.min(
      1.0,
      distanceFromBoundary / safeWidgetHeight,
    );

    final speed = _maxScrollSpeed * math.pow(penetration, _speedExponent);

    return speed;
  }

  void _checkAndHandleAutoScroll() {
    final provider = GalleryBoundariesProvider.of(context);
    final scrollController =
        provider?.scrollControllerNotifier.value ?? widget.scrollController;
    if (!scrollController.hasClients) return;

    // 上边界：PinnedGroupHeader 上报（无 pinned 头的沉浸网格为 null → 0，
    // 即视口顶）；下边界：visort 批量栏由 Scaffold 垫高 body，视口底即
    // 批量栏顶——ente 的悬浮操作栏上报在这里不可得，用 wrapper 自身
    // viewport 底兜底（provider 值优先，为未来悬浮栏留口）。
    final topBoundary = provider?.topBoundaryNotifier.value ?? 0.0;
    final bottomBoundary =
        provider?.bottomBoundaryNotifier.value ?? _viewportBottom();

    if (topBoundary >= bottomBoundary) {
      _stopAutoScroll();
      return;
    }

    if (_currentPointerY < topBoundary) {
      final distance = topBoundary - _currentPointerY;
      _startAutoScroll(scrollController, -1, distance, topBoundary, true);
    } else if (_currentPointerY > bottomBoundary) {
      final distance = _currentPointerY - bottomBoundary;
      _startAutoScroll(scrollController, 1, distance, bottomBoundary, false);
    } else {
      _stopAutoScroll();
    }
  }

  /// wrapper 自身 RenderBox 的底边全局 y（= 网格视口底；布局完成后可用）。
  double _viewportBottom() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(Offset.zero).dy + box.size.height;
    }
    return _cachedScreenHeight ?? MediaQuery.of(context).size.height;
  }

  void _startAutoScroll(
    ScrollController controller,
    int direction,
    double distance,
    double boundaryPosition,
    bool scrollingUp,
  ) {
    final scrollSpeed = _calculateScrollSpeed(
      distance,
      boundaryPosition,
      scrollingUp,
    );

    if (_autoScrollTicker != null &&
        _currentScrollDirection == direction &&
        _activeScrollController == controller) {
      _currentScrollSpeed = scrollSpeed;
      return;
    }

    _stopAutoScroll();
    _currentScrollDirection = direction;
    _currentScrollSpeed = scrollSpeed;
    _activeScrollController = controller;
    _lastElapsed = Duration.zero;

    _autoScrollTicker = createTicker((elapsed) {
      if (!mounted || !controller.hasClients) {
        _stopAutoScroll();
        return;
      }

      final deltaTime = elapsed - _lastElapsed;
      _lastElapsed = elapsed;

      final deltaSeconds = deltaTime.inMicroseconds / 1000000.0;

      final scrollDelta =
          _currentScrollSpeed * _currentScrollDirection! * deltaSeconds;

      final currentOffset = controller.offset;
      final newOffset = currentOffset + scrollDelta;

      final clampedOffset = newOffset.clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );

      if (clampedOffset != currentOffset) {
        final actualScrollDelta = (clampedOffset - currentOffset).abs();
        controller.jumpTo(clampedOffset);

        _accumulatedScrollDelta += actualScrollDelta;

        // 滚动不移动指针 → 合成 move 事件注回手势系统，让新滚入的 tile
        // 被 TouchCrossDetector 命中、选择延伸。
        if (_accumulatedScrollDelta >= _syntheticEventThreshold &&
            widget.swipeActiveNotifier.value &&
            _activePointer != null) {
          final syntheticEvent = PointerMoveEvent(
            position: Offset(_currentPointerX, _currentPointerY),
            pointer: _activePointer!,
            timeStamp: elapsed,
          );
          GestureBinding.instance.handlePointerEvent(syntheticEvent);
          _accumulatedScrollDelta = 0;
        }
      }
    });

    _autoScrollTicker!.start();
  }

  void _stopAutoScroll() {
    _autoScrollTicker?.dispose();
    _autoScrollTicker = null;
    _accumulatedScrollDelta = 0;
    _currentScrollDirection = null;
    _currentScrollSpeed = 0;
    _activeScrollController = null;
    _lastElapsed = Duration.zero;
  }

  @override
  void dispose() {
    _stopAutoScroll();
    super.dispose();
  }
}
