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

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart' show HomeLayout;
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/shared/widgets/app_bar_title.dart';
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

class _GalleryScreenState extends ConsumerState<GalleryScreen>
    with WidgetsBindingObserver {
  /// 飞行目标 tag（父级全局）：点击相册瞬间置位，所有 tile 的 HeroMode
  /// 据此屏蔽非目标 tile（含屏外预构建）；push 返回后清除。
  String? _flightTag;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(galleryControllerProvider.notifier).loadBuckets();
    });
    // 从相册内/看图器返回 `/`：重查 buckets（数量/封面可能已变）。
    currentRouteName.addListener(_onRouteChanged);
    widget.shellHandle?.onActivated = () {
      ref.read(galleryControllerProvider.notifier).loadBuckets();
    };
  }

  void _onRouteChanged() {
    if (currentRouteName.value == AppRoutes.home) {
      ref.read(galleryControllerProvider.notifier).loadBuckets();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户从系统设置授权后返回：重探权限，已授予则立即加载相册
    // （提示条「去系统设置」路径——requestPermission 被「不再询问」短路时
    // 系统设置是唯一出口，回到 app 由本钩子闭环）。
    if (state != AppLifecycleState.resumed) return;
    if (!ref.read(galleryControllerProvider).permissionDenied) return;
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      if (!ref.read(galleryControllerProvider).permissionDenied) return;
      if (await const MediaStoreChannel().hasPermission()) {
        unawaited(ref.read(galleryControllerProvider.notifier).loadBuckets());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        // 标题视觉对齐共用组件（CJK 字形重心偏下 −1.4dp 上移贴中线，
        // 见 app_bar_title.dart）。
        title: AppBarTitleText(t(ref, 'gallery_title')),
        actions: [
          // 搜索（[ente 对齐] 选项按钮左侧）：进入分类搜索页
          //（人物/位置/文件类型），页内支持文件名过滤与结果网格。
          // 自绘放大镜：与三线选项按钮/返回箭头同形制（28 画布、
          // stroke 1.9 圆头），Material Icons.search 轮廓过细过小不搭。
          // 贴近选项按钮：真机像素实测两图形间隙 34.2dp（图标盒间隙
          // 是假象——图形包络仅 ~11dp，盒内留白全算进视觉间隙）。
          // x 12.75 → 图形间隙 22dp（34.2 原始→11.2 偏紧→16.2 略紧→
          // 19.2→22，真机多轮反馈逐步回调）；y 1.1 = 图形重心偏上
          // 补偿（镜圆偏上短柄，包络中心 y≈11.1/24，真机实测比三线
          // 筛选高 1.13dp，下压贴齐 AppBar 几何中线，四元素共线）。
          // 选项按钮不动（保其与内容区右缘 16dp 对齐的既有调校）。
          Transform.translate(
            offset: const Offset(12.75, 1.1),
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
    // 权限未授予（新装/清空数据）：顶部友好引导条 + 空态骨架——不是错误，
    // 不走红色错误页（用户定稿）。
    if (gallery.permissionDenied) {
      return SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _PermissionBanner(),
            Expanded(
              child: Center(
                child: Icon(
                  Icons.photo_library_outlined,
                  size: 56,
                  color: AppColors.muted.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),
      );
    }
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
          ref.read(galleryControllerProvider.notifier).loadBuckets(),
      child: isGrid ? _buildGridBody(buckets, bottomInset) : _buildListBody(buckets, bottomInset),
    );
  }

  /// 网格布局：与快速整理页网格同构（固定列宽，列数独立配置）。
  /// 行式惰性网格（审查 F16）：原 SingleChildScrollView+Wrap 全量 inflate
  /// 全部 tile → 封面解码同时发起（首帧洪泛）。现按行切分 +
  /// SliverList.builder 行级惰性——固定列宽语义不变（GridView 的
  /// childAspectRatio 会锁死 cell 高度留白，见 home_screen_android 同款
  /// 注释，故不走 SliverGrid）；「内容最小高度撑满视口」由
  /// SliverFillRemaining 等价实现（不满一屏时填充剩余，下拉回弹不露底，
  /// 满屏时零高度）。
  Widget _buildGridBody(List<MsBucket> buckets, double bottomInset) {
    final cols = ref.watch(configProvider).galleryGridColumns;
    // spacing 4 + tile 内水平 padding 4×2 = 相邻封面间隙 12dp（用户定稿，
    // 中间曾调 10dp 后回调）；top 10 + tile vertical 2 = 顶栏到首行封面
    // 12dp。
    const spacing = 4.0;
    const hpad = 12.0;
    return LayoutBuilder(
      builder: (ctx, c) {
        final cellW = (c.maxWidth - hpad * 2 - spacing * (cols - 1)) / cols;
        final rowCount = (buckets.length + cols - 1) ~/ cols;
        return CustomScrollView(
          // 动画对齐 ente：iOS 式回弹滚动物理（AlwaysScrollable 保下拉刷新）。
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(hpad, 10, hpad, 0),
              sliver: SliverList.builder(
                itemCount: rowCount,
                itemBuilder: (ctx, r) {
                  final start = r * cols;
                  final end =
                      start + cols < buckets.length ? start + cols : buckets.length;
                  return Padding(
                    // 首行不加顶距（SliverPadding 已有 10dp 顶距）
                    padding: EdgeInsets.only(top: r == 0 ? 0 : spacing),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = start; i < end; i++)
                          Padding(
                            padding: EdgeInsets.only(
                                left: i > start ? spacing : 0),
                            child: SizedBox(
                              width: cellW,
                              child: _AlbumTile(
                                grid: true,
                                bucket: buckets[i],
                                flightTag: _flightTag,
                                onFlightStart: (tag) =>
                                    setState(() => _flightTag = tag),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // 撑满剩余视口（原 ConstrainedBox minHeight 语义）+ 尾部 inset
            //（末行封面不被手势条压住）。
            SliverPadding(
              padding: EdgeInsets.only(bottom: 16 + bottomInset),
              sliver: const SliverFillRemaining(
                hasScrollBody: false,
                child: SizedBox.expand(),
              ),
            ),
          ],
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
      padding: EdgeInsets.only(top: 10, bottom: 16 + bottomInset),
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

/// 未授权顶部引导条（新装/清空数据首启）：友好提示而非错误页。
///
/// 主行 = 图标 + 文案 + 「授予权限」按钮（弹系统权限窗，授予后自动加载，
/// 条随 permissionDenied 清除而消失）。弹过仍被拒（含「不再询问」后
/// requestPermission 立即回调 denied 不再弹窗）→ 追加副行「到系统设置」
/// 跳转入口；从设置授权回来由页面的 lifecycle resumed 钩子闭环加载。
class _PermissionBanner extends ConsumerStatefulWidget {
  const _PermissionBanner();

  @override
  ConsumerState<_PermissionBanner> createState() => _PermissionBannerState();
}

class _PermissionBannerState extends ConsumerState<_PermissionBanner> {
  /// 点过授权按钮但仍未授予 → 显示系统设置跳转副行。
  bool _deniedOnce = false;

  Future<void> _grant() async {
    final ok = await const MediaStoreChannel().requestPermission();
    if (!mounted) return;
    if (ok) {
      // 授权成功 → 重查（permissionDenied 清除后本条随分支消失）。
      await ref.read(galleryControllerProvider.notifier).loadBuckets();
    } else {
      // 拒绝或「不再询问」短路 → 补系统设置出口（lifecycle 钩子接住回程）。
      setState(() => _deniedOnce = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 22,
                color: AppColors.accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t(ref, 'gallery_perm_hint'),
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    color: AppColors.text,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _grant,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 13,
                  ),
                ),
                child: Text(t(ref, 'grant_permission')),
              ),
            ],
          ),
          if (_deniedOnce) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () =>
                  const MediaStoreChannel().openAppSettings(),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.settings_outlined,
                      size: 14,
                      color: AppColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      t(ref, 'gallery_perm_settings_hint'),
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: AppFonts.cjkFallback,
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
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

  /// 导航防重入【static 跨全部 tile 实例互斥】：双指同点两个 tile 时
  /// 两个 _open 并发执行（曾无锁：双路由入栈打断首路由 Hero flight →
  /// 飞行被吃/黑 tile 残影/残影吞点击，2026-09 真机多轮实证）。锁在
  /// 首个 await 前同步置位——同 isolate 内后续 tap 必然看到 true。
  static bool _navInFlight = false;

  Future<void> _open() async {
    // [GAL] 入口打点（排查"返回后点击无反应"，2026-09）：区分三类——
    // locked（锁被占，上一轮导航未结束）/ 全程无 enter 日志（onTap 被
    // 浮层屏障吞）/ enter 后 abort（state 竞态）。
    debugPrint('[GAL] open tap bucket=${widget.bucket.id} '
        'locked=$_navInFlight view=${ref.read(galleryControllerProvider).view}');
    if (_navInFlight) return;
    _navInFlight = true;
    try {
      // [ente 对齐] 相册打开 = 200ms fade + 封面 Hero 飞行（封面↔网格第一张图）。
      // 先 await enterBucket：push 时网格第一张 cell 必须已存在（Hero 终点），
      // 否则 flight 不启动（数据异步查询错过动画窗口）。快照命中秒回；
      // 首次查 MediaStore ~100-300ms（一次性，之后快照直出）。
      final notifier = ref.read(galleryControllerProvider.notifier);
      await notifier.enterBucket(widget.bucket.id);
      if (!mounted) return;
      final s = ref.read(galleryControllerProvider);
      // 终局裁决（await 之后、push 之前）：await 窗口内 state 可能已被
      // 其他入口（Shell 切页/收藏/回收站）切走——非本桶直接放弃导航，
      // 且不拿他桶首张做 Hero（跨桶 tag 与真实终点对不上）。
      if (s.bucketId != widget.bucket.id) {
        debugPrint('[GAL] gallery nav-abort(own) bucket=${widget.bucket.id} '
            'state=${s.bucketId}');
        return;
      }
      // 已有相册路由在栈（防一切来源的并发导航）：push 是 UI 线程同步
      // 原子操作，两并发流只可能一个在 push 前观测到 canPop==false。
      if (Navigator.of(context).canPop()) {
        debugPrint('[GAL] gallery nav-abort(canPop) bucket=${widget.bucket.id}');
        return;
      }
      final photos = s.photos;
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
    } finally {
      _navInFlight = false;
    }
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
