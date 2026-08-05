// 路由 —— 4 屏命名路由（Home / Sort / Review / Results）+ 相册浏览（gallery/album）
//
// 用 Flutter 内置 Navigator，不引入 go_router（规模无需）。
// 流程：Home → Sort → Review → Results，Results 完成后 popTo Home。
// 安卓额外：Home → gallery → album（相册浏览）。
//
// （已移除 A0 SAF PoC demo 路由——SAF 方案已被 MediaStore 取代，相关代码清理。）

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'route_transitions.dart';
import 'screens/album_screen.dart';
import 'screens/gallery_screen.dart';
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
  static const gallery = '/gallery';
  static const album = '/album';
  static const photoViewer = '/photo-viewer';
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
      // 根路由：实际无转场（首屏），但保持 couiFade 以备 pushAndRemoveUntil 场景。
      // ⚠️ 不用 couiSlideRoute：其被推页视差（左移 8% + 暗化）会让相册返回时
      // 首页整体"从左向右滑动"——couiFadeRoute 被推页无位移（仅 2% 缩放）。
      return couiFadeRoute(
        builder: (_) => Platform.isAndroid
            ? const HomeScreenAndroid()
            : const HomeScreen(),
        settings: settings,
      );
    case AppRoutes.sort:
      return couiSlideRoute(
        builder: (_) => const SortScreen(),
        settings: settings,
      );
    case AppRoutes.review:
      return couiSlideRoute(
        builder: (_) => const ReviewScreen(),
        settings: settings,
      );
    case AppRoutes.results:
      return couiSlideRoute(
        builder: (_) => const ResultsScreen(),
        settings: settings,
      );
    case AppRoutes.gallery:
      // 相册浏览链（与 album 的 grow 动画配套）：被推页无位移——
      // slide 的被推页视差会让相册返回时列表页整体滑动。
      return couiFadeRoute(
        builder: (_) => const GalleryScreen(),
        settings: settings,
      );
    case AppRoutes.album:
      // 参数通过 settings.arguments（Map）传入 bucketId / bucketName / bucketCount。
      // 用快速浮现（fade + 轻缩放）：比 slide 更轻盈，适合内容浏览切换。
      final args = settings.arguments;
      if (args is Map) {
        return couiFadeRoute(
          builder: (_) => AlbumScreen(
            bucketId: args['bucketId']?.toString() ?? '',
            bucketName: args['bucketName']?.toString(),
            bucketCount: (args['bucketCount'] as num?)?.toInt(),
            favoritesOnly: args['favoritesOnly'] == true,
            trashedOnly: args['trashedOnly'] == true,
          ),
          settings: settings,
        );
      }
      return null;
    case AppRoutes.settings:
      return couiSlideRoute(
        builder: (_) => const SettingsScreen(),
        settings: settings,
      );
    default:
      return null;
  }
}

/// 导航辅助（全局 key 访问 navigator，便于非 widget 上下文触发）
final navigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((ref) {
  return GlobalKey<NavigatorState>();
});
