// [ente 移植] 相册网格主组件 —— 原文件：ente mobile/apps/photos/lib/ui/viewer/gallery/gallery.dart
//
// 精简（visort 最小适配）：
//   - 数据流：删除 asyncLoader/事件流（reloadEvent/forceReloadEvents/LocalPhotosAddedEvent/
//     FilesUpdatedEvent），外层直接给全量 allFiles，内部按 groupType 用同目录
//     gallery_groups.dart 分组（同步计算）。
//   - 删除：搜索过滤（hierarchical_search_util）、滑动划选 SwipeSelectionWrapper/
//     SwipeToSelectHelper、appBar 折叠（GalleryAppBarConfig/_GalleryAppBarScrollBody）、
//     EmptyState/ente_components、limitSelectionToOne、fileToJumpTo、tab 双击事件、
//     Christmas 临时 physics（ExponentialBouncingScrollPhysics → BouncingScrollPhysics）。
//   - 保留（核心价值）：CustomScrollView + SectionedListSliver + PinnedGroupHeader 吸附头
//     （AnimatedScale 1.0→1.2 拖动放大 200ms easeInOutSine + 尾部图标 fadeIn 200ms）+
//     CustomScrollBar 滚动条联动 + GalleryFileWidget + BouncingScrollPhysics + loading/empty。
//   - 状态包装：GalleryContextState/SelectionState 内层包；GalleryFilesState/
//     GalleryBoundariesProvider 由外层提供（Gallery 只读取/写入）。
//   - groupHeaderExtent 默认 32（GroupHeaderWidget 默认高；ente 用 getIntrinsicSizeOfWidget
//     实测）；groupType 不显示分组头时取 GalleryGroups.spacing（其构造断言要求）。
//   - onFileTap/onFileLongPress 透传给 GalleryFileWidget（经 GalleryGroups 转发）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

import 'boundary_reporter_mixin.dart';
import '../../shared/widgets/scroll_drag_handle.dart';
import 'gallery_boundaries_provider.dart';
import 'gallery_context_state.dart';
import 'gallery_files_inherited_widget.dart';
import 'gallery_groups.dart';
import 'group_header_widget.dart';
import 'group_type.dart';
import 'sectioned_sliver_list.dart';
import 'selected_files.dart';
import 'selection_state.dart';

/// 相册网格主组件（ente Gallery 移植）。
///
/// 外层直接提供全量 [allFiles]（已排序），内部按 [groupType] 分组渲染为
/// 吸附头的分组网格；长画廊带 [CustomScrollBar] 滚动条联动与拖动分区标题。
/// 选中态由 [selectedFiles] 驱动（多选模式见 [inSelectionMode]），
/// 点击/长按经 [onFileTap]/[onFileLongPress] 交回外层处理（选中切换/路由）。
class Gallery extends StatefulWidget {
  /// 全量图片（外层已排序；Gallery 只读，不持有事件流）。
  final List<MsImageInfo> allFiles;

  /// RepaintBoundary key 前缀（默认 'photo'，与 GalleryFileWidget 内部
  /// Hero tag 'photo_${file.id}' 保持一致）。
  final String tagPrefix;

  /// 分组类型（day/week/month/year/none）。
  final GroupType groupType;

  /// 多选状态；null 表示不启用多选。
  final SelectedFiles? selectedFiles;

  /// 网格列数（<4 时 GalleryFileWidget 用 512 缩略图，否则 256）。
  final int crossAxisCount;

  /// 升序（旧→新）为 true；默认 true。
  final bool sortOrderAsc;

  /// 分组头高度（默认 32 = GroupHeaderWidget 默认高；groupType 不显示
  /// 分组头时强制取 GalleryGroups.spacing）。
  final double groupHeaderExtent;

  /// 分组计算期间的占位（默认居中 loading 圈）。
  final Widget? loadingWidget;

  /// 空数据占位（默认居中"没有照片"）。
  final Widget? emptyState;

