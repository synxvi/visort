// [ente 移植] 全局指针跨界检测 —— 原文件：ente .../ui/common/touch_cross_detector.dart
//
// Flutter 只把 drag 事件派发给按下的那个 widget；本组件用全局指针路由
// （pointerRouter.addGlobalRoute，路由后原始事件、绕过手势竞技场）把每个
// 指针事件广播给所有已挂载的 RenderTouchCrossDetector，各自做
// size.contains(globalToLocal(position)) 几何判定 → onEnter/onExit/onHover。
// 这是滑动多选的命中基石：与 GestureDetector（点击/长按）、列表滚动天然
// 共存，零竞技场冲突；每指针独立跟踪，多指不串。

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 指针进出子树边界的检测器（RenderProxyBox，零 widget 开销）。
///
/// 按下时在子树内回报 [onPointerDown] + [onEnter]；滑入 [onEnter]、滑出
/// [onExit]、停留 [onHover]；在子树内抬起/取消回报 [onExit]。
class TouchCrossDetector extends SingleChildRenderObjectWidget {
  const TouchCrossDetector({
    super.key,
    this.onEnter,
    this.onExit,
    this.onHover,
    this.onPointerDown,
    required Widget super.child,
  });

  final void Function(PointerEnterEvent)? onEnter;
  final void Function(PointerExitEvent)? onExit;
  final void Function(PointerHoverEvent)? onHover;
  final void Function(PointerDownEvent)? onPointerDown;

  static bool isPointerActive(int pointer) {
    return _TouchCrossRenderTracker.instance.isPointerActive(pointer);
  }

  @override
  RenderTouchCrossDetector createRenderObject(BuildContext context) {
    return RenderTouchCrossDetector(
      onEnter: onEnter,
      onExit: onExit,
      onHover: onHover,
      onPointerDown: onPointerDown,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderTouchCrossDetector renderObject,
  ) {
    renderObject
      ..onEnter = onEnter
      ..onExit = onExit
      ..onHover = onHover
      ..onPointerDown = onPointerDown;
  }
}

class RenderTouchCrossDetector extends RenderProxyBox {
  RenderTouchCrossDetector({
    void Function(PointerEnterEvent)? onEnter,
    void Function(PointerExitEvent)? onExit,
    void Function(PointerHoverEvent)? onHover,
    void Function(PointerDownEvent)? onPointerDown,
    RenderBox? child,
  }) : _onEnter = onEnter,
       _onExit = onExit,
       _onHover = onHover,
       _onPointerDown = onPointerDown,
       super(child);

  void Function(PointerEnterEvent)? _onEnter;
  set onEnter(void Function(PointerEnterEvent)? value) {
    if (_onEnter != value) {
      _onEnter = value;
    }
  }

  void Function(PointerExitEvent)? _onExit;
  set onExit(void Function(PointerExitEvent)? value) {
    if (_onExit != value) {
      _onExit = value;
    }
  }

  void Function(PointerHoverEvent)? _onHover;
  set onHover(void Function(PointerHoverEvent)? value) {
    if (_onHover != value) {
      _onHover = value;
    }
  }

  void Function(PointerDownEvent)? _onPointerDown;
  set onPointerDown(void Function(PointerDownEvent)? value) {
    if (_onPointerDown != value) {
      _onPointerDown = value;
    }
  }

  final Set<int> _activePointers = <int>{};

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _TouchCrossRenderTracker.instance.register(this);
  }

  @override
  void detach() {
    _TouchCrossRenderTracker.instance.unregister(this);
    super.detach();
  }

  void handlePointerDown(PointerDownEvent event) {
    if (!attached) return;
    final bool isInside = size.contains(globalToLocal(event.position));
    if (isInside) {
      _activePointers.add(event.pointer);
      _onPointerDown?.call(event);
      _onEnter?.call(
        PointerEnterEvent(
          position: event.position,
          timeStamp: event.timeStamp,
          pointer: event.pointer,
        ),
      );
    }
  }

  void handlePointerUpdate(PointerEvent event) {
    if (!attached) return;
    final bool isInside = size.contains(globalToLocal(event.position));
    final bool wasInside = _activePointers.contains(event.pointer);
    if (isInside && !wasInside) {
      _activePointers.add(event.pointer);
      _onEnter?.call(
        PointerEnterEvent(
          position: event.position,
          timeStamp: event.timeStamp,
          pointer: event.pointer,
        ),
      );
    } else if (!isInside && wasInside) {
      _activePointers.remove(event.pointer);
      _onExit?.call(
        PointerExitEvent(
          position: event.position,
          timeStamp: event.timeStamp,
          pointer: event.pointer,
        ),
      );
    } else if (isInside && wasInside) {
      _onHover?.call(
        PointerHoverEvent(
          position: event.position,
          timeStamp: event.timeStamp,
          pointer: event.pointer,
        ),
      );
    }
  }

  void handlePointerUp(PointerUpEvent event) {
    if (_activePointers.contains(event.pointer)) {
      _activePointers.remove(event.pointer);
      _onExit?.call(
        PointerExitEvent(
          position: event.position,
          timeStamp: event.timeStamp,
          pointer: event.pointer,
        ),
      );
    }
  }

  void handlePointerCancel(PointerCancelEvent event) {
    if (_activePointers.contains(event.pointer)) {
      _activePointers.remove(event.pointer);
      _onExit?.call(
        PointerExitEvent(
          position: event.position,
          timeStamp: event.timeStamp,
          pointer: event.pointer,
        ),
      );
    }
  }
}

class _TouchCrossRenderTracker {
  _TouchCrossRenderTracker._() {
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
  }
  static final _TouchCrossRenderTracker instance = _TouchCrossRenderTracker._();
  final Set<RenderTouchCrossDetector> _trackedRenderObjects =
      <RenderTouchCrossDetector>{};
  final Set<int> _activePointers = <int>{};

  bool isPointerActive(int pointer) => _activePointers.contains(pointer);
  void register(RenderTouchCrossDetector renderObject) {
    _trackedRenderObjects.add(renderObject);
  }

  void unregister(RenderTouchCrossDetector renderObject) {
    _trackedRenderObjects.remove(renderObject);
  }

  void _handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _activePointers.add(event.pointer);
      for (final renderObject in _trackedRenderObjects) {
        renderObject.handlePointerDown(event);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _activePointers.remove(event.pointer);
      for (final renderObject in _trackedRenderObjects) {
        if (event is PointerUpEvent) {
          renderObject.handlePointerUp(event);
        } else if (event is PointerCancelEvent) {
          renderObject.handlePointerCancel(event);
        }
      }
    } else if (event is PointerMoveEvent &&
        _activePointers.contains(event.pointer)) {
      for (final renderObject in _trackedRenderObjects) {
        renderObject.handlePointerUpdate(event);
      }
    }
  }
}
