// [ente 移植] 大图浏览页 —— 基于 ente detail_page.dart（PageView + 全屏 + 手势）
//
// 动画行为保持 ente（与 ente 完全一致）：
//   - PageView.builder + FastScrollPhysics(speedFactor:4) 翻页惯性
//   - HeroMode(enabled: index == selectedIndex)：只有当前页启 Hero
//   - 缩放中禁用翻页（shouldDisableScroll → NeverScrollableScrollPhysics）
//   - 全屏切换：顶/底栏/缩略图条 AnimatedOpacity 200ms 淡出（enableFullScreenNotifier）
//   - 删除补位 jumpToPage + 缩略图条手动同步
//   - 上滑详情（onSwipeUp → 详情面板）
//
// UI 组件样式完全采用 visort 主分支（photo_viewer.dart）：
//   - 顶栏：返回 + 文件名(MiddleEllipsisText 中段省略) + 序号，实心黑底
//   - 底栏：info 详情 + 收藏 + 分享 + 删除日期(回收站) + 恢复(回收站) + 删除，实心黑底
//   - 缩略图长条(filmstrip)：底栏上方横滑 ListView，居中放大高亮 + 手写吸附 +
//     与主图双向联动（跟手 jumpToPage / 点按 animateToPage / 主图翻页程序滚动）
//   - 详情面板：Overlay 自有实现(_panelCtrl + _panelExtent，无路由无 DSS)，
//     ColorOS 相册式卡片栈(PhotoDetailsSheet)，图片上推 + 顶栏/缩略图条淡出联动
//
// 适配 visort：
//   - EnteFile → MsImageInfo；操作走 galleryController（MediaStore）
//   - 删除 OCR/QR/社交/全景/编辑/guest/共享/云端（不含视频播放）

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/cache_perf.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/service_policy.dart' show RequestPriority;
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/fs/share_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart' show configProvider, t;
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/shared/widgets/back_glyph_button.dart';
import 'package:visort_flutter/shared/widgets/confirm_sheet.dart';
import 'package:visort_flutter/shared/widgets/glyph_icons.dart';
import 'package:visort_flutter/shared/widgets/middle_ellipsis_text.dart';
import 'package:visort_flutter/shared/widgets/non_modal_menu.dart';
import 'package:visort_flutter/shared/widgets/rename_dialog.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/screens/album_picker_screen.dart';

import 'detail_page_state.dart';
import 'fast_scroll_physics.dart';
import 'filmstrip.dart';
import 'photo_details_sheet.dart';
import 'wallpaper_crop_page.dart';
import 'zoomable_image.dart';

// ─────────────── 栏位常量（主分支 photo_viewer.dart 同款） ───────────────

/// 底栏内容行高（不含安全区 inset）；面板以此垫高，锚定在底栏上方生长。
const double _kBottomChromeHeight = 64.0;

/// 【诊断开关】true = 缩略图条禁用（布局占位保留）——历史定位打开卡顿
/// 元凶用（旧版 ListView 深位 O(N) 定位；第三版锚点式布局后深位 O(视口)，
/// 开关仅留作排查兜底）。
const bool _kFilmstripDiagnosisOff = false;

/// 面板顶部把手拖拽区高度：内容 ListView 与面板拖拽手势分离的窄条区域。
const double _kPanelDragZone = 32.0;

/// 默认展开占比（相对「屏高 − 底栏高」可用区）。
const double _kDetailInitial = 0.5;

/// 图片上推量 = 面板像素高度 × 此系数。0.5 使图片居中主体落在面板上方可见区。
const double _kImagePushFactor = 0.5;

/// 顶/底栏显隐动画时长（曲线分离见 _buildTopBar/_buildBottomOverlay）。
const Duration _kChromeAnimDuration = Duration(milliseconds: 200);

// ─────────────── 底栏缩略图条(filmstrip)：常量在 filmstrip.dart ───────────────
// 行为/布局/动画全部封装在 Filmstrip 组件（锚点式布局 + 变格宽 28/43.5 +
// 聚焦项方形无框（系统相册同款）+ pagePos 锁步），本文件只持数据与联动桥。

/// 缩略图条高度(竖屏)：布局/滑出公式引用（定义在 filmstrip.dart）。
const double _kThumbLineHeight = kFilmstripHeight;

/// 缩略图加载尺寸(px)：与 zoomable_image 加载兜底共用 key（见
/// detail_page_state.kFilmstripThumbLoadSize），单点定义防漂移。
const int _kThumbLoadSize = kFilmstripThumbLoadSize;

/// 主图翻页跟随动画时长（与条程序滚动 kFilmstripSyncDuration 同步）。
const Duration _kThumbSyncDuration = kFilmstripSyncDuration;

class DetailPage extends ConsumerStatefulWidget {
  final List<MsImageInfo> files;
  final int initialIndex;

  /// 翻页回调：网格滚动到当前行（Hero pop 时 cell 在视口才找得到飞行目标）。
  final ValueChanged<int>? onIndexChanged;

  /// 来源视图的网格列数（相册内/收藏/回收站各自独立）：缩略图条按它取
  /// cell 尺寸以命中网格的 ImageCache 档。null = 回退 config 相册内列数。
  final int? gridCols;

