// 相册内浏览屏（网格 + 大图浏览器）—— 安卓 MediaStore
//
// 流程：从 GalleryScreen 进入，参数 bucketId。
//   顶部：相册名 + 排序切换 + 返回
//   主体：GridView 3 列缩略图网格，滚动到底加载更多（keyset 分页）
//   点击缩略图 → 全屏大图浏览器（PageView 左右滑 + InteractiveViewer 缩放 + 删除按钮）
//
// 删除：复用 galleryController.deletePhoto（requestDelete + 缓存清理 + 本地移除）。
// 大图浏览器与分页联动：滚动接近末尾时触发 loadMore，viewer 一路滑到底。
//
// 注意：本文件已拆分——PhotoViewer 见 photo_viewer.dart，详情抽屉见
// photo_details_sheet.dart，共享辅助见 album_common.dart。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/shared/widgets/scroll_drag_handle.dart';
import 'package:visort_flutter/shared/widgets/sort_toggle.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';

import 'album_common.dart';
import 'photo_viewer.dart';

class AlbumScreen extends ConsumerStatefulWidget {
  const AlbumScreen({
    super.key,
    required this.bucketId,
    this.bucketName,
    this.bucketCount,
    this.favoritesOnly = false,
    this.trashedOnly = false,
  });

  final String bucketId;
  final String? bucketName;

  /// 该相册的图片总数（来自 MediaStore bucket.count，稳定不变）。
  /// 供滚动拖拽手柄做精确进度定位——不随分页 loadMore 变化，故手柄不跳。
  /// null 时手柄回退到「已加载内容内定位」。
  final int? bucketCount;

  /// 跨相册收藏视图（P1b）：true 时忽略 bucketId，扫描所有 IS_FAVORITE=1。
  final bool favoritesOnly;

  /// 跨相册回收站视图（P1a）：true 时扫描所有 IS_TRASHED=1。
  final bool trashedOnly;

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  late final ScrollController _scrollCtrl = ScrollController();
  /// 日期视图独立的滚动控制器（与沉浸网格分用，避免切换视图时
  /// ScrollController 同时 attached 到两个 scrollable 触发断言）。
  final ScrollController _timelineScrollCtrl = ScrollController();
  static const _threshold = 0.7; // 滚动到 70% 触发加载更多

  /// 网格 GridView key：计算 cell 屏幕位置（返回飞行层终点）用。
  final GlobalKey _gridKey = GlobalKey();

  /// 打开 viewer 时的照片索引与网格滚动位置：
  /// 返回定位规则（对标系统相册）——向后滑→目标行贴视口底部；
  /// 向前滑→贴顶部；翻回原位→恢复打开时的网格视口。
  int _openViewerIndex = 0;
  double _openScrollOffset = 0;

  /// 飞行层图：跟随当前照片（翻页后返回动画缩回的是当前照片，不是初始那张）。
  late Widget _flightImage;

  /// 飞行层终点：当前照片所在 cell 的屏幕位置（翻页时滚动网格到该行后计算）。
  Rect? _flightEndRect;

  /// 飞行层当前照片宽高比：Transform 缩放精确算 cell→全屏 缩放比（避免竖图溢出）。
  /// _buildFlightImage 每次换图时刷新。
  double? _flightImgAspect;

  // ── 批量选择模式：长按 cell 进入，勾选后底部操作栏执行批量操作 ──
  bool _selectMode = false;
  final Set<String> _selectedIds = {};
  /// 视图模式：false=沉浸网格(默认)；true=日期分组视图。
  bool _timelineView = false;

  // ── 日期分组视图扁平索引（单 SliverList 混合项：组头 / 整行照片）──
  // 多 sliver（每组分 SliverGrid）在组数多时 build 重：进入动画帧叠加会卡顿
  // （真机实测 1100 张/几十组明显，沉浸单 GridView 无此问题）。扁平化为单
  // SliverList 后 build 轻（只 layout 可见项），动画流畅且直接渲染清晰缩略图
  // （128→300 正常渐进，无低质量跳变）。全量加载后 itemCount 固定，extent 稳定。
  List<MsImageInfo>? _flatPhotos; // 索引对应的 photos（identical 判定缓存）
  List<int> _flat = const []; // 负=组头(-组号-1)，非负=行首 photo 全局下标
  List<int> _flatRowEnd = const []; // 行项的末尾 photo 下标+1（组尾行不满）
  List<int> _flatDayMs = const []; // 组头 dayMs（按组号）
  int _flatGroupCount = 0; // 已加载组数

