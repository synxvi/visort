// 从 album_screen.dart 拆出。相比拆分前的增强：
//   - 分页联动：滚动到接近末尾且 hasMore 时回调 [onLoadMore]，外部新数据经
//     didUpdateWidget 合并进本地列表，大相册可一路滑到底（原版本只能看已加载页）。
//   - 删除后从列表移除当前项，自动跳到下一张（或末尾）。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
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
    with TickerProviderStateMixin {
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
  /// 图片区(面板上方)下滑/点击收起的全屏手势层。随面板打开插入、关闭移除。
  OverlayEntry? _dismissEntry;
  // 详情面板用 Overlay 自有实现(不经 showModalBottomSheet 路由 + DSS:二者组合下
  // DSS 松手的 snap/fling 会卡 route ticker,且 snap 开关无法同时满足"不卡"与"无
  // 中间态")。_panelCtrl 单一驱动面板位移 + 图片上推,严格同步、无路由、自定义 snap。
  AnimationController? _panelCtrl;
  OverlayEntry? _panelEntry;
  /// 底栏缩略图条（对标系统相册 photo_page ThumbLine）。独立 OverlayEntry：
  /// 显隐由 _chromeFade × _panelExtent 组合驱动（ValueListenableBuilder 内部重建，
  /// 不随 _barEntry markNeedsBuild）。滚动/吸附/联动由 ScrollController + 手写居中吸附
  /// （对标系统相册 ThumbLineLayoutManager 手写居中，非 SnapHelper/PageView）。
  OverlayEntry? _thumbEntry;
  ScrollController? _thumbScrollCtrl;
  /// 实时居中项（滚动中更新，驱动单项高亮）。
  ValueNotifier<int>? _thumbCenterIndex;
  /// 主图→缩略图条程序滚动标记：期间忽略滚动联动，防回环。
  bool _thumbSyncing = false;
  /// 缩略图条驱动主图 animateToPage 期间标记:主图跨多页时中间页 onPageChanged 据此
  /// 忽略,不回弹缩略图条。到达 target(i==_index) 复位,另有超时兜底。
  bool _pagerDrivenByThumb = false;

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
      if (mounted) {
        _insertBars();
        _insertThumbLine();
      }
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
    _panelEntry?.remove();
    _panelEntry = null;
    _panelCtrl?.dispose();
    _panelCtrl = null;
    _thumbEntry?.remove();
    _thumbEntry = null;
    _thumbScrollCtrl?.dispose();
    _thumbScrollCtrl = null;
    _thumbCenterIndex?.dispose();
    _thumbCenterIndex = null;
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
      // 缩略图条 itemCount 随 _photos 增长刷新（loadMore 后）。
      _thumbEntry?.markNeedsBuild();
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

  /// 插入底栏缩略图条（对标系统相册 photo_page ThumbLine）。独立 OverlayEntry，
  /// 插入到 _barEntry 之下：后续 _panelEntry（详情面板）也 below _barEntry 插入 →
  /// 落在缩略图条之上，面板展开时自然覆盖缩略图条区域。显隐由 _chromeFade ×
  /// _panelExtent 组合驱动（顶栏同款逻辑）。
  void _insertThumbLine() {
    if (_photos.isEmpty) return;
    _thumbScrollCtrl = ScrollController();
    _thumbCenterIndex = ValueNotifier<int>(_index);
    _thumbScrollCtrl!.addListener(_onThumbScroll);
    _thumbEntry = OverlayEntry(
      builder: (_) => Positioned(
        bottom: _kBottomChromeHeight,
        left: 0,
        right: 0,
        height: _kThumbLineHeight,
        child: ValueListenableBuilder<double>(
          // 面板占比 → 缩略图条淡出（上滑详情时随顶栏一起隐藏）。
          valueListenable: _panelExtent,
          builder: (_, extent, strip) {
            final thumbVis = (1 - extent / _kDetailInitial).clamp(0.0, 1.0);
            return AnimatedBuilder(
              animation: _chromeFade,
              builder: (_, child) {
                final vis = _chromeFade.value * thumbVis;
                // 下滑滑出 + 淡出，比纯 alpha 更有"沉下去"的丝滑感。
                final dy = (1 - vis) * _kThumbLineHeight;
                return Transform.translate(
                  offset: Offset(0, dy),
                  child: Opacity(
                    opacity: vis,
                    child: IgnorePointer(
                      ignoring: vis < 0.5,
                      child: child,
                    ),
                  ),
                );
              },
              // child 不随显隐重建 → ListView/缩略图不重复构造。
              child: strip,
            );
          },
          // 稳定 child：缩略图条本体。
          child: _ThumbLineStrip(
            photos: _photos,
            controller: _thumbScrollCtrl!,
            centerIndex: _thumbCenterIndex!,
            onTap: _onThumbTap,
            onScrollEnd: _onThumbScrollEnd,
          ),
        ),
      ),
    );
    // below _barEntry：底栏 z 序更高（面板后插入会覆盖缩略图条）。
    final bar = _barEntry;
    if (bar != null) {
      Overlay.of(context).insert(_thumbEntry!, below: bar);
    } else {
      Overlay.of(context).insert(_thumbEntry!);
    }
    // 首帧定位到当前 index 居中（等 layout 就绪）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctrl = _thumbScrollCtrl;
      if (mounted && ctrl != null && ctrl.hasClients) {
        ctrl.jumpTo(_thumbOffsetForCenter(_index));
      }
    });
  }

  /// 缩略图条滚动中：实时算离视口中心最近的项，更新高亮 + 跟手联动主图。
  /// 主图即时 jumpToPage（不 setState 避免主 build 频繁重建）；_index 直接赋值 →
  /// 主图 onPageChanged 命中 `i == _index` 守卫，不回弹缩略图条。
  void _onThumbScroll() {
    if (_thumbSyncing) return;
    final ctrl = _thumbScrollCtrl;
    final ci = _thumbCenterIndex;
    if (ctrl == null || ci == null || !ctrl.hasClients) return;
    final newCenter = _thumbComputeCenter();
    if (newCenter == ci.value) return;
    ci.value = newCenter; // 高亮跟手
    if (newCenter == _index) return;
    // 跟手联动主图：直接赋值 _index（不 setState）+ jumpToPage 即时切换 +
    // markNeedsBuild 刷顶栏计数器。松手 snap 由 _onThumbScrollEnd 接管。
    _index = newCenter;
    widget.onIndexChanged?.call(newCenter);
    _barEntry?.markNeedsBuild();
    if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(newCenter);
    _maybeLoadMore();
  }

  /// 缩略图条滚动停止（fling 减速结束）：吸附最近项到正中 + 联动主图。
  void _onThumbScrollEnd() {
    final ctrl = _thumbScrollCtrl;
    if (ctrl == null || !ctrl.hasClients || _thumbSyncing) return;
    final target = _thumbComputeCenter();
    final offset = _thumbOffsetForCenter(target);
    if ((ctrl.offset - offset).abs() > 0.5) {
      ctrl.animateTo(offset,
          duration: _kThumbSnapDuration, curve: Curves.easeOut);
    }
    if (target != _index) _onThumbPageChanged(target);
  }

  /// 点按缩略图单项 → 主图跳转 + 缩略图条吸附居中。
  void _onThumbTap(int i) {
    if (i == _index) return;
    _onThumbPageChanged(i);
    final ctrl = _thumbScrollCtrl;
    if (ctrl != null && ctrl.hasClients) {
      _thumbSyncing = true;
      ctrl
          .animateTo(_thumbOffsetForCenter(i),
              duration: _kThumbSnapDuration, curve: Curves.easeOut)
          .then((_) => _thumbSyncing = false);
    }
  }

  /// 离视口中心最近的 item index（padding=vw/2−ext/2 时 = round(offset/ext)）。
  int _thumbComputeCenter() {
    final ctrl = _thumbScrollCtrl;
    if (ctrl == null || !ctrl.hasClients) return _index;
    return (ctrl.offset / _kThumbItemExtent)
        .round()
        .clamp(0, _photos.length - 1);
  }

  /// 让 item i 居中所需的 scroll offset（= i × itemExtent）。
  double _thumbOffsetForCenter(int i) => i * _kThumbItemExtent;

  /// 缩略图条滚动停止/点按 → 主图跟随。靠 `i == _index` 天然防回环。
  void _onThumbPageChanged(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    widget.onIndexChanged?.call(i);
    _barEntry?.markNeedsBuild();
    _thumbCenterIndex?.value = i;
    if (_pageCtrl.hasClients) {
      _pagerDrivenByThumb = true;
      // 兜底:万一主图 animateToPage 未触发 target onPageChanged,超时复位防 flag 卡死。
      Future.delayed(_kThumbSyncDuration + const Duration(milliseconds: 80),
          () => _pagerDrivenByThumb = false);
      _pageCtrl.animateToPage(i,
          duration: _kThumbSyncDuration, curve: Curves.easeOut);
    }
    _maybeLoadMore();
  }

  /// 主图翻页 → 缩略图条居中跟随（程序滚动，_thumbSyncing 防回环）。
  void _syncThumbTo(int i) {
    final ctrl = _thumbScrollCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    _thumbSyncing = true;
    _thumbCenterIndex?.value = i;
    ctrl
        .animateTo(_thumbOffsetForCenter(i),
            duration: _kThumbSyncDuration, curve: Curves.easeOut)
        .then((_) => _thumbSyncing = false);
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
          _syncThumbTo(_index); // jumpToPage 触发的 onPageChanged 命中 i==_index 不回弹,故手动同步
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
    // pageBuilder（PageRouteBuilder）只在 push 时执行一次，widget.photos 是打开
    // 瞬间的快照；loadMore 后 gallery state.photos 增长但 widget.photos 不刷新，
    // didUpdateWidget 的合并永不触发 → _photos 卡在第一页（_pageSize=60）→
    // 翻到第 60 张后再也无法右滑。直接监听 provider，把 loadMore 追加的条目
    // 合并进 _photos（删除/收藏等 length 不增长的场景不在此响应）。
    ref.listen(galleryControllerProvider, (_, next) {
      if (next.photos.length <= _photos.length) return;
      final existing = _photos.map((p) => p.id).toSet();
      final added =
          next.photos.where((p) => !existing.contains(p.id)).toList();
      if (added.isEmpty) return;
      setState(() => _photos.addAll(added));
    });
    return PopScope(
      // 面板展开时拦截系统返回:收回面板而非退出大图;关闭时正常返回相册。
      canPop: !_detailsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _detailsOpen) _animateClose();
      },
      child: Scaffold(
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
                      allowImplicitScrolling: true, // 预渲染±1 页：相邻页图片提前解码，翻页时已就绪，减少"某张大图解码慢→手势丢帧→要滑多次"
                      physics: const _SnapSpringPhysics(),
                      itemCount: _photos.length,
                      canScrollPage: _canScrollPage,
                      onPageChanged: (i) {
                        if (_pagerDrivenByThumb) {
                          // 缩略图条驱动主图:跨多页时中间页 onPageChanged 忽略,不回弹缩略图条;
                          // 到达 target(i==_index) 复位 flag。
                          if (i == _index) _pagerDrivenByThumb = false;
                          return;
                        }
                        if (i == _index) return;
                        setState(() => _index = i);
                        widget.onIndexChanged?.call(i);
                        _barEntry?.markNeedsBuild();
                        _syncThumbTo(i);
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
      ),
    );
  }

  /// 切换详情面板(底栏 info 按钮入口):开则关、关则开。
  void _toggleDetails() {
    if (_detailsOpen) {
      _animateClose();
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
    // setState:恢复 PopScope canPop(面板收回后可正常返回退出大图)。
    setState(() => _detailsOpen = false);
    _panelExtent.value = 0;
    _dismissEntry?.remove();
    _dismissEntry = null;
    _panelEntry?.remove();
    _panelEntry = null;
    _panelCtrl?.dispose();
    _panelCtrl = null;
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
              onTap: _animateClose,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 0) {
                  _animateClose();
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
    // setState:PopScope 的 canPop 依赖 _detailsOpen,不重建则系统返回直接退出。
    setState(() => _detailsOpen = true);
    // 面板打开期间底栏需随面板上移、顶栏淡出:强制栏可见(edge-to-edge)。
    if (!_barVisible.value) {
      _barVisible.value = true;
      _chromeFade.forward();
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // Overlay 自有面板:单一 _panelCtrl 驱动面板位移 + 图片上推,严格同步,无路由
    // (不误 pop)、无 DSS (无 snap 卡 ticker)。value 0=关闭/1=展开。
    _panelCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
    )..addListener(() {
        _panelExtent.value = _panelCtrl!.value * _kDetailInitial;
        _panelEntry?.markNeedsBuild();
      });
    _panelCtrl!.value = 0;
    _panelEntry = OverlayEntry(builder: (_) => _buildPanelOverlay(info));
    // 面板条目插入到底栏条目(_barEntry)之下:底栏绘制在面板之上 → 面板从底栏
    // 后面滑入/滑出,动画过程中不再遮挡底栏。仅调整绘制层级,位移/曲线/时长/
    // 图片上推等动画参数一律不变。
    final bar = _barEntry;
    if (bar != null) {
      Overlay.of(context).insert(_panelEntry!, below: bar);
    } else {
      Overlay.of(context).insert(_panelEntry!);
    }
    // 打开:easeOut(前快后慢)。
    _panelCtrl!.animateTo(1,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    // 图片区收起手势层(下滑/点击关闭),位于面板之上。
    _insertDismissLayer();
  }

  /// 关闭:easeIn(前快后慢,不在一半突然加速),完成后移除 Overlay。
  void _animateClose() {
    final ctrl = _panelCtrl;
    if (ctrl == null) return;
    ctrl
        .animateTo(0,
            duration: const Duration(milliseconds: 180), curve: Curves.easeIn)
        .orCancel
        .then((_) {
      if (mounted) _onDetailsDismissed();
    });
  }

  /// 拖拽面板松手:snap 二值(展开/收回),不停在中间。
  void _onPanelDragEnd(DragEndDetails d) {
    final ctrl = _panelCtrl;
    if (ctrl == null) return;
    final v = d.primaryVelocity ?? 0;
    if (v > 300) {
      _animateClose();
    } else if (v < -300) {
      ctrl.animateTo(1,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else if (ctrl.value > 0.5) {
      ctrl.animateTo(1,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _animateClose();
    }
  }

  /// 详情面板 Overlay:固定 _kDetailInitial 可用区高度,Transform 跟随 _panelCtrl
  /// 从屏底滑入/滑出。锚定在底栏上方(bottom: barH)→ 底栏始终可见,面板从底栏上沿
  /// 长出。松手 snap 二值。Material 提供 DefaultTextStyle(消除 Overlay 内 Text 黄线)。
  ///
  /// 手势分层:内容区(ListView)滚内容;内容滚到顶后继续下拉 → OverscrollNotification
  /// → 收回面板(见 [_handlePanelContentScroll]);顶部把手条可随时直接拖面板。
  Widget _buildPanelOverlay(MsImageInfo info) {
    final mq = MediaQuery.of(context);
    final barH = _kBottomChromeHeight + mq.viewPadding.bottom;
    final availH = mq.size.height - barH;
    final panelH = _kDetailInitial * availH;
    final slideOut = panelH + barH;
    return Positioned(
      left: 0,
      right: 0,
      bottom: barH,
      height: panelH,
      child: AnimatedBuilder(
        animation: _panelCtrl!,
        builder: (_, child) {
          final ty = (1 - _panelCtrl!.value) * slideOut;
          return Transform.translate(offset: Offset(0, ty), child: child);
        },
        child: Stack(
          children: [
            Positioned.fill(
              // scrollable:true → 面板内容可滚动(ListView)。拖拽手势只挂在顶部
              // 把手区:内容 Scrollable 与父 GestureDetector 同抢垂直拖拽时子级必赢,
              // 全面板 GestureDetector 会收不到事件,故收窄到把手条互不冲突。
              child: NotificationListener<ScrollNotification>(
                onNotification: _handlePanelContentScroll,
                child: ScrollConfiguration(
                  // 内容区需始终接受拖拽(内容不可滚时默认 physics 会拒绝用户
                  // 拖拽 → 无法通过 overscroll 收回面板),见 _PanelContentPhysics。
                  behavior: const _PanelContentScrollBehavior(),
                  child: Material(
                    type: MaterialType.transparency,
                    child: PhotoDetailsSheet(info: info, scrollable: true),
                  ),
                ),
              ),
            ),
            // 面板顶部把手拖拽区(透明):下拉收起 / 上拉展开面板。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _kPanelDragZone,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) {
                  final ctrl = _panelCtrl;
                  if (ctrl == null) return;
                  ctrl.value =
                      (ctrl.value - d.primaryDelta! / slideOut).clamp(0.0, 1.0);
                },
                onVerticalDragEnd: _onPanelDragEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 面板内容区越界拖拽状态:记录本次手势是否发生过 overscroll(面板联动过),
  /// 及末次越界速率(ScrollEnd 时据此决定 snap 方向,与图片区 dismiss 手感一致)。
  /// 注意:SDK 的 Scroll/OverscrollNotification 不含拖拽速度(velocity 恒 0,
  /// DragUpdateDetails 无 velocity),只能采样 (事件时间戳, 单次过界量) 自算。
  bool _panelOverDragged = false;
  final List<(Duration, double)> _overSamples = [];
  double _lastOverVel = 0;

  /// 面板内容区滚动协调(嵌套滚动):
  ///   - 内容滚到顶后继续下拉 → OverscrollNotification(负)→ 面板随之下移(收回);
  ///   - 内容滚到底后继续上拉 → overscroll(正)→ 面板回升(展开);
  ///   - 松手(ScrollEnd)→ 与图片区(dismiss 层)一致:向下速度即收回,不依赖位移;
  ///     向上速度展开;无速度(缓停)按位置二值。
  /// 内容区范围内的滚动完全交给 ListView,这里只处理越界量(Android 默认
  /// ClampingScrollPhysics 在边界本就发出 OverscrollNotification,无需自定义 physics)。
  bool _handlePanelContentScroll(ScrollNotification n) {
    final ctrl = _panelCtrl;
    if (ctrl == null) return false;
    if (n is ScrollStartNotification) {
      // 新手势开始:重置越界状态(内容普通滚动不触发面板 snap)
      _panelOverDragged = false;
      _overSamples.clear();
      _lastOverVel = 0;
      return false;
    }
    if (n is OverscrollNotification) {
      _panelOverDragged = true;
      final over = n.overscroll;
      final t = n.dragDetails?.sourceTimeStamp;
      if (over != 0 && t != null) {
        _overSamples.add((t, over));
        if (_overSamples.length > 4) _overSamples.removeAt(0);
        if (_overSamples.length >= 2) {
          final a = _overSamples[_overSamples.length - 2];
          final b = _overSamples.last;
          final dtUs = b.$1.inMicroseconds - a.$1.inMicroseconds;
          if (dtUs > 0) {
            // 取反:overscroll 负 = 内容向顶部过界 = 手指向下 → 速度应为正。
            _lastOverVel = -(b.$2 / dtUs * 1e6);
          }
        }
      }
      if (over == 0) return false;
      ctrl.value = (ctrl.value + over / _panelSlideOut).clamp(0.0, 1.0);
      return false; // 不消费:辉光反馈等仍由 Scrollable 内部处理
    }
    if (n is ScrollEndNotification &&
        _panelOverDragged &&
        ctrl.value < 1.0) {
      final v = _lastOverVel;
      if (v > 0) {
        _animateClose();
      } else if (v < 0) {
        ctrl.animateTo(1,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else if (ctrl.value > 0.5) {
        ctrl.animateTo(1,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _animateClose();
      }
      return false;
    }
    return false;
  }

  /// 面板从屏外滑到位的总行程(与 _buildPanelOverlay 的 slideOut 同值)。
  double get _panelSlideOut {
    final mq = MediaQuery.of(context);
    final barH = _kBottomChromeHeight + mq.viewPadding.bottom;
    return _kDetailInitial * (mq.size.height - barH) + barH;
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
  // 惰性创建（首次触摸/双击时）；不用 late final —— dispose 阶段若从未访问过
  // 会在此惰性初始化 AnimationController，而 dispose 中 createTicker 会因
  // TickerMode 祖先查找断言崩溃（widget test 复现）。
  AnimationController? _doubleTapAnim;
  AnimationController get _dblTapAnim =>
      _doubleTapAnim ??= AnimationController(
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
      scale: tween.evaluate(_dblTapAnim),
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
    _doubleTapAnim?.dispose();
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
    _dblTapAnim
      ..stop()
      ..value = 0.0;
    // animateTo 而非 fling：fling(0.4) 经 ClampingSimulation 实际约 1.5s，
    _dblTapAnim.animateTo(
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
    _dblTapAnim.stop();
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

/// 面板顶部把手拖拽区高度:内容 ListView 与面板拖拽手势分离的窄条区域。
const double _kPanelDragZone = 32.0;

/// 面板内容区 physics:默认 physics 在内容不可滚(maxScrollExtent==0,占位/短内容)
/// 时 shouldAcceptUserOffset 返回 false,Scrollable 拒绝用户拖拽 → 下拉无法产生
/// overscroll、面板收不回来。强制接受:内容可滚时行为不变,不可滚时下拉仍能
/// 经 OverscrollNotification 收回面板。
class _PanelContentPhysics extends ClampingScrollPhysics {
  const _PanelContentPhysics({super.parent});

  @override
  _PanelContentPhysics applyTo(ScrollPhysics? ancestor) =>
      _PanelContentPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;
}

/// 供面板内容 ListView 使用的 ScrollBehavior(注入 [_PanelContentPhysics])。
class _PanelContentScrollBehavior extends MaterialScrollBehavior {
  const _PanelContentScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const _PanelContentPhysics().applyTo(super.getScrollPhysics(context));
}

/// 默认展开占比(相对「屏高 − 底栏高」可用区):相比旧 0.6×屏高 缩小约 1/4。
const double _kDetailInitial = 0.5;
/// 图片上推量 = 面板像素高度 × 此系数。0.5 使图片居中主体落在面板上方可见区,
/// 且可见区无大面积空白(图像刚好覆盖,见 _showDetails 设计推导)。
const double _kImagePushFactor = 0.5;

// ─────────────── 底栏缩略图条(ThumbLine,对标系统相册 photo_page)───────────────

/// 缩略图条高度(竖屏):容纳放大后的当前项(42dp)+上下边距。
const double _kThumbLineHeight = 44.0;

/// 每个 item 的固定布局宽度(含间距)。紧凑:对标系统相册 item 21.3dp + 4dp 间距。
/// 用固定 itemExtent 让 ListView 自由 fling(甩一下滚多张减速,非 PageView 一页一停)
/// 且 offset 连续不跳。当前项靠 [AnimatedContainer] 整体放大+底部对齐强调。
const double _kThumbItemExtent = 32.0;

/// 当前(中心)项宽:比普通项(23)大 ~30% = 30。
const double _kThumbCenterW = 30.0;

/// 当前项高:比普通项(32)大 ~30% = 42。底部对齐 → 顶部高出普通项 10dp(强调)。
const double _kThumbCenterH = 42.0;

/// 普通项宽:正常大小。
const double _kThumbNormalW = 23.0;

/// 普通项高:正常大小(32dp)。
const double _kThumbItemH = 32.0;

/// 中心/普通项圆角。
const double _kThumbRadiusCenter = 4.0;
const double _kThumbRadiusNormal = 2.5;

/// 缩略图加载尺寸(px):复用 buildThumbnailProvider,两级渐进(128 占位→96 清晰)。
const int _kThumbLoadSize = 96;

/// 缩略图条→主图联动动画时长(主图翻页跟随缩略图条滚动停止/点按)。
const Duration _kThumbSyncDuration = Duration(milliseconds: 220);

/// 缩略图条滚动停止后吸附居中时长(略短,手感利落)。
const Duration _kThumbSnapDuration = Duration(milliseconds: 180);

/// 底栏缩略图条(对标系统相册 photo_page ThumbLine)。
///
/// 横向 ListView + 固定紧凑 itemExtent,自由 fling(甩一下滚多张慢慢减速,非 PageView 的
/// 一页一停)。居中即选中:[controller] 实时算离视口中心最近的项 → [centerIndex] 高亮;
/// 滚动停止(fling 减速结束)→ [onScrollEnd] 吸附该项到正中 + 联动主图。点按单项 →
/// [onTap] 跳转。系统相册用自定义 ThumbLineLayoutManager 居中对齐(非 SnapHelper),
/// Flutter 用 ListView + ScrollController + 手写吸附等价实现。
class _ThumbLineStrip extends StatelessWidget {
  const _ThumbLineStrip({
    required this.photos,
    required this.controller,
    required this.centerIndex,
    required this.onTap,
    required this.onScrollEnd,
  });

  final List<MsImageInfo> photos;
  final ScrollController controller;

  /// 当前居中项(滚动中实时更新,驱动单项高亮)。
  final ValueListenable<int> centerIndex;

  /// 点按单项 → 主图跳转。
  final ValueChanged<int> onTap;

  /// 滚动停止(fling 减速结束)→ 吸附居中 + 联动主图。
  final VoidCallback onScrollEnd;

  @override
  Widget build(BuildContext context) {
    // padding 让首尾项能滚到视口正中(每侧留 vw/2 − itemExtent/2)。
    final vw = MediaQuery.sizeOf(context).width;
    final pad = (vw - _kThumbItemExtent) / 2;
    // 黑底:与底栏视觉一体,缩略图条覆盖在图片上(图片在下层被黑底遮)。
    return ColoredBox(
      color: Colors.black,
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (_) {
          onScrollEnd();
          return false;
        },
        child: ListView.builder(
          controller: controller,
          scrollDirection: Axis.horizontal,
          itemExtent: _kThumbItemExtent,
          padding: EdgeInsets.symmetric(horizontal: pad),
          itemCount: photos.length,
          itemBuilder: (ctx, i) {
            final info = photos[i];
            return ValueListenableBuilder<int>(
              valueListenable: centerIndex,
              builder: (_, center, _) {
                final isCenter = i == center;
                final w = isCenter ? _kThumbCenterW : _kThumbNormalW;
                // 中心项方形(矮),普通项竖条(高出一截):尺寸对比代替间距对比。
                final h = isCenter ? _kThumbCenterH : _kThumbItemH;
                final r = isCenter ? _kThumbRadiusCenter : _kThumbRadiusNormal;
                return GestureDetector(
                  onTap: () => onTap(i),
                  behavior: HitTestBehavior.opaque,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Opacity(
                      opacity: isCenter ? 1.0 : 0.5,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: w,
                        height: h,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(r),
                          border: isCenter
                              ? Border.all(color: AppColors.text, width: 1.5)
                              : null,
                          image: DecorationImage(
                            image: buildThumbnailProvider(
                              imageRefFromMediaStoreId(info.id),
                              size: _kThumbLoadSize,
                            ),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
