// 路由 —— 4 屏命名路由（Setup / Sort / Review / Results）+ A0 SAF demo
//
// 用 Flutter 内置 Navigator，不引入 go_router（4 屏规模无需）。
// 流程：Setup → Sort → Review → Results，Results 完成后 popTo Setup。
//
// /saf-demo 仅在 Android + debug 显示：A0 SAF PoC 验证用，A2 后将移除。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/album_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/results_screen.dart';
import 'screens/review_screen.dart';
import 'screens/saf_demo_screen.dart';
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
  // 仅 Android + debug：A0 SAF PoC demo（A2 后将移除）
  static const safDemo = '/saf-demo';
}

/// 是否显示 SAF demo 入口（仅 Android debug）
bool get _safDemoAvailable => Platform.isAndroid && kDebugMode;

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
      // 参数通过 settings.arguments（Map）传入 bucketId / bucketName
      final args = settings.arguments;
      if (args is Map) {
        return MaterialPageRoute(
          builder: (_) => AlbumScreen(
            bucketId: args['bucketId']?.toString() ?? '',
            bucketName: args['bucketName']?.toString(),
          ),
          settings: settings,
        );
      }
      return null;
    case AppRoutes.safDemo:
      if (!_safDemoAvailable) return null;
      return MaterialPageRoute(
        builder: (_) => const SafDemoScreen(),
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

/// Setup 屏判断是否显示 SAF demo 入口
bool shouldShowSafDemoEntry() => _safDemoAvailable;
