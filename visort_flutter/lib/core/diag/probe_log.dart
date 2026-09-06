// 真机时序排查的环形日志缓冲 + 落盘（2026-09，起因：hero pop flight 连环
// 时序 bug 定位中 logcat 窗口与用户操作反复错开 + debugPrint 节流致时间戳
// 失真，单轮「打点→装机→复现→读日志」5-10 分钟 × 6+ 轮）。
//
// 机制：接管全局 debugPrint——app 与 SDK 补丁（heroes.dart 等）里所有现有
// 打点零改动自动进环形缓冲（单调钟时间戳，不经节流队列）并批量落盘；
// 排查时用户**随时**复现，事后从设备拉文件即得完整时间线：
//   adb shell su -c 'cat /data/user/0/com.synxvi.visort/cache/probe.log'
//（非 root 调试包用 run-as；Windows 桌面为 %TEMP%/probe.log。）
//
// 代价控制：内存环 4000 条（单条截 500 字符）；文件 1MB 轮转（保留一份
// .old）；2 秒批量 flush + 生命周期 paused 时 flush（杀进程最多丢 2 秒）；
// 高频噪音行（帧 timings 批）不落盘只留 logcat。IO 失败静默降级为纯内存环。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

class ProbeLog with WidgetsBindingObserver {
  ProbeLog._();

  static const int _maxEntries = 4000;
  static const int _maxLineChars = 500;
  static const int _rotateBytes = 1 << 20;

  /// 高频噪音前缀：不进环/不落盘（每秒多行，冲刷排查窗口）。
  static const List<String> _dropPrefixes = ['[HERO-CTL] timings-batch'];

  static final List<String> _ring = <String>[];
  static final Stopwatch _clock = Stopwatch();
  static DateTime? _wallClockBase;
  static IOSink? _sink;
  static int _flushed = 0;
  static DebugPrintCallback? _origPrint;
  static bool _ioFailed = false;
  static bool _inited = false;

  /// main() 最早调用（ensureInitialized 之后）。幂等。
  static void init() {
    if (_inited) return;
    _inited = true;
    _wallClockBase = DateTime.now();
    _clock.start();
    _origPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      log(message ?? '');
      _origPrint?.call(message, wrapWidth: wrapWidth);
    };
    WidgetsBinding.instance.addObserver(ProbeLog._());
    Timer.periodic(const Duration(seconds: 2), (_) => _flush()); // 进程级常驻批量落盘
    _openSink();
  }

  /// 单调时间戳前缀（秒，相对 app 启动）：与帧时间戳/stopwatch 同域，
  /// 无节流延迟；文件首行的墙钟基准用于对齐「用户说的钟点」。
  static void log(String line) {
    if (_dropPrefixes.any(line.startsWith)) return;
    if (line.length > _maxLineChars) line = line.substring(0, _maxLineChars);
    _ring.add('+${(_clock.elapsedMicroseconds / 1e6).toStringAsFixed(3)} $line');
    if (_ring.length > _maxEntries) {
      _ring.removeRange(0, _ring.length - _maxEntries);
      // 环回绕时文件侧的下标基准失效：把 _flushed 钉到环长（余量重写）。
      _flushed = _flushed > _ring.length ? _ring.length : _flushed;
    }
  }

  static Future<void> _openSink() async {
    if (_ioFailed) return;
    try {
      // path_provider：Android=app cache 目录（Directory.systemTemp 在
      // Android 上不指向 cache，写入失败会被下面的降级分支静默吞掉）。
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/probe.log');
      if (await file.exists() && await file.length() > _rotateBytes) {
        final old = File('${dir.path}/probe.log.old');
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
      _sink = file.openWrite(mode: FileMode.append);
      _sink!.writeln(
        '== probe start ${_wallClockBase!.toIso8601String()} pid=$pid',
      );
    } catch (_) {
      _ioFailed = true; // 只留内存环 + logcat
    }
  }

  /// 增量落盘（2s 定时 / 生命周期切换触发）。flush() 确保 IOSink 缓冲
  /// 真正写盘——事后拉取场景必须读到（IOSink 默认攒缓冲）。
  static void _flush() {
    final sink = _sink;
    if (sink == null) return;
    var wrote = false;
    while (_flushed < _ring.length) {
      sink.writeln(_ring[_flushed++]);
      wrote = true;
    }
    if (wrote) sink.flush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // paused 及更深状态：同步冲刷（进程随时可能被杀）。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _flush();
      _sink?.flush();
    }
  }
}
