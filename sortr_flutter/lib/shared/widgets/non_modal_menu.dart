// 非模态浮层菜单 —— 对标一加相册的轻量弹出菜单
//
// 与 showGeneralDialog（模态）的区别：
//   - 不拦截底层手势：主界面 ListView/GridView 可正常滚动
//   - 主界面开始滚动时，菜单自动收回（通过 isScrolling 信号驱动）
//   - 无 barrier（不暗化背景）
//
// 实现：OverlayEntry 插入 rootOverlay，菜单用 Positioned 定位到锚点下方。
//
// 收回动画：close() 不再瞬间 remove，而是触发 _ctrl.reverse()（150ms,
// couiOutEase 快速收），动画结束才移除 entry——展开用弹簧过冲，收回用快速
// 缩放，形成"弹出来 / 收回去"的完整闭环。
//
// ⚠️ ColorOS DynamicFrameRate 可能对 Overlay 自定义动画降帧到 30（见 album_screen:209）。
// 弹簧展开若降帧，回退方案：改简单 fade（fade 在任何帧率下无差别）。
// 实测验证后再决定是否回退。

import 'package:flutter/material.dart';

import '../../core/theme/app_animations.dart';

/// 显示一个非模态浮层菜单。
///
/// [anchorKey] = 触发按钮的 GlobalKey（用于定位）。
/// [menuBuilder] = 菜单内容 widget（不含定位）。
/// [isScrolling] = 主界面滚动信号；变 true 时菜单自动收回。
/// [onDismiss] = 菜单收回后的回调（可选，收回动画结束后触发）。
/// [menuWidth] = 菜单宽度。
/// [offsetX] / [offsetY] = 相对按钮左上角的额外偏移（微调定位）。
///
/// 返回一个 controller，可手动调 close() 收回（带收回动画）。
NonModalMenuController showNonModalMenu({
  required BuildContext context,
  required GlobalKey anchorKey,
  required WidgetBuilder menuBuilder,
  required ValueNotifier<bool> isScrolling,
  required double menuWidth,
  VoidCallback? onDismiss,
  double offsetX = 0,
  double offsetY = 0,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final controller = NonModalMenuController();
  // 收回信号：controller.close() 置 true，body 监听后播 reverse，
  // 完成回调 onClose → controller._dismiss 真正移除（实现收回动画）。
  final closeSignal = ValueNotifier<bool>(false);
  controller._closeSignal = closeSignal;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _NonModalMenuBody(
      anchorKey: anchorKey,
      menuWidth: menuWidth,
      offsetX: offsetX,
      offsetY: offsetY,
      isScrolling: isScrolling,
      closeSignal: closeSignal,
      onClose: () {
        controller._dismiss(entry, onDismiss);
      },
      menuBuilder: menuBuilder,
    ),
  );
  overlay.insert(entry);
  controller._entry = entry;
  return controller;
}

/// 菜单控制器：触发收回动画 + 资源清理。
class NonModalMenuController {
  OverlayEntry? _entry;
  ValueNotifier<bool>? _closeSignal;
  bool _closed = false;

  /// 菜单是否已关闭（展开/收回动画期间为 false；entry 移除后变 true）。
  /// 供触发按钮做 toggle 判断（已展开则再点收回）。
  bool get isClosed => _closed;

  /// 触发收回动画（reverse 150ms），动画结束后真正移除 entry。
  /// 若 body 已被滚动等原因提前收回（_closed=true），直接返回。
  void close() {
    if (_closed) return;
    _closeSignal?.value = true;
  }

  void _dismiss(OverlayEntry entry, VoidCallback? onDismiss) {
    if (_closed) return;
    _closed = true;
    entry.remove();
    _entry = null;
    onDismiss?.call();
  }
}

class _NonModalMenuBody extends StatefulWidget {
  const _NonModalMenuBody({
    required this.anchorKey,
    required this.menuWidth,
    required this.offsetX,
    required this.offsetY,
    required this.isScrolling,
    required this.closeSignal,
    required this.onClose,
    required this.menuBuilder,
  });

  final GlobalKey anchorKey;
  final double menuWidth;
  final double offsetX;
  final double offsetY;
  final ValueNotifier<bool> isScrolling;
  /// controller.close() 触发的收回信号。
  final ValueNotifier<bool> closeSignal;
  final VoidCallback onClose;
  final WidgetBuilder menuBuilder;

