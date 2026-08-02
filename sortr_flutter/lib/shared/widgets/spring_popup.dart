// 弹簧弹窗封装 —— 对标一加浮动手环的弹性缩放效果
//
// 反编译自一加 com.coui.appcompat...MenuViewAnimatorImpl（浮动手环）：
//   response=0.5s, bounce=0.4 → stiffness≈158, dampingRatio=0.6
// 效果：弹窗从触发位置（锚点）以真实弹簧物理展开，带可见过冲回弹。
//
// 实现基于 showGeneralDialog（路由级 transition，ColorOS 不降帧），
// transitionBuilder 内用弹簧 simulation 把线性 animation 映射成弹簧曲线。
// 锚点展开：复用 setup_screen_android.dart 的 Matrix4 translate·scale·translate 技巧。

import 'package:flutter/material.dart';

import '../../core/theme/app_animations.dart';

/// 居中弹窗（一加 coui_center_dialog 风格）。
///
/// 反编译自一加 res/anim/coui_center_dialog_enter.xml：
///   scale 0.8→1.0（pivot 50%,50%）+ alpha 0→1，250ms，cubic(0.3,0,0.1,1)。
/// 退出：alpha-only 150ms（coui_center_dialog_exit）。
///
/// 替代默认 showDialog（其转场是平台默认 fade），用于 AlertDialog 等。
Future<T?> showCenterDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
  Color barrierColor = const Color(0x80000000),
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'dialog',
    barrierColor: barrierColor,
    transitionDuration: AppDurations.dialog,
    // 退出 150ms（一加 coui_center_dialog_exit 仅 fade）。
    // showGeneralDialog 无 reverseTransitionDuration，靠 transitionBuilder 内
    // 按 anim.status==reverse 切换行为实现快退。
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionBuilder: (ctx, anim, _, child) {
      // 进入：scale 0.8→1.0 + fade，dialogEnter 曲线
      final t = AppCurves.dialogEnter.transform(anim.value);
      final scale = 0.8 + 0.2 * t;
      // 退出（anim 1→0）：纯 alpha（一加 coui_center_dialog_exit 仅 fade）
      final isExiting = anim.status == AnimationStatus.reverse;
      final opacity = isExiting ? anim.value : t;
      return Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(scale: scale, child: child),
      );
    },
  );
}

/// 弹簧弹窗（从锚点缩放展开）。
///
/// [anchor] 为弹窗在屏幕中的对齐位置（如 topLeft 表示从左上角长出来）。
/// [spring] 默认 bouncy（可见回弹）；菜单可用 gentle（轻微回弹）。
Future<T?> showSpringPopup<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Alignment anchor = Alignment.center,
  bool dismissible = true,
  String barrierLabel = 'popup',
  Color barrierColor = Colors.transparent,
  SpringDescription spring = AppSprings.bouncy,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor,
    // transitionDuration 设为弹簧 settling 上限（1.25s）。
    // 弹窗可提前交互（barrierDismissible 一旦显示即响应），不受此时长限制。
    transitionDuration: const Duration(milliseconds: 1250),
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionBuilder: (ctx, anim, _, child) {
      // fade 用 COUIEase 120ms（与缩放解耦，避免 alpha 也跟着弹簧抖）。
      final fadeT = (anim.value / 0.12).clamp(0.0, 1.0);
      final opacity = AppCurves.couiEase.transform(fadeT);
      return Opacity(
        opacity: opacity,
        child: AnimatedBuilder(
          animation: anim,
          builder: (ctx, _) {
            // 把线性 anim (0→1) 送进弹簧 simulation，取位移作为 scale。
            final sim = AppSprings.simulation(from: 0.0, to: 1.0, spring: spring);
            // anim.value 0..1 → 弹簧时间 0..1.25s（response=0.5 → 1.25s 覆盖过冲+回弹）
            final tSec = anim.value * 1.25;
            final scale = sim.x(tSec).clamp(0.0, 1.2);
            return Transform.scale(scale: scale, alignment: anchor, child: child);
          },
        ),
      );
    },
  );
}

