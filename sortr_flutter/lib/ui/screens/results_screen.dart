// Results 屏幕 —— 执行 RUN + 显示结果（对应前端 #screen-results + run-stream）
//
// 进入时自动触发 run_controller.run(session)，用 StreamBuilder 显示进度，
// 完成后显示 4 项计数 + 错误明细，Continue 重置 session 回 Setup。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/run/run_controller.dart';
import 'package:sortr_flutter/features/session/session_controller.dart';
import 'package:sortr_flutter/ui/router.dart';

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
          // 执行中
          if (!snap.hasData || snap.data!.done != true) {
            final progress = snap.data;
            return _ExecutingView(
              current: progress?.current,
              total: progress?.total,
              currentFile: progress?.currentFile,
            );
          }
          // 完成
          return _DoneView(results: snap.data!.results!);
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
                    fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 13,
                    color: AppColors.text)),
            if (current != null && total != null) ...[
              const SizedBox(height: 8),
              Text('$current / $total',
                  style: const TextStyle(
                      fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 11,
                      color: AppColors.muted)),
            ],
            if (currentFile != null) ...[
              const SizedBox(height: 4),
              Text('${t(ref, 'processing_of')}$currentFile',
                  style: const TextStyle(
                      fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 11,
                      color: AppColors.muted)),
            ],
          ],
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
                    style: TextStyle(
                        fontSize: 48, color: AppColors.success)),
                const SizedBox(height: 16),
                Text(t(ref, 'done'),
                    style: const TextStyle(
                        fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w800,
                        fontSize: 32)),
                const SizedBox(height: 8),
                Text(t(ref, 'all_applied'),
                    style: const TextStyle(color: AppColors.muted)),
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
                                        fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
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
                      // 重置 session 回 Setup
                      ref.read(sessionControllerProvider.notifier).reset();
                      Navigator.pushNamedAndRemoveUntil(
                          context, AppRoutes.setup, (_) => false);
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
          Text(icon, style: TextStyle(color: color, fontSize: 16)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback, fontSize: 13)),
          ),
          Text('$count',
              style: TextStyle(
                  fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: color)),
        ],
      ),
    );
  }
}
