// 相册选择页（复制到相册 / 移至相册共用）—— aves album_pick_page 简化版
//
// 布局与首页相册列表一致（封面 44 + 名称 + 数量的行），仅显示标题与系统
// 相册列表：点选目标相册即 pop 返回 [MsBucket]，由调用方执行复制/移动。
// 无排序/视图切换等首页附加控件（选择器保持最简，aves 同款「仅标题+列表」）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';

/// 打开相册选择页。返回选中的相册；取消返回 null。
/// 顶栏标题恒「相册」（2026-09 用户定稿：不区分复制/移入来源）。
Future<MsBucket?> pushAlbumPicker(BuildContext context) {
  return Navigator.of(context).push<MsBucket>(
    MaterialPageRoute(
      settings: const RouteSettings(name: '/album-picker'),
      builder: (_) => const AlbumPickerScreen(),
    ),
  );
}

class AlbumPickerScreen extends ConsumerStatefulWidget {
  const AlbumPickerScreen({super.key});

  @override
  ConsumerState<AlbumPickerScreen> createState() => _AlbumPickerScreenState();
}

class _AlbumPickerScreenState extends ConsumerState<AlbumPickerScreen> {
  @override
  void initState() {
    super.initState();
    // 从相册/大图页进来时 buckets 多半已加载（首页 loadBuckets 过）；为空时
    // 兜底拉一次（例如进程重建后直接深链进相册再选图）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = ref.read(galleryControllerProvider);
      if (c.buckets.isEmpty) {
        ref.read(galleryControllerProvider.notifier).loadBuckets();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(galleryControllerProvider);
    final buckets = gallery.sortedBuckets;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        // 与 album_screen AppBar 同款：标题紧贴返回箭头
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
      ),
      body: buckets.isEmpty
          ? Center(
              child: Text(
                t(ref, 'no_albums'),
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.muted,
                  fontSize: 13,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: buckets.length,
              itemBuilder: (_, i) => _PickerRow(
                bucket: buckets[i],
                onTap: () => Navigator.of(context).pop(buckets[i]),
              ),
            ),
    );
  }
}

/// 单行相册：封面 + 名称 + 数量（首页列表 tile 同款排版）。
class _PickerRow extends StatelessWidget {
  const _PickerRow({required this.bucket, required this.onTap});

  final MsBucket bucket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              _pickerCover(bucket.coverId),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bucket.name.isEmpty ? tr('root_dir') : bucket.name,
                      style: TextStyle(
                        fontFamily: 'Space Mono',
                        height: 1.2,
                        fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.text.withValues(alpha: 0.95),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${bucket.count}',
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        height: 1.2,
                        fontSize: 10,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面缩略图（首页 _CoverThumb 同款：44 方形、圆角 6、无封面占位图标）。
  /// 不做 Hero（选择器与相册网格无配对关系）。
  Widget _pickerCover(String? coverId) {
    if (coverId == null || coverId.isEmpty) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(
          Icons.photo_outlined,
          color: AppColors.muted,
          size: 20,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image(
        image: buildThumbnailProvider(
          imageRefFromMediaStoreId(coverId),
          size: 300,
          squareCrop: true,
        ),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => Container(
          width: 44,
          height: 44,
          color: AppColors.surface,
          child: const Icon(
            Icons.broken_image_outlined,
            color: AppColors.muted,
            size: 20,
          ),
        ),
      ),
    );
  }
}
