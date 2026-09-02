// 安卓抽屉壳层 —— 左侧抽屉 + 一级页容器
//
// `/` 路由（仅安卓）挂本壳。5 个一级页以惰性 IndexedStack 保活：
//   ① 相册 ② SORT（快速整理，2026-08 更名+提位） ③ 收藏 ④ 回收站
//   ⑤ 设置。默认首页可配（设置 → 通用，默认相册）——启动屏与返回终点。
// 「惰性」= 访问过的页才真正 build（位掩码标记），未访问槽位放空盒——
// 避免冷启时 5 页同时 initState（3 路 MediaStore 查询互相覆盖 loadToken、
// 权限弹窗与数据加载竞态）。已访问页常驻，状态保留（快速整理页的勾选/
// 输入草稿、收藏/回收站的滚动位置在页间切换后不丢）。
//
// 抽屉与当前页同树，推拉缩放动画才是连续 transform（参考演示样式）：
// 打开时抽屉带视差从左滑入，当前页同步缩小(topLeft 锚点)+右移+圆角+投影，
// 顶栏 ☰ 语义变为「点缩小页/返回键关闭」；关闭反向。
//
// sort/review/results、相册内浏览（/album）、大图查看器仍是 Navigator push
// 的二级页，脱离抽屉体系（全屏、无抽屉手势）。
//
// 返回键四段分发（本壳是 `/` 路由上唯一的 PopScope——同路由多 PopScope 会
// 全部同时回调，一级页不得再注册，一律走 [ShellHandle.onBack]）：
//   1. 抽屉展开 → 收起抽屉
//   2. 当前页勾选态 → 退出勾选（ShellHandle.onBack 返回 true 表示已消费）
//   3. 非默认页 → 切回默认页——默认页是所有返回操作的应用内终点
//      （设置 → 通用 → 默认首页，相册 / SORT / 收藏）
//   4. 默认页 → moveTaskToBack 回桌面
//
// 手势分派（设计定稿）：
//   - 快速整理页：整页右滑 = 呼出抽屉（子目录模式，原先无操作）/
//     切回子目录（相册间模式，原行为）；整页手势由该页自己的
//     GestureDetector 承担，本壳不给它加边缘热区。
//   - 其余四页（相册/收藏/回收站/设置）：左缘 32dp 热区右滑呼出——
//     热区只注册水平 drag 识别器，点击/垂直滚动穿透到下层（arena 裁决），
//     网格从左缘起手的纵向滚动不受影响。系统返回手势占最边缘 ~24dp，
//     从最边缘起手可能触发系统返回，稍内侧起手即归抽屉（ente 同款取舍）。

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart'
    show DefaultHomePage, DrawerAnimSpeed;
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/root_overlay_registry.dart';
import 'package:visort_flutter/shared/widgets/visort_logo.dart';
import 'package:visort_flutter/ui/screens/album_screen.dart';
import 'package:visort_flutter/ui/screens/gallery_screen.dart';
import 'package:visort_flutter/ui/screens/home_screen_android.dart';
import 'package:visort_flutter/ui/screens/settings_screen.dart';

/// Shell ↔ 一级页 的桥接句柄。Shell 每页持有一个实例并注入构造参数；
/// 页在 initState 挂回调、dispose 摘除（[onBack]/[onActivated] 置 null）。
class ShellHandle {
  VoidCallback? _openDrawer;
  VoidCallback? _toggleDrawer;

  /// 抽屉开合动画（0=收起 / 1=展开）。供顶栏侧栏图形 morph 成 ✕
  ///（[DrawerMenuButton]）——morph 严格限定在抽屉开合动画时长内。
  Animation<double>? drawerAnimation;

  /// 呼出抽屉（页面 ☰ 按钮 / 快速整理页子目录模式右滑）。
  void openDrawer() => _openDrawer?.call();

  /// 切换抽屉（展开态点 ✕ = 收起）。[DrawerMenuButton] 用。
  void toggleDrawer() => _toggleDrawer?.call();

