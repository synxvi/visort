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

import 'package:flutter/foundation.dart'
    show DebugPrintCallback, debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

class ProbeLog with WidgetsBindingObserver {
  ProbeLog._();

  static const int _maxEntries = 4000;
  // 4000：StackTrace.current 多行打点（[DT] zi-init 带栈）整条进环，500 会
  // 把栈截到 #5 帧失去定位力（真机实证 2026-09-11 沉浸重建排查）。
  static const int _maxLineChars = 4000;
  static const int _rotateBytes = 1 << 20;

  /// 高频噪音前缀：不进环/不落盘（每秒多行，冲刷排查窗口）。
  /// 排查期临时高频打点在此登记，结案随打点一起撤（如 [HERO-CTL]）。
  static const List<String> _dropPrefixes = [];

  static final List<String> _ring = <String>[];
  static final Stopwatch _clock = Stopwatch();
  static DateTime? _wallClockBase;
  static IOSink? _sink;
  static File? _file;
  static int _flushed = 0;
  static DebugPrintCallback? _origPrint;
  static bool _ioFailed = false;
  static bool _rotating = false;
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
      final dropped = _ring.length - _maxEntries;
      _ring.removeRange(0, dropped);
      // _flushed 是「环内下标」：回绕删了 dropped 条，未刷条目整体前移，
      // 基准同步前移（模拟器实证：旧实现钉到环长 → _flushed 恒等于
      // _ring.length → 首次回绕后【永远不再落盘】，文件冻结在回绕时刻）。
      _flushed = _flushed - dropped;
      if (_flushed < 0) _flushed = 0;
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
      _file = file;
      _sink = file.openWrite(mode: FileMode.append);
      unawaited(_sink!.done.catchError((_) => _ioFailed = true));
      _sink!.writeln('== probe start ${_wallClockBase!.toIso8601String()} pid=$pid');
    } catch (_) {
      _ioFailed = true; // 只留内存环 + logcat
    }
  }

  /// 增量落盘（2s 定时 / 生命周期切换触发）。flush() 确保 IOSink 缓冲
  /// 真正写盘——事后拉取场景必须读到（IOSink 默认攒缓冲）。
  /// 写错误（磁盘满等）经 done/flush 的 catch 降级为纯内存环，不产生
  /// unhandled async exception。
  static void _flush() {
    final sink = _sink;
    if (sink == null || _rotating) return;
    var wrote = false;
    while (_flushed < _ring.length) {
      sink.writeln(_ring[_flushed++]);
      wrote = true;
    }
    if (wrote) {
      // flush 完成后才轮转：IOSink 的 flush/close 并发调用抛
      // 「Bad state: StreamSink is bound to a stream」（diag 实证），必须
      // 串行——轮转链在本轮 flush Future 之上。
      sink
          .flush()
          .then((_) => _maybeRotate(sink))
          .catchError((_) => _ioFailed = true);
    }
  }

  /// 运行期轮转：文件超 1MB 时切新文件（旧 → .old）。openWrite 只在
  /// 启动时检查一次超限，长会话高频打点（[SP] 洪水）会让文件无限增长
  /// ——轮转必须跟着 flush 走。切完后重写墙钟基准头。
  static Future<void> _maybeRotate(IOSink sink) async {
    _rotating = true;
    try {
      final file = _file;
      if (file == null || !await file.exists()) return;
      final len = await file.length();
      if (len <= _rotateBytes) return;
      // 不再 flush：调用方已在本轮 flush 完成后才进入这里（见 _flush 的
      // 串行注释）；close 自带缓冲冲刷语义。
      await sink.close();
      final old = File('${file.path}.old');
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
      _sink = file.openWrite(mode: FileMode.append);
      unawaited(_sink!.done.catchError((_) {}));
      _sink!.writeln('== probe start ${_wallClockBase!.toIso8601String()} pid=$pid');
    } catch (_) {
      // 轮转失败不致命：继续写原文件（可能超 1MB，可接受）。
    } finally {
      _rotating = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // paused 及更深状态：冲刷（进程随时可能被杀）。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // ⚠️ 只走 _flush()：其内部自带串行 flush 链（wrote 才 flush）。
      // 此前外部再 _sink?.flush() 与内部 Future 链并发 =「Bad state:
      // StreamSink is bound to a stream」（diag 实证，审查 P2）；且
      // _rotating 中外部 flush 会撞 close。wrote=false 时缓冲本空无需
      // 冲刷；IOSink 无同步 flush，内部链已是最快路径。
      _flush();
    }
  }

  // ── 测试缝（@visibleForTesting；生产不可用） ──

  /// 复位全部静态态并还原 debugPrint（widget test teardown 用）。
  @visibleForTesting
  static void debugReset() {
    _rotating = false;
    _ioFailed = false;
    _flushed = 0;
    _ring.clear();
    unawaited(_sink?.close().catchError((_) {}));
    _sink = null;
    _file = null;
    if (_origPrint != null) debugPrint = _origPrint!;
    _origPrint = null;
    _inited = false;
    _clock.reset();
    _wallClockBase = null;
  }

  /// 当前环内容快照。
  @visibleForTesting
  static List<String> get debugRing => List.unmodifiable(_ring);

  /// 已落盘游标（环内下标语义；恒 ≤ 环长）。
  @visibleForTesting
  static int get debugFlushed => _flushed;
}
