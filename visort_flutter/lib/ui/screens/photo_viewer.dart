// 从 album_screen.dart 拆出。相比拆分前的增强：
//   - 分页联动：滚动到接近末尾且 hasMore 时回调 [onLoadMore]，外部新数据经
//     didUpdateWidget 合并进本地列表，大相册可一路滑到底（原版本只能看已加载页）。
//   - 删除后从列表移除当前项，自动跳到下一张（或末尾）。

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';

import 'album_common.dart';
import 'photo_details_sheet.dart';

/// 分页联动：[onLoadMore] 在滚动接近末尾且 [hasMore] 为真时回调，外部应触发相册
/// loadMore 并把新数据经 [photos] 重新传入（viewer 通过 didUpdateWidget 追加新条目）。
class PhotoViewer extends ConsumerStatefulWidget {
  const PhotoViewer({
    super.key,
    required this.photos,
    required this.initialIndex,
    this.hasMore = false,
    this.totalCount,
    this.onLoadMore,
    this.onIndexChanged,
    this.transition,
  });

  final List<MsImageInfo> photos;
  final int initialIndex;
  /// 相册内是否还有更多未加载的图片（用于触发 loadMore）。
  final bool hasMore;
  /// 相册图片总数（来自 bucket.count，仅用于底部计数器显示）。
  final int? totalCount;
  /// 滚动接近末尾时的回调，外部触发分页加载。
  final Future<void> Function()? onLoadMore;
  final ValueChanged<int>? onIndexChanged;
  final Animation<double>? transition;

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  late final ExtendedPageController _pageCtrl;
  late List<MsImageInfo> _photos;
  late int _index;
  OverlayEntry? _barEntry;
  final ValueNotifier<bool> _barVisible = ValueNotifier(false);
  bool _loadingMore = false;
  /// 本次浏览中**已加载完成全图**的照片 id 集合。
  /// dispose 时逐个 evict（2880px 大图 ≈ 数十 MB/张，残留会撑爆 ImageCache →
  final Set<String> _viewedIds = {};
  // canScrollPage 钩子承担（见 build），不再需要自研指针计数/边界状态。
  // 2880 的解码已由 album 端 _openViewer 的 precacheImage 在点击瞬间发起；此处
  bool _allowFull = false;
  // viewer 全图下采样目标宽（屏宽物理×0.8，build 时算；evict 复用同值匹配 ImageCache key）。
  int _viewerTargetWidth = 1152;