  /// 分组头是否显示全选入口。
  final bool showSelectAll;

  /// 是否处于多选模式（透传给 GalleryContextState，供子组件读取）。
  final bool inSelectionMode;

  /// 点击回调，透传给 GalleryFileWidget（外层处理选中切换/路由）。
  final ValueChanged<MsImageInfo>? onFileTap;

  /// 长按回调，透传给 GalleryFileWidget（外层处理进入多选等）。
  final ValueChanged<MsImageInfo>? onFileLongPress;

  final ScrollController? scrollController;

  const Gallery({
    required this.allFiles,
    /// 外部滚动控制器（外层 Hero 返回定位/拖拽手柄复用）；null 时内部自建。
    this.scrollController,
    this.tagPrefix = 'photo',
    this.groupType = GroupType.day,
    this.selectedFiles,
    this.crossAxisCount = 4,
    this.sortOrderAsc = true,
    this.groupHeaderExtent = 32.0,
    this.loadingWidget,
    this.emptyState,
    this.showSelectAll = true,
    this.inSelectionMode = false,
    this.onFileTap,
    this.onFileLongPress,
    super.key,
  });

  @override
  State<Gallery> createState() {
    return GalleryState();
  }
}

class GalleryState extends State<Gallery> {
  late ScrollController _scrollController;
  final scrollBarInUseNotifier = ValueNotifier<bool>(false);

  /// 网格上方 header 高度（visort 无 header，恒 0；保留 ente 字段以支持
  /// PinnedGroupHeader 的 _setCurrentGroupID 归一化）。
  final _headerHeightNotifier = ValueNotifier<double?>(0.0);

  late GroupType _groupType;
  late bool _sortOrderAsc;
  List<MsImageInfo> _allGalleryFiles = [];
  double? groupHeaderExtent;
  GalleryGroups? galleryGroups;
  InheritedGalleryBoundaries? _boundariesProvider;

