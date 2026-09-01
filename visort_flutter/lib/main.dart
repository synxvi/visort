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

import 'package:visort_flutter/core/fs/idle_precache.dart';

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/gestures.dart' show debugPrintGestureArenaDiagnostics, debugPrintRecognizerCallbacksTrace;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'core/fs/image_loader.dart' show initMaxDecodePixels;
import 'app.dart';
import 'core/db/database_service.dart';
import 'features/search/search_data_store.dart';
import 'core/i18n/i18n.dart';
import 'core/window/window_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // [SDH 取证] 手势诊断（临时，排查手柄第一次拖不动）：
  // arena 裁决序列 + recognizer 回调 trace，release 下同样生效。
  if (Platform.isAndroid) {
    debugPrintGestureArenaDiagnostics = true;
    debugPrintRecognizerCallbacksTrace = true;
  }

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
    var config = await service.load();
    // 首启语言落定:'system' 是出厂默认,仅在首启决断一次(设备中文→zh,
    // 其余→en 兜底)并写回持久化。此后 config.language 恒为 zh/en,设置页
    // 的语言选项也只提供这两态(不再有「跟随系统」)。
    if (config.language == 'system') {
      config = config.copyWith(language: resolveLanguage('system'));
      await service.save(config);
    }
    container.read(configProvider.notifier).state = config;
  } catch (_) {
    // 加载失败用默认配置
  }

  // ──────────── SQLite 预热(P0) ────────────
  // 后台打开 + 迁移,不阻塞首帧(与安卓 prefs 预热同模式)。首屏不依赖 DB;
  // store 一律经 DatabaseService.database 幂等 getter 兜底,慢一点也不出错。
  // 失败静默降级为纯内存(降级红线,见 database_service.dart)。
  unawaited(container.read(databaseServiceProvider).init());

  // ──────────── 空闲预缓存激活(安卓) ────────────
  // read 一次激活 provider（attach 生命周期监听 + 配额推送 Kotlin +
  // 常驻低频扫描循环）。桌面端无 MediaStore 通道，跳过。
  if (Platform.isAndroid) {
    container.read(idlePrecacheProvider);
    // 搜索数据预热：全量照片 + 分组产物常驻 store（[用户定稿] 提前
    // 渲染好，进搜索页零加载——根治入场帧布局跳动）。首屏稳了再跑
    //（2s），快照缓存下 ~50ms 无感；幂等，进页 warmUp 只是兜底。
    unawaited(Future.delayed(const Duration(seconds: 2), () async {
      await container.read(searchDataProvider.notifier).warmUp();
    }));
  }

  // 手动注册 SpaceMono 字体:FontManifest 注册在本机 release 下不生效(字体 asset
  // 能加载、文件等宽、FontManifest 正确,但 Flutter 渲染时 fallback 成系统 sans)。
  // 用 FontLoader 直接把 ttf 字节注册为 family 'Space Mono' 绕过。
  final smLoader = FontLoader('Space Mono');
  smLoader.addFont(rootBundle.load('assets/fonts/SpaceMono-Regular.ttf'));
  smLoader.addFont(rootBundle.load('assets/fonts/SpaceMono-Bold.ttf'));
  await smLoader.load();

  // 全局错误兜底：未捕获的异步异常在 release 下无声消失、线上无从排查。
  // 统一落 debugPrint（release 为空操作但 zone 已吞掉，不再有未处理异常
  // 警告；debug/profile 可见全栈）。后续如需持久化再接本地日志文件。
  FlutterError.onError = (details) {
    debugPrint('[FlutterError] ${details.exception}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[uncaught] $error\n$stack');
    return true; // 标记已处理，阻止向 zone 冒泡
  };

  runApp(UncontrolledProviderScope(
    container: container,
    child: const VisortApp(),
  ));
}

// ───────────────────────── Windows 初始化 ─────────────────────────

Future<void> _setupWindows() async {
  try {
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
  } catch (e) {
    // 兜底：窗口恢复读的是持久化 JSON（显示器变更后非法坐标等），
    // setBounds 等任一失败若冒泡到 main 顶层则 runApp 永不执行——
    // 应用整体无法启动。跳过窗口恢复降级启动（默认窗口尺寸），
    // 与文件内其余初始化（DB/prefs）「失败静默降级」策略一致。
    debugPrint('[_setupWindows] 窗口初始化失败，降级默认启动: $e');
  }
}

// ───────────────────────── Android 初始化 ─────────────────────────

/// 启用边到边（沉浸式）布局：内容画到物理屏幕边缘，系统栏透明叠加。
///
/// Android 15+ 已强制 edge-to-edge；这里显式开启以兼容更低版本并让
/// 全屏看图器（PhotoViewer）中的图片在物理屏幕正中央居中，而非被
/// 实色状态栏挤偏。深色 App 用亮色系统栏图标。
///
/// 手势条（小横条）无背景的两个关键点（对齐 ente photos main.dart）：
///   - 两个系统栏色都用 0x00010000 而非纯 0x00000000——部分 ROM（ColorOS
///     实测）把全零当作「未设置」而回退默认 scrim。状态栏同坑：抽屉动画
///     中页面缩小、顶部条带露出时被 ColorOS 默认黑 scrim 盖住（底部手势条
///     早已修过、顶部漏网，真机实测「顶部黑底部正常」的不对称即此）；
///   - 两个 contrastEnforced=false：关闭系统对透明系统栏强加的半透明
///     对比度遮罩。窗口层的同款设置在 MainActivity.onCreate 已提前完成。
void _enableEdgeToEdge() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    // ente 同款 workaround：alpha=0 但 RGB 非零，避免被 ROM 当未设置忽略。
    statusBarColor: Color(0x00010000),
    systemNavigationBarColor: Color(0x00010000),
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light, // 深底白字
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  ));
  // 3.47 engine 的 edgeToEdge 会把 legacy systemUiVisibility 清零，而 ColorOS
  // 靠 LAYOUT_* bits 判定「沉浸式窗口→手势条无背景悬浮」（不认新 API）。
  // 通知 Android 侧在 engine 覆写后补设（详见 MainActivity.reassert…注释）。
  MethodChannel('visort/app').invokeMethod('reassertSystemUiFlags');
}

Future<void> _setupAndroid() async {
  // 预热 shared_preferences（首次访问会异步初始化，提前做避免后续访问 jank）。
  // 由 main() 以 unawaited 后台调用，不阻塞 runApp。
  // 授权有效性检查留给 home_screen_android（需要 UI 上下文提示重新授权）
  await SharedPreferences.getInstance();
  // [ente 对齐] 解码防崩阈值（RAM < 5GB → 24MP）：后台预热，不阻塞首帧。
  await initMaxDecodePixels();
  // [P1 迁移] 桶快照已迁 SQLite(bucket_snapshot 表);旧 visort_snap_* prefs
  // 是缓存语义,不做数据搬迁,一次性清 key 即可。
  await _purgeLegacySnapKeys();
}

/// 清除旧版桶快照的 SharedPreferences key(P1 SQLite 迁移遗留)。
Future<void> _purgeLegacySnapKeys() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final legacy =
        prefs.getKeys().where((k) => k.startsWith('visort_snap_')).toList();
    for (final k in legacy) {
      await prefs.remove(k);
    }
  } catch (_) {
    // 清理失败无碍(残留 key 只占几 KB,不影响功能)。
  }
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
