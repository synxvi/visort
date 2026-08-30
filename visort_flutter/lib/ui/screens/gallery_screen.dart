// 相册列表页 —— 抽屉一级页①（默认屏）· 安卓 MediaStore
//
// 纯浏览入口：3 列封面网格（封面 + 相册名 + 数量），点相册 → push
// /album（相册内浏览，封面↔网格第一张 Hero 飞行）。历史上的 GalleryScreen
// （行式列表 + 源相册勾选 Checkbox + 收藏/回收站入口行）已随抽屉重构
// 重写：勾选职责归快速整理页、收藏/回收站归抽屉一级页，本页只做浏览。
//
// 排序：AppBar 右侧 SortToggle（GalleryController.albumSortBy，偏好持久化）。
//
// 刷新时机：initState（首启）、抽屉切回本页（ShellHandle.onActivated）、
// 从相册内/看图器 pop 回 `/`（currentRouteName 监听）——三处都静默重查
// buckets，保证封面与数量在移动/删除后不失真。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/press_scale.dart';
import 'package:visort_flutter/shared/widgets/sort_toggle.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/ui/screens/app_shell_android.dart'
    show ShellHandle;

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key, this.shellHandle});

  /// 抽屉壳注入的句柄：null = 非 shell 场景（预留）。
  final ShellHandle? shellHandle;

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  /// 飞行目标 tag（父级全局）：点击相册瞬间置位，所有 tile 的 HeroMode
  /// 据此屏蔽非目标 tile（含屏外预构建）；push 返回后清除。
  String? _flightTag;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(galleryControllerProvider.notifier).loadBuckets();
    });
    // 从相册内/看图器返回 `/`：重查 buckets（数量/封面可能已变）。
    currentRouteName.addListener(_onRouteChanged);
    widget.shellHandle?.onActivated = () {
      ref.read(galleryControllerProvider.notifier).loadBuckets(silent: true);
    };
  }

  void _onRouteChanged() {
    if (currentRouteName.value == AppRoutes.home) {
      ref.read(galleryControllerProvider.notifier).loadBuckets(silent: true);
    }
  }

  @override
  void dispose() {
    currentRouteName.removeListener(_onRouteChanged);
    widget.shellHandle?.onActivated = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(galleryControllerProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        leading: IconButton(
          icon: const Icon(Icons.menu, color: AppColors.text),
          tooltip: t(ref, 'gallery_title'),
          onPressed: () => widget.shellHandle?.openDrawer(),
        ),
        titleSpacing: 0,
        title: Text(
          t(ref, 'gallery_title'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            height: 1.2,
            fontFamilyFallback: AppFonts.cjkFallback,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
        actions: [
          SortToggle(
            sortBy: gallery.albumSortBy,
            asc: gallery.albumSortAsc,
            onChanged: (by, asc) => ref
                .read(galleryControllerProvider.notifier)
                .setAlbumSort(by, asc),
          ),
        ],
      ),
      // [ente 对齐] 排序切换内容交叉淡入 150ms（easeInQuart / easeOutExpo）。
      // edge-to-edge：bottom:false，网格延伸到物理底边，尾部 inset 避让手势条。
      body: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: AppDurations.enteContentSwitch,
          switchInCurve: Curves.easeInQuart,
          switchOutCurve: Curves.easeOutExpo,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            children: [
              for (final previous in previousChildren)
                Positioned.fill(child: previous),
              if (currentChild != null) Positioned.fill(child: currentChild),
            ],
          ),
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: KeyedSubtree(
            key: ValueKey((gallery.albumSortBy, gallery.albumSortAsc)),
            child: _buildBody(gallery),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(GalleryState gallery) {
    // ⚠️ 无转圈：buckets 为空（加载中/真空）时保持空网格底色，数据到达后
    // 直接填充，不闪不转；error 时显示错误页（可重试）。
    if (gallery.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 40, color: AppColors.danger),
              const SizedBox(height: 12),
              SelectableText(
                t(ref, gallery.error!),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.danger,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () =>
                    ref.read(galleryControllerProvider.notifier).loadBuckets(),
                child: Text(t(ref, 'retry')),
              ),
            ],
          ),
        ),
      );
    }
    final buckets = gallery.sortedBuckets;
    // 尾部 inset = 手势条高度 + 网格间距：末行封面不被手势条压住。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () =>
          ref.read(galleryControllerProvider.notifier).loadBuckets(silent: true),
      child: GridView.builder(
        // 动画对齐 ente：iOS 式回弹滚动物理。
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(12, 8, 12, 16 + bottomInset),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 14,
          // cell 高 = 封面(正方形) + 名称/数量两行文字 ≈ 1.33 倍宽
          childAspectRatio: 0.75,
        ),
        itemCount: buckets.length,
        itemBuilder: (ctx, i) {
          return _AlbumTile(
            bucket: buckets[i],
            flightTag: _flightTag,
            onFlightStart: (tag) => setState(() => _flightTag = tag),
          );
        },
      ),
    );
  }
}

