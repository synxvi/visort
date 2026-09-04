// [ente 移植] 滑动多选状态机 —— 原文件：ente .../ui/viewer/gallery/swipe_to_select_helper.dart
//
// 以 [fromIndex, toIndex] 连续区间做差分：区间扩张补齐、区间回缩（反向
// 拖）撤销——来回滑不会反复翻转；每批实际变更触发一次 selectionClick 触觉。
// 方向恒为"选"（visort 定稿，与长按起手统一）：ente 原版"起点已选 → 取消
// 方向"语义弃用——从已勾选图出发轻扫 = 保持+扩展选中；取消靠单击/组头。
//
// 适配 visort：
//   - EnteFile → MsImageInfo；id→index 用 Map（万级列表免 indexOf 线性扫）。
//   - 选择变更不直改 SelectedFiles（ente 原版行为），改经 [onSelectionDelta]
//     回调外发——visort 选择真源在各 screen（_selectedIds），直改会导致批量
//     栏不启用/操作作用于空集（album_screen 注释实证过的坑）。selectedFiles
//     仅做只读查询（方向判定）与清空监听（外部退出勾选态时终止会话）。
//   - startSelection 幂等跳过：长按链路起点刚被 _enterSelectMode 选中，
//     forceSelecting 再选一次是 no-op，此时跳过触觉避免与长按 mediumImpact
//     双响。

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

import 'selected_files.dart';

/// 滑动多选区间状态机（一次拖选会话）。
class SwipeToSelectHelper {
  /// 与渲染网格严格同步的完整文件序列（分组只影响渲染，不影响线性 index）。
  final List<MsImageInfo> allFiles;

  /// 只读：方向判定 + 外部清空监听（变更一律走 [onSelectionDelta]）。
  final SelectedFiles selectedFiles;

  /// 拖选产生的增量（选/取消），由外层 screen 更新选择真源后回写渲染。
  final void Function(Set<MsImageInfo> toSelect, Set<MsImageInfo> toUnselect)
  onSelectionDelta;

  late final Map<String, int> _indexById;

  SwipeToSelectHelper({
    required this.allFiles,
    required this.selectedFiles,
    required this.onSelectionDelta,
  }) {
    _indexById = {
      for (var i = 0; i < allFiles.length; i++) allFiles[i].id: i,
    };
    selectedFiles.addListener(_onSelectionChanged);
  }

  int? _fromIndex;
  int? _lastToIndex;
  bool? _selecting;

  /// 拖选自身变更进行中（delta 外发窗口）。取消方向把最后一张选中图清空
  /// 时选择集瞬时为空——与"用户主动退出勾选态"在 _onSelectionChanged 里
  /// 不可区分，会误杀会话（起手图丢失 + 二次锚定方向翻转，真机 [SWIPE]
  /// 日志实证）。自身变更豁免 reset 判定。
  bool _selfMutation = false;

  /// 外发增量（经真源回写，通知同步回到 _onSelectionChanged）。
  void _applyDelta(Set<MsImageInfo> toSelect, Set<MsImageInfo> toUnselect) {
    _selfMutation = true;
    try {
      onSelectionDelta(toSelect, toUnselect);
    } finally {
      _selfMutation = false;
    }
  }

  /// 手势按下时的格（tile onPointerDown 报备）。激活瞬间手指往往已越过
  /// 起手格边界（首个显著 move 可达十几 px），起手格只收到 onExit、
  /// 首个滑入的邻格抢先锚定 → 起手图被跳过（"从当前图+1 开始"）。
  /// 锚定时优先消费本记录：起点恒为按下的那张图。
  MsImageInfo? _pendingStart;

  /// tile 按下时报备待定起点（每次按下覆盖，取最新手势）。
  void notePendingStart(MsImageInfo file) {
    _pendingStart = file;
    debugPrint('[SWIPE] pendingStart=${file.id}');
  }

  // isActive 可能滞后；指针手势态以 GallerySwipeHelper 的 notifier 为准。
  bool get isActive => _fromIndex != null;

  void startSelection(MsImageInfo file, {bool? forceSelecting}) {
    // 优先锚定按下时的格（轻扫起手图），报备仍在 index 空间内才生效。
    final triggerFile = file;
    final pending = _pendingStart;
    if (pending != null && _indexById.containsKey(pending.id)) {
      file = pending;
    }
    _pendingStart = null;
    final index = _indexById[file.id];
    if (index == null) return;

    _fromIndex = index;
    _lastToIndex = index;
    // visort 定稿：拖选恒为"选"（与长按起手 forceSelecting 语义统一）——
    // 从已勾选图出发轻扫 = 保持+扩展选中（用户预期"包含当前图"）。ente
    // 原版"起点已选 → 取消方向"语义弃用：取消靠单击/组头。
    _selecting = true;
    debugPrint('[SWIPE] start trigger=${triggerFile.id} anchor=${file.id} '
        'selecting=$_selecting');

    final alreadyInTargetState = selectedFiles.isFileSelected(file) ==
        _selecting;
    if (!alreadyInTargetState) {
      if (_selecting == true) {
        _applyDelta({file}, const {});
      } else {
        _applyDelta(const {}, {file});
      }
      HapticFeedback.selectionClick();
    }
    // 激活瞬间大步滑入邻格触发锚定：触发格 ≠ 起手格时把区间推进到
    // 触发格——否则该格只充当锚定触发器、自己不进选中区间（ente 原版
    // 缺陷，一次大步跨入时丢格）。
    final triggerIndex = _indexById[triggerFile.id];
    if (triggerIndex != null && triggerIndex != index) {
      _toggleSelectionToIndex(triggerIndex);
      _lastToIndex = triggerIndex;
    }
  }

