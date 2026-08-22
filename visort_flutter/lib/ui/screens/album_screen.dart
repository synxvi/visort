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
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/shared/widgets/sort_toggle.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';

import 'package:visort_flutter/ui/ente_viewer/gallery.dart' show Gallery;
import 'package:visort_flutter/ui/ente_viewer/gallery_groups.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery_boundaries_provider.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery_files_inherited_widget.dart';
import 'package:visort_flutter/ui/ente_viewer/group_type.dart';
import 'package:visort_flutter/ui/ente_viewer/selected_files.dart';
import 'package:visort_flutter/ui/ente_viewer/detail_page.dart';
import 'album_common.dart';

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

  /// 打开 viewer 时的照片索引与网格滚动位置：
  /// 返回定位规则（对标系统相册）——向后滑→目标行贴视口底部；
  /// 向前滑→贴顶部；翻回原位→恢复打开时的网格视口。
  int _openViewerIndex = 0;
  double _openScrollOffset = 0;

  // ── 批量选择模式：长按 cell 进入，勾选后底部操作栏执行批量操作 ──
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  /// ente Gallery 选择态（勾选渲染用）；_selectedIds 保持真源，双向同步。
  final SelectedFiles _selection = SelectedFiles();

  /// 视图模式：false=沉浸网格(默认)；true=日期分组视图。
  bool _timelineView = false;

  void _enterSelectMode(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
      _syncSelection();
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
      _selection.clearAll();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      _syncSelection();
    });
  }

  /// 组头点击（选择模式）：切换该组全选（aves 交互）。
  /// 走 _selectedIds 真源再回写 _selection——修复原 ente 行为只改
  /// SelectedFiles 导致批量栏按钮不启用/操作作用于空集的问题。
  void _toggleGroupSelection(List<MsImageInfo> files) {
    setState(() {
      final ids = files.map((f) => f.id).toSet();
      if (ids.every(_selectedIds.contains)) {
        _selectedIds.removeAll(ids);
      } else {
        _selectedIds.addAll(ids);
      }
      _syncSelection();
    });
  }

  /// 组头长按（非选择模式）：进入选择模式并全选该组（aves 交互，
  /// 一步到位的批量整理入口——「删掉这一天」两次交互完成）。
  void _longPressGroupToSelect(List<MsImageInfo> files) {
    setState(() {
      _selectMode = true;
      _selectedIds.addAll(files.map((f) => f.id));
      _syncSelection();
    });
  }

  /// 把 _selectedIds 同步进 ente SelectedFiles（Gallery 勾选渲染用）。
  void _syncSelection() {
    final photos = ref.read(galleryControllerProvider).photos;
    _selection.replaceSelection(
      photos.where((p) => _selectedIds.contains(p.id)).toSet(),
    );
  }

  /// 切换沉浸网格/日期分组视图。切到日期视图时强制按创建日期排序
  /// （日期分组依赖 dateCreated 顺序；切回沉浸保留原排序偏好）。
  void _toggleViewMode() {
    setState(() => _timelineView = !_timelineView);
    // 持久化视图偏好（重进相册保持）。
    ref.read(configProvider.notifier).state = ref
        .read(configProvider)
        .copyWith(photoTimelineView: _timelineView);
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
    // 飞行层稳定性:返回(pop,route reverse)开始时冻结网格滚动——停止滚动惯性
    // 动画,飞行层(Positioned 缩小的实时渲染)保持静态网格,不与缩小叠加闪烁。
    // ModalRoute.of 依赖 _ModalScopeStatus(inherited)，initState 调用会触发
    // dependOnInheritedWidgetOfExactType assert（debug 构建）→ didChangeDependencies。
  }

  Animation<double>? _routeAnim;
  bool _routeStatusHooked2 = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeStatusHooked2) {
      final anim = ModalRoute.of(context)?.animation;
      if (anim != null) {
        _routeStatusHooked2 = true;
        _routeAnim = anim;
        anim.addStatusListener(_onRouteStatus);
      }
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    // pop(reverse)开始时曾用 _scrollCtrl.jumpTo(offset) 冻结滚动惯性,但 jumpTo
    // 即使值相同也会触发 ScrollPosition.notifyListeners() → GridView /
    // ScrollDragHandle 重算 → 动画一开始内容上下跳一下(沉浸抖;日期视图的
    // _timelineScrollCtrl 不 jumpTo 故不抖)。飞行层用静态截图(RawImage),
    // 惯性只影响截图完成前 1-2 帧,可忽略,故移除。
  }

  @override
  void dispose() {
    _routeAnim?.removeStatusListener(_onRouteStatus);
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _timelineScrollCtrl.removeListener(_onTimelineScroll);
    _timelineScrollCtrl.dispose();
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
        if (!didPop && _selectMode) {
          _exitSelectMode();
          return;
        }
        if (didPop) {
          // 退出相册：保存桶快照（同桶重进秒出）+ 重查相册列表（返回首页
          // 刷新 count/封面）。不能在 dispose 里 ref.read——riverpod 断言
          // "Cannot use ref after the widget was disposed"（debug 红屏）。
          ref.read(galleryControllerProvider.notifier).exitBucket();
        }
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
                    child: Padding(
                      // 收藏/回收站没有右侧视图切换按钮(48px)——补右距
                      // 对齐普通相册排序图标位置（否则紧贴屏幕右缘）。
                      padding: EdgeInsets.only(
                        // 收藏/回收站没有右侧视图切换按钮(48px)——补右距
                        // 对齐标准 action 图标边距（视觉距右缘 ~18px）。
                        right: (widget.favoritesOnly || widget.trashedOnly)
                            ? 24
                            : 0,
                      ),
                      child: SortToggle(
                        // 日期视图固定按创建日期，只留升/降序
                        sortBy: _timelineView
                            ? SortBy.dateCreated
                            : gallery.effectivePhotoSortBy,
                        asc: gallery.photoSortAsc,
                        // dateOnly 仅在日期视图实际生效时（收藏/回收站
                        // 不走日期视图 body，但 _timelineView 若从普通相册
                        // 偏好恢复为 true，会把菜单误砍成只剩升/降序）。
                        dateOnly:
                            _timelineView &&
                            !widget.favoritesOnly &&
                            !widget.trashedOnly,
                        // 回收站视图额外提供「按删除日期」
                        showDateTrashed: widget.trashedOnly,
                        onChanged: (by, asc) => ref
                            .read(galleryControllerProvider.notifier)
                            .setPhotoSort(by, asc),
                      ),
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
                        ref,
                        _timelineView ? 'view_immersive' : 'view_date',
                      ),
                      onPressed: _toggleViewMode,
                    ),
                ],
        ),
        // 视图切换淡入（TweenAnimationBuilder）：AnimatedSwitcher 的交叉
        // 淡化要求新旧 child **同时挂载**——两个视图的 Gallery 共享
        // ScrollController 时双 attach 崩溃（"ScrollController attached
        // to multiple scroll views"，模拟器红屏实证：视图切换/排序切换
        // 均触发）。TweenAnimationBuilder key 变化时旧 child 先卸载
        // （scrollable detach）再挂新 child 淡入——无重叠挂载，保留淡入
        // 效果且彻底杜绝双 attach 崩溃。
        // edge-to-edge 沉浸：bottom:false——网格延伸画到屏幕物理底边（手势条
        // 悬浮在照片上，系统自动对比取色）；末行避让由 Gallery 尾部 inset
        // sliver 承担（gallery.dart）。选择态底栏出现时 Scaffold 自动垫高 body。
        body: SafeArea(
          bottom: false,
          child: TweenAnimationBuilder<double>(
            key: ValueKey(_timelineView),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: AppDurations.enteContentSwitch,
            curve: Curves.easeOut,
            builder: (_, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: _buildBody(gallery),
          ),
        ),
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
    // [ente 移植] 沉浸网格：ente Gallery（SectionedSliverList 分组网格 +
    // 自定义滚动条 + 2px 间距；间距/布局与 ente 一致）。
    // Gallery 依赖外层 GalleryFilesState + GalleryBoundariesProvider（ente
    // CollectionPage 同款包装：GalleryFilesState 提供 files、BoundariesProvider
    // 供 PinnedGroupHeader 定位）。
    return GalleryBoundariesProvider(
      key: const ValueKey('grid'),
      child: GalleryFilesState(
        child: Gallery(
          allFiles: photos,
          tagPrefix: 'photo',
          groupType: GroupType.none,
          // selectedFiles 恒传（非选择模式 files 为空）：保证 Gallery 内
          // SelectionState 包裹结构恒定——若按 _selectMode 切 null，进入/
          // 退出选择模式时 child 位置变化导致网格子树整体重建（无 GlobalKey
          // → 旧 CustomScrollView 未 detach 新的已 attach）→ debug 红屏
          // "attached to multiple scroll views"、release 渲染 ErrorWidget
          // 灰盒 + AnimatedSwitcher 淡化 = 半透明灰遮罩盖住网格。
          selectedFiles: _selection,
          // 非选择模式组头/PinnedGroupHeader 不显示全选圈。
          showSelectAll: _selectMode,
          inSelectionMode: _selectMode,
          // 收藏视图：所有项都是收藏项，红心徽标冗余 → 隐藏。
          hideFavoriteBadge: widget.favoritesOnly,
          crossAxisCount: cols,
          sortOrderAsc: !gallery.photoSortAsc,
          scrollController: _scrollCtrl,
          emptyState: const SizedBox.shrink(),
          onFileTap: (file) {
            final i = photos.indexOf(file);
            if (i < 0) return;
            _selectMode
                ? _toggleSelect(file.id)
                : _openViewer(context, gallery, photos, i, null);
          },
          onFileLongPress: (file) {
            if (!_selectMode) _enterSelectMode(file.id);
          },
          onGroupHeaderToggle: _toggleGroupSelection,
          onGroupHeaderLongPress: _longPressGroupToSelect,
        ),
      ),
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
    // [ente 移植] 日期分组视图：ente Gallery（GroupType.day 分组 +
    // PinnedGroupHeader 吸附头 + 自定义滚动条联动）。
    return GalleryBoundariesProvider(
      key: const ValueKey('timeline'),
      child: GalleryFilesState(
        child: Gallery(
          allFiles: photos,
          tagPrefix: 'photo',
          groupType: GroupType.day,
          // 同沉浸视图：selectedFiles 恒传防网格子树重建（双 attach 红屏/
          // release 灰遮罩）；组头全选圈仅选择模式显示。
          selectedFiles: _selection,
          showSelectAll: _selectMode,
          inSelectionMode: _selectMode,
          hideFavoriteBadge: widget.favoritesOnly,
          crossAxisCount: cols,
          sortOrderAsc: !gallery.photoSortAsc,
          scrollController: _timelineScrollCtrl,
          emptyState: const SizedBox.shrink(),
          onFileTap: (file) {
            final i = photos.indexOf(file);
            if (i < 0) return;
            _selectMode
                ? _toggleSelect(file.id)
                : _openViewer(context, gallery, photos, i, null);
          },
          onFileLongPress: (file) {
            if (!_selectMode) _enterSelectMode(file.id);
          },
          onGroupHeaderToggle: _toggleGroupSelection,
          onGroupHeaderLongPress: _longPressGroupToSelect,
        ),
      ),
    );
  }

  /// 日期标签：今天/昨天/M月d日/YYYY年M月d日（跨年带年份）。
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
    // edge-to-edge：不用 SafeArea（其内容避让会让 Container 色止步于手势条
    // 上缘，条区露 Scaffold 背景黑条）——Container 自垫 bottomInset，背景
    // （surface）延伸到物理底边，内容避让手势条。
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.only(
        top: 6,
        bottom: 6 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Row(children: ops),
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
    toast(
      context,
      err == null ? t(ref, 'unfavorited') : t(ref, 'favorite_failed'),
    );
  }

  /// viewer 翻页：飞行层返回动画跟随当前照片——更新飞行层图 + 滚动网格到
  /// 目标行 + 计算终点 cell 位置。滚动在 viewer 打开期间后台执行（用户无感），
  /// 返回时目标行已在正确位置（缩略图也随滚动预加载）。
  void _onViewerIndexChanged(int index) {
    final photos = ref.read(galleryControllerProvider).photos;
    if (index < 0 || index >= photos.length) return;
    // 翻页时立即滚动网格到当前行(jumpTo 无动画):Hero pop 时 cell 必须在视口
    // (GridView lazy build,视口外 cell 无 RenderObject → Hero 找不到飞回目标)。
    // viewer 盖住网格,滚动用户无感;返回时 cell 已在正确位置 + 缩略图已预加载。
    _scrollToCellRow(index);
  }

  /// 滚动网格让目标行可见。返回定位规则（对标系统相册）：
  /// - 向后滑（index > 打开时）→ 目标行贴视口**底部**（成为最后可见行）
  /// - 向前滑（index < 打开时）→ 目标行贴视口**顶部**（成为第一行）
  /// - 翻回原位 → 恢复打开时的网格视口
  /// 滚动在 viewer 打开期间后台执行（用户无感），返回时目标行已在正确位置。
  /// [ente 移植] 网格已换 ente Gallery：行高 = cellW + 2px 间距；日期视图
  /// 额外累加组头 32（GroupHeaderWidget 高），组边界用 GroupType.day 判定。
  void _scrollToCellRow(int index) {
    final cols = ref.read(configProvider).photoGridColumns;
    final screen = MediaQuery.sizeOf(context);
    final cellW = (screen.width - (cols - 1) * GalleryGroups.spacing) / cols;
    final cellH = cellW + GalleryGroups.spacing;
    final ctrl = _timelineView ? _timelineScrollCtrl : _scrollCtrl;
    if (!ctrl.hasClients) return;
    // 网格实际视口高（AppBar/底部安全区之外）——用 screen.height 会高估
    // 行数：贴底计算把目标行滚到"全屏底"，行落在网格视口下方被切半
    //（返回飞行终点 cell 半截出视口，动画观感差）。
    final viewportH = ctrl.position.viewportDimension;
    double target;
    if (_timelineView) {
      final photos = ref.read(galleryControllerProvider).photos;
      // 组高模型与 SectionedListSliver 布局公式**完全同构**（否则估算误差
      // 在组多时累积——真机 99 组曾因每组多算 1 个 spacing(2px) 高估
      // ~198px → scroll 滚过头 → 目标行顶被导航栏整个盖住）：
      //   组高 = 组头32 + rows×tileHeight + (rows-1)×spacing
      //   行高 = tileHeight + spacing（tileHeight = cellW）
      // 即每组 = 32 + rows×cellH - spacing。
      const spacing = GalleryGroups.spacing;
      var groupTop = 0.0; // 目标组的组头起始 offset（滚动到此时组头贴视口顶）
      var photosInGroup = 0;
      for (var i = 0; i <= index && i < photos.length; i++) {
        if (i > 0 &&
            !GroupType.day.areFromSameGroup(photos[i - 1], photos[i])) {
          final rows = (photosInGroup + cols - 1) ~/ cols;
          groupTop += 32 + rows * cellH - spacing;
          photosInGroup = 0;
        }
        photosInGroup++;
      }
      // index 所在行：组头 + 组内前序行的偏移。
      final rowInGroup = (photosInGroup - 1) ~/ cols;
      final rowTop = groupTop + 32 + rowInGroup * cellH;
      if (index == _openViewerIndex) {
        target = _openScrollOffset;
      } else if (index > _openViewerIndex) {
        // 贴底：目标行下沿贴视口底（该行成为"最后完整可见行"，下一行
        // 整行不可见——与用户定义一致）。
        target = rowTop + cellH - viewportH;
      } else {
        // 贴顶：组内第一行 → 组头贴视口顶、目标行完整露在组头下（32）；
        // 组内后续行 → 组头滚出、PinnedGroupHeader（判定已提前）吸附显示
        // 当前组、目标行仍完整可见。
        target = groupTop + rowInGroup * cellH;
      }
    } else {
      final row = index ~/ cols;
      final viewportRows = (viewportH / cellH).floor();
      if (index == _openViewerIndex) {
        target = _openScrollOffset;
      } else if (index > _openViewerIndex) {
        // 贴底：目标行成为视口最后一行（最小滚动）
        target = (row - viewportRows + 1) * cellH;
      } else {
        // 贴顶：目标行成为视口第一行
        target = row * cellH;
      }
    }
    _jumpToCell(ctrl, target);
  }

  void _jumpToCell(ScrollController ctrl, double target) {
    ctrl.jumpTo(target.clamp(0.0, ctrl.position.maxScrollExtent));
  }

  void _openViewer(
    BuildContext context,
    GalleryState gallery,
    List<MsImageInfo> photos,
    int index,
    Rect? cellRect,
  ) {
    _openViewerIndex = index;
    // 按视图记录打开时的滚动 offset（日期视图用独立 controller，翻回原位时恢复）。
    _openScrollOffset = _timelineView
        ? (_timelineScrollCtrl.hasClients ? _timelineScrollCtrl.offset : 0)
        : (_scrollCtrl.hasClients ? _scrollCtrl.offset : 0);
    // 点击瞬间发起原图（1152 物理宽下采样，~1MP）precache：IO+解码与 400ms 动画
    // 并行，动画结束（completed）时 cache 命中 → viewer 立即清晰。此前试过移除
    // precache 或延后到动画尾部——动画结束后明显模糊（渐进加载），且扁图卡顿
    // 与 precache 无关（移除后仍卡，另行排查），故恢复点击瞬间版。
    // targetWidth 必须与 photo_viewer computeViewerTargetWidth 同值（ImageCache key）。
    final info = photos[index];
    final imgRef = imageRefFromMediaStoreId(
      info.id,
      extension: extOf(info.name),
    );
    precacheImage(
      buildImageProvider(
        imgRef,
        targetWidth: computeViewerTargetWidth(
          MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context),
        ),
      ),
      context,
    );
    Navigator.of(context).push(
      // [ente 移植] 完全复刻 ente routeToPage（navigation_util _buildPageRoute）：
      // Align + FadeTransition 200ms + opaque:false。无黑遮罩、无门控——
      // viewer（含 PageView 预渲染 ±1 页）随 fade 一起淡入 = 中间图淡入淡出、
      // 上下图随之淡入的观感；Hero 飞行层在 overlay 独立负责 cell→大图缩放。
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        opaque: false,
        transitionsBuilder: (ctx, anim, _, child) {
          return Align(
            child: FadeTransition(opacity: anim, child: child),
          );
        },
        pageBuilder: (_, _, _) => DetailPage(
          files: photos,
          initialIndex: index,
          onIndexChanged: _onViewerIndexChanged,
        ),
        settings: const RouteSettings(name: AlbumRoutes.photoViewer),
        fullscreenDialog: true,
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
