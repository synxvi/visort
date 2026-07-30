// 相册内浏览屏（网格 + 大图浏览器）—— 安卓 MediaStore
//
// 流程：从 GalleryScreen 进入，参数 bucketId。
//   顶部：相册名 + 排序切换 + 返回
//   主体：GridView 3 列缩略图网格，滚动到底加载更多（分页）
//   点击缩略图 → 全屏大图浏览器（PageView 左右滑 + InteractiveViewer 缩放 + 删除按钮）
//
// 删除：复用 galleryController.deletePhoto（requestDelete + 缓存清理 + 本地移除）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/gallery/gallery_controller.dart';
import 'package:sortr_flutter/shared/widgets/sort_toggle.dart';
import 'package:sortr_flutter/shared/widgets/toast.dart';

class AlbumScreen extends ConsumerStatefulWidget {
  const AlbumScreen({super.key, required this.bucketId, this.bucketName});

  final String bucketId;
  final String? bucketName;

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
      ref.read(galleryControllerProvider.notifier).enterBucket(widget.bucketId);
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
          widget.bucketName ?? t(ref, 'gallery_title'),
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
    // 避免 Dart/SQL 对 DATE_TAKEN 为空（NULL）行的处理差异导致首张不一致。
    final photos = gallery.photos;
    if (photos.isEmpty) {
      return Center(
          child: Text(t(ref, 'album_empty'),
              style: const TextStyle(color: AppColors.muted, fontSize: 13)));
    }
    return GridView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: photos.length + (gallery.hasMore || gallery.loadingMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i >= photos.length) {
          return const _LoadingCell();
        }
        final info = photos[i];
        return _PhotoCell(
          info: info,
          onTap: () => _openViewer(context, photos, i),
        );
      },
    );
  }

  /// 打开大图浏览器
  void _openViewer(BuildContext context, List<MsImageInfo> photos, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PhotoViewer(
        photos: photos,
        initialIndex: index,
      ),
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
    final ref = imageRefFromMediaStoreId(info.id, extension: _extOf(info.name));
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

/// 加载更多时的占位 cell
class _LoadingCell extends StatelessWidget {
  const _LoadingCell();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: const Center(
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
        ),
      ),
    );
  }
}

// ───────────────────────── 大图浏览器 ─────────────────────────

/// 全屏大图浏览器：PageView 左右滑 + InteractiveViewer 缩放 + 删除按钮。
///
/// 删除后从列表移除当前项，自动跳到下一张（或末尾）。
class PhotoViewer extends ConsumerStatefulWidget {
  const PhotoViewer({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  final List<MsImageInfo> photos;
  final int initialIndex;

  @override
  ConsumerState<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends ConsumerState<PhotoViewer> {
  late final PageController _pageCtrl;
  late List<MsImageInfo> _photos;
  late int _index;

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
    super.dispose();
  }

  Future<void> _deleteCurrent() async {
    if (_photos.isEmpty) return;
    final current = _photos[_index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(t(ref, 'delete_confirm'),
            style: const TextStyle(color: AppColors.text, fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t(ref, 'cancel'),
                style: const TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger, foregroundColor: AppColors.bg),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t(ref, 'delete_photo')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final err = await ref.read(galleryControllerProvider.notifier).deletePhoto(current.id);
    if (err != null) {
      if (mounted) toast(context, t(ref, 'delete_failed'));
      return;
    }
    if (!mounted) return;
    // 本地列表同步移除
    setState(() {
      _photos.removeAt(_index);
      if (_photos.isEmpty) {
        Navigator.pop(context);
        return;
      }
      _index = _index >= _photos.length ? _photos.length - 1 : _index;
    });
    // 跳到新的当前位置（保持页面）
    if (_pageCtrl.hasClients) {
      // 用 duration 0 避免动画错乱
      Future.microtask(() {
        if (mounted && _pageCtrl.hasClients) {
          _pageCtrl.jumpToPage(_index);
        }
      });
    }
    toast(context, t(ref, 'deleted'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: AppColors.text,
        elevation: 0,
        title: Text(
          '${_index + 1} / ${_photos.length}',
          style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 13, color: AppColors.text),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            tooltip: t(ref, 'delete_photo'),
            onPressed: _deleteCurrent,
          ),
        ],
      ),
      body: _photos.isEmpty
          ? const SizedBox.shrink()
          : Stack(
              children: [
                PageView.builder(
                  controller: _pageCtrl,
                  itemCount: _photos.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (ctx, i) {
                    final info = _photos[i];
                    return _BigImage(info: info, active: i == _index);
                  },
                ),
                // 底部图片信息栏（跟随当前图片）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _PhotoInfoBar(info: _photos[_index]),
                ),
              ],
            ),
    );
  }
}

/// 大图底部信息栏：文件名 / 大小 / 拍摄时间 / 入库时间
class _PhotoInfoBar extends ConsumerWidget {
  const _PhotoInfoBar({required this.info});
  final MsImageInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 文件名
          Text(
            info.name,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          // 元信息行：大小 · 拍摄时间 · 入库时间
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _meta('${t(ref, 'photo_size')}: ${_formatSize(info.size)}'),
              _meta(
                  '${t(ref, 'photo_taken_at')}: ${_formatDate(info.dateTakenMs)}'),
              _meta(
                  '${t(ref, 'photo_added_at')}: ${_formatDate(info.dateAddedMs)}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meta(String text) {
    return Text(
      text,
      style: TextStyle(
        color: AppColors.text.withValues(alpha: 0.7),
        fontSize: 11,
        fontFamily: 'SpaceMono',
        fontFamilyFallback: AppFonts.cjkFallback,
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '-';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

/// 单张大图：InteractiveViewer 缩放 + 双击复位
class _BigImage extends StatefulWidget {
  const _BigImage({required this.info, required this.active});
  final MsImageInfo info;
  final bool active;

  @override
  State<_BigImage> createState() => _BigImageState();
}

class _BigImageState extends State<_BigImage> {
  final TransformationController _tc = TransformationController();

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (_tc.value != Matrix4.identity()) {
      _tc.value = Matrix4.identity();
    } else {
      // 双击放大到 2x
      _tc.value = Matrix4.diagonal3Values(2.0, 2.0, 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = imageRefFromMediaStoreId(widget.info.id,
        extension: _extOf(widget.info.name));
    return GestureDetector(
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        clipBehavior: Clip.none,
        minScale: 0.8,
        maxScale: 4.0,
        child: Center(
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
      ),
    );
  }
}

// ───────────────────────── 辅助 ─────────────────────────

String _extOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '.jpg';
  return name.substring(dot).toLowerCase();
}
