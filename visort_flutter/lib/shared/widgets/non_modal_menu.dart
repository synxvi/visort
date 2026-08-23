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
/// [upward] = 向上展开（菜单底贴按钮顶上方 4dp）：锚点在屏幕下方时用
///   （如大图浏览页底栏按钮——向下展开会跑到屏幕外）。
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
  bool upward = false,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final controller = NonModalMenuController();
  // 收回信号：controller.close() 置 true，body 监听后播 reverse，
  // 完成回调 onClose → controller._dismiss 真正移除（实现收回动画）。
  final closeSignal = ValueNotifier<bool>(false);
  controller._closeSignal = closeSignal;

  // 当前路由的次级动画：新页面 push 覆盖本页时播放（value 0→1）。
  // 菜单监听它——非模态菜单不拦截手势，导航发生时若不主动收回，
  // 菜单会滞留在 rootOverlay 最上层（盖到相册/sort/settings 等新页面之上）。
  final routeSecondary = ModalRoute.of(context)?.secondaryAnimation;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _NonModalMenuBody(
      anchorKey: anchorKey,
      menuWidth: menuWidth,
      offsetX: offsetX,
      offsetY: offsetY,
      upward: upward,
      isScrolling: isScrolling,
      closeSignal: closeSignal,
      routeSecondary: routeSecondary,
      onClose: () {
        controller._dismiss(entry, onDismiss);
      },
      menuBuilder: menuBuilder,
    ),
  );
  overlay.insert(entry);
  return controller;
}

/// 菜单控制器：触发收回动画 + 资源清理。
class NonModalMenuController {
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
    onDismiss?.call();
  }
}

class _NonModalMenuBody extends StatefulWidget {
  const _NonModalMenuBody({
    required this.anchorKey,
    required this.menuWidth,
    required this.offsetX,
    required this.offsetY,
    required this.upward,
    required this.isScrolling,
    required this.closeSignal,
    this.routeSecondary,
    required this.onClose,
    required this.menuBuilder,
  });

