// [ente 移植] 选择状态 —— 原文件：ente .../state/selection_state.dart

import 'package:flutter/material.dart';

import 'selected_files.dart';

// Gallery 与批量操作栏必须共享此 ancestor（全选）。
// ignore: must_be_immutable
class SelectionState extends InheritedWidget {
  final SelectedFiles selectedFiles;

  const SelectionState({
    super.key,
    required this.selectedFiles,
    required super.child,
  });

  static SelectionState? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SelectionState>();
  }

  static SelectionState? of(BuildContext context) {
    return maybeOf(context);
  }

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;
}
