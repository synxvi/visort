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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'core/fs/image_loader.dart' show initMaxDecodePixels;
import 'package:flutter/scheduler.dart';
import 'app.dart';
import 'core/i18n/i18n.dart';
import 'core/window/window_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ──────────── 平台分叉初始化 ────────────
  if (Platform.isWindows) {
    await _setupWindows();
  } else if (Platform.isAndroid) {
    // 启用 edge-to-edge：内容绘制延伸到状态栏 / 导航栏（手势条）下方，
    // 系统栏透明叠加。让图片等全屏内容在物理屏幕正中央居中，而非被
    // 状态栏占位挤偏。桌面端无系统栏，此调用为 no-op。
    _enableEdgeToEdge();
    // SharedPreferences 预热改为后台执行，不阻塞首帧。
    // 它的初始化结果直到 HomeScreen 首次真正读写 prefs 时才被需要，
    // 而那发生在首帧绘制之后的 postFrameCallback 里，晚于 runApp。
    unawaited(_setupAndroid());
  }

  // ──────────── 加载配置（两端共享） ────────────
  // 注意：配置加载保持 await —— HomeScreen 首帧需要用户已保存的 profiles，
  // 延后加载会导致首屏先用默认配置再跳变，时序复杂且体验更差。
  final container = ProviderContainer();
  try {
    final service = container.read(profilesServiceProvider);
    final config = await service.load();
    container.read(configProvider.notifier).state = config;
  } catch (_) {
    // 加载失败用默认配置
  }

  // 手动注册 SpaceMono 字体:FontManifest 注册在本机 release 下不生效(字体 asset
  // 能加载、文件等宽、FontManifest 正确,但 Flutter 渲染时 fallback 成系统 sans)。
  // 用 FontLoader 直接把 ttf 字节注册为 family 'Space Mono' 绕过。
  final smLoader = FontLoader('Space Mono');
  smLoader.addFont(rootBundle.load('assets/fonts/SpaceMono-Regular.ttf'));
  smLoader.addFont(rootBundle.load('assets/fonts/SpaceMono-Bold.ttf'));
  await smLoader.load();

  runApp(UncontrolledProviderScope(
    container: container,
    child: const VisortApp(),
  ));

  // 临时 FPS 统计（排查 30 帧问题用，定位后移除）：用真实时间窗统计
  // 实际提交帧率（之前用 totalSpan 算法不含帧间隔，会高估）。
  final sw = Stopwatch()..start();
  int count = 0;
  SchedulerBinding.instance.addTimingsCallback((timings) {
    count += timings.length;
    final elapsed = sw.elapsed;
    if (elapsed >= const Duration(milliseconds: 500)) {
      final fps = count * 1000 / elapsed.inMilliseconds;
      debugPrint(
          '[FPS] ${fps.toStringAsFixed(0)} (frames=$count / ${elapsed.inMilliseconds}ms)');
      count = 0;
      sw.reset();
    }
  });

  // 诊断:SpaceMono 字体 asset 能否加载(排查字体不生效)
  rootBundle.load('assets/fonts/SpaceMono-Regular.ttf').then((data) {
    debugPrint('[FONT] SpaceMono asset OK: ${data.lengthInBytes} bytes');
  }).catchError((e) {
    debugPrint('[FONT] SpaceMono asset FAIL: $e');
  });
}

// ───────────────────────── Windows 初始化 ─────────────────────────

Future<void> _setupWindows() async {
  await windowManager.ensureInitialized();
  await windowManager.setTitle('Visort');
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

/// 启用边到边（沉浸式）布局：内容画到物理屏幕边缘，系统栏透明叠加。
///
/// Android 15+ 已强制 edge-to-edge；这里显式开启以兼容更低版本并让
/// 全屏看图器（PhotoViewer）中的图片在物理屏幕正中央居中，而非被
/// 实色状态栏挤偏。深色 App 用亮色系统栏图标。
///
/// 手势条（小横条）无背景的两个关键点（对齐 ente photos main.dart）：
///   - systemNavigationBarColor 用 0x00010000 而非纯 0x00000000——部分 ROM
///     （ColorOS 实测）把全零当作「未设置」而回退默认半透明 scrim；
///   - 两个 contrastEnforced=false：关闭系统对透明系统栏强加的半透明
///     对比度遮罩。窗口层的同款设置在 MainActivity.onCreate 已提前完成。
void _enableEdgeToEdge() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    // ente 同款 workaround：alpha=0 但 RGB 非零，避免被 ROM 当未设置忽略。
    systemNavigationBarColor: Color(0x00010000),
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light, // 深底白字
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  ));
}

Future<void> _setupAndroid() async {
  // 预热 shared_preferences（首次访问会异步初始化，提前做避免后续访问 jank）。
  // 由 main() 以 unawaited 后台调用，不阻塞 runApp。
  // 授权有效性检查留给 home_screen_android（需要 UI 上下文提示重新授权）
  await SharedPreferences.getInstance();
  // [ente 对齐] 解码防崩阈值（RAM < 5GB → 24MP）：后台预热，不阻塞首帧。
  await initMaxDecodePixels();
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
