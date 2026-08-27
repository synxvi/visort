// Run 控制器 —— 执行批量操作（移动/删除），对应 Python /api/run + /api/run-stream
//
// 核心逻辑（app.py:691-774）:
//   1. 遍历 decisions
//   2. skip → 累加跳过
//   3. 源文件缺失 → 记 error
//   4. delete → fs.delete
//   5. move → 解析 destDir（三级回退）+ 冲突改名 + fs.move
//
// dest_dir 解析优先级（app.py:736-747）:
//   __root__  → destinationParent
//   folder_map[destKey] → 优先
//   dest_path → 回退
//   dest_label 匹配 → 最后回退
//
// 进度用 Stream<RunProgress> 推送（替代 SSE）：
//   每处理一张发 progress，结束发 done

import 'dart:async';
import 'dart:developer' show log;
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/run_log_store.dart';
import 'package:visort_flutter/core/fs/file_system_repository.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/core/fs/fs_provider.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/features/session/session_models.dart';

/// 进度事件
class RunProgress {
  const RunProgress({this.current, this.total, this.currentFile, this.done, this.results});
  final int? current;
  final int? total;
  final String? currentFile;
  final bool? done;
  final RunResults? results;
}

/// 执行结果汇总（对应 Python results dict）
class RunResults {
  const RunResults({
    this.moved = const [],
    this.deleted = const [],
    this.skipped = const [],
    this.errors = const [],
  });
  /// {file, to}
  final List<({String file, String to})> moved;
  final List<String> deleted;
  final List<String> skipped;
  /// {file, reason}
  final List<({String file, String reason})> errors;
}

class RunController {
  RunController(this._fs, [this._runLog, this.onApplied]);

  final FileSystemRepository _fs;

  /// Run 完成后回写成功项（moved+deleted 的 fileId 集）——SessionController
  /// 据此记 appliedIds，Review 重跑跳过已执行项（防重放误报）。
  final void Function(Set<String> applied)? onApplied;

  /// Run 历史落库(P3);null = 不记录(纯内存测试/降级)。
  final RunLogStore? _runLog;

  /// Run 防重入闸门：run() 是 async* 流，Results 屏退出即取消订阅；重入
  /// （退出后再 Run）会对全量决策重放一遍——操作幂等不损坏数据，但 Results
  /// 会被 move_failed/source_missing 误导性错误刷屏。in-flight 时直接返回
  /// 单事件错误流。async* 的 finally 保证任意取消路径都会复位。
  bool _running = false;

  /// 执行 RUN。返回进度 Stream。
  /// UI 用 StreamBuilder 订阅，结束事件含 results。
  Stream<RunProgress> run(SessionState session) async* {
    if (_running) {
      yield const RunProgress(
        done: true,
        results: RunResults(
          errors: [(file: 'run', reason: 'run_already_running')],
        ),
      );
      return;
    }
    _running = true;
    try {
      yield* _runInner(session);
    } catch (e) {
      // 流兜底：_runInner 任何未捕获异常（channel 层 PlatformException 等）
      // 若以 error 事件终止流，Results 屏 StreamBuilder 会永远停在执行中
      // 且 PopScope 困死用户——捕获后转为正常 done 事件 + run_failed 错误项。
      // 原始异常打到 dart log（保留可诊断信息），reason 用纯 i18n key——
      // results_screen 用 t(ref, e.reason) 翻译，拼接串会把 key 破坏直出英文。
      log('run failed: $e');
      yield RunProgress(
        done: true,
        results: RunResults(
          errors: [(file: 'run', reason: 'run_failed')],
        ),
      );
    } finally {
      _running = false;
    }
  }

  Stream<RunProgress> _runInner(SessionState session) async* {
    final decisions = session.decisions ?? {};

    if (decisions.isEmpty || session.images.isEmpty) {
      yield RunProgress(done: true, results: const RunResults());
      return;
    }

    // 构建 folder_map：当前 session 的 folders（key → path）。
    // 重复 key 保首插——与 SessionController.decide 的 firstWhere 语义对齐；
    // 若用 map 字面量（后者覆盖前者），decide 记录的目标与 Run 实际移动
    // 目标会在重复 key 时分叉（key 唯一性由 Home/编辑器保证，此处防御）。
    final folderMap = <String, String>{};
    for (final f in session.folders) {
      folderMap.putIfAbsent(f.key, () => f.path);
    }
    final destParent = session.destinationParent;

    final moved = <({String file, String to})>[];
    final deleted = <String>[];
    final skipped = <String>[];
    final errors = <({String file, String reason})>[];

    final entries = decisions.entries.toList();
    final total = entries.length;

    // MediaStore 批量语义：delete 和 move 决策先收集，循环结束后批量提交
    final pendingDeleteIds = <String>[];
    final pendingDeleteFileNames = <String, String>{}; // fileId → 显示名（label）
    // move 按 destDir(RELATIVE_PATH) 分组：<relativePath, List<fileId>>
    final pendingMoveByDest = <String, List<String>>{};

    // 系统同意弹窗的 URI 列表经 Intent ClipData 走 Binder 事务缓冲（~1MB），
    // 单批过大抛 TransactionTooLargeException → 整批失败。按 400/批分片
    // 提交（超限多弹几次窗），桌面端逐文件 move 分片无副作用。
    const kConsentBatchSize = 400;

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final fileId = entry.key;
      final decision = entry.value;

      // 查找图片引用
      final imgRef = session.images.firstWhere(
        (img) => img.id == fileId,
        orElse: () => ImageRef(root: session.sourceDir, relativePath: fileId, extension: ''),
      );

      // 发送进度（处理前）
      yield RunProgress(
        current: i + 1,
        total: total,
        currentFile: fileId,
      );

      // 已应用（上次 Run 成功执行过）→ 本次重跑跳过，不再重放——否则
      // 源已不存在（移走/删除）会误报 move_failed/source_missing。
      if (session.appliedIds.contains(fileId)) {
        skipped.add(fileId);
        continue;
      }

      // skip
      if (decision.action == DecisionAction.skip) {
        skipped.add(fileId);
        continue;
      }

      if (decision.action == DecisionAction.delete) {
        // 检查源文件存在（桌面端精确；MediaStore 端 deleteBatch 内部兜底）
        final exists = await _fs.exists(imgRef);
        if (!exists) {
          errors.add((file: fileId, reason: 'source_missing'));
          continue;
        }
        // 批量收集，不逐个删除（MediaStore createDeleteRequest 批量提交）
        pendingDeleteIds.add(imgRef.relativePath);
        pendingDeleteFileNames[fileId] = imgRef.label;
        continue;
      }

      if (decision.action == DecisionAction.move) {
        // 解析 destDir（三级回退；MediaStore 下 destDir = RELATIVE_PATH）
        final destDir = _resolveDestDir(decision, folderMap, destParent);
        if (destDir == null || destDir.isEmpty) {
          errors.add((file: fileId, reason: 'dest_unresolved'));
          continue;
        }
        // 按目标分组收集（批量移动，每组一次 createWriteRequest）
        pendingMoveByDest.putIfAbsent(destDir, () => []).add(imgRef.relativePath);
      }
    }

