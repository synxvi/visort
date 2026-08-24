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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/run_log_store.dart';
import 'package:visort_flutter/core/fs/file_system_repository.dart';
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
  RunController(this._fs, [this._runLog]);

  final FileSystemRepository _fs;

  /// Run 历史落库(P3);null = 不记录(纯内存测试/降级)。
  final RunLogStore? _runLog;

  /// 执行 RUN。返回进度 Stream。
  /// UI 用 StreamBuilder 订阅，结束事件含 results。
  Stream<RunProgress> run(SessionState session) async* {
    final decisions = session.decisions ?? {};

    if (decisions.isEmpty || session.images.isEmpty) {
      yield RunProgress(done: true, results: const RunResults());
      return;
    }

    // 构建 folder_map：当前 session 的 folders（key → path）
    final folderMap = {for (final f in session.folders) f.key: f.path};
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
      final movedIds = await _fs.moveBatch(ids, destPath, session.sourceDir);
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
      final deletedIds = await _fs.deleteBatch(pendingDeleteIds, session.sourceDir);
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
  );
});
