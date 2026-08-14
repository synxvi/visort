// [ente 移植] 网格 item —— 原文件：ente .../ui/viewer/gallery/component/gallery_file_widget.dart
//
// 保留（与 ente 一致）：
//   - Hero（tag = 'photo_${file.id}'，flightShuttleBuilder 返回 toHeroContext.child，
//     transitionOnUserGestures: true）
//   - GestureDetector onTap/onLongPress 回调（外部注入，选中/路由逻辑由网格层处理）
//   - 选中态：40% 黑罩 + 右上角 check_circle 勾选圈（AppColors.accent）
//   - ClipRRect borderRadius = Radius.circular(1)
//
// 适配 visort：
//   - ente 文件模型 → MsImageInfo（tag = 'photo_${id}'）
//   - ThumbnailWidget 加载管线（buildThumbnailProvider，thumbnailSize 按 photoGridSize 传 512/256）
//   - selectedFiles 用 SelectedFiles（id 匹配）
//   - 删除：owner avatar、上传监听/事件、picker 分支、滑动选择、单选限制、
//     假文件对象、事件总线、云服务、路由（DetailPage）

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

import 'gallery_groups.dart' show GalleryGroups;
import 'selected_files.dart';
import 'thumbnail_widget.dart';

/// 网格单元格：缩略图 + Hero 飞行层 + 选中态遮罩/勾选圈。
///
/// 点击/长按通过 [onTap]/[onLongPress] 透传给网格层处理（选中切换、路由到
/// DetailPage 等），本 widget 不持有业务逻辑。
class GalleryFileWidget extends StatefulWidget {
  final MsImageInfo file;
  final SelectedFiles? selectedFiles;

  /// 网格列数；< 4 用 512 缩略图，否则 256（ente photoGridSizeDefault=4 语义）。
  final int photoGridSize;

  /// 点击回调。
  final ValueChanged<MsImageInfo> onTap;

  /// 长按回调。
  final ValueChanged<MsImageInfo> onLongPress;

  const GalleryFileWidget({
    required this.file,
    required this.selectedFiles,
    required this.photoGridSize,
    required this.onTap,
    required this.onLongPress,
    super.key,
  });

  @override
  State<GalleryFileWidget> createState() => _GalleryFileWidgetState();
}

class _GalleryFileWidgetState extends State<GalleryFileWidget> {
  static const borderRadius = BorderRadius.all(Radius.circular(1));
  late bool _isFileSelected;

  @override
  void initState() {
    super.initState();
    _isFileSelected =
        widget.selectedFiles?.isFileSelected(widget.file) ?? false;
    widget.selectedFiles?.addListener(_selectedFilesListener);
  }

  @override
  void dispose() {
    widget.selectedFiles?.removeListener(_selectedFilesListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => widget.onTap(widget.file),
      onLongPress: () => widget.onLongPress(widget.file),
      child: _buildFileContent(context),
    );
  }

  Widget _buildFileContent(BuildContext context) {
    final String heroTag = 'photo_${widget.file.id}';
    // [visort 适配] 缩略图尺寸：cell 逻辑宽 × dpr（clamp 160~512），与
    // viewer zoomable_image/_cellThumbSize 同公式 → ImageCache key 一致，
    // 飞行层/Hero 首帧直接命中。原 ente 固定 256（列数≥4）在 4 列高 dpr
    // 真机（cell 物理 ~316px）欠采样发糊。
    final mq = MediaQuery.of(context);
    final cellW =
        (mq.size.width - 8 - (widget.photoGridSize - 1) * GalleryGroups.spacing) /
        widget.photoGridSize;
    final thumbSize =
        (cellW * mq.devicePixelRatio).round().clamp(160, 512);
    final Widget thumbnailWidget = ThumbnailWidget(
      widget.file,
      key: Key(heroTag),
      thumbnailSize: thumbSize,
    );
    final Widget hero = Hero(
      tag: heroTag,
      flightShuttleBuilder:
          (
            flightContext,
            animation,
            flightDirection,
            fromHeroContext,
            toHeroContext,
          ) => (toHeroContext.widget as Hero).child,
      transitionOnUserGestures: true,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: thumbnailWidget,
      ),
    );
    if (_isFileSelected) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            key: ValueKey(heroTag),
            borderRadius: borderRadius,
            child: hero,
          ),
          // 40% 黑罩（ente Color.fromARGB(102, 0, 0, 0) 同值）。
          Container(
            decoration: BoxDecoration(
              color: Color.fromARGB(102, 0, 0, 0),
              borderRadius: borderRadius,
            ),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: Icon(
              Icons.check_circle,
              size: 16,
              color: AppColors.accent,
            ),
          ),
        ],
      );
    }
    return ClipRRect(
      key: ValueKey(heroTag),
      borderRadius: borderRadius,
      child: hero,
    );
  }

  void _selectedFilesListener() {
    late bool latestSelectionState;
    if (widget.selectedFiles?.files.contains(widget.file) ?? false) {
      latestSelectionState = true;
    } else {
      latestSelectionState = false;
    }
    if (latestSelectionState != _isFileSelected && mounted) {
      setState(() {
        _isFileSelected = latestSelectionState;
      });
    }
  }
}
