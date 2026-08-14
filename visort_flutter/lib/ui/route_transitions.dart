// 页面转场工厂 —— 1:1 复刻 ente
//
// ente 实现（mobile/packages/ente_pure_utils/lib/src/navigation_util.dart
//   → _buildPageRoute + apps/photos/lib/services/app_navigation_service.dart）：
//   - PageRouteBuilder + FadeTransition 200ms
//   - opaque: false —— 下层路由参与合成，push/pop 均为交叉淡入观感
//   - transitionsBuilder 包 Align（对齐子项，保持 ente 原样）
//
// ⚠️ 必须是路由级 transition（PageRouteBuilder.transitionsBuilder），
// 不能用 Overlay + AnimationController —— ColorOS DynamicFrameRate 会把
// Overlay 上的自定义动画降帧到 30 且粘滞不恢复（实测，历史教训）。
// 路由级动画被系统视为 push/pop，不受此限。ente 同为路由级，无此问题。
//
// 历史：本文件原为 COUI 风格转场（对标一加系统相册，350ms 视差位移），
// 2026-08 动画对齐 ente 时整体替换（git 历史可回溯）。

import 'package:flutter/material.dart';

/// ente 式页面转场：200ms 交叉淡入，opaque:false。
///
/// 全路由统一（home/sort/review/results/settings/gallery/album），
/// 与 ente 的 routeToPage/pushPage 行为一致。
Route<T> enteFadeRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  return PageRouteBuilder<T>(
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionsBuilder: (ctx, animation, secondary, child) {
      return Align(
        child: FadeTransition(opacity: animation, child: child),
      );
    },
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    // opaque:false —— pop 返回时底下页面参与合成可见（ente 交叉淡入的关键）。
    opaque: false,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}
