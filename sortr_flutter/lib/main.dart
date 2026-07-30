// 应用入口 —— 启动前加载配置 + 平台分叉初始化
//
// 共识 #13（A3）：用 Platform.isXxx 显式分叉，取代之前的 try/catch 静默吞错。
//   - Windows: window_manager 初始化 + 窗口状态恢复
//   - Android: shared_preferences 预热 + SAF 授权状态预检
//
// 注：window_manager 在安卓端会被插件注册加载（Flutter 机制），但 Platform.isWindows
// 守卫确保其方法不会被调用。这比 try/catch 静默吞错语义更清晰。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/i18n/i18n.dart';
import 'core/window/window_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ──────────── 平台分叉初始化 ────────────
  if (Platform.isWindows) {
    await _setupWindows();
  } else if (Platform.isAndroid) {
    // SharedPreferences 预热改为后台执行，不阻塞首帧。
    // 它的初始化结果直到 SetupScreen 首次真正读写 prefs 时才被需要，
    // 而那发生在首帧绘制之后的 postFrameCallback 里，晚于 runApp。
    unawaited(_setupAndroid());
  }

  // ──────────── 加载配置（两端共享） ────────────
  // 注意：配置加载保持 await —— SetupScreen 首帧需要用户已保存的 profiles，
  // 延后加载会导致首屏先用默认配置再跳变，时序复杂且体验更差。
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

// ───────────────────────── Windows 初始化 ─────────────────────────

Future<void> _setupWindows() async {
  await windowManager.ensureInitialized();
  await windowManager.setTitle('SORTR');
  await windowManager.setMinimumSize(const Size(900, 600));

  // 恢复上次窗口状态（大小 + 位置 + 最大化）
  final windowService = WindowStateService();
  final bounds = await windowService.load();
  if (bounds != null) {
    await windowManager.setBounds(Rect.fromLTWH(
      bounds.offsetX,
      bounds.offsetY,
      bounds.width,
      bounds.height,
    ));
    if (bounds.isMaximized) {
      await windowManager.maximize();
    }
  } else {
    // 首次启动：默认尺寸 + 居中
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.center();
  }

  // 注册窗口监听：resize/move 结束后异步保存（带防抖）
  windowManager.addListener(_WindowPersistListener(windowService));
}

// ───────────────────────── Android 初始化 ─────────────────────────

Future<void> _setupAndroid() async {
  // 预热 shared_preferences（首次访问会异步初始化，提前做避免后续访问 jank）。
  // 由 main() 以 unawaited 后台调用，不阻塞 runApp。
  // 授权有效性检查留给 setup_screen_android（需要 UI 上下文提示重新授权）
  await SharedPreferences.getInstance();
}

// ───────────────────────── 窗口持久化监听器（Windows） ─────────────────────────

/// 窗口状态持久化监听器。
///
/// 仅在 resize/move 完成后触发保存（不在拖动过程中频繁写盘），
/// 用防抖定时器合并连续事件。
class _WindowPersistListener extends WindowListener {
  _WindowPersistListener(this._service);
  final WindowStateService _service;
  Timer? _debounce;

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _service.saveCurrent);
  }

  @override
  void onWindowResized() => _schedule();

  @override
  void onWindowMoved() => _schedule();

  @override
  void onWindowMaximize() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();

  @override
  void onWindowClose() async {
    _debounce?.cancel();
    await _service.saveCurrent();
    await windowManager.destroy();
  }
}
