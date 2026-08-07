// Session 数据模型 —— 精确对应 Python 版 session_state 与 decisions 结构
//
// 源: app.py session_state (332-344) + /api/decide 决策格式 (617-669)
//
// session_state 字段:
//   sourceDir / images / currentIndex / destinationParent /
//   folderTemplates / folders(含path) / decisions
//
// Decision 四种格式（C3）:
//   move-folder : {action:move, destKey, destLabel, destPath}
//   move-root   : {action:move, destKey:__root__, destLabel:'根目录', destPath:rootPath}
//   delete      : {action:delete}
//   skip        : {action:skip}

import 'dart:collection';

import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/profiles_service.dart' show FolderDescriptor;
import 'package:visort_flutter/core/fs/image_ref.dart';

/// 决策动作类型
enum DecisionAction { move, delete, skip }

/// 根目录的特殊 destKey（对应 Python '__root__'，前端 Space 键）
const kRootDestKey = '__root__';

/// 单张图片的决策。key 是图片相对路径（ImageRef.id）
class Decision {
  Decision({
    required this.action,
    this.destKey,
    this.destLabel,
    this.destPath,
  });

  final DecisionAction action;

  /// move 动作的目标文件夹快捷键；move-root 为 kRootDestKey；delete/skip 为 null
  final String? destKey;
  final String? destLabel;
  /// move 动作的目标完整路径
  final String? destPath;

  bool get isMove => action == DecisionAction.move;
  bool get isMoveToRoot => action == DecisionAction.move && destKey == kRootDestKey;

  factory Decision.move({required String destKey, required String destLabel, required String destPath}) {
    return Decision(action: DecisionAction.move, destKey: destKey, destLabel: destLabel, destPath: destPath);
  }

  factory Decision.moveToRoot({required String rootPath, required String rootLabel}) {
    return Decision(action: DecisionAction.move, destKey: kRootDestKey, destLabel: rootLabel, destPath: rootPath);
  }

  factory Decision.delete() => Decision(action: DecisionAction.delete);
  factory Decision.skip() => Decision(action: DecisionAction.skip);

  @override
  String toString() {
    switch (action) {
      case DecisionAction.move:
        return 'Decision(move → $destLabel @ $destPath)';
      case DecisionAction.delete:
        return 'Decision(delete)';
      case DecisionAction.skip:
        return 'Decision(skip)';
    }
  }
}

/// decide() 的返回（对应 /api/decide 的 next_index / done）
class DecideResult {
  const DecideResult({required this.nextIndex, required this.done});
  final int nextIndex;
  final bool done;
}

/// folder descriptor（模板 + 完整路径）—— 复用 config 的 FolderDescriptor

/// 单次扫描完成后的完整 session 状态
class SessionState {
  const SessionState({
    this.sourceDir = '',
    this.images = const [],
    this.currentIndex = 0,
    this.destinationParent = '',
    this.folderTemplates = const [],
    this.folders = const [],
    this.decisions,
  });

  /// 源目录根标识（Windows=路径 / 安卓=tree URI）
  final String sourceDir;
  /// 扫描到的图片列表（相对路径唯一）
  final List<ImageRef> images;
  /// 当前展示的图片索引
  final int currentIndex;
  /// 目标父目录根标识
  final String destinationParent;
  /// 当前 session 用的文件夹模板
  final List<FolderTemplate> folderTemplates;
  /// 完整文件夹描述符（含 path），由 recomputeFolders 计算
  final List<FolderDescriptor> folders;

  /// 决策字典：图片相对路径 → Decision。
  /// 用 LinkedHashMap 保持插入顺序，撤销时删除最后一个。
  final LinkedHashMap<String, Decision>? decisions;

  bool get isEmpty => images.isEmpty;
  int get totalCount => images.length;

  /// 所有图片已决策完毕（currentIndex 越过末尾）。
  /// Sort 屏据此自动进入 Review，不再停留多余的"审核变更"中间页
  /// （否则进度会显示成 (length+1)/length，如 5/4）。
  bool get isComplete => !isEmpty && currentIndex >= images.length;

  /// 当前图片（可能越界）
  ImageRef? get currentImage =>
      currentIndex >= 0 && currentIndex < images.length ? images[currentIndex] : null;

  /// 未决策的图片（扫描到但用户没操作）
  List<ImageRef> get undecided => images.where((img) => !(decisions?.containsKey(img.id) ?? false)).toList();

  /// 是否还有下一张
  bool get hasNext => currentIndex < images.length - 1;
  bool get hasPrev => currentIndex > 0;

  SessionState copyWith({
    String? sourceDir,
    List<ImageRef>? images,
    int? currentIndex,
    String? destinationParent,
    List<FolderTemplate>? folderTemplates,
    List<FolderDescriptor>? folders,
    LinkedHashMap<String, Decision>? decisions,
  }) {
    return SessionState(
      sourceDir: sourceDir ?? this.sourceDir,
      images: images ?? this.images,
      currentIndex: currentIndex ?? this.currentIndex,
      destinationParent: destinationParent ?? this.destinationParent,
      folderTemplates: folderTemplates ?? this.folderTemplates,
      folders: folders ?? this.folders,
      decisions: decisions ?? this.decisions,
    );
  }
}
