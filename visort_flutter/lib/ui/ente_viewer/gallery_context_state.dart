// [ente 移植] 网格上下文 —— 原文件：ente .../state/gallery_context_state.dart
// 简化：去掉 GalleryType（visort 无此概念）。

import 'package:flutter/material.dart';

import 'group_type.dart';

class GalleryContextState extends InheritedWidget {
  final bool sortOrderAsc;
  final bool inSelectionMode;
  final GroupType type;

  const GalleryContextState({
    this.inSelectionMode = false,
    this.type = GroupType.day,
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
        type != oldWidget.type;
  }
}
