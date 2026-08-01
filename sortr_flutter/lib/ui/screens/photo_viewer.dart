// 全屏大图浏览器 —— PageView 左右滑 + InteractiveViewer 缩放 + 删除
//
// 从 album_screen.dart 拆出。相比拆分前的增强：
//   - 分页联动：滚动到接近末尾且 hasMore 时回调 [onLoadMore]，外部新数据经
//     didUpdateWidget 合并进本地列表，大相册可一路滑到底（原版本只能看已加载页）。
//   - 删除后从列表移除当前项，自动跳到下一张（或末尾）。
//
// 交互：单击切换顶/底栏遮罩 + 系统栏显隐（沉浸式）；双击落点缩放（官方 toScene 算法）；
//       双指捏合由 InteractiveViewer 内部处理。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/gallery/gallery_controller.dart';
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
  });

  final List<MsImageInfo> photos;
  final int initialIndex;
  /// 相册内是否还有更多未加载的图片（用于触发 loadMore）。
  final bool hasMore;
  /// 相册图片总数（来自 bucket.count，仅用于底部计数器显示）。
  final int? totalCount;
  /// 滚动接近末尾时的回调，外部触发分页加载。
  final Future<void> Function()? onLoadMore;

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  late final PageController _pageCtrl;
  late List<MsImageInfo> _photos;
  late int _index;
  bool _chromeVisible = true; // 顶/底栏遮罩可见性（点击图片切换）
  bool _loadingMore = false;
  // 活跃触摸指针数：≥2（双指捏合）时禁用 PageView 滚动，让 InteractiveViewer
  // 的缩放独占手势竞技场。否则双指捏合时第一指的轻微横移就会让 PageView 的
  // drag 先胜出（翻页/抢手势），表现为“捏合很难触发”。
  int _activePointers = 0;
  // 是否允许 PageView 翻页（与 _activePointers 双层保护缩放独占）。
  // InteractiveViewer 交互开始（onInteractionStart）置 false；结束且 scale 归 1.0 才恢复。
  bool _scrollEnabled = true;

  @override
  void initState() {
    super.initState();
    _photos = List.of(widget.photos);
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _pageCtrl = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    // 离开页面恢复 edge-to-edge，避免影响其他页的系统栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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

  /// 点击图片：切换顶/底栏遮罩 + 系统栏显隐（沉浸式浏览）
  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      // 沉浸式浏览：隐藏状态栏 + 导航栏（immersiveSticky）。
      // 返回手势已由 MainActivity 的 OnBackAnimationCallback 接管（见其注释）：
      // 右滑直接触发返回，不会被系统消费用于“显示系统栏/再次滑动返回”。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Future<void> _deleteCurrent() async {
    if (_photos.isEmpty) return;
    final current = _photos[_index];
    final controller = ref.read(galleryControllerProvider.notifier);
    String? toastKey;
    if (current.isTrashed) {
      // 回收站视图：恢复 / 彻底删除 / 取消（全宽竖排按钮，避免窄屏横向溢出）
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(t(ref, 'trash_item_title'),
              style: const TextStyle(color: AppColors.text, fontSize: 15)),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.bg),
                  onPressed: () => Navigator.pop(ctx, 'restore'),
                  child: Text(t(ref, 'action_restore')),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'delete'),
                  child: Text(t(ref, 'delete_permanently'),
                      style: const TextStyle(color: AppColors.danger)),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: Text(t(ref, 'cancel'),
                      style: const TextStyle(color: AppColors.muted)),
                ),
              ],
            ),
          ],
        ),
      );
      if (action == null) return;
      if (action == 'restore') {
        final err = await controller.restorePhoto(current.id);
        if (err != null) {
          if (mounted) toast(context, t(ref, 'restore_failed'));
          return;
        }
        toastKey = 'restored';
      } else {
        final err = await controller.deletePhoto(current.id);
        if (err != null) {
          if (mounted) toast(context, t(ref, 'delete_failed'));
          return;
        }
        toastKey = 'deleted';
      }
    } else {
      // 普通视图：删除 = 移入回收站（与系统相册一致；回收站内可恢复/彻底删除）
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(t(ref, 'confirm_trash'),
              style: const TextStyle(color: AppColors.text, fontSize: 15)),
          content: Text(t(ref, 'trash_confirm_desc'),
              style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      foregroundColor: AppColors.bg),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'action_trash')),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t(ref, 'cancel'),
                      style: const TextStyle(color: AppColors.muted)),
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
      toastKey = 'trashed';
    }
    if (!mounted) return;
    setState(() {
      _photos.removeAt(_index);
      if (_photos.isEmpty) {
        Navigator.pop(context);
        return;
      }
      _index = _index >= _photos.length ? _photos.length - 1 : _index;
    });
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
      );
    });
    toast(context, t(ref, current.isFavorite ? 'unfavorited' : 'favorited'));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // canPop=true 明确告诉系统「可以立即返回」，不触发 ColorOS 的预测手势
      // 二次确认（"再次滑动返回"）。
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        // 图片直接铺满物理屏幕；顶/底栏作为渐变遮罩叠在上层。
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
                  // physics 双层禁滚保护，确保双指缩放独占手势竞技场：
                  //  ① 指针计数 _activePointers<2：第二指落下即禁滚（防第一指 drag 抢先 accept）；
                  //  ② _scrollEnabled：InteractiveViewer 交互中（onInteractionStart）禁用，
                  //     onInteractionEnd 且 scale 归 1 才恢复（对齐 Google Photos：放大态不翻页）。
                  PageView.builder(
                    controller: _pageCtrl,
                    physics: (_scrollEnabled && _activePointers < 2)
                        ? const _SnapSpringPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: _photos.length,
                    onPageChanged: (i) {
                      setState(() => _index = i);
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
                          onTapChrome: _toggleChrome,
                          onInteractionStart: () =>
                              setState(() => _scrollEnabled = false),
                          onInteractionEnd: (scale) {
                            if (scale <= 1.0) {
                              setState(() => _scrollEnabled = true);
                            }
                          },
                        ),
                      );
                    },
                  ),

                  // 顶部渐变遮罩栏：返回 + 当前照片时间 | 计数器
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _chromeVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_chromeVisible,
                        child: _TopChromeBar(
                          info: _photos[_index],
                          index: _index,
                          total: widget.totalCount ?? _photos.length,
                          onBack: () => Navigator.maybePop(context),
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
                      opacity: _chromeVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_chromeVisible,
                        child: _BottomChromeBar(
                          onInfo: () => _showDetails(_photos[_index]),
                          onDelete: _deleteCurrent,
                          isFavorite: _photos[_index].isFavorite,
                          onFavorite: _toggleFavoriteCurrent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ),
    );
  }

  /// 显示当前照片的详情信息抽屉
  void _showDetails(MsImageInfo info) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => PhotoDetailsSheet(info: info),
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
                    fontFamily: 'SpaceMono',
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
  });
  final VoidCallback onInfo;
  final VoidCallback onDelete;
  final bool isFavorite;
  final VoidCallback onFavorite;

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