  @override
  State<_NonModalMenuBody> createState() => _NonModalMenuBodyState();
}

class _NonModalMenuBodyState extends State<_NonModalMenuBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  // 是否处于收回流程（防止 reverse 完成回调与滚动收回重复触发 onClose）
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
      // 收回用 150ms（比展开弹簧快、利落），curve 由 _scale/_opacity 的
      // reverseCurve 决定（couiOutEase 快速收，不反向播弹簧）。
      reverseDuration: const Duration(milliseconds: 150),
    );
    // 展开：弹簧曲线（一加浮动手环：stiffness 158, dampingRatio 0.6）。
    // 收回：couiOutEase（快速起步、极慢收尾 → "嗖"地收回）。
    _scale = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: _SpringCurve(),
        reverseCurve: AppCurves.couiOutEase,
      ),
    );
    _opacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: AppCurves.couiEase,
        reverseCurve: AppCurves.couiEase,
      ),
    );
    _ctrl.addStatusListener((s) {
      // reverse 播完（value 归 0 → dismissed）→ 真正移除 entry。
      if (s == AnimationStatus.dismissed && _closing) {
        widget.onClose();
      }
    });
    _ctrl.forward();
    // 监听滚动信号：一旦开始滚动，瞬间收回（滚动时优先速度，不走动画）。
    widget.isScrolling.addListener(_onScrollChanged);
    // 监听 controller.close()：播收回动画。
    widget.closeSignal.addListener(_onCloseSignal);
  }

  void _onScrollChanged() {
    if (widget.isScrolling.value && mounted && !_closing) {
      // 滚动收回：直接 onClose 瞬间移除（不等动画，避免菜单滞留滚动中）。
      _closing = true;
      widget.onClose();
    }
  }

  void _onCloseSignal() {
    if (widget.closeSignal.value && !_closing && mounted) {
      _closing = true;
      _ctrl.reverse(); // 收回动画；dismissed 后 statusListener 调 onClose 移除
    }
  }

  @override
  void dispose() {
    widget.isScrolling.removeListener(_onScrollChanged);
    widget.closeSignal.removeListener(_onCloseSignal);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 定位：基于锚点按钮的屏幕坐标
    final btnCtx = widget.anchorKey.currentContext;
    final screen = MediaQuery.sizeOf(context);
    double left = 0, top = 0;
    if (btnCtx != null) {
      final box = btnCtx.findRenderObject() as RenderBox;
      final pos = box.localToGlobal(Offset.zero);
      // 菜单右对齐按钮右缘 -8dp
      left = (pos.dx + box.size.width - widget.menuWidth - 8 + widget.offsetX)
          .clamp(0.0, screen.width - widget.menuWidth);
      // 菜单顶 = 按钮底 + 4dp
      top = pos.dy + box.size.height + 4 + widget.offsetY;
    }

    // 锚点（菜单内坐标）：按钮右下角相对菜单左上角
    final anchorDx = widget.menuWidth + 8; // 菜单右缘到按钮右缘
    final anchorDy = -4.0; // 菜单顶在按钮底+4，故按钮底相对菜单顶是 -4

    return Positioned(
      left: left,
      top: top,
      width: widget.menuWidth,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (ctx, _) {
          final s = (_scale.value).clamp(0.0, 1.2);
          final o = (_opacity.value * 8).clamp(0.0, 1.0); // fade 快速完成（前 1/8）
          return Opacity(
            opacity: o,
            child: Transform(
              alignment: Alignment.topRight,
              // 以按钮右下角为支点缩放（菜单从按钮处向左下展开 / 收回）
              transform: Matrix4.identity()
                ..translateByDouble(anchorDx, anchorDy, 0, 1)
                ..scaleByDouble(s, s, 1, 1)
                ..translateByDouble(-anchorDx, -anchorDy, 0, 1),
              child: widget.menuBuilder(ctx),
            ),
          );
        },
      ),
    );
  }
}

/// 弹簧曲线：把线性 t 映射为弹簧位移（stiffness 158, dampingRatio 0.6）。
/// 用于 AnimationController 的 curve，让 scale 带真实过冲。
class _SpringCurve extends Curve {
  @override
  double transformInternal(double t) {
    final sim = AppSprings.simulation(from: 0.0, to: 1.0);
    final tSec = t * 1.25;
    return sim.x(tSec).clamp(0.0, 1.2);
  }
}
