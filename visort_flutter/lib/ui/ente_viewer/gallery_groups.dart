// [ente 移植] 网格分组计算 —— 原文件：ente .../models/gallery/gallery_groups.dart
// 适配：EnteFile→MsImageInfo（creationTime 微秒 = dateAddedMs 毫秒×1000）、
// DummyFile 删除（不做滑动划选，末尾行不满直接渲染）、Uuid→计数器、
// crossAxisCount 由外层传入（visort 无 localSettings）、currentUserID 删除。

import 'dart:core';

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

import 'fixed_extent_grid_row.dart';
import 'fixed_extent_section_layout.dart';
import 'gallery_file_widget.dart';
import 'group_header_widget.dart';
import 'group_type.dart';
import 'selected_files.dart';

class GalleryGroups {
  final List<MsImageInfo> allFiles;
  final GroupType groupType;
  final SelectedFiles? selectedFiles;
  final bool limitSelectionToOne;
  final String tagPrefix;
  final bool showSelectAll;
  final bool sortOrderAsc;
  final double widthAvailable;
  final double groupHeaderExtent;
  final int crossAxisCount;
  /// item 点击/长按回调（透传 GalleryFileWidget）。
  final ValueChanged<MsImageInfo>? onFileTap;
  final ValueChanged<MsImageInfo>? onFileLongPress;
  /// 组头点击（选择模式 toggle 该组）/长按（进入选择模式+全选）回调
  /// （透传 GroupHeaderWidget，aves 交互）。
  final ValueChanged<List<MsImageInfo>>? onGroupHeaderToggle;
  final ValueChanged<List<MsImageInfo>>? onGroupHeaderLongPress;

  GalleryGroups({
    required this.allFiles,
    required this.groupType,
    required this.widthAvailable,
    required this.selectedFiles,
    required this.tagPrefix,
    required this.crossAxisCount,
    this.sortOrderAsc = true,
    required this.groupHeaderExtent,
    required this.showSelectAll,
    this.limitSelectionToOne = false,
    this.onFileTap,
    this.onFileLongPress,
    this.onGroupHeaderToggle,
    this.onGroupHeaderLongPress,
  }) {
    init();
    if (!groupType.showGroupHeader()) {
      assert(
        groupHeaderExtent == spacing,
        '''groupHeaderExtent should be equal to spacing when group header is not shown''',
      );
    }
  }

  static const double spacing = 2.0;

  late final List<FixedExtentSectionLayout> _groupLayouts;

  final List<String> _groupIds = [];
  final Map<String, List<MsImageInfo>> _groupIdToFilesMap = {};
  final Map<
    String,
    ({GroupType groupType, int maxCreationTime, int minCreationTime})
  >
  _groupIdToGroupDataMap = {};
  final Map<double, String> _scrollOffsetToGroupIdMap = {};
  final Map<String, double> _groupIdToScrollOffsetMap = {};
  final List<double> _groupScrollOffsets = [];
  final List<({String groupID, String title})> _scrollbarDivisions = [];
  int _groupIdCounter = 0;

  List<String> get groupIDs => _groupIds;
  Map<String, List<MsImageInfo>> get groupIDToFilesMap => _groupIdToFilesMap;
  Map<String, ({GroupType groupType, int maxCreationTime, int minCreationTime})>
  get groupIdToGroupDataMap => _groupIdToGroupDataMap;
  Map<double, String> get scrollOffsetToGroupIdMap => _scrollOffsetToGroupIdMap;
  Map<String, double> get groupIdToScrollOffsetMap => _groupIdToScrollOffsetMap;
  List<FixedExtentSectionLayout> get groupLayouts => _groupLayouts;
  List<double> get groupScrollOffsets => _groupScrollOffsets;
  List<({String groupID, String title})> get scrollbarDivisions =>
      _scrollbarDivisions;

  double? getOffsetOfGroupContainingFile(MsImageInfo file) {
    final creationTime = _us(file);
    final groupId = _findGroupForCreationTime(creationTime);
    if (groupId == null) return null;
    return _groupIdToScrollOffsetMap[groupId];
  }

