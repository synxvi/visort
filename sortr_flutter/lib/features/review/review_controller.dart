// Review 统计 —— 遍历 decisions 累加，对应前端 renderReview（index.html:2071-2099）
//
// 后端不预计算统计，前端遍历 decisions 累加 moves/deletes/skips，
// undecided = 扫描到但用户未决策的图片。
// 这里用纯函数从 SessionState 派生，无需独立 Provider（UI 直接 compute）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/features/session/session_controller.dart';
import 'package:sortr_flutter/features/session/session_models.dart';

class ReviewStats {
  const ReviewStats({
    required this.moved,
    required this.deleted,
    required this.skipped,
    required this.undecided,
    required this.moveEntries,
    required this.deleteEntries,
    required this.skipEntries,
    required this.undecidedIds,
  });

  final int moved;
  final int deleted;
  final int skipped;
  final int undecided;

  /// 明细：移动项（fileId → destLabel + destPath 全路径）
  final List<({String fileId, String destLabel, String destPath})> moveEntries;
  /// 删除项（fileId 列表）
  final List<String> deleteEntries;
  /// 跳过项（fileId 列表）
  final List<String> skipEntries;
  /// 未处理项（fileId 列表）
  final List<String> undecidedIds;

  int get total => moved + deleted + skipped + undecided;
}

/// 从当前 session 派生 Review 统计
ReviewStats computeReviewStats(SessionState session) {
  final decisions = session.decisions ?? {};
  final moves = <({String fileId, String destLabel, String destPath})>[];
  final deletes = <String>[];
  final skips = <String>[];

  decisions.forEach((fileId, d) {
    switch (d.action) {
      case DecisionAction.move:
        moves.add((
          fileId: fileId,
          destLabel: d.destLabel ?? '',
          destPath: d.destPath ?? '',
        ));
        break;
      case DecisionAction.delete:
        deletes.add(fileId);
        break;
      case DecisionAction.skip:
        skips.add(fileId);
        break;
    }
  });

  // undecided: images 中不在 decisions 的
  final decided = decisions.keys.toSet();
  final undecidedIds =
      session.images.where((img) => !decided.contains(img.id)).map((e) => e.id).toList();

  return ReviewStats(
    moved: moves.length,
    deleted: deletes.length,
    skipped: skips.length,
    undecided: undecidedIds.length,
    moveEntries: moves,
    deleteEntries: deletes,
    skipEntries: skips,
    undecidedIds: undecidedIds,
  );
}

/// Review 统计 Provider（跟随 session 变化自动重算）
final reviewStatsProvider = Provider<ReviewStats>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return computeReviewStats(session);
});