  @override
  void initState() {
    super.initState();
    _photos = List.of(widget.photos);
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _pageCtrl = ExtendedPageController(initialPage: _index);
    final tr = widget.transition;
    if (tr == null) {
      _allowFull = true;
    } else {
      _allowFull = tr.status == AnimationStatus.completed;
      if (!_allowFull) {
        tr.addStatusListener(_onTransitionStatus);
      }
    }
    // 顶/底栏插入 Navigator Overlay（route 之上）：点击打开立即浮现（50ms 淡入），
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _insertBars();
    });
  }

  /// reverse（返回）不重置 _allowFull：原图保留在树中，返回时无清晰度跳变。
  void _onTransitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && !_allowFull) {
      setState(() => _allowFull = true);
    }
  }

  @override
  void dispose() {
    widget.transition?.removeStatusListener(_onTransitionStatus);
    // 移除 Overlay 顶/底栏 + 释放状态
    _barEntry?.remove();
    _barEntry = null;
    _barVisible.dispose();
    _pageCtrl.dispose();
    // 离开页面恢复 edge-to-edge，避免影响其他页的系统栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Evict 本次浏览过的大图（2880px，数十 MB/张）。
    // 不清网格用的 300 缩略图（evictViewerImageCache 只清 1024 + 全图）。
    // 之前"临时去掉 evict"导致大图残留 → ImageCache 占满 → 滚动掉帧单调恶化
    // （实测多次进出后 30→10fps）。只 evict 实际加载过的（_viewedIds），
    // 而非全量遍历 _photos（可能几百张），避免 dispose 时 GC 峰值。
    for (final id in _viewedIds) {
      evictViewerImageCache(id, _viewerTargetWidth);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部 photos 增长（loadMore 完成）：追加本地不存在的条目（按 id 去重）。
    if (widget.photos.length != oldWidget.photos.length) {
      final existingIds = _photos.map((p) => p.id).toSet();
      for (final p in widget.photos) {
        if (!existingIds.contains(p.id)) {
          _photos.add(p);
        }
      }
    }
  }

  /// 滚动到接近末尾时触发分页加载（距离末尾 < 5 张且 hasMore）。
  Future<void> _maybeLoadMore() async {
    if (!widget.hasMore || _loadingMore) return;
    final remaining = _photos.length - _index;
    if (remaining > 5) return;
    final cb = widget.onLoadMore;
    if (cb == null) return;
    setState(() => _loadingMore = true);
    try {
      await cb();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 点击图片：切换顶/底栏遮罩 + 系统栏显隐。
  void _toggleChrome() {
    _barVisible.value = !_barVisible.value;
    if (_barVisible.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      // 右滑直接触发返回，不会被系统消费用于“显示系统栏/再次滑动返回”。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// 放大：隐藏栏 + immersiveSticky；缩回 1.0：恢复栏 + edgeToEdge。触发时机是"放大"，
  void _onZoomStateChanged(bool zoomed) {
    if (!mounted) return;
    if (zoomed) {
      _barVisible.value = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    // 缩回 1.0：不自动恢复栏——放大隐藏 UI 后缩小保持隐藏，由单击（_toggleChrome）
  }

  bool _canScrollPage(GestureDetails? details) {
    if (details == null) return true;
    final scale = details.totalScale ?? 1.0;
    if (scale <= 1.0) return true;
    final vw = details.layoutRect?.width ?? 0;
    final sw = vw * scale;
    if (sw <= vw) return true;
    final maxDx = (sw - vw) / 2;
    final dx = details.offset?.dx ?? 0;
    return dx.abs() >= maxDx - 0.5;
  }

  void _insertBars() {
    final overlay = Overlay.of(context);
    _barEntry = OverlayEntry(
      builder: (_) => ValueListenableBuilder<bool>(
        valueListenable: _barVisible,
        builder: (ctx, visible, _) => Stack(
          children: [
            // 顶部渐变遮罩栏：返回 + 当前照片时间 | 计数器
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: visible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 50),
                curve: Curves.easeOutCubic,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: Material(
                    // ⚠️ OverlayEntry 无 Material 祖先：Text 会回退到
                    // DefaultTextStyle.fallback（自带黄色下划线警告），必须包 Material
                    // 提供标准文本样式，黄线才会消失。
                    color: Colors.black,
                    child: _TopChromeBar(
                      info: _photos[_index],
                      index: _index,
                      total: widget.totalCount ?? _photos.length,
                      onBack: () => Navigator.maybePop(context),
                    ),
                  ),
                ),
              ),
            ),
            // 底部渐变遮罩栏：info 详情 | delete 删除
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: visible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 50),
                curve: Curves.easeOutCubic,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: Material(
                    color: Colors.black,
                    child: _BottomChromeBar(
                      onInfo: () => _showDetails(_photos[_index]),
                      onDelete: _deleteCurrent,
                      isFavorite: _photos[_index].isFavorite,
                      onFavorite: _toggleFavoriteCurrent,
                      isTrashed: _photos[_index].isTrashed,
                      dateTrashedMs: _photos[_index].dateTrashedMs,
                      onRestore: _photos[_index].isTrashed
                          ? _restoreCurrent
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    overlay.insert(_barEntry!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _barVisible.value = true;
    });
  }

  Future<void> _deleteCurrent() async {
    if (_photos.isEmpty) return;
    final current = _photos[_index];
    final controller = ref.read(galleryControllerProvider.notifier);
    if (current.isTrashed) {
      // 回收站视图：彻底删除。恢复已拆到底栏独立按钮，不再用三选项弹窗。
      // 确认弹窗风格与恢复/普通删除一致：左取消、右确认（danger 红色填充）。
      final confirmed = await showCenterDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(t(ref, 'delete_permanently'),
              style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.text, fontSize: 15)),
          content: Text(t(ref, 'delete_permanently_desc'),
              style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted, fontSize: 13)),
          actions: [
            // 左右布局：左取消、右确认（danger 红色填充）
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(t(ref, 'cancel'),
                        style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        foregroundColor: AppColors.bg),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(t(ref, 'confirm')),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final err = await controller.deletePhoto(current.id);
      if (err != null) {
        if (mounted) toast(context, t(ref, 'delete_failed'));
        return;
      }
      _removeCurrentAndAdvance('deleted');
      return;
    }
    // 普通视图：删除 = 移入回收站（与系统相册一致；回收站内可恢复/彻底删除）
    final confirmed = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(t(ref, 'delete_confirm'),
            style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.text, fontSize: 15)),
        actions: [
          // 左右布局：左取消、右确认（danger 红色填充）
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t(ref, 'cancel'),
                      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      foregroundColor: AppColors.bg),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await controller.trashPhoto(current.id);
    if (err != null) {
      if (mounted) toast(context, t(ref, 'trash_unsupported'));
      return;
    }
    _removeCurrentAndAdvance('trashed');
  }

  /// 恢复当前照片（回收站视图底栏恢复按钮）。确认弹窗风格与彻底删除一致：
  /// 左取消、右确认（accent 蓝色——恢复为积极操作，与删除的 danger 红对照）。
  Future<void> _restoreCurrent() async {
    if (_photos.isEmpty) return;
    final current = _photos[_index];
    final confirmed = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(t(ref, 'action_restore'),
            style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.text, fontSize: 15)),
        content: Text(t(ref, 'restore_desc'),
            style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted, fontSize: 13)),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t(ref, 'cancel'),
                      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.bg),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final controller = ref.read(galleryControllerProvider.notifier);
    final err = await controller.restorePhoto(current.id);
    if (err != null) {
      if (mounted) toast(context, t(ref, 'restore_failed'));
      return;
    }
    _removeCurrentAndAdvance('restored');
  }

  /// 删除/恢复成功后从列表移除当前项并跳到下一张（或末张），刷新 chrome 计数。
  /// 回收站的恢复、彻底删除与普通删除（移入回收站）共用此收尾逻辑。
  void _removeCurrentAndAdvance(String toastKey) {
    if (!mounted) return;
    setState(() {
      _photos.removeAt(_index);
      if (_photos.isEmpty) {
        // 最后一张已移除：直接强制退出（Navigator.pop 不走 PopScope 拦截）。
        Navigator.pop(context);
        return;
      }
      _index = _index >= _photos.length ? _photos.length - 1 : _index;
    });
    // Overlay 顶/底栏显示当前照片信息，移除后刷新
    _barEntry?.markNeedsBuild();
    widget.onIndexChanged?.call(_index);
    if (_pageCtrl.hasClients) {
      Future.microtask(() {
        if (mounted && _pageCtrl.hasClients) {
          _pageCtrl.jumpToPage(_index);
        }
      });
    }
    toast(context, t(ref, toastKey));
  }

  /// 收藏/取消收藏当前照片（P1b）。同步本地 _photos 副本。
  Future<void> _toggleFavoriteCurrent() async {
    if (_photos.isEmpty) return;
    final current = _photos[_index];
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .toggleFavorite(current);
    if (!mounted) return;
    if (err != null) {
      toast(context, t(ref, 'favorite_failed'));
      return;
    }
    setState(() {
      final p = _photos[_index];
      _photos[_index] = MsImageInfo(
        id: p.id,
        name: p.name,
        size: p.size,
        mime: p.mime,
        bucketId: p.bucketId,
        dateAddedMs: p.dateAddedMs,
        dateModifiedMs: p.dateModifiedMs,
        isFavorite: !p.isFavorite,
        isTrashed: p.isTrashed,
        dateTrashedMs: p.dateTrashedMs,
        width: p.width,
        height: p.height,
      );
    });
    // Overlay 底栏收藏图标刷新
    _barEntry?.markNeedsBuild();
    toast(context, t(ref, current.isFavorite ? 'unfavorited' : 'favorited'));
  }

  @override
  Widget build(BuildContext context) {
    _viewerTargetWidth = computeViewerTargetWidth(
        MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context));
    return Scaffold(
      backgroundColor: Colors.black,
      body: _photos.isEmpty
          ? const SizedBox.shrink()
            : Stack(
                children: [
                  ExtendedImageGesturePageView.builder(
                    controller: _pageCtrl,
                    physics: const _SnapSpringPhysics(),
                    itemCount: _photos.length,
                    canScrollPage: _canScrollPage,
                    onPageChanged: (i) {
                      setState(() => _index = i);
                      widget.onIndexChanged?.call(i);
                      _barEntry?.markNeedsBuild();
                      _maybeLoadMore();
                    },
                    itemBuilder: (ctx, i) {
                      final info = _photos[i];
                      // 两图之间留一点黑色间隙。
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _BigImage(
                          info: info,
                          active: i == _index,
                          loadFull: _allowFull,
                          onTapChrome: _toggleChrome,
                          onSwipeUp: () => _showDetails(info),
                          onZoomStateChanged: _onZoomStateChanged,
                          onFullLoaded: (id) => _viewedIds.add(id),
                        ),
                      );
                    },
                  ),
                ],
              ),
    );
  }

  /// 显示当前照片的详情面板(ColorOS 相册式卡片栈)。
  void _showDetails(MsImageInfo info) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: false,
      builder: (ctx) {
        var dismissed = false;
        return NotificationListener<DraggableScrollableNotification>(
          onNotification: (n) {
            if (!dismissed && n.extent <= n.minExtent + 0.01) {
              dismissed = true;
              Navigator.of(ctx).maybePop();
            }
            return false;
          },
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.2,
            maxChildSize: 0.95,
            snapSizes: const [0.6, 0.9],
            snap: true,
            expand: false,
            builder: (_, controller) =>
                PhotoDetailsSheet(info: info, scrollController: controller),
          ),
        );
      },
    );
  }
}

