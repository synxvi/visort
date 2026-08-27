// Results 屏幕 —— 执行 RUN + 显示结果（对应前端 #screen-results + run-stream）
//
// 进入时自动触发 run_controller.run(session)，用 StreamBuilder 显示进度，
// 完成后显示 4 项计数 + 错误明细，Continue 重置 session 回 Home。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/run/run_controller.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/router.dart';

class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key});

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  late Stream<RunProgress> _runStream;

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionControllerProvider);
    final runner = ref.read(runControllerProvider);
    _runStream = runner.run(session);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<RunProgress>(
        stream: _runStream,
        builder: (ctx, snap) {
          final failed = snap.hasError;
          final done = !failed && snap.hasData && snap.data!.done == true;
          // 执行中禁止退出：StreamBuilder dispose 会取消订阅，async* 流在
          // 下个 yield 点终止——批量 move/delete 根本不会执行，用户已确认
          // Run 却静默落空。done/失败后恢复返回（Continue/返回键均可离开）；
          // 失败也必须放行——否则流异常时用户被 PopScope 永久困死在转圈页。
          return PopScope(
            canPop: done || failed,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) toast(context, t(ref, 'run_in_progress'));
            },
            child: failed
                ? _ErrorView(error: snap.error)
                : !done
                    ? _ExecutingView(
                        current: snap.data?.current,
                        total: snap.data?.total,
                        currentFile: snap.data?.currentFile,
                      )
                    : _DoneView(results: snap.data!.results!),
          );
        },
      ),
    );
  }
}

class _ExecutingView extends ConsumerWidget {
  const _ExecutingView({this.current, this.total, this.currentFile});
  final int? current;
  final int? total;
  final String? currentFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = (current != null && total != null && total! > 0)
        ? current! / total!
        : 0.0;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                value: total == null ? null : pct,
              ),
            ),
            const SizedBox(height: 20),
            Text(t(ref, 'applying'),
                style: const TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 13,
                    color: AppColors.text)),
            if (current != null && total != null) ...[
              const SizedBox(height: 8),
              Text('$current / $total',
                  style: const TextStyle(
                      fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 11,
                      color: AppColors.muted)),
            ],
            if (currentFile != null) ...[
              const SizedBox(height: 4),
              Text('${t(ref, 'processing_of')}$currentFile',
                  style: const TextStyle(
                      fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 11,
                      color: AppColors.muted)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 流异常视图（run 流顶层兜底之外的最后防线）：可退出，不再困死。
class _ErrorView extends ConsumerWidget {
  const _ErrorView({this.error});
  final Object? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('⚠',
                    style: TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                        fontSize: 48, color: AppColors.danger)),
                const SizedBox(height: 16),
                Text(t(ref, 'run_failed'),
                    style: const TextStyle(
                        fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w800,
                        fontSize: 32)),
                const SizedBox(height: 8),
                if (error != null)
                  Text('$error',
                      style: const TextStyle(
                          fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                          color: AppColors.muted)),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(t(ref, 'back')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneView extends ConsumerWidget {
  const _DoneView({required this.results});
  final RunResults results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('✦',
                    style: TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                        fontSize: 48, color: AppColors.success)),
                const SizedBox(height: 16),
                Text(t(ref, 'done'),
                    style: const TextStyle(
                        fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w800,
                        fontSize: 32)),
                const SizedBox(height: 8),
                Text(t(ref, 'all_applied'),
                    style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)),
                const SizedBox(height: 32),
                _ResultRow(
                    icon: '✔',
                    label: t(ref, 'moved_label'),
                    count: results.moved.length,
                    color: AppColors.accent),
                _ResultRow(
                    icon: '✖',
                    label: t(ref, 'deleted_label'),
                    count: results.deleted.length,
                    color: AppColors.danger),
                _ResultRow(
                    icon: '⊘',
                    label: t(ref, 'skipped_label'),
                    count: results.skipped.length,
                    color: AppColors.muted),
                if (results.errors.isNotEmpty)
                  _ResultRow(
                      icon: '⚠',
                      label: t(ref, 'errors_label'),
                      count: results.errors.length,
                      color: AppColors.accent2),
                // 错误明细
                if (results.errors.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.danger),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: results.errors
                          .map((e) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                    '${e.file}: ${t(ref, e.reason)}',
                                    style: const TextStyle(
                                        fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                                        fontSize: 11,
                                        color: AppColors.danger)),
                              ))
                          .toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      // 重置 session 回 Home
                      ref.read(sessionControllerProvider.notifier).reset();
                      Navigator.pushNamedAndRemoveUntil(
                          context, AppRoutes.home, (_) => false);
                    },
                    child: Text(t(ref, 'continue_btn')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
  });
  final String icon;
  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(icon, style: TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: color, fontSize: 16)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 13)),
          ),
          Text('$count',
              style: TextStyle(
                  fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: color)),
        ],
      ),
    );
  }
}
