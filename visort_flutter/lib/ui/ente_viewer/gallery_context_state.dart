// [ente 移植] 网格上下文 —— 原文件：ente .../state/gallery_context_state.dart
// 简化：去掉 GalleryType（visort 无此概念）。

import 'package:flutter/material.dart';

import 'group_type.dart';

class GalleryContextState extends InheritedWidget {
  final bool sortOrderAsc;
  final bool inSelectionMode;
  final GroupType type;

  /// 收藏视图：所有项都是收藏项，红心徽标冗余 → 隐藏。
  final bool hideFavoriteBadge;

  const GalleryContextState({
    this.inSelectionMode = false,
    this.type = GroupType.day,
    this.hideFavoriteBadge = false,
    required this.sortOrderAsc,
    required super.child,
    super.key,
  });

  static GalleryContextState? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<GalleryContextState>();
  }

  @override
  bool updateShouldNotify(GalleryContextState oldWidget) {
    return sortOrderAsc != oldWidget.sortOrderAsc ||
        inSelectionMode != oldWidget.inSelectionMode ||
        type != oldWidget.type ||
        hideFavoriteBadge != oldWidget.hideFavoriteBadge;
  }
}
