// 相册浏览屏（首页：相册列表）—— 安卓 MediaStore
//
// 展示所有相册（bucket），每行：
//   左侧封面缩略图（该相册最新一张图）+ 相册名 + 总数 badge
//   右侧 Checkbox（勾选作为"源相册"，传递回 setup 用于分类）
//   点缩略图/名称区 → 进入相册内浏览（AlbumScreen）
//
// 排序：AppBar 右侧 SortToggle，偏好持久化到 AppConfig。
//
// 与 SetupScreenAndroid 的关系：本屏是独立的"浏览/管理"入口，
// Setup 的源相册勾选是另一套状态。两者复用 listBuckets 数据源但状态隔离。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/gallery/gallery_controller.dart';
import 'package:sortr_flutter/shared/widgets/sort_toggle.dart';
import 'package:sortr_flutter/ui/router.dart';

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(galleryControllerProvider.notifier).loadBuckets();
    });
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(galleryControllerProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        title: Text(t(ref, 'gallery_title'),
            style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontWeight: FontWeight.w800,
                fontSize: 18)),
        actions: [
          SortToggle(
            sortBy: gallery.albumSortBy,
            asc: gallery.albumSortAsc,
            onChanged: (by, asc) =>
                ref.read(galleryControllerProvider.notifier).setAlbumSort(by, asc),
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
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () =>
          ref.read(galleryControllerProvider.notifier).loadBuckets(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: buckets.length + 2,
        itemBuilder: (ctx, i) {
          if (i == 0) return const _FavoritesTile();
          if (i == 1) return const _TrashTile();
          return _AlbumTile(bucket: buckets[i - 2]);
        },
      ),
    );
  }
}

/// 「收藏」入口行（P1b）：置顶于相册列表，进入跨相册收藏视图。
class _FavoritesTile extends ConsumerWidget {
  const _FavoritesTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.favorite, color: AppColors.danger, size: 24),
      ),
      title: Text(
        t(ref, 'favorites_title'),
        style: const TextStyle(
          color: AppColors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: ['SpaceMono'],
        ),
      ),
      trailing:
          const Icon(Icons.chevron_right, color: AppColors.muted, size: 20),
      onTap: () => Navigator.pushNamed(context, AppRoutes.album,
          arguments: const {'favoritesOnly': true}),
    );
  }
}

/// 「回收站」入口行（P1a）：进入跨相册回收站视图（IS_TRASHED=1）。
class _TrashTile extends ConsumerWidget {
  const _TrashTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.muted.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.delete_outline, color: AppColors.muted, size: 24),
      ),
      title: Text(
        t(ref, 'trash_title'),
        style: const TextStyle(
          color: AppColors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: ['SpaceMono'],
        ),
      ),
      trailing:
          const Icon(Icons.chevron_right, color: AppColors.muted, size: 20),
      onTap: () => Navigator.pushNamed(context, AppRoutes.album,
          arguments: const {'trashedOnly': true}),
    );
  }
}

/// 单个相册行：左封面 + 名称 + 总数 → 点击进相册；右侧 Checkbox（预留勾选）
class _AlbumTile extends ConsumerWidget {
  const _AlbumTile({required this.bucket});
  final MsBucket bucket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, AppRoutes.album,
          arguments: {
            'bucketId': bucket.id,
            'bucketName': bucket.name,
            'bucketCount': bucket.count,
          }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // 封面缩略图
            _CoverThumb(coverId: bucket.coverId, size: 56),
            const SizedBox(width: 14),
            // 名称
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bucket.name,
                    style: TextStyle(
                      fontFamily: 'SpaceMono',
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.text.withValues(alpha: 0.95),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t(ref, 'photo_count', [bucket.count]),
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 进入箭头
            const Icon(Icons.chevron_right, color: AppColors.muted, size: 22),
          ],
        ),
      ),
    );
  }
}

/// 封面缩略图（正方形，圆角）。无封面时显示占位图标。
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.coverId, required this.size});
  final String? coverId;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (coverId == null || coverId!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(Icons.photo_outlined,
            color: AppColors.muted, size: 24),
      );
    }
    final ref = imageRefFromMediaStoreId(coverId!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image(
        image: buildThumbnailProvider(ref, size: 200),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (ctx, error, stack) => Container(
          width: size,
          height: size,
          color: AppColors.surface,
          child: const Icon(Icons.broken_image_outlined,
              color: AppColors.muted, size: 24),
        ),
      ),
    );
  }
}
