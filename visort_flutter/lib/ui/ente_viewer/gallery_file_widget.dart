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
//   - 滑动多选（2026-09 补回，原移植时删除）：TouchCrossDetector 命中 +
//     GallerySwipeHelper 激活时 enter→start/update、hover→起点兜底；长按
//     进入选择态后不松手直接拖 = 连续勾选（_handleLongPressForSwipe）。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

import 'gallery_context_state.dart';
import 'gallery_groups.dart' show GalleryGroups;
import 'gallery_swipe_helper.dart';
import 'selected_files.dart';
import 'thumbnail_widget.dart';
import 'touch_cross_detector.dart';

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

  // ── 滑动多选（ente SwipeSelectableFileWidget 同款状态）──
  // 手指是否仍在本 tile 内 / 按下时的指针 id（长按起手确认用）。
  bool _isPointerInside = false;
  int? _currentPointerId;

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
    // 未启用滑动多选（Gallery 未下发 helper，如搜索页）→ 原始 cell，零开销。
    final swipeHelper = GallerySwipeHelper.of(context);
    final swipeActiveNotifier = GallerySwipeHelper.swipeActiveNotifierOf(
      context,
    );
    if (swipeHelper == null || swipeActiveNotifier == null) {
      return GestureDetector(
        onTap: () => widget.onTap(widget.file),
        onLongPress: () => widget.onLongPress(widget.file),
        child: _buildFileContent(context),
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: swipeActiveNotifier,
      builder: (context, isSwipeActive, child) {
        // 激活瞬间手指正好停在本 tile（没经过 enter）→ 下一帧补起点，
        // 解决"激活与 enter 同帧"竞态（ente 同款兜底）。
        if (isSwipeActive &&
            _isPointerInside &&
            !swipeHelper.isActive &&
            widget.selectedFiles != null &&
            widget.selectedFiles!.files.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                isSwipeActive &&
                _isPointerInside &&
                !swipeHelper.isActive) {
              swipeHelper.startSelection(widget.file);
            }
          });
        }
        return TouchCrossDetector(
          onPointerDown: (event) {
            _isPointerInside = true;
            _currentPointerId = event.pointer;
            // 报备待定起点：激活后锚定时优先用（见 helper._pendingStart 注释，
            // 防"轻扫越界导致起手图被跳过"）。
            swipeHelper.notePendingStart(widget.file);
          },
          onHover: (event) {
            _isPointerInside = true;
            // 激活时手指本来就在本 tile 里 → 以本 tile 为起点。
            if (swipeActiveNotifier.value &&
                !swipeHelper.isActive &&
                widget.selectedFiles != null &&
                widget.selectedFiles!.files.isNotEmpty) {
              swipeHelper.startSelection(widget.file);
            }
          },
          onEnter: (event) {
            _isPointerInside = true;
            if (swipeActiveNotifier.value || swipeHelper.isActive) {
              if (!swipeHelper.isActive) {
                swipeHelper.startSelection(widget.file);
              } else {
                swipeHelper.updateSelection(widget.file);
              }
            }
          },
          onExit: (event) {
            _isPointerInside = false;
          },
          child: child!,
        );
      },
      child: GestureDetector(
        onTap: () => widget.onTap(widget.file),
        onLongPress: _onLongPress,
        child: _buildFileContent(context),
      ),
    );
  }

  /// 长按：先走外层回调（进入选择态并选中本图），再锚定滑动多选起点
  /// （手指仍按在本 tile 上时）——此后不松手拖动即连续勾选。
  ///
  /// 勾选态内长按同样锚定（ente 原版勾选态长按是打开大图，visort 无此
  /// 语义，长按拖选复用到勾选态）：已选图锚定无副作用（startSelection
  /// 幂等跳过），未选图选中它——「取消首张/松手后重新长按范围拖选」
  /// 都靠这条链路恢复，不依赖外层回调是否真改了选择集。
  void _onLongPress() {
    widget.onLongPress(widget.file);
    _handleLongPressForSwipe();
  }

  void _handleLongPressForSwipe() {
    final swipeHelper = GallerySwipeHelper.of(context);
    final pointerId = _currentPointerId;
    if (pointerId == null ||
        !_isPointerInside ||
        !TouchCrossDetector.isPointerActive(pointerId) ||
        swipeHelper == null ||
        widget.selectedFiles == null) {
      return;
    }
    // 长按起点固定为"选"（ente forceSelecting 语义；起点已处于选中态时
    // startSelection 内部幂等跳过重复操作与触觉）。
    swipeHelper.startSelection(widget.file, forceSelecting: true);
  }

  Widget _buildFileContent(BuildContext context) {
    final String heroTag = 'photo_${widget.file.id}';
    // [visort 适配] 缩略图尺寸：cell 逻辑宽 × dpr（clamp 160~512），与
    // viewer zoomable_image/_cellThumbSize 同公式 → ImageCache key 一致，
    // 飞行层/Hero 首帧直接命中。原 ente 固定 256（列数≥4）在 4 列高 dpr
    // 真机（cell 物理 ~316px）欠采样发糊。
    final mq = MediaQuery.of(context);
    final cellW =
        (mq.size.width -
            8 -
            (widget.photoGridSize - 1) * GalleryGroups.spacing) /
        widget.photoGridSize;
    final thumbSize = (cellW * mq.devicePixelRatio).round().clamp(160, 512);
    final Widget thumbnailWidget = ThumbnailWidget(
      widget.file,
      key: Key(heroTag),
      thumbnailSize: thumbSize,
      // 收藏视图：全部是收藏项，红心徽标冗余 → 隐藏（外层
      // GalleryContextState.hideFavoriteBadge 驱动）。
      shouldShowFavoriteIcon:
          !(GalleryContextState.of(context)?.hideFavoriteBadge ?? false),
    );
    final Widget hero = Hero(
      tag: heroTag,
      // 飞行内容取 viewer 端 Hero 的 child（PhotoViewCore 的裸 Image，
      // fit: contain）——首帧即"完整等比图 contain 于飞行框"，与网格的
      // cover 裁切显示有一次内容切换（系统相册同款），但几何比例与
      // 终点/落位全程一致（缩略图等比请求框保证，见 MediaStoreRepository
      // readThumbnail 注释）。
      flightShuttleBuilder:
          (
            flightContext,
            animation,
            flightDirection,
            fromHeroContext,
            toHeroContext,
          ) => (toHeroContext.widget as Hero).child,
      transitionOnUserGestures: true,
      child: ClipRRect(borderRadius: borderRadius, child: thumbnailWidget),
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
            child: Icon(Icons.check_circle, size: 16, color: AppColors.accent),
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
    // id 口径（2026-09 审查 F7）：HDR 回填 copyWith 换新实例后，恒等
    // contains 对新实例恒 false → 勾选圈/黑罩不显示（计数却是对的）。
    // isFileSelected 与 SelectedFiles 真源同一 id 匹配，实例无关。
    final latestSelectionState =
        widget.selectedFiles?.isFileSelected(widget.file) ?? false;
    if (latestSelectionState != _isFileSelected && mounted) {
      setState(() {
        _isFileSelected = latestSelectionState;
      });
    }
  }
}
