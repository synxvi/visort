// 从 album_screen.dart 拆出。相比拆分前的增强：
//   - 分页联动：滚动到接近末尾且 hasMore 时回调 [onLoadMore]，外部新数据经
//     didUpdateWidget 合并进本地列表，大相册可一路滑到底（原版本只能看已加载页）。
//   - 删除后从列表移除当前项，自动跳到下一张（或末尾）。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/middle_ellipsis_text.dart';
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

class _PhotoViewerState extends ConsumerState<PhotoViewer>
    with SingleTickerProviderStateMixin {
  late final ExtendedPageController _pageCtrl;
  late List<MsImageInfo> _photos;
  late int _index;
  OverlayEntry? _barEntry;
  final ValueNotifier<bool> _barVisible = ValueNotifier(false);

  /// 顶/底栏淡入淡出。显式 AnimationController 驱动 Opacity，每帧 markNeedsBuild
  /// 刷新 OverlayEntry——比 AnimatedOpacity 可靠（后者在 OverlayEntry 重建路径下
  /// 隐式动画会失效，曾出现"淡出有动画、淡入无动画"的不对称）。
  late final AnimationController _chromeFade;
  bool _loadingMore = false;

  /// 本次浏览中**已加载完成全图**的照片 id 集合。
  /// dispose 时逐个 evict（2880px 大图 ≈ 数十 MB/张，残留会撑爆 ImageCache →
  final Set<String> _viewedIds = {};
  // canScrollPage 钩子承担（见 build），不再需要自研指针计数/边界状态。
  // 2880 的解码已由 album 端 _openViewer 的 precacheImage 在点击瞬间发起；此处
  bool _allowFull = false;
  // viewer 全图下采样目标宽（屏宽物理×0.8，build 时算；evict 复用同值匹配 ImageCache key）。
  int _viewerTargetWidth = 1152;
  // ─────────────── 详情面板(上划信息)同步动画 ───────────────
  // 面板占比(0..1,相对屏高):单一驱动源,联动图片上推 / 顶栏淡出 / 底栏随面板上移。
  // 由 ModalBottomSheet 的路由动画(开/关)与 DraggableScrollableSheet 的拖拽通知共同写入。
  final ValueNotifier<double> _panelExtent = ValueNotifier(0);
  bool _detailsOpen = false;
  /// 图片区(面板上方)下滑/点击收起的全屏手势层。随面板打开插入、关闭移除;
  /// 独立于模态内容(不随路由滑动),只覆盖面板上方,故不干扰面板拖拽。
  OverlayEntry? _dismissEntry;

  @override
  void initState() {
    super.initState();
    _chromeFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(() => _barEntry?.markNeedsBuild());
    // 面板占比变化 → 刷新 Overlay 顶/底栏(顶栏淡出、底栏上移均随占比联动)。
    _panelExtent.addListener(_onPanelExtent);
    _photos = List.of(widget.photos);
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _pageCtrl = ExtendedPageController(initialPage: _index);
    final tr = widget.transition;
    // 始终监听 route 动画 status：completed → 放行原图；dismissed → 移除栏。
    // 无条件 add——之前 `if(!_allowFull) addStatusListener` 在 _allowFull 初值
    // 为 true 时漏 add，dismissed 永不触发，栏残留覆盖相册/首页。
    tr?.addStatusListener(_onTransitionStatus);
    if (tr == null) {
      _allowFull = true;
    } else {
      _allowFull = tr.status == AnimationStatus.completed;
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
    // 返回动画结束（dismissed）：立即移除栏。PageRouteBuilder(opaque:false) 下
    // page 的 dispose 会延迟甚至不触发，而栏挂在 root Overlay 不随 route 消失，
    // 必须主动 remove——否则返回相册/首页后顶/底栏残留覆盖网格（已实测复现）。
    if (status == AnimationStatus.dismissed) {
      _chromeFade.stop();
      _barEntry?.remove();
      _barEntry = null;
    }
  }

  @override
  void dispose() {
    widget.transition?.removeStatusListener(_onTransitionStatus);
    // 移除 Overlay 顶/底栏 + 释放状态
    _barEntry?.remove();
    _barEntry = null;
    _dismissEntry?.remove();
    _dismissEntry = null;
    _chromeFade.dispose();
    _barVisible.dispose();
    _panelExtent.dispose();
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
      _chromeFade.forward();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      _chromeFade.reverse();
      // 右滑直接触发返回，不会被系统消费用于“显示系统栏/再次滑动返回”。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// 放大：隐藏栏 + immersiveSticky；缩回 1.0：恢复栏 + edgeToEdge。触发时机是"放大"，
  void _onZoomStateChanged(bool zoomed) {
    if (!mounted) return;
    if (zoomed) {
      _barVisible.value = false;
      _chromeFade.reverse();
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
      builder: (_) {
        final opacity = _chromeFade.value;
        // 面板占比联动顶栏淡出(沉浸)。底栏固定不动,面板从底栏上沿向上生长。
        final extent = _panelExtent.value;
        final topVis = (1 - extent / _kDetailInitial).clamp(0.0, 1.0);
        return Stack(
          children: [
            // 顶部渐变遮罩栏：返回 + 当前照片时间 | 计数器
            // 面板展开时随占比淡出至隐藏(沉浸);关闭时随占比回落恢复。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Opacity(
                opacity: opacity * topVis,
                child: IgnorePointer(
                  ignoring: opacity * topVis < 0.5,
                  child: Material(
                    // 纯黑栏跟随 chromeFade 整体淡入淡出（沉浸时黑底一起消失，不残留）。
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
            // 固定在屏幕底部不动;面板从本栏上沿向上生长,黑底无缝衔接。
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Opacity(
                opacity: opacity,
                child: IgnorePointer(
                  ignoring: opacity < 0.5,
                  child: Material(
                    color: Colors.black,
                    child: _BottomChromeBar(
                      onInfo: _toggleDetails,
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
        );
      },
    );
    overlay.insert(_barEntry!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _barVisible.value = true;
        // 首次立即置 1（不 forward 淡入）：栏瞬间黑底就位盖住栏区飞行层图，避免
        // "图→黑"渐变闪烁。后续 _toggleChrome 走 forward/reverse 正常淡入淡出。
        _chromeFade.value = 1.0;
      }
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
            t(ref, 'delete_permanently_desc'),
            style: const TextStyle(
              fontFamily: 'Space Mono',
              fontFamilyFallback: ['Noto Sans Mono CJK SC'],
              color: AppColors.muted,
              fontSize: 13,
            ),
          ),
          actions: [
            // 左右布局：左取消、右确认（danger 红色填充）
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
        title: Text(
          t(ref, 'delete_confirm'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.text,
            fontSize: 15,
          ),
        ),
        actions: [
          // 左右布局：左取消、右确认（danger 红色填充）
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
        title: Text(
          t(ref, 'action_restore'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.text,
            fontSize: 15,
          ),
        ),
        content: Text(
          t(ref, 'restore_desc'),
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
    // 最后一张:直接退出,不 setState——否则 viewer 会先 rebuild 成空 SizedBox
    // (build 里 _photos.isEmpty → SizedBox.shrink),在 pop 动画期间露出一帧
    // 空白,表现为回收站空时返回动画灰/黑屏闪一下。
    if (_photos.length <= 1) {
      Navigator.pop(context);
      toast(context, t(ref, toastKey));
      return;
    }
    setState(() {
      _photos.removeAt(_index);
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
      MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: _photos.isEmpty
          ? const SizedBox.shrink()
          : Stack(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: _panelExtent,
                  builder: (_, extent, pageView) {
                    // 图片随面板上推:面板从底栏上沿向上生长,占 extent×可用区高;
                    // 图片上移该高度的一半 → 居中主体落在面板上方可见区,且无空白。
                    // 可用区 = 屏高 − 底栏高(面板锚定在底栏上方,extent 相对可用区)。
                    final mq = MediaQuery.of(context);
                    final availH = mq.size.height -
                        (_kBottomChromeHeight + mq.viewPadding.bottom);
                    // clamp ≥ 0:杜绝关闭回弹时图片「过冲到正常位置以下」的闪烁
                    // (任何使 extent 瞬时为负的边角时序都只会让图片停在原位,而非下冲)。
                    final pushPx =
                        (extent * availH * _kImagePushFactor).clamp(0.0, availH);
                    return Transform.translate(
                      offset: Offset(0, -pushPx),
                      child: pageView,
                    );
                  },
                  child: RepaintBoundary(
                    // 隔离图片层光栅化:外层 Transform.translate 只移动已缓存的图层,
                    // 避免每帧重新光栅化大图导致的偶发闪烁。
                    child: ExtendedImageGesturePageView.builder(
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
                  ),
                ),
              ],
            ),
    );
  }

  /// 切换详情面板(底栏 info 按钮入口):开则关、关则开。
  void _toggleDetails() {
    if (_detailsOpen) {
      Navigator.of(context).maybePop();
    } else if (_photos.isNotEmpty) {
      _showDetails(_photos[_index]);
    }
  }

  /// 详情面板占比变化 → 刷新 Overlay 顶/底栏 + 收起手势层(下沿跟随面板顶部)。
  void _onPanelExtent() {
    _barEntry?.markNeedsBuild();
    _dismissEntry?.markNeedsBuild();
  }

  /// 详情面板关闭收尾(路由动画 dismissed 后由 host 回调 / Future 兜底)。
  void _onDetailsDismissed() {
    _detailsOpen = false;
    _panelExtent.value = 0;
    _dismissEntry?.remove();
    _dismissEntry = null;
  }

  /// 插入图片区(面板上方)的收起手势层:下滑或点击 → 收起面板。
  /// 覆盖区域下沿跟随面板顶部(_panelExtent),只覆盖面板上方,不干扰面板自身的拖拽/滚动。
  /// 独立于模态内容(挂在 root Overlay、不随路由滑动),故关闭时无全屏平移导致的闪烁。
  void _insertDismissLayer() {
    _dismissEntry = OverlayEntry(
      builder: (ctx) => ValueListenableBuilder<double>(
        valueListenable: _panelExtent,
        builder: (_, extent, _) {
          final mq = MediaQuery.of(ctx);
          final barH = _kBottomChromeHeight + mq.viewPadding.bottom;
          final availH = mq.size.height - barH;
          final panelTopFromBottom = barH + extent * availH;
          return Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: panelTopFromBottom,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 应用内任意位置(面板上方)下滑或点击即收起。
              onTap: () => Navigator.of(ctx).maybePop(),
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 0) {
                  Navigator.of(ctx).maybePop();
                }
              },
            ),
          );
        },
      ),
    );
    Overlay.of(context).insert(_dismissEntry!);
  }

  /// 显示当前照片的详情面板(ColorOS 相册式卡片栈)。
  //
  // 同步动画:_panelExtent(0..1,相对屏高)是图片上推 / 顶栏淡出 / 底栏上移的唯一驱动源:
  //   - 开/关过程:由 ModalBottomSheet 路由动画(0→1 滑入 / 1→0 滑出)插值写入,与面板滑动严格同步;
  //   - 拖拽/吸附:路由动画落定(completed)后,由 DraggableScrollableNotification.extent 写入。
  // 图片上推量 = 面板像素高 × _kImagePushFactor(0.5):面板从底部升起遮挡屏幕下 e·H,
  // 图片整体上移 e·H/2 后,可见区[0, H−e·H]恰好显示图像居中主体[e·H/2, H−e·H/2],无大面积空白。
  void _showDetails(MsImageInfo info) {
    if (_detailsOpen) return;
    _detailsOpen = true;
    // 面板打开期间底栏需随面板上移、顶栏淡出:强制栏可见(edge-to-edge)。
    if (!_barVisible.value) {
      _barVisible.value = true;
      _chromeFade.forward();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // 透明遮罩:图片不被压暗,上推后居中主体清晰可见(对标系统相册)。
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: false,
      // 关闭模态自带的 enableDrag:它会在拖拽结束时把面板动画重绑到 Split 曲线,
      // 与本文件 _onAnim 用的 legacyDecelerate 不同步 → 从面板下滑收起时图片下沿闪烁。
      // DraggableScrollableSheet 自带拖拽缩放 + min 时通知关闭,面板仍可拖动/收起。
      enableDrag: false,
      // 整体动画比默认(进 250ms / 出 200ms)略快,也让关闭后遮罩更快消失 →
      // 关闭后能更快重新上划触发面板(否则关闭动画期间遮罩仍拦截图片手势)。
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 200),
        reverseDuration: Duration(milliseconds: 150),
      ),
      builder: (_) => _SyncedDetailsSheet(
        info: info,
        panelExtent: _panelExtent,
        onDismissed: _onDetailsDismissed,
      ),
    ).then((_) {
      // 路由 Future 在面板完全关闭时完成:作为 _detailsOpen 复位的兜底,
      // 与 host 的 onDismissed 双保险(任一路径都保证能再次上划唤起)。
      // 路由 Future 在 pop 时立即 complete,不等关闭动画结束(这是 Flutter 行为)。
      // 不能在此调 _onDetailsDismissed——它会把 _panelExtent 强行归零,而此时路由
      // reverse 动画才刚开始、_onAnim 正用 _closeStartExtent 驱动图片平滑回落,
      // 提前归零会让图片瞬间落底、再被 _onAnim 拉回 → 收尾闪烁。
      // 这里只复位非视觉状态;视觉归零交给路由动画真正结束时由
      // _SyncedDetailsSheet._onStatus(dismissed)→onDismissed→_onDetailsDismissed。
      if (mounted && _detailsOpen) {
        _detailsOpen = false;
        _dismissEntry?.remove();
        _dismissEntry = null;
      }
    });
    // 插入图片区收起手势层(在模态之后插入 → 位于模态之上;不随路由滑动)。
    _insertDismissLayer();
  }
}

/// 详情面板容器:在 ModalBottomSheet 内,把路由动画(开/关滑动)与拖拽 extent 统一写入
/// [panelExtent],从而与图片上推 / 顶栏淡出 / 底栏上移严格同步。
/// didChangeDependencies 一次性绑定路由动画监听(builder 可能重入,避免重复 addListener)。
class _SyncedDetailsSheet extends StatefulWidget {
  const _SyncedDetailsSheet({
    required this.info,
    required this.panelExtent,
    required this.onDismissed,
  });
  final MsImageInfo info;
  final ValueNotifier<double> panelExtent;
  final VoidCallback onDismissed;

  @override
  State<_SyncedDetailsSheet> createState() => _SyncedDetailsSheetState();
}

class _SyncedDetailsSheetState extends State<_SyncedDetailsSheet> {
  Animation<double>? _anim;
  bool _attached = false;
  bool _dismissed = false;
  double _closeStartExtent = 0;
  /// DSS 控制器:关闭触发时 jumpTo(min) 冻结面板尺寸,取消释放后的 snap/fling,
  /// 使其在路由 reverse 期间恒定,与 _onAnim 驱动的图片上推同步。
  final DraggableScrollableController _dssController =
      DraggableScrollableController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_attached) return;
    _attached = true;
    _anim = ModalRoute.of(context)?.animation;
    _anim?.addListener(_onAnim);
    _anim?.addStatusListener(_onStatus);
  }

  // 路由动画驱动开/关过程的占比,与面板滑入/滑出严格同步。
  void _onAnim() {
    final a = _anim;
    if (a == null) return;
    // 面板滑动用 CurvedAnimation 包了 Easing.legacyDecelerate;若这里用原始线性值,
    // 图片上推/回落会与面板不同步 → 面板下沿处闪烁(尤其图片下半部)。对原始动画值
    // 施加相同曲线,二者严丝合缝。(拖拽关闭时走 DSS extent 通知,不经此处,无此问题。)
    final t = Easing.legacyDecelerate.transform(a.value);
    if (a.status == AnimationStatus.forward) {
      widget.panelExtent.value = _kDetailInitial * t;
    } else if (a.status == AnimationStatus.reverse) {
      widget.panelExtent.value = _closeStartExtent * t;
    }
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      // forward 末帧 value=1 时 status 可能已切到 completed → _onAnim 跳过,
      // 这里补一帧精确落定到目标,避免占比停在 ~99%(顶栏残留微透明)。
      widget.panelExtent.value = _kDetailInitial;
      // 预记录落定值:reverse 首帧的 value 监听(_onAnim)可能先于 status 监听触发,
      // 若此时才捕获 _closeStartExtent 会用到旧值(0)→ 占比瞬间跳到 0 → 图片/顶栏闪烁。
      // 在落定/拖拽时持续记录,reverse 起点即始终有效。
      _closeStartExtent = _kDetailInitial;
    } else if (s == AnimationStatus.dismissed) {
      // 路由完全关闭:无条件重置外层 _detailsOpen。不再用 !_dismissed 守卫——
      // 拖拽关闭路径会先置 _dismissed=true,旧守卫会跳过此处导致 _detailsOpen
      // 不复位 → 之后上划再也无法唤起面板。
      widget.onDismissed();
    }
  }

  @override
  void dispose() {
    _anim?.removeListener(_onAnim);
    _anim?.removeStatusListener(_onStatus);
    _dssController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 面板锚定在底栏上方:底部留出底栏高度,DraggableScrollableSheet 从底栏上沿生长。
    // 保持内容为「仅面板」(非全屏)——路由开/关动画只平移面板自身高度,
    // 与图片上推回落的幅度同尺度,避免全屏内容平移整屏导致面板先飞走、留出黑色空隙。
    final barH = _kBottomChromeHeight + MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: barH),
      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: (n) {
          // 路由动画落定后,拖拽/吸附占比直接驱动(开/关过程由路由动画接管)。
          if (_anim?.status == AnimationStatus.completed) {
            widget.panelExtent.value = n.extent;
            _closeStartExtent = n.extent; // 持续记录当前占比,关闭时插值起点始终有效
          }
          // 拖到最小尺寸以下 → 关闭。先 jumpTo(min) 冻结面板尺寸:取消拖拽释放后的
          // snap/fling,使其不在路由 reverse 期间继续改变尺寸(否则与 _onAnim 驱动的
          // 图片上推不同步 → 从信息栏下滑收起时图片抖动)。maybePop 后路由 reverse,
          // 面板尺寸恒定,与图片严格同步。
          if (!_dismissed && n.extent <= n.minExtent + 0.01) {
            _dismissed = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              try {
                _dssController.jumpTo(n.minExtent);
              } catch (_) {}
            });
            Navigator.of(context).maybePop();
          }
          return false;
        },
        child: DraggableScrollableSheet(
          controller: _dssController,
          // 默认展开相比旧 0.6 缩小约 1/4;snap 保留(无 snap 时拖拽惯性更晃)。
          // 关闭抖动由上面的 jumpTo(min) 冻结解决,而非关闭 snap。
          initialChildSize: _kDetailInitial,
          minChildSize: _kDetailMin,
          maxChildSize: _kDetailMax,
          snapSizes: const [_kDetailInitial, _kDetailSnapHigh],
          snap: true,
          expand: false,
          builder: (_, controller) =>
              PhotoDetailsSheet(info: widget.info, scrollController: controller),
        ),
      ),
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
              // 图片名称（中段省略保留扩展名）
              // Expanded 占满空间把序号推到最右；内部 ConstrainedBox 收窄
              // 实际文字宽度（左对齐），让省略号提前出现、不紧贴序号。
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: MiddleEllipsisText(
                      info.name,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 13,
                        fontFamily: 'Space Mono',
                        height: 1.2,
                        fontFamilyFallback: AppFonts.cjkFallback,
                      ),
                      padding: const EdgeInsets.only(right: 12),
                    ),
                  ),
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
                    fontFamily: 'Space Mono',
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
        height: _kBottomChromeHeight,
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
              tooltip: t(
                ref,
                isFavorite ? 'action_unfavorite' : 'action_favorite',
              ),
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
    final dt = DateTime.fromMillisecondsSinceEpoch(
      ms - 30 * 24 * 60 * 60 * 1000,
    );
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
  Timer? _chromeTapTimer;
  Duration? _lastChromeTapAt;

  @override
  void initState() {
    super.initState();
    _isGif =
        widget.info.mime == 'image/gif' || extOf(widget.info.name) == '.gif';
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
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _BigImage old) {
    super.didUpdateWidget(old);
  }

  @override
  void dispose() {
    _chromeTapTimer?.cancel();
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
    final ref = imageRefFromMediaStoreId(
      widget.info.id,
      extension: extOf(widget.info.name),
    );
    return Listener(
      onPointerDown: _handleSwipeDown,
      onPointerMove: _handleSwipeMove,
      onPointerUp: _handleSwipeUp,
      onPointerCancel: (_) => _resetSwipeTrack(),
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
          // 手势过程允许缩小到 0.5（双指向内拖动），松手弹回 minScale=1.0（正常大小）。
          // extended_image: animationMinScale 是过程下限，minScale 是回弹目标。
          animationMinScale: 0.5,
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
                child: Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.muted,
                  size: 48,
                ),
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
    );
  }

  /// 上划详情：未放大时单指快速上划 → 详情面板。
  void _handleSwipeDown(PointerDownEvent e) {
    _doubleTapAnim.stop();
    if (_trackPointer != null) return;
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
    // 单指快速上划（未放大时）→ 详情面板。放大时禁用，避免与平移冲突。
    if (_currentScale <= 1.05 &&
        delta.dy < -48 &&
        delta.dy.abs() > delta.dx.abs() * 1.3) {
      widget.onSwipeUp?.call();
      return;
    }
    // 单击（小位移）→ 切换栏。带双击抑制：300ms 内的第二次小位移 up
    // 视为双击，取消挂起的单击，交给 ExtendedImage.onDoubleTap 缩放。
    // Listener 在 pointer 层不参与竞技场，避免与 ExtendedImage 双击识别器抢手势
    // （原 GestureDetector.onTapUp 方案下第二次 tap 被库双击吃掉，单击不稳）。
    // 放大时也允许单击切换栏——否则放大隐藏栏后无法恢复（用户反馈"回不来"）。
    if (delta.distance < 18) {
      final last = _lastChromeTapAt;
      if (last != null &&
          (e.timeStamp - last) < const Duration(milliseconds: 300)) {
        _lastChromeTapAt = null;
        _chromeTapTimer?.cancel();
        return;
      }
      _lastChromeTapAt = e.timeStamp;
      _chromeTapTimer?.cancel();
      _chromeTapTimer = Timer(const Duration(milliseconds: 300), () {
        widget.onTapChrome();
      });
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
              MediaQuery.devicePixelRatioOf(context),
        ),
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
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 1.0);
}

// ─────────────── 详情面板(上划信息)同步动画参数 ───────────────

/// 底栏内容行高(不含安全区 inset);面板以此垫高,锚定在底栏上方生长。
const double _kBottomChromeHeight = 64.0;

/// 默认展开占比(相对「屏高 − 底栏高」可用区):相比旧 0.6×屏高 缩小约 1/4。
const double _kDetailInitial = 0.5;
const double _kDetailMin = 0.15;
const double _kDetailMax = 0.95;
const double _kDetailSnapHigh = 0.8;
/// 图片上推量 = 面板像素高度 × 此系数。0.5 使图片居中主体落在面板上方可见区,
/// 且可见区无大面积空白(图像刚好覆盖,见 _showDetails 设计推导)。
const double _kImagePushFactor = 0.5;
