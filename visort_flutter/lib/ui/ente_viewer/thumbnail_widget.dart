// [ente 移植] 网格缩略图 —— 原文件：ente .../ui/viewer/file/thumbnail_widget.dart
// 加载管线改写：ente 的 LRU/磁盘/服务端/TaskQueue → visort buildThumbnailProvider
// （MediaStore 下采样，ImageCache 由 provider+size 管理）。删除上传状态/
// owner avatar/live photo/视频时长 overlay。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/ui/screens/album_common.dart' show extOf;

class ThumbnailWidget extends StatefulWidget {
  final MsImageInfo file;
  final BoxFit fit;
  final bool rawThumbnail;
  final bool shouldShowFavoriteIcon;
  final int thumbnailSize;
  final Color? placeholderColor;

  ThumbnailWidget(
    this.file, {
    Key? key,
    this.fit = BoxFit.cover,
    this.rawThumbnail = false,
    this.shouldShowFavoriteIcon = true,
    this.thumbnailSize = 256,
    this.placeholderColor,
  }) : super(key: key ?? Key(file.id));

  @override
  State<ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<ThumbnailWidget> {
  ImageProvider? _imageProvider;
  bool _hasLoadedThumbnail = false;
  bool _failed = false;

  ImageRef get _ref => imageRefFromMediaStoreId(
        widget.file.id,
        extension: extOf(widget.file.name),
      );

  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id ||
        oldWidget.thumbnailSize != widget.thumbnailSize) {
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasLoadedThumbnail && !_failed) {
      _loadThumbnail();
    }
    Widget? image;
    if (_imageProvider != null) {
      image = Image(image: _imageProvider!, fit: widget.fit, gaplessPlayback: true);
    }
    if (widget.rawThumbnail) {
      return image ?? ThumbnailPlaceHolder(color: widget.placeholderColor);
    }
    final List<Widget> contentChildren = [];
    if (image != null) contentChildren.add(image);
    if (widget.shouldShowFavoriteIcon && widget.file.isFavorite) {
      contentChildren.add(
        const Positioned(
          top: 4,
          right: 4,
          child: Icon(Icons.favorite, size: 14, color: Color(0xFFE53935)),
        ),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        ThumbnailPlaceHolder(color: widget.placeholderColor),
        if (contentChildren.isNotEmpty)
          Stack(fit: StackFit.expand, children: contentChildren),
      ],
    );
  }

  void _loadThumbnail() {
    // visort provider：按 size 下采样，ImageCache 命中（网格/飞行层共用）即显。
    final provider = buildThumbnailProvider(_ref, size: widget.thumbnailSize);
    if (PaintingBinding.instance.imageCache.containsKey(provider)) {
      setState(() {
        _imageProvider = provider;
        _hasLoadedThumbnail = true;
      });
      return;
    }
    precacheImage(provider, context).then((_) {
      if (mounted && !_hasLoadedThumbnail) {
        setState(() {
          _imageProvider = provider;
          _hasLoadedThumbnail = true;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  void _reset() {
    _imageProvider = null;
    _hasLoadedThumbnail = false;
    _failed = false;
  }
}

/// 占位（加载中/失败）：暗色块 + 图标（visort AppColors）。
class ThumbnailPlaceHolder extends StatelessWidget {
  final Color? color;
  const ThumbnailPlaceHolder({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color ?? AppColors.surface,
      child: const Center(
        child: Icon(Icons.image_outlined, color: AppColors.muted, size: 20),
      ),
    );
  }
}