/// 弹簧弹窗（从指定锚点坐标展开，复刻"从触发按钮位置长出来"）。
///
/// [anchorGlobalDx]/[anchorGlobalDy] = 触发按钮右下角的屏幕坐标。
/// [menuLeft]/[menuTop] = 菜单 Positioned 的 left/top（屏幕坐标）。
/// [menuWidth] = 菜单宽度（用于精确定位 Positioned）。
/// [menuBuilder] 只构建菜单内容本体（不含 Stack/Positioned），
/// 本函数负责定位 + 锚点缩放 + fade。
Future<T?> showSpringPopupFromAnchor<T>({
  required BuildContext context,
  required WidgetBuilder menuBuilder,
  required double anchorGlobalDx,
  required double anchorGlobalDy,
  required double menuLeft,
  required double menuTop,
  required double menuWidth,
  bool dismissible = true,
  String barrierLabel = 'popup',
  Color barrierColor = Colors.transparent,
  SpringDescription spring = AppSprings.bouncy,
}) {
  // 锚点相对菜单左上角的偏移：Transform 作用在菜单本体上（非全屏 Stack），
  // 故此偏移是"菜单内坐标系下按钮右下角的位置"。
  final dx = anchorGlobalDx - menuLeft;
  final dy = anchorGlobalDy - menuTop;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor,
    transitionDuration: const Duration(milliseconds: 1250),
    // pageBuilder 返回全屏 Stack，菜单用 Positioned 精确定位。
    // ⚠️ 弹簧缩放必须作用在 Positioned.child（菜单本体）上，不能作用在整个 Stack
    // （Stack 左上角是屏幕 0,0，会导致锚点错位——早期 bug：从挖孔弹出）。
    pageBuilder: (ctx, _, _) {
      return Stack(
        children: [
          Positioned(
            left: menuLeft,
            top: menuTop,
            width: menuWidth,
            // 缩放锚点 = 按钮右下角（菜单内坐标 dx,dy）。
            child: _SpringAnchorScale(
              animation: ModalRoute.of(ctx)!.animation!,
              dx: dx,
              dy: dy,
              spring: spring,
              child: menuBuilder(ctx),
            ),
          ),
        ],
      );
    },
    // transitionBuilder 只负责整体 fade（Stack 层），缩放已内联到 Positioned.child。
    transitionBuilder: (ctx, anim, _, child) {
      final fadeT = (anim.value / 0.12).clamp(0.0, 1.0);
      final opacity = AppCurves.couiEase.transform(fadeT);
      return Opacity(opacity: opacity, child: child);
    },
  );
}

/// 锚点弹簧缩放：以菜单内坐标 (dx,dy) 为支点，弹簧 scale 0→1。
/// 监听路由 animation（push 0→1 / pop 1→0）。
class _SpringAnchorScale extends StatelessWidget {
  const _SpringAnchorScale({
    required this.animation,
    required this.dx,
    required this.dy,
    required this.spring,
    required this.child,
  });

  final Animation<double> animation;
  final double dx;
  final double dy;
  final SpringDescription spring;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (ctx, _) {
        final sim = AppSprings.simulation(from: 0.0, to: 1.0, spring: spring);
        final tSec = animation.value * 1.25;
        final s = sim.x(tSec).clamp(0.0, 1.2);
        return Transform(
          alignment: Alignment.topLeft,
          // 以锚点缩放：T(dx,dy)·S·T(-dx,-dy)，让 (dx,dy) 点保持不动。
          transform: Matrix4.identity()
            ..translateByDouble(dx, dy, 0, 1)
            ..scaleByDouble(s, s, 1, 1)
            ..translateByDouble(-dx, -dy, 0, 1),
          child: child,
        );
      },
    );
  }
}
