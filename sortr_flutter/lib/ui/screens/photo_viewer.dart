// 全屏大图浏览器 —— PageView 左右滑 + InteractiveViewer 缩放 + 删除
//
// 从 album_screen.dart 拆出。相比拆分前的增强：
//   - 分页联动：滚动到接近末尾且 hasMore 时回调 [onLoadMore]，外部新数据经
//     didUpdateWidget 合并进本地列表，大相册可一路滑到底（原版本只能看已加载页）。
//   - 删除后从列表移除当前项，自动跳到下一张（或末尾）。
//
// 交互：单击切换顶/底栏遮罩 + 系统栏显隐（沉浸式）；双击落点缩放（官方 toScene 算法）；
//       双指捏合由 InteractiveViewer 内部处理。

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/gallery/gallery_controller.dart';
import 'package:sortr_flutter/shared/widgets/spring_popup.dart';
import 'package:sortr_flutter/shared/widgets/toast.dart';

import 'album_common.dart';
import 'photo_details_sheet.dart';

/// 全屏大图浏览器：PageView 左右滑 + InteractiveViewer 缩放 + 删除按钮。
///
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
  /// 翻页回调（当前照片索引变化时）。相册网格据此更新飞行层返回动画的
  /// 终点——缩略图与缩放位置跟随当前照片，而不是初始打开的那张。
  final ValueChanged<int>? onIndexChanged;
  /// 打开本页的 route 过渡动画（album 飞行层 push 用）。非 null 时，2880 原图
  /// 延迟到动画完成（status == completed）后才开始加载——否则动画期间
  /// viewer 被 Opacity 隐藏仍会 resolve 原图（precache/自身加载），缩放结束
  /// 瞬间直接是原图，没有"缩放结束才完整加载"的渐进感。null（无动画入口）
  /// 时立即允许加载原图。pop 反向动画期间不重置：原图保留在树中，返回时
  /// viewer 淡出与飞行层衔接无清晰度跳变。
  final Animation<double>? transition;

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  late final PageController _pageCtrl;
  late List<MsImageInfo> _photos;
  late int _index;
  // 顶/底栏：通过 Navigator OverlayEntry 显示（位于 route/飞行层转场之上），
  // 点击打开 viewer 的瞬间即可见（50ms 淡入），不受转场动画隐藏（Opacity 0）影响。
  // 点击图片切换（隐藏+沉浸 / 浮现+恢复）。
  OverlayEntry? _barEntry;
  final ValueNotifier<bool> _barVisible = ValueNotifier(false);
  bool _loadingMore = false;
  /// 本次浏览中**已加载完成全图**的照片 id 集合。
  /// dispose 时逐个 evict（2880px 大图 ≈ 数十 MB/张，残留会撑爆 ImageCache →
  /// 滚动时缩略图反复驱逐 + GC，帧率单调下降）。只记实际加载的，避免全量 evict。
  final Set<String> _viewedIds = {};
  // 活跃触摸指针数：≥2（双指捏合）时禁用 PageView 滚动，让 InteractiveViewer
  // 的缩放独占手势竞技场。否则双指捏合时第一指的轻微横移就会让 PageView 的
  // drag 先胜出（翻页/抢手势），表现为“捏合很难触发”。
  int _activePointers = 0;
  // 翻页裁决三态（替代旧单 bool _scrollEnabled，对标系统相册"放大先 pan 到边再翻页"）：
  //  InteractiveViewer 交互中（_interacting）或双指（_activePointers>=2）禁翻页；
  //  放大态（_zoomed）且未到水平边界（_atHorizontalEdge=false）禁翻页——放大后需先
  //  pan 到图片水平边缘，到边才允许 PageView 翻页。_zoomed/_atHorizontalEdge 由当前
  //  active 图片经 onZoomEdgeChanged 实时上报；_interacting 在 onInteractionStart/End 切换。
  bool _interacting = false;
  bool _zoomed = false;
  bool _atHorizontalEdge = false;
  bool get _canFlip =>
      !_interacting && _activePointers < 2 && (!_zoomed || _atHorizontalEdge);
  // 2880 原图是否允许”显示”：route 过渡动画（album 飞行层）完成后才置 true。
  // 2880 的解码已由 album 端 _openViewer 的 precacheImage 在点击瞬间发起；此处
  // 只门控原图层进树——保证 t=1 衔接点 viewer 垫 300（与飞行末帧一致无跳变），
  // 1~2 帧后 2880 命中缓存覆盖。transition 为 null（无动画入口）时初始即 true。
  bool _allowFull = false;
  // viewer 全图下采样目标宽（屏宽物理×0.8，build 时算；evict 复用同值匹配 ImageCache key）。
  int _viewerTargetWidth = 1152;

  @override
  void initState() {
    super.initState();
    _photos = List.of(widget.photos);
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _pageCtrl = PageController(initialPage: _index);
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
    // 缩放动画期间即可见——不受 viewer 被隐藏（Opacity 0）的影响。
    // 系统栏保持进入时状态（不沉浸）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _insertBars();
    });
  }

  /// route 动画完成（缩放结束）→ 允许加载 2880 原图，触发一次重建。
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
  /// 打开即自动浮现；点击 → 隐藏+沉浸（immersiveSticky），再点 → 浮现+恢复。
  void _toggleChrome() {
    _barVisible.value = !_barVisible.value;
    if (_barVisible.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      // 沉浸式浏览：隐藏状态栏 + 导航栏（immersiveSticky）。
      // 返回手势已由 MainActivity 的 OnBackAnimationCallback 接管（见其注释）：
      // 右滑直接触发返回，不会被系统消费用于“显示系统栏/再次滑动返回”。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  /// 放大态变化（scale 跨 1.05）→ 自动沉浸/恢复（对标系统相册/Google Photos）。
  /// 放大：隐藏栏 + immersiveSticky；缩回 1.0：恢复栏 + edgeToEdge。触发时机是"放大"，
  /// **不是**打开即沉浸——从缩略图进入时栏照常浮现（_insertBars 的 postFrame 淡入）。
  /// 与 _toggleChrome（未放大点击切栏）不冲突：放大态点击已被 _BigImage 屏蔽（onTap=null）。
  void _onZoomStateChanged(bool zoomed) {
    if (!mounted) return;
    if (zoomed) {
      // 放大：自动隐藏栏 + 沉浸（对标系统相册）
      _barVisible.value = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    // 缩回 1.0：不自动恢复栏——放大隐藏 UI 后缩小保持隐藏，由单击（_toggleChrome）
    // 切换显隐，对标系统相册。系统栏也保持沉浸，单击显栏时统一恢复 edgeToEdge。
  }

  /// 甩到边即翻：放大态贴边 + 横向甩手（_BigImage 在 onInteractionEnd 检测）→ 程序式翻页。
  /// delta=-1 上一张、+1 下一张。
  void _flingPage(int delta) {
    if (!_pageCtrl.hasClients) return;
    final next = (_index + delta).clamp(0, _photos.length - 1);
    if (next == _index) return;
    _pageCtrl.animateToPage(next,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// 把顶/底栏插入 Navigator Overlay：位于当前 route（含飞行层转场）之上，
  /// 打开瞬间即可见，50ms 淡入与缩放动画并行——不会像放在 viewer 内部那样
  /// 被转场动画的 Opacity(0) 隐藏，等动画结束才露出（用户感知为“动画结束+图片
  /// 加载完才浮现”）。栏数据（当前照片/页数/收藏）在翻页/删除后 markNeedsBuild 刷新。
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
    // 下一帧淡入（50ms）：从打开瞬间开始计时，与缩放动画并行。
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
        title: Text(t(ref, 'confirm_trash'),
            style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.text, fontSize: 15)),
        content: Text(t(ref, 'trash_confirm_desc'),
            style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted, fontSize: 13)),
        actions: [
          // 左右布局：左取消、右删除（移到回收站）
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
                  child: Text(t(ref, 'action_trash')),
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
    // 列表已变短：飞行层返回动画的终点跟随调整后的当前照片
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
            : Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => setState(() => _activePointers++),
                onPointerUp: (_) => setState(() {
                  if (_activePointers > 0) _activePointers--;
                }),
                onPointerCancel: (_) => setState(() {
                  if (_activePointers > 0) _activePointers--;
                }),
                child: Stack(
                children: [
                  // 图片层（PageView 左右滑 + 缩放）
                  // 翻页裁决见 _canFlip：交互中/双指/放大未到边 时禁滚（让缩放与 pan 独占）；
                  // 放大且已 pan 到水平边界 → 允许翻页（对标系统相册：先 pan 后翻）。
                  PageView.builder(
                    controller: _pageCtrl,
                    physics: _canFlip
                        ? const _SnapSpringPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: _photos.length,
                    onPageChanged: (i) {
                      setState(() => _index = i);
                      // 通知相册网格:飞行层返回动画跟随当前照片
                      widget.onIndexChanged?.call(i);
                      // Overlay 顶/底栏显示当前照片信息，翻页后刷新
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
                          onInteractionStart: () =>
                              setState(() => _interacting = true),
                          onInteractionEnd: (scale) => setState(() {
                            _interacting = false;
                            _zoomed = scale > 1.0;
                          }),
                          // 当前 active 图片的缩放/边界态实时上报，驱动 _canFlip
                          onZoomEdgeChanged: ({
                            required bool zoomed,
                            required bool atHorizontalEdge,
                          }) {
                            if (!mounted) return;
                            setState(() {
                              _zoomed = zoomed;
                              _atHorizontalEdge = atHorizontalEdge;
                            });
                          },
                          onZoomStateChanged: _onZoomStateChanged,
                          onFlingPage: _flingPage,
                          onFullLoaded: (id) => _viewedIds.add(id),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
    );
  }

  /// 显示当前照片的详情面板(ColorOS 相册式卡片栈)。
  ///
  /// 用 DraggableScrollableSheet 承载:上划展开、下划收起,拖至最小自动关闭——
  /// 对标系统相册 PhotoDetailsPanelSection 的 VERTICAL_SLIDE_UP 两态面板
  /// (EXPAND/COLLAPSE + 顶部渐隐)。入口:底栏 info 按钮,或照片上垂直上划。
  void _showDetails(MsImageInfo info) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: false,
      builder: (ctx) {
        // dismissed 标志:确保「拖到最小尺寸→关闭」只 pop 一次,避免 pop 动画
        // 期间重复 maybePop 误关下层相册路由。
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

/// 单张大图：InteractiveViewer 缩放 + 双击复位/放大 + 单击切换顶/底栏
class _BigImage extends StatefulWidget {
  const _BigImage({
    required this.info,
    required this.active,
    required this.onTapChrome,
    this.loadFull = false,
    this.onInteractionStart,
    this.onInteractionEnd,
    this.onZoomEdgeChanged,
    this.onZoomStateChanged,
    this.onFlingPage,
    this.onFullLoaded,
    this.onSwipeUp,
  });
  final MsImageInfo info;
  final bool active;
  final VoidCallback onTapChrome;
  /// 是否允许"显示"2880 原图层（动画完成后才 true）。2880 的解码已由 album 端
  /// _openViewer 的 precacheImage 在点击瞬间发起，此处只门控原图层进树时机。
  /// false 时只显示 300 垫底，原图层（静态图）与 GIF 原片层都不进入树。
  final bool loadFull;
  // 缩放交互回调：开始/结束通知外层（维护 _interacting/_zoomed）。
  final VoidCallback? onInteractionStart;
  final void Function(double scale)? onInteractionEnd;
  /// 缩放/边界态变化（_tc 变化时实时上报）：驱动外层 _canFlip 翻页裁决。
  final void Function({
    required bool zoomed,
    required bool atHorizontalEdge,
  })? onZoomEdgeChanged;
  /// scale 跨 1.05（放大/缩回）：外层据此自动沉浸/恢复。
  final void Function(bool zoomed)? onZoomStateChanged;
  /// 放大态贴边横向甩手：外层程序式翻页（-1 上一张 / +1 下一张）。
  final void Function(int delta)? onFlingPage;
  /// 原图（kViewerTargetWidth）加载完成时回调，外层记录 id 用于退出时 evict。
  final void Function(String mediaStoreId)? onFullLoaded;
  /// 照片上垂直上划手势:未放大时向上划唤出详情面板(对标系统相册上滑展开 details)。
  final VoidCallback? onSwipeUp;

  @override
  State<_BigImage> createState() => _BigImageState();
}

class _BigImageState extends State<_BigImage> with SingleTickerProviderStateMixin {
  // ★ InteractiveViewer + TransformationController（内置双指缩放/平移本就对）。
  //   双击用外层 GestureDetector 的 onDoubleTapDown + onDoubleTap，缩放矩阵用
  //   Flutter 官方 toScene 算法（落点保持不动）。
  final TransformationController _tc = TransformationController();
  // LayoutBuilder 捕获的 InteractiveViewer viewport 尺寸（边界判定 + 双击自适应用）。
  Size? _viewportSize;
  // 图片原始宽高比（双击自适应铺满算 coverRatio 用）。优先 widget.info.width/height，
  // 为 0 时 readMeta 懒加载兜底；都无则双击 fallback 2.5×。
  double? _imageAspect;
  // 自动沉浸：scale 跨 1.05 的上一次态（仅边沿穿越回调，避免每帧重复上报）。
  bool _wasZoomed = false;
  // 边界判定的像素容差（tx 浮点误差）。
  static const _edgeEps = 0.5;

  // 双击动画：listener 在初始化时注册一次（之前每次双击都 addListener 会泄漏
  // 导致矩阵错乱、双击「坏掉」）
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300), // 对齐系统相册双击/pinch 动画 300ms
  )..addListener(() {
      if (_matrixTween != null) {
        // Decelerate ≈ 系统相册 DecelerateInterpolator(2.5)：快进慢出
        final t = Curves.decelerate.transform(_anim.value);
        _tc.value = _matrixTween!.transform(t);
      }
    });
  Matrix4Tween? _matrixTween;
  // 双击落点（onDoubleTapDown 提供，DoubleTap 自身不带坐标）
  Offset _doubleTapPos = Offset.zero;
  // 原图是否已加载完成：完成前显示垫底缩略图，完成后直接替换为原图
  // （同一照片同一 contain 布局，仅清晰度变化——**不要**用淡入淡出过渡，
  // 交叉淡化会产生叠影“闪一下”，实测观感差）。
  bool _fullLoaded = false;
  // 是否已触发高清原图加载。双击/双指缩放放大到 scale>1.3 时按需加载原片全像素
  // (readBytes 全图,~250ms)——日常浏览用上层下采样图(快),只有放大看细节才 load 原图。
  bool _hdTriggered = false;
  // 是否为 GIF 动图。GIF 不走下采样渐进层——下采样(BitmapFactory+inSampleSize)
  // 只取第一帧、compress JPEG 彻底丢帧,得到静态首帧无法播放动画;只有原片全像素
  // (targetWidth:null)能让 Flutter 解出完整多帧 Codec 播动画。
  late final bool _isGif;

  @override
  void initState() {
    super.initState();
    _isGif = widget.info.mime == 'image/gif' ||
        extOf(widget.info.name) == '.gif';
    // _tc listener 始终注册（不再按 isGif 区分）：边界上报、自动沉浸、高清触发都依赖它。
    // 高清触发内部仍守卫 !isGif（GIF 始终原片，无按需高清层）。
    _tc.addListener(_onMatrixChanged);
  }

  /// _tc 矩阵变化（双击动画 / 双指缩放 / 平移 驱动）统一处理：
  ///  (1) 高清触发（仅非 GIF，scale>1.3）；
  ///  (2) 边界上报（合并同帧多次回调，驱动外层 _canFlip）；
  ///  (3) 自动沉浸（scale 跨 1.05 → 外层切栏 + 系统栏）。
  void _onMatrixChanged() {
    final scale = _tc.value.getMaxScaleOnAxis();
    if (!_isGif && !_hdTriggered && scale > 1.3) {
      setState(() => _hdTriggered = true);
    }
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportEdge());
    }
    final zoomed = scale > 1.05;
    if (zoomed != _wasZoomed) {
      _wasZoomed = zoomed;
      widget.onZoomStateChanged?.call(zoomed);
    }
  }

  /// 上报当前 active 图片的缩放态 + 是否触达水平边界（外层据此裁决翻页）。
  //  child 是 Stack(StackFit.expand) → 尺寸 == viewport；变换 = 均匀缩放 s + 平移 (tx,ty)。
  //  atLeftEdge: child 左缘贴 viewport 左缘（tx >= -eps）→ 继续右拖翻上一张。
  //  atRightEdge: child 右缘贴 viewport 右缘（tx <= vw*(1-s)+eps）→ 继续左拖翻下一张。
  void _reportEdge() {
    if (!mounted || !widget.active || _viewportSize == null) return;
    final m = _tc.value;
    final s = m.getMaxScaleOnAxis();
    final tx = m[12];
    final vw = _viewportSize!.width;
    final zoomed = s > 1.0;
    final atLeft = tx >= -_edgeEps;
    final atRight = tx <= vw * (1 - s) + _edgeEps;
    widget.onZoomEdgeChanged?.call(
      zoomed: zoomed,
      atHorizontalEdge: !zoomed || atLeft || atRight,
    );
  }

  /// 甩到边即翻：放大态、贴水平边、横向甩手速度足够 → 通知外层程序式翻页。
  //  ScaleEndDetails.velocity.pixelsPerSecond.dx = 横向速度（px/s）。
  void _maybeFlingPage(ScaleEndDetails details) {
    if (_viewportSize == null) return;
    final m = _tc.value;
    final s = m.getMaxScaleOnAxis();
    if (s <= 1.0) return;
    final tx = m[12];
    final vw = _viewportSize!.width;
    final vx = details.velocity.pixelsPerSecond.dx;
    if (vx.abs() < 600) return;
    if (tx <= vw * (1 - s) + _edgeEps && vx < 0) {
      widget.onFlingPage?.call(1); // 贴右缘 + 左甩 → 下一张
    } else if (tx >= -_edgeEps && vx > 0) {
      widget.onFlingPage?.call(-1); // 贴左缘 + 右甩 → 上一张
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureImageAspect();
  }

  /// 双击自适应铺满需要的图片宽高比。优先 MsImageInfo.width/height（列表已带回）；
  //  为 0（损坏/低版本）时 readMeta 懒加载兜底；都没就留空 → 双击 fallback 2.5×。
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
      // 留空 → 双击 fallback 2.5
    }
  }

  @override
  void didUpdateWidget(covariant _BigImage old) {
    super.didUpdateWidget(old);
    // 翻页过来（active false→true）：立即上报自身态，否则外层 _canFlip 带上一张状态
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportEdge());
    }
  }

  @override
  void dispose() {
    _tc.removeListener(_onMatrixChanged);
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  /// 单击：立即切换顶/底栏（浮现/隐藏）。
  /// ⚠️ 不要再加 Timer 延迟：onTap 与 onDoubleTap 并存时 Flutter 本就等待
  /// 双击判定窗口（~300ms）才回调 onTap，再加 Timer 会叠加成 ~580ms，
  /// 用户感知“点击后要等图片加载完栏才动”。双击（放大）由 GestureDetector
  /// 的 onDoubleTap 独立处理，单击无需自己区分。
  void _onTap() {
    widget.onTapChrome();
  }

  /// 单指垂直上划（未放大时）→ 唤详情面板。在 InteractiveViewer.onInteractionEnd
  //  用 velocity 检测——原外层 onVerticalDragEnd 的 VerticalDragGestureRecognizer 会
  //  与双指缩放抢竞技场（第一指垂直微移被 accept → 双指 scale 首次失效），故移到
  //  内层 Scale 回调。放大态（scale>1.05）不触发（上划是平移图片）。
  void _maybeSwipeUp(ScaleEndDetails details) {
    if (_tc.value.getMaxScaleOnAxis() > 1.05) return;
    final vy = details.velocity.pixelsPerSecond.dy;
    if (vy < -350) widget.onSwipeUp?.call();
  }

  /// 双击：放大↔复位，以【落点】为锚点（官方 toScene 算法）。
  /// 目标倍率自适应：未放大 → max(2.5, coverRatio) 铺满屏幕消除黑边；
  /// 已放大 → 回 contain(1.0)。落点 pivot 用官方 toScene（落点下图片点不动）。
  void _onDoubleTap() {
    final begin = _tc.value;
    final currentScale = begin.getMaxScaleOnAxis();
    final zooming = currentScale <= 1.01;
    final targetScale = zooming ? _computeDoubleTapTarget() : 1.0;

    var scenePoint = _tc.toScene(_doubleTapPos);
    // 落点 pivot：对「contain 时未铺满的轴」clamp 到「放大后仍覆盖 viewport（无黑边）」
    // 的合法范围，已铺满轴保留落点。这样无论点图片内还是黑边，放大后都不留黑边，
    // 且落点尽量不动——落点在合法范围内时完全不动，只有会导致黑边时才贴到边界
    // （系统相册靠动画后 snapback 钳位，这里在算 pivot 时直接保证）。
    final vp = _viewportSize;
    final ia = _imageAspect;
    if (zooming && targetScale > 1.0 &&
        vp != null && vp.width > 0 && vp.height > 0 &&
        ia != null && ia > 0) {
      final vpAspect = vp.width / vp.height;
      // contain 图在 scene（Stack=viewport）内的尺寸与位置
      final double cw, ch;
      if (ia >= vpAspect) {
        cw = vp.width; // 宽铺满
        ch = vp.width / ia;
      } else {
        ch = vp.height; // 高铺满
        cw = vp.height * ia;
      }
      final cx0 = (vp.width - cw) / 2, cy0 = (vp.height - ch) / 2;
      final cx1 = cx0 + cw, cy1 = cy0 + ch;
      final s = targetScale;
      double sx = scenePoint.dx, sy = scenePoint.dy;
      // 仅 contain 未铺满的轴（图<viewport）需 clamp：放大后该轴覆盖 viewport，
      // pivot 合法范围 = [让图起点贴 viewport 起点, 让图终点贴 viewport 终点]。
      if (cw < vp.width) {
        final sxMin = s * cx0 / (s - 1);
        final sxMax = (s * cx1 - vp.width) / (s - 1);
        sx = sx.clamp(sxMin, sxMax);
      }
      if (ch < vp.height) {
        final syMin = s * cy0 / (s - 1);
        final syMax = (s * cy1 - vp.height) / (s - 1);
        sy = sy.clamp(syMin, syMax);
      }
      scenePoint = Offset(sx, sy);
    }
    // T(scenePoint) · S(targetScale) · T(-scenePoint)：该点缩放后保持不动
    final target = Matrix4.identity()
      ..translate(scenePoint.dx, scenePoint.dy)
      ..scale(targetScale)
      ..translate(-scenePoint.dx, -scenePoint.dy);

    _matrixTween = Matrix4Tween(begin: begin, end: target);
    _anim
      ..stop()
      ..value = 0.0
      ..fling(velocity: 0.4);
  }

  /// 双击放大目标倍率（相对 contain=1.0）：max(2.5, coverRatio).clamp(1,5)。
  //  coverRatio = max(imgAspect/vpAspect, vpAspect/imgAspect) = cover/contain 倍率，
  //  保证双击后图片短边也铺满屏幕、无上下黑边（对标系统相册 FIT×2.5 并补足铺满）。
  double _computeDoubleTapTarget() {
    final vp = _viewportSize;
    final ia = _imageAspect;
    if (vp == null || vp.width <= 0 || vp.height <= 0 || ia == null || ia <= 0) {
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
    // 放大态：onTap / onVerticalDragEnd 置 null——
    //  ① 点击不切栏（放大自动沉浸已隐藏栏，避免与 _toggleChrome 打架）；
    //  ② 不注册垂直 drag → 竖向拖交给 InteractiveViewer pan（修复"放大后竖拖不动"：
    //     原 onVerticalDragEnd 的 VerticalDragGestureRecognizer 会抢赢竞技场，使
    //     InteractiveViewer 收不到竖向 update）。
    final zoomed = _tc.value.getMaxScaleOnAxis() > 1.05;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: zoomed ? null : _onTap,
      onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
      onDoubleTap: _onDoubleTap,
      // 注：不注册 onVerticalDragEnd——其 VerticalDragGestureRecognizer 会与
      // InteractiveViewer 双指缩放抢竞技场（scale=1 时它活跃，第一指垂直微移被
      // accept → 双指 scale 首次无反应）。上划唤详情改由 onInteractionEnd 的
      // velocity 检测（见 _maybeSwipeUp）。
      // LayoutBuilder 捕获 InteractiveViewer viewport 尺寸（边界判定 + 双击自适应用）。
      // 注意外层 Padding(horizontal:4) 使 viewport 宽 = 屏宽 - 8，用真实约束值最稳。
      child: LayoutBuilder(builder: (ctx, constraints) {
        _viewportSize = constraints.biggest;
        // 展开转场由飞行层负责（图从 cell 位置线性放大到全屏 contain）。
        return InteractiveViewer(
          transformationController: _tc,
          clipBehavior: Clip.hardEdge,
          minScale: 1.0,
          maxScale: 5.0,
          panEnabled: true,
          scaleEnabled: true,
          onInteractionStart: (_) => widget.onInteractionStart?.call(),
          onInteractionUpdate: (_) {
            if (widget.active) _reportEdge();
          },
          onInteractionEnd: (details) {
            _reportEdge();
            widget.onInteractionEnd?.call(_tc.value.getMaxScaleOnAxis());
            _maybeFlingPage(details);
            _maybeSwipeUp(details);
          },
          child: _buildContent(ref),
        );
      }),
    );
  }

  /// 图片内容层：静态图多层 Stack（垫底 300 / 原图 / 高清）或 GIF 原片层。
  //  从 build 提取，便于 build 用 LayoutBuilder 包裹 InteractiveViewer 捕获 viewport 尺寸。
  Widget _buildContent(ImageRef ref) {
    if (_isGif) return _gifStack(ref);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!_fullLoaded)
          // ① 垫底 300：网格同 key 已缓存，飞行层移除瞬间立即衔接可见。
          //    2880 就绪前显示（兜底）；就绪后 _fullLoaded=true，本层移除、原图覆盖。
          Image(
            image: buildThumbnailProvider(ref, size: 300),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (ctx, error, stack) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  color: AppColors.muted, size: 48),
            ),
          ),
        // 原图层：contain 完整显示。加载完成前透明（不挡垫底层）；
        // 完成后直接上屏（垫底同帧移除，无叠影）。加载失败保持透明，
        // 垫底缩略图继续可见。targetWidth 运行时算（屏宽×0.8，computeViewerTargetWidth），
        // 全屏 contain 够清晰、解码量小；放大 scale>1.3 由 _hdTriggered 原片覆盖。
        // ⚠️ loadFull 门控：缩放动画结束前不进树，避免"动画时已垫原图"。
        if (widget.loadFull)
          Image(
            image: buildImageProvider(ref,
                targetWidth: computeViewerTargetWidth(
                    MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (ctx, child, progress) {
              if (progress == null) {
                if (!_fullLoaded) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() => _fullLoaded = true);
                      // 通知外层记录 id：退出 viewer 时 evict 这些大图，
                      // 否则 ImageCache 残留导致多次进出后滚动掉帧（实测 30→10fps）。
                      widget.onFullLoaded?.call(widget.info.id);
                    }
                  });
                }
                return child;
              }
              return const SizedBox.shrink();
            },
            errorBuilder: (ctx, error, stack) => const SizedBox.shrink(),
          ),
        // 高清原图层:放大(scale>1.3)时按需加载原片全像素(readBytes 全图)。
        // 日常浏览用上层下采样图(快),只有放大看细节才 load 原图;高清就绪后
        // 覆盖 1536,放大清晰;加载中透明(透出下层 1536,放大虽糊但可见)。
        if (_hdTriggered)
          Image(
            image: buildImageProvider(ref, targetWidth: null),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (ctx, child, progress) =>
                progress == null ? child : const SizedBox.shrink(),
            errorBuilder: (ctx, error, stack) => const SizedBox.shrink(),
          ),
      ],
    );
  }

  /// GIF 动图渲染层:直接加载原片全像素(readBytes),Flutter 解出完整多帧 Codec
  /// 自动播放动画。**不走** 300/2880 下采样渐进层——下采样走 native
  /// BitmapFactory+inSampleSize(只取第一帧)再 compress JPEG(彻底丢帧),得到的是
  /// 静态首帧;只有 targetWidth:null 的原片能让 dart 解码器播动画。
  /// 300 系统缩略图(静态首帧)仅作原图加载期垫底防黑屏,原图就绪后覆盖。
  /// 缩放由 InteractiveViewer 直接缩放原片(GIF 不下采样,放大即原片缩放)。
  Widget _gifStack(ImageRef ref) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!_fullLoaded)
          // 加载期垫底:网格同 key 的 300 缩略图(静态首帧),防黑屏。
          Image(
            image: buildThumbnailProvider(ref, size: 300),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (ctx, error, stack) => const Center(
              child: Icon(Icons.broken_image_outlined,
                  color: AppColors.muted, size: 48),
            ),
          ),
        // 原片全像素:多帧 Codec 自动播放动画。就绪后覆盖上层 300 垫底。
        // ⚠️ loadFull 门控:缩放动画结束前不进树(与静态原图层一致)。
        if (widget.loadFull)
          Image(
            image: buildImageProvider(ref, targetWidth: null),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (ctx, child, progress) {
              if (progress == null) {
                if (!_fullLoaded) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() => _fullLoaded = true);
                      // 通知外层记录 id:退出 viewer 时 evict(与静态图原片同 key)。
                      widget.onFullLoaded?.call(widget.info.id);
                    }
                  });
                }
                return child;
              }
              return const SizedBox.shrink();
            },
            errorBuilder: (ctx, error, stack) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// PageView snap 弹簧：松手翻页比默认更紧、临界阻尼无过冲（ratio 1.0），
/// 快速到位不回弹（默认弹簧偏软、近似匀速滑过）。
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
