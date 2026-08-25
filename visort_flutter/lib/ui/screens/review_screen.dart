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
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/review/review_controller.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/shared/widgets/kbd_badge.dart';
import 'package:visort_flutter/shared/widgets/middle_ellipsis_text.dart';
import 'package:visort_flutter/ui/router.dart';

/// 「返回」按钮 → 回 Sort 屏继续整理：先把游标回退到最后一张图（破坏
/// session 完成态）再 pop——sort 屏在 [SessionState.isComplete] 时渲染空白
/// 过渡页（见 sort_screen.dart），裸 pop 会落到那个空白页 → 黑屏。
void _continueSortAndPop(BuildContext context, WidgetRef ref) {
  final s = ref.read(sessionControllerProvider);
  if (s.totalCount > 0) {
    ref.read(sessionControllerProvider.notifier).goToIndex(s.totalCount - 1);
  }
  Navigator.pop(context);
}

/// 系统返回/手势、AppBar 返回箭头 → 直接回首页。session 保持完成态
/// （不回退游标）：首页「继续」或「开始」的恢复对话框会落回本审核屏
/// （P2 的 isComplete 恢复直达 review 语义），决策不丢。
void _goHomeAndPop(BuildContext context) {
  Navigator.popUntil(context, (r) => r.isFirst);
}

class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key});

  /// Run 防双击闸门：push /results 的转场（enteFadeRoute opaque:false）约
  /// 200ms 内 Review 仍在 hit-test 树、按钮可再点，双击会 push 两次 →
  /// 同批决策双执行（双系统弹窗 + 第二次全屏误导性错误）。Results pop
  /// 返回时（pushNamed Future 完成）复位，允许下一轮 Run。
  /// ReviewScreen 是无状态组件，闸门挂 static。
  static final ValueNotifier<bool> _runGate = ValueNotifier<bool>(false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(reviewStatsProvider);
    // 拦截系统返回（安卓物理/手势返回）→ 回首页（与 AppBar 箭头一致）；
    // 「返回」按钮才回 sort 继续整理（见 _continueSortAndPop）。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goHomeAndPop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _goHomeAndPop(context),
          ),
          // "审核变更"标题在右侧，与返回箭头同高（标准 toolbar 垂直居中）
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                t(ref, 'review_title'),
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
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
                  // 4 张统计卡片
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          value: stats.moved,
                          label: t(ref, 'moved'),
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          value: stats.deleted,
                          label: t(ref, 'deleted'),
                          color: AppColors.danger,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          value: stats.skipped,
                          label: t(ref, 'skipped'),
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          value: stats.undecided,
                          label: t(ref, 'unprocessed'),
                          color: AppColors.accent2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // 操作按钮：返回（淡黄·左）+ 应用所有变更（主题黄绿·右）
                  Row(
                    children: [
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.softYellow,
                          foregroundColor: AppColors.bg,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                        onPressed: () => _continueSortAndPop(context, ref),
                        child: Text(t(ref, 'back')),
                      ),
                      const Spacer(),
                      // ValueListenableBuilder：闸门置位后立即禁用按钮
                      //（转场期间本屏仍在树中、仍可命中点击）。
                      ValueListenableBuilder<bool>(
                        valueListenable: _runGate,
                        builder: (context, runStarted, _) => FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: AppColors.bg,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                          ),
                          onPressed: stats.total == 0 || runStarted
                              ? null
                              : () async {
                                  _runGate.value = true;
                                  await Navigator.pushNamed(
                                    context,
                                    AppRoutes.results,
                                  );
                                  _runGate.value = false;
                                },
                          child: Text(t(ref, 'run_apply')),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t(ref, 'review_desc'),
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.muted,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // 变更表格
                  _ChangesTable(stats: stats),
                  // 未处理文件
                  if (stats.undecided > 0) ...[
                    const SizedBox(height: 24),
                    Text(
                      t(ref, 'undecided_label'),
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        height: 1.2,
                        fontFamilyFallback: AppFonts.cjkFallback,
                        fontSize: 11,
                        color: AppColors.muted,
                      ),
                    ),
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
                            .map(
                              (id) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.bg,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Text(
                                  id,
                                  style: const TextStyle(
                                    fontFamily: 'Space Mono',
                                    height: 1.2,
                                    fontFamilyFallback: AppFonts.cjkFallback,
                                    fontSize: 11,
                                    color: AppColors.muted,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
  });
  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Space Mono',
              height: 1.2,
              fontFamilyFallback: AppFonts.cjkFallback,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Space Mono',
              height: 1.2,
              fontFamilyFallback: AppFonts.cjkFallback,
              fontSize: 11,
              color: AppColors.muted,
            ),
          ),
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
    // fileId(安卓=MediaStore _ID 数字)→ 真实文件名(含扩展名)label,显示用。
    final images = ref.watch(sessionControllerProvider).images;
    final labelOf = {for (final img in images) img.id: img.label};
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
                Expanded(flex: 3, child: _Header(t(ref, 'file'))),
                SizedBox(width: 72, child: _Header(t(ref, 'action'))),
                Expanded(flex: 5, child: _Header(t(ref, 'dest_col'))),
              ],
            ),
          ),
          // 行
          ...stats.moveEntries.map(
            (e) => _Row(
              file: labelOf[e.fileId] ?? e.fileId,
              badge: DecisionBadge(
                type: BadgeType.move,
                label: t(ref, 'moved'),
              ),
              dest: e.destPath,
            ),
          ),
          ...stats.deleteEntries.map(
            (f) => _Row(
              file: labelOf[f] ?? f,
              badge: DecisionBadge(
                type: BadgeType.delete,
                label: t(ref, 'deleted'),
              ),
              dest: '—',
            ),
          ),
          ...stats.skipEntries.map(
            (f) => _Row(
              file: labelOf[f] ?? f,
              badge: DecisionBadge(
                type: BadgeType.skip,
                label: t(ref, 'skipped'),
              ),
              dest: '—',
            ),
          ),
          if (stats.total == 0)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '—',
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                  color: AppColors.muted,
                ),
                textAlign: TextAlign.center,
              ),
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
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Space Mono',
        height: 1.2,
        fontFamilyFallback: AppFonts.cjkFallback,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: AppColors.muted,
        letterSpacing: 0.5,
      ),
    );
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
            child: _TappableText(
              message: file,
              child: MiddleEllipsisText(
                file,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          // 固定宽度容器，与表头对齐；badge 左对齐，不撑满
          SizedBox(
            width: 72,
            child: Align(alignment: Alignment.centerLeft, child: badge),
          ),
          Expanded(
            flex: 5,
            child: _TappableText(
              message: dest,
              child: Text(
                dest,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 点击弹完整值小气泡的包裹器(对标系统相册:点击截断文本弹气泡看全)。
/// 审核表格的文件名/目标位置用它包裹,点击显示完整内容。
class _TappableText extends StatelessWidget {
  const _TappableText({required this.message, required this.child});
  final String message;
  final Widget child;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: message,
    triggerMode: TooltipTriggerMode.tap,
    showDuration: const Duration(seconds: 3),
    preferBelow: false,
    decoration: BoxDecoration(
      color: Colors.black,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppColors.border),
    ),
    textStyle: const TextStyle(
      color: AppColors.text,
      fontSize: 13,
      fontFamily: 'Space Mono',
      height: 1.2,
      fontFamilyFallback: AppFonts.cjkFallback,
    ),
    child: child,
  );
}