  @override
  void initState() {
    super.initState();
    _scrollController = widget.scrollController ?? ScrollController();
    _sortOrderAsc = widget.sortOrderAsc;
    _groupType = widget.groupType;
    _allGalleryFiles = widget.allFiles;
    _setGroupHeaderExtent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _boundariesProvider?.setScrollController(_scrollController);
    });
  }

  @override
  void didUpdateWidget(covariant Gallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    var needsRegroup = false;
    // 视图切换（沉浸 ↔ 日期）复用同一 Gallery element 但传不同
    // scrollController：必须换绑，否则日期视图滚沉浸的 controller
    //（滚动/手柄/返回定位全错）。
    if (oldWidget.scrollController != widget.scrollController) {
      final old = _scrollController;
      _scrollController = widget.scrollController ?? ScrollController();
      _boundariesProvider?.setScrollController(_scrollController);
      if (oldWidget.scrollController == null) old.dispose();
      needsRegroup = true;
    }
    if (oldWidget.groupType != widget.groupType) {
      _groupType = widget.groupType;
      _setGroupHeaderExtent();
      needsRegroup = true;
    }
    if (oldWidget.sortOrderAsc != widget.sortOrderAsc) {
      _sortOrderAsc = widget.sortOrderAsc;
      needsRegroup = true;
    }
    if (!identical(oldWidget.allFiles, widget.allFiles)) {
      _allGalleryFiles = widget.allFiles;
      needsRegroup = true;
    }
    if (needsRegroup && mounted) {
      _updateGalleryGroups();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _boundariesProvider = GalleryBoundariesProvider.of(context);
    if (galleryGroups == null) {
      _updateGalleryGroups(callSetState: false);
    }
  }

  @override
  void dispose() {
    _boundariesProvider?.setScrollController(null);
    if (widget.scrollController == null) _scrollController.dispose();
    scrollBarInUseNotifier.dispose();
    _headerHeightNotifier.dispose();
    super.dispose();
  }

  void _setGroupHeaderExtent() {
    groupHeaderExtent = _groupType.showGroupHeader()
        ? widget.groupHeaderExtent
        : GalleryGroups.spacing;
  }

  void _updateGalleryGroups({bool callSetState = true}) {
    final groupHeaderExtent = this.groupHeaderExtent;
    if (groupHeaderExtent == null) return;
    galleryGroups = GalleryGroups(
      allFiles: _allGalleryFiles,
      groupType: _groupType,
      sortOrderAsc: _sortOrderAsc,
      widthAvailable: MediaQuery.sizeOf(context).width,
      selectedFiles: widget.selectedFiles,
      tagPrefix: widget.tagPrefix,
      crossAxisCount: widget.crossAxisCount,
      groupHeaderExtent: groupHeaderExtent,
      showSelectAll: widget.showSelectAll,
      // 无单选限制（visort 多选由外层 SelectedFiles 全权管理）。
      onFileTap: widget.onFileTap,
      onFileLongPress: widget.onFileLongPress,
    );
    if (callSetState && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    GalleryFilesState.of(context).setGalleryFiles = _allGalleryFiles;

    final widthAvailable = MediaQuery.sizeOf(context).width;
    if (galleryGroups == null) {
      _updateGalleryGroups(callSetState: false);
    }
    final groups = galleryGroups;
    if (groups == null) {
      return widget.loadingWidget ??
          const Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          );
    }

    if (groups.widthAvailable != widthAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateGalleryGroups();
        }
      });
    }

    final cellWidth =
        (MediaQuery.sizeOf(context).width -
                8 -
                (widget.crossAxisCount - 1) * GalleryGroups.spacing) /
        widget.crossAxisCount;

    final grid = GalleryContextState(
      sortOrderAsc: _sortOrderAsc,
      inSelectionMode: widget.inSelectionMode,
      type: _groupType,
      child: _allGalleryFiles.isEmpty
          ? (widget.emptyState ??
              const Center(
                child: Text(
                  '没有照片',
                  style: TextStyle(color: AppColors.muted, fontSize: 14),
                ),
              ))
          : Stack(
              clipBehavior: Clip.none,
              children: [
                CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  controller: _scrollController,
                  slivers: [
                    SectionedListSliver(
                      sectionLayouts: groups.groupLayouts,
                    ),
                  ],
                ),
                if (groups.groupType.showGroupHeader())
                  PinnedGroupHeader(
                    scrollController: _scrollController,
                    galleryGroups: groups,
                    headerHeightNotifier: _headerHeightNotifier,
                    scrollOffsetBase: 0,
                    topOffset: 0,
                    selectedFiles: widget.selectedFiles,
                    showSelectAll: widget.showSelectAll,
                    scrollbarInUseNotifier: scrollBarInUseNotifier,
                  ),
                // 右侧滚动拖拽手柄（主分支样式）：向下滚动后出现，可拖拽
                // 跳转。用照片总数 + 固定行高算进度，分母稳定（loadMore
                // 不跳）；日期分组混合 sliver（组头行高不同）用
                // monotonicExtent 单调化 maxScrollExtent 防抖。
                ScrollDragHandle(
                  controller: _scrollController,
                  totalItems: _allGalleryFiles.length,
                  rowExtent: cellWidth + GalleryGroups.spacing,
                  columns: widget.crossAxisCount,
                  viewportRows: 5,
                  monotonicExtent: true,
                ),
              ],
            ),
    );

    // 多选时向下提供 SelectionState（外层未包时自足；外层已包则内层遮蔽同实例）。
    final selectedFiles = widget.selectedFiles;
    return selectedFiles == null
        ? grid
        : SelectionState(selectedFiles: selectedFiles, child: grid);
  }
}

