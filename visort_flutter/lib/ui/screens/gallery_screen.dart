// 相册列表页 —— 抽屉一级页①（默认屏）· 安卓 MediaStore
//
// 纯浏览入口：3 列封面网格（封面 + 相册名 + 数量），点相册 → push
// /album（相册内浏览，封面↔网格第一张 Hero 飞行）。历史上的 GalleryScreen
// （行式列表 + 源相册勾选 Checkbox + 收藏/回收站入口行）已随抽屉重构
// 重写：勾选职责归快速整理页、收藏/回收站归抽屉一级页，本页只做浏览。
//
// 视图选项：AppBar 右侧 ViewOptionsToggle（[ente 对齐] 布局列表↔网格单条目
// 切换 + 网格列数步进 + 排序点按换向），排序态在 GalleryController、布局/
// 列数在 configProvider，均持久化。
//
// 刷新时机：initState（首启）、抽屉切回本页（ShellHandle.onActivated）、
// 从相册内/看图器 pop 回 `/`（currentRouteName 监听）——三处都静默重查
// buckets，保证封面与数量在移动/删除后不失真。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart' show HomeLayout;
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/view_options_toggle.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/ui/screens/app_shell_android.dart'
    show DrawerMenuButton, ShellHandle;

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
    final config = ref.watch(configProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        leading: DrawerMenuButton(
          handle: widget.shellHandle,
          tooltip: t(ref, 'gallery_title'),
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
          // 搜索（[ente 对齐] 选项按钮左侧）：进入分类搜索页
          //（人物/位置/文件类型），页内支持文件名过滤与结果网格。
          // 自绘放大镜：与三线选项按钮/返回箭头同形制（28 画布、
          // stroke 1.9 圆头），Material Icons.search 轮廓过细过小不搭。
          // 贴近选项按钮：真机像素实测两图形间隙 34.2dp（图标盒间隙
          // 是假象——图形包络仅 ~11dp，盒内留白全算进视觉间隙）。
          // Transform 右移 18 → 图形间隙 16.2dp（23 版实测 11.2dp 偏紧，
          // 真机反馈回调；原始间距 34.2dp）。
          // 选项按钮不动（保其与内容区右缘 16dp 对齐的既有调校）。
          Transform.translate(
            offset: const Offset(18, 0),
            child: IconButton(
              icon: const _SearchGlyphIcon(),
              tooltip: t(ref, 'search'),
              onPressed: () =>
                  Navigator.pushNamed(context, AlbumRoutes.search),
            ),
          ),
          ViewOptionsToggle(
            layout: config.galleryLayout,
            onLayoutChanged: _setLayout,
            gridColumns: config.galleryGridColumns,
            onGridColumnsChanged: _setGridColumns,
            sortBy: gallery.albumSortBy,
            asc: gallery.albumSortAsc,
            onSortChanged: (by, asc) => ref
                .read(galleryControllerProvider.notifier)
                .setAlbumSort(by, asc),
          ),
        ],
      ),
      // [ente 对齐] 排序/布局切换内容交叉淡入 150ms（easeInQuart / easeOutExpo）。
      // 列数步进不参与 key：网格 cell 宽度跟随 reflow 即可，交叉淡入反而闪。
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
            key: ValueKey(
                (gallery.albumSortBy, gallery.albumSortAsc, config.galleryLayout)),
            child: _buildBody(gallery),
          ),
        ),
      ),
    );
  }

  /// 切换相册页布局（列表↔网格）并持久化。
  Future<void> _setLayout(HomeLayout layout) async {
    final updated =
        ref.read(configProvider).copyWith(galleryLayout: layout);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
  }

  /// 步进相册页网格列数并持久化。
  Future<void> _setGridColumns(int cols) async {
    final updated =
        ref.read(configProvider).copyWith(galleryGridColumns: cols);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
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
    // 布局配置与快速整理页解耦（galleryLayout/galleryGridColumns）：
    // 网格 = Wrap + 固定列宽（GridView 的 childAspectRatio 会锁死 cell 高
    // 留白，见 home_screen_android 同款注释）；列表 = 行式（封面+名称+数量）。
    final config = ref.watch(configProvider);
    final isGrid = config.galleryLayout == HomeLayout.grid;
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () =>
          ref.read(galleryControllerProvider.notifier).loadBuckets(silent: true),
      child: isGrid ? _buildGridBody(buckets, bottomInset) : _buildListBody(buckets, bottomInset),
    );
  }

  /// 网格布局：与快速整理页网格同构（Wrap + 固定列宽），列数独立配置。
  Widget _buildGridBody(List<MsBucket> buckets, double bottomInset) {
    final cols = ref.watch(configProvider).galleryGridColumns;
    const spacing = 4.0;
    const hpad = 12.0;
    return LayoutBuilder(
      builder: (ctx, c) {
        final cellW = (c.maxWidth - hpad * 2 - spacing * (cols - 1)) / cols;
        return SingleChildScrollView(
          // 动画对齐 ente：iOS 式回弹滚动物理（AlwaysScrollable 保下拉刷新）。
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(hpad, 8, hpad, 16 + bottomInset),
          // 内容最小高度 = 视口：相册不满一屏时撑满，下拉刷新/回弹时
          // 底部不再露出大片黑（真机实测下拉时底部 1/4 黑屏）。
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final bucket in buckets)
                  SizedBox(
                    width: cellW,
                    child: _AlbumTile(
                      grid: true,
                      bucket: bucket,
                      flightTag: _flightTag,
                      onFlightStart: (tag) => setState(() => _flightTag = tag),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 列表布局：行式 tile（封面 + 名称 + 数量 + chevron）。
  Widget _buildListBody(List<MsBucket> buckets, double bottomInset) {
    return ListView.builder(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: EdgeInsets.only(top: 8, bottom: 16 + bottomInset),
      itemCount: buckets.length,
      itemBuilder: (ctx, i) => _AlbumTile(
        grid: false,
        bucket: buckets[i],
        flightTag: _flightTag,
        onFlightStart: (tag) => setState(() => _flightTag = tag),
      ),
    );
  }
}

/// 单个相册 cell：网格态（封面 + 名称 + 内嵌数量 badge）/ 列表态
/// （封面 + 名称 + 数量 + chevron 行式）→ 点击进相册。
class _AlbumTile extends ConsumerStatefulWidget {
  const _AlbumTile({
    required this.bucket,
    required this.grid,
    this.flightTag,
    this.onFlightStart,
  });

  final MsBucket bucket;

  /// true = 网格 tile；false = 行式 tile。
  final bool grid;

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
    return widget.grid ? _buildGrid(bucket) : _buildRow(bucket);
  }

  /// 行式 tile（列表布局）：封面 + 名称/数量两行 + 右 chevron。
  Widget _buildRow(MsBucket bucket) {
    return GestureDetector(
      onTap: _open,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _CoverThumb(
              coverId: bucket.coverId,
              heroTag: _heroTag,
              heroEnabled:
                  widget.flightTag == null || widget.flightTag == _heroTag,
              size: 56,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bucket.name.isEmpty ? t(ref, 'root_dir') : bucket.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t(ref, 'photo_count', [bucket.count]),
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: AppFonts.cjkFallback,
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.muted, size: 22),
          ],
        ),
      ),
    );
  }

  /// 网格 tile：裸 GestureDetector 无按压反馈（Hero 封面飞行即反馈；
  /// 旧版 PressScale 按压缩放是已废弃的交互）。数量为封面左下角内嵌
  /// 黑 badge，名称单行紧贴封面下。
  Widget _buildGrid(MsBucket bucket) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: _open,
                  child: LayoutBuilder(
                    builder: (ctx, c) => _CoverThumb(
                      coverId: bucket.coverId,
                      heroTag: _heroTag,
                      heroEnabled: widget.flightTag == null ||
                          widget.flightTag == _heroTag,
                      size: c.maxWidth,
                    ),
                  ),
                ),
                // 数量 badge：封面左下角内嵌（IgnorePointer 穿透点击进相册）
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${bucket.count}',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                          fontFamily: 'Space Mono',
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _open,
            behavior: HitTestBehavior.opaque,
            child: Text(
              bucket.name.isEmpty ? t(ref, 'root_dir') : bucket.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Space Mono',
                height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                color: AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面缩略图（正方形，圆角 8，与快速整理页 tile 一致）。无封面时占位图标。
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({
    required this.coverId,
    required this.size,
    this.heroTag,
    this.heroEnabled = true,
  });

  final String? coverId;

  /// 显示边长（cell 宽，LayoutBuilder 传入）。
  final double size;

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
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(Icons.photo_outlined,
            color: AppColors.muted, size: 24),
      );
    }
    final ref = imageRefFromMediaStoreId(coverId!);
    // 封面缩略图像素尺寸 = 显示尺寸 × dpr（物理对齐，替代固定 300）
    final thumbSize =
        (size * MediaQuery.devicePixelRatioOf(context)).round().clamp(96, 512);
    // [ente 对齐] 封面包 Hero：与相册网格第一张 cell（GalleryFileWidget
    // tag 'photo_${id}'）配对 → 进入/返回时封面↔第一张图飞行。
    // 显式 SizedBox（不用 AspectRatio）：列表态 tile 直接放在 Row 里，
    // 宽高双无界约束下 AspectRatio 无法求解 → 渲染异常 → 整页黑屏
    //（真机实测：列表布局进入只显示顶栏）。网格态同效（size=cellW）。
    return SizedBox(
      width: size,
      height: size,
      child: HeroMode(
        enabled: heroEnabled,
        child: Hero(
          tag: heroTag ?? 'photo_$coverId',
          flightShuttleBuilder:
              (flightContext, animation, type, fromHeroContext, toHeroContext) =>
                  (toHeroContext.widget as Hero).child,
          transitionOnUserGestures: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
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

/// 自绘放大镜图标（搜索按钮用）。
///
/// 形制对齐 _FilterMorphPainter / _BackGlyphPainter：24 基准视口、
/// stroke 1.9、圆头笔帽。包络刻意收窄到 ~10.4 方形（三线按钮内容盒
/// 11.2×8.2 同宽），柄短促——大圆长柄版本视觉重量超三线按钮，实测偏笨。
class _SearchGlyphIcon extends StatelessWidget {
  const _SearchGlyphIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _SearchGlyphPainter(),
    );
  }
}

class _SearchGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    final paint = Paint()
      ..color = AppColors.text
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round;
    // 镜圆：中心 (10.1, 10.3) 半径 4.3 → 圆盒 (5.8~14.4)×(6.0~14.6)
    final c = Offset(10.1, 10.3) * scale;
    final r = 4.3 * scale;
    canvas.drawCircle(c, r, paint);
    // 柄：圆 45° 切点 → 短柄终点 (16.2, 16.2)，整包络 (5.8~16.2)²
    final start = Offset(13.14, 13.34) * scale;
    final end = Offset(16.2, 16.2) * scale;
    canvas.drawLine(start, end, paint);
  }

  @override
  bool shouldRepaint(covariant _SearchGlyphPainter oldDelegate) => false;
}
