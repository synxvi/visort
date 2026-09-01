// 过滤 chip（[aves 对齐] AvesFilterChip 的 visort 风格版）
//
// 搜索页维度建议与已选过滤共用的 chip：图标 + 标签 + 数量；
// 选中态 accent 填充反白，再点取消选中。
// [SearchFilterData] 是 chip 的数据定义（[aves 对齐] CollectionFilter
// 的轻量版：category = 维度，同维度多选取并（OR），跨维度取交（AND）；
// 谓词简化为照片 id 集合包含）。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

/// 一个可选过滤项（维度值 → 照片 id 集合）。
class SearchFilterData {
  const SearchFilterData({
    required this.key,
    required this.label,
    required this.category,
    required this.icon,
    required this.ids,
  });

  final String key;
  final String label;
  final String category;
  final IconData icon;
  final Set<String> ids;

  bool contains(String id) => ids.contains(id);
}

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
