// 搜索过滤项数据定义 —— 纯数据类，feature 层。
//
// [aves 对齐] Aves CollectionFilter 的轻量版：category = 维度，同维度
// 多选取并（OR）、跨维度取交（AND）；谓词简化为照片 id 集合包含。
// 2026-09 自 ui/screens/search_filter_chip.dart 下沉（审查 P2 分层反向
// 依赖：features/search 的 store 不得 import ui 层）；chip 组件继续在
// UI 层引用本类。

import 'package:flutter/material.dart' show IconData;

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
