// 应用根 Widget —— 接入主题、语言、噪点、路由

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/i18n/i18n.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/noise_overlay.dart';
import 'ui/router.dart';

/// 噪点 overlay 不套用的路由（相册浏览相关）。
/// 这些页面有大面积滚动列表/全屏看图，每帧全屏 alpha 合成会拖慢渲染；
/// 且「看照片」时颗粒质感无意义，故绕过。见 currentRouteName 说明。
const _noiseDisabledRoutes = {
  AppRoutes.gallery,
  AppRoutes.album,
  AppRoutes.photoViewer,
};

class SortrApp extends ConsumerWidget {
  const SortrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lang = ref.watch(currentLanguageProvider);
    return MaterialApp(
      title: 'SORTR',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: Locale(lang),
      supportedLocales: const [Locale('en'), Locale('zh')],
      // 关键：提供 Material/S_widgets 的本地化
      // 否则 locale='zh' 时 MaterialLocalizations.of() 返回 null，
      // 导致所有 TextField 渲染崩溃（灰色 ErrorWidget）
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      initialRoute: AppRoutes.setup,
      onGenerateRoute: onGenerateRoute,
      // 记录当前活动路由名，供 builder 判断是否套噪点
      navigatorObservers: [RouteNameObserver()],
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        // 监听当前路由变化，相册浏览相关路由不套噪点（性能 + 观感）
        return AnimatedBuilder(
          animation: currentRouteName,
          builder: (context, _) {
            final route = currentRouteName.value;
            final enabled =
                route == null || !_noiseDisabledRoutes.contains(route);
            return enabled ? WithNoise(child: content) : content;
          },
        );
      },
    );
  }
}
