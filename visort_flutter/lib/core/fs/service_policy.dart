// 加载请求优先级队列（对标 aves ServicePolicy）—— Dart 侧全局闸门。
//
// 现状问题：所有解码请求无差别 FIFO 压给 Kotlin 12 线程池——
//   ① 快滚时滚出屏的请求仍在跑，新滚入 cell 的请求排在后面（越滚越空）；
//   ② 128 占位图（要秒显）与 512 清晰图、viewer 当前大图与网格后台补清晰
//      同优先级，互相挤占；
//   ③ Flutter ImageStreamCompleter 无 cancel 概念，请求发出只能跑完。
//
// 解法：channel 调用前先过本队列（并发门 6）：
//   - 优先级调度：viewer 当前大图 50（压过 filmstream/占位 100，修打开
//     与放大卡顿）< 占位层 100 < 网格清晰层 200；
//   - 已在跑的请求不中断（MethodChannel 无法取消），结果照常进
//     ImageCache——滚回来直接命中，反而赚。
//
// ⚠️ 滚动挂起（aves pauseAbove/resumeAll）实测后【未启用】：快甩惯性
// 阶段持续挂起会露占位糊图（观感差）；拖拽手柄 jumpTo 每帧连发
// Start/Update/End 使挂起被同帧消掉从未生效——两种滚动行为不自洽。
// 用户偏好视觉连续，故只保留优先级 + 并发门。pauseAbove/resumeAll
// 保留在类里（单测覆盖），供未来区域解码等真正需要节流的场景。
//
// Kotlin 侧不动：Dart 门 6 生效后 ioExecutor(12)/信号量(12) 永不饱和，
// 退化为兜底。

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// 请求优先级（越小越先执行）。数值对齐 aves service_policy 的梯度设计。
abstract final class RequestPriority {
  /// viewer 当前大图：用户正盯着，必须压过一切（filmstrip 缩略图 96px
  /// 走 fastThumbnail=100，若大图低于它会被十几个 filmstrip 请求压在
  /// 门后 → 打开/放大卡顿）。
  static const int viewerImage = 50;

  /// 网格占位层（≤128px 快速小图，含 viewer filmstrip 96px）：
  /// 快滚中也不暂停，秒显。
  static const int fastThumbnail = 100;

  /// 网格清晰层（256/512）：快滚中挂起，停稳/慢滚时集中补。
  static const int sizedThumbnail = 200;
}

class _Task<T> {
  _Task(this.priority, this.job, [this.tag, this.enqueuedQlen, this.enqueuedAt]);
  final int priority;
  final Future<T> Function() job;
  /// 性能打点标识（可空）。
  final String? tag;
  final int? enqueuedQlen;
  final int? enqueuedAt;
  final Completer<T> completer = Completer<T>();
}

/// 微秒时钟（打点用；DateTime.now 避免引入额外依赖）。
int nowMicros() => DateTime.now().microsecondsSinceEpoch;

/// 加载管线打点开关（release 装机排查时置 true；平时 false 零开销）。
/// 输出格式：[SP] prio wait run qLen@in tag —— wait 为入队→启动的排队
/// 时长（队列拥塞指标），run 为 job 执行时长（解码/IO 本身），qLen@in
/// 为入队瞬间队列深度（洪泛指标）。
/// 排查实证（2026-08-28 快甩卡顿）：开启后真机复现一轮，wait/q 直接
/// 定位 resolve-洪泛根因；修复后同操作 avgWait 1701ms→0ms、maxQ 431→24。
const bool kServicePolicyPerfLog = true; // 排查期临时开启（缓存性能专项）

void _perfLog(_Task<dynamic> task, int startAt) {
  if (!kServicePolicyPerfLog) return;
  final t = task.tag;
  if (t == null) return;
  final doneAt = nowMicros();
  final wait = ((startAt - (task.enqueuedAt ?? startAt)) / 1000).round();
  final run = ((doneAt - startAt) / 1000).round();
  debugPrint(
      '[SP] p${task.priority} wait=${wait}ms run=${run}ms q=${task.enqueuedQlen} $t');
}

