// [ente 移植] 分组头 —— 原文件：ente .../component/group/group_header_widget.dart
// 精简：ente_components 主题/SelectAllStatusIcon → 原生组件 + AppColors；
// showGalleryLayoutSettingCTA/吸附头放大图标 fadeIn 保留（PinnedGroupHeader 常量内联）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

import 'selected_files.dart';

class GroupHeaderWidget extends StatefulWidget {
  final String title;
  final int gridSize;
  final double? height;
  final List<MsImageInfo> filesInGroup;
  final SelectedFiles? selectedFiles;
  final bool showSelectAll;
  final bool showTrailingIcons;
  final bool isPinnedHeader;
  final bool fadeInTrailingIcons;

  /// 选择模式下点击组头（整行或全选圈）= 切换该组全选（aves 同款交互）。
  /// 外层统一维护选择真源（visort _selectedIds）后回写 selectedFiles；
  /// null 时回退 ente 原行为（直接 toggleGroupSelection，仅改渲染层）。
  final ValueChanged<List<MsImageInfo>>? onGroupToggle;

  /// 非选择模式长按组头 = 进入选择模式并全选该组（aves 同款，
  /// 一步到位的批量整理入口）。null 时无此交互。
  final ValueChanged<List<MsImageInfo>>? onGroupLongPress;

  const GroupHeaderWidget({
    super.key,
    required this.title,
    required this.gridSize,
    required this.filesInGroup,
    required this.selectedFiles,
    required this.showSelectAll,
    this.height,
    this.showTrailingIcons = true,
    this.isPinnedHeader = false,
    this.fadeInTrailingIcons = false,
    this.onGroupToggle,
    this.onGroupLongPress,
  });

  @override
  State<GroupHeaderWidget> createState() => _GroupHeaderWidgetState();
}

class _GroupHeaderWidgetState extends State<GroupHeaderWidget> {
  static const _selectionIconSize = 18.0;
  // PinnedGroupHeader 同款（ente gallery.dart 常量）。
  static const _kScaleDurationInMilliseconds = 200;
  static const _kTrailingIconsFadeInDurationMs = 200;

  late final ValueNotifier<bool> _areAllFromGroupSelectedNotifier;

  @override
  void initState() {
    super.initState();
    _areAllFromGroupSelectedNotifier = ValueNotifier(
      _areAllFromGroupSelected(),
    );
    widget.selectedFiles?.addListener(_selectedFilesListener);
  }

  @override
  void didUpdateWidget(covariant GroupHeaderWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filesInGroup != widget.filesInGroup) {
      _areAllFromGroupSelectedNotifier.value = _areAllFromGroupSelected();
    }
  }

  @override
  void dispose() {
    widget.selectedFiles?.removeListener(_selectedFilesListener);
    _areAllFromGroupSelectedNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 组头整行手势（aves 交互）：选择模式点击 = 切换该组全选（扩大点击面，
    // 不必精确点圈）；非选择模式长按 = 进入选择模式并全选该组。
    Widget header = SizedBox(
      height: widget.height ?? 32,
      child: Row(
        children: [
          // 网格贴屏边（spacing 2 无边距），组头 16 缩进偏多 → 8。
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                // 全局字体规则：数字/英文 Space Mono，中文回退思源。
                fontFamily: 'Space Mono',
                height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ),
          widget.showSelectAll
              ? GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleGroup,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: ValueListenableBuilder(
                      valueListenable: _areAllFromGroupSelectedNotifier,
                      builder: (context, dynamic value, _) {
                        return _buildSelectionIcon(value as bool);
                      },
                    ),
                  ),
                )
              : const SizedBox.shrink(),
          const SizedBox(width: 16),
        ],
      ),
    );
    final longPress = widget.onGroupLongPress;
    if (longPress != null) {
      header = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.showSelectAll ? _toggleGroup : null,
        onLongPress: () => longPress(widget.filesInGroup),
        child: header,
      );
    }
    return header;
  }

  /// 切换该组全选：上抛回调由外层维护选择真源（回写 selectedFiles）；
  /// 未提供回调时回退 ente 原行为（仅 toggleGroupSelection 渲染层）。
  void _toggleGroup() {
    HapticFeedback.selectionClick();
    final onGroupToggle = widget.onGroupToggle;
    if (onGroupToggle != null) {
      onGroupToggle(widget.filesInGroup);
    } else {
      widget.selectedFiles?.toggleGroupSelection(widget.filesInGroup.toSet());
    }
  }

  void _selectedFilesListener() {
    _areAllFromGroupSelectedNotifier.value = _areAllFromGroupSelected();
  }

  Widget _buildSelectionIcon(bool isSelected) {
    final icon = Icon(
      isSelected
          ? Icons.check_circle
          : Icons.radio_button_unchecked,
      size: _selectionIconSize,
      color: isSelected ? AppColors.accent : AppColors.muted,
    );
    if (!widget.fadeInTrailingIcons) return icon;
    return icon.animate().fadeIn(
          duration: const Duration(
            milliseconds: _kTrailingIconsFadeInDurationMs,
          ),
          delay: const Duration(milliseconds: _kScaleDurationInMilliseconds),
          curve: Curves.easeOut,
        );
  }

  bool _areAllFromGroupSelected() {
    final selectedFiles = widget.selectedFiles;
    if (selectedFiles == null || selectedFiles.files.isEmpty) return false;
    return selectedFiles.files.containsAll(widget.filesInGroup);
  }
}
