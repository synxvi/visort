// ServicePolicy 优先级队列行为测试。
//
// 验证：并发门、优先级抢占（高优插队）、滚动暂停/恢复保序、异常传播。

import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/service_policy.dart';

void main() {
  group('ServicePolicy', () {
    test('并发门：超出门限的任务等待，完成后继续', () async {
      final p = ServicePolicy();
      var running = 0;
      var maxRunning = 0;
      Future<int> job(int v) async {
        running++;
        maxRunning = maxRunning < running ? running : maxRunning;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        running--;
        return v;
      }

      final results = await Future.wait(
        List.generate(10, (i) => p.run(100, () => job(i))),
      );
      expect(results, List<int>.generate(10, (i) => i));
      // 门 4：任意时刻在跑 ≤ 4
      expect(maxRunning, lessThanOrEqualTo(ServicePolicy.maxConcurrent));
    });

    test("优先级：门空出时高优（数值小）先执行", () async {
      final p = ServicePolicy();
      final order = <int>[];
      // 先占满并发门
      final blockers = List.generate(
        ServicePolicy.maxConcurrent,
        (i) => p.run(500, () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return i;
        }),
      );
      // 低优先入队、高优后入队
      final low = p.run(
        200,
        () async => order.add(200),
      );
      final high = p.run(
        100,
        () async => order.add(100),
      );
      await Future.wait<dynamic>([...blockers, low, high]);
      expect(order.first, 100, reason: '高优先级应插队先执行');
    });

    test('滚动暂停：>阈值任务挂起，恢复后保序继续', () async {
      final p = ServicePolicy();
      final done = <int>[];
      // 占满门
      final blockers = List.generate(
        ServicePolicy.maxConcurrent,
        (i) => p.run(
          100,
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            return i;
          },
        ),
      );
      p.pauseAbove(150);
      // 滚动中：清晰层(200)入队 → 挂起
      final sized = p.run(
        200,
        () async => done.add(200),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(done, isEmpty, reason: '暂停期间挂起任务不应执行');

      p.resumeAll();
      await Future.wait([...blockers, sized]);
      expect(done, [200]);
    });

    test('滚动中占位层(≤阈值)不被暂停', () async {
      final p = ServicePolicy();
      final done = <int>[];
      p.pauseAbove(150);
      final fast = p.run(
        100,
        () async {
          done.add(100);
          return 100;
        },
      );
      await fast;
      expect(done, [100], reason: '占位层应绕过暂停直接调度');
      p.resumeAll();
    });

    test('异常传播给调用方，不阻塞后续任务', () async {
      final p = ServicePolicy();
      final failing = p.run<int>(
        100,
        () async => throw StateError('boom'),
      );
      final ok = p.run(
        100,
        () async => 42,
      );
      await expectLater(failing, throwsStateError);
      expect(await ok, 42);
    });
  });
}
