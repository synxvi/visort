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
//     CustomScrollBar 滚动条联动（该类已删——visort 实际用 scroll_drag_handle，
//     2026-09 审查 F22 死代码清理）+ GalleryFileWidget + BouncingScrollPhysics + loading/empty。
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
import 'package:visort_flutter/shared/widgets/scroll_drag_handle.dart';
import 'gallery_boundaries_provider.dart';
import 'gallery_context_state.dart';
import 'gallery_files_inherited_widget.dart';
import 'gallery_groups.dart';
import 'group_header_widget.dart';
import 'group_type.dart';
import 'sectioned_sliver_list.dart';
import 'selected_files.dart';
import 'selection_state.dart';
import 'swipe_selection_wrapper.dart';
import 'swipe_to_select_helper.dart';

/// 相册网格主组件（ente Gallery 移植）。
///
/// 外层直接提供全量 [allFiles]（已排序），内部按 [groupType] 分组渲染为
/// 吸附头的分组网格；长画廊的滚动条联动用 ScrollDragHandle（原
/// CustomScrollBar 已删，2026-09 审查 F22 死代码清理）。
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

  /// 收藏视图：隐藏缩略图红心徽标（透传 GalleryContextState）。
  final bool hideFavoriteBadge;

  /// 点击回调，透传给 GalleryFileWidget（外层处理选中切换/路由）。
  final ValueChanged<MsImageInfo>? onFileTap;

  /// 长按回调，透传给 GalleryFileWidget（外层处理进入多选等）。
  final ValueChanged<MsImageInfo>? onFileLongPress;

  /// 组头交互（aves）：选择模式下点击组头（滚动组头或吸附头）= 切换该组
  /// 全选；非选择模式长按组头 = 进入选择模式并全选该组。外层统一维护
  /// 选择真源后回写 selectedFiles。
  final ValueChanged<List<MsImageInfo>>? onGroupHeaderToggle;
  final ValueChanged<List<MsImageInfo>>? onGroupHeaderLongPress;

  /// 滑动多选增量回调（ente SwipeToSelectHelper 适配）：拖选产生的
  /// （选中，取消）增量交外层更新选择真源（visort 真源在 screen 层的
  /// _selectedIds，不能由 Gallery 直改 selectedFiles——批量栏会不启用）。
  /// 与 [selectedFiles] 同时非 null 才启用滑动多选；逐格触觉由 Gallery 层
  /// helper 触发，外层勿重复震动。
  final void Function(Set<MsImageInfo> toSelect, Set<MsImageInfo> toUnselect)?
  onSelectionDelta;

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
    this.hideFavoriteBadge = false,
    this.onFileTap,
    this.onFileLongPress,
    this.onGroupHeaderToggle,
    this.onGroupHeaderLongPress,
    this.onSelectionDelta,
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

  // ── 滑动多选（ente 同款）：helper 随分组重建（allFiles 与渲染序列严格
  // 同步，否则 index 错位）；激活标志驱动 physics 切换 NeverScroll。──
  SwipeToSelectHelper? _swipeHelper;
  final _swipeActiveNotifier = ValueNotifier<bool>(false);
  bool get _swipeSelectionEnabled =>
      widget.onSelectionDelta != null && widget.selectedFiles != null;

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
    // 网格列数变化（选项面板步进）：GalleryGroups 缓存的行布局/缩略图
    // 档位都按列数预算，必须重算——曾漏此条致「改列数不生效」（真机实证）。
    if (oldWidget.crossAxisCount != widget.crossAxisCount) {
      needsRegroup = true;
    }
    if (oldWidget.sortOrderAsc != widget.sortOrderAsc) {
      _sortOrderAsc = widget.sortOrderAsc;
      needsRegroup = true;
    }
    if (!identical(oldWidget.allFiles, widget.allFiles)) {
      _allGalleryFiles = widget.allFiles;
      // 内容指纹短路（审查 F18）：HDR 回填/收藏切换 copyWith 生成新 List
      // 实例，identical 必失效 → 整表重算（万级 = 万次键提取 + 全部行
      // 布局）。指纹白名单 = id + dateAddedMs（分组键）+ isHdr/isFavorite/
      // name（cell 徽标与显示名）——序列未变则跳过重算。⚠️ 未来 cell
      // 新增展示字段时须同步扩白名单，否则会被此短路吞掉刷新。
      needsRegroup = !_sameFileSequence(oldWidget.allFiles, widget.allFiles);
    }
    // 滑动多选开关或选择器实例切换（enabled 边沿）→ 重建 helper。
    if (oldWidget.onSelectionDelta != widget.onSelectionDelta ||
        !identical(oldWidget.selectedFiles, widget.selectedFiles)) {
      _updateSwipeHelper();
    }
    if (needsRegroup && mounted) {
      _updateGalleryGroups();
    }
  }

  /// 指纹比较（didUpdateWidget 专用，见上方注释）。
  static bool _sameFileSequence(List<MsImageInfo> a, List<MsImageInfo> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.id != y.id ||
          x.dateAddedMs != y.dateAddedMs ||
          x.isHdr != y.isHdr ||
          x.isFavorite != y.isFavorite ||
          x.name != y.name) {
        return false;
      }
    }
    return true;
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
    _swipeHelper?.dispose();
    _swipeActiveNotifier.dispose();
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
      onGroupHeaderToggle: widget.onGroupHeaderToggle,
      onGroupHeaderLongPress: widget.onGroupHeaderLongPress,
    );
    _updateSwipeHelper();
    if (callSetState && mounted) {
      setState(() {});
    }
  }

  /// 滑动多选 helper 与渲染序列同步重建（ente _updateSwipeHelper 同款）。
  void _updateSwipeHelper() {
    final delta = widget.onSelectionDelta;
    final selectedFiles = widget.selectedFiles;
    _swipeHelper?.dispose();
    if (delta == null || selectedFiles == null) {
      _swipeHelper = null;
      return;
    }
    // 不重置 _swipeActiveNotifier：didChangeDependencies 等触发重建时若正
    // 拖选中，notifier 保持 true（physics 维持禁滚动），新 helper 未激活
    // → tile 的 postFrame 兜底会以手指所在 tile 无缝重启会话，比中断好。
    _swipeHelper = SwipeToSelectHelper(
      allFiles: _allGalleryFiles,
      selectedFiles: selectedFiles,
      onSelectionDelta: delta,
    );
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

    Widget grid = GalleryContextState(
      sortOrderAsc: _sortOrderAsc,
      inSelectionMode: widget.inSelectionMode,
      hideFavoriteBadge: widget.hideFavoriteBadge,
      type: _groupType,
      child: _allGalleryFiles.isEmpty
          ? (widget.emptyState ??
                const Center(
                  child: Text(
                    '没有照片',
                    style: TextStyle(color: AppColors.muted, fontSize: 14),
                  ),
                ))
          // ServicePolicy 滚动挂起曾在此联动，实测移除：
          // ① 手指快甩（ballistic 惯性阶段无 ScrollEnd）挂起持续 → 快滚露
          //   占位糊图，观感差；
          // ② 拖拽手柄 jumpTo 每帧连发 Start/Update/End，挂起被 End 同帧
          //   消掉从未生效 → 两种滚动行为不自洽。
          // 用户偏好视觉连续：保留优先级调度（viewer 大图 50 插队）+ 并发门
          // 平滑解码尖峰，放弃快滚省解码。
          : Stack(
              clipBehavior: Clip.none,
              children: [
                // 滑动多选激活期间禁滚动（ente 同款 physics 切换；active
                // 仅在拖选起止翻转，重建成本可忽略）。
                _swipeSelectionEnabled
                    ? ValueListenableBuilder<bool>(
                        valueListenable: _swipeActiveNotifier,
                        builder: (context, active, _) => CustomScrollView(
                          physics: active
                              ? const NeverScrollableScrollPhysics()
                              : const BouncingScrollPhysics(),
                          controller: _scrollController,
                          slivers: _gridSlivers(groups),
                        ),
                      )
                    : CustomScrollView(
                        physics: const BouncingScrollPhysics(),
                        controller: _scrollController,
                        slivers: _gridSlivers(groups),
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
                    onGroupHeaderToggle: widget.onGroupHeaderToggle,
                    onGroupHeaderLongPress: widget.onGroupHeaderLongPress,
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
                  // 日期视图行程起点避让顶部吸附组头（+8 间隙）：
                  // 手柄初始位在第一个日期标题栏下方，不叠加显示。
                  // 沉浸网格无组头（showGroupHeader=false）传 0 不受影响。
                  topInset: groups.groupType.showGroupHeader()
                      ? (groupHeaderExtent ?? 32) + 8
                      : 0,
                  // 日期视图（aves 拖动体验）：拖动显示当前组日期气泡，
                  // 松手吸附最近分组头；沉浸网格无分组不启用。
                  labelBuilder: groups.groupType.showGroupHeader()
                      ? (pixels) {
                          final gid = groups.groupIdAtOffset(pixels);
                          if (gid == null) return null;
                          final data = groups.groupIdToGroupDataMap[gid];
                          final files = groups.groupIDToFilesMap[gid];
                          if (data == null || files == null || files.isEmpty) {
                            return null;
                          }
                          return data.groupType.getTitle(context, files.first);
                        }
                      : null,
                  snapOffset: groups.groupType.showGroupHeader()
                      ? (pixels) => groups.nearestGroupOffset(pixels)
                      : null,
                ),
              ],
            ),
    );

    // 滑动多选：wrapper 承担激活判定（长按拖动 / 勾选态水平轻扫）、激活期
    // physics 切换的消费在上方 CustomScrollView、自动滚动与合成事件；并向
    // tile 下发 helper（GallerySwipeHelper）。
    if (_swipeSelectionEnabled) {
      grid = SwipeSelectionWrapper(
        swipeHelper: _swipeHelper,
        selectedFiles: widget.selectedFiles,
        isEnabled: true,
        swipeActiveNotifier: _swipeActiveNotifier,
        scrollController: _scrollController,
        child: grid,
      );
    }

    // 多选时向下提供 SelectionState（外层未包时自足；外层已包则内层遮蔽同实例）。
    final selectedFiles = widget.selectedFiles;
    return selectedFiles == null
        ? grid
        : SelectionState(selectedFiles: selectedFiles, child: grid);
  }

  /// 网格 slivers（分组网格 + 手势条 inset 占位），供 physics 两分支复用。
  List<Widget> _gridSlivers(GalleryGroups groups) {
    return [
      SectionedListSliver<dynamic>(sectionLayouts: groups.groupLayouts),
      // [visort 追加] edge-to-edge：尾部补手势条 inset 占位——
      // 配合外层 SafeArea(bottom:false)，末行可滚进手势条区
      // （照片穿过手势条，系统相册/ente 行为），停稳时不被遮挡。
      SliverToBoxAdapter(
        child: SizedBox(
          height: MediaQuery.viewPaddingOf(context).bottom,
        ),
      ),
    ];
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
  /// 组头点击/长按回调（透传 GroupHeaderWidget，与滚动组头行为一致）。
  final ValueChanged<List<MsImageInfo>>? onGroupHeaderToggle;
  final ValueChanged<List<MsImageInfo>>? onGroupHeaderLongPress;
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
    this.onGroupHeaderToggle,
    this.onGroupHeaderLongPress,
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
        // 首帧后 controller 已 attach，立即算当前组显示 pinned 头——
        // _headerHeightNotifier 恒 0.0（测量写入链路已不存在）且同值
        // 不通知，500ms 刷新路径是死路；ScrollPosition 的 content-
        // dimensions 通知在部分时序（视图切换重建）下不触发 → 切换
        // 日期视图后 pinned 头不出现直到滚动（真机实证）。postFrame
        // 主动调用覆盖全新 element 的所有进入路径。
        _setCurrentGroupID();
      }
    });
    widget.headerHeightNotifier.addListener(_headerHeightNotifierListener);
  }

  @override
  void didUpdateWidget(covariant PinnedGroupHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _setCurrentGroupID();
    // 视图切换（沉浸↔日期复用同一 Gallery element，didUpdateWidget 换绑
    // controller）：同步调用时新 controller 尚未 attach 到新 CustomScrollView
    //（positions.length != 1 → _scrollOffset null → 直接 return），且
    // headerHeightNotifier 复用旧值不变（ValueNotifier 同值不通知，500ms
    // 刷新路径也不触发）→ currentGroupId 保持 null，pinned 头直到用户滚动
    // 才出现（用户反馈：切换日期视图第一行标题栏不与顶栏融合；从首页
    // 直接进入正常——全新 element 的 postFrame 时机 controller 已 attach）。
    // postFrame 重试一次，此时 ScrollView 已 attach，header 立即显示。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setCurrentGroupID();
    });
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
    //
    // [visort 定制] 顶部 overscroll（刚进相册下拉橡皮筋，Bouncing 允许
    // pixels<0）按顶部静止态处理（clamp 0）：保持第一组标题显示，
    // 不随下拉消失（用户反馈"下拉不松手时日期标题栏别消失"）。
    final normalizedScrollOffset =
        (scrollOffset < 0 ? 0.0 : scrollOffset) -
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
                                color: AppColors.headerShadow,
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
                          onGroupToggle: widget.onGroupHeaderToggle,
                          onGroupLongPress: widget.onGroupHeaderLongPress,
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
