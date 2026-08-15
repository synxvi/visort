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
    return SizedBox(
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
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: ValueListenableBuilder(
                      valueListenable: _areAllFromGroupSelectedNotifier,
                      builder: (context, dynamic value, _) {
                        return _buildSelectionIcon(value as bool);
                      },
                    ),
                  ),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.selectedFiles?.toggleGroupSelection(
                      widget.filesInGroup.toSet(),
                    );
                  },
                )
              : const SizedBox.shrink(),
          const SizedBox(width: 16),
        ],
      ),
    );
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
