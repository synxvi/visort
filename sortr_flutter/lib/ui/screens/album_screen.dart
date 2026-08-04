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
import 'package:sortr_flutter/core/theme/app_animations.dart';
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
        // 标题紧贴返回箭头（默认 titleSpacing 16 会显得相册名离箭头太远）
        titleSpacing: 0,
        title: Text(
          widget.trashedOnly
              ? t(ref, 'trash_title')
              : (widget.favoritesOnly
                  ? t(ref, 'favorites_title')
                  : (widget.bucketName ?? t(ref, 'gallery_title'))),
          style: TextStyle(
            fontFamily: 'Space Mono', height: 1.2,
            fontFamilyFallback: AppFonts.cjkFallback,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          SortToggle(
            sortBy: gallery.effectivePhotoSortBy,
            asc: gallery.photoSortAsc,
            // 回收站视图额外提供「按删除日期」
            showDateTrashed: widget.trashedOnly,
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
                  style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.danger, fontSize: 12)),
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
              style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted, fontSize: 13)));
    }
    final cols = ref.watch(configProvider).photoGridColumns;
    return Stack(
      children: [
        GridView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
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
            // ⚠️ 不要用 RepaintBoundary 包 cell：滚动时每个新 cell 创建独立
            // layer、旧 cell 销毁，频繁 layer 分配会拖慢滚动（实测滚动变卡）。
            // cell 保持纯 InkWell + Image（与无动画版本一致，滚动流畅）。
            return _PhotoCell(
              info: info,
              onTap: (cellRect) =>
                  _openViewer(context, gallery, photos, i, cellRect),
            );
          },
        ),
        // 右侧滚动拖拽手柄：向下滚动后出现，可拖拽跳转。
        // 用真实图片总数（bucket.count）+ 固定单行高度算进度，
        // 分母稳定不变 → 分页 loadMore 时手柄绝不回跳。
        ScrollDragHandle(
          controller: _scrollCtrl,
          totalItems: widget.bucketCount ?? photos.length,
          rowExtent:
              (MediaQuery.sizeOf(context).width - 4 * 2 - (cols - 1) * 3) /
                  cols +
              3,
          columns: cols,
          viewportRows: 5,
        ),
      ],
    );
  }

  /// 打开大图浏览器：用 PageRouteBuilder 的 transitionsBuilder 实现
  /// "图从 cell 位置线性放大到全屏"的缩放动画。
  /// ⚠️ 必须用 route transition，不能用 Overlay AnimationController：
  /// ColorOS DynamicFramerate 对 Overlay 上的自定义动画在 Choreographer 层
  /// 降帧到 30 且粘滞不恢复（实测）；route 过渡动画是系统 push/pop 驱动，
  /// ColorOS 不降帧（fade 版实测全程 120）。
  /// [cellRect] 为点击 cell 的屏幕坐标；null 时无缩放动画。
  void _openViewer(
    BuildContext context,
    GalleryState gallery,
    List<MsImageInfo> photos,
    int index,
    Rect? cellRect,
  ) {
    final info = photos[index];
    final imgRef =
        imageRefFromMediaStoreId(info.id, extension: extOf(info.name));
    // 预解码 2880 原图（native readSampledImage，~92ms）：点击瞬间发起，与 push
    // 飞行动画并发——动画期间 viewer 被 Opacity 0 隐藏，2880 在后台解码。250ms 动画
    // 期内解完则缩放结束瞬间即高清（t=1 仍垫 300 与飞行末帧衔接无跳变，1~2 帧后
    // 2880 命中缓存覆盖 300）。不 await，不阻塞 push。
    // 不预载 768：768 层已移除——loadThumbnail(~50ms) 比 readSampledImage(~92ms) 快，
    // 保留它会抢先生成造成多一次闪现；直接 300→2880 更干脆。
    precacheImage(
        buildImageProvider(imgRef,
            targetWidth: computeViewerTargetWidth(
                MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))),
        context);
    // 飞行层图片：闭包捕获，transitionsBuilder 每帧复用（不重建 provider）。
    // ⚠️ 必须用 size:300（网格同 key，ImageCache 已缓存）——用 1024 时动画
    // 250ms 内 loadThumbnail 加载不完 → 飞行层空白 → 灰屏且无缩放效果。
    // errorBuilder 用灰块兜底：即使加载失败也有可见内容在放大（诊断+兜底）。
    final flightImage = Image(
      image: buildThumbnailProvider(imgRef, size: 300),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      loadingBuilder: (ctx, child, progress) {
        debugPrint('[FlightImg] loading progress=$progress');
        return child;
      },
      errorBuilder: (_, _, _) {
        debugPrint('[FlightImg] ERROR');
        return const ColoredBox(color: Color(0xFF2A2A2A));
      },
    );
    Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      // ⚠️ opaque: false —— pop 返回动画期间底下 album 网格参与合成并可见
      // （COUI 式返回：viewer 淡出 + 飞行层缩回时网格全程在底下，动画结束
      // 无"黑→网格瞬现"）。push 期网格被下方恒黑垫底层盖住，观感不变；
      // 代价是动画期间多一层网格合成（180~250ms，Impeller 下可接受）。
      opaque: false,
      // route animation 驱动 rect 缩放：
      // push（anim 0→1）：图从 cellRect 线性放大到全屏 contain；
      // pop（anim 1→0）：图从全屏缩回 cellRect。
      // child = PhotoViewer 页面（在飞行层下方）。
      transitionsBuilder: (ctx, anim, _, child) {
        debugPrint(
            '[Flight] t=${anim.value.toStringAsFixed(2)} status=${anim.status} cellRect=$cellRect');
        final size = MediaQuery.sizeOf(ctx);
        // 终点与 viewer 图区域一致（PageView 页 Padding(horizontal:4)）。
        final fullRect = Rect.fromLTWH(4, 0, size.width - 8, size.height);
        // COUIMoveEase 替代原 linear：强 ease-out，图"冲"到全屏而非匀速滑入。
        // 原 linear 已验证可用但略机械；couiMoveEase 更贴近一加手感。
        final t = AppCurves.couiMoveEase.transform(anim.value);
        final rect = Rect.lerp(cellRect ?? fullRect, fullRect, t)!;
        // ⚠️ showFlight 必须用 status 判断（不能用 anim.value < 1）：
        // completed 后 transitionsBuilder 不再 rebuild，若黑底留在树里会
        // 永远盖住 viewer。pop 触发时 status 变 reverse → 飞行层重新出现。
        final showFlight =
            cellRect != null && anim.status != AnimationStatus.completed;
        // push 时 viewer 完全隐藏,让飞行层独占缩放动画——否则 viewer 的满屏
        // 清晰图(_openViewer 里 precache 预加载的 2880)会随 t 淡入,与飞行
        // 缩略图重叠成"底下垫满屏图 + 缩放动画"的双图观感。pop 时仍随 t 淡出
        // (与返回手势衔接)。t=1 飞行层移除瞬间 viewer 显现,其 300 垫底与飞行
        // 末帧(300 满屏 contain)同布局,无跳变。
        final isReverse = anim.status == AnimationStatus.reverse;
        final viewerOpacity = isReverse ? t : (showFlight ? 0.0 : 1.0);
        // 飞行层渐显渐隐：起点/终点 15% 内淡入淡出（避免 push 突兀出现 /
        // pop 缩回瞬间消失）。
        final baseBlack = (t / 0.15).clamp(0.0, 1.0);
        // 黑遮罩仅 push 期使用：viewer 半透明（t<1）时盖住底层，viewer 完全
        // 可见（t=1）时 black=0，showFlight 移除瞬间（completed）chrome 顶/底栏
        // 不会从"被黑盖住"突变到可见。（旧逻辑末段加深到 0.95 再整层移除 → 闪烁）
        // ⚠️ pop 返回时 black=0：配合 opaque:false 让底下相册网格全程可见
        // （COUI 式返回），viewer 淡出 + 飞行层缩回时网格透出，动画结束
        // 无"黑→网格瞬现"。
        final black = isReverse ? 0.0 : (1.0 - t).clamp(0.0, 1.0) * 0.95;
        return Stack(
          fit: StackFit.expand,
          children: [
            // ⚠️ 垫底（仅 push 期）：纯黑（= viewer Scaffold 背景），**恒不透明**——
            // push 期 viewer 隐藏、飞行层 contain 留白透出本层；t=1 飞行层移除、
            // viewer 显现，留白从「垫底」交接到「viewer 背景」，二者同色避免
            // 灰→黑跳变闪烁（原 #0F0F0F 与 viewer 纯黑差 15 → 图片上下留白闪灰）。
            // pop 返回时移除本层——opaque:false 下底层网格参与合成，viewer 淡出
            // 即露出网格；保留本层会把网格重新盖死（又变回"瞬现"）。
            if (!isReverse) const ColoredBox(color: Colors.black),
            // viewer 页面：push 隐藏飞行层独占缩放;pop 走 viewerOpacity(t)淡出。
            Opacity(opacity: viewerOpacity, child: child),
            if (showFlight) ...[
              if (black > 0)
                ColoredBox(color: Colors.black.withValues(alpha: black)),
              // ⚠️ Positioned 必须直接作为 Stack 的 child！之前在 Opacity 里
              // （Opacity→Positioned），release 下不报错但定位不生效、图尺寸
              // 为 0 → 飞行层不可见 → “无缩放”（多版灰屏的根因）。
              // 渐隐用 Positioned 内部的 Opacity 实现。
              Positioned.fromRect(
                rect: rect,
                child: Opacity(opacity: baseBlack, child: flightImage),
              ),
            ],
          ],
        );
      },
      // pageBuilder 的 anim 与 transitionsBuilder 的 anim 是同一个 route 动画：
      // 传给 viewer 用于门控 2880 原图加载时机（completed 前不加载，见 PhotoViewer）。
      pageBuilder: (_, anim, _) => PhotoViewer(
        photos: photos,
        initialIndex: index,
        hasMore: ref.read(galleryControllerProvider).hasMore,
        totalCount: widget.bucketCount,
        onLoadMore: () =>
            ref.read(galleryControllerProvider.notifier).loadMore(),
        transition: anim,
      ),
      settings: const RouteSettings(name: AppRoutes.photoViewer),
      fullscreenDialog: true,
    ));
  }
}

/// 单个缩略图 cell：InkWell + cover 缩略图。
/// 无额外动画状态（滚动性能与普通网格一致）；点击时在自身 context 里记录
/// cell 屏幕坐标（注意：itemBuilder 的 ctx.findRenderObject() 返回的是
/// RenderSliverGrid，强转 RenderBox 会崩——必须在 cell 自己的 context 取），
/// 坐标传给 [_AlbumScreenState] 打开 viewer（飞行层动画在 viewer 侧播放）。
class _PhotoCell extends StatelessWidget {
  const _PhotoCell({required this.info, required this.onTap});
  final MsImageInfo info;
  final ValueChanged<Rect?> onTap;

  @override
  Widget build(BuildContext context) {
    final ref = imageRefFromMediaStoreId(info.id, extension: extOf(info.name));
    return InkWell(
      onTap: () {
        final box = context.findRenderObject();
        final rect = (box is RenderBox && box.attached)
            ? box.localToGlobal(Offset.zero) & box.size
            : null;
        debugPrint('[Flight] onTap box=$box rect=$rect');
        onTap(rect);
      },
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