  /// 滚动位置 → 当前组 ID（组起始 offset ≤ pixels 的最后一组）。
  /// 拖动滚动条时的日期气泡用（aves crumbs 等价物）。
  String? groupIdAtOffset(double pixels) {
    final offsets = _groupScrollOffsets;
    if (offsets.isEmpty) return null;
    if (pixels <= offsets.first) {
      return _scrollOffsetToGroupIdMap[offsets.first];
    }
    // 二分找 ≤ pixels 的最大 offset（offsets 按列表顺序单调递增）。
    int lo = 0, hi = offsets.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (offsets[mid] <= pixels) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return _scrollOffsetToGroupIdMap[offsets[ans]];
  }

  /// 最近的组头 offset（拖动滚动条松手时的吸附目标，aves 同款）。
  /// 组数（按天）为几百级，线性扫一次成本可忽略。
  double? nearestGroupOffset(double pixels) {
    final offsets = _groupScrollOffsets;
    if (offsets.isEmpty) return null;
    var best = offsets.first;
    var bestDist = (pixels - best).abs();
    for (final o in offsets) {
      final d = (pixels - o).abs();
      if (d < bestDist) {
        bestDist = d;
        best = o;
      }
    }
    return best;
  }

  String? _findGroupForCreationTime(int creationTime) {
    if (_groupIds.isEmpty) return null;
    int left = 0;
    int right = _groupIds.length - 1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final groupId = _groupIds[mid];
      final groupData = _groupIdToGroupDataMap[groupId];
      if (groupData == null) return null;
      final maxTime = groupData.maxCreationTime;
      final minTime = groupData.minCreationTime;
      if (creationTime <= maxTime && creationTime >= minTime) {
        return groupId;
      } else if (sortOrderAsc) {
        if (creationTime < minTime) {
          right = mid - 1;
        } else if (creationTime > maxTime) {
          left = mid + 1;
        }
      } else {
        if (creationTime > maxTime) {
          right = mid - 1;
        } else if (creationTime < minTime) {
          left = mid + 1;
        }
      }
    }
    return null;
  }

  void init() {
    _buildGroups();
    _groupLayouts = _computeGroupLayouts();
  }

  /// dateAddedMs（毫秒）→ 微秒（与 ente creationTime 语义一致）。
  static int _us(MsImageInfo f) => f.dateAddedMs * 1000;

  List<FixedExtentSectionLayout> _computeGroupLayouts() {
    final showGroupHeader = groupType.showGroupHeader();
    int currentIndex = 0;
    double currentOffset = 0.0;
    final tileHeight =
        (widthAvailable - (crossAxisCount - 1) * spacing) / crossAxisCount;
    final groupLayouts = <FixedExtentSectionLayout>[];

    for (final groupID in _groupIdToFilesMap.keys) {
      final filesInGroup = _groupIdToFilesMap[groupID]!;
      final numberOfGridRows = (filesInGroup.length / crossAxisCount).ceil();
      final firstIndex = currentIndex == 0 ? currentIndex : currentIndex + 1;
      final lastIndex = firstIndex + numberOfGridRows;
      final minOffset = currentOffset;
      final maxOffset =
          minOffset +
          (numberOfGridRows * tileHeight) +
          (numberOfGridRows - 1) * spacing +
          groupHeaderExtent;
      final bodyFirstIndex = firstIndex + 1;

      groupLayouts.add(
        FixedExtentSectionLayout(
          firstIndex: firstIndex,
          lastIndex: lastIndex,
          minOffset: minOffset,
          maxOffset: maxOffset,
          headerExtent: groupHeaderExtent,
          tileHeight: tileHeight,
          spacing: spacing,
          builder: (context, rowIndex) {
            if (rowIndex == firstIndex) {
              if (showGroupHeader) {
                return GroupHeaderWidget(
                  title: _groupIdToGroupDataMap[groupID]!.groupType.getTitle(
                    context,
                    groupIDToFilesMap[groupID]!.first,
                  ),
                  gridSize: crossAxisCount,
                  filesInGroup: groupIDToFilesMap[groupID]!,
                  selectedFiles: selectedFiles,
                  showSelectAll: showSelectAll && !limitSelectionToOne,
                  onGroupToggle: onGroupHeaderToggle,
                  onGroupLongPress: onGroupHeaderLongPress,
                );
              } else {
                return const SizedBox(height: spacing);
              }
            } else {
              final gridRowChildren = <Widget>[];
              final firstIndexOfRowWrtFilesInGroup =
                  (rowIndex - bodyFirstIndex) * crossAxisCount;
              // 末尾行：可能不满 crossAxisCount 个（dummy 已删除，直接渲染实际项）。
              final count = rowIndex == lastIndex
                  ? filesInGroup.length - firstIndexOfRowWrtFilesInGroup
                  : crossAxisCount;
              for (int i = 0; i < count; i++) {
                final file = filesInGroup[firstIndexOfRowWrtFilesInGroup + i];
                gridRowChildren.add(
                  RepaintBoundary(
                    key: ValueKey(tagPrefix + file.id),
                    child: GalleryFileWidget(
                      file: file,
                      selectedFiles: selectedFiles,
                      photoGridSize: crossAxisCount,
                      onTap: onFileTap ?? (_) {},
                      onLongPress: onFileLongPress ?? (_) {},
                    ),
                  ),
                );
              }
              return FixedExtentGridRow(
                width: tileHeight,
                height: tileHeight,
                spacing: spacing,
                textDirection: TextDirection.ltr,
                children: gridRowChildren,
              );
            }
          },
        ),
      );

      _scrollOffsetToGroupIdMap[currentOffset] = groupID;
      _groupIdToScrollOffsetMap[groupID] = currentOffset;
      _groupScrollOffsets.add(currentOffset);

      currentIndex = lastIndex;
      currentOffset = maxOffset;
    }

    return groupLayouts;
  }

  void _buildGroups() {
    final yearsInGroups = <int>{};
    List<MsImageInfo> groupFiles = [];
    final allFilesLength = allFiles.length;

    if (groupType.showGroupHeader()) {
      for (int index = 0; index < allFilesLength; index++) {
        if (index > 0 &&
            !groupType.areFromSameGroup(allFiles[index - 1], allFiles[index])) {
          _createNewGroup(groupFiles, yearsInGroups);
          groupFiles = [];
        }
        groupFiles.add(allFiles[index]);
      }
      if (groupFiles.isNotEmpty) {
        _createNewGroup(groupFiles, yearsInGroups);
      }
    } else {
      // 无分组：切成固定大小块（性能，SectionedSliverList 按需 layout）。
      for (int i = 0; i < allFiles.length; i += 10 * crossAxisCount) {
        final end = (i + 10 * crossAxisCount < allFiles.length)
            ? i + 10 * crossAxisCount
            : allFiles.length;
        _createNewGroup(allFiles.sublist(i, end), yearsInGroups);
      }
    }
  }

  void _createNewGroup(List<MsImageInfo> groupFiles, Set<int> yearsInGroups) {
    final groupID = 'g${_groupIdCounter++}';
    final lastFile = groupFiles.last;
    _groupIds.add(groupID);
    _groupIdToFilesMap[groupID] = groupFiles;
    final firstCreationTime = _us(groupFiles.first);
    final lastCreationTime = _us(lastFile);
    final maxCreationTime = firstCreationTime > lastCreationTime
        ? firstCreationTime
        : lastCreationTime;
    final minCreationTime = firstCreationTime < lastCreationTime
        ? firstCreationTime
        : lastCreationTime;

    _groupIdToGroupDataMap[groupID] = (
      groupType: groupType,
      maxCreationTime: maxCreationTime,
      minCreationTime: minCreationTime,
    );

    if (groupType.timeGrouping()) {
      final yearOfGroup = DateTime.fromMicrosecondsSinceEpoch(
        _us(groupFiles.first),
      ).year;
      if (!yearsInGroups.contains(yearOfGroup)) {
        yearsInGroups.add(yearOfGroup);
        _scrollbarDivisions.add((groupID: groupID, title: yearOfGroup.toString()));
      }
    }
  }
}
