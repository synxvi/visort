// Review 屏幕 —— 审核变更（对应前端 #screen-review）
//
// 还原 K3 UI:
//   - 标题 + 描述 + 返回按钮
//   - 4 张统计卡片（moves/deletes/skips/undecided）
//   - 变更表格（File / Action badge / Destination）
//   - 未处理文件折叠区
//   - Run 按钮（success 色）→ 执行 → 跳 Results

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/review/review_controller.dart';
import 'package:sortr_flutter/features/session/session_models.dart';
import 'package:sortr_flutter/shared/widgets/kbd_badge.dart';
import 'package:sortr_flutter/ui/router.dart';

class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(reviewStatsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(t(ref, 'review_title')),
        actions: [
          TextButton(
            onPressed: () => setLanguage(
                ref, ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh'),
            child: Text(
                ref.read(currentLanguageProvider) == 'zh' ? '中文' : 'EN'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t(ref, 'review_desc'),
                    style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                const SizedBox(height: 24),
                // 4 张统计卡片
                Row(
                  children: [
                    Expanded(
                        child: _StatCard(
                            value: stats.moved,
                            label: t(ref, 'moved'),
                            color: AppColors.accent)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _StatCard(
                            value: stats.deleted,
                            label: t(ref, 'deleted'),
                            color: AppColors.danger)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _StatCard(
                            value: stats.skipped,
                            label: t(ref, 'skipped'),
                            color: AppColors.muted)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _StatCard(
                            value: stats.undecided,
                            label: t(ref, 'unprocessed'),
                            color: AppColors.accent2)),
                  ],
                ),
                const SizedBox(height: 32),
                // 变更表格
                _ChangesTable(stats: stats),
                // 未处理文件
                if (stats.undecided > 0) ...[
                  const SizedBox(height: 24),
                  Text(t(ref, 'undecided_label'),
                      style: const TextStyle(
                          fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                          fontSize: 11,
                          color: AppColors.muted)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: stats.undecidedIds
                          .map((id) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.bg,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Text(id,
                                    style: const TextStyle(
                                        fontFamily: 'SpaceMono',
                                        fontFamilyFallback: AppFonts.cjkFallback,
                                        fontSize: 11,
                                        color: AppColors.muted)),
                              ))
                          .toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                // 操作按钮（Flexible 防止窄屏溢出）
                Row(
                  children: [
                    Flexible(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(t(ref, 'continue_sort'),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: AppColors.bg,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 14),
                      ),
                      onPressed: stats.total == 0
                          ? null
                          : () => Navigator.pushNamed(
                              context, AppRoutes.results),
                      child: Text(t(ref, 'run_apply')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.value, required this.label, required this.color});
  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value',
              style: TextStyle(
                  fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: color)),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(
                  fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 11,
                  color: AppColors.muted)),
        ],
      ),
    );
  }
}

class _ChangesTable extends ConsumerWidget {
  const _ChangesTable({required this.stats});
  final ReviewStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          // 表头
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                    flex: 3,
                    child: _Header(t(ref, 'file'))),
                SizedBox(
                    width: 72,
                    child: _Header(t(ref, 'action'))),
                Expanded(
                    flex: 5,
                    child: _Header(t(ref, 'dest_col'))),
              ],
            ),
          ),
          // 行
          ...stats.moveEntries.map((e) => _Row(
                file: e.fileId,
                badge: DecisionBadge(
                    type: BadgeType.move, label: t(ref, 'moved')),
                dest: e.destPath,
              )),
          ...stats.deleteEntries.map((f) => _Row(
                file: f,
                badge: DecisionBadge(
                    type: BadgeType.delete, label: t(ref, 'deleted')),
                dest: '—',
              )),
          ...stats.skipEntries.map((f) => _Row(
                file: f,
                badge: DecisionBadge(
                    type: BadgeType.skip, label: t(ref, 'skipped')),
                dest: '—',
              )),
          if (stats.total == 0)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('—',
                  style: const TextStyle(color: AppColors.muted),
                  textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
            letterSpacing: 0.5));
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.file, required this.badge, required this.dest});
  final String file;
  final Widget badge;
  final String dest;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Text(file,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback, fontSize: 12))),
          // 固定宽度容器，与表头对齐；badge 左对齐，不撑满
          SizedBox(
            width: 72,
            child: Align(
              alignment: Alignment.centerLeft,
              child: badge,
            ),
          ),
          Expanded(
              flex: 5,
              child: Text(dest,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback, fontSize: 12))),
        ],
      ),
    );
  }
}