  /// 返回键拦截：非 null 时在 moveTaskToBack 前调用；返回 true = 已消费
  /// （如退出勾选态），false = 落到退后台。仅当前页的拦截会被咨询。
  bool Function()? onBack;

  /// 页面被切换为当前页后回调（快速整理页刷新封面/会话横条用）。
  /// 首次激活（页此时尚未 build、回调未挂）不会触发——各页 initState
  /// 的加载流程已覆盖首启场景。
  void Function()? onActivated;
}

class AppShellAndroid extends ConsumerStatefulWidget {
  const AppShellAndroid({super.key});

  @override
  ConsumerState<AppShellAndroid> createState() => _AppShellAndroidState();
}

class _AppShellAndroidState extends ConsumerState<AppShellAndroid>
    with TickerProviderStateMixin {
  // 一级页下标（抽屉菜单顺序；SORT 提到第 2 项——2026-08 用户定稿）
  static const _pageAlbums = 0;
  static const _pageQuickSort = 1;
  static const _pageFavorites = 2;
  static const _pageTrash = 3;
  static const _pageSettings = 4;
  static const _pageCount = 5;

  /// 默认首页（[DefaultHomePage] 配置）对应的一级页下标。
  int _homeIndexOf(DefaultHomePage page) => switch (page) {
        DefaultHomePage.gallery => _pageAlbums,
        DefaultHomePage.sort => _pageQuickSort,
        DefaultHomePage.favorites => _pageFavorites,
      };

  /// 缩放推拉动画参数（参考演示实测观感）：
  /// 抽屉宽 = 屏宽 66%（窄屏夹 250 / 宽屏夹 340）；当前页 scale 0.88、
  /// 垂直居中（centerLeft 锚点，上下各露 6% 背景）、右移 = 抽屉宽、圆角 16。
  static const _pageScale = 0.88;
  static const _pageRadius = 16.0;
  static const _drawerParallax = 0.25; // 抽屉入场反向偏移（视差）

  /// 当前页下标。初始 = 默认首页（设置 → 通用，默认相册；下次启动生效）。
  late int _currentPage;
  late int _visited;
  bool _drawerEverOpened = false; // 抽屉内容惰性构建（logo 入场动画随首开播放）
  Timer? _prewarmTimer;

  late final AnimationController _drawerCtrl;
  late final CurvedAnimation _drawerAnim;
  late final AnimationController _itemCtrl; // 抽屉项错峰入场（独立于面板动画）
  /// 返回切页 crossfade：截旧屏快照 → 立即切页 → 快照层淡出。
  /// 直接 Fade 页面会透出底下近黑 bg（「右半屏突然变深」），且切 index
  /// 瞬间从半透明旧页跳到纯底色有跳变；快照盖顶淡出是真交叉淡化。
  final GlobalKey _pagesKey = GlobalKey();
  ui.Image? _crossfadeSnapshot;
  late final AnimationController _crossfadeCtrl; // 快照透明度 1→0
  Timer? _itemDelay;
  late final List<ShellHandle> _handles;

  @override
  void initState() {
    super.initState();
    // 启动屏 = 配置的默认首页（下次启动生效语义：读的是持久化配置）。
    _currentPage =
        _homeIndexOf(ref.read(configProvider).defaultHomePage);
    _visited = 1 << _currentPage;
    // 启动直入收藏/回收站时补发数据查询：嵌入 Shell 的这两页 initState
    // 不自查（album_screen：数据进入由 Shell 切页驱动），而启动直入未经
    // _selectPage——缺此补发则页面停在占位网格（真机实证：默认首页=
    // 收藏时 6 行空白格）。相册/SORT 页有自己的 initState 加载，无需补。
    if (_currentPage == _pageFavorites || _currentPage == _pageTrash) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final gallery = ref.read(galleryControllerProvider.notifier);
        if (_currentPage == _pageFavorites) {
          gallery.enterFavorites(silent: true);
        } else {
          gallery.enterTrash(silent: true);
        }
      });
    }
    _drawerCtrl = AnimationController(
      vsync: this,
      duration: AppDurations.activity,
      value: 0,
    );
    _drawerAnim = CurvedAnimation(
      parent: _drawerCtrl,
      curve: AppCurves.couiMoveEase,
      reverseCurve: AppCurves.couiOutEase,
    );
    // 项入场不绑面板动画：250ms 面板内每项间隔仅 ~25ms，人眼不可分
    //（用户实测"没做"）。独立 450ms 控制器 + 面板滑入后 100ms 起播，
    // 项在面板就位后延续错峰显现——快速但可感知。
    _itemCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: 0,
    );
    // 返回切页的快照淡出（crossfade 下半程）
    _crossfadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0,
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          // 淡出完成释放快照
          _crossfadeSnapshot?.dispose();
          _crossfadeSnapshot = null;
        }
      });
    _handles = List.generate(_pageCount, (_) => ShellHandle());
    for (final h in _handles) {
      h._openDrawer = _openDrawer;
      h._toggleDrawer = _toggleDrawer;
      h.drawerAnimation = _drawerAnim;
    }
    // 空闲预热快速整理页：冷启动 2.5s 后（首屏相册网格解码已让位）offstage
    // 预构建——IndexedStack 非活动页 build+layout 但不 paint，buckets 查询与
    // 相册 tile 缩略图解码真实发生并进 ImageCache。用户首次切过去时零构建
    // 零解码（真机实测首切明显卡顿的根因就是惰性首建当帧洪泛）。
    // 只预热快速整理：它与 galleryController 数据隔离（自有 channel 查询），
    // 不会打断默认屏；收藏/回收站预热会触发 enter 系数据切换，不预热。
    _prewarmTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && (_visited & (1 << _pageQuickSort)) == 0) {
        setState(() => _visited |= (1 << _pageQuickSort));
      }
    });
  }

  @override
  void dispose() {
    _prewarmTimer?.cancel();
    _itemDelay?.cancel();
    _crossfadeSnapshot?.dispose();
    _crossfadeCtrl.dispose();
    _itemCtrl.dispose();
    _drawerAnim.dispose();
    _drawerCtrl.dispose();
    super.dispose();
  }

  double _drawerWidth(BuildContext ctx) =>
      (MediaQuery.sizeOf(ctx).width * 0.66).clamp(250.0, 340.0);

  void _openDrawer() {
    if (_drawerCtrl.isCompleted) {
      // 已展开：只补播项入场（直接拖开/中断重开场景）
      _startItemEntrance();
      return;
    }
    setState(() => _drawerEverOpened = true);
    // ☰/快速右滑≈迅速滑动语义：恒用黄金值（250ms 上限），与档位无关。
    _drawerCtrl.duration = const Duration(milliseconds: _flingOpenMs);
    _drawerCtrl.forward();
    _startItemEntrance();
  }

  void _closeDrawer() {
    if (_drawerCtrl.isDismissed) return;
    _drawerCtrl.duration = _closeDuration;
    _drawerCtrl.reverse();
    // 收起不播项退场（面板整体滑走），立即归零备下次入场。
    _itemDelay?.cancel();
    _itemCtrl.value = 0;
  }

  /// 项错峰入场：面板滑入大半（100ms）后起播，450ms 内完成全部显现。
  void _startItemEntrance() {
    _itemDelay?.cancel();
    _itemDelay = Timer(const Duration(milliseconds: 100), () {
      if (mounted && _drawerCtrl.status != AnimationStatus.reverse) {
        _itemCtrl.forward(from: 0);
      }
    });
  }

  // 展开态左滑收起（velocity 判定播动画；不做跟手——用户定稿仅按钮/
  // 快速滑动触发）。收起态 handler 为 null 不进 arena，页面右滑呼出
  // 与自身手势不受竞争。
  static const _closeVelocity = -300.0;

  void _onActiveDragEnd(DragEndDetails d) {
    if ((d.primaryVelocity ?? 0) < _closeVelocity) _closeDrawer();
  }

  /// ☰/✕ 按钮切换：展开态（过半）点按 = 收起，否则展开。
  void _toggleDrawer() =>
      _drawerAnim.value > 0.5 ? _closeDrawer() : _openDrawer();

  /// 切换一级页：先收抽屉（关闭动画正好把新页从缩小态推回全屏，遮住切换），
  /// 再切 IndexedStack 下标；收藏/回收站静默重查（silent 保留旧数据直到
  /// 新数据到达，无占位灰格闪烁），最后通知目标页激活。
  void _selectPage(int index) {
    // 挂 root Overlay 的模态浮层（确认小窗等）不感知 IndexedStack 切页
    //（一级页无路由动画），随旧视图一起关——残留的模态 scrim 会吞掉
    // 新页全部点击（F8 真机反馈）。
    dismissTopRootOverlay();
    _closeDrawer();
    if (index == _currentPage) return;
    setState(() {
      _visited |= (1 << index);
      _currentPage = index;
    });
    final gallery = ref.read(galleryControllerProvider.notifier);
    switch (index) {
      case _pageFavorites:
        gallery.enterFavorites(silent: true);
      case _pageTrash:
        gallery.enterTrash(silent: true);
    }
    _handles[index].onActivated?.call();
  }

  /// 返回键四段分发（类注释）：默认首页是所有返回操作的应用内终点——
  /// 非默认页按返回切回默认页（设置 → 通用 → 默认首页，2026-08 起可配，
  /// 原硬编码相册页），仅默认页退桌面（moveTaskToBack）。
  void _onBackInvoked(bool didPop, _) {
    if (didPop) return;
    if (_drawerCtrl.value > 0) {
      _closeDrawer();
      return;
    }
    // 模态浮层（确认小窗等）挡在前台时，返回先关浮层（安卓模态标准行
    // 为）——浮层挂 root Overlay 不感知本 shell 的 IndexedStack 切页
    //（一级页无路由动画），不收口则残留的模态 scrim 吞全屏点击（F8
    // 真机反馈：设置页弹窗返回后首页相册点不动）。
    if (dismissTopRootOverlay()) return;
    final handler = _handles[_currentPage].onBack;
    if (handler != null && handler()) return;
    final homeIndex = _homeIndexOf(ref.read(configProvider).defaultHomePage);
    if (_currentPage != homeIndex) {
      _fadeToPage(homeIndex);
      return;
    }
    const MethodChannel('visort/app').invokeMethod('moveTaskToBack');
  }

  /// 返回切页（回首页）crossfade：截当前屏快照 → 立即切 IndexedStack
  /// 下标（新页在下层正常渲染）→ 快照层从 1 淡出到 0。
  /// 抽屉菜单切页不走此路径——抽屉收起动画已掩护切换；返回是抽屉已收
  /// 下的硬切，才需要过渡。toImage 有帧级 async gap，完成后才截下一帧。
  Future<void> _fadeToPage(int index) async {
    final boundary =
        _pagesKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    ui.Image? snapshot;
    if (boundary != null) {
      try {
        snapshot = await boundary.toImage(
          pixelRatio: View.of(context).devicePixelRatio,
        );
      } catch (_) {
        // 截屏失败退化为直接切换（无过渡），不影响功能
      }
    }
    if (!mounted) {
      snapshot?.dispose();
      return;
    }
    _selectPage(index);
    if (snapshot != null) {
      _crossfadeSnapshot?.dispose();
      _crossfadeSnapshot = snapshot;
      _crossfadeCtrl.forward(from: 0);
    }
  }

  // ── 开合时长（无跟手——用户定稿：仅 ☰ 按钮与快速右滑触发）──
  // 呼出（按钮/快甩）：恒 250ms 黄金值；收起按设置档位（非对称，关快于开）。
  static const _flingOpenMs = 250;
  static const _flingCloseMs = 200;

  /// 收起档位时长（设置「抽屉动画」）：快速 200 / 舒适 240。
  Duration get _closeDuration => Duration(
      milliseconds:
          ref.read(configProvider).drawerAnimSpeed == DrawerAnimSpeed.fast
              ? _flingCloseMs
              : 240);

  @override
  Widget build(BuildContext context) {
    // AnimatedBuilder 的 child 放 IndexedStack：抽屉动画每帧只重建
    // transform 层与抽屉面板，5 个一级页不随动画帧重建。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onBackInvoked,
      child: Material(
        color: AppColors.bg,
        child: AnimatedBuilder(
          animation: _drawerCtrl,
          child: _buildPages(),
          builder: (ctx, pages) {
            final t = _drawerAnim.value;
            final drawerW = _drawerWidth(ctx);
            // 展开态（含开/关动画中）整屏左滑收起；收起态 handler null
            // 不进 arena，页面手势不受竞争。
            final drawerActive = t > 0;
            return GestureDetector(
              onHorizontalDragEnd: drawerActive ? _onActiveDragEnd : null,
              child: Stack(
              children: [
                // ── 退让区底色：恒 surface ──
                // 不随 t lerp：关闭动画后半段若从 surface 渐回 bg（近黑），
                // 条带在被放大的页面盖住前会先经历一段「近黑带」（顶部配
                // 状态栏白字尤刺眼，真机实测「顶部黑底部正常」即此——底部
                // 同样暗只是被手势条视觉掩盖）。t=0 时页面满屏盖住底色，
                // bg 起点本就不可见，lerp 纯多余。
                Positioned.fill(
                  child: const ColoredBox(color: AppColors.surface),
                ),
                // ── 抽屉（底层）：视差滑入；项错峰入场由 _itemCtrl 驱动 ──
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: drawerW,
                  child: Transform.translate(
                    offset: Offset(-_drawerParallax * drawerW * (1 - t), 0),
                    child: Material(
                      color: AppColors.surface,
                      child: _drawerEverOpened
                          ? AnimatedBuilder(
                              animation: _itemCtrl,
                              builder: (ctx, _) => _DrawerContent(
                                current: _currentPage,
                                onSelect: _selectPage,
                                progress: _itemCtrl.value,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                  // ── 当前页（顶层）：缩小 + 右移 + 圆角 ──
                  // 垂直居中用显式数学（topLeft 锚点 + y 平移 (1-s)h/2），
                  // 上下留白严格对称，不依赖 alignment 的 pivot 语义
                  //（真机实测 alignment 版观感偏上，显式平移后实测对称）。
                  Builder(builder: (ctx) {
                    final h = MediaQuery.sizeOf(ctx).height;
                    final s = 1 - (1 - _pageScale) * t;
                    return Transform.translate(
                      offset: Offset(drawerW * t, (1 - s) * h / 2),
                      child: Transform.scale(
                        alignment: Alignment.topLeft,
                        scale: s,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(_pageRadius * t),
                          child: GestureDetector(
                            // 展开态点缩小页 = 收抽屉；收起态 onTap 为 null，
                            // 识别器不进 arena，点击原样穿透给页面。
                            behavior: HitTestBehavior.opaque,
                            onTap: t > 0.5 ? _closeDrawer : null,
                            child: IgnorePointer(
                              // 展开即屏蔽页面交互（t>0），直到关闭动画落回 0；
                              // 阈值 0.5 时前半程仍可点页面按钮，误触观感差。
                              ignoring: t > 0,
                              // 「悬浮」用 scrim 变暗（Material M1-M3 抽屉官方
                              // 方案：behind it darkened by a scrim，Flutter
                              // DrawerController 的 _Scrim 即此）——层级感来自
                              // 亮度对比（抽屉亮/页面退暗），无阴影无模糊。
                              // alpha 0.32 为 Material 官方值。foregroundDecoration
                              // 画在 child 之上（普通 decoration/ColoredBox 是
                              // 垫底背景，会被不透明页面盖住，真机实测无效）。
                              child: Container(
                                foregroundDecoration: BoxDecoration(
                                  color: Colors.black
                                      .withValues(alpha: 0.32 * t),
                                ),
                                child: pages,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                  ),
                  // ── 返回切页 crossfade 快照层（最顶层）──
                  // 旧屏截图淡出；IgnorePointer 常屏蔽（纯视觉层）。
                  if (_crossfadeSnapshot != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: FadeTransition(
                          opacity: ReverseAnimation(_crossfadeCtrl),
                          child: RawImage(
                            image: _crossfadeSnapshot,
                            fit: BoxFit.fill,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 惰性 IndexedStack：未访问槽位空盒，访问过的页常驻保活。
  ///
  /// 每页外包 HeroMode：仅当前活动页的 Hero 参与 flight——IndexedStack 的
  /// 非活动页（含预热的快速整理页）虽不绘制但 render 树在、坐标真实，
  /// 其相册 tile 的 Hero tag（photo_coverId）与活动页目标 tile 的
  /// （photo_第一张id，封面=第一张时相等）冲突，Hero 解析按遍历序后者
  /// 覆盖前者 → 飞行起点取到不可见页的 tile 坐标（右下角起飞，真机实测）。
  Widget _buildPages() {
    return RepaintBoundary(
      key: _pagesKey,
      child: IndexedStack(
        index: _currentPage,
        children: [
          for (var i = 0; i < _pageCount; i++)
            (_visited & (1 << i)) != 0
                ? HeroMode(
                    enabled: i == _currentPage,
                    child: _pageWidget(i),
                  )
                : const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _pageWidget(int index) {
    final Widget page;
    switch (index) {
      case _pageAlbums:
        page = GalleryScreen(shellHandle: _handles[index]);
      case _pageFavorites:
        page = AlbumScreen(
          favoritesOnly: true,
          shellHandle: _handles[index],
        );
      case _pageTrash:
        page = AlbumScreen(trashedOnly: true, shellHandle: _handles[index]);
      case _pageQuickSort:
        // 整页右滑手势由页面自身分派（子目录→抽屉 / 相册间→子目录），
        // 不套左缘热区——整页热区会与模式切换手势打架。
        return HomeScreenAndroid(shellHandle: _handles[index]);
      case _pageSettings:
        page = SettingsScreen(shellHandle: _handles[index]);
      default:
        throw StateError('unreachable page index $index');
    }
    return DrawerSwipeWrapper(onSwipeRight: _openDrawer, child: page);
  }
}

/// 抽屉面板：VISORT 品牌头部 + 5 项菜单（当前项 accent pill 高亮 + 圆点）。
///
/// [progress] = 项入场进度（Shell 的 _itemCtrl，独立于面板开合动画）：
/// 头部与各项依次错峰显现——由左向右滑入（-40dp）+ 淡入，顺序由上到下
///（头部→相册→…→设置）。错峰窗口占入场动画前 50%，每项自身 50%——
/// 在 450ms 内完成全部，快速但可感知（绑 250ms 面板动画时每项间隔仅
/// 25ms，人眼不可分，真机实测"等于没做"）。收起时立即归零不播退场
///（面板整体滑走已足够）。
class _DrawerContent extends ConsumerWidget {
  const _DrawerContent({
    required this.current,
    required this.onSelect,
    required this.progress,
  });

  final int current;
  final ValueChanged<int> onSelect;

  /// 项入场进度（0~1）。命名避开 i18n 的全局 [t] 函数。
  final double progress;

  static const _items = [
    (0, Icons.photo_library_outlined, 'gallery_title'),
    (1, Icons.bolt_outlined, 'quick_sort_title'),
    (2, Icons.favorite_border, 'favorites_title'),
    (3, Icons.delete_outline, 'trash_title'),
    (4, Icons.settings_outlined, 'settings_title'),
  ];

  /// 单元素错峰显现：[i]/[total] 决定错峰起点，easeOutCubic 快起缓收。
  /// 位移 -40dp 由左向右 + 淡入。
  Widget _staggerIn(int i, int total, Widget child) {
    final begin = (i / total) * 0.5;
    final v = Interval(begin, begin + 0.5, curve: Curves.easeOutCubic)
        .transform(progress.clamp(0.0, 1.0));
    return Opacity(
      opacity: v,
      child: Transform.translate(
        offset: Offset(-40 * (1 - v), 0),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 参与错峰的元素数（头部 + 5 项；_items.length 非 const 可表达式，硬编码）
    const total = 6;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌头部：VisortLogo 首实例播放入场动画（惰性构建 → 随首次
          // 开抽屉播放；若快速整理页先被访问，则在该页顶栏播放，闸门一致）。
          _staggerIn(
            0,
            total,
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
              child: VisortLogo(),
            ),
          ),
          _staggerIn(
            0,
            total,
            const SizedBox(height: 18),
          ),
          for (final (index, icon, labelKey) in _items)
            _staggerIn(
              index + 1,
              total,
              _DrawerItem(
                icon: icon,
                label: t(ref, labelKey),
                active: index == current,
                onTap: () => onSelect(index),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final labelColor = active
        ? AppColors.text
        : AppColors.text.withValues(alpha: 0.75);
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: active ? AppColors.accentWithOpacity(0.12) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          // 严格垂直居中：文字行盒含 descent 空隙，Row 盒中心对齐后光学
          // 中心仍偏上（观感成「底部对齐」）。改固定 20px 高盒 + Center +
          // 行高 1.0——行盒=字高，字形光学中心≈盒中心，与 20px 图标共中线。
          // 文字盒不撑满（紧贴图标，间距=14）：用 Spacer 把右侧圆点推右，
          // 否则 Expanded+Center 会把文字居中到行首留白、间距变远。
          children: [
            Icon(icon, size: 20, color: active ? AppColors.accent : labelColor),
            const SizedBox(width: 14),
            SizedBox(
              height: 20,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 14,
                    height: 1.0,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                    color: labelColor,
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (active)
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 收起态整页快速右滑呼出抽屉的包装。无跟手（用户定稿：仅 ☰ 按钮与
/// 快速右滑触发，松手判速度后播完整开合动画）。
/// 点击/长按与垂直滚动不受影响（arena 裁决垂直归滚动、tap 归 InkWell），
/// 纯水平拖动由本层赢。
///
/// 不用左缘窄热区：ColorOS 全面屏的系统返回手势保留左缘 ~24dp，窄热区
/// 的事件被系统吞掉，Flutter 收不到（真机实测完全不触发）。整页右滑
/// 绕开系统保留区。
/// 由 Shell 包裹除快速整理页外的一级页（该页整页水平手势归模式切换，
/// 与本层同型 recognizer 会竞争，不套本包装——其右滑呼出走
/// openDrawer() 播完整动画）。
class DrawerSwipeWrapper extends StatelessWidget {
  const DrawerSwipeWrapper({
    super.key,
    required this.child,
    required this.onSwipeRight,
  });

  final Widget child;
  final VoidCallback onSwipeRight;

  static const _velocityThreshold = 300.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > _velocityThreshold) {
          onSwipeRight();
        }
      },
      child: child,
    );
  }
}

/// 一级页顶栏的抽屉按钮（四页共用）：随抽屉开合在开合动画时长内
/// morph 为 ✕（自绘侧栏图形 ↔ ✕，进度 = Shell 的抽屉动画），展开态
/// 点按收起、收起态点按展开。侧栏图形（面板框 + 左分隔线）与右侧选项
/// 按钮 ViewOptionsToggle 的三线筛选图标分属不同形状族，避免 ☰ 的
/// 同形冲突（2026-08 用户反馈）。
///
/// y 补偿已归零（2026-09 真机像素复测）：原 +1.5 是旧 menu/close 图形
/// 时代下压贴「文字线」的产物——而 CJK 标题字形重心天然低于 AppBar
/// 几何中线 ~1.4dp，等于整组被拉低，与右侧放大镜/选项按钮断档
/// 2.6dp/1.5dp。现四元素统一对齐几何中线（见 gallery_screen 首页
/// 顶栏同批调校）；侧栏框图形自身几何正中，无需 y 补偿。
/// Transform.translate 不动布局盒，点击区不受影响。
class DrawerMenuButton extends StatelessWidget {
  const DrawerMenuButton({super.key, this.handle, this.tooltip});

  final ShellHandle? handle;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final anim = handle?.drawerAnimation;
    return IconButton(
      tooltip: tooltip,
      onPressed: handle?.toggleDrawer,
      icon: Transform.translate(
        // 光学补偿（不动布局盒/点击区）：x −4 = 字形左缘距屏 16dp，
        // 与内容区（bucket 网格 hpad12 + tile 内边 4）左右两缘对齐且与
        // 右侧 ViewOptionsToggle 图标边距对称（真机实测 20dp → 16dp）；
        // y = 0：侧栏框图形几何正中，与 AppBar 几何中线同线（原 +1.5
        // 补偿已删，见类注释）。
        offset: const Offset(-4, 0),
        child: anim != null
            ? AnimatedBuilder(
                animation: anim,
                builder: (ctx, _) => CustomPaint(
                  size: const Size.square(24),
                  painter: _SidebarMorphPainter(anim.value),
                ),
              )
            : const Icon(Icons.view_sidebar_outlined, color: AppColors.text),
      ),
    );
  }
}

/// 抽屉按钮配套 morph：0 = 侧栏图形（圆角面板框 + 左侧竖分隔线），
/// 1 = ✕。面板框绕中心收缩淡出、✕ 两臂自中心生长，在抽屉开合动画
/// 时长内连续形变（接替 AnimatedIcons.menu_close——其收起态 ☰ 与
/// 右侧三线筛选图标同形族冲突）。
class _SidebarMorphPainter extends CustomPainter {
  const _SidebarMorphPainter(this.t);

  /// morph 进度：0 = 侧栏图形（抽屉收起），1 = ✕（抽屉展开）。
  final double t;

  /// ✕ 四臂端点（24 视口，与 _FilterMorphPainter 同几何）。
  static const _x1 = Offset(7.2, 7.2), _x2 = Offset(16.8, 16.8);
  static const _x3 = Offset(16.8, 7.2), _x4 = Offset(7.2, 16.8);
  static const _c = Offset(12, 12);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round;

    // 面板框 + 左分隔线：绕中心收缩（1 → 0.5）并淡出。
    final frameAlpha = (1 - t).clamp(0.0, 1.0);
    if (frameAlpha > 0) {
      stroke.color = AppColors.text.withValues(alpha: frameAlpha);
      final s = 1 - 0.5 * t;
      final rect = Rect.fromCenter(
        center: _c,
        width: 14 * s,
        height: 13 * s,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        stroke,
      );
      final dx = rect.left + rect.width * 0.32;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), stroke);
    }

    // ✕ 两臂：自中心向外生长。
    final xAlpha = t.clamp(0.0, 1.0);
    if (xAlpha > 0) {
      stroke.color = AppColors.text.withValues(alpha: xAlpha);
      Offset grow(Offset p) =>
          Offset(_c.dx + (p.dx - _c.dx) * t, _c.dy + (p.dy - _c.dy) * t);
      canvas.drawLine(grow(_x1), grow(_x2), stroke);
      canvas.drawLine(grow(_x3), grow(_x4), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SidebarMorphPainter oldDelegate) => oldDelegate.t != t;
}