  void _enterSelectMode(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  /// 切换沉浸网格/日期分组视图。切到日期视图时强制按创建日期排序
  /// （日期分组依赖 dateCreated 顺序；切回沉浸保留原排序偏好）。
  void _toggleViewMode() {
    setState(() => _timelineView = !_timelineView);
    // 持久化视图偏好（重进相册保持）。
    ref.read(configProvider.notifier).state =
        ref.read(configProvider).copyWith(photoTimelineView: _timelineView);
    if (_timelineView) {
      final c = ref.read(galleryControllerProvider);
      if (c.effectivePhotoSortBy != SortBy.dateCreated) {
        ref
            .read(galleryControllerProvider.notifier)
            .setPhotoSort(SortBy.dateCreated, c.photoSortAsc);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // 恢复上次相册内视图偏好（沉浸网格 / 日期分组）。
    _timelineView = ref.read(configProvider).photoTimelineView;
    _scrollCtrl.addListener(_onScroll);
    _timelineScrollCtrl.addListener(_onTimelineScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 进入动画（网格由小变大）期间网格照常渲染——动画主体就是网格本身，
      // query 在动画窗口内完成,动画结束缩略图渐进填充。
      if (widget.favoritesOnly) {
        ref.read(galleryControllerProvider.notifier).enterFavorites();
      } else if (widget.trashedOnly) {
        ref.read(galleryControllerProvider.notifier).enterTrash();
      } else {
        ref
            .read(galleryControllerProvider.notifier)
            .enterBucket(widget.bucketId);
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _timelineScrollCtrl.removeListener(_onTimelineScroll);
    _timelineScrollCtrl.dispose();
    // 退出相册：保存桶快照（同桶重进秒出）+ 重查相册列表（返回首页刷新
    // count/封面，删除/恢复后不残留旧数据）。
    ref.read(galleryControllerProvider.notifier).exitBucket();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    _maybeLoadMore(_scrollCtrl.position);
  }

  /// 日期视图滚动：接近底部触发 loadMore（独立 controller）。
  void _onTimelineScroll() {
    if (!_timelineScrollCtrl.hasClients) return;
    _maybeLoadMore(_timelineScrollCtrl.position);
  }

  /// 接近底部触发 loadMore。全量加载后 nextCursor=null，loadMore 内部直接 return，
  /// 此方法保留作 fallback（未来若恢复分页仍可用）。
  void _maybeLoadMore(ScrollPosition pos) {
    if (pos.pixels < pos.maxScrollExtent * _threshold) return;
    ref.read(galleryControllerProvider.notifier).loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(galleryControllerProvider);
    // 勾选态拦截返回：系统返回/返回箭头先取消勾选态，不退出页面
    // （对标系统相册；再按一次才真正退出）。
    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectMode) _exitSelectMode();
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.text,
          // 标题紧贴返回箭头（默认 titleSpacing 16 会显得相册名离箭头太远）
          titleSpacing: 0,
          title: _selectMode
              ? Text(
                  t(ref, 'selected_n', [_selectedIds.length]),
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    height: 1.2,
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                )
              : Text(
                  widget.trashedOnly
                      ? t(ref, 'trash_title')
                      : (widget.favoritesOnly
                            ? t(ref, 'favorites_title')
                            : (widget.bucketName ?? t(ref, 'gallery_title'))),
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    height: 1.2,
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          actions: _selectMode
              ? [
                  IconButton(
                    icon: const Icon(Icons.select_all),
                    tooltip: t(ref, 'select_all'),
                    onPressed: () => setState(() {
                      final photos = ref.read(galleryControllerProvider).photos;
                      _selectedIds.addAll(photos.map((p) => p.id));
                    }),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: t(ref, 'batch_cancel'),
                    onPressed: _exitSelectMode,
                  ),
                ]
              : [
                  // 与首页顶栏一致的排版：SortToggle 右移 14 贴近右侧按钮
                  Transform.translate(
                    offset: const Offset(14, 0),
                    child: SortToggle(
                      // 日期视图固定按创建日期，只留升/降序
                      sortBy: _timelineView
                          ? SortBy.dateCreated
                          : gallery.effectivePhotoSortBy,
                      asc: gallery.photoSortAsc,
                      dateOnly: _timelineView,
                      // 回收站视图额外提供「按删除日期」
                      showDateTrashed: widget.trashedOnly,
                      onChanged: (by, asc) => ref
                          .read(galleryControllerProvider.notifier)
                          .setPhotoSort(by, asc),
                    ),
                  ),
                  // 视图切换（排序组件右侧；仅普通相册，收藏/回收站保持沉浸）
                  if (!widget.favoritesOnly && !widget.trashedOnly)
                    IconButton(
                      icon: Icon(
                        _timelineView
                            ? Icons.calendar_view_day
                            : Icons.view_module,
                        color: AppColors.text,
                      ),
                      tooltip: t(
                          ref, _timelineView ? 'view_immersive' : 'view_date'),
                      onPressed: _toggleViewMode,
                    ),
                ],
        ),
        body: SafeArea(child: _buildBody(gallery)),
        // 批量选择模式：底部操作栏（按视图模式提供不同批量操作）
        bottomNavigationBar: _selectMode ? _buildBatchBar(gallery) : null,
      ),
    );
  }

  Widget _buildBody(GalleryState gallery) {
    final cols = ref.watch(configProvider).photoGridColumns;
    // 日期分组视图（仅普通相册）：按创建日期分组 + sticky 日期头。
    if (_timelineView && !widget.favoritesOnly && !widget.trashedOnly) {
      // 进入动画期间先渲染轻量占位：日期视图多 sliver（每组一个 SliverGrid）
      // 完整 build 叠加动画帧会卡顿（沉浸单 GridView 无此问题）。动画完成后
      // 切完整日期视图（数据秒出 + 缩略图渐进填充，无突兀感）。
      return _buildTimelineBody(gallery);
    }
    // ⚠️ 无转圈：首屏未完成（firstPageLoaded=false 且无数据）时显示灰格占位网格，
    // 第一页到达后无缝替换；error 时显示错误页（可重试）。
    if (gallery.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 40,
                color: AppColors.danger,
              ),
              const SizedBox(height: 12),
              SelectableText(
                gallery.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                  color: AppColors.danger,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => ref
                    .read(galleryControllerProvider.notifier)
                    .enterBucket(widget.bucketId),
                child: Text(t(ref, 'retry')),
              ),
            ],
          ),
        ),
      );
    }
    // 缩略图像素尺寸 = cell 逻辑宽 × dpr（物理像素对齐，对标系统相册 dp×dpr 分档）。
    // 固定 300 时代 dpr≈3.19 的 cell≈466px 物理，缩略图欠采样发糊；按 dpr 全采样更清晰。
    final cellWidth =
        (MediaQuery.sizeOf(context).width - 4 * 2 - (cols - 1) * 3) / cols;
    final thumbSize = (cellWidth * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(160, 512);
    // 直接用 scanImages 的 SQL 原序（已跟随 photoSortBy 排序），与首页封面
    // （listBuckets 取该 SQL 排序首张）严格一致。不用 sortedPhotos 内存重排，
    // 避免 Dart/SQL 对日期列（DATE_ADDED）为空（NULL）行的处理差异导致首张不一致。
    final photos = gallery.photos;
    if (photos.isEmpty) {
      if (!gallery.firstPageLoaded) {
        // 首次进入占位：灰格网格（无转圈），数据到达后无缝替换
        return _ThumbGridPlaceholder(cols: cols);
      }
      return Center(
        child: Text(
          t(ref, 'album_empty'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.muted,
            fontSize: 13,
          ),
        ),
      );
    }
    return Stack(
      children: [
        GridView.builder(
          key: _gridKey,
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 3,
            mainAxisSpacing: 3,
          ),
          // ⚠️ 无「加载更多」占位项：滚动 70% 自动触发 loadMore，数据到达直接插入，
          // 底部不再渲染转圈 cell。
          itemCount: photos.length,
          itemBuilder: (ctx, i) {
            final info = photos[i];
            // ⚠️ 不要用 RepaintBoundary 包 cell：滚动时每个新 cell 创建独立
            // layer、旧 cell 销毁，频繁 layer 分配会拖慢滚动（实测滚动变卡）。
            // cell 保持纯 InkWell + Image（与无动画版本一致，滚动流畅）。
            return _PhotoCell(
              info: info,
              thumbSize: thumbSize,
              selectMode: _selectMode,
              selected: _selectedIds.contains(info.id),
              onTap: (cellRect) => _selectMode
                  ? _toggleSelect(info.id)
                  : _openViewer(context, gallery, photos, i, cellRect),
              onLongPress: _selectMode ? null : () => _enterSelectMode(info.id),
            );
          },
        ),
        // 右侧滚动拖拽手柄：向下滚动后出现，可拖拽跳转。
        // 用真实图片总数（bucket.count）+ 固定单行高度算进度，
        // 分母稳定不变 → 分页 loadMore 时手柄绝不回跳。
        ScrollDragHandle(
          controller: _scrollCtrl,
          totalItems: widget.bucketCount ?? photos.length,
          rowExtent:
              (MediaQuery.sizeOf(context).width - 4 * 2 - (cols - 1) * 3) /
                  cols +
              3,
          columns: cols,
          viewportRows: 5,
        ),
      ],
    );
  }

  /// 日期分组视图：按创建日期(dateAddedMs)分组，组头 + 整行照片混合的单
  /// SliverList。网格列数复用 config.photoGridColumns（与沉浸视图一致）。
  /// 扁平化：多 sliver（每组分 SliverGrid）在组数多时 build 重，进入动画帧
  /// 叠加会卡顿；单 SliverList 只 layout 可见项 → 动画流畅 + 直接清晰缩略图
  /// （128→300 正常渐进，无低质量跳变）。全量加载后 itemCount 固定，extent 稳定。
  Widget _buildTimelineBody(GalleryState gallery) {
    final cols = ref.watch(configProvider).photoGridColumns;
    final photos = gallery.photos;
    if (photos.isEmpty) {
      if (!gallery.firstPageLoaded) {
        return _ThumbGridPlaceholder(cols: cols);
      }
      return Center(
        child: Text(
          t(ref, 'album_empty'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.muted,
            fontSize: 13,
          ),
        ),
      );
    }
    final cellWidth =
        (MediaQuery.sizeOf(context).width - 4 * 2 - (cols - 1) * 3) / cols;
    final cellH = cellWidth + 3; // 含行距，与手柄 rowExtent 一致
    final thumbSize = (cellWidth * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(160, 512);
    final totalItems = widget.bucketCount ?? photos.length;
    // 扁平索引：photos 引用变化（loadMore/刷新）时重建，否则复用（滚动/选中/
    // 动画帧不重算 —— build 轻的关键，也是动画流畅的根因）。
    if (!identical(_flatPhotos, photos)) _buildTimelineIndex(photos, cols);
    return Stack(
      children: [
        CustomScrollView(
          key: _gridKey,
          controller: _timelineScrollCtrl,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((ctx, j) {
                  final f = _flat[j];
                  if (f < 0) {
                    // 组头项：随内容滚动（非 sticky，避免多组日期头叠成日期列表）
                    return _DateHeaderRow(
                      label: _dayLabel(_flatDayMs[-f - 1], ref),
                    );
                  }
                  // 整行项：行首 photo 下标 f 起连续 cols 张（组尾行不满补空）
                  final end = _flatRowEnd[j];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      children: [
                        for (var pi = f; pi < end; pi++)
                          Expanded(
                            child: Padding(
                              padding:
                                  EdgeInsets.only(right: pi == end - 1 ? 0 : 3),
                              child: SizedBox(
                                width: double.infinity,
                                height: cellWidth,
                                child: _PhotoCell(
                                  info: photos[pi],
                                  thumbSize: thumbSize,
                                  selectMode: _selectMode,
                                  selected:
                                      _selectedIds.contains(photos[pi].id),
                                  onTap: (cellRect) => _selectMode
                                      ? _toggleSelect(photos[pi].id)
                                      : _openViewer(context, gallery, photos,
                                          pi, cellRect),
                                  onLongPress: _selectMode
                                      ? null
                                      : () =>
                                          _enterSelectMode(photos[pi].id),
                                ),
                              ),
                            ),
                          ),
                        // 组尾不完整行：补齐空位（与沉浸网格右侧留白观感一致）
                        for (var i = end - f; i < cols; i++)
                          const Expanded(child: SizedBox()),
                      ],
                    ),
                  );
                }, childCount: _flat.length),
              ),
            ),
          ],
        ),
        // 日期视图拖拽手柄：useActualExtent（实际可滚范围），到底=100%。
        // 全量加载后 itemCount 固定 → maxScrollExtent 稳定，手柄不跳。
        ScrollDragHandle(
          controller: _timelineScrollCtrl,
          totalItems: totalItems,
          rowExtent: cellH,
          columns: cols,
          viewportRows: 5,
          useActualExtent: true,
        ),
      ],
    );
  }

  /// 构建日期视图扁平索引：flat（组头/整行）+ 行边界。photos 引用变化时重建。
  void _buildTimelineIndex(List<MsImageInfo> photos, int cols) {
    _flatPhotos = photos;
    final groups = _groupPhotosByDay(photos);
    _flatGroupCount = groups.length;
    _flat = <int>[];
    _flatRowEnd = <int>[];
    _flatDayMs = List<int>.filled(groups.length, 0);
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      _flatDayMs[gi] = g.dayMs;
      _flat.add(-(gi + 1)); // 组头项
      _flatRowEnd.add(-1);
      final end = g.startIndex + g.photos.length;
      for (var rowFirst = g.startIndex; rowFirst < end; rowFirst += cols) {
        final rowEnd = rowFirst + cols < end ? rowFirst + cols : end;
        _flat.add(rowFirst); // 行项：行首 photo 下标
        _flatRowEnd.add(rowEnd);
      }
    }
  }

  /// 按天分组（保持 photos 的 SQL 排序顺序：升序旧→新 / 降序新→旧）。
  /// [startIndex] 记录每组首项在 gallery.photos 的全局下标，供 viewer 全列表翻页。
  List<_DateGroup> _groupPhotosByDay(List<MsImageInfo> photos) {
    final groups = <_DateGroup>[];
    for (var i = 0; i < photos.length; i++) {
      final day = _dayStartMs(photos[i].dateAddedMs);
      if (groups.isEmpty || groups.last.dayMs != day) {
        groups.add(_DateGroup(day, [photos[i]], i));
      } else {
        groups.last.photos.add(photos[i]);
      }
    }
    return groups;
  }

  /// 归一化到当天 0 点（毫秒）。
  int _dayStartMs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  /// 日期标签：今天/昨天/M月d日/YYYY年M月d日（跨年带年份）。
  String _dayLabel(int dayMs, WidgetRef ref) {
    final day = DateTime.fromMillisecondsSinceEpoch(dayMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return t(ref, 'today');
    if (day == today.subtract(const Duration(days: 1))) {
      return t(ref, 'yesterday');
    }
    if (day.year == now.year) return '${day.month}月${day.day}日';
    return '${day.year}年${day.month}月${day.day}日';
  }

  /// 批量选择模式的底部操作栏：按视图模式提供不同操作。
  /// 普通相册：批量删除（移入回收站）；收藏：取消收藏 + 删除；回收站：恢复 + 彻底删除。
  Widget _buildBatchBar(GalleryState gallery) {
    final enabled = _selectedIds.isNotEmpty;
    Widget op(IconData icon, String label, Color color, VoidCallback? onTap) =>
        Expanded(
          child: TextButton.icon(
            onPressed: enabled ? onTap : null,
            icon: Icon(icon, size: 18),
            label: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(foregroundColor: color),
          ),
        );
    final ops = widget.trashedOnly
        ? [
            op(
              Icons.restore,
              t(ref, 'action_restore'),
              AppColors.accent,
              _runBatchRestore,
            ),
            op(
              Icons.delete_forever,
              t(ref, 'delete_permanently'),
              AppColors.danger,
              _runBatchDelete,
            ),
          ]
        : widget.favoritesOnly
        ? [
            op(
              Icons.favorite_border,
              t(ref, 'action_unfavorite'),
              AppColors.accent,
              _runBatchUnfavorite,
            ),
            op(
              Icons.delete_outline,
              t(ref, 'delete_photo'),
              AppColors.danger,
              _runBatchTrash,
            ),
          ]
        : [
            op(
              Icons.favorite_border,
              t(ref, 'action_favorite'),
              AppColors.accent,
              _runBatchFavorite,
            ),
            op(
              Icons.delete_outline,
              t(ref, 'delete_photo'),
              AppColors.danger,
              _runBatchTrash,
            ),
          ];
    return SafeArea(
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: ops),
      ),
    );
  }

  /// 当前仍存在于列表中的选中 id（observer/外部变更可能已移除部分）。
  List<String> _currentSelectedIds() {
    final photos = ref.read(galleryControllerProvider).photos;
    return _selectedIds.where((id) => photos.any((p) => p.id == id)).toList();
  }

  /// 批量移入回收站（普通相册/收藏视图的「批量删除」）。
  Future<void> _runBatchTrash() async {
    final ids = _currentSelectedIds();
    if (ids.isEmpty) {
      _exitSelectMode();
      return;
    }
    final confirmed = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          t(ref, 'batch_delete_confirm', [ids.length]),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.text,
            fontSize: 15,
          ),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    t(ref, 'cancel'),
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    foregroundColor: AppColors.bg,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .trashPhotos(ids);
    if (!mounted) return;
    _exitSelectMode();
    toast(
      context,
      err == null ? t(ref, 'trashed') : t(ref, 'trash_unsupported'),
    );
  }

  /// 批量从回收站恢复。
  Future<void> _runBatchRestore() async {
    final ids = _currentSelectedIds();
    if (ids.isEmpty) {
      _exitSelectMode();
      return;
    }
    final confirmed = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          t(ref, 'batch_restore_confirm', [ids.length]),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.text,
            fontSize: 15,
          ),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    t(ref, 'cancel'),
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.bg,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .restorePhotos(ids);
    if (!mounted) return;
    _exitSelectMode();
    toast(context, err == null ? t(ref, 'restored') : t(ref, 'restore_failed'));
  }

  /// 批量彻底删除（回收站视图）。
  Future<void> _runBatchDelete() async {
    final ids = _currentSelectedIds();
    if (ids.isEmpty) {
      _exitSelectMode();
      return;
    }
    final confirmed = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          t(ref, 'delete_permanently'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.text,
            fontSize: 15,
          ),
        ),
        content: Text(
          t(ref, 'batch_delete_permanent_confirm', [ids.length]),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.muted,
            fontSize: 13,
          ),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    t(ref, 'cancel'),
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    foregroundColor: AppColors.bg,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .deletePhotos(ids);
    if (!mounted) return;
    _exitSelectMode();
    toast(context, err == null ? t(ref, 'deleted') : t(ref, 'delete_failed'));
  }

  /// 批量收藏（普通相册；与单张收藏切换一致不弹窗，乐观更新）。
  Future<void> _runBatchFavorite() async {
    final ids = _currentSelectedIds();
    if (ids.isEmpty) {
      _exitSelectMode();
      return;
    }
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .setFavorites(ids, true);
    if (!mounted) return;
    _exitSelectMode();
    toast(
      context,
      err == null ? t(ref, 'favorited') : t(ref, 'favorite_failed'),
    );
  }

  /// 批量取消收藏（收藏视图；与单张收藏切换一致不弹窗，乐观更新）。
  Future<void> _runBatchUnfavorite() async {
    final ids = _currentSelectedIds();
    if (ids.isEmpty) {
      _exitSelectMode();
      return;
    }
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .setFavorites(ids, false);
    if (!mounted) return;
    _exitSelectMode();
    toast(
      context,
      err == null ? t(ref, 'unfavorited') : t(ref, 'favorite_failed'),
    );
  }

  /// 打开大图浏览器：用 PageRouteBuilder 的 transitionsBuilder 实现
  /// "图从 cell 位置线性放大到全屏"的缩放动画。
  /// ⚠️ 必须用 route transition，不能用 Overlay AnimationController：
  /// ColorOS DynamicFramerate 对 Overlay 上的自定义动画在 Choreographer 层
  /// 降帧到 30 且粘滞不恢复（实测）；route 过渡动画是系统 push/pop 驱动，
  /// ColorOS 不降帧（fade 版实测全程 120）。
  /// [cellRect] 为点击 cell 的屏幕坐标；null 时无缩放动画。
  /// 飞行层图片：跟随当前照片。
  /// ⚠️ 必须用 size:300（网格同 key，ImageCache 已缓存）——用 1024 时动画
  /// 250ms 内 loadThumbnail 加载不完 → 飞行层空白 → 灰屏且无缩放效果。
  /// errorBuilder 用灰块兜底：即使加载失败也有可见内容在放大（诊断+兜底）。
  Widget _buildFlightImage(MsImageInfo info) {
    final imgRef = imageRefFromMediaStoreId(
      info.id,
      extension: extOf(info.name),
    );
    // 记录宽高比，供 transitionsBuilder 算 Transform 缩放比（contain 全程缩放，
    // 避免方形 cell↔竖屏全屏 的 contain 方向跳变重影）。
    _flightImgAspect = (info.width > 0 && info.height > 0)
        ? info.width / info.height
        : null;
    // 两级飞行层：300 缩略图（网格缓存，push 立即可见）+ 下采样原图
    // （与 viewer 用同一 computeViewerTargetWidth → pop 时命中 viewer 已加载
    // 的缓存，返回动画清晰；push 期间解码完则无缝覆盖 300，没完也有 300 兜
    // 底不灰屏）。之前只挂 300 → pop 时 viewer 原图已就绪却被 300 盖住、
    // 返回发虚（用户反馈"图已加载出来不该再模糊"）。
    // 两级飞行层：300 缩略图（网格缓存，push 立即可见）+ 下采样原图（1152，动画
    // 期清晰）。1152 解码完用 gaplessPlayback 覆盖 300，没完则 300 兜底不模糊。
    final tw = computeViewerTargetWidth(
      MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: buildThumbnailProvider(imgRef, size: 300),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF2A2A2A)),
        ),
        Image(
          image: buildImageProvider(imgRef, targetWidth: tw),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// viewer 翻页：飞行层返回动画跟随当前照片——更新飞行层图 + 滚动网格到
  /// 目标行 + 计算终点 cell 位置。滚动在 viewer 打开期间后台执行（用户无感），
  /// 返回时目标行已在正确位置（缩略图也随滚动预加载）。
  void _onViewerIndexChanged(int index) {
    final photos = ref.read(galleryControllerProvider).photos;
    if (index < 0 || index >= photos.length) return;
    _flightImage = _buildFlightImage(photos[index]);
    _scrollToCellRow(index);
    final r = _cellRectFor(index);
    if (r != null) _flightEndRect = r;
  }

  /// 滚动网格让目标行可见。返回定位规则（对标系统相册）：
  /// - 向后滑（index > 打开时）→ 目标行贴视口**底部**（成为最后可见行）
  /// - 向前滑（index < 打开时）→ 目标行贴视口**顶部**（成为第一行）
  /// - 翻回原位 → 恢复打开时的网格视口
  /// 滚动在 viewer 打开期间后台执行（用户无感），返回时目标行已在正确位置
  ///（缩略图也随滚动预加载）。
  void _scrollToCellRow(int index) {
    if (!_scrollCtrl.hasClients) return;
    final cols = ref.read(configProvider).photoGridColumns;
    final gridBox = _gridKey.currentContext?.findRenderObject();
    if (gridBox is! RenderBox) return;
    final cellW = (gridBox.size.width - 8 - (cols - 1) * 3) / cols;
    final rowExtent = cellW + 3;
    final row = index ~/ cols;
    final viewportRows = (gridBox.size.height / rowExtent).floor();
    double target;
    if (index == _openViewerIndex) {
      target = _openScrollOffset;
    } else if (index > _openViewerIndex) {
      // 贴底：目标行成为视口最后一行（最小滚动）
      target = (row - viewportRows + 1) * rowExtent;
    } else {
      // 贴顶：目标行成为视口第一行
      target = row * rowExtent;
    }
    _scrollCtrl.jumpTo(target.clamp(0.0, _scrollCtrl.position.maxScrollExtent));
  }

  /// 计算网格中某 index cell 的屏幕位置。
  /// 布局规则固定（padding 4、spacing 3、正方形 cell），与 ScrollDragHandle
  /// 的 rowExtent 公式一致——无需 RenderObject 即可精确定位。
  Rect? _cellRectFor(int index) {
    final gridBox = _gridKey.currentContext?.findRenderObject();
    if (gridBox is! RenderBox || !gridBox.attached || !_scrollCtrl.hasClients) {
      return null;
    }
    final cols = ref.read(configProvider).photoGridColumns;
    final cellW = (gridBox.size.width - 8 - (cols - 1) * 3) / cols;
    final rowExtent = cellW + 3;
    final row = index ~/ cols;
    final col = index % cols;
    final topLeft = gridBox.localToGlobal(
      Offset(4 + col * (cellW + 3), 4 + row * rowExtent - _scrollCtrl.offset),
    );
    return topLeft & Size(cellW, cellW);
  }

  void _openViewer(
    BuildContext context,
    GalleryState gallery,
    List<MsImageInfo> photos,
    int index,
    Rect? cellRect,
  ) {
    final info = photos[index];
    // 不预解码 2880：precacheImage 在 push 同帧发起大图解码+纹理上传，
    // 与飞行动画抢 raster 线程。本诊断版移除，验证动画期纹理上传是否为掉帧根因。
    // final imgRef =
    //     imageRefFromMediaStoreId(info.id, extension: extOf(info.name));
    // precacheImage(
    //     buildImageProvider(imgRef,
    //         targetWidth: computeViewerTargetWidth(
    //             MediaQuery.sizeOf(context).width *
    //                 MediaQuery.devicePixelRatioOf(context))),
    //     context);
    // 飞行层初始状态：当前照片 + 点击 cell 位置。
    // 翻页后由 [_onViewerIndexChanged] 更新——返回动画跟随当前照片。
    _openViewerIndex = index;
    _openScrollOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0;
    _flightImage = _buildFlightImage(info);
    _flightEndRect = cellRect;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        // ⚠️ opaque: false —— pop 返回动画期间底下 album 网格参与合成并可见
        // （COUI 式返回：viewer 淡出 + 飞行层缩回时网格全程在底下，动画结束
        // 无"黑→网格瞬现"）。push 期网格被下方恒黑垫底层盖住，观感不变；
        // 代价是动画期间多一层网格合成（180~250ms，Impeller 下可接受）。
        opaque: false,
        // route animation 驱动 rect 缩放：
        // push（anim 0→1）：图从 cellRect 线性放大到全屏 contain；
        // pop（anim 1→0）：图从全屏缩回**当前照片**的 cell 位置（翻页后更新）。
        // child = PhotoViewer 页面（在飞行层下方）。
        transitionsBuilder: (ctx, anim, _, child) {
          // 移除每帧 debugPrint（release 下非空操作，throttle buffer 满
          // flush logcat 会阻塞主 isolate）。
          final size = MediaQuery.sizeOf(ctx);
          // 终点 = 全屏 contain 区域（与 viewer 图区域一致：图延伸到栏后，由栏
          // overlay 盖住）。栏黑底不参与淡入（见 photo_viewer _insertBars），故
          // 飞行层图进栏区域、completed 切换均不闪。
          final fullRect = Rect.fromLTWH(4, 0, size.width - 8, size.height);
          // COUIMoveEase 替代原 linear：强 ease-out，图"冲"到全屏而非匀速滑入。
          // 原 linear 已验证可用但略机械；couiMoveEase 更贴近一加手感。
          final t = AppCurves.couiMoveEase.transform(anim.value);
          final endRect = _flightEndRect;
          // 飞行层：图 cover 填满渲染矩形（无 contain 留白方向跳变重影），渲染矩形
          // 从 cellRect 线性插值到 containFullRect（图在全屏的实际占位）。
          // t=0 cover cellRect = 缩略图（填满，无缝）；t=1 cover containFullRect
          // （矩形比例=图，cover 无裁剪）= viewer contain → completed/返回终点/过程都不跳。
          final imgA = _flightImgAspect;
          Rect targetRect;
          if (imgA != null && imgA > 0) {
            final vpA = fullRect.width / fullRect.height;
            double fullImgW, fullImgH;
            if (imgA < vpA) {
              // 图比 rect 更高 → 按高缩（高满，左右留白）
              fullImgH = fullRect.height;
              fullImgW = fullRect.height * imgA;
            } else {
              // 图比 rect 更宽 → 按宽缩（宽满，上下留白）
              fullImgW = fullRect.width;
              fullImgH = fullRect.width / imgA;
            }
            targetRect = Rect.fromCenter(
              center: fullRect.center,
              width: fullImgW,
              height: fullImgH,
            );
          } else {
            targetRect = fullRect;
          }
          final rect = Rect.lerp(endRect ?? targetRect, targetRect, t)!;
          // ⚠️ showFlight 必须用 status 判断（不能用 anim.value < 1）：
          // completed 后 transitionsBuilder 不再 rebuild，若黑底留在树里会
          // 永远盖住 viewer。pop 触发时 status 变 reverse → 飞行层重新出现。
          final showFlight =
              endRect != null && anim.status != AnimationStatus.completed;
          // push 与 pop 都让 viewer 隐藏、飞行层独占缩放：push 时若 viewer 可见，
          // 其满屏图会与飞行缩略图重叠成"底下垫图 + 缩放"的双图观感；pop 时若 viewer
          // 随 t 淡出，飞行层缩回过程中后面会叠着 viewer 全屏原图，衔接生硬（用户
          // 反馈"两层图"）。故两种方向都 viewerOpacity=0，仅 completed 后 viewer 显现。
          final isReverse = anim.status == AnimationStatus.reverse;
          final viewerOpacity = showFlight ? 0.0 : 1.0;
          // 飞行层渐显渐隐：起点/终点 15% 内淡入淡出（避免 push 突兀出现 /
          // pop 缩回瞬间消失）。
          final baseBlack = (t / 0.15).clamp(0.0, 1.0);
          // 黑遮罩仅 push 期使用：viewer 半透明（t<1）时盖住底层，viewer 完全
          // 可见（t=1）时 black=0，showFlight 移除瞬间（completed）chrome 顶/底栏
          // 不会从"被黑盖住"突变到可见。（旧逻辑末段加深到 0.95 再整层移除 → 闪烁）
          // ⚠️ pop 返回时 black=0：配合 opaque:false 让底下相册网格全程可见
          // （COUI 式返回），viewer 淡出 + 飞行层缩回时网格透出，动画结束
          // 无"黑→网格瞬现"。
          final black = isReverse ? 0.0 : (1.0 - t).clamp(0.0, 1.0) * 0.95;
          return Stack(
            fit: StackFit.expand,
            children: [
              // ⚠️ 垫底（仅 push 期）：纯黑（= viewer Scaffold 背景），**恒不透明**——
              // push 期 viewer 隐藏、飞行层 contain 留白透出本层；t=1 飞行层移除、
              // viewer 显现，留白从「垫底」交接到「viewer 背景」，二者同色避免
              // 灰→黑跳变闪烁（原 #0F0F0F 与 viewer 纯黑差 15 → 图片上下留白闪灰）。
              // pop 返回时移除本层——opaque:false 下底层网格参与合成，viewer 淡出
              // 即露出网格；保留本层会把网格重新盖死（又变回"瞬现"）。
              if (!isReverse) const ColoredBox(color: Colors.black),
              // viewer 页面：push 隐藏飞行层独占缩放;pop 走 viewerOpacity(t)淡出。
              Opacity(opacity: viewerOpacity, child: child),
              if (showFlight) ...[
                if (black > 0)
                  ColoredBox(color: Colors.black.withValues(alpha: black)),
                // ⚠️ Positioned 必须直接作为 Stack 的 child！之前在 Opacity 里
                // （Opacity→Positioned），release 下不报错但定位不生效、图尺寸
                // 为 0 → 飞行层不可见 → “无缩放”（多版灰屏的根因）。
                // 渐隐用 Positioned 内部的 Opacity 实现。
                Positioned.fromRect(
                  rect: rect,
                  child: Opacity(opacity: baseBlack, child: _flightImage),
                ),
              ],
            ],
          );
        },
        // pageBuilder 的 anim 与 transitionsBuilder 的 anim 是同一个 route 动画：
        // 传给 viewer 用于门控 2880 原图加载时机（completed 前不加载，见 PhotoViewer）。
        pageBuilder: (_, anim, _) => PhotoViewer(
          photos: photos,
          initialIndex: index,
          hasMore: ref.read(galleryControllerProvider).hasMore,
          totalCount: widget.bucketCount,
          onLoadMore: () =>
              ref.read(galleryControllerProvider.notifier).loadMore(),
          onIndexChanged: _onViewerIndexChanged,
          transition: anim,
        ),
        settings: const RouteSettings(name: AlbumRoutes.photoViewer),
        fullscreenDialog: true,
      ),
    );
  }
}

