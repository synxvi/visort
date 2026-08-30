// 安卓抽屉壳层 —— 左侧抽屉 + 一级页容器
//
// `/` 路由（仅安卓）挂本壳。5 个一级页以惰性 IndexedStack 保活：
//   ① 相册（新独立浏览页，默认屏） ② 收藏 ③ 回收站 ④ 快速整理（原首页）
//   ⑤ 设置
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
// 返回键三段分发（本壳是 `/` 路由上唯一的 PopScope——同路由多 PopScope 会
// 全部同时回调，一级页不得再注册，一律走 [ShellHandle.onBack]）：
//   1. 抽屉展开 → 收起抽屉
//   2. 当前页勾选态 → 退出勾选（ShellHandle.onBack 返回 true 表示已消费）
//   3. 否则 → moveTaskToBack 回桌面（原首页行为上移）
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/visort_logo.dart';
import 'package:visort_flutter/ui/screens/album_screen.dart';
import 'package:visort_flutter/ui/screens/gallery_screen.dart';
import 'package:visort_flutter/ui/screens/home_screen_android.dart';
import 'package:visort_flutter/ui/screens/settings_screen.dart';

/// Shell ↔ 一级页 的桥接句柄。Shell 每页持有一个实例并注入构造参数；
/// 页在 initState 挂回调、dispose 摘除（[onBack]/[onActivated] 置 null）。
class ShellHandle {
  VoidCallback? _openDrawer;

  /// 呼出抽屉（页面 ☰ 按钮 / 快速整理页子目录模式右滑）。
  void openDrawer() => _openDrawer?.call();

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
    with SingleTickerProviderStateMixin {
  // 一级页下标（抽屉菜单顺序）
  static const _pageAlbums = 0;
  static const _pageFavorites = 1;
  static const _pageTrash = 2;
  static const _pageQuickSort = 3;
  static const _pageSettings = 4;
  static const _pageCount = 5;

  /// 缩放推拉动画参数（参考演示实测观感）：
  /// 抽屉宽 = 屏宽 66%（窄屏夹 250 / 宽屏夹 340）；当前页 scale 0.88、
  /// 垂直居中（centerLeft 锚点，上下各露 6% 背景）、右移 = 抽屉宽、圆角 16。
  static const _pageScale = 0.88;
  static const _pageRadius = 16.0;
  static const _drawerParallax = 0.25; // 抽屉入场反向偏移（视差）

  int _currentPage = _pageAlbums; // 默认屏 = 相册
  int _visited = 1 << _pageAlbums;
  bool _drawerEverOpened = false; // 抽屉内容惰性构建（logo 入场动画随首开播放）
  Timer? _prewarmTimer;

  late final AnimationController _drawerCtrl;
  late final CurvedAnimation _drawerAnim;
  late final List<ShellHandle> _handles;

  @override
  void initState() {
    super.initState();
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
    _handles = List.generate(_pageCount, (_) => ShellHandle());
    for (final h in _handles) {
      h._openDrawer = _openDrawer;
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
    _drawerAnim.dispose();
    _drawerCtrl.dispose();
    super.dispose();
  }

  double _drawerWidth(BuildContext ctx) =>
      (MediaQuery.sizeOf(ctx).width * 0.66).clamp(250.0, 340.0);

  void _openDrawer() {
    if (_drawerCtrl.isCompleted) return;
    setState(() => _drawerEverOpened = true);
    // 快速呼出入口（☰/快速整理页右滑≈迅速滑动语义）：250ms 上限，
    // 与 fling 路径一致；settleDrawer 缩短过的 duration 在此覆盖。
    _drawerCtrl.duration = const Duration(milliseconds: _flingSettleMs);
    _drawerCtrl.forward();
  }

  void _closeDrawer() {
    if (_drawerCtrl.isDismissed) return;
    _drawerCtrl.duration = AppDurations.activity;
    _drawerCtrl.reverse();
  }

  /// 切换一级页：先收抽屉（关闭动画正好把新页从缩小态推回全屏，遮住切换），
  /// 再切 IndexedStack 下标；收藏/回收站静默重查（silent 保留旧数据直到
  /// 新数据到达，无占位灰格闪烁），最后通知目标页激活。
  void _selectPage(int index) {
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

  /// 返回键三段分发（类注释）。
  void _onBackInvoked(bool didPop, _) {
    if (didPop) return;
    if (_drawerCtrl.value > 0) {
      _closeDrawer();
      return;
    }
    final handler = _handles[_currentPage].onBack;
    if (handler != null && handler()) return;
    const MethodChannel('visort/app').invokeMethod('moveTaskToBack');
  }

  // ── 跟手拖动（推拉手势核心）──
  // 收起态：DrawerSwipeWrapper（四页包装）把水平拖动转发到本层，抽屉跟
  // 手拖出（t 随 dx 增减）；展开态：页面被 IgnorePointer 屏蔽，Shell 顶层
  // GestureDetector 独占（同一套方法，两个入口共享判定逻辑）。
  // 快速整理页不参与跟手（整页水平手势归模式切换，避免 arena 竞争），
  // 其右滑呼出走 openDrawer() 播完整动画。
  static const _flingVelocity = 250.0;
  static const _settleThreshold = 0.35; // 慢速松手的展开阈值（拖出 35% 即开）
  static const _flingSettleMs = 250; // 快甩路径补齐动画的全程上限（ms）

  void _onDrawerDragUpdate(DragUpdateDetails d) {
    final drawerW = _drawerWidth(context);
    // 右滑 dx>0 → t 增大（抽屉展开方向）；clamp 防越界（控制器越界会抛错）。
    _drawerCtrl.value =
        (_drawerCtrl.value + d.delta.dx / drawerW).clamp(0.0, 1.0);
    // 跟手拖出即需抽屉内容（不经 _openDrawer 的直接拖开路径）
    if (!_drawerEverOpened) setState(() => _drawerEverOpened = true);
  }

  void _onDrawerDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v > _flingVelocity) {
      _settleDrawer(true, fling: true);
    } else if (v < -_flingVelocity) {
      _settleDrawer(false, fling: true);
    } else {
      // 慢速松手：拖出超过阈值（或已大半展开）→ 展开，否则收回。
      _settleDrawer(_drawerCtrl.value >= _settleThreshold);
    }
  }

  /// 松手后的补齐动画：时长按剩余行程比例缩短，从半程松手只需约一半
  /// 时间落位，跟手体验不被拖沓的定长动画打断。下限 60ms 防退化。
  /// [fling]：快速甩动路径——全程上限 250ms（迅速滑动完全展开须 ≤250，
  /// 用户实测手感要求）；慢速判定回弹用全量 token 350ms。
  void _settleDrawer(bool open, {bool fling = false}) {
    final remain = open ? 1 - _drawerCtrl.value : _drawerCtrl.value;
    if (remain <= 0) return;
    final full = fling
        ? _flingSettleMs
        : AppDurations.activity.inMilliseconds;
    _drawerCtrl.duration = Duration(
      milliseconds: (full * remain).round().clamp(60, full),
    );
    open ? _drawerCtrl.forward() : _drawerCtrl.reverse();
  }

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
            // 展开态（含开/关动画过程中）整屏跟手；收起态 handler 全 null
            // 不注册识别器，页面自身手势不受竞争。
            final drawerActive = t > 0;
            return GestureDetector(
              onHorizontalDragUpdate: drawerActive ? _onDrawerDragUpdate : null,
              onHorizontalDragEnd: drawerActive ? _onDrawerDragEnd : null,
              child: Stack(
                children: [
                  // ── 退让区底色：bg → surface 随 t 过渡 ──
                  // 展开时缩小页四周露出的底色与抽屉面板统一（surface），
                  // 收起态（t=0）保持 bg（页面满屏盖住，不可见）。
                  Positioned.fill(
                    child: ColoredBox(
                      color: ColorTween(
                        begin: AppColors.bg,
                        end: AppColors.surface,
                      ).evaluate(_drawerAnim) ?? AppColors.bg,
                    ),
                  ),
                  // ── 抽屉（底层）：视差滑入 ──
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
                            ? _DrawerContent(
                                current: _currentPage,
                                onSelect: _selectPage,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  // ── 当前页（顶层）：缩小 + 右移 + 圆角 + 投影 ──
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
                        child: DecoratedBox(
                        // 卡片阴影：轻量单枚（小 blur + 轻微下沉）——大 blur
                        // 双枚会在 surface 底色上糊出宽环带、与页面 bg 形成
                        // 明显分层（真机实测），收敛到只做边缘描离。
                        // alpha 随 t 渐入，收起态无阴影。
                        decoration: BoxDecoration(
                          boxShadow: [
                            if (t > 0)
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35 * t),
                                blurRadius: 14,
                                offset: const Offset(0, 2),
                              ),
                          ],
                        ),
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
                              child: pages,
                            ),
                          ),
                        ),
                      ),
                      ),
                    );
                  },
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
    return IndexedStack(
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
    return DrawerSwipeWrapper(
      onDragUpdate: _onDrawerDragUpdate,
      onDragEnd: _onDrawerDragEnd,
      child: page,
    );
  }
}