    // 批量移动（MediaStore createWriteRequest 按目标分组；桌面端逐个移）
    for (final entry in pendingMoveByDest.entries) {
      final destPath = entry.key;
      final ids = entry.value;
      final movedIds = <String>{};
      for (var i = 0; i < ids.length; i += kConsentBatchSize) {
        final chunk =
            ids.sublist(i, math.min(i + kConsentBatchSize, ids.length));
        movedIds.addAll(await _fs.moveBatch(chunk, destPath, session.sourceDir));
      }
      // 找回 fileId 记入结果
      for (final entry2 in entries) {
        if (entry2.value.action == DecisionAction.move) {
          final fileId = entry2.key;
          final imgRef = session.images.firstWhere(
            (img) => img.id == fileId,
            orElse: () => ImageRef(root: session.sourceDir, relativePath: fileId, extension: ''),
          );
          if (ids.contains(imgRef.relativePath)) {
            if (movedIds.contains(imgRef.relativePath)) {
              moved.add((file: fileId, to: entry2.value.destLabel ?? ''));
            } else {
              errors.add((file: fileId, reason: 'move_failed'));
            }
          }
        }
      }
    }

    // 批量删除（MediaStore createDeleteRequest 一次系统弹窗；桌面端逐个删）
    if (pendingDeleteIds.isNotEmpty) {
      final deletedIds = <String>{};
      for (var i = 0; i < pendingDeleteIds.length; i += kConsentBatchSize) {
        final chunk = pendingDeleteIds.sublist(
            i, math.min(i + kConsentBatchSize, pendingDeleteIds.length));
        deletedIds.addAll(await _fs.deleteBatch(chunk, session.sourceDir));
      }
      for (final entry in entries) {
        if (entry.value.action == DecisionAction.delete) {
          final fileId = entry.key;
          // 用 ImageRef.relativePath 匹配（与 pendingDeleteIds 同语义）
          final imgRef = session.images.firstWhere(
            (img) => img.id == fileId,
            orElse: () => ImageRef(root: session.sourceDir, relativePath: fileId, extension: ''),
          );
          if (deletedIds.contains(imgRef.relativePath)) {
            deleted.add(fileId);
          } else {
            errors.add((file: fileId, reason: 'delete_failed'));
          }
        }
      }
    }

    final results = RunResults(
      moved: moved,
      deleted: deleted,
      skipped: skipped,
      errors: errors,
    );

    // 回写成功项 → appliedIds（Review 重跑跳过已执行项）。
    onApplied?.call({...moved.map((m) => m.file), ...deleted});

    // Run 历史审计(P3):结束事件前落一行摘要。写库失败被 store 吞掉,
    // 绝不影响结果下发;空决策的提前 return 不经过此处,不记账。
    await _runLog?.insert(
      moved: results.moved.length,
      deleted: results.deleted.length,
      skipped: results.skipped.length,
      errors: results.errors,
    );

    yield RunProgress(done: true, results: results);
  }

  /// 解析目标目录（三级回退，app.py:736-747）
  String? _resolveDestDir(
    Decision decision,
    Map<String, String> folderMap,
    String destParent,
  ) {
    final destKey = decision.destKey ?? '';
    if (destKey == kRootDestKey) {
      return destParent;
    }
    // 优先 folder_map
    if (folderMap.containsKey(destKey)) {
      return folderMap[destKey];
    }
    // 回退 dest_path
    if ((decision.destPath ?? '').isNotEmpty) {
      return decision.destPath;
    }
    // 最后回退：按 dest_label 匹配（run 时无 templates，此处跳过）
    return null;
  }
}

final runControllerProvider = Provider<RunController>((ref) {
  return RunController(
    ref.watch(fileSystemRepositoryProvider),
    RunLogStore(ref.watch(databaseServiceProvider).database),
    (applied) =>
        ref.read(sessionControllerProvider.notifier).markApplied(applied),
  );
});