/// 顶部渐变遮罩栏：黑色自上而下渐变（深→透明），对标系统相册 top_decoration。
/// 内容：[左] 返回 + 当前照片时间  [右] 计数器 n / total
class _TopChromeBar extends ConsumerWidget {
  const _TopChromeBar({
    required this.info,
    required this.index,
    required this.total,
    required this.onBack,
  });
  final MsImageInfo info;
  final int index;
  final int total;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topInset = MediaQuery.viewPaddingOf(context).top;
    return Container(
      decoration: const BoxDecoration(color: Colors.black),
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                // 与相册页 AppBar 返回箭头对齐：AppBar leading 宽 56，IconButton
                // 被 Center 居中（左缘 4dp），IconButton 内 icon 在 padding 内居中
                // （默认 padding 8 时 icon 左缘 8+4=12dp）→ 箭头图标左缘 = 16dp。
                // 这里 padding 左 16 + icon 24 + 右 8 = 48，内容区恰好 24 无居中偏移。
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                icon: const Icon(Icons.arrow_back, color: AppColors.text),
                tooltip: t(ref, 'back'),
                onPressed: onBack,
              ),
              // 当前照片时间（系统相册式：智能日期 + HH:MM）
              Expanded(
                child: Text(
                  _smartDate(ref, info.dateAddedMs),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'Space Mono', height: 1.2,
                    fontFamilyFallback: AppFonts.cjkFallback,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 计数器
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  '${index + 1} / $total',
                  style: TextStyle(
                    color: AppColors.text.withValues(alpha: 0.7),
                    fontSize: 13,
                    fontFamily: 'Space Mono', height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 智能日期：今天→「今天 HH:MM」/ 昨天→「昨天 HH:MM」/ 否则「YYYY-MM-DD HH:MM」
  String _smartDate(WidgetRef ref, int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diffDays = today.difference(that).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(dt.hour)}:${two(dt.minute)}';
    if (diffDays == 0) return '${t(ref, 'today')} $hm';
    if (diffDays == 1) return '${t(ref, 'yesterday')} $hm';
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} $hm';
  }
}

/// 底部渐变遮罩栏：黑色自上而下渐变（透明→深），对标系统相册 bottom_decoration。
/// 内容：[左] info 详情  [右] delete 删除，中间留白。
class _BottomChromeBar extends ConsumerWidget {
  const _BottomChromeBar({
    required this.onInfo,
    required this.onDelete,
    required this.isFavorite,
    required this.onFavorite,
    this.onRestore,
    this.isTrashed = false,
    this.dateTrashedMs = 0,
  });
  final VoidCallback onInfo;
  final VoidCallback onDelete;
  final bool isFavorite;
  final VoidCallback onFavorite;
  /// 回收站项恢复回调；非 null 时在删除按钮左侧显示恢复按钮（icon）。
  final VoidCallback? onRestore;
  /// 回收站项：是否已删除（决定是否显示删除日期）。
  final bool isTrashed;
  /// 删除日期（DATE_EXPIRES * 1000）；>0 时显示。
  final int dateTrashedMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      decoration: const BoxDecoration(color: Colors.black),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: 64,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.info_outline, color: AppColors.text),
              tooltip: t(ref, 'photo_details'),
              onPressed: onInfo,
            ),
            IconButton(
              icon: Icon(
                isFavorite ? Icons.favorite : Icons.favorite_border,
                color: isFavorite ? AppColors.danger : AppColors.text,
              ),
              tooltip: t(ref, isFavorite ? 'action_unfavorite' : 'action_favorite'),
              onPressed: onFavorite,
            ),
            const Spacer(),
            // 回收站项：删除按钮左侧显示删除日期
            if (isTrashed && dateTrashedMs > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _TrashDateLabel(ms: dateTrashedMs),
              ),
            // 回收站恢复按钮（删除按钮左侧，icon 表示）——把原三选项弹窗里的
            // 「恢复」提升为底栏独立操作，与删除形成左恢复 / 右删除的并列入口。
            if (onRestore != null)
              IconButton(
                icon: const Icon(Icons.restore, color: AppColors.accent),
                tooltip: t(ref, 'action_restore'),
                onPressed: onRestore,
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              tooltip: t(ref, 'delete_photo'),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 回收站项底栏的删除日期标签：两行小字「删除于 / MM-DD」。
class _TrashDateLabel extends ConsumerWidget {
  const _TrashDateLabel({required this.ms});
  final int ms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // DATE_EXPIRES 是「过期时间」= 移入回收站时刻 + 30 天（AOSP 默认保留期）；
    // 删除日期 ≈ DATE_EXPIRES − 30 天。（排序仍用 DATE_EXPIRES，相对顺序=删除顺序）
    final dt = DateTime.fromMillisecondsSinceEpoch(ms - 30 * 24 * 60 * 60 * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    final dateStr = '${two(dt.month)}-${two(dt.day)}';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t(ref, 'trash_deleted_label'),
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 10,
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
          ),
        ),
        Text(
          dateStr,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 12,
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
          ),
        ),
      ],
    );
  }
}

