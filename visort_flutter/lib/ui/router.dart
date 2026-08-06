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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'route_transitions.dart';
import 'router_android.dart';
import 'screens/results_screen.dart';
import 'screens/review_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/home_screen.dart';
import 'screens/home_screen_android.dart';
import 'screens/sort_screen.dart';

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
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName.value = route.settings.name;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName.value = previousRoute?.settings.name;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) currentRouteName.value = newRoute.settings.name;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName.value = previousRoute?.settings.name;
  }
}

Route<dynamic>? onGenerateRoute(RouteSettings settings) {
  switch (settings.name) {
    case AppRoutes.home:
      // 根路由（首屏，实际无可见转场）。
      // 安卓保持 couiFade（pushAndRemoveUntil 场景 / 相册返回首页时的克制过渡；
      // ⚠️ 不用 couiSlideRoute：其被推页视差会让相册返回时首页整体滑动）。
      // 桌面 MaterialPageRoute 走平台默认。
      Widget homeBuilder(BuildContext _) => Platform.isAndroid
          ? const HomeScreenAndroid()
          : const HomeScreen();
      return Platform.isAndroid
          ? couiFadeRoute(builder: homeBuilder, settings: settings)
          : MaterialPageRoute(builder: homeBuilder, settings: settings);
    case AppRoutes.sort:
      return _platformRoute(
        builder: (_) => const SortScreen(),
        settings: settings,
      );
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

/// 平台分叉路由转场工厂。
/// - 安卓：用 COUI 转场（一加相册手感，sort/review/results 用 slide，其余按需）。
/// - 桌面（Windows/macOS/linux）：MaterialPageRoute，走 Theme.pageTransitionsTheme
///   的平台默认（桌面 = 快速淡入，无位移视差，符合桌面惯例且更流畅）。
///
/// 解耦背景：COUI 转场是为安卓触屏调校（350ms 视差位移），桌面端大屏套用会显得
/// 拖沓且合成开销高。让"一加手感"留在安卓侧，桌面走平台原生惯例。
Route<T> _platformRoute<T>({
  required WidgetBuilder builder,
  required RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  if (Platform.isAndroid) {
    return couiSlideRoute<T>(
      builder: builder,
      settings: settings,
      fullscreenDialog: fullscreenDialog,
    );
  }
  return MaterialPageRoute<T>(
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}

/// 导航辅助（全局 key 访问 navigator，便于非 widget 上下文触发）
final navigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((ref) {
  return GlobalKey<NavigatorState>();
});
