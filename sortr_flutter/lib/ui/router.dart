// 路由 —— 4 屏命名路由（Setup / Sort / Review / Results）
//
// 用 Flutter 内置 Navigator，不引入 go_router（4 屏规模无需）。
// 流程：Setup → Sort → Review → Results，Results 完成后 popTo Setup。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/results_screen.dart';
import 'screens/review_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/sort_screen.dart';

class AppRoutes {
  static const setup = '/';
  static const sort = '/sort';
  static const review = '/review';
  static const results = '/results';
}

Route<dynamic>? onGenerateRoute(RouteSettings settings) {
  switch (settings.name) {
    case AppRoutes.setup:
      return MaterialPageRoute(
        builder: (_) => const SetupScreen(),
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
    default:
      return null;
  }
}

/// 导航辅助（全局 key 访问 navigator，便于非 widget 上下文触发）
final navigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((ref) {
  return GlobalKey<NavigatorState>();
});
