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
import 'package:sortr_flutter/core/fs/file_system_repository.dart';
import 'package:sortr_flutter/core/fs/fs_provider.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
import 'package:sortr_flutter/features/session/session_models.dart';

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
  RunController(this._fs);

  final FileSystemRepository _fs;

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

      // 检查源文件存在
      final exists = await _fs.exists(imgRef);
      if (!exists) {
        errors.add((file: fileId, reason: 'source_missing'));
        continue;
      }

      if (decision.action == DecisionAction.delete) {
        final ok = await _fs.delete(imgRef);
        if (ok) {
          deleted.add(fileId);
        } else {
          errors.add((file: fileId, reason: 'delete_failed'));
        }
        continue;
      }

      if (decision.action == DecisionAction.move) {
        // 解析 destDir（三级回退）
        final destDir = _resolveDestDir(decision, folderMap, destParent);
        if (destDir == null || destDir.isEmpty) {
          errors.add((file: fileId, reason: 'dest_unresolved'));
          continue;
        }
        final result = await _fs.move(imgRef, destDir);
        if (result.success) {
          moved.add((file: fileId, to: decision.destLabel ?? ''));
        } else {
          errors.add((file: fileId, reason: result.error ?? 'move_failed'));
        }
      }
    }

    yield RunProgress(
      done: true,
      results: RunResults(
        moved: moved,
        deleted: deleted,
        skipped: skipped,
        errors: errors,
      ),
    );
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
  return RunController(ref.watch(fileSystemRepositoryProvider));
});