/// 吸附在顶部的当前分组头：滚动经过分组边界时切换标题，拖动滚动条时
/// AnimatedScale 1.0→1.2 放大（200ms easeInOutSine）+ 尾部图标 fadeIn（200ms）。
class PinnedGroupHeader extends StatefulWidget {
  final ScrollController scrollController;
  final GalleryGroups galleryGroups;
  final ValueNotifier<double?> headerHeightNotifier;
  final double scrollOffsetBase;
  final double topOffset;
  final SelectedFiles? selectedFiles;
  final bool showSelectAll;
  final ValueNotifier<bool> scrollbarInUseNotifier;
  static const kScaleDurationInMilliseconds = 200;
  static const kTrailingIconsFadeInDelayMs = 0;
  static const kTrailingIconsFadeInDurationMs = 200;

  const PinnedGroupHeader({
    required this.scrollController,
    required this.galleryGroups,
    required this.headerHeightNotifier,
    required this.scrollOffsetBase,
    required this.topOffset,
    required this.selectedFiles,
    required this.showSelectAll,
    required this.scrollbarInUseNotifier,
    super.key,
  });

  @override
  State<PinnedGroupHeader> createState() => _PinnedGroupHeaderState();
}

class _PinnedGroupHeaderState extends State<PinnedGroupHeader>
    with BoundaryReporter {
  String? currentGroupId;
  final _enlargeHeader = ValueNotifier<bool>(false);
  Timer? _enlargeHeaderTimer;
  InheritedGalleryBoundaries? _boundariesProvider;
  Timer? _timer;
  bool lastInUseState = false;
  bool fadeInTrailingIcons = false;
  @override
  void initState() {
    super.initState();
    widget.scrollbarInUseNotifier.addListener(scrollbarInUseListener);
    widget.scrollController.addListener(_setCurrentGroupID);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _setBaseTopBoundary();
      }
    });
    widget.headerHeightNotifier.addListener(_headerHeightNotifierListener);
  }

  @override
  void didUpdateWidget(covariant PinnedGroupHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _setCurrentGroupID();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _boundariesProvider = GalleryBoundariesProvider.of(context);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_setCurrentGroupID);
    widget.scrollbarInUseNotifier.removeListener(scrollbarInUseListener);
    widget.headerHeightNotifier.removeListener(_headerHeightNotifierListener);
    _enlargeHeader.dispose();
    _enlargeHeaderTimer?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _setCurrentGroupID() {
    if (widget.headerHeightNotifier.value == null) return;
    final scrollOffset = _scrollOffset;
    if (scrollOffset == null) return;
    // [visort 定制] 吸附判定提前 64（2×组头高）：ente 原版"组头完全滚出
    // 视口顶（scroll ≥ 组offset+32）才切换标题"——返回定位贴顶落点在
    // 组头 y=32（scroll=组offset-32），原判定会让 pinned 头停在上一组
    //（用户报"标题未正确替换"）；提前后 scroll ≥ 组offset-32 即显示当前
    // 组（normalized = scroll-32+64 = scroll+32 ≥ 组offset ⟺ scroll ≥
    // 组offset-32），吸附标题与第一行图片落点一致：不遮挡、同步切换。
    final normalizedScrollOffset =
        scrollOffset -
        widget.scrollOffsetBase -
        widget.headerHeightNotifier.value! +
        64;
    if (normalizedScrollOffset < 0) {
      _setBaseTopBoundary();
      if (currentGroupId == null) return;
      currentGroupId = null;
    } else {
      final groupScrollOffsets = widget.galleryGroups.groupScrollOffsets;

      int low = 0;
      int high = groupScrollOffsets.length - 1;
      int floorIndex = 0;

      if (normalizedScrollOffset < groupScrollOffsets.first) {
        return;
      }

      while (low <= high) {
        final mid = low + (high - low) ~/ 2;
        final midValue = groupScrollOffsets[mid];

        if (midValue <= normalizedScrollOffset) {
          floorIndex = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      if (currentGroupId ==
          widget
              .galleryGroups
              .scrollOffsetToGroupIdMap[groupScrollOffsets[floorIndex]]) {
        return;
      }
      currentGroupId = widget
          .galleryGroups
          .scrollOffsetToGroupIdMap[groupScrollOffsets[floorIndex]];
    }

    setState(() {});
    if (widget.scrollbarInUseNotifier.value) {
      if (Platform.isIOS) {
        HapticFeedback.selectionClick();
      } else {
        HapticFeedback.vibrate();
      }
    }
  }

  void _setBaseTopBoundary() {
    _boundariesProvider?.setTopBoundary(
      widget.topOffset > 0 ? widget.topOffset : null,
    );
  }

  double? get _scrollOffset {
    if (widget.scrollController.positions.length != 1) {
      return null;
    }
    return widget.scrollController.offset;
  }

  void scrollbarInUseListener() {
    _enlargeHeaderTimer?.cancel();
    if (widget.scrollbarInUseNotifier.value) {
      _enlargeHeader.value = true;
      lastInUseState = true;
      fadeInTrailingIcons = false;
    } else {
      _enlargeHeaderTimer = Timer(const Duration(milliseconds: 250), () {
        _enlargeHeader.value = false;
        if (lastInUseState) {
          fadeInTrailingIcons = true;
          Future.delayed(
            const Duration(
              milliseconds:
                  PinnedGroupHeader.kTrailingIconsFadeInDelayMs +
                  PinnedGroupHeader.kTrailingIconsFadeInDurationMs +
                  100,
            ),
            () {
              if (!mounted) return;
              setState(() {
                fadeInTrailingIcons = false;
              });
            },
          );
        }
        lastInUseState = false;
      });
    }
  }

  void _headerHeightNotifierListener() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      _setCurrentGroupID();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 与 visort AppBar（album_screen 用 AppColors.surface）同色，滚动内容
    // 从下方经过时被完全遮挡。
    final backgroundColor = AppColors.surface;
    final header = currentGroupId != null
        ? ValueListenableBuilder(
            valueListenable: _enlargeHeader,
            builder: (context, inUse, _) {
              return AnimatedScale(
                scale: inUse ? 1.2 : 1.0,
                alignment: Alignment.topLeft,
                duration: const Duration(
                  milliseconds: PinnedGroupHeader.kScaleDurationInMilliseconds,
                ),
                curve: Curves.easeInOutSine,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Positioned.fill(
                      child: ClipRect(
                        clipper: _PinnedHeaderBottomShadowClipper(),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ColoredBox(
                      color: backgroundColor,
                      child: boundaryWidget(
                        position: BoundaryPosition.top,
                        child: GroupHeaderWidget(
                          title: widget
                              .galleryGroups
                              .groupIdToGroupDataMap[currentGroupId!]!
                              .groupType
                              .getTitle(
                                context,
                                widget
                                    .galleryGroups
                                    .groupIDToFilesMap[currentGroupId]!
                                    .first,
                              ),
                          gridSize: widget.galleryGroups.crossAxisCount,
                          height: widget.galleryGroups.groupHeaderExtent,
                          filesInGroup: widget
                              .galleryGroups
                              .groupIDToFilesMap[currentGroupId!]!,
                          selectedFiles: widget.selectedFiles,
                          showSelectAll: widget.showSelectAll,
                          showTrailingIcons: !inUse,
                          isPinnedHeader: true,
                          fadeInTrailingIcons: fadeInTrailingIcons,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          )
        : const SizedBox.shrink();

    if (widget.topOffset == 0) {
      return header;
    }

    return Padding(
      padding: EdgeInsets.only(top: widget.topOffset),
      child: header,
    );
  }
}

class _PinnedHeaderBottomShadowClipper extends CustomClipper<Rect> {
  const _PinnedHeaderBottomShadowClipper();

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(0, size.height, size.width, size.height + 8);
  }

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) => false;
}
