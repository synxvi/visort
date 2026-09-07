// ProbeLog 落盘管线回归（模拟器实证 bug 的防回归）：
//  - 回绕死锁：旧实现 _flushed 钉到环长后恒等于 _ring.length，首次
//    回绕后永远不再落盘（probe.log 冻结在回绕时刻）——回绕前后各冲刷
//    一拍，文件必须持续增长且含最新条目；
//  - 运行期 1MB 轮转：长会话文件超限切 .old（旧实现只在启动时检查）。
// 用纯 test()（真实事件循环）：flush Timer 与文件 IO 都是真异步，
// fake async（testWidgets/pump）推进不了真实 IO future。
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/diag/probe_log.dart';

Future<void> _waitFlush() =>
    Future<void>.delayed(const Duration(milliseconds: 2300));

void main() {
  final dir = Directory.systemTemp.createTempSync('probe_log_test');

  tearDown(() => ProbeLog.debugReset());

  // path_provider platform channel → 测试临时目录。
  void mockPathProvider() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  }

  test('回绕不死锁：回绕后落盘持续、游标不卡死', timeout: const Timeout(Duration(seconds: 60)), () async {
    mockPathProvider();
    ProbeLog.init();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 第一拍：灌满并回绕（8000 > 2×4000），冲一次。
    for (var i = 0; i < 8000; i++) {
      debugPrint('a$i');
    }
    await _waitFlush();
    final file = File('${dir.path}/probe.log');
    final sizeAfterFirst = file.readAsLinesSync();
    expect(sizeAfterFirst.last, contains('a7999'), reason: '回绕后第一拍冲刷必须含最新条目');

    // 第二拍：再发新条目（此时环已回绕过——旧实现在此死后游标卡死）。
    for (var i = 0; i < 200; i++) {
      debugPrint('b$i');
    }
    await _waitFlush();
    final lines = file.readAsLinesSync();
    expect(
      lines.length,
      greaterThan(sizeAfterFirst.length),
      reason: '回绕后第二拍必须继续落盘（旧 bug：_flushed 钉到环长恒相等，'
          '文件冻结在首次回绕时刻）',
    );
    expect(lines.last, contains('b199'), reason: '最新条目必须已落盘');
    expect(
      ProbeLog.debugFlushed,
      lessThanOrEqualTo(ProbeLog.debugRing.length),
      reason: '游标是环内下标，恒不超环长',
    );
  });

  test('运行期 1MB 轮转：超限切 .old 并继续写', timeout: const Timeout(Duration(seconds: 90)), () async {
    mockPathProvider();
    ProbeLog.init();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 每条 ~500 字符（截断上限）：8000 条 ≈ 4MB，必触发轮转。
    final chunk = 'x' * 490;
    for (var i = 0; i < 8000; i++) {
      debugPrint('$i $chunk');
      if (i % 2000 == 1999) await _waitFlush();
    }
    await _waitFlush();

    final file = File('${dir.path}/probe.log');
    final old = File('${dir.path}/probe.log.old');
    expect(old.existsSync(), isTrue, reason: '超 1MB 必须轮转出 .old');
    expect(
      file.lengthSync(),
      lessThanOrEqualTo((1 << 20) + (500 << 10)),
      reason: '新文件应回到 ~1MB 量级（含轮转后新写入）',
    );
    expect(
      file.readAsLinesSync().last,
      contains('7999'),
      reason: '轮转后继续写最新条目',
    );
  });
}