/// 抽屉面板：VISORT 品牌头部 + 5 项菜单（当前项 accent pill 高亮 + 圆点）。
class _DrawerContent extends ConsumerWidget {
  const _DrawerContent({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  static const _items = [
    (0, Icons.photo_library_outlined, 'gallery_title'),
    (1, Icons.favorite_border, 'favorites_title'),
    (2, Icons.delete_outline, 'trash_title'),
    (3, Icons.bolt_outlined, 'quick_sort_title'),
    (4, Icons.settings_outlined, 'settings_title'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌头部：VisortLogo 首实例播放入场动画（惰性构建 → 随首次
          // 开抽屉播放；若快速整理页先被访问，则在该页顶栏播放，闸门一致）。
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: VisortLogo(),
          ),
          const SizedBox(height: 18),
          for (final (index, icon, labelKey) in _items)
            _DrawerItem(
              icon: icon,
              label: t(ref, labelKey),
              active: index == current,
              onTap: () => onSelect(index),
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
          children: [
            Icon(icon, size: 20, color: active ? AppColors.accent : labelColor),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 14,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  color: labelColor,
                ),
              ),
            ),
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

/// 收起态整页跟手呼出抽屉的包装。水平拖动实时转发给 Shell（抽屉跟手
/// 拖出/收回），松手由 Shell 按速度/阈值判定展开或回弹。
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
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final Widget child;

  /// 转发 Shell 的跟手更新（t 随 dx 增减）。
  final ValueChanged<DragUpdateDetails> onDragUpdate;

  /// 转发 Shell 的松手判定（速度/阈值 → 展开或回弹）。
  final ValueChanged<DragEndDetails> onDragEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: onDragEnd,
      child: child,
    );
  }
}
