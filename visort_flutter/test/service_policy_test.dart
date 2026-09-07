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

    test('五档优先级乱序入队：按 p50<p120<p200<p250<p300 执行', () async {
      // 矩阵 B：全档梯度插队次序（反序入队，出队必须严格按档从高到低）。
      final p = ServicePolicy();
      final order = <int>[];
      final blockers = List.generate(
        ServicePolicy.maxConcurrent,
        (i) => p.run(500, () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return i;
        }),
      );
      // 反序入队：最低档先到、最高档（当前页 p50）最后到——后来的必须
      // 插到一切之前（打开 viewer 时不被 filmstrip/预取压住的关键）。
      final all = <Future<dynamic>>[
        ...blockers,
        for (final prio in [300, 250, 200, 120, 50])
          p.run(prio, () async => order.add(prio)),
      ];
      await Future.wait<dynamic>(all);
      expect(
        order,
        [50, 120, 200, 250, 300],
        reason: '调度循环取 min：每个空位都先取当前最高优先级任务',
      );
    });

    test('bumpPriority：升级未启动任务插队，在跑任务不受影响', () async {
      // 矩阵 B：precacheImage 同 key 合并 listener 改不了已入队任务的
      // 优先级（p120 合并进早先 p250 会卡预取级）——bump 是唯一插队手段；
      // 已在跑的（MethodChannel 无法中断）不动，future 照常完成。
      final p = ServicePolicy();
      final order = <String>[];
      final blockers = List.generate(
        ServicePolicy.maxConcurrent,
        (i) => p.run(500, () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          return i;
        }),
      );
      final prefetch = p.run(250, () async => order.add('prefetch'));
      final sized = p.run(200, () async => order.add('sized'));
      // 停稳：把在排的 p250 预取升到当前页级 50 → 插到 p200 之前。
      p.bumpPriority((t) => t.priority == 250, 50);
      await Future.wait<dynamic>([...blockers, prefetch, sized]);
      expect(order, ['prefetch', 'sized'], reason: '升级后的任务须先于未升级的 p200');

      // 在跑任务 bump 不误伤：future 正常完成、结果不丢。
      final running = p.run(500, () async => 'ok');
      p.bumpPriority((t) => true, 10);
      expect(await running, 'ok', reason: '在跑任务不可被 bump 打断/破坏');
    });

    test('deprioritizeQueued：匹配未启动任务挪队尾，future 照常完成', () async {
      // viewer pop 冲刷场景：甩滑遗留的条 512/96 预取挪后，网格 cell
      // 解码立即占满并发门（200ms 飞行窗口内出图，落位不闪烁）。
      final p = ServicePolicy();
      final order = <int>[];
      final blockers = List.generate(
        ServicePolicy.maxConcurrent,
        (i) => p.run(500, () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          return i;
        }),
      );
      // 条预取先入队（p50 原本最优先），网格 cell 后入队（p100）——跨档
      // 让位：修前只挪位置、调度取 min 依然 p50 先出（单测实证）。
      final stripPrefetch = p.run(50, () async {
        order.add(50);
        return 'strip';
      });
      final gridCell = p.run(100, () async {
        order.add(100);
        return 'grid';
      });
      // pop 冲刷：条预取挪到队尾 → 网格 cell 先出队。
      p.deprioritizeQueued((t) => t.priority == 50);
      await Future.wait<dynamic>([...blockers, stripPrefetch, gridCell]);
      expect(order, [100, 50], reason: '挪尾后网格 cell 须先执行');
      expect(await stripPrefetch, 'strip', reason: '挪尾不丢 future 结果');
      expect(await gridCell, 'grid', reason: '正常任务结果不受影响');
    });
  });
}
