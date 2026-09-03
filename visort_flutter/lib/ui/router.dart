// 路由 —— 全平台通用命名路由（Home / Sort / Review / Results / Settings）
//
// 用 Flutter 内置 Navigator，不引入 go_router（规模无需）。
// 流程：Home → Sort → Review → Results，Results 完成后 popTo Home。
//
// 安卓额外的相册浏览链（gallery / album / photoViewer）见 router_android.dart，
// 由本文件 default 分支委托 onGenerateAlbumRoute 处理。
// 桌面端（Windows/macOS/linux）不注册、不引用相册路由。

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'route_transitions.dart';
import 'router_android.dart';
import 'screens/results_screen.dart';
import 'screens/review_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/home_screen.dart';
import 'screens/app_shell_android.dart';
import 'screens/sort_screen.dart';
import 'screens/sort_screen_android.dart';

class AppRoutes {
  static const home = '/';
  static const sort = '/sort';
  static const review = '/review';
  static const results = '/results';
  static const settings = '/settings';
}

/// 当前活动路由名（由 [RouteNameObserver] 维护）。
/// 供 app.dart 的 builder 判断是否套用全局噪点 overlay——相册浏览相关页
///（gallery/album 及其上 push 的 PhotoViewer）不套噪点，既提升滚动性能
///（避免每帧全屏 alpha 合成），也还原「看照片」的纯净观感。
final ValueNotifier<String?> currentRouteName = ValueNotifier<String?>(null);

class RouteNameObserver extends NavigatorObserver {
  // restoreState（导航状态恢复）在 build 期间同步回调 didPush/didPop，
  // 直接赋 currentRouteName 会触发监听者（app.dart 噪点层）build 期间 setState
  // 断言（setState() called during build）。延迟到帧后赋值。
  //
  // 无名路由（settings.name == null：dialog / bottom sheet / 弹簧菜单等
  // 弹层）不是「页面」，底下的页面没变——不更新（保持上一个有名路由）。
  // 旧实现置 null，而 app.dart 把 null 当「启用噪点」：豁免页（如设置页
  // 所在的 '/' 壳）上弹任何小窗都会全屏叠出噪点纹理、观感变亮（2026-09
  // 实报）。弹层 pop 时 previousRoute 是底下的有名页面，正常恢复。
  static void _set(String? name) {
    if (name == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      currentRouteName.value = name;
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _set(route.settings.name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _set(previousRoute?.settings.name);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _set(newRoute.settings.name);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _set(previousRoute?.settings.name);
  }
}

Route<dynamic>? onGenerateRoute(RouteSettings settings) {
  switch (settings.name) {
    case AppRoutes.home:
      // 根路由（首屏，实际无可见转场；popTo Home / 相册返回首页时 200ms 淡入）。
      // 安卓 = 抽屉壳（相册为默认屏，快速整理等 5 个一级页住在壳里）；
      // 桌面 = 键盘流首页，无抽屉。
      Widget homeBuilder(BuildContext _) => Platform.isAndroid
          ? const AppShellAndroid()
          : const HomeScreen();
      return enteFadeRoute(builder: homeBuilder, settings: settings);
    case AppRoutes.sort:
      // 与 home 同款文件级分叉：安卓沉浸式布局 / 桌面键盘布局
      //（共享会话守卫在 sort_common.dart，平台差异不进共享文件）。
      Widget sortBuilder(BuildContext _) => Platform.isAndroid
          ? const SortScreenAndroid()
          : const SortScreen();
      return enteFadeRoute(builder: sortBuilder, settings: settings);
    case AppRoutes.review:
      return _platformRoute(
        builder: (_) => const ReviewScreen(),
        settings: settings,
      );
    case AppRoutes.results:
      return _platformRoute(
        builder: (_) => const ResultsScreen(),
        settings: settings,
      );
    case AppRoutes.settings:
      return _platformRoute(
        builder: (_) => const SettingsScreen(),
        settings: settings,
      );
    default:
      // 相册浏览链等安卓专属路由委托安卓侧处理；桌面端永不 push 这些路由名，
      // 走到这里返回 null（Flutter 会显示错误页，但桌面无法到达，安全）。
      return onGenerateAlbumRoute(settings);
  }
}

/// 路由转场工厂 —— 全平台统一 ente 式 200ms 交叉淡入（enteFadeRoute）。
///
/// 历史：安卓曾用 COUI 350ms 视差转场、桌面 MaterialPageRoute；动画对齐
/// ente 后统一 fade（ente 桌面 iOS 侧用 SwipeableRouteBuilder，Windows 无
/// 手势返回场景，fade 统一即可）。
Route<T> _platformRoute<T>({
  required WidgetBuilder builder,
  required RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  return enteFadeRoute<T>(
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}
