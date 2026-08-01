// Session 状态机 —— 核心整理逻辑（两端共享）
//
// 精确对齐 Python 版:
//   - decide():     四种动作 move/move-root/delete/skip（app.py:617-669）
//   - undo():       撤销最近一次决策（前端 undo()，按操作顺序）
//   - recomputeFolders(): 本地拼接路径（前端 recomputeFoldersFromTemplates）
//
// decide 命中规则（前端 handleKey 优先级）:
//   文件夹 key → Space(根目录) → delete → skip → undo
//
// __root__ 标签: Python 存中文"根目录"，这里存占位常量，UI 层翻译显示

import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
import 'package:sortr_flutter/features/session/session_models.dart';

/// __root__ 决策的 label 占位（UI 层用 i18n root_dir 翻译显示）
const kRootLabel = '@root@';

/// Session 控制器。状态为 SessionState。
///
/// 注意：扫描（scan）由 ScanController 负责，它会调用本控制器的 initFromScan。
/// 这样分离是因为扫描涉及 fs + profiles 协作，属于独立的 IO 流程。
class SessionController extends Notifier<SessionState> {
  final ProfilesService _profilesService;

  SessionController(this._profilesService);

  @override
  SessionState build() => const SessionState(
        decisions: null, // 延迟到首次 scan 才初始化
      );

  // ───────────────────────── 扫描后初始化 ─────────────────────────

  /// 扫描完成后由 ScanController 调用，注入图片列表与配置。
  /// 会重置 decisions、计算 folders。
  ///
  /// [prebuiltFolders]：若传入则直接用（安卓 MediaStore 模式，folders 已由 setup 层构建好，
  /// path 存 RELATIVE_PATH）。否则用 destinationParent + folderTemplates 走 computeDestinationFolders（Windows）。
  void initFromScan({
    required String sourceDir,
    required String destinationParent,
    required List<ImageRef> images,
    required List<FolderTemplate> folderTemplates,
    List<FolderDescriptor>? prebuiltFolders,
  }) {
    final folders = prebuiltFolders ??
        _profilesService.computeDestinationFolders(
            destinationParent, folderTemplates);
    state = SessionState(
      sourceDir: sourceDir,
      destinationParent: destinationParent,
      images: images,
      currentIndex: 0,
      folderTemplates: folderTemplates,
      folders: folders,
      decisions: LinkedHashMap<String, Decision>(),
    );
  }

  // ───────────────────────── 文件夹路径重算 ─────────────────────────

  /// 当目标父目录或模板变化时重算 folders（对应前端 recomputeFoldersFromTemplates）
  void recomputeFolders({String? destinationParent, List<FolderTemplate>? templates}) {
    final dest = destinationParent ?? state.destinationParent;
    final tmpl = templates ?? state.folderTemplates;
    final folders = _profilesService.computeDestinationFolders(dest, tmpl);
    state = state.copyWith(
      destinationParent: destinationParent ?? state.destinationParent,
      folderTemplates: templates ?? state.folderTemplates,
      folders: folders,
    );
  }

  // ───────────────────────── 决策 ─────────────────────────

  /// 对当前图片做决策。返回 {nextIndex, done}（对应 /api/decide）。
  ///
  /// [action] = move/delete/skip
  /// [destKey] 仅 move 需要：文件夹 key 或 kRootDestKey
  DecideResult decide(DecisionAction action, {String? destKey}) {
    final decisions = state.decisions ?? LinkedHashMap<String, Decision>(); // ignore: prefer_collection_literals
    final img = state.currentImage;
    if (img == null) {
      return DecideResult(nextIndex: state.currentIndex, done: true);
    }

    Decision decision;
    switch (action) {
      case DecisionAction.move:
        if (destKey == kRootDestKey) {
          decision = Decision.moveToRoot(
            rootPath: state.destinationParent,
            rootLabel: kRootLabel,
          );
        } else {
          final folder = state.folders.firstWhere(
            (f) => f.key == destKey,
            orElse: () => throw StateError('Unknown folder key: $destKey'),
          );
          decision = Decision.move(
            destKey: folder.key,
            destLabel: folder.label,
            destPath: folder.path,
          );
        }
        break;
      case DecisionAction.delete:
        decision = Decision.delete();
        break;
      case DecisionAction.skip:
        decision = Decision.skip();
        break;
    }

    decisions[img.id] = decision;
    final nextIndex = state.currentIndex + 1;
    final done = nextIndex >= state.images.length;
    state = state.copyWith(
      currentIndex: nextIndex,
      decisions: decisions,
    );
    return DecideResult(nextIndex: nextIndex, done: done);
  }

  // ───────────────────────── 撤销 ─────────────────────────

  /// 撤销：删除最后一个决策，并把 currentIndex 回退到那张图。
  /// 对应前端 undo()：若最后决策的图在当前之前，回退索引。
  /// 返回 true 表示成功撤销，false 表示无可撤销。
  bool undo() {
    final decisions = state.decisions;
    if (decisions == null || decisions.isEmpty) return false;

    // 取最后插入的 key（LinkedHashMap 保持插入序）
    final lastKey = decisions.keys.last;
    decisions.remove(lastKey);

    // 回退 currentIndex 到被撤销的那张图
    // 找到该图在 images 中的索引
    final imgIndex = state.images.indexWhere((img) => img.id == lastKey);
    final newIndex = imgIndex >= 0 ? imgIndex : state.currentIndex;

    state = state.copyWith(
      currentIndex: newIndex,
      decisions: decisions,
    );
    return true;
  }

  // ───────────────────────── 导航（Review 流程辅助） ─────────────────────────

  /// 跳到指定索引（Review → 继续分类时用）
  void goToIndex(int index) {
    if (index < 0 || index >= state.images.length) return;
    state = state.copyWith(currentIndex: index);
  }

  /// 重置 session（RUN 执行后或重新扫描前）
  void reset() {
    state = const SessionState();
  }

  // ───────────────────────── 便捷访问 ─────────────────────────

  /// 当前图片是否已有决策
  bool get currentHasDecision {
    final img = state.currentImage;
    if (img == null) return false;
    return state.decisions?.containsKey(img.id) ?? false;
  }

  /// 找快捷键对应的文件夹（键盘处理用）
  FolderDescriptor? folderByKey(String key) {
    try {
      return state.folders.firstWhere((f) =>
          f.key.toLowerCase() == key.toLowerCase());
    } catch (_) {
      return null;
    }
  }
}

// ───────────────────────── Provider 注册 ─────────────────────────

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(
  () => SessionController(ProfilesService()),
);