/// 单个相册 cell：上封面 + 相册名 + 数量 → 点击进相册。
class _AlbumTile extends ConsumerStatefulWidget {
  const _AlbumTile({
    required this.bucket,
    this.flightTag,
    this.onFlightStart,
  });

  final MsBucket bucket;

  /// 父级飞行目标 tag（点击相册瞬间非 null，用于 HeroMode 屏蔽本 tile）。
  final String? flightTag;

  /// 点击时通知父级置位飞行目标（父级 setState 后本 tile rebuild）。
  final ValueChanged<String>? onFlightStart;

  @override
  ConsumerState<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends ConsumerState<_AlbumTile> {
  /// 封面 Hero tag：动态取「网格排序后第一张」的 id（ente 封面↔第一张配对）。
  /// coverId 是 listBuckets 的封面（排序可能与相册内不同）→ 必须用 photos[0]。
  String? _heroTag;

  Future<void> _open() async {
    // [ente 对齐] 相册打开 = 200ms fade + 封面 Hero 飞行（封面↔网格第一张图）。
    // 先 await enterBucket：push 时网格第一张 cell 必须已存在（Hero 终点），
    // 否则 flight 不启动（数据异步查询错过动画窗口）。快照命中秒回；
    // 首次查 MediaStore ~100-300ms（一次性，之后快照直出）。
    final notifier = ref.read(galleryControllerProvider.notifier);
    await notifier.enterBucket(widget.bucket.id);
    if (!mounted) return;
    final photos = ref.read(galleryControllerProvider).photos;
    if (photos.isNotEmpty) {
      final tag = 'photo_${photos[0].id}';
      setState(() => _heroTag = tag);
      widget.onFlightStart?.call(tag);
    }
    final args = {
      'bucketId': widget.bucket.id,
      'bucketName': widget.bucket.name,
      'bucketCount': widget.bucket.count,
    };
    await Navigator.pushNamed(context, AlbumRoutes.album, arguments: args);
    if (mounted) widget.onFlightStart?.call(''); // 清除
  }

  @override
  Widget build(BuildContext context) {
    final bucket = widget.bucket;
    return PressScale(
      onTap: _open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CoverThumb(
            coverId: bucket.coverId,
            heroTag: _heroTag,
            heroEnabled:
                widget.flightTag == null || widget.flightTag == _heroTag,
          ),
          const SizedBox(height: 6),
          Text(
            bucket.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Space Mono',
              height: 1.2,
              fontFamilyFallback: AppFonts.cjkFallback,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            t(ref, 'photo_count', [bucket.count]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Space Mono',
              fontFamilyFallback: AppFonts.cjkFallback,
              fontSize: 10,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面缩略图（正方形，圆角 10）。无封面时显示占位图标。
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({
    required this.coverId,
    this.heroTag,
    this.heroEnabled = true,
  });

  final String? coverId;

  /// 封面 Hero tag（网格第一张 id，enterBucket 后动态更新）；null 时用 coverId。
  final String? heroTag;

  /// 是否参与 Hero 配对：点击相册瞬间仅目标 tile 启用，屏蔽屏外预构建 tile。
  final bool heroEnabled;

  @override
  Widget build(BuildContext context) {
    if (coverId == null || coverId!.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(Icons.photo_outlined,
            color: AppColors.muted, size: 24),
      );
    }
    final ref = imageRefFromMediaStoreId(coverId!);
    // 封面缩略图像素尺寸 = 显示尺寸 × dpr（物理对齐，替代固定 300）
    final side = MediaQuery.sizeOf(context).width / 3 - 14;
    final thumbSize =
        (side * MediaQuery.devicePixelRatioOf(context)).round().clamp(96, 512);
    // [ente 对齐] 封面包 Hero：与相册网格第一张 cell（GalleryFileWidget
    // tag 'photo_${id}'）配对 → 进入/返回时封面↔第一张图飞行。
    return AspectRatio(
      aspectRatio: 1,
      child: HeroMode(
        enabled: heroEnabled,
        child: Hero(
          tag: heroTag ?? 'photo_$coverId',
          flightShuttleBuilder:
              (flightContext, animation, type, fromHeroContext, toHeroContext) =>
                  (toHeroContext.widget as Hero).child,
          transitionOnUserGestures: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image(
              image:
                  buildThumbnailProvider(ref, size: thumbSize, squareCrop: true),
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Image(
                  image: buildThumbnailProvider(ref,
                      size: kThumbnailPlaceholderSize, squareCrop: true),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(color: AppColors.surface),
                );
              },
              errorBuilder: (ctx, error, stack) => Container(
                color: AppColors.surface,
                child: const Icon(Icons.broken_image_outlined,
                    color: AppColors.muted, size: 24),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