/// 单张大图：InteractiveViewer 缩放 + 双击复位/放大 + 单击切换顶/底栏
class _BigImage extends StatefulWidget {
  const _BigImage({
    required this.info,
    required this.active,
    required this.onTapChrome,
    this.onInteractionStart,
    this.onInteractionEnd,
  });
  final MsImageInfo info;
  final bool active;
  final VoidCallback onTapChrome;
  // 缩放交互回调：开始时通知外层禁用 PageView 翻页；
  // 结束时回传当前 scale，外层据此决定是否恢复翻页（scale 归 1 才恢复）。
  final VoidCallback? onInteractionStart;
  final void Function(double scale)? onInteractionEnd;

  @override
  State<_BigImage> createState() => _BigImageState();
}

class _BigImageState extends State<_BigImage> with SingleTickerProviderStateMixin {
  // ★ InteractiveViewer + TransformationController（内置双指缩放/平移本就对）。
  //   双击用外层 GestureDetector 的 onDoubleTapDown + onDoubleTap，缩放矩阵用
  //   Flutter 官方 toScene 算法（落点保持不动）。
  final TransformationController _tc = TransformationController();
  static const _doubleTapScale = 2.0;

  // 双击动画：listener 在初始化时注册一次（之前每次双击都 addListener 会泄漏
  // 导致矩阵错乱、双击「坏掉」）
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..addListener(() {
      if (_matrixTween != null) {
        _tc.value = _matrixTween!.transform(_anim.value);
      }
    });
  Matrix4Tween? _matrixTween;
  // 双击落点（onDoubleTapDown 提供，DoubleTap 自身不带坐标）
  Offset _doubleTapPos = Offset.zero;
  // 单击延迟判定（与双击区分）
  Timer? _singleTapTimer;

  @override
  void dispose() {
    _singleTapTimer?.cancel();
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _onTap() {
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(const Duration(milliseconds: 280), () {
      widget.onTapChrome();
    });
  }

  /// 双击：放大↔复位，以【落点】为锚点（官方 toScene 算法）。
  void _onDoubleTap() {
    _singleTapTimer?.cancel();
    final begin = _tc.value;
    final currentScale = begin.getMaxScaleOnAxis();
    final zooming = currentScale <= 1.01;
    final targetScale = zooming ? _doubleTapScale : 1.0;

    // ⭐ 官方算法：toScene 把屏幕落点转成场景坐标（落点下的图片点）
    // （translate/scale 虽有 deprecation info，但其替代 API 签名为 4 参数矩阵形式，
    //  这里保持与原 album_screen 一致的 2D 链式写法——deprecation 不影响正确性。）
    final scenePoint = _tc.toScene(_doubleTapPos);
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

  @override
  Widget build(BuildContext context) {
    final ref = imageRefFromMediaStoreId(widget.info.id,
        extension: extOf(widget.info.name));
    // 外层 GestureDetector 处理单击/双击，双指捏合由 InteractiveViewer 内部处理。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        clipBehavior: Clip.hardEdge,
        minScale: 1.0,
        maxScale: 4.0,
        panEnabled: true,
        scaleEnabled: true,
        onInteractionStart: (_) => widget.onInteractionStart?.call(),
        onInteractionEnd: (_) =>
            widget.onInteractionEnd?.call(_tc.value.getMaxScaleOnAxis()),
        child: Image(
          image: buildImageProvider(ref),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          loadingBuilder: (ctx, child, progress) {
            if (progress == null) return child;
            return Center(
              child: CircularProgressIndicator(
                value: progress.cumulativeBytesLoaded /
                    (progress.expectedTotalBytes ?? 1),
                color: AppColors.accent,
              ),
            );
          },
          errorBuilder: (ctx, error, stack) => const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined,
                  color: AppColors.muted, size: 48),
              SizedBox(height: 8),
              Text('Preview unavailable',
                  style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          ),
        ),
      ),
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
