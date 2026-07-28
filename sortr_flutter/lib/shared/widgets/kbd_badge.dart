// Kbd 与 Badge 组件 —— 快捷键标签 + 决策徽章（对应前端 .kbd / .badge）

import 'package:flutter/material.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

/// 快捷键标签（对应 .kbd 样式）
class Kbd extends StatelessWidget {
  const Kbd({super.key, required this.label, this.highlight = false});
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? AppColors.accent : AppColors.surface,
        border: Border.all(
          color: highlight ? AppColors.accent : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: highlight ? AppColors.bg : AppColors.text,
        ),
      ),
    );
  }
}

/// 决策徽章（对应 .badge-move / .badge-delete / .badge-skip）
class DecisionBadge extends StatelessWidget {
  const DecisionBadge({super.key, required this.type, required this.label});
  final BadgeType type;
  final String label;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (type) {
      BadgeType.move => (AppColors.badgeMove, AppColors.accent),
      BadgeType.delete => (AppColors.badgeDelete, AppColors.danger),
      BadgeType.skip => (AppColors.badgeSkip, AppColors.text),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

enum BadgeType { move, delete, skip }