  const DetailPage({
    super.key,
    required this.files,
    required this.initialIndex,
    this.onIndexChanged,
    this.gridCols,
  });

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage>
    with TickerProviderStateMixin {
  late final PageController _pageController;
  late final ValueNotifier<int> _selectedIndexNotifier;
  late List<MsImageInfo> _files;

  /// id→index 查表（审查 F19）：_trimDistantViewerCache 每次翻页对每个
  /// 已看 id 线性扫 _files（O(N)×已看数）——千张长翻看 = 每页数十次
  /// 全表扫。惰性建一次；_files 结构性变更（removeAt）时置 null 重建，
  /// copyWith 原位替换 id 不变无需失效。
  Map<String, int>? _indexById;
  Map<String, int> get _idIndex =>
      _indexById ??= {
        for (var i = 0; i < _files.length; i++) _files[i].id: i,
      };

  /// 缩略图条独立数据：删除时条**立即**删除+补位动画（白色框固定、
  /// 下一张滑入），主图在旧数据上滑动（PageView 需要"从被删项滑到
  /// 下一项"的旧列表）——300ms 后主图数据才删。两者同步动画的关键。
  late List<MsImageInfo> _thumbFiles;
  bool _shouldDisableScroll = false;
  bool _swipeLocked = false;
  /// 条→主图 drive 代际：兜底 timer 只清当前 drive 的 flag（P3）。
  int _thumbDriveToken = 0;

  /// 条最近一次「选区主张」（跟手跨档/停稳/点按的汇聚记录）：时间 + 索引。
  /// onPageChanged 的迟到回声守卫用——条跟手 jumpToPage 连射的中间页通知
  /// 可能晚到（实测 settle 后 971ms 到达 idx=旧主张−1），无守卫时
  /// _syncThumbTo 会把条弹回旧页（「甩动后条弹回」根因）。
  DateTime? _stripClaimAt;
  int? _stripClaimIdx;

  void _claimStripIndex(int i) {
    _stripClaimAt = DateTime.now();
    _stripClaimIdx = i;
  }

  final ValueNotifier<bool> enableFullScreenNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isZoomedNotifier = ValueNotifier(false);
  final ValueNotifier<ZoomTransform> zoomTransformNotifier = ValueNotifier(
    ZoomTransform.identity,
  );
  final ValueNotifier<bool> isInSharedCollectionNotifier = ValueNotifier(false);
  final ValueNotifier<String?> showingThumbnailFallbackNotifier = ValueNotifier(
    null,
  );

  // ─────────────── 详情面板(上划信息) ───────────────
  /// 面板占比(0..1,相对屏高):单一驱动源,联动图片上推 / 顶栏淡出 / 缩略图条淡出。
  final ValueNotifier<double> _panelExtent = ValueNotifier(0);
  bool _detailsOpen = false;
  AnimationController? _panelCtrl;

  // ─────────────── 底栏缩略图条 ───────────────
  /// 条居中项双向桥（Filmstrip.center）：外部写 = 程序滚动+聚焦指令
  ///（主图翻页联动/删除同步）；条滚动中组件实时写（跟手联动入口）。
  ValueNotifier<int>? _thumbCenterIndex;

  /// 条联动抑制桥（Filmstrip.frozen）：pop 冻结/删除流程期间置 true，
  /// 条忽略滚动联动与外部指令（渲染照常；删除流程 offset 冻结天然自洽，
  /// 见 filmstrip.dart 文件头）。
  final ValueNotifier<bool> _thumbFrozen = ValueNotifier(false);

  /// 删除流程抑制条滚动：删除期间聚焦位必须固定在视口中心不动——
  /// 主图 animateToPage 触发的 onPageChanged→_syncThumbTo 若滚条，
  /// 激活框会跳到下一格位置（"跳到第二个上面"）。抑制后只更新 center
  /// 高亮，offset 保持——数据左移后下一张自然占据原中心位置。
  bool _suppressThumbScroll = false;

  /// 缩略图条删除动画（系统相册 PhotoPagerIndicator 同构：RecyclerView
  /// ItemAnimator 的位置动画——被删项淡出 + 后续项**平移**补位，而非
  /// AnimatedList 的布局重排式（重排会在移除项占槽期间把高亮项排到
  /// 右边一格 = "跳到第二个又弹回来"）。
  late final AnimationController _thumbDeleteAnim;

  /// 正在删除的条索引（-1 = 无）。
  int _thumbDeleteIndex = -1;

  /// 删除流程进行中（主图动画结束前禁止重复删除/恢复，防数据错乱）。
  bool _deletingInProgress = false;

  /// 删除确认 sheet 显示中（防重入：sheet scrim 吸收栏上点击，再点「删除」
  /// 不响应，无叠加；PopScope 拦截系统返回依赖本标志，须 setState 切换）。
  bool _deleteDialogShowing = false;

  /// 当前 sheet 的外部关闭句柄（PopScope 拦截系统返回时关闭 sheet）。
  VoidCallback? _deleteSheetClose;

  /// 缩略图条驱动主图 animateToPage 期间标记:主图跨多页时中间页 onPageChanged 据此
  /// 忽略,不回弹缩略图条。到达 target 复位,另有超时兜底。
  bool _pagerDrivenByThumb = false;

  /// 同上 flag 的 notifier 形态（Filmstrip.pagerDriven）：条据此在主图
  /// 程序驱动翻页期间放弃锁步跟随（否则 animateToPage 途经的中间页
  /// fraction 会把条拖离已就位的目标项）。写入点与 bool 字段同步。
  final ValueNotifier<bool> _pagerDrivenN = ValueNotifier(false);

  /// 主图翻页连续位置（PageController.page → Filmstrip.pagePos）：条的
  /// 锁步输入——主图用户拖动时条按 fraction 双项插值逐帧跟随（系统
  /// 相册 p() 同构）。integral 值 = 静止，不触发任何联动。
  final ValueNotifier<double> _thumbPagePos = ValueNotifier(0);

  /// [photo_view fork] X 边缘溢出翻页动画进行中：期间忽略重复回调防连翻。
  bool _edgePageAnimating = false;

  /// 翻页滚动中显示页缘黑缝（ScrollNotification 驱动，停稳淡出）。
  bool _pageGapVisible = false;

  /// 顶层双击路由表：pageIndex → 该页 ZoomableImage 的双击处理
  /// （Scrollable ballistic 中 ignorePointer 屏蔽页内 tap，双击必须
  /// 由 PageView 之外捕获再分发到当前页）。
  final Map<int, void Function(Offset globalPosition)> _doubleTapHandlers =
      <int, void Function(Offset)>{};

  /// 顶/底栏/缩略图条/详情面板挂 root Overlay（Hero 飞行层之上）：
  /// Hero flight overlay 插在 Navigator overlay 最上，页面 Stack 内的栏
  /// 会被飞行层盖住（高图飞行满屏时图片冒到栏上、结束又落回栏下的闪烁）。
  /// initState postFrame 注册晚于 HeroController 的 postFrame（didChangeTop
  /// 在 push 事务中先注册）→ entry 插入在 flight overlay 之上（主分支
  /// _barEntry 同款时序）。
  OverlayEntry? _chromeEntry;
  Offset? _lastDoubleTapDown;

  /// 栏让路开关：root Overlay 在所有路由之上（Hero 时序需要），push
  /// 壁纸裁剪页这类全屏子页面时若不抑制，顶/底栏/缩略图条会浮在子页
  /// 之上。裁剪页进入前置 true、返回后复位（_setAsWallpaper）。
  final ValueNotifier<bool> chromeSuppressed = ValueNotifier(false);

  // ─────────────── 底栏 ⋮ 菜单（NonModalMenu 向上展开）───────────────
  // 必须走 rootOverlay 的 NonModalMenu（PopupMenu 走 Navigator overlay，
  // 层级低于挂在 Overlay 之上的底栏/缩略图条，会被盖住）；底栏按钮在屏幕
  // 下缘，用 upward 让菜单向上长。
  final GlobalKey _viewerMenuKey = GlobalKey();
  NonModalMenuController? _viewerMenuCtl;

  /// ⋮ 菜单是否展开中（含收回动画期间，isClosed=false）：PopScope 拦截
  /// 系统返回的依据——展开时系统返回应收起菜单，而非直接退出大图。
  bool get _viewerMenuOpen =>
      _viewerMenuCtl != null && !_viewerMenuCtl!.isClosed;

  /// viewer 无纵向滚动信号（屏障本身拦截手势），恒 false 占位满足 API。
  final ValueNotifier<bool> _viewerMenuScrolling = ValueNotifier(false);

  void initState() {
    super.initState();
    _files = List.of(widget.files);
    _thumbFiles = List.of(widget.files);
    _thumbDeleteAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    // 栏入 root Overlay（时序注释见 _chromeEntry 声明）。延迟 100ms：
    // 条初始带（~24 item × resolve）若与 push 首帧同帧会切碎飞行帧节奏
    //（真机帧数据：busy 轻但帧间隙 133-324ms）；220ms 实验版证明有效但
    // 条出现偏慢，折中 100ms（避开飞行首帧，观感接近立即出现）。
    // postFrame：Overlay.of 需要 mounted context。
    _chromeInsertTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      _chromeEntry = OverlayEntry(builder: _buildChromeOverlay);
      Overlay.of(context).insert(_chromeEntry!);
      // filmstrip 初始定位在组件内（initialScrollOffset 直达 + postFrame
      // 兜底），本页不再干预。

      // pop flight（SDK patch HeroController.didPop 同步启动）的 overlay
      // 插在最上，会盖住栏——flight 插入后同帧重插栏（保持栏在飞行层
      // 之上，消失时机不变）。
      HeroController.onPopFlightStarted = _reinsertChromeAboveFlight;
    });
    _selectedIndexNotifier = ValueNotifier(widget.initialIndex);
    _pageController = PageController(initialPage: widget.initialIndex);
    _thumbPagePos.value = widget.initialIndex.toDouble();
    // 主图翻页位置 → 条锁步输入（page 连续值；用户拖动/程序动画都流经
    // 此处，条侧由 pagerDriven 门控区分）。
    _pageController.addListener(_onPageScroll);
    // 滚动/吸附/聚焦/初始定位全部在 Filmstrip 组件内；本页只持双向桥。
    _thumbCenterIndex = ValueNotifier<int>(widget.initialIndex);
    // 沉浸模式：进入缩放（双击/双指放大）→ 隐藏顶/底栏/缩略图条；
    // 退出缩放 → 恢复进入前的显示状态（手动全屏过则保持全屏）。
    isZoomedNotifier.addListener(_onZoomedForImmersive);
    // 条重预取延迟门：push 首帧 Filmstrip 初始可见带 ~24 item 同帧 build，
    // 每项最多 5 个 precache（large/full/96）与 DetailPage 整树构建、Hero
    // 飞行首帧同帧竞争（真机帧数据：飞行首帧 build 83ms）。300ms 后放行
    // heavy 档并【补发】——初始构建潮发生时门未开，预取被跳过且 build 不会
    // 再来，必须主动补一轮当前中心的 heavy 预取（否则邻页翻页全冷）。
    _heavyStripGateTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _heavyStripPrefetch = true;
      final c = _thumbCenterIndex?.value;
      if (c != null) _prefetchPageNeighbors(c);
    });
  }

  Animation<double>? _routeAnimation;
  bool _routeStatusHooked = false;

  /// PageController → _thumbPagePos 泵（条锁步输入，见字段注释）。
  void _onPageScroll() {
    if (!_pageController.hasClients) return;
    final p = _pageController.page;
    if (p != null) {
      _thumbPagePos.value = p;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // route 动画 status 监听（只挂一次）：dismissed → 移除栏。
    if (!_routeStatusHooked) {
      final anim = ModalRoute.of(context)?.animation;
      if (anim != null) {
        _routeStatusHooked = true;
        _routeAnimation = anim;
        anim.addStatusListener(_onRouteAnimationStatus);
      }
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    // pop(reverse)起点：冻结条/主图联动——甩滑惯性未停就返回时，pop
    // 动画 200ms 内条仍在滚、center 继续变 → onIndexChanged 让网格再次
    // jumpTo（leading）→ Hero 目标 cell 移位 → flight abort/divert =
    // 「吃飞行动画」；网格二次跳动也是「飞行末端闪烁」的来源。冻结后
    // 网格锁死在 flush 定位（album 侧 reverse 同帧冲刷），飞行目标稳定。
    if (status == AnimationStatus.reverse) {
      _popping = true;
      // 条联动一并冻结（Filmstrip.frozen）：滚动/吸附/外部指令全停，
      // 在途自驱动画（fling/settle）在组件内同步截断。
      _thumbFrozen.value = true;
      // ⚠️ pop 冻结须同时锁 PageView 惯性（physics 加 _popping）：
      // 快甩（fling 惯性未停）中返回时 PageView 若继续滚，onPageChanged
      // 被 _popping 拒后网格 cell 与 viewer 页错位，Hero 终点悬空/错位
      //（审查实证 P1，089ea74 冻结了条/网格联动但漏了页面本体）。
      // setState 让 physics 立即生效（首帧即锁，无 1 帧惯性间隙）。
      // ⚠️ physics 只锁【手势】惯性——条甩动跨档驱动的 animateToPage
      //（DrivenScrollActivity）不受 physics 拦截，淡出 200ms 内大图
      // 继续平移 = 真机实证「网格已显示 + 滚动中大图残留」闪烁。同值
      // jumpTo 把一切在途 Activity 替换为 idle hold（值不变零视觉跳变）。
      if (_pageController.hasClients) {
        _pageController.jumpTo(_pageController.position.pixels);
      }
      if (mounted) setState(() {});
    }
    // 返回动画结束：立即移除栏。PageRouteBuilder(opaque:false) 下页面
    // dispose 延迟甚至不触发，栏挂 root Overlay 不随 route 消失，必须
    // 主动 remove（否则返回相册后栏残留覆盖网格）。
    // pop 退场的底栏滑出不用隐式动画（AnimatedSlide）驱动：pop flight
    // 启动时栏 entry 被 remove+insert（重插到飞行层之上，见
    // _reinsertChromeAboveFlight），子树销毁重建会丢隐式动画状态 →
    // 瞬间消失。改由 _buildBottomOverlay 里的 AnimatedBuilder 直接读
    // 路由动画值驱动位移（值驱动对重建免疫）。
    if (status == AnimationStatus.dismissed) {
      _removeChromeEntry();
      _evictViewedViewerCache();
      // live 注册表随 pop 收尾清空：opaque:false 路由 dispose 可能延迟/
      // 不触发，残留条目会被【下一次 push】的飞行 shuttle 误当图源
      //（全程低档不升级，「飞行动画分辨率低」的半个根因；另一半是
      // gallery_file_widget 对 push 禁用 live）。
      kLiveViewerProviders.clear();
      // 收藏视图取消收藏的延后移除在此应用（飞行已完成，cell 可安全消失，
      // 见 gallery_controller._pendingFavRemovals）：postFrame 一拍让 Hero
      // flight overlay 先完成清理，网格淡入补位。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(galleryControllerProvider.notifier)
            .applyPendingFavRemovals();
      });
    }
  }

  /// pop(reverse)进行中：联动全冻结（见 _onRouteAnimationStatus 注释）。
  bool _popping = false;

  /// 条 heavy 预取（large640/full）延迟门（见 initState 注释）。
  bool _heavyStripPrefetch = false;
  Timer? _heavyStripGateTimer;

  /// 栏 entry 延迟插入（见 initState 注释：100ms 折中）。
  Timer? _chromeInsertTimer;

  /// 本次浏览已出全图的 id 集合 + 首次全图时算好的目标宽度。
  /// pop(dismissed)/dispose 时逐个 evict viewer 大图缓存——
  /// evictViewerImageCache 的设计意图（见其 doc），此前 onFullLoaded 是
  /// 空回调、零调用接线：每张 ~9.5MB 三级条目会占满 ImageCache、挤掉网格
  /// 缩略图，表现为「打开关闭几次后滚动变卡」。
  final _viewedFullIds = <String>{};
  int? _viewerTargetWidthPx;

  void _onFullImageLoaded(String id) {
    _viewedFullIds.add(id);
    cachePerfEvent('fullLoaded id=$id n=${_viewedFullIds.length}');
    // 此时 context 处于活跃生命周期（zoomable_image 全图解码完成回调），
    // MediaQuery 读取安全；dispose 阶段不可再读 inherited，故提前缓存。
    _viewerTargetWidthPx ??= computeViewerTargetWidth(
      MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context),
    );
  }

  void _evictViewedViewerCache() {
    final tw = _viewerTargetWidthPx;
    if (tw == null || _viewedFullIds.isEmpty) return;
    cachePerfEvent('evictAll R=pop n=${_viewedFullIds.length} tw=$tw');
    for (final id in _viewedFullIds) {
      evictViewerImageCache(id, tw);
    }
    _viewedFullIds.clear();
  }

  /// 浏览中增量清理：翻页时把已远离当前页（>±3）的 viewer 大图逐出
  /// ImageCache。长时间翻看几十上百张时，4MB/张 的原图条目会持续挤占
  /// 缓存（上限 96-160MB）——网格缩略图被 LRU 逐出，pop 返回后整屏重新
  /// 解码 = 「网格界面加载慢」。窗口内的保留（±3 立即翻回零重解码），
  /// 其余随走随清，pop 时缓存主体仍是网格缩略图。
  void _trimDistantViewerCache(int currentIndex) {
    final tw = _viewerTargetWidthPx;
    // 窗口 14 张（±6 + 当前）与 _prefetchPageNeighbors 的预取窗口 ±5 对齐
    //（留 1 档裕量）：±5 版真机实证 trim 仍按旧 ±3 清——dist4~5 刚解码
    // 入缓存即被驱逐（预取白跑 27ms、页到达重解）= 快甩残余 miss 主因。
    if (tw == null || _viewedFullIds.length <= 14) return;
    final indexById = _idIndex; // F19：O(1) 查表替线性扫
    final distant = <String>[];
    for (final id in _viewedFullIds) {
      final i = indexById[id];
      if (i == null || (i - currentIndex).abs() > 6) distant.add(id);
    }
    for (final id in distant) {
      evictViewerImageCache(id, tw);
      _viewedFullIds.remove(id);
    }
    if (distant.isNotEmpty) {
      cachePerfEvent('trim idx=$currentIndex evicted=${distant.length}');
    }
  }

  void _removeChromeEntry() {
    if (HeroController.onPopFlightStarted == _reinsertChromeAboveFlight) {
      HeroController.onPopFlightStarted = null;
    }
    _chromeEntry?.remove();
    _chromeEntry = null;
  }

  /// pop 退场整组滑出的最大位移（像素）：底栏 + 安全区 + 缩略图条总高，
  /// 保证进度 1 时两栏都完全出屏。底栏与缩略图条共用同一公式，同步滑出。
  static double _popSlideMaxPx(BuildContext context) {
    return _kBottomChromeHeight +
        MediaQuery.viewPaddingOf(context).bottom +
        _kThumbLineHeight;
  }

  /// pop flight overlay 已插入（最上）→ 同帧把栏 entry 重插到它之上。
  void _reinsertChromeAboveFlight() {
    final entry = _chromeEntry;
    if (entry == null || !mounted) return;
    entry.remove();
    Overlay.of(context).insert(entry);
  }

  @override
  void dispose() {
    _heavyStripGateTimer?.cancel();
    _heavyStripGateTimer = null;
    _chromeInsertTimer?.cancel();
    _chromeInsertTimer = null;
    // 菜单浮层挂 rootOverlay（不随本页 dispose），主动收回防残留。
    _viewerMenuCtl?.close();
    _viewerMenuScrolling.dispose();
    // 沉浸残留修复（真机实测）：沉浸态直接 pop 时引擎窗口上仍挂着
    // HIDE_NAVIGATION|IMMERSIVE_STICKY，返回网格后手势条消失。pop 时若仍
    // 沉浸：先复位 notifier（使 200ms 延迟进沉浸的竞态回调失效）再恢复
    // 系统栏。ente 原版 dispose 即有此恢复（setSystemUIOverlayStyle +
    // edgeToEdge），移植时丢失。恢复顺序须在 notifier.dispose() 之前。
    if (enableFullScreenNotifier.value) {
      enableFullScreenNotifier.value = false;
      restoreEdgeToEdgeBars();
    }
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _removeChromeEntry();
    // 飞行层图源注册表兜底清空（补位换图等场景的旧 id 残余一并回收）。
    kLiveViewerProviders.clear();
    // opaque:false 的路由 dispose 可能延迟/不触发，dismissed 分支已 evict；
    // 此处兜底（如直接 remove 路由的场景）。
    _evictViewedViewerCache();
    isZoomedNotifier.removeListener(_onZoomedForImmersive);
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _selectedIndexNotifier.dispose();
    enableFullScreenNotifier.dispose();
    isZoomedNotifier.dispose();
    zoomTransformNotifier.dispose();
    isInSharedCollectionNotifier.dispose();
    showingThumbnailFallbackNotifier.dispose();
    _panelExtent.dispose();
    _panelCtrl?.dispose();
    _thumbCenterIndex?.dispose();
    _thumbFrozen.dispose();
    _thumbDeleteAnim.dispose();
    _thumbPagePos.dispose();
    _pagerDrivenN.dispose();
    _flingLimit.dispose();
    super.dispose();
  }

  bool? _fullscreenBeforeZoom;

  /// 沉浸模式联动（isZoomedNotifier → enableFullScreenNotifier）。
  void _onZoomedForImmersive() {
    if (!mounted) return;
    if (isZoomedNotifier.value) {
      _fullscreenBeforeZoom ??= enableFullScreenNotifier.value;
      if (!enableFullScreenNotifier.value) {
        enableFullScreenNotifier.value = true;
      }
    } else {
      final restore = _fullscreenBeforeZoom ?? false;
      _fullscreenBeforeZoom = null;
      if (enableFullScreenNotifier.value != restore) {
        enableFullScreenNotifier.value = restore;
      }
    }
  }

  MsImageInfo? get _selectedFile => _fileAt(_selectedIndexNotifier.value);

  MsImageInfo? _fileAt(int index) {
    if (index < 0 || index >= _files.length) return null;
    return _files[index];
  }

  /// 栏 OverlayEntry 内容（与原 Stack 顺序一致：filmstrip < 顶栏 < 底栏 <
  /// 面板；面板 z 序最高，展开时覆盖缩略图条区域）。Material 提供栏组件
  /// 的默认文本/ink 语境（原在 Scaffold 内）。
  Widget _buildChromeOverlay(BuildContext _) {
    // 抑制时整体透明 + 不可点（保持 subtree 状态——filmstrip 滚动位置等
    // 不因 entry 重建丢失）。
    return ValueListenableBuilder<bool>(
      valueListenable: chromeSuppressed,
      builder: (_, suppressed, child) => IgnorePointer(
        ignoring: suppressed,
        child: Opacity(opacity: suppressed ? 0.0 : 1.0, child: child!),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // 底栏缩略图条（filmstrip）
            _buildThumbLine(),
            // 详情面板：z 序在底栏**后面**——滑入/滑出动画经过底栏区域时
            // 被底栏遮住（"从底栏后面弹出/收回"），而非覆盖底栏。
            if (_detailsOpen && _panelCtrl != null)
              _buildPanelOverlay(_selectedFile),
            // 顶栏
            _buildTopBar(),
            // 底栏（z 序最上）
            _buildBottomOverlay(),
          ],
        ),
      ),
    );
  }

  /// 页面 build 后的栏刷新调度：build 阶段直接 markNeedsBuild 会触发
  /// "setState() called during build"（OverlayEntry 非页面祖先——翻页
  /// rebuild 时 _chromeEntry 已存在 → 红屏）。postFrame 标脏，去重。
  bool _chromeRefreshScheduled = false;

  void _scheduleChromeRefresh() {
    if (_chromeRefreshScheduled) return;
    _chromeRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chromeRefreshScheduled = false;
      _chromeEntry?.markNeedsBuild();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 页面 setState（栏相关字段：_detailsOpen/_panelCtrl/_files 等）顺带
    // 刷新栏 entry（OverlayEntry 不随页面 rebuild；ValueListenable 部分
    // 由内嵌 ValueListenableBuilder 自行响应）。
    _scheduleChromeRefresh();
    if (_files.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.maybePop(context);
      });
      return const Scaffold(backgroundColor: Colors.black);
    }
    return InheritedDetailPageState(
      enableFullScreenNotifier: enableFullScreenNotifier,
      isInSharedCollectionNotifier: isInSharedCollectionNotifier,
      showingThumbnailFallbackNotifier: showingThumbnailFallbackNotifier,
      isZoomedNotifier: isZoomedNotifier,
      selectedIndexNotifier: _selectedIndexNotifier,
      doubleTapHandlers: _doubleTapHandlers,
      zoomTransformNotifier: zoomTransformNotifier,
      // 面板打开时点击图片区 → 收面板（而非切换全屏）。
      onImageTap: _detailsOpen ? _animateClose : null,
      child: PopScope(
        // 面板展开/删除 sheet 显示/⋮ 菜单展开时拦截系统返回:先收回面板/关
        // sheet/收起菜单,而非退出大图;都关闭时正常返回相册。
        canPop: !_detailsOpen && !_deleteDialogShowing && !_viewerMenuOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // ⋮ 菜单优先:展开时系统返回先收起菜单(再按一次才退出大图)。
          if (_viewerMenuOpen) {
            _viewerMenuCtl?.close();
            return;
          }
          if (_deleteDialogShowing) {
            _deleteSheetClose?.call();
            return;
          }
          if (_detailsOpen) _animateClose();
        },
        child: Scaffold(
          extendBodyBehindAppBar: true,
          resizeToAvoidBottomInset: false,
          backgroundColor: Colors.black,
          body: Center(
            child: Stack(
              children: [
                // 图片随面板上推（唯一驱动源 _panelExtent）。
                ValueListenableBuilder<double>(
                  valueListenable: _panelExtent,
                  builder: (_, extent, pageView) {
                    final mq = MediaQuery.of(context);
                    final availH =
                        mq.size.height -
                        (_kBottomChromeHeight + mq.viewPadding.bottom);
                    // clamp ≥ 0:杜绝关闭回弹时图片「过冲到正常位置以下」的闪烁。
                    final pushPx = (extent * availH * _kImagePushFactor).clamp(
                      0.0,
                      availH,
                    );
                    return Transform.translate(
                      offset: Offset(0, -pushPx),
                      child: pageView,
                    );
                  },
                  child: _buildPageView(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageView() {
    return GestureDetector(
      // [顶层双击] Scrollable ballistic/拖动中 ignorePointer 屏蔽页内 tap
      // （翻页未停稳双击失灵的根因）——双击在 PageView 之上捕获，按当前
      // 页索引分发到该页 ZoomableImage（→ PhotoViewCore.doubleTapZoom）。
      // translucent：PageView ignorePointer 期间 child hit 失败，deferToChild
      // 会让本层 hit 一并失败（双击收不到）；translucent 自身参与 hit 且
      // 透传，滚动中 tap 仍可达。只注册 DoubleTap recognizer，不影响
      // drag/scale；与页内 onTap 共存的单击 300ms 延迟与此前一致。
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (d) => _lastDoubleTapDown = d.globalPosition,
      onDoubleTap: () {
        final down = _lastDoubleTapDown;
        if (down == null) return;
        // 快甩惯性未停稳时双击：立即跳停到当前页（上一页瞬间出视口，
        // 消除"放大的同时上一页未完全消失"），放大动画在满屏单页上进行。
        final ctrl = _pageController;
        if (ctrl.hasClients && ctrl.position.isScrollingNotifier.value) {
          ctrl.jumpToPage(_selectedIndexNotifier.value);
        }
        _doubleTapHandlers[_selectedIndexNotifier.value]?.call(down);
      },
      child: NotificationListener<ScrollNotification>(
        // 翻页间隙：滚动中显示页缘黑缝（相邻两页交界 8px 黑，区分两张图），
        // 停稳后淡出——静止时图片满宽贴屏（无永久 padding，Hero 终点矩形
        // 与网格 cell 严格一致）。depth==0：只认 PageView 自身（内部无可滚
        // 子组件，防御性过滤）。
        onNotification: (n) {
          if (n.depth != 0) return false;
          // 删除补位的程序滚动（animateToPage/jumpToPage）不显示页缘黑缝：
          // 黑缝为用户翻页区分相邻两图而设，程序滚动的 Start/Update/End
          // 序列会在动画结束时以 150ms 淡出一道黑边 = 切换结束时图片
          // 两侧轻微闪烁（真机实证）。
          if (_deletingInProgress) return false;
          final scrolling = n is! ScrollEndNotification;
          if (scrolling != _pageGapVisible) {
            setState(() => _pageGapVisible = scrolling);
          }
          return false;
        },
        child: PageView.builder(
          clipBehavior: Clip.none,
          // 相邻页预 build（±1 页）：ZoomableImage 的 didChangeDependencies
          // 自然完成预解码，快速连翻不再有糊图期（对标系统相册翻页即现）。
          allowImplicitScrolling: true,
          itemBuilder: (context, index) {
            final file = _files[index];
            final fileContent = ZoomableImage(
              file,
              tagPrefix: 'photo',
              // 页索引：顶层双击路由（Scrollable ballistic 中 ignorePointer
              // 屏蔽页内 tap → 双击由 detail_page 顶层捕获后按索引分发）。
              pageIndex: index,
              // 与来源网格同列数：cell 缩略图尺寸一致（ImageCache key 命中）。
              gridCols: widget.gridCols ??
                  ref.watch(configProvider).photoGridColumns,
              shouldDisableScroll: (value) {
                if (_shouldDisableScroll != value) {
                  setState(() => _shouldDisableScroll = value);
                }
              },
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              onSwipeUp: () => _showDetails(file),
              // 面板打开时下滑 → 收面板；否则默认返回。
              onSwipeDown: _detailsOpen ? _animateClose : null,
              // 放大后平移到 X 边缘继续拖 → 翻页（photo_view fork onEdgeX）。
              onEdgeX: _handleEdgePage,
              onFullLoaded: _onFullImageLoaded,
            );
            final pageContent = GestureDetector(
              onTap: () {
                InheritedDetailPageState.of(context).toggleFullScreenByUser();
              },
              child: fileContent,
            );
            // 页缘黑缝遮罩：仅滚动中可见（AnimatedOpacity 淡入淡出）。
            // IgnorePointer 不挡下层手势。
            final page = Stack(
              children: [
                Positioned.fill(child: pageContent),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _pageGapVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: const _PageGapEdges(),
                    ),
                  ),
                ),
              ],
            );
            return ValueListenableBuilder(
              // 按 file.id 建 key：删除补位时列表移位，element 跟着【图】走
              // 而非"同 index 复用换血"——换图场景（didUpdateWidget 换
              // photo + childSize/scale 竞态）整体消失，补位页的缩放/加载
              // 链全程连续（真机实证方→扁/竖→扁补位均无大小跳变）。
              key: ValueKey('vp_${file.id}'),
              valueListenable: _selectedIndexNotifier,
              builder: (context, selectedIndex, _) =>
                  HeroMode(enabled: index == selectedIndex, child: page),
            );
          },
          onPageChanged: (index) {
            if (_popping) return; // pop 冻结：主图不再换页（源端 Hero 稳定）
            if (_pagerDrivenByThumb) {
              // 缩略图条驱动主图:跨多页时中间页忽略,不回弹缩略图条;
              // 到达 target 复位 flag。
              if (index == _selectedIndexNotifier.value) {
                _pagerDrivenByThumb = false;
                _pagerDrivenN.value = false;
              }
              return;
            }
            if (_selectedIndexNotifier.value == index) {
              // 文件数可能已变但索引未变（删除补位/缩略图跟手 jumpToPage 触发）。
              // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
              _selectedIndexNotifier.notifyListeners();
              // ⚠️ 跟手路径（filmstrip 快甩 jumpToPage）也须清理远端缓存：
              // 快甩扫过 20+ 页时每页 full(4.4MB)都记入 _viewedFullIds，若
              // 不 trim 则浏览期缓存撑爆、网格缩略图被逐（审查实证 P1——
              // _trimDistantViewerCache 注释声明的场景原样发生）。
              _trimDistantViewerCache(index);
              return; // 跟手场景 filmstrip 已就位，不程序回滚
            }
            // 迟到回声守卫：条停稳/跟手主张后 800ms 内到达、与主张只差 1 格
            // 的 onPageChanged = 跟手 jumpToPage 连射的中间页通知迟到（实测
            // settle 后 971ms 到达 idx=主张−1）——sel/条均已对齐主张，放行会
            // 经 _syncThumbTo 把条弹回旧页（「甩动后条弹回」根因）。吞掉；
            // 主图位置由跟手最后一次 jumpToPage（=主张页）保证一致。
            final claimAt = _stripClaimAt;
            final claimIdx = _stripClaimIdx;
            if (claimAt != null &&
                claimIdx != null &&
                DateTime.now().difference(claimAt) <
                    const Duration(milliseconds: 800) &&
                (index - claimIdx).abs() <= 1) {
              return;
            }
            _selectedIndexNotifier.value = index;
            cachePerfEvent('page idx=$index id=${_files[index].id}');
            widget.onIndexChanged?.call(index);
            _syncThumbTo(index);
            _trimDistantViewerCache(index);
            _prefetchPageNeighbors(index);
          },
          physics: _shouldDisableScroll || _swipeLocked || _popping
              ? const NeverScrollableScrollPhysics()
              : const FastScrollPhysics(speedFactor: 4.0),
          controller: _pageController,
          itemCount: _files.length,
        ),
      ),
    );
  }

  /// [photo_view fork] 放大后 X 边缘溢出 → 翻页（dir>0 右拖→上一张，<0 左拖→下一张）。
  void _handleEdgePage(int dir) {
    if (_detailsOpen || _edgePageAnimating) return;
    if (!_pageController.hasClients) return;
    _edgePageAnimating = true;
    final future = dir < 0
        ? _pageController.nextPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
        : _pageController.previousPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
    unawaited(
      future.whenComplete(() {
        _edgePageAnimating = false;
        // 旧页的放大态翻页后残留（新页 postFrame 也会复位，这里兜底
        // 翻页动画期间 PageView 已恢复可滚）。
        if (_shouldDisableScroll) {
          setState(() => _shouldDisableScroll = false);
        }
      }),
    );
  }

  // （F22 删除空壳 _preloadFiles）邻页图片由 ImageCache +
  // allowImplicitScrolling 预渲染处理，无需显式预加载（ente 有服务端
  // 预取；visort 本地 MediaStore 读取快，跳过）。

  // ─────────────── 顶栏（主分支 _TopChromeBar 样式） ───────────────

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<int>(
        valueListenable: _selectedIndexNotifier,
        builder: (context, selectedIndex, _) {
          final file = _fileAt(selectedIndex);
          if (file == null) return const SizedBox.shrink();
          return ValueListenableBuilder<bool>(
            valueListenable: enableFullScreenNotifier,
            builder: (context, isFullScreen, _) {
              // 面板占比联动顶栏淡出(沉浸)。
              return ValueListenableBuilder<double>(
                valueListenable: _panelExtent,
                builder: (_, extent, __) {
                  final topVis = (1 - extent / _kDetailInitial).clamp(0.0, 1.0);
                  return IgnorePointer(
                    ignoring: isFullScreen || topVis < 0.5,
                    // 曲线分离（aves entry_viewer_stack 同思路）：顶栏上滑
                    // 滑入/出（easeOutCubic）+ 淡入淡出（easeOutQuad），
                    // 比纯 fade 有方向感；底栏对应用 scale（防位移感）。
                    child: AnimatedSlide(
                      offset: isFullScreen ? const Offset(0, -1) : Offset.zero,
                      duration: _kChromeAnimDuration,
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        // 全屏切换 200ms 淡出（ente）；extent 联动同步系数（topVis）。
                        opacity: isFullScreen ? 0 : 1,
                        duration: _kChromeAnimDuration,
                        curve: Curves.easeOutQuad,
                        child: Opacity(
                          opacity: topVis,
                          child: Container(
                            color: Colors.black,
                            child: Padding(
                              padding: EdgeInsets.only(
                                top: MediaQuery.viewPaddingOf(context).top,
                              ),
                              child: SizedBox(
                                height: 56,
                                child: Row(
                                  children: [
                                    BackGlyphButton(
                                      // 与相册页 AppBar 返回箭头对齐（主分支同款 padding）。
                                      // 自绘细线箭头：与抽屉侧栏 / 选项三线按钮同形制。
                                      tooltip: t(ref, 'back'),
                                      onPressed: () =>
                                          Navigator.maybePop(context),
                                    ),
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 180,
                                          ),
                                          child: MiddleEllipsisText(
                                            file.name,
                                            style: const TextStyle(
                                              color: AppColors.text,
                                              fontSize: 13,
                                              fontFamily: 'Space Mono',
                                              height: 1.2,
                                              fontFamilyFallback:
                                                  AppFonts.cjkFallback,
                                            ),
                                            padding: const EdgeInsets.only(
                                              right: 12,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(right: 16),
                                      child: Text(
                                        '${selectedIndex + 1} / ${_files.length}',
                                        style: TextStyle(
                                          color: AppColors.text.withValues(
                                            alpha: 0.7,
                                          ),
                                          fontSize: 13,
                                          fontFamily: 'Space Mono',
                                          height: 1.2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  // ─────────────── 底栏（主分支 _BottomChromeBar 样式） ───────────────

  Widget _buildBottomOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: ValueListenableBuilder<int>(
        valueListenable: _selectedIndexNotifier,
        builder: (context, selectedIndex, _) {
          final file = _fileAt(selectedIndex);
          if (file == null) return const SizedBox.shrink();
          // pop 退场滑出（与路由 reverse 同步）：读路由动画【值】直接驱动
          // 位移而非隐式动画——pop flight 启动时栏 entry 被 remove+insert
          // 重插（_reinsertChromeAboveFlight），隐式动画状态会随子树重建
          // 丢失（实测瞬间消失），值驱动重建后读当前进度，连续无跳变。
          // 位移用【统一像素】（整组总高度 × 进度）而非各自身高度的
          // fraction——底栏与缩略图条高度不同，fraction 位移会拉开空隙。
          // _buildThumbLine 同公式，两栏作为整体同步滑出。
          return AnimatedBuilder(
            animation: _routeAnimation ?? kAlwaysCompleteAnimation,
            builder: (context, child) {
              final anim = _routeAnimation;
              final popping =
                  anim != null && anim.status == AnimationStatus.reverse;
              final popSlidePx =
                  (popping ? 1.0 - anim.value : 0.0) * _popSlideMaxPx(context);
              return Transform.translate(
                offset: Offset(0, popSlidePx),
                child: child,
              );
            },
            child: ValueListenableBuilder<bool>(
              valueListenable: enableFullScreenNotifier,
              builder: (context, isFullScreen, _) {
                final hidden = isFullScreen;
                return IgnorePointer(
                  ignoring: hidden,
                  // 底栏向下滑出（与顶栏上滑对称，easeOutCubic）：
                  // 曾试 scale 0.96 缩小淡出，缩小后的黑色小矩形观感差，
                  // 滑出屏外更干净。
                  child: AnimatedSlide(
                    offset: hidden ? const Offset(0, 1) : Offset.zero,
                    duration: _kChromeAnimDuration,
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: hidden ? 0 : 1,
                      duration: _kChromeAnimDuration,
                      curve: Curves.easeOutQuad,
                      child: Container(
                        color: Colors.black,
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        child: SizedBox(
                          height: _kBottomChromeHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 底栏图标全换自绘 Glyph 形制（见 glyph_icons.dart
                              // 文件头规范）：stock Material 满格 24 包络与
                              // 顶栏细线家族风格断档。布局盒（IconButton 48）
                              // 与间距不动，只换图形。
                              IconButton(
                                // strokeWidth 1.7：底栏黑底高对比，1.9
                                // 观感偏重（2026-09 真机反馈）
                                icon: const InfoGlyphIcon(strokeWidth: 1.7),
                                tooltip: t(ref, 'photo_details'),
                                onPressed: _toggleDetails,
                              ),
                              // 回收站视图无收藏（系统相册式，网格批量栏同规则）
                              if (!file.isTrashed)
                                IconButton(
                                  icon: HeartGlyphIcon(
                                    filled: file.isFavorite,
                                    color: file.isFavorite
                                        ? AppColors.danger
                                        : AppColors.text,
                                  ),
                                  tooltip: t(
                                    ref,
                                    file.isFavorite
                                        ? 'action_unfavorite'
                                        : 'action_favorite',
                                  ),
                                  onPressed: _toggleFavoriteCurrent,
                                ),
                              // 分享（收藏右邻，Aves 同款）：系统分享面板
                              //（ACTION_SEND，MediaStore URI 授权接收方读）。
                              // 回收站项不显示（与收藏/⋮ 菜单同规则——
                              // trashed URI 对接收方不可靠）。
                              if (!file.isTrashed)
                                IconButton(
                                  icon: const ShareGlyphIcon(strokeWidth: 1.7),
                                  tooltip: t(ref, 'share_photo'),
                                  onPressed: _shareCurrent,
                                ),
                              // 垃圾桶挪到收藏右边（原先在最右；腾出原位放 ⋮）
                              IconButton(
                                icon: const TrashGlyphIcon(
                                  color: AppColors.danger,
                                ),
                                tooltip: t(ref, 'delete_photo'),
                                onPressed: _deleteCurrent,
                              ),
                              const Spacer(),
                              // 回收站项：恢复按钮左侧显示删除日期
                              if (file.isTrashed && file.dateTrashedMs > 0)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: _TrashDateLabel(
                                    ms: file.dateTrashedMs,
                                  ),
                                ),
                              // 回收站恢复按钮：跑道形撤回图标（删除
                              // toast 同款图形，2026-09 用户定稿）。size 24
                              //（跑道含箭头包络 ~15 > 其他底栏图形 13——
                              // 28 画布实测显大一圈，缩档后 ≈12.9 同档）。
                              if (file.isTrashed)
                                IconButton(
                                  icon: const UndoTrackGlyphIcon(size: 24),
                                  tooltip: t(ref, 'action_restore'),
                                  onPressed: _restoreCurrent,
                                ),
                              // 原删除位 ⋮ 选项菜单：对当前图 复制/移动/重命名。
                              // 回收站项这三项均无意义，不显示（与收藏按钮同规则）。
                              // 走 rootOverlay NonModalMenu（upward 向上展开）——
                              // PopupMenu 挂 Navigator overlay，层级低于挂在
                              // Overlay 之上的底栏/缩略图条，会被盖住。
                              if (!file.isTrashed)
                                IconButton(
                                  key: _viewerMenuKey,
                                  icon: const MoreVertGlyphIcon(),
                                  tooltip: t(ref, 'gallery_manage'),
                                  onPressed: _showViewerMenu,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 回收站项底栏的删除日期标签：由外层 _BottomChromeBar 使用。
  /// 实现见文件底部顶层类 _TrashDateLabel（ConsumerWidget）。

  // ─────────────── 底栏缩略图条（Filmstrip 组件，见 filmstrip.dart） ───────────────

  Widget _buildThumbLine() {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Positioned(
      bottom: _kBottomChromeHeight + bottomInset,
      left: 0,
      right: 0,
      height: _kThumbLineHeight,
      // pop 退场滑出（值驱动，与底栏同步——机制与原因见
      // _buildBottomOverlay 内注释）：位移用与底栏相同的统一像素公式
      // （_popSlideMaxPx），两栏作为整体同步滑出、无空隙。
      child: AnimatedBuilder(
        animation: _routeAnimation ?? kAlwaysCompleteAnimation,
        builder: (context, child) {
          final anim = _routeAnimation;
          final popping =
              anim != null && anim.status == AnimationStatus.reverse;
          final popSlidePx =
              (popping ? 1.0 - anim.value : 0.0) * _popSlideMaxPx(context);
          return Transform.translate(
            offset: Offset(0, popSlidePx),
            child: child,
          );
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: enableFullScreenNotifier,
          builder: (_, isFullScreen, __) {
            return ValueListenableBuilder<double>(
              valueListenable: _panelExtent,
              builder: (_, extent, ___) {
                final thumbVis = (1 - extent / _kDetailInitial).clamp(0.0, 1.0);
                // 面板联动：面板展开时条下沉 + 淡出（原逻辑保留）。
                final dy = (1 - thumbVis) * _kThumbLineHeight;
                // 沉浸显隐：AnimatedSlide 与底栏同 duration/curve，整组
                // 「一起长出来 / 收回去」。条位移 = 底栏高 + inset + 条高
                // （多滑一个条高）：滑动中条的下部藏进底栏（z 序在其上）
                // 后面，终态完全出屏；两栏同进度 → 条下缘全程贴着底栏上缘
                // 缝隙插入底栏区域被盖住，视觉无缝。
                // （原 isFullScreen 布尔直算 vis：退出沉浸时条瞬现在终点、
                // 底栏还在滑 → 白底图上两栏之间露缝，真机实证。）
                return AnimatedSlide(
                  offset: isFullScreen
                      ? Offset(
                          0,
                          (_kBottomChromeHeight + bottomInset +
                                  _kThumbLineHeight) /
                              _kThumbLineHeight,
                        )
                      : Offset.zero,
                  duration: _kChromeAnimDuration,
                  curve: Curves.easeOutCubic,
                  child: Transform.translate(
                    offset: Offset(0, dy),
                    child: Opacity(
                      opacity: thumbVis,
                      child: IgnorePointer(
                        ignoring: isFullScreen || thumbVis < 0.5,
                        // 【诊断开关】临时禁用条（保持布局占位）定位打开卡顿
                        // 元凶：timeline 实证打开窗口存在 394ms 帧（3907
                        // BUILD + 5711 putIfAbsent，半数 BUILD 在 LAYOUT 期）
                        // 且 _scrollToCellRow 零调用（网格无关）。若禁用条后
                        // 停摆消失 → 条实锤。
                        child: _kFilmstripDiagnosisOff
                            ? const SizedBox.expand()
                            : Filmstrip(
                                itemCount: _thumbFiles.length,
                                initialIndex: widget.initialIndex,
                                center: _thumbCenterIndex!,
                                frozen: _thumbFrozen,
                                thumbnail: (i) => buildThumbnailProvider(
                                  imageRefFromMediaStoreId(_thumbFiles[i].id),
                                  size: _kThumbLoadSize,
                                  squareCrop: true, // 方形 cover item
                                ),
                                onCenterChanged: _onThumbCenterChanged,
                                onSettled: _onThumbSettled,
                                onTap: _onThumbSettled,
                                onItemBuild: _prefetchStripItem,
                                deleteAnim: _thumbDeleteAnim,
                                deleteIndex: _thumbDeleteIndex,
                                pagePos: _thumbPagePos,
                                pagerDriven: _pagerDrivenN,
                                flingLimit: _flingLimit,
                              ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// 条滚动跨档（Filmstrip.onCenterChanged，实时）：sel/大图逐档硬跳 +
  /// 预取窗口推进。2026-09-07 smali 级考古修正（此前「条甩动不跳大图、
  /// 停稳一次跳转」系误读）：系统相册 ds70.F 尾部直接 PhotoPagerSection
  /// .w0(pos, smooth=false) → RecyclerView.scrollToPosition——条甩动期间
  /// 【每帧硬跳】大图（100-136 档/s，无任何时间窗合并），跳到即清晰靠的
  /// 是并行加载滑窗的距离分级预解码（见 _prefetchPageNeighbors）。visort
  /// 同构：跨档即 jumpToPage（60ms 节流已删——节流把切换拖慢到 16 页/s，
  /// 即「系统切换比我们快很多」的直接原因；糊的根因是掠过页显示档落
  /// strip96，与跳页频率无关）。pop/删除冻结由 frozen 桥在组件内挡。
  void _onThumbCenterChanged(int i) {
    _claimStripIndex(i);
    if (i == _selectedIndexNotifier.value) return;
    _selectedIndexNotifier.value = i;
    widget.onIndexChanged?.call(i);
    if (_pageController.hasClients) {
      _pageController.jumpToPage(i);
    }
    _pumpFlingBackpressure();
    _prefetchPageNeighbors(i);
  }

  // ─── fling 背压（系统相册「多轮快甩过图反而变慢」的同构机制） ───
  /// 跨档时间窗（1s 内跨档数 = 过图率）：持续快甩（>25 档/s 连续）时逐档
  /// 调低条 fling 钳制（2000→最低 1000，下一轮甩动生效）——过图率降半，
  /// dist3 预取领先量 65→130ms >> run 27ms，fling 段命中推向 100%。停稳
  /// （_onThumbSettled）清窗恢复全速。轻扫/慢速不达阈值不受影响。
  static const int _kBackpressureCrossPerSec = 25;
  static const double _kFlingLimitMin = 1000.0;
  final ValueNotifier<double> _flingLimit = ValueNotifier(2000.0);
  final List<DateTime> _crossTimes = <DateTime>[];

  void _pumpFlingBackpressure() {
    final now = DateTime.now();
    _crossTimes.add(now);
    while (_crossTimes.isNotEmpty &&
        now.difference(_crossTimes.first) > const Duration(seconds: 1)) {
      _crossTimes.removeAt(0);
    }
    if (_crossTimes.length > _kBackpressureCrossPerSec &&
        _flingLimit.value > _kFlingLimitMin) {
      _flingLimit.value =
          (_flingLimit.value - 250).clamp(_kFlingLimitMin, 2000.0);
    }
  }

  /// 条停稳吸附/点按单项（Filmstrip.onSettled/onTap，组件已完成吸附
  /// 聚焦）：主图跟随动画。逐档硬跳下 center 多已同步（同值早退），
  /// 此处收口吸附微调（_underCenter 最近项 ≠ 最后一档时 animateToPage
  /// 对齐）。停稳即解除背压恢复全速；并补一发 ±5 宽窗预取——下一轮
  /// 起跑前 5 档已就绪，消起跑冷启动 miss（起跑瞬间 dist3 任务刚入队
  /// 未完成的结构性 miss）。
  void _onThumbSettled(int i) {
    _crossTimes.clear();
    if (_flingLimit.value != 2000.0) _flingLimit.value = 2000.0;
    _onThumbPageChanged(i);
  }

  /// 条目构建钩子（Filmstrip.onItemBuild）：只管 96 显示档预取（±2）。
  /// large640/full 的预取不在条 build 驱动——新 build 的 item 是滚入
  /// 视口的【边缘格】（距聚焦 10+ 格），按 |i-center| 门控会永不触发
  ///（真机实证翻页 pick 降级 strip96 + full 全冷）；预取语义属于
  /// 「聚焦邻居」，由 _prefetchPageNeighbors（center 驱动）承担。
  void _prefetchStripItem(BuildContext ctx, int i) {
    for (final n in [i - 2, i + 2]) {
      if (n >= 0 && n < _thumbFiles.length) {
        precacheImage(
          buildThumbnailProvider(
            imageRefFromMediaStoreId(_thumbFiles[n].id),
            size: _kThumbLoadSize,
            squareCrop: true,
          ),
          ctx,
        );
      }
    }
  }

  /// 主图页驱动预取（翻页 onPageChanged / 条跟手联动的汇聚点）：档位按
  /// 距离分级（smali 考古对齐系统相册 r5c0.b：dist0=PRESENT /
  /// dist1=CONTENT(screenNail) / dist2~3=THUMB(0.625/0.375×屏宽) / 出窗
  /// =DATA 不加载）。visort 三轮真机迭代定案：
  ///  - dist0：full1152 p50——跳到页 ~70ms 内 fit 屏全清。
  ///  - dist1~5：**full1152 p250**（窗口 ±5 终版）——全库预缓存 blob 秒
  ///    读（run 27ms 实测 96% < 50ms），显示档即 fit 屏全清档。任务发起
  ///    率不变（每跨档仍 1 个新任务：46 档/s × 28ms / 6 门 ≈ 21% 门占用，
  ///    wait 0.5ms 实测零积压），±3→±5 纯粹把领先量拉到 109-217ms >> run
  ///    27ms——±3 时稳态超快段 full 命中 91%（miss 59/729 均匀散布 =
  ///    折返/起跑/峰值的领先不足），±5 收口。
  ///    ⚠️ 曾试 mid900 自产档（readSampledImage 现场生成）：blob 无预缓存
  ///    覆盖，每张首解 80-150ms——轻扫 dist1 都 miss（真机「轻扫就糊」
  ///    实证）；且 MediaStore thumb 640 尺寸不可控（59% 吐 240x320 mini、
  ///    余下 360x792 欠采样）两条路都堵死，full 直发是最短路径。900 档
  ///    保留在 pick 链（kViewerMidThumbSize）接住历史已生成条目。
  /// GIF 无 full 直通（readBytes 多帧）保持 640 等比 thumb。受
  /// _heavyStripPrefetch 延迟门控制（push 首帧洪峰防护，300ms）。
  void _prefetchPageNeighbors(int idx, {int radius = 5}) {
    if (!mounted || !_heavyStripPrefetch) return;
    final tw = computeViewerTargetWidth(View.of(context).physicalSize.width);
    for (var n = idx - radius; n <= idx + radius; n++) {
      if (n < 0 || n >= _thumbFiles.length) continue;
      final dist = (n - idx).abs();
      final imgRef = imageRefFromMediaStoreId(_thumbFiles[n].id);
      if (_thumbFiles[n].mime == 'image/gif') {
        precacheImage(
          buildThumbnailProvider(
            imgRef,
            size: kViewerLargeThumbSize,
            squareCrop: false,
          ),
          context,
        );
        continue;
      }
      precacheImage(
        buildImageProvider(
          imgRef,
          targetWidth: tw,
          // dist0 当前页级 p50（跳到页最快档）；dist1+ p250 预取级——
          // 让位当前页直通/probe，同档 FIFO 下 dist1 天然先于 dist3。
          priority: dist == 0
              ? RequestPriority.viewerImage
              : RequestPriority.prefetchFull,
        ),
        context,
      );
    }
  }

  /// 缩略图条滚动停止/点按 → 主图跟随。靠 `i == 当前` 天然防回环。
  void _onThumbPageChanged(int i) {
    _claimStripIndex(i);
    if (i == _selectedIndexNotifier.value) return;
    _selectedIndexNotifier.value = i;
    widget.onIndexChanged?.call(i);
    _thumbCenterIndex?.value = i;
    if (_pageController.hasClients) {
      _pagerDrivenByThumb = true;
      _pagerDrivenN.value = true; // 条锁步让位（animateToPage 途经 fraction）
      // 兜底:万一主图 animateToPage 未触发 target onPageChanged,超时复位防 flag 卡死。
      // token 守卫：快速连续点条时旧 timer 不再清掉新 drive 的 flag
      //（否则中间页 onPageChanged 不再被吞 → 条回弹抖动）。
      final token = ++_thumbDriveToken;
      Future.delayed(
        _kThumbSyncDuration + const Duration(milliseconds: 80),
        () {
          if (token == _thumbDriveToken) {
            if (_pagerDrivenByThumb) {
            }
            _pagerDrivenByThumb = false;
            _pagerDrivenN.value = false;
          }
        },
      );
      unawaited(
        _pageController
            .animateToPage(
              i,
              duration: _kThumbSyncDuration,
              curve: Curves.easeOut,
            )
            .whenComplete(() {
            }),
      );
    }
  }

  /// 主图翻页 → 缩略图条居中跟随：写 center 双向桥即可（Filmstrip 监听
  /// 外部写入 → 程序滚动 + 保持聚焦，大格随滚动滑入聚焦位）。
  /// 删除流程（_suppressThumbScroll）完全忽略：条数据/center 已由
  /// _removeCurrentAndAdvance 直接同步（frozen 桥挡），滑动期间的
  /// onPageChanged 若更新会把 center 推到旧语义 index（聚焦位跳出中心）。
  void _syncThumbTo(int i) {
    if (_suppressThumbScroll) return;
    _thumbCenterIndex?.value = i;
  }

  // ─────────────── 操作（主分支弹窗/流程 + galleryController） ───────────────

  Future<void> _toggleFavoriteCurrent() async {
    final file = _selectedFile;
    if (file == null) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .setFavorites(
          [file.id],
          !file.isFavorite,
          // 收藏视图下取消收藏延后移除（controller 语义）：pop 飞行需要
          // 网格 cell 存在，飞行完成后由 _onRouteAnimStatus 统一应用。
          deferForFlight: true,
        );
    if (!mounted) return;
    if (err != null) {
      toast(context, t(ref, 'favorite_failed'));
      return;
    }
    setState(() {
      final i = _files.indexWhere((f) => f.id == file.id);
      if (i >= 0) {
        // 全字段 copyWith——旧手写 13 字段构造漏 isHdr（收藏后 HDR 徽标被清）
        _files[i] = _files[i].copyWith(isFavorite: !_files[i].isFavorite);
      }
    });
    toast(context, t(ref, file.isFavorite ? 'unfavorited' : 'favorited'));
  }

  /// 分享当前图：系统分享面板（Aves 同款链路——Dart 松弛 MIME，原生
  /// ACTION_SEND + MediaStore content URI + FLAG_GRANT_READ_URI_PERMISSION，
  /// 见 share_channel.dart / SharePlugin.kt）。
  Future<void> _shareCurrent() async {
    final file = _selectedFile;
    if (file == null) return;
    try {
      final started = await shareImages([file]);
      if (!mounted) return;
      // false = 无应用能接收（Aves showNoMatchingAppDialog 的轻量版）
      if (!started) toast(context, t(ref, 'share_no_app'));
    } on ShareException {
      if (mounted) toast(context, t(ref, 'share_failed'));
    }
  }

  Future<void> _deleteCurrent() async {
    // 弹窗模态守卫：底栏挂在 root Overlay（Hero 飞行层之上），在 dialog 的
    // ModalBarrier 之上仍可点——弹窗显示期间再点「删除」会叠加弹窗（真机
    // 复现多层 barrier 越点越黑）。弹窗已开时忽略重复点击，等效模态。
    if (_deleteDialogShowing) return;
    final current = _selectedFile;
    if (current == null) return;
    // setState：PopScope.canPop 依赖本标志，不重建则系统返回仍 pop 页面。
    setState(() => _deleteDialogShowing = true);
    try {
      await _confirmAndDelete(current);
    } finally {
      _deleteDialogShowing = false;
      if (mounted) setState(() {});
    }
  }

  /// 弹出删除确认 sheet（系统相册式，公用 ConfirmSheet）。返回是否确认。
  /// session.close 存入 [_deleteSheetClose] 供 PopScope 拦截系统返回时关闭。
  Future<bool> _showDeleteSheet({required String title, String? desc}) async {
    final session = showConfirmSheet(
      context,
      title: title,
      desc: desc,
      cancelText: t(ref, 'cancel'),
      confirmText: t(ref, 'confirm'),
    );
    _deleteSheetClose = session.close;
    try {
      return await session.confirmed;
    } finally {
      _deleteSheetClose = null;
    }
  }

  Future<void> _confirmAndDelete(MsImageInfo current) async {
    final controller = ref.read(galleryControllerProvider.notifier);
    if (current.isTrashed) {
      // 回收站视图：彻底删除。
      final confirmed = await _showDeleteSheet(
        title: t(ref, 'delete_permanently'),
        desc: t(ref, 'delete_permanently_desc'),
      );
      if (confirmed != true) return;
      final err = await controller.deletePhoto(current.id);
      if (err != null) {
        if (mounted) toast(context, t(ref, 'delete_failed'));
        return;
      }
      _removeCurrentAndAdvance(t(ref, 'deleted'));
      return;
    }
    // 普通视图：删除 = 移入回收站（与系统相册一致；回收站内可恢复/彻底删除）。
    // 「图片删除提醒」开关（设置页，默认开）关闭时跳过应用内确认 sheet
    // 直接执行——移入回收站仍可恢复，且系统层面 trash 仍有兜底确认；
    // 回收站内的「彻底删除」不受此开关影响（不可恢复操作恒确认）。
    final confirmed = !ref.read(configProvider).deleteConfirmEnabled ||
        await _showDeleteSheet(
          title: t(ref, 'delete_confirm'),
          desc: t(ref, 'delete_confirm_desc'),
        );
    if (!confirmed) return;
    final err = await controller.trashPhoto(current.id);
    if (err != null) {
      // 用户取消系统弹窗是正常动作，静默返回；真实失败才提示
      //（旧实现统一「回收站需要 Android 10+」，minSdk 30 下永假误导）。
      if (err != 'trash_cancelled' && mounted) {
        toast(context, t(ref, 'trash_failed'));
      }
      return;
    }
    // undoPhoto：删除结果气泡带「撤回」（restorePhoto 恢复），仅普通视图
    // 删除提供——回收站彻底删除不可恢复，不给撤回入口。文案用
    // 'deleted_label'（已删除）而非 'deleted'（删除，批量/review 共用）。
    _removeCurrentAndAdvance(t(ref, 'deleted_label'), undoPhoto: current);
  }

  /// 恢复当前照片（回收站视图底栏恢复按钮）。
  Future<void> _restoreCurrent() async {
    final current = _selectedFile;
    if (current == null) return;
    final confirmed = await showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          t(ref, 'action_restore'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.text,
            fontSize: 15,
          ),
        ),
        content: Text(
          t(ref, 'restore_desc'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.muted,
            fontSize: 13,
          ),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    t(ref, 'cancel'),
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.bg,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t(ref, 'confirm')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .restorePhoto(current.id);
    if (err != null) {
      if (mounted) toast(context, t(ref, 'restore_failed'));
      return;
    }
    _removeCurrentAndAdvance(t(ref, 'restored'));
  }

  // ─────────────── ⋮ 菜单：复制/移动/重命名/设为壁纸（当前图） ───────────────

  /// 底栏 ⋮ 菜单（首页/相册勾选态同款 NonModalMenu，向上展开）。
  void _showViewerMenu() {
    // toggle：菜单已展开则收回（与首页同款）。
    if (_viewerMenuOpen) {
      _viewerMenuCtl!.close();
      return;
    }
    // 菜单宽度 = max(固定 184, 按最宽项测量)。测量公式（首页语言菜单/设置页
    // 同算法）：padding 16×2 + 图标 20 + 间距 12 + 最宽文本 + 12 缓冲。
    // 固定 184 在英文 "Set as wallpaper"（Space Mono 14px ≈ 143px）下会溢出
    // 弹窗右缘，故英文时按内容加宽；中文短标签（≈132px）保持 184 原观感。
    // 缓冲 12 而非同款菜单的 2——实测 TextPainter 测量值与实际渲染有 2~3px
    // 误差，2px 缓冲在 "Set as wallpaper" 上仍会触发 RenderFlex 溢出（debug 黄条）。
    const labelStyle = TextStyle(
      fontFamily: 'Space Mono',
      fontFamilyFallback: AppFonts.cjkFallback,
      color: AppColors.text,
      fontSize: 14,
    );
    final scaler = MediaQuery.textScalerOf(context);
    const labelKeys = [
      'copy_to_album',
      'move_to_album',
      'rename',
      'set_wallpaper',
    ];
    double maxText = 0;
    for (final key in labelKeys) {
      final tp = TextPainter(
        text: TextSpan(text: t(ref, key), style: labelStyle),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > maxText) maxText = tp.width;
    }
    const minMenuWidth = 184.0;
    final measuredWidth = 16 * 2 + 20 + 12 + maxText + 12;
    final menuWidth =
        measuredWidth > minMenuWidth ? measuredWidth : minMenuWidth;
    _viewerMenuCtl = showNonModalMenu(
      context: context,
      anchorKey: _viewerMenuKey,
      menuWidth: menuWidth,
      upward: true,
      isScrolling: _viewerMenuScrolling,
      // 菜单收起（任意途径）后刷新 PopScope.canPop：不刷新则收起后仍停留
      // false，下一次系统返回会被 onPopInvoked 吞掉（菜单已关、无操作）。
      onDismiss: () {
        if (mounted) setState(() {});
      },
      menuBuilder: (ctx) => Material(
        color: AppColors.surfaceElevated,
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _viewerMenuItem(
              ctx,
              Icons.content_copy,
              t(ref, 'copy_to_album'),
              onTap: () {
                _viewerMenuCtl?.close();
                _copyMoveCurrent(copy: true);
              },
            ),
            _viewerMenuItem(
              ctx,
              Icons.drive_file_move_outlined,
              t(ref, 'move_to_album'),
              onTap: () {
                _viewerMenuCtl?.close();
                _copyMoveCurrent(copy: false);
              },
            ),
            _viewerMenuItem(
              ctx,
              Icons.drive_file_rename_outline,
              t(ref, 'rename'),
              onTap: () {
                _viewerMenuCtl?.close();
                _renameCurrent();
              },
            ),
            _viewerMenuItem(
              ctx,
              Icons.wallpaper,
              t(ref, 'set_wallpaper'),
              onTap: () {
                _viewerMenuCtl?.close();
                _setAsWallpaper();
              },
            ),
          ],
        ),
      ),
    );
    // 展开后立即刷新 PopScope.canPop——菜单刚开、期间无其它 rebuild，
    // 不刷新则系统返回会直接 pop 页面（详见 PopScope 拦截逻辑）。
    setState(() {});
  }

  /// 菜单单项（首页 _buildMenuItem 同款：图标 + 文本，48 高）。
  Widget _viewerMenuItem(
    BuildContext ctx,
    IconData icon,
    String label, {
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: AppColors.text, size: 20),
              const SizedBox(width: 12),
              // Expanded：菜单宽度按最宽项测量（含 12 缓冲）后文本完整显示；
              // 极端字号缩放等剩余宽度不足时省略号兜底，而非 RenderFlex 溢出。
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    color: AppColors.text,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 设当前图为壁纸 → 全屏范围调整页（模仿 Aves WallpaperPage：
  /// 初始 covered 可拖动/捏合调整，右下按钮 → 目标三选 + 滚动效果开关）。
  /// 裁剪页期间抑制本页栏（root Overlay 浮于子路由之上的问题）。
  Future<void> _setAsWallpaper() async {
    final current = _selectedFile;
    if (current == null) return;
    chromeSuppressed.value = true;
    try {
      await pushWallpaperCropPage(context, current);
    } finally {
      if (mounted) chromeSuppressed.value = false;
    }
  }

  /// 复制/移动当前图到选定相册。copy 原图不动只 toast；move 走删除同款
  /// 移除+补位（_removeCurrentAndAdvance）。
  Future<void> _copyMoveCurrent({required bool copy}) async {
    final current = _selectedFile;
    if (current == null) return;
    // 相册选择页期间抑制本页栏（root Overlay 浮于子路由之上——与
    // _setAsWallpaper 同款问题：不抑制则顶栏/底栏/filmstrip 盖在选择页上）。
    chromeSuppressed.value = true;
    final MsBucket? bucket;
    try {
      bucket = await pushAlbumPicker(context);
    } finally {
      if (mounted) chromeSuppressed.value = false;
    }
    if (bucket == null || !mounted) return;
    final controller = ref.read(galleryControllerProvider.notifier);
    final err = copy
        ? await controller.copyPhotosToAlbum([current.id], bucket.id)
        : await controller.movePhotosToAlbum([current.id], bucket.id);
    if (!mounted) return;
    if (err != null) {
      // 已知 key（copy_failed/move_failed/move_cancelled…）直接翻译，
      // 异常串回退通用失败文案。
      final key = err.contains(' ')
          ? (copy ? 'copy_failed' : 'move_failed')
          : err;
      toast(context, t(ref, key));
      return;
    }
    if (copy) {
      toast(context, t(ref, 'copied'));
    } else {
      _removeCurrentAndAdvance(t(ref, 'moved_toast'));
    }
  }

  /// 重命名当前图（对话框 → DISPLAY_NAME 更新 → 本地回填名称）。
  Future<void> _renameCurrent() async {
    final current = _selectedFile;
    if (current == null) return;
    final newName = await showRenameDialog(context, ref, photo: current);
    if (newName == null || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .renamePhoto(current.id, newName);
    if (!mounted) return;
    if (err != null) {
      final key = err.contains(' ') ? 'rename_failed' : err;
      toast(context, t(ref, key));
      return;
    }
    // 本地回填（顶栏文件名 + 缩略图条数据同步；_ID 不变 uri 仍有效）
    setState(() {
      final i = _files.indexWhere((f) => f.id == current.id);
      if (i >= 0) _files[i] = _files[i].copyWith(name: newName);
      final j = _thumbFiles.indexWhere((f) => f.id == current.id);
      if (j >= 0) _thumbFiles[j] = _thumbFiles[j].copyWith(name: newName);
    });
    toast(context, t(ref, 'renamed'));
  }

  /// 删除/恢复成功后从列表移除当前项并跳到下一张（或末张），刷新栏位计数。
  ///
  /// [undoPhoto] 非空（普通视图删除移入回收站）时结果气泡带「撤回」按钮
  /// （见 [_showDeleteToast]）；null 走全局 toast（恢复/移动/彻底删除）。
  ///
  /// 条动画 = 系统相册 PhotoPagerIndicator 同构（RecyclerView ItemAnimator
  /// 位置动画）。聚焦位固定在条正中（锚点布局的视口中心）：
  ///  1. center 翻到下一项延迟到补位后段（150ms）——B 进聚焦位途中才放大
  ///     （120ms），两条动画同时收尾，不出现「聚焦位外先放大再推入」；
  ///  2. 被删项保持放大态在聚焦位原地淡出（位置置空），后续项
  ///     Transform.translate 平滑左移一格补位（位置动画，非 AnimatedList
  ///     布局重排——重排会在移除项占槽期间把高亮项排到右边一格 =
  ///     "跳到第二个又弹回来"）；
  ///  3. 条动画完成（250ms）：数据左移 + center 对齐（同一项，无跳变）；
  ///  4. 主图在旧数据上 animateToPage(next) 滑动（300ms），完成后删数据
  ///     + pixels 校正（同帧）。
  void _removeCurrentAndAdvance(String message, {MsImageInfo? undoPhoto}) {
    if (!mounted || _deletingInProgress) return;
    // 最后一张:直接退出,不 setState——否则 viewer 会先 rebuild 成空 Scaffold,
    // 在 pop 动画期间露出一帧空白。气泡先挂（root Overlay 独立于路由，pop
    // 后仍可撤回——controller 层恢复，相册页靠 ContentObserver 自动刷新）。
    if (_files.length <= 1) {
      if (undoPhoto != null) {
        _showDeleteToast(message, undoPhoto, 0);
      } else {
        toast(context, message);
      }
      Navigator.pop(context);
      return;
    }
    final index = _selectedIndexNotifier.value;
    final next = index < _files.length - 1 ? index + 1 : index - 1;
    _deletingInProgress = true;
    _suppressThumbScroll = true;
    // 条联动一并冻结（Filmstrip.frozen）：offset 冻结 + 渲染照常——删除
    // 前后聚焦格模型同构，中心项不动，下一项顶入原聚焦格（见 filmstrip
    // 文件头）；frozen 解除时组件对齐 center 补聚焦（删末项场景）。
    _thumbFrozen.value = true;
    // 300ms 动画窗口锁主图 physics（_swipeLocked 旧字段从未接线=死代码）：
    // 用户滑动会打断 animateToPage → .then 提前 removeAt 与手势目标打架，
    // 选中态/聚焦位/主图三处错位。锁后手势全部失效，动画必然走完。
    setState(() => _swipeLocked = true);

    // ─ 条：平移补位动画 ─
    _thumbDeleteIndex = index;
    // center 翻页延迟到补位**后段**（150ms）：立即切会让 B 在框外就完成
    // 放大（120ms）再推入——放大先于进框，观感错序（真机反馈）。后段
    // 切换 = B 进框途中放大（150+120 ≈ 补位 250ms 收尾，同时到达），
    // 被删项全程保持放大态淡出（框内置空观感更强）。_thumbDeleteIndex
    // 守卫防早到 timer 误切（理论上 300ms 删除窗口挡住连续删除，纯防御）。
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _thumbDeleteIndex == index) {
        _thumbCenterIndex?.value = next;
      }
    });
    unawaited(
      _thumbDeleteAnim.forward(from: 0).then((_) {
        if (!mounted) return;
        setState(() => _thumbFiles.removeAt(index));
        _thumbCenterIndex?.value = min(index, _thumbFiles.length - 1);
        _thumbDeleteIndex = -1;
      }),
    );

    // ─ 主图：旧数据滑动 ─
    unawaited(
      _pageController
          .animateToPage(
            next,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .then((_) {
            if (!mounted) return;
            final arrived = _pageController.page?.round() ?? -1;
            if (arrived != next) {
              // 动画被中断（理论不可达：physics 已锁；防御未知 ROM/手势
              // 竞争）：数据照删（MediaStore 已物理删除，不删会残留幽灵
              // 项），同帧 jump 校正选中态，无动画终态收敛。
              setState(() {
                _files.removeAt(index);
                _indexById = null; // F19：结构变更，查表重建
              });
              final newIndex = min(index, _files.length - 1);
              _selectedIndexNotifier.value = newIndex;
              widget.onIndexChanged?.call(newIndex);
              if (_pageController.hasClients) {
                _pageController.jumpToPage(newIndex);
              }
              return;
            }
            setState(() {
              _files.removeAt(index);
              _indexById = null; // F19：结构变更，查表重建
            });
            final newIndex = min(index, _files.length - 1);
            _selectedIndexNotifier.value = newIndex;
            widget.onIndexChanged?.call(newIndex);
            // 删除倒数第二张时 pixels 可能在旧 maxScrollExtent 之外——校正。
            if (_pageController.hasClients &&
                (_pageController.page?.round() ?? newIndex) != newIndex) {
              _pageController.jumpToPage(newIndex);
            }
          })
          .whenComplete(() {
            _deletingInProgress = false;
            _suppressThumbScroll = false;
            _thumbFrozen.value = false; // 组件对齐 center 补聚焦
            if (mounted) setState(() => _swipeLocked = false);
          }),
    );
    if (undoPhoto != null) {
      _showDeleteToast(message, undoPhoto, index);
    } else {
      toast(context, message);
    }
  }

  // ─────────────── 删除结果气泡（带撤回） ───────────────

  /// 当前删除撤回气泡（同时至多一条：连续删除先移除上一条）。
  OverlayEntry? _deleteToastEntry;

  /// 大图删除专用结果气泡：文案 + 撤回按钮（主题黄绿 undo icon）。
  ///
  /// 与全局 toast 的差异：
  ///  - 位置：缩略图条**上方**（全局 toast bottomInset+76 压住缩略图条，
  ///    真机反馈遮挡）；
  ///  - 带撤回：[onUndo] → restorePhoto 恢复 + 插回列表跳回该张；
  ///  - 生命周期独立于本页（挂 root Overlay，页面 pop 后 3.5s 内仍可撤回
  ///    ——最后一张删除场景，恢复后相册页靠 ContentObserver 自动刷新）。
  void _showDeleteToast(String message, MsImageInfo photo, int removedIndex) {
    _deleteToastEntry?.remove();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _DeleteToastView(
        message: message,
        onUndo: () {
          // 先取 container 再 remove：remove 即 deactivate 气泡子树，
          // 之后 ctx 失效（containerOf/inherited 查找会 assert）。
          final container = ProviderScope.containerOf(ctx, listen: false);
          entry.remove();
          if (_deleteToastEntry == entry) _deleteToastEntry = null;
          _undoDelete(container, photo, removedIndex);
        },
      ),
    );
    _deleteToastEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    Future.delayed(const Duration(milliseconds: 3500), () {
      // 已被撤回/被下一条气泡顶替时 entry 已 remove，幂等守卫防二次移除。
      if (_deleteToastEntry == entry) {
        _deleteToastEntry = null;
        entry.remove();
      }
    });
  }

  /// 撤回删除：restorePhoto 恢复 MediaStore 行；页面在世则插回
  /// [_files]/[_thumbFiles] 原位置并跳回该张，已 pop 则到此为止（相册页
  /// ContentObserver 自动刷新）。[container] 由气泡 ctx 在移除前取得——
  /// 页面 dispose 后 ref 不可用，全局容器是唯一通道。
  Future<void> _undoDelete(
    ProviderContainer container,
    MsImageInfo photo,
    int removedIndex,
  ) async {
    // 删除补位动画窗口（300ms）防御：插回会与动画链的 removeAt 竞态。
    // 气泡与动画同时出现，物理上点不到这么快，纯防御。
    if (_deletingInProgress) return;
    final controller = container.read(galleryControllerProvider.notifier);
    final err = await controller.restorePhoto(photo.id);
    if (err != null) {
      // 用户取消系统恢复弹窗是正常动作，静默；真实失败才提示（页面已
      // pop 时静默——恢复失败的照片仍在回收站，入口不丢）。
      if (err != 'restore_cancelled' && mounted) {
        toast(context, t(ref, 'restore_failed'));
      }
      return;
    }
    if (!mounted) return;
    final restored = photo.copyWith(isTrashed: false);
    setState(() {
      final i = removedIndex.clamp(0, _files.length);
      _files.insert(i, restored);
      _thumbFiles.insert(
        removedIndex.clamp(0, _thumbFiles.length),
        restored,
      );
      _indexById = null; // 结构变更，查表重建
    });
    // 跳回恢复的那张：主图 + 选中态 + 缩略图条居中。
    final newIndex = removedIndex.clamp(0, _files.length - 1);
    _selectedIndexNotifier.value = newIndex;
    widget.onIndexChanged?.call(newIndex);
    if (_pageController.hasClients) _pageController.jumpToPage(newIndex);
    _syncThumbTo(newIndex);
  }

  // ─────────────── 详情面板（主分支 Overlay 自有机制） ───────────────

  /// 切换详情面板(底栏 info 按钮入口):开则关、关则开。
  void _toggleDetails() {
    if (_detailsOpen) {
      _animateClose();
    } else {
      final file = _selectedFile;
      if (file != null) _showDetails(file);
    }
  }

  /// 显示当前照片的详情面板(ColorOS 相册式卡片栈)。
  ///
  /// 同步动画:_panelExtent(0..1,相对屏高)是图片上推 / 顶栏淡出 / 缩略图条淡出的
  /// 唯一驱动源。Overlay 自有面板:单一 _panelCtrl 驱动面板位移 + 图片上推,严格同步,
  /// 无路由(不误 pop)、无 DSS(无 snap 卡 ticker)。value 0=关闭/1=展开。
  void _showDetails(MsImageInfo info) {
    if (_detailsOpen) return;
    // setState:PopScope 的 canPop 依赖 _detailsOpen,不重建则系统返回直接退出。
    setState(() => _detailsOpen = true);
    // 面板打开期间底栏/缩略图条需可见、顶栏随占比淡出:强制退出全屏(edge-to-edge)。
    if (enableFullScreenNotifier.value) {
      enableFullScreenNotifier.value = false;
      restoreEdgeToEdgeBars();
    }
    _panelCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
          reverseDuration: const Duration(milliseconds: 180),
        )..addListener(() {
          _panelExtent.value = _panelCtrl!.value * _kDetailInitial;
        });
    _panelCtrl!.value = 0;
    // 打开:easeOut(前快后慢)。
    _panelCtrl!.animateTo(
      1,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  /// 关闭:easeIn(前快后慢,不在一半突然加速),完成后移除面板。
  void _animateClose() {
    final ctrl = _panelCtrl;
    if (ctrl == null) return;
    ctrl
        .animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeIn,
        )
        .orCancel
        .then((_) {
          if (mounted) _onDetailsDismissed();
        })
        // .orCancel 在面板动画被切（快速关闭重建、翻页重置）时抛 TickerCanceled，
        // 属预期取消——吞掉避免 unhandled async error 污染日志。
        .onError((_, __) {});
  }

  /// 详情面板关闭收尾。
  void _onDetailsDismissed() {
    setState(() => _detailsOpen = false);
    _panelExtent.value = 0;
    // 关键：面板 AnimatedBuilder 在被栏移除之前可能再被标脏 rebuild 一次，
    // 此时 builder 读 _panelCtrl! 会撞 null 崩溃 → 该帧渲染 ErrorWidget
    // （release 为灰盒）→ 用户看到"收起结束瞬间面板区闪灰色一块"。
    // builder 已改为读局部捕获的 controller（见 _buildPanelOverlay），
    // 这里只把字段置 null（guard 面板不再重建）；dispose 再延后一帧，
    // 确保期间任何 rebuild 读到的都是活着的 controller（value=0，屏外）。
    final ctrl = _panelCtrl;
    _panelCtrl = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl?.dispose());
  }

  /// 拖拽面板松手:snap 二值(展开/收回),不停在中间。
  void _onPanelDragEnd(DragEndDetails d) {
    final ctrl = _panelCtrl;
    if (ctrl == null) return;
    final v = d.primaryVelocity ?? 0;
    if (v > 300) {
      _animateClose();
    } else if (v < -300) {
      ctrl.animateTo(
        1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else if (ctrl.value > 0.5) {
      ctrl.animateTo(
        1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _animateClose();
    }
  }

  /// 详情面板 Overlay:固定 _kDetailInitial 可用区高度,Transform 跟随 _panelCtrl
  /// 从屏底滑入/滑出。锚定在底栏上方(bottom: barH)→ 底栏始终可见,面板从底栏上沿
  /// 长出。松手 snap 二值。
  ///
  /// 手势分层:内容区(ListView)滚内容;内容滚到顶后继续下拉 → OverscrollNotification
  /// → 收回面板(见 [_handlePanelContentScroll]);顶部把手条可随时直接拖面板。
  Widget _buildPanelOverlay(MsImageInfo? info) {
    if (info == null) return const SizedBox.shrink();
    final mq = MediaQuery.of(context);
    final barH = _kBottomChromeHeight + mq.viewPadding.bottom;
    final availH = mq.size.height - barH;
    final panelH = _kDetailInitial * availH;
    final slideOut = panelH + barH;
    // 局部捕获 controller：builder 绝不读可空字段 _panelCtrl!——面板被栏
    // 移除之前若再次 rebuild（_onDetailsDismissed 已置 null），空断言崩溃
    // 会让该帧渲染 ErrorWidget（release 灰盒）= 收起结束瞬间的灰色闪烁。
    final ctrl = _panelCtrl;
    if (ctrl == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: barH,
      height: panelH,
      child: AnimatedBuilder(
        animation: ctrl,
        builder: (_, child) {
          final ty = (1 - ctrl.value) * slideOut;
          return Transform.translate(offset: Offset(0, ty), child: child);
        },
        child: Stack(
          children: [
            Positioned.fill(
              // scrollable:true → 面板内容可滚动(ListView)。拖拽手势只挂在顶部
              // 把手区:内容 Scrollable 与父 GestureDetector 同抢垂直拖拽时子级必赢,
              // 全面板 GestureDetector 会收不到事件,故收窄到把手条互不冲突。
              child: NotificationListener<ScrollNotification>(
                onNotification: _handlePanelContentScroll,
                child: ScrollConfiguration(
                  // 内容区需始终接受拖拽(内容不可滚时默认 physics 会拒绝用户
                  // 拖拽 → 无法通过 overscroll 收回面板),见 _PanelContentPhysics。
                  behavior: const _PanelContentScrollBehavior(),
                  child: Material(
                    type: MaterialType.transparency,
                    child: PhotoDetailsSheet(info: info, scrollable: true),
                  ),
                ),
              ),
            ),
            // 面板顶部把手拖拽区(透明):下拉收起 / 上拉展开面板。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _kPanelDragZone,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) {
                  final ctrl = _panelCtrl;
                  if (ctrl == null) return;
                  ctrl.value = (ctrl.value - d.primaryDelta! / slideOut).clamp(
                    0.0,
                    1.0,
                  );
                },
                onVerticalDragEnd: _onPanelDragEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 面板内容区越界拖拽状态:记录本次手势是否发生过 overscroll(面板联动过),
  /// 及末次越界速率(ScrollEnd 时据此决定 snap 方向,与图片区 dismiss 手感一致)。
  bool _panelOverDragged = false;
  final List<(Duration, double)> _overSamples = [];
  double _lastOverVel = 0;

  /// 面板内容区滚动协调(嵌套滚动):
  ///   - 内容滚到顶后继续下拉 → OverscrollNotification(负)→ 面板随之下移(收回);
  ///   - 内容滚到底后继续上拉 → overscroll(正)→ 面板回升(展开);
  ///   - 松手(ScrollEnd)→ 与图片区(dismiss 层)一致:向下速度即收回,不依赖位移;
  ///     向上速度展开;无速度(缓停)按位置二值。
  bool _handlePanelContentScroll(ScrollNotification n) {
    final ctrl = _panelCtrl;
    if (ctrl == null) return false;
    if (n is ScrollStartNotification) {
      // 新手势开始:重置越界状态(内容普通滚动不触发面板 snap)
      _panelOverDragged = false;
      _overSamples.clear();
      _lastOverVel = 0;
      return false;
    }
    if (n is OverscrollNotification) {
      _panelOverDragged = true;
      final over = n.overscroll;
      final t = n.dragDetails?.sourceTimeStamp;
      if (over != 0 && t != null) {
        _overSamples.add((t, over));
        if (_overSamples.length > 4) _overSamples.removeAt(0);
        if (_overSamples.length >= 2) {
          final a = _overSamples[_overSamples.length - 2];
          final b = _overSamples.last;
          final dtUs = b.$1.inMicroseconds - a.$1.inMicroseconds;
          if (dtUs > 0) {
            // 取反:overscroll 负 = 内容向顶部过界 = 手指向下 → 速度应为正。
            _lastOverVel = -(b.$2 / dtUs * 1e6);
          }
        }
      }
      if (over == 0) return false;
      ctrl.value = (ctrl.value + over / slideOutForPanel()).clamp(0.0, 1.0);
      return false; // 不消费:辉光反馈等仍由 Scrollable 内部处理
    }
    if (n is ScrollEndNotification && _panelOverDragged && ctrl.value < 1.0) {
      final v = _lastOverVel;
      if (v > 0) {
        _animateClose();
      } else if (v < 0) {
        ctrl.animateTo(
          1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else if (ctrl.value > 0.5) {
        ctrl.animateTo(
          1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        _animateClose();
      }
      return false;
    }
    return false;
  }

  /// 面板从屏外滑到位的总行程(与 _buildPanelOverlay 的 slideOut 同值)。
  double slideOutForPanel() {
    final mq = MediaQuery.of(context);
    final barH = _kBottomChromeHeight + mq.viewPadding.bottom;
    return _kDetailInitial * (mq.size.height - barH) + barH;
  }
}

/// 跑道形撤回图标已上收为共享组件 UndoTrackGlyphIcon（glyph_icons.dart；
/// 回收站批量栏「恢复」操作复用同款图形，size 22 缩小档）。

/// 大图删除结果气泡：文案 + 撤回按钮（主题黄绿 undo icon）。
///
/// 与全局 toast（toast.dart）同款皮肤（surface/border/圆角/阴影/淡入淡出
/// 节奏），差异：
///  - 定位在缩略图条**上方**（全局 toast 的 bottomInset+76 落在缩略图条
///    区域内，真机反馈遮挡缩略图条）；
///  - 文案区可点穿（不挡主图手势），撤回 icon 是唯一交互点。
class _DeleteToastView extends StatefulWidget {
  const _DeleteToastView({required this.message, required this.onUndo});

  final String message;
  final VoidCallback onUndo;

  @override
  State<_DeleteToastView> createState() => _DeleteToastViewState();
}

class _DeleteToastViewState extends State<_DeleteToastView>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _controller.forward();
    // 淡出节奏同全局 toast：2.5s 起淡出，3.5s 由页面侧移除 entry。
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) _controller.reverse();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 底栏(64) + 缩略图条(44) + 12px 间隙——完全避开缩略图条。
    final bottom =
        MediaQuery.viewPaddingOf(context).bottom + _kBottomChromeHeight + _kThumbLineHeight + 12;
    return Positioned(
      bottom: bottom,
      left: 0,
      right: 0,
      child: Center(
        child: FadeTransition(
          opacity: _controller,
          child: Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width - 48,
              ),
              child: Container(
                // 紧凑版（2026-09 用户要求整体缩小，文字字号不变）：
                // 内边距/间距全面收紧，高度由按钮行主导。
                padding: const EdgeInsets.only(left: 12, right: 5, top: 3, bottom: 3),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [
                    BoxShadow(
                      color: AppColors.shadowScrim,
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 文案区点穿：不挡下层主图手势（气泡悬浮在图片上）。
                    IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          widget.message,
                          style: const TextStyle(
                            fontFamily: 'Space Mono',
                            height: 1.2,
                            fontFamilyFallback: AppFonts.cjkFallback,
                            fontSize: 13,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // 撤回按钮：跑道形撤回图标（自绘，主题黄绿）——
                    // 上/下两条直线 + 两端半圆弧的跑道轮廓，路径从左下
                    // 起（底线左端）→ 底直线 → 右端弧 → 顶直线 → 左上止，
                    // 箭头指向行进方向（用户定稿形状；Material 的
                    // undo/replay 均为纯弧线非此形）。
                    InkWell(
                      onTap: widget.onUndo,
                      borderRadius: BorderRadius.circular(6),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                        child: UndoTrackGlyphIcon(size: 28),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板内容区 physics:默认 physics 在内容不可滚(maxScrollExtent==0,占位/短内容)
/// 时 shouldAcceptUserOffset 返回 false,Scrollable 拒绝用户拖拽 → 下拉无法产生
/// overscroll、面板收不回来。强制接受:内容可滚时行为不变,不可滚时下拉仍能
/// 经 OverscrollNotification 收回面板。
class _PanelContentPhysics extends ClampingScrollPhysics {
  const _PanelContentPhysics({super.parent});

  @override
  _PanelContentPhysics applyTo(ScrollPhysics? ancestor) =>
      _PanelContentPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;
}

/// 供面板内容 ListView 使用的 ScrollBehavior(注入 [_PanelContentPhysics])。
class _PanelContentScrollBehavior extends MaterialScrollBehavior {
  const _PanelContentScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const _PanelContentPhysics().applyTo(super.getScrollPhysics(context));
}

/// 回收站项底栏的删除日期标签（主分支 _TrashDateLabel 同款）。
class _TrashDateLabel extends ConsumerWidget {
  const _TrashDateLabel({required this.ms});
  final int ms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // DATE_EXPIRES 是「过期时间」= 移入回收站时刻 + 30 天（AOSP 默认保留期）；
    // 删除日期 ≈ DATE_EXPIRES − 30 天。（排序仍用 DATE_EXPIRES，相对顺序=删除顺序）
    final dt = DateTime.fromMillisecondsSinceEpoch(
      ms - 30 * 24 * 60 * 60 * 1000,
    );
    String two(int n) => n.toString().padLeft(2, '0');
    final dateStr = '${two(dt.month)}-${two(dt.day)}';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t(ref, 'trash_deleted_label'),
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 10,
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
          ),
        ),
        Text(
          dateStr,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 12,
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
          ),
        ),
      ],
    );
  }
}

/// 页缘黑缝（翻页间隙）：左右各 4px 黑条，仅 PageView 滚动中显示
/// （AnimatedOpacity 淡入），相邻两页交界处拼成 8px 黑色间距。
class _PageGapEdges extends StatelessWidget {
  const _PageGapEdges();

  @override
  Widget build(BuildContext context) {
    // Stack 双 Positioned 顶底拉伸（Row+SizedBox(width) 在
    // crossAxisAlignment.center 下高度 0 = 不可见，真机翻页无缝的根因）。
    return const Stack(
      children: [
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: 4,
          child: ColoredBox(color: Colors.black),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 4,
          child: ColoredBox(color: Colors.black),
        ),
      ],
    );
  }
}
