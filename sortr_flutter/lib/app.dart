// 应用根 Widget —— 接入主题、语言、噪点、路由

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/i18n/i18n.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/noise_overlay.dart';
import 'ui/router.dart';

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
      builder: (context, child) {
        return WithNoise(child: child ?? const SizedBox.shrink());
      },
    );
  }
}
