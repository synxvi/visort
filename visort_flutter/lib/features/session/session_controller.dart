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


import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/profiles_service.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/session_store.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/features/session/session_models.dart';

/// __root__ 决策的 label 占位（UI 层用 i18n root_dir 翻译显示）
const kRootLabel = '@root@';

/// Session 控制器。状态为 SessionState。
///
/// 注意：扫描（scan）由 ScanController 负责，它会调用本控制器的 initFromScan。
/// 这样分离是因为扫描涉及 fs + profiles 协作，属于独立的 IO 流程。
///
/// P2 起决策/索引经 [SessionStore] 直写 SQLite(单行 upsert/UPDATE,微秒级,
/// 免防抖零丢失窗口);DB 不可用时 store noop,退化为纯内存(现状行为)。
/// seq 由内存 [_seqById] 分配:新 key 递增、重 decide 保持原值——与内存
/// LinkedHashMap「重复 put 保持首插位」语义严格对齐,恢复后 undo 不变味。
class SessionController extends Notifier<SessionState> {
  final ProfilesService _profilesService;

  SessionController(this._profilesService);

  /// 持久化 store(build 时经 Notifier ref 建;DB 降级时全 noop)。
  late final SessionStore _store;

  /// 决策插入序:image_id → seq。undo 删行、重 decide 保序全靠它。
  final Map<String, int> _seqById = {};

  /// 下一个新决策的 seq(恢复时初始化为 max+1)。
  int _decisionSeq = 0;

  @override
  SessionState build() {
    _store = SessionStore(ref.read(databaseServiceProvider).database);
    return const SessionState(
      decisions: null, // 延迟到首次 scan 才初始化
    );
  }

  // ───────────────────────── 扫描后初始化 ─────────────────────────

  /// 扫描完成后由 ScanController 调用，注入图片列表与配置。
  /// 会重置 decisions、计算 folders。
  ///
  /// [prebuiltFolders]：若传入则直接用（安卓 MediaStore 模式，folders 已由 Home 层构建好，
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
      decisions: {},
    );
    // 新扫描整体覆写旧会话(单活跃模型);序号计数归零。
    _seqById.clear();
    _decisionSeq = 0;
    _store.saveNewSession(state);
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
    final decisions = state.decisions ?? <String, Decision>{};
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
    // 持久化:重 decide 保持原 seq(LinkedHashMap 首插位语义);索引随写。
    final existing = _seqById[img.id];
    final seq = existing ?? _decisionSeq++;
    _seqById[img.id] = seq;
    _store.upsertDecision(img.id, decision, seq);
    _store.updateCurrentIndex(nextIndex);
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
    _seqById.remove(lastKey);
    _store.deleteDecision(lastKey);
    _store.updateCurrentIndex(newIndex);
    return true;
  }

  // ───────────────────────── 导航（Review 流程辅助） ─────────────────────────

  /// 跳到指定索引（Review → 继续分类时用）
  void goToIndex(int index) {
    if (index < 0 || index >= state.images.length) return;
    state = state.copyWith(currentIndex: index);
    _store.updateCurrentIndex(index);
  }

  /// 重置 session（RUN 执行后或重新扫描前）
  void reset() {
    state = const SessionState();
    _seqById.clear();
    _decisionSeq = 0;
    _store.clear();
  }

  // ───────────────────────── 会话恢复(P2) ─────────────────────────

  /// 是否有可恢复的持久化会话(Home 横条探测用)。
  Future<bool> hasPersistedSession() => _store.hasActive();

  /// 持久化会话摘要(Start 前恢复弹窗:总张数/已决策/进行到);无会话 null。
  Future<({int total, int decided, int currentIndex})?>
      persistedSummary() async {
    final r = await _store.summary();
    if (r == null) return null;
    // 快照头行可能过期(如 decision 行手工修正),口径以行数为准兜底。
    return (total: r.total, decided: r.decided, currentIndex: r.currentIndex);
  }

  /// 恢复上次会话(杀进程后)。成功则 state 就位、seq 计数重建,
  /// 返回 true;无会话/数据异常返回 false(Home 不显示横条)。
  Future<bool> restoreLastSession() async {
    final r = await _store.loadActive();
    if (r == null) return false;
    state = r.state;
    _seqById
      ..clear()
      ..addAll(r.seqById);
    _decisionSeq = r.nextSeq;
    return true;
  }

  /// 丢弃持久化会话(横条滑除)。不动内存活动会话——清的只是「中断记录」;
  /// 之后的正常扫描/Run 照旧(新扫描覆写,Run 后清库)。
  Future<void> discardPersistedSession() => _store.clear();

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
