// 排序切换按钮 —— 首页相册列表 / 相册内图片共用
//
// 交互：先选排序维度（名称 / 拍摄日期 / 入库日期），再选方向（升序 / 降序）。
// 菜单分两段（中间分隔线）：上段 = 维度（3 项），下段 = 方向（2 项），当前选中项打勾。
//
// 弹出方式：showSpringPopupFromAnchor —— 从按钮右下角（点击位置）弹簧展开，
// 与首页三点菜单 / 设置选择器动画完全统一（展开 1250ms 弹簧 / 收回 500ms）。
// 不用 PopupMenuButton：它的 showMenu 起点在屏幕边缘、转场是系统默认 fade。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/shared/widgets/spring_popup.dart';

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
    this.showDateTrashed = false,
  });

  final SortBy sortBy;
  final bool asc;
  final void Function(SortBy sortBy, bool asc) onChanged;
  /// 回收站视图：显示「按删除日期」(dateTrashed) 维度选项。
  /// 仅回收站有意义（DATE_EXPIRES 仅回收站项有值），其他视图不显示。
  final bool showDateTrashed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      // 与左侧返回箭头左右对称：箭头图标左缘距屏 16dp。
      // 本组件 icon Row（18+2+14=34dp）在 IconButton（min 48）内居中溢出，
      // 图标右缘距按钮右缘 48-(8+29)=11dp → 整体再左移 5dp 后右缘距屏 16dp。
      padding: const EdgeInsets.only(right: 5),
      child: IconButton(
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
        onPressed: () => _openMenu(context, ref),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context, WidgetRef ref) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    final menuWidth = _measureMenuWidth(context, ref);

    // value 格式："dim:name" / "dir:asc"
    final selected = await showSpringPopupFromAnchor<String>(
      context: context,
      barrierLabel: 'sort',
      // 弹簧起点 = 按钮右下角（点击位置），非屏幕边缘
      anchorGlobalDx: pos.dx + box.size.width,
      anchorGlobalDy: pos.dy + box.size.height,
      // 菜单右缘对齐按钮右缘
      menuLeft: (pos.dx + box.size.width - menuWidth)
          .clamp(0.0, screen.width - menuWidth),
      menuTop: pos.dy + box.size.height + 4,
      menuWidth: menuWidth,
      menuBuilder: (ctx) => Material(
        color: AppColors.surfaceElevated,
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 维度段 ──
            _dimRow(ctx, ref, Icons.sort_by_alpha, 'name', SortBy.name),
            _dimRow(
                ctx, ref, Icons.access_time, 'date_created', SortBy.dateCreated),
            _dimRow(ctx, ref, Icons.access_time, 'date_modified',
                SortBy.dateModified),
            // 回收站视图额外提供「按删除日期」（DATE_EXPIRES）
            if (showDateTrashed)
              _dimRow(ctx, ref, Icons.delete_outline, 'date_trashed',
                  SortBy.dateTrashed),
            // 自定义暗色分隔线
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: AppColors.border,
            ),
            // ── 方向段 ──
            _dirRow(ctx, ref, Icons.arrow_upward, 'asc', true),
            _dirRow(ctx, ref, Icons.arrow_downward, 'desc', false),
          ],
        ),
      ),
    );

    if (selected == null) return;
    final parts = selected.split(':');
    if (parts[0] == 'dim') {
      final newBy = SortBy.values.firstWhere(
        (s) => s.name == parts[1],
        orElse: () => sortBy,
      );
      onChanged(newBy, asc);
    } else if (parts[0] == 'dir') {
      onChanged(sortBy, parts[1] == 'asc');
    }
  }

  /// 维度行
  Widget _dimRow(
      BuildContext ctx, WidgetRef ref, IconData icon, String suffix, SortBy by) {
    final active = sortBy == by;
    return _MenuRow(
      icon: icon,
      active: active,
      label: t(ref, 'sort_by_$suffix'),
      onTap: () => Navigator.of(ctx).pop('dim:${by.name}'),
    );
  }

  /// 方向行
  Widget _dirRow(
      BuildContext ctx, WidgetRef ref, IconData icon, String suffix, bool ascVal) {
    final active = asc == ascVal;
    return _MenuRow(
      icon: icon,
      active: active,
      label: t(ref, 'sort_$suffix'),
      onTap: () => Navigator.of(ctx).pop('dir:$suffix'),
    );
  }

  /// 测量菜单内容宽度（弹簧锚点定位用）。
  /// 单行 = 左右内边距(16×2) + 图标(16) + 间距(8) + 文字宽度；取最宽行。
  double _measureMenuWidth(BuildContext context, WidgetRef ref) {
    const style = TextStyle(
      fontFamily: 'Space Mono',
      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
      fontSize: 12,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final labels = [
      t(ref, 'sort_by_name'),
      t(ref, 'sort_by_date_created'),
      t(ref, 'sort_by_date_modified'),
      if (showDateTrashed) t(ref, 'sort_by_date_trashed'),
      t(ref, 'sort_asc'),
      t(ref, 'sort_desc'),
    ];
    double maxText = 0;
    for (final l in labels) {
      final tp = TextPainter(
        text: TextSpan(text: l, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > maxText) maxText = tp.width;
    }
    return 16 * 2 + 16 + 8 + maxText;
  }

  IconData _byIcon(SortBy by) {
    switch (by) {
      case SortBy.name:
        return Icons.sort_by_alpha;
      case SortBy.dateCreated:
      case SortBy.dateModified:
        return Icons.access_time;
      case SortBy.dateTrashed:
        return Icons.delete_outline;
    }
  }
}

/// 菜单单项：图标 + 文本；选中态高亮（accent + 加粗）。点击 pop 出 value。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.active,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? AppColors.accent : AppColors.muted),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: const ['Noto Sans Mono CJK SC'],
                fontSize: 12,
                color: active ? AppColors.accent : AppColors.text,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
