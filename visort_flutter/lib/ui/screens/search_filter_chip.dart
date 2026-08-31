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
    required this.selected,
    required this.onTap,
  });

  final SearchFilterData filter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.bg : AppColors.text;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(filter.icon, size: 13, color: selected ? fg : AppColors.muted),
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
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
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
