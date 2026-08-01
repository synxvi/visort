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
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/gallery/gallery_controller.dart';
import 'package:sortr_flutter/ui/router.dart';
import 'package:sortr_flutter/shared/widgets/scroll_drag_handle.dart';
import 'package:sortr_flutter/shared/widgets/sort_toggle.dart';

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
  static const _threshold = 0.7; // 滚动到 70% 触发加载更多

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.favoritesOnly) {
        ref.read(galleryControllerProvider.notifier).enterFavorites();
      } else if (widget.trashedOnly) {
        ref.read(galleryControllerProvider.notifier).enterTrash();
      } else {
        ref.read(galleryControllerProvider.notifier).enterBucket(widget.bucketId);
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent * _threshold) {
      ref.read(galleryControllerProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(galleryControllerProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        title: Text(
          widget.trashedOnly
              ? t(ref, 'trash_title')
              : (widget.favoritesOnly
                  ? t(ref, 'favorites_title')
                  : (widget.bucketName ?? t(ref, 'gallery_title'))),
          style: TextStyle(
            fontFamily: 'SpaceMono',
            fontFamilyFallback: AppFonts.cjkFallback,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          SortToggle(
            sortBy: gallery.photoSortBy,
            asc: gallery.photoSortAsc,
            onChanged: (by, asc) =>
                ref.read(galleryControllerProvider.notifier).setPhotoSort(by, asc),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(gallery)),
    );
  }

  Widget _buildBody(GalleryState gallery) {
    if (gallery.loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (gallery.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: AppColors.danger),
              const SizedBox(height: 12),
              SelectableText(gallery.error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.danger, fontSize: 12)),
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
    // 直接用 scanImages 的 SQL 原序（已跟随 photoSortBy 排序），与首页封面
    // （listBuckets 取该 SQL 排序首张）严格一致。不用 sortedPhotos 内存重排，
    // 避免 Dart/SQL 对日期列（DATE_ADDED）为空（NULL）行的处理差异导致首张不一致。
    final photos = gallery.photos;
    if (photos.isEmpty) {
      return Center(
          child: Text(t(ref, 'album_empty'),
              style: const TextStyle(color: AppColors.muted, fontSize: 13)));
    }
    return Stack(
      children: [
        GridView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(4),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 3,
            mainAxisSpacing: 3,
          ),
          itemCount:
              photos.length + (gallery.hasMore || gallery.loadingMore ? 1 : 0),
          itemBuilder: (ctx, i) {
            if (i >= photos.length) {
              return const LoadingCell();
            }
            final info = photos[i];
            return _PhotoCell(
              info: info,
              onTap: () => _openViewer(context, gallery, photos, i),
            );
          },
        ),
        // 右侧滚动拖拽手柄：向下滚动后出现，可拖拽跳转。
        // 用真实图片总数（bucket.count）+ 固定单行高度算进度，
        // 分母稳定不变 → 分页 loadMore 时手柄绝不回跳。
        ScrollDragHandle(
          controller: _scrollCtrl,
          totalItems: widget.bucketCount ?? photos.length,
          rowExtent: (MediaQuery.sizeOf(context).width - 4 * 2 - 3 * 2) / 3 + 3,
          viewportRows: 5,
        ),
      ],
    );
  }

  /// 打开大图浏览器，传入分页联动回调（viewer 接近末尾时触发 loadMore）。
  void _openViewer(
    BuildContext context,
    GalleryState gallery,
    List<MsImageInfo> photos,
    int index,
  ) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PhotoViewer(
        photos: photos,
        initialIndex: index,
        hasMore: gallery.hasMore,
        totalCount: widget.bucketCount,
        onLoadMore: () =>
            ref.read(galleryControllerProvider.notifier).loadMore(),
      ),
      settings: const RouteSettings(name: AppRoutes.photoViewer),
      fullscreenDialog: true,
    ));
  }
}

/// 单个缩略图 cell
class _PhotoCell extends StatelessWidget {
  const _PhotoCell({required this.info, required this.onTap});
  final MsImageInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ref = imageRefFromMediaStoreId(info.id, extension: extOf(info.name));
    return InkWell(
      onTap: onTap,
      child: Image(
        image: buildThumbnailProvider(ref, size: 300),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (ctx, error, stack) => Container(
          color: AppColors.surface,
          child: const Icon(Icons.broken_image_outlined,
              color: AppColors.muted, size: 28),
        ),
      ),
    );
  }
}
