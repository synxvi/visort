// COUI 风格页面转场工厂 —— 对标一加系统相册
//
// 反编译自一加 Animation.COUI.Activity（res/values/styles.xml + res/anim/coui_open_slide_*）：
//   - 进入页 x: +100% → 0（350ms, cubic(0.3,0.1,0.3,1)）
//   - 被推页 x: 0 → -30% 视差 + alpha 1 → 0.5 暗化（350ms）
//   - pop 反向，被推页恢复 alpha 0.5 → 1
//
// ⚠️ 必须是路由级 transition（PageRouteBuilder.transitionsBuilder），
// 不能用 Overlay + AnimationController —— ColorOS DynamicFrameRate 会把
// Overlay 上的自定义动画降帧到 30 且粘滞不恢复（实测，见 album_screen.dart:209 注释）。
// 路由级动画被系统视为 push/pop，不受此限。
//
// Flutter 路由转场标准模式：transitionsBuilder 的 [child] = 当前路由页面本身。
// - [animation]：本路由的进度（push 0→1 自己进入；pop 1→0 自己退出）。
// - [secondaryAnimation]：本路由"底下那层"被推走/拉回的进度。
// 两个动画叠加在同一 child 上：进入时用 animation，被别人推走时用 secondaryAnimation。

import 'package:flutter/material.dart';

import '../core/theme/app_animations.dart';

/// 从右滑入 + 底页视差暗化（一加 activity 默认转场）。
///
/// 适用于：settings / sort / review / results / gallery 等普通页面。
Route<T> couiSlideRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  return PageRouteBuilder<T>(
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionsBuilder: (ctx, animation, secondary, child) {
      final width = MediaQuery.sizeOf(ctx).width;

      // ① 进入/退出（animation 驱动本路由）：
      //    push: x 从 +30% 宽度 → 0（一加用 100%，visort 用 30% 更紧凑，
      //    避免深色背景下大位移像"飞入"）。
      final enterT = AppCurves.slideEnter.transform(animation.value);
      final enterX = (1 - enterT) * 0.3 * width;

      // ② 被推/被拉回（secondaryAnimation 驱动本路由，当新路由压在上面时）：
      //    左移 -8% + alpha 1→0.5 暗化（一加 -30%/0.5，visort 用 -8% 更克制）。
      final exitT = AppCurves.slideExit.transform(secondary.value);
      final exitX = -exitT * 0.08 * width;
      final exitAlpha = 1 - 0.5 * AppCurves.couiEase.transform(secondary.value);

      return Transform.translate(
        offset: Offset(enterX + exitX, 0),
        child: Opacity(opacity: animation.value * exitAlpha, child: child),
      );
    },
    transitionDuration: AppDurations.activity,
    reverseTransitionDuration: AppDurations.activity,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}

/// 缩放进入（配合 Hero 的页面转场）。
///
/// 适用于：gallery → album（相册封面缩放成整个页面）。
/// 进入页 scale 0.92 → 1.0 + fade 0 → 1；被推页 scale 1.0 → 0.96 + alpha 1 → 0.6。
/// Hero 负责封面→页面的飞行缩放，本转场负责页面整体的"涌出"感。
Route<T> couiScaleRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  return PageRouteBuilder<T>(
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionsBuilder: (ctx, animation, secondary, child) {
      // ① 进入/退出（animation）：scale 0.92→1.0 + fade（COUIMoveEase 强 ease-out）
      final enterT = AppCurves.couiMoveEase.transform(animation.value);
      final enterScale = 0.92 + 0.08 * enterT;

      // ② 被推/被拉回（secondary）：scale 1.0→0.96 + alpha 1→0.6
      final exitT = AppCurves.couiMoveEase.transform(secondary.value);
      final exitScale = 1.0 - 0.04 * exitT;
      final exitAlpha = 1 - 0.4 * exitT;

      return Transform.scale(
        scale: enterScale * exitScale,
        child: Opacity(
          opacity: animation.value * exitAlpha,
          child: child,
        ),
      );
    },
    transitionDuration: AppDurations.activity,
    reverseTransitionDuration: AppDurations.activity,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}

/// 快速浮现（fade + 轻微缩放，无位移）。
///
/// 对标一加 coui_grow_fade：进入页 alpha 0→1 + scale 0.96→1.0，
/// 被推页几乎不动（仅极轻 scale 1.0→0.98）。
/// 比 slide 更轻盈、更快"出现"的感觉，适合相册浏览这类内容切换。
/// 曲线用 COUIMoveEase（强 ease-out）：瞬间浮现、不拖沓。
Route<T> couiFadeRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  return PageRouteBuilder<T>(
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionsBuilder: (ctx, animation, secondary, child) {
      // 进入页：alpha 0→1 + scale 0.96→1.0（COUIMoveEase 快速冲到位）
      final enterT = AppCurves.couiMoveEase.transform(animation.value);
      final enterScale = 0.96 + 0.04 * enterT;

      // 被推页：极轻缩放 1.0→0.98（仅暗示层级，不位移、不暗化）
      final exitT = AppCurves.couiMoveEase.transform(secondary.value);
      final exitScale = 1.0 - 0.02 * exitT;

      return Transform.scale(
        scale: enterScale * exitScale,
        child: Opacity(opacity: animation.value, child: child),
      );
    },
    transitionDuration: AppDurations.activity,
    reverseTransitionDuration: AppDurations.activity,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}
