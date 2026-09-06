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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/ui/screens/album_common.dart' show extOf;

import 'detail_page_state.dart'
    show kLiveViewerProviders, kViewerLargeThumbSize;
import 'gallery_context_state.dart';
import 'gallery_groups.dart' show GalleryGroups;
import 'gallery_swipe_helper.dart';
import 'package:visort_flutter/core/fs/image_cache_state.dart';
import 'selected_files.dart';
import 'thumbnail_widget.dart';
import 'touch_cross_detector.dart';

/// 从 Hero child widget 挖裸 Image 的 provider（相册封面端 child =
/// ClipRRect(Image) 固定两层结构）。挖到 = 封面↔网格链路（封面图正在
/// 显示、provider 必 completed，可直接做飞行图源同步出图）；挖不到 =
/// 网格↔viewer 链路（PhotoViewCore / ThumbnailWidget 为 stateful，
/// provider 藏在各 build 里，由此天然区分两条几何不同的链路）。
ImageProvider? _heroChildImageProvider(Widget? widget) {
  Widget? w = widget;
  while (w != null) {
    if (w is Image) return w.image;
    if (w is ClipRRect) {
      w = w.child;
      continue;
    }
    return null;
  }
  return null;
}

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
        onTap: _handleTap,
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
        onTap: _handleTap,
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

  void _handleTap() {
    widget.onTap(widget.file);
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
      // [immich 同款] 飞行内容 push 取网格端（from）child、pop 取 to（to
      // 在 pop 时也是网格端）——两个方向全程显示本端方形 cover 裁剪。
      // push：飞行框从方形 lerp 到 viewer 端原比例 contain 框，cover 裁剪
      // 逐渐展开露出被遮部分，终点框=原比例 → cover 零裁剪，与落位图
      // 无缝衔接（viewer 端 hero rect 恒为原比例框，见 zoomable_image
      // _aspectHeroFrame）。无旧方案（shuttle 恒取 viewer contain child）
      // 首帧"方形裁剪→等比 letterbox"的跳变。飞行线路（rect tween）不变。
      // 参考 immich thumbnail_tile.widget.dart flightShuttleBuilder：
      // direction == push ? from.widget : to.widget。
      flightShuttleBuilder:
          (
            flightContext,
            animation,
            flightDirection,
            fromHeroContext,
            toHeroContext,
          ) {
            final bool isPush = flightDirection == HeroFlightDirection.push;
            // 起点端 child：push=from（网格 cell / 相册封面）、pop=to（网格
            // cell / 封面）。链路分流（两条链路几何完全不同）：
            //  ① 网格↔viewer（cover 展开）：图源 live 注册表（正在显示的
            //     provider，同步出图、不受 evict/LRU 影响）→ 探测链兜底；
            //  ② 封面↔网格（两端方形 cover）：挖起点端裸 Image 的 provider
            //     （封面图正在显示，同步出图）。
            // 飞行层恒为裸 cover Image：无徽标/红心/占位图标。
            final heroChild =
                ((isPush ? fromHeroContext.widget : toHeroContext.widget)
                    as Hero).child;
            final mq = MediaQuery.of(context);
            final ref = imageRefFromMediaStoreId(
              widget.file.id,
              extension: extOf(widget.file.name),
            );
            final cache = PaintingBinding.instance.imageCache;
            // live（viewer 正在显示的 provider）只对【pop】有效——push 时
            // viewer 端尚未显示，命中的是【上次会话的残留】（opaque:false
            // 路由 dispose 延迟，kLiveViewerProviders 未清，真机日志实证
            // 3/5 次 push 被劫持且全程低档不升级 = 「飞行动画分辨率低」）。
            // push 一律走 full-pending 探测链（_openViewer 已发起 full
            // precache，~40ms 出图）。
            final live = isPush
                ? null
                : kLiveViewerProviders[widget.file.id];
            final coverProvider = _heroChildImageProvider(heroChild);
            final grid = buildThumbnailProvider(
              ref,
              size: thumbSize,
              squareCrop: true,
            );
            final ImageProvider chosen;
            final Widget? loadingUnderlay;
            if (live != null) {
              chosen = live;
              loadingUnderlay = null;
              // pop 落位预热：拖拽浏览多张大图后 ImageCache 常被 full 档
              //（~18MB/张×3 预取）挤爆、网格档被 LRU 逐出 → 落位时 tile 重
              // 解码（黑格→出图）。起飞瞬间即预热网格档（346px 解码几十
              // ms，飞行 ~200ms 内完成）→ 落位即图。completed 时立即返回。
              unawaited(precacheImage(grid, context));
            } else if (coverProvider != null) {
              // 封面链路：封面档方形裁剪图（显示中必 completed）。
              chosen = coverProvider;
              loadingUnderlay = null;
            } else if (!isPush) {
              // viewer 缺席的 pop（极罕见，如 viewer 全加载失败态直接
              // 返回）：原样 child（ente 旧机制，GlobalKey reparent）。
              return heroChild;
            } else {
              // 网格→viewer push 且 viewer 首帧未出图（远距离/切后台后首开
              // 等比档全 miss）：等比档兜底（方形 grid 源在原比例终点框会
              // 二次裁剪 → 落位视野跳变，长截图尤其明显，不可用作主图），
              // 解码等待期用网格方形档垫底——等待时飞行框仍近方形，方形源
              // 与等比源 cover 显示内容一致（同为中央方形裁剪），等比档
              // 到达后的切换无感，随后裁剪随框展开。
              final full = buildImageProvider(
                ref,
                targetWidth: computeViewerTargetWidth(
                  mq.size.width * mq.devicePixelRatio,
                ),
              );
              final large = buildThumbnailProvider(
                ref,
                size: kViewerLargeThumbSize,
                squareCrop: false,
              );
              bool anyState(ImageProvider p) {
                // 同 imageCacheState 的三态判定（含 live，见其注释）。
                final s = cache.statusForKey(p);
                return s.live || s.keepAlive || s.pending;
              }

              if (imageCacheState(full) == 'complete') {
                chosen = full;
              } else if (imageCacheState(large) == 'complete') {
                chosen = large;
              } else if (anyState(full)) {
                chosen = full;
              } else {
                chosen = large;
              }
              loadingUnderlay = imageCacheState(grid) == 'complete'
                  ? Image(image: grid, fit: BoxFit.cover)
                  : const ColoredBox(color: Colors.black);
            }
            return ClipRRect(
              borderRadius: borderRadius,
              child: Image(
                image: chosen,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                loadingBuilder: loadingUnderlay == null
                    ? null
                    : (_, child, _) => loadingUnderlay!,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: AppColors.surface),
              ),
            );
          },
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
