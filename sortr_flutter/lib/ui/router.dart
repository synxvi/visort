// 路由 —— 4 屏命名路由（Setup / Sort / Review / Results）+ 相册浏览（gallery/album）
//
// 用 Flutter 内置 Navigator，不引入 go_router（规模无需）。
// 流程：Setup → Sort → Review → Results，Results 完成后 popTo Setup。
// 安卓额外：Setup → gallery → album（相册浏览）。
//
// （已移除 A0 SAF PoC demo 路由——SAF 方案已被 MediaStore 取代，相关代码清理。）

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/album_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/results_screen.dart';
import 'screens/review_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/setup_screen_android.dart';
import 'screens/sort_screen.dart';

class AppRoutes {
  static const setup = '/';
  static const sort = '/sort';
  static const review = '/review';
  static const results = '/results';
  static const gallery = '/gallery';
  static const album = '/album';
  static const photoViewer = '/photo-viewer';
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
    case AppRoutes.setup:
      return MaterialPageRoute(
        builder: (_) => Platform.isAndroid
            ? const SetupScreenAndroid()
            : const SetupScreen(),
        settings: settings,
      );
    case AppRoutes.sort:
      return MaterialPageRoute(
        builder: (_) => const SortScreen(),
        settings: settings,
      );
    case AppRoutes.review:
      return MaterialPageRoute(
        builder: (_) => const ReviewScreen(),
        settings: settings,
      );
    case AppRoutes.results:
      return MaterialPageRoute(
        builder: (_) => const ResultsScreen(),
        settings: settings,
      );
    case AppRoutes.gallery:
      return MaterialPageRoute(
        builder: (_) => const GalleryScreen(),
        settings: settings,
      );
    case AppRoutes.album:
      // 参数通过 settings.arguments（Map）传入 bucketId / bucketName / bucketCount
      final args = settings.arguments;
      if (args is Map) {
        return MaterialPageRoute(
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
    default:
      return null;
  }
}

/// 导航辅助（全局 key 访问 navigator，便于非 widget 上下文触发）
final navigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((ref) {
  return GlobalKey<NavigatorState>();
});