class ServicePolicy {
  ServicePolicy();

  /// 全局单例（生产用；测试可独立 new 实例避免跨用例状态泄漏）。
  static final ServicePolicy instance = ServicePolicy();

  /// 并发门：6（aves 取 4；实测 4 下快滚补清晰偏慢提到 6，Kotlin 12
  /// 线程池前仍有余量）。
  static const int maxConcurrent = 6;

  final List<_Task<dynamic>> _queue = [];
  final List<_Task<dynamic>> _suspended = [];
  int _running = 0;

  /// 暂停阈值：非 null 时 priority > 阈值的任务挂起（滚动中）。
  int? _pausedAbove;

  /// 入队执行 [job]，按 [priority] 调度；滚动暂停期间高优先级任务挂起
  /// 保序，resume 后继续。返回 job 的结果（job 的异常原样抛给调用方）。
  ///
  /// [tag]：性能打点标识（[perfLog]），定位快滚卡顿用，不影响调度。
  Future<T> run<T>(int priority, Future<T> Function() job, {String? tag}) {
    final task = _Task<T>(priority, job, tag, _queue.length, nowMicros());
    final pausedAbove = _pausedAbove;
    if (pausedAbove != null && priority > pausedAbove) {
      _suspended.add(task);
    } else {
      _queue.add(task);
      _schedule();
    }
    return task.completer.future;
  }

  /// 把队列中匹配的【未启动】任务移到队尾（温和重排：不取消、不报错、
  /// future 照常完成）。viewer pop 冲刷时把甩滑遗留的条 512/96 预取挪后，
  /// 让网格 cell 解码立即占满并发门——否则网格缩略图排在几十个无观众
  /// 积压之后，200ms 飞行窗口内出不了图，落位后陆续替换 = 网格闪烁。
  void deprioritizeQueued(bool Function(_Task<dynamic> task) test) {
    if (_queue.isEmpty) return;
    final moved = <_Task<dynamic>>[];
    final keep = <_Task<dynamic>>[];
    for (final t in _queue) {
      (test(t) ? moved : keep).add(t);
    }
    if (moved.isEmpty) return;
    _queue
      ..clear()
      ..addAll(keep)
      ..addAll(moved);
  }

  /// 滚动开始：把队列中 priority > [threshold] 的任务移出挂起（保序），
  /// 后续入队的高优先级任务直接进挂起区。
  void pauseAbove(int threshold) {
    if (_pausedAbove != null && _pausedAbove! <= threshold) return;
    _pausedAbove = threshold;
    final keep = <_Task<dynamic>>[];
    for (final task in _queue) {
      if (task.priority > threshold) {
        _suspended.add(task);
      } else {
        keep.add(task);
      }
    }
    _queue
      ..clear()
      ..addAll(keep);
  }

  /// 滚动结束：挂起任务放回队列继续调度。
  void resumeAll() {
    if (_pausedAbove == null && _suspended.isEmpty) return;
    _pausedAbove = null;
    _queue.addAll(_suspended);
    _suspended.clear();
    _schedule();
  }

  /// 调度循环：并发有空位就取队列中优先级最高（数值最小）的任务执行。
  /// 队列长度为滚动时的在途 miss 数（几十级），线性取 min 足够。
  void _schedule() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      var bestIdx = 0;
      for (var i = 1; i < _queue.length; i++) {
        if (_queue[i].priority < _queue[bestIdx].priority) bestIdx = i;
      }
      final task = _queue.removeAt(bestIdx);
      _running++;
      _runTask(task);
    }
  }

  Future<void> _runTask(_Task<dynamic> task) async {
    final startAt = nowMicros();
    try {
      final result = await task.job();
      if (!task.completer.isCompleted) task.completer.complete(result);
    } catch (e, st) {
      if (!task.completer.isCompleted) task.completer.completeError(e, st);
    } finally {
      _perfLog(task, startAt);
      _running--;
      _schedule();
    }
  }
}