/// 单个缩略图 cell：InkWell + cover 缩略图。
/// 无额外动画状态（滚动性能与普通网格一致）；点击时在自身 context 里记录
/// cell 屏幕坐标（注意：itemBuilder 的 ctx.findRenderObject() 返回的是
/// RenderSliverGrid，强转 RenderBox 会崩——必须在 cell 自己的 context 取），
/// 坐标传给 [_AlbumScreenState] 打开 viewer（飞行层动画在 viewer 侧播放）。
class _PhotoCell extends StatelessWidget {
  const _PhotoCell({
    required this.info,
    required this.onTap,
    required this.thumbSize,
    this.selectMode = false,
    this.selected = false,
    this.onLongPress,
  });
  final MsImageInfo info;
  final ValueChanged<Rect?> onTap;

  /// 缩略图像素尺寸（cell 逻辑宽 × dpr，物理对齐，替代固定 300）。
  final int thumbSize;

  /// 批量选择模式：点击切换勾选而非打开 viewer；显示右上角勾选圈。
  final bool selectMode;
  final bool selected;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ref = imageRefFromMediaStoreId(info.id, extension: extOf(info.name));
    return InkWell(
      onTap: () {
        final box = context.findRenderObject();
        final rect = (box is RenderBox && box.attached)
            ? box.localToGlobal(Offset.zero) & box.size
            : null;
        debugPrint('[Flight] onTap box=$box rect=$rect');
        onTap(rect);
      },
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image(
            image: buildThumbnailProvider(
              ref,
              size: thumbSize,
              dateModifiedMs: info.dateModifiedMs,
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // 两级渐进（对标系统相册 xqip/EXIF 占位 → 清晰替换）：
            // 清晰层加载中先显示小尺寸层（Kotlin 侧 ≤128px 优先 EXIF 内嵌缩略图，
            // ~5ms 秒显，替代纯灰底等待），清晰层完成直切。磁盘缓存命中时
            // 两层近同步完成,无感。
            loadingBuilder: (ctx, child, progress) {
              if (progress == null) return child;
              return ColoredBox(
                color: AppColors.surface,
                child: Image(
                  image: buildThumbnailProvider(
                    ref,
                    size: kThumbnailPlaceholderSize,
                    dateModifiedMs: info.dateModifiedMs,
                  ),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: AppColors.surface),
                ),
              );
            },
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: AppColors.surface),
          ),
          // 批量选择模式的勾选圈：右上角，选中实心 accent + 对勾，未选空心
          if (selectMode)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? AppColors.accent
                      : AppColors.bg.withValues(alpha: 0.6),
                  border: Border.all(
                    color: selected ? AppColors.accent : Colors.white70,
                    width: 1.5,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 14, color: AppColors.bg)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// 首屏加载占位：静态灰格网格（替代转圈）。数据到达后由真实网格无缝替换。
class _ThumbGridPlaceholder extends StatelessWidget {
  const _ThumbGridPlaceholder({required this.cols});
  final int cols;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: cols * 6,
      itemBuilder: (_, _) => const ColoredBox(color: AppColors.surface),
    );
  }
}

/// 日期分组：一天的照片 + 该组首项在总列表中的下标。
class _DateGroup {
  const _DateGroup(this.dayMs, this.photos, this.startIndex);
  final int dayMs;
  final List<MsImageInfo> photos;
  final int startIndex;
}

/// 日期分组视图的日期行（随内容滚动，无背景）。
class _DateHeaderRow extends StatelessWidget {
  const _DateHeaderRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Space Mono',
          fontFamilyFallback: ['Noto Sans Mono CJK SC'],
          color: AppColors.text,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
