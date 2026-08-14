// [ente 移植] 多选状态 —— SelectedFiles（EnteFile → MsImageInfo，id 匹配）
// 原文件：ente mobile/apps/photos/lib/models/selected_files.dart

import 'package:flutter/foundation.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

class SelectedFiles extends ChangeNotifier {
  final files = <MsImageInfo>{};
  final lastSelectionOperationFiles = <MsImageInfo>{};

  void toggleSelection(MsImageInfo fileToToggle) {
    final alreadySelected = files.where((e) => e.id == fileToToggle.id);
    if (alreadySelected.isNotEmpty) {
      files.remove(alreadySelected.first);
    } else {
      files.add(fileToToggle);
    }
    lastSelectionOperationFiles.clear();
    lastSelectionOperationFiles.add(fileToToggle);
    notifyListeners();
  }

  void toggleGroupSelection(Set<MsImageInfo> filesToToggle) {
    if (filesToToggle.isEmpty) return;
    if (files.containsAll(filesToToggle)) {
      unSelectAll(filesToToggle);
    } else {
      selectAll(filesToToggle);
    }
  }

  void selectAll(Set<MsImageInfo> filesToSelect) {
    files.addAll(filesToSelect);
    lastSelectionOperationFiles.clear();
    lastSelectionOperationFiles.addAll(filesToSelect);
    notifyListeners();
  }

  void unSelectAll(Set<MsImageInfo> filesToUnselect, {bool skipNotify = false}) {
    files.removeWhere((file) => filesToUnselect.contains(file));
    lastSelectionOperationFiles.clear();
    lastSelectionOperationFiles.addAll(filesToUnselect);
    if (!skipNotify) notifyListeners();
  }

  bool isFileSelected(MsImageInfo file) => files.any((e) => e.id == file.id);

  bool isPartOfLastSelected(MsImageInfo file) =>
      lastSelectionOperationFiles.any((e) => e.id == file.id);

  void clearAll() {
    lastSelectionOperationFiles.addAll(files);
    files.clear();
    notifyListeners();
  }

  /// 先移除再变更（用于 == / hashCode 依赖的字段变更，visort 用 copyWith 场景）。
  void mutateFile(MsImageInfo file, void Function() mutate) {
    final wasInFiles = files.remove(file);
    final wasInLastOp = lastSelectionOperationFiles.remove(file);
    mutate();
    if (wasInFiles) files.add(file);
    if (wasInLastOp) lastSelectionOperationFiles.add(file);
    if (wasInFiles || wasInLastOp) notifyListeners();
  }

  void retainFiles(Set<MsImageInfo> filesToRetain) {
    files.retainAll(filesToRetain);
    notifyListeners();
  }

  void replaceSelection(Set<MsImageInfo> filesToSelect) {
    lastSelectionOperationFiles.clear();
    lastSelectionOperationFiles.addAll(files);
    files
      ..clear()
      ..addAll(filesToSelect);
    lastSelectionOperationFiles.addAll(filesToSelect);
    notifyListeners();
  }
}
