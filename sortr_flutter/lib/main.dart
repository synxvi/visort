// 应用入口 —— 启动前加载配置

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/i18n/i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端：初始化窗口（安卓端 window_manager 不可用，包在 try 中）
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('SORTR');
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setMinimumSize(const Size(900, 600));
  } catch (_) {
    // 非 Windows 桌面端，忽略
  }

  // 启动前加载配置
  final container = ProviderContainer();
  try {
    final service = container.read(profilesServiceProvider);
    final config = await service.load();
    container.read(configProvider.notifier).state = config;
  } catch (_) {
    // 加载失败用默认配置
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const SortrApp(),
  ));
}