  void updateSelection(MsImageInfo file) {
    if (_fromIndex == null) return;

    final toIndex = _indexById[file.id];
    if (toIndex == null || toIndex == _lastToIndex) return;
    debugPrint('[SWIPE] update ${file.id} from=$_fromIndex '
        'lastTo=$_lastToIndex → $toIndex');

    _toggleSelectionToIndex(toIndex);
    _lastToIndex = toIndex;
  }

  void endSelection() {
    _fromIndex = null;
    _lastToIndex = null;
    _selecting = null;
    _pendingStart = null;
  }

  // 反向拖会撤销新 [起点, 指针] 区间之外的上次变更（ente 原版语义）。
  void _toggleSelectionToIndex(int toIndex) {
    if (_fromIndex == null || _lastToIndex == null || _selecting == null) {
      return;
    }

    final fromIndex = _fromIndex!;
    final lastToIndex = _lastToIndex!;
    final selecting = _selecting!;

    Set<MsImageInfo> getRange(int start, int end) {
      if (start < end && start >= 0 && end <= allFiles.length) {
        return allFiles.getRange(start, end).toSet();
      }
      return {};
    }

    if (selecting) {
      if (toIndex <= fromIndex) {
        if (toIndex < lastToIndex) {
          final itemsToAdd = getRange(toIndex, min(fromIndex, lastToIndex));
          if (itemsToAdd.isNotEmpty) {
            _applyDelta(itemsToAdd, const {});
            HapticFeedback.selectionClick();
          }
          if (fromIndex < lastToIndex) {
            final itemsToRemove = getRange(fromIndex + 1, lastToIndex + 1);
            if (itemsToRemove.isNotEmpty) {
              _applyDelta(const {}, itemsToRemove);
              HapticFeedback.selectionClick();
            }
          }
        } else if (lastToIndex < toIndex) {
          final itemsToRemove = getRange(lastToIndex, toIndex);
          if (itemsToRemove.isNotEmpty) {
            _applyDelta(const {}, itemsToRemove);
            HapticFeedback.selectionClick();
          }
        }
      } else if (fromIndex < toIndex) {
        if (lastToIndex < toIndex) {
          final itemsToAdd = getRange(max(fromIndex, lastToIndex), toIndex + 1);
          if (itemsToAdd.isNotEmpty) {
            _applyDelta(itemsToAdd, const {});
            HapticFeedback.selectionClick();
          }
          if (lastToIndex < fromIndex) {
            final itemsToRemove = getRange(lastToIndex, fromIndex);
            if (itemsToRemove.isNotEmpty) {
              _applyDelta(const {}, itemsToRemove);
              HapticFeedback.selectionClick();
            }
          }
        } else if (toIndex < lastToIndex) {
          final itemsToRemove = getRange(toIndex + 1, lastToIndex + 1);
          if (itemsToRemove.isNotEmpty) {
            _applyDelta(const {}, itemsToRemove);
            HapticFeedback.selectionClick();
          }
        }
      }
    } else {
      if (toIndex <= fromIndex) {
        if (toIndex < lastToIndex) {
          final itemsToRemove = getRange(toIndex, min(fromIndex, lastToIndex));
          if (itemsToRemove.isNotEmpty) {
            _applyDelta(const {}, itemsToRemove);
            HapticFeedback.selectionClick();
          }
          if (fromIndex < lastToIndex) {
            final itemsToAdd = getRange(fromIndex + 1, lastToIndex + 1);
            if (itemsToAdd.isNotEmpty) {
              _applyDelta(itemsToAdd, const {});
              HapticFeedback.selectionClick();
            }
          }
        } else if (lastToIndex < toIndex) {
          final itemsToAdd = getRange(lastToIndex, toIndex);
          if (itemsToAdd.isNotEmpty) {
            _applyDelta(itemsToAdd, const {});
            HapticFeedback.selectionClick();
          }
        }
      } else if (fromIndex < toIndex) {
        if (lastToIndex < toIndex) {
          final itemsToRemove = getRange(
            max(fromIndex, lastToIndex),
            toIndex + 1,
          );
          if (itemsToRemove.isNotEmpty) {
            _applyDelta(const {}, itemsToRemove);
            HapticFeedback.selectionClick();
          }
          if (lastToIndex < fromIndex) {
            final itemsToAdd = getRange(lastToIndex, fromIndex);
            if (itemsToAdd.isNotEmpty) {
              _applyDelta(itemsToAdd, const {});
              HapticFeedback.selectionClick();
            }
          }
        } else if (toIndex < lastToIndex) {
          final itemsToAdd = getRange(toIndex + 1, lastToIndex + 1);
          if (itemsToAdd.isNotEmpty) {
            _applyDelta(itemsToAdd, const {});
            HapticFeedback.selectionClick();
          }
        }
      }
    }
  }

  void reset() {
    endSelection();
  }

  void _onSelectionChanged() {
    // 拖选自身的变更（取消方向把最后一张清空）不视为外部退出，会话保留
    //（见 _selfMutation 注释）。
    if (_selfMutation) return;
    if (selectedFiles.files.isEmpty && isActive) {
      debugPrint('[SWIPE] reset (外部清空)');
      reset();
    }
  }

  void dispose() {
    selectedFiles.removeListener(_onSelectionChanged);
  }
}