  final GlobalKey anchorKey;
  final double menuWidth;
  final double offsetX;
  final double offsetY;
  /// 向上展开（菜单底贴按钮顶上方 4dp）。
  final bool upward;
  final ValueNotifier<bool> isScrolling;
  /// controller.close() 触发的收回信号。
  final ValueNotifier<bool> closeSignal;
  /// 所属路由的次级动画：新页面覆盖本页时播放，用于导航时自动收回。
  final Animation<double>? routeSecondary;
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
  // 收回起点：记录触发收回瞬间的 scale 与 controller value，
  // 让收回从当前显示尺寸线性缩到 0（绕开 forward 弹簧 → reverse 线性的曲线跳变）。
  double _reverseStartScale = 1.0;
  double _reverseStartValue = 1.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
      // 收回 450ms（linear 曲线下匀速、看得清又利落；与弹簧弹窗收回统一）。
      reverseDuration: const Duration(milliseconds: 450),
    );
    // 展开：弹簧曲线（一加浮动手环：stiffness 158, dampingRatio 0.6）。
    // 收回：couiOutEase（快速起步、极慢收尾 → "嗖"地收回）。
    _scale = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: _SpringCurve(),
        // 收回用线性：展开弹簧过冲有性格，收回则匀速、干脆、不拖尾。
        reverseCurve: Curves.linear,
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
    // 监听路由覆盖：新页面 push 时瞬间收回（与滚动收回同模式，避免菜单滞留新页面之上）。
    widget.routeSecondary?.addListener(_onRoutePushed);
  }

  /// 路由被新页面覆盖时（secondaryAnimation value > 0）瞬间收回。
  void _onRoutePushed() {
    final anim = widget.routeSecondary;
    if (anim != null && anim.value > 0 && mounted && !_closing) {
      _closing = true;
      widget.onClose();
    }
  }

  /// 点外部屏障：播收回动画（与 controller.close() 同路径），dismissed 后移除。
  /// 屏障 opaque 吞噬第一次点击 → 不触发底层，再点一次才进对应页面。
  void _dismissOnOutsideTap() {
    if (!_closing && mounted) {
      _closing = true;
      _beginReverse();
    }
  }

  /// 记录当前 scale / controller 值后开始收回。收回按 controller 归一化进度，
  /// 从 [_reverseStartScale] 线性缩到 0 —— 无论在展开哪个阶段收回，都从当前
  /// 显示尺寸连续缩小，彻底绕开 CurvedAnimation 的 curve→reverseCurve 切换跳变。
  void _beginReverse() {
    _reverseStartScale = _scale.value.clamp(0.0, 1.2);
    _reverseStartValue = _ctrl.value;
    _ctrl.reverse();
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
      _beginReverse(); // 收回动画；dismissed 后 statusListener 调 onClose 移除
    }
  }

  @override
  void dispose() {
    widget.isScrolling.removeListener(_onScrollChanged);
    widget.closeSignal.removeListener(_onCloseSignal);
    widget.routeSecondary?.removeListener(_onRoutePushed);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 定位：基于锚点按钮的屏幕坐标
    final btnCtx = widget.anchorKey.currentContext;
    final screen = MediaQuery.sizeOf(context);
    double left = 0, top = 0, bottom = 0, btnW = 0;
    if (btnCtx != null) {
      final box = btnCtx.findRenderObject() as RenderBox;
      btnW = box.size.width;
      final pos = box.localToGlobal(Offset.zero);
      // 菜单右对齐按钮右缘 -8dp
      left = (pos.dx + box.size.width - widget.menuWidth - 8 + widget.offsetX)
          .clamp(0.0, screen.width - widget.menuWidth);
      if (widget.upward) {
        // 向上展开：菜单底 = 按钮顶 - 4dp（Positioned.bottom 相对屏幕底）。
        // 底栏按钮下方是屏幕外，只能向上长（如大图浏览页底栏 ⋮）。
        bottom = screen.height - pos.dy + 4 - widget.offsetY;
      } else {
        // 菜单顶 = 按钮底 + 4dp
        top = pos.dy + box.size.height + 4 + widget.offsetY;
      }
    }

    // 锚点（菜单内坐标）：按钮水平中心、菜单靠近按钮那侧边（向下=顶边，
    // 向上=底边）的交点。菜单右缘对齐「按钮右缘 -8」，故按钮中心相对菜单左
    // = menuWidth + 8 - btnW/2。
    final anchorDx = widget.menuWidth + 8 - btnW / 2;
    final anchorDy = 0.0;

    return Stack(
      children: [
        // 全屏屏障：展开期间吞噬第一次点击 → 仅收回菜单，不触发底层导航。
        // （标准 popover 行为：菜单在时点外部只关菜单，再点才进对应页面。）
        // 代价：展开期间主界面不可滚动（modal 化）；可接受的短时交互代价。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismissOnOutsideTap,
            // 滑动(pan)其他地方松手也收回——视同点击外部(drag 不会触发 onTap)。
            onPanEnd: (_) => _dismissOnOutsideTap(),
          ),
        ),
        Positioned(
          left: left,
          top: widget.upward ? null : top,
          bottom: widget.upward ? bottom : null,
          width: widget.menuWidth,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (ctx, _) {
              // 展开：弹簧 scale（_scale.value 过冲）；收回：从触发瞬间的 scale
              // 线性缩到 0（rawScale）—— 不再读 _scale.value，绕开 curve 切换跳变。
              final double rawScale = (_closing && _reverseStartValue > 0)
                  ? _reverseStartScale * (_ctrl.value / _reverseStartValue)
                  : _scale.value;
              final s = rawScale.clamp(0.0, 1.2);
              // 展开：前 1/8 快速淡入；收回：跟随 scale 同步淡出。
              final o = (_closing ? rawScale : _opacity.value * 8)
                  .clamp(0.0, 1.0);
              return Opacity(
                opacity: o,
                child: widget.upward
                    ? Transform.scale(
                        // 向上展开的支点 = (anchorDx, 菜单底边)。菜单高度未知
                        // （menuBuilder 是 min-Column，layout 后才定），拿不到 y，
                        // 用 Alignment 等价表达：x = anchorDx/menuWidth 映射到
                        // [-1,1]，y = 1（底边）。Transform.scale(alignment:) 即
                        // 绕该支点缩放，与手动矩阵 T(支点)·S·T(-支点) 数学等价。
                        scale: s,
                        alignment: Alignment(
                          2 * anchorDx / widget.menuWidth - 1,
                          1.0,
                        ),
                        child: widget.menuBuilder(ctx),
                      )
                    : Transform(
                        // 支点由下方 translate·scale·translate 矩阵精确给出（按钮正下方
                        // 顶边交点，见上 anchorDx/anchorDy）。
                        // ⚠️ 不能再传 alignment：RenderTransform 会再叠一层 alignment 平移，
                        //    把有效支点推到错误位置。默认 center 分支会原样使用此矩阵。
                        transform: Matrix4.identity()
                          ..translateByDouble(anchorDx, anchorDy, 0, 1)
                          ..scaleByDouble(s, s, 1, 1)
                          ..translateByDouble(-anchorDx, -anchorDy, 0, 1),
                        child: widget.menuBuilder(ctx),
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 弹簧曲线：把线性 t 映射为弹簧位移（stiffness 158, dampingRatio 0.6）。
/// 用于 AnimationController 的 curve，让 scale 带真实过冲。
class _SpringCurve extends Curve {
  @override
  double transformInternal(double t) {
    final sim = AppSprings.simulation(from: 0.0, to: 1.0);
    final tSec = t * 1.0;
    return sim.x(tSec).clamp(0.0, 1.2);
  }
}
