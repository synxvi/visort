// 排序切换按钮 —— 首页相册列表 / 相册内图片共用
//
// 交互：先选排序维度（名称 / 拍摄日期 / 入库日期），再选方向（升序 / 降序）。
// 实现为单个 PopupMenuButton，菜单分两段（中间分隔线）：
//   上段 = 维度（3 项），下段 = 方向（2 项），当前选中项打勾。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

/// 排序切换按钮。
///
/// [sortBy] / [asc] 为当前排序状态。
/// [onChanged] 在用户选择新排序时回调（维度 + 方向）。
class SortToggle extends ConsumerWidget {
  const SortToggle({
    super.key,
    required this.sortBy,
    required this.asc,
    required this.onChanged,
  });

  final SortBy sortBy;
  final bool asc;
  final void Function(SortBy sortBy, bool asc) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_byIcon(sortBy), size: 18, color: AppColors.text),
          const SizedBox(width: 2),
          Icon(
            asc ? Icons.arrow_upward : Icons.arrow_downward,
            size: 14,
            color: AppColors.accent,
          ),
        ],
      ),
      tooltip: t(ref, 'album_sort'),
      color: AppColors.surface,
      position: PopupMenuPosition.under,
      itemBuilder: (ctx) => [
        // ── 维度段 ──
        _dimItem(ref, 'name', SortBy.name),
        _dimItem(ref, 'date_created', SortBy.dateCreated),
        _dimItem(ref, 'date_modified', SortBy.dateModified),
        // 自定义暗色分隔线（PopupMenuDivider 默认过亮）
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          height: 1,
          child: Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            color: AppColors.border,
          ),
        ),
        // ── 方向段 ──
        _dirItem(ref, 'asc', true),
        _dirItem(ref, 'desc', false),
      ],
      onSelected: (value) {
        // value 格式："dim:name" / "dir:asc"
        final parts = value.split(':');
        if (parts[0] == 'dim') {
          final newBy = SortBy.values.firstWhere(
            (s) => s.name == parts[1],
            orElse: () => sortBy,
          );
          onChanged(newBy, asc);
        } else if (parts[0] == 'dir') {
          onChanged(sortBy, parts[1] == 'asc');
        }
      },
    );
  }

  IconData _byIcon(SortBy by) {
    switch (by) {
      case SortBy.name:
        return Icons.sort_by_alpha;
      case SortBy.dateCreated:
      case SortBy.dateModified:
        return Icons.access_time;
    }
  }

  /// 维度菜单项
  PopupMenuItem<String> _dimItem(
      WidgetRef ref, String suffix, SortBy by) {
    final active = sortBy == by;
    return PopupMenuItem<String>(
      value: 'dim:${by.name}',
      child: Row(
        children: [
          Icon(
            active ? Icons.check : Icons.sort_by_alpha,
            size: 16,
            color: active ? AppColors.accent : AppColors.muted,
          ),
          const SizedBox(width: 8),
          Text(
            t(ref, 'sort_by_$suffix'),
            style: TextStyle(
              fontSize: 12,
              color: active ? AppColors.accent : AppColors.text,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  /// 方向菜单项
  PopupMenuItem<String> _dirItem(WidgetRef ref, String suffix, bool ascVal) {
    final active = asc == ascVal;
    return PopupMenuItem<String>(
      value: 'dir:$suffix',
      child: Row(
        children: [
          Icon(
            ascVal ? Icons.arrow_upward : Icons.arrow_downward,
            size: 16,
            color: active ? AppColors.accent : AppColors.muted,
          ),
          const SizedBox(width: 8),
          Text(
            t(ref, 'sort_$suffix'),
            style: TextStyle(
              fontSize: 12,
              color: active ? AppColors.accent : AppColors.text,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