/// 由 image provider 切换 + loadStateChanged 承担。
class _BigImage extends StatefulWidget {
  const _BigImage({
    required this.info,
    required this.active,
    required this.onTapChrome,
    this.loadFull = false,
    this.onZoomStateChanged,
    this.onFullLoaded,
    this.onSwipeUp,
  });
  final MsImageInfo info;
  final bool active;
  final VoidCallback onTapChrome;
  /// _openViewer 的 precacheImage 在点击瞬间发起，此处只门控原图层进树时机。
  final bool loadFull;
  final void Function(bool zoomed)? onZoomStateChanged;
  /// 原图（下采样）加载完成时回调，外层记录 id 用于退出时 evict。
  final void Function(String mediaStoreId)? onFullLoaded;
  final VoidCallback? onSwipeUp;

  @override
  State<_BigImage> createState() => _BigImageState();
}

class _BigImageState extends State<_BigImage>
    with SingleTickerProviderStateMixin {
  ExtendedImageGestureState? _gestureState;
  double _currentScale = 1.0;
  double? _imageAspect;
  bool _wasZoomed = false;
  // Decelerate ≈ 系统相册 DecelerateInterpolator(2.5)：快进慢出
  late final AnimationController _doubleTapAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..addListener(_onDoubleTapTick);
  Tween<double>? _doubleTapTween;
  Offset _doubleTapPos = Offset.zero;
  bool _fullLoaded = false;
  bool _hdTriggered = false;
  late final bool _isGif;
  int? _trackPointer;
  Offset? _trackDown;
  Offset? _trackLast;

  @override
  void initState() {
    super.initState();
    _isGif = widget.info.mime == 'image/gif' ||
        extOf(widget.info.name) == '.gif';
  }

  void _onGestureDetailsChanged(GestureDetails? details) {
    if (details == null) return;
    final scale = details.totalScale ?? 1.0;
    _currentScale = scale;
    if (!_isGif && !_hdTriggered && scale > 1.3) {
      setState(() => _hdTriggered = true);
    }
    final zoomed = scale > 1.05;
    if (zoomed != _wasZoomed) {
      _wasZoomed = zoomed;
      widget.onZoomStateChanged?.call(zoomed);
    }
  }

  void _onDoubleTapTick() {
    final state = _gestureState;
    final tween = _doubleTapTween;
    if (state == null || tween == null) return;
    state.handleDoubleTap(
      scale: tween.evaluate(_doubleTapAnim),
      doubleTapPosition: _doubleTapPos,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureImageAspect();
  }

  Future<void> _ensureImageAspect() async {
    if (_imageAspect != null) return;
    final info = widget.info;
    if (info.width > 0 && info.height > 0) {
      _imageAspect = info.width / info.height;
      return;
    }
    try {
      final meta = await MediaStoreChannel().readMeta(info.id);
      if (mounted && meta.width > 0 && meta.height > 0) {
        _imageAspect = meta.width / meta.height;
      }
    } catch (_) {
    }
  }

  @override
  void didUpdateWidget(covariant _BigImage old) {
    super.didUpdateWidget(old);
  }

  @override
  void dispose() {
    _doubleTapAnim.dispose();
    super.dispose();
  }

  /// 目标倍率自适应：未放大 → max(2.5, coverRatio) 铺满屏幕消除黑边；
  /// 与旧自研 toScene + clamp 算法效果一致）。
  void _onDoubleTap(ExtendedImageGestureState state) {
    _gestureState = state;
    final pointerDown = state.pointerDownPosition;
    if (pointerDown == null) return;
    final begin = state.gestureDetails?.totalScale ?? 1.0;
    final zooming = begin <= 1.01;
    final targetScale = zooming ? _computeDoubleTapTarget() : 1.0;
    _doubleTapPos = pointerDown;
    _doubleTapTween = Tween(begin: begin, end: targetScale);
    _doubleTapAnim
      ..stop()
      ..value = 0.0;
    // animateTo 而非 fling：fling(0.4) 经 ClampingSimulation 实际约 1.5s，
    _doubleTapAnim.animateTo(
      1.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.decelerate,
    );
  }

  //  coverRatio = max(imgAspect/vpAspect, vpAspect/imgAspect) = cover/contain 倍率，
  double _computeDoubleTapTarget() {
    final ia = _imageAspect;
    // viewport = ExtendedImage 区域：屏宽 - 8（两侧 4px 间隙）、屏高。
    final screen = MediaQuery.sizeOf(context);
    final vp = Size(screen.width - 8, screen.height);
    if (vp.width <= 0 || vp.height <= 0 || ia == null || ia <= 0) {
      return 2.5; // 尺寸未就绪 fallback
    }
    final viewportAspect = vp.width / vp.height;
    final r = ia / viewportAspect;
    final coverRatio = r >= 1 ? r : 1 / r; // = max(r, 1/r) ≥ 1
    final target = coverRatio > 2.5 ? coverRatio : 2.5;
    if (target < 1.0) return 1.0;
    if (target > 5.0) return 5.0;
    return target;
  }

  @override
  Widget build(BuildContext context) {
    final ref = imageRefFromMediaStoreId(widget.info.id,
        extension: extOf(widget.info.name));
    final zoomed = _currentScale > 1.05;
    return Listener(
      onPointerDown: _handleSwipeDown,
      onPointerMove: _handleSwipeMove,
      onPointerUp: _handleSwipeUp,
      onPointerCancel: (_) => _resetSwipeTrack(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Tap 输（不闪栏）；单击需等 double-tap 超时(~300ms)才触发（与旧版一致）。
        onTapUp: zoomed ? null : (_) => widget.onTapChrome(),
        child: ExtendedImage(
        image: widget.loadFull
            ? _providerFor(ref)
            : buildThumbnailProvider(ref, size: 300),
        fit: BoxFit.contain,
        // 用户反馈"采样分辨率特别差"）；medium 与 InteractiveViewer 时代观感一致。
        filterQuality: FilterQuality.medium,
        // gaplessPlayback: image 切换（300→1536→HD）时不置 loading——否则库
        gaplessPlayback: true,
        mode: ExtendedImageMode.gesture,
        enableLoadState: true,
        initGestureConfigHandler: (state) => GestureConfig(
          minScale: 1.0,
          maxScale: 5.0,
          animationMinScale: 1.0,
          animationMaxScale: 5.0,
          speed: 1.0,
          inertialSpeed: 100,
          initialScale: 1.0,
          inPageView: true,
          gestureDetailsIsChanged: _onGestureDetailsChanged,
        ),
        onDoubleTap: _onDoubleTap,
        loadStateChanged: (state) {
          if (state.extendedImageLoadState == LoadState.loading) {
            state.returnLoadStateChangedWidget = true;
            return Image(
              image: buildThumbnailProvider(ref, size: 300),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (ctx, error, stack) => const Center(
                child: Icon(Icons.broken_image_outlined,
                    color: AppColors.muted, size: 48),
              ),
            );
          }
          if (state.extendedImageLoadState == LoadState.completed &&
              !_fullLoaded) {
            // 首层（300）加载完成 → 切下采样原图；原图就绪后不再触发。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => _fullLoaded = true);
                // 通知外层记录 id：退出 viewer 时 evict。
                widget.onFullLoaded?.call(widget.info.id);
              }
            });
          }
          return null;
        },
      ),
      ),
    );
  }

  /// 上划详情：未放大时单指快速上划 → 详情面板。
  void _handleSwipeDown(PointerDownEvent e) {
    _doubleTapAnim.stop();
    if (_trackPointer != null || _currentScale > 1.05) return;
    _trackPointer = e.pointer;
    _trackDown = e.position;
    _trackLast = e.position;
  }

  void _handleSwipeMove(PointerMoveEvent e) {
    if (e.pointer != _trackPointer) return;
    final last = _trackLast;
    if (last == null) return;
    _trackLast = e.position;
  }

  void _handleSwipeUp(PointerUpEvent e) {
    if (e.pointer != _trackPointer) return;
    final down = _trackDown;
    final up = e.position;
    _resetSwipeTrack();
    if (down == null) return;
    final delta = up - down;
    // 单指快速上划：向上位移 > 90px 且以向上为主（dx 不超过 dy 的 2/3）。
    if (delta.dy < -90 && delta.dy.abs() > delta.dx.abs() * 1.5) {
      widget.onSwipeUp?.call();
    }
  }

  void _resetSwipeTrack() {
    _trackPointer = null;
    _trackDown = null;
    _trackLast = null;
  }

  ImageProvider _providerFor(ImageRef ref) {
    if (_isGif || _hdTriggered) {
      return buildImageProvider(ref, targetWidth: null);
    }
    if (_fullLoaded) {
      return buildImageProvider(
        ref,
        targetWidth: computeViewerTargetWidth(
            MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context)),
      );
    }
    return buildThumbnailProvider(ref, size: 300);
  }
}

/// 页对齐由 _PagePosition 保证，这里只调 spring 参数。
class _SnapSpringPhysics extends ScrollPhysics {
  const _SnapSpringPhysics({super.parent});
  @override
  _SnapSpringPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapSpringPhysics(parent: buildParent(ancestor));
  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 300,
        ratio: 1.0,
      );
}
