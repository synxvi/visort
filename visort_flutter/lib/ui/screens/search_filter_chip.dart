// 过滤 chip（[aves 对齐] AvesFilterChip 的 visort 风格版）
//
// 搜索页维度建议与已选过滤共用的 chip：图标 + 标签 + 数量；
// 选中态 accent 填充反白，再点取消选中。
// [SearchFilterData]（chip 的数据定义）已下沉 features 层
//（search_filter_data.dart，2026-09 分层修正）——此处 re-export 保持
// 既有 import 路径兼容。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/search/search_filter_data.dart';

export 'package:visort_flutter/features/search/search_filter_data.dart';

/// 搜索过滤 chip。
class FilterChipWidget extends StatelessWidget {
  const FilterChipWidget({
    super.key,
    required this.filter,
    this.selected = false,
    required this.onTap,
    this.selectedT,
  });

  final SearchFilterData filter;
  final bool selected;
  final VoidCallback onTap;

  /// 选中度插值（0=未选中色，1=选中色）：飞行动画期间传入动画值，
  /// 颜色/字重随飞行渐变（[用户定稿] 变色发生在动画期间而非点击瞬间，
  /// 起飞/落位两侧零跳变）。null 时退回 [selected] 布尔语义。
  final double? selectedT;

  @override
  Widget build(BuildContext context) {
    final t = (selectedT ?? (selected ? 1.0 : 0.0)).clamp(0.0, 1.0);
    final bg = Color.lerp(AppColors.surface, AppColors.accent, t)!;
    final borderColor = Color.lerp(AppColors.border, AppColors.accent, t)!;
    final fg = Color.lerp(AppColors.text, AppColors.bg, t)!;
    final iconColor = Color.lerp(AppColors.muted, AppColors.bg, t)!;
    final weight = FontWeight.lerp(FontWeight.w400, FontWeight.w700, t)!;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(filter.icon, size: 13, color: iconColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                filter.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontWeight: weight,
                  fontSize: 12,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
