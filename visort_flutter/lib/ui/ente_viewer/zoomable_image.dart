// [ente 移植] 大图缩放组件 —— 基于 ente zoomable_image.dart（photo_view 0.15）
//
// 保留（与 ente 完全一致）：
//   - PhotoView 配置：minScale contained / maxScale covered×3 / strictScale
//   - PhotoViewGestureDetectorScope(axis: vertical) 垂直手势轴裁决
//   - scaleStateChangedCallback：缩放中禁用翻页 + isZoomedNotifier
//   - outputStateStream → zoomTransformNotifier（浮层跟手）
//   - _updatePhotoViewController：缩放中切原图按尺寸比修正防跳变
//   - loadingBuilder 按图片在屏最终尺寸渲染（Hero 动画期占位不跳变）
//   - 垂直拖拽：下滑 >8px → pop（Navigator.maybePop）；上滑 >8px → 详情
//
// 适配 visort：
//   - EnteFile → MsImageInfo；tag = 'photo_${id}'（与网格 cell Hero 配对）
//   - 加载管线：缩略图/原图用 visort buildThumbnailProvider/buildImageProvider
//     （MediaStore 通道，无服务端下载/加密/Rust/EXIF 特判）
//   - 删除：memories/live photo/QR/服务端/DB/事件总线/共享/guest view

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/src/core/photo_view_core.dart'
    show PhotoViewCoreState;
import 'package:visort_flutter/core/fs/cache_perf.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/fs/service_policy.dart';

import 'package:visort_flutter/ui/screens/album_common.dart' show extOf;
import 'detail_page_state.dart';
import 'gallery_groups.dart' show GalleryGroups;
import 'thumbnail_widget.dart' show ThumbnailPlaceHolder;

/// ente 常量（core/constants.dart dragSensitivity = 8）：上滑详情/下滑关闭阈值。
const double _kDragSensitivity = 8.0;

/// 重加载（512 缩略图 + 下采样原图）起跳延迟。
///
/// 缩略图条快甩联动主图（跟手 jumpToPage / 停止后 animateToPage 扫过）
/// 时，途经页 build 即触发本页 512+原图 precache——几十个早已无观众的
/// 重量级请求（原图 ~1MP 解码，优先级 50）灌满 ServicePolicy 6 槽门，
/// 当前页与缩略图条（96px，优先级 100）反而在队尾 → 主图黑屏、条占位
/// 符连片，停稳后还要等积压排空。延迟 150ms 起跳：路过页在窗口内被
/// dispose/换图（generation++）即取消，零入队；正常翻页（±1 预建页常驻
/// >150ms）预取语义不变。
const Duration _kHeavyLoadDelay = Duration(milliseconds: 150);

class ZoomableImage extends StatefulWidget {
  final MsImageInfo photo;

  /// 页索引（顶层双击路由注册键；null 时不参与顶层分发）。
  final int? pageIndex;
  final void Function(bool)? shouldDisableScroll;
  final String? tagPrefix;
  final Decoration? backgroundDecoration;

  /// 上滑（>8px）→ 详情面板（visort 适配：外层 DetailPage 决定展示）。
  final VoidCallback? onSwipeUp;

  /// [photo_view fork] X 边缘溢出回调：放大后平移到 X 边缘继续拖
  /// （+1 右拖→上一张，-1 左拖→下一张，由外层 DetailPage 翻页）。
  final ValueChanged<int>? onEdgeX;

  /// 下滑（>8px）→ 返回（visort 适配：外层 DetailPage 面板打开时改为收面板）。
  final VoidCallback? onSwipeDown;

  /// 原图（下采样）就绪回调（外层记录 id，退出时 evict 缓存）。
  final ValueChanged<String>? onFullLoaded;

  /// 放大升档（HD 2304）就绪回调（外层记录 id，翻页窄窗 trim）。
  final ValueChanged<String>? onHdLoaded;

  /// 网格列数：cell 缩略图尺寸与网格 cell 完全一致（ImageCache key 命中，
  /// 飞行层/Hero shuttle 首帧不重新解码）。
  final int gridCols;

  const ZoomableImage(
    this.photo, {
    super.key,
    this.pageIndex,
    this.gridCols = 4,
    this.shouldDisableScroll,
    this.tagPrefix,
    this.backgroundDecoration,
    this.onSwipeUp,
    this.onSwipeDown,
    this.onEdgeX,
    this.onFullLoaded,
    this.onHdLoaded,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  /// PhotoViewCore 全局键：顶层双击 → doubleTapZoom 入口。
  final GlobalKey<PhotoViewCoreState> _coreKey =
      GlobalKey<PhotoViewCoreState>();
  InheritedDetailPageState? _inherited;

  /// 加载代际：换图（didUpdateWidget）时自增；旧图 precache 回调按代际
  /// 丢弃，防止删除补位后旧图 large/final 迟到覆盖新图 provider。
  int _loadGeneration = 0;

  /// 重加载（512 + 原图 precache）起跳延迟计时器：见 [_kHeavyLoadDelay]。
  Timer? _heavyLoadTimer;
  ImageProvider? _imageProvider;
  bool _loadedSmallThumbnail = false;
  bool _loadingLargeThumbnail = false;
  bool _loadedLargeThumbnail = false;
  bool _loadingFinalImage = false;
  bool _loadedFinalImage = false;
  bool _showingThumbnailFallback = false;

  /// 盘缓存直通（快甩掠过即清晰）：exists 已探测（每图一次，换图复位）/
  /// 直通 full 在途（p120，停稳时被 bumpPriority 升级插队）。见
  /// [_probePassThrough]。
  bool _passThroughProbed = false;
  bool _passThroughInFlight = false;

  // 放大升档：无触发判据（immich 行为）——打开/翻页零升档任务，4096 仅由
  // 「进入放大态」的离散状态信号触发（_scaleStateChangedCallback /
  // _updateViewWithFinalImage 末尾补查），p150 与一切用户请求互斥。
  // 此前按 scale 阈值触发的方案每轮真机都在修边界（基准宽被补偿污染/
  // 双击窗口/静止门延迟），全部废除。

  /// 渐进升档 completer 的流（_updateViewWithFinalImage 换上渐进 provider
  /// 时 resolve 持有；放大触发经它调 requestUpTo）。换图复位。
  ImageStream? _progressiveStream;

  /// 【实验·打开即原图】渐进 provider 引用（attach 时存，帧就绪且静止
  /// 闸开时 _tryFlushHd 统一换链）：渐进 completer 跳过 1152 首帧、首帧
  /// 即 4096，提前换链 = PhotoView 黑底窗口。换图复位。
  ImageProvider? _progressiveProvider;

  /// 【4096 替换时机闸】帧解完（completer 暂存）后，何时 flush：
  /// ①路由 push 动画 completed（飞行动画结束，用户注意力空档——最佳
  ///   替换时机：既用到 1152 缓存秒显，落地即全清）；
  /// ②缩放静止（距最后 zoom 事件 ≥250ms，双击/捏合动画中推帧会与动画
  ///   写值交错 = 视觉跳变）。
  /// 驱动源：completer onFrameReady 回调 + 路由 statusListener + zoom
  /// 事件重排的停稳 Timer。
  bool _routeSettled = false;
  bool _routeListenerAttached = false;
  DateTime _lastZoomActivityAt = DateTime.now();
  Timer? _hdFlushTimer;

  static const Duration _kZoomIdleForFlush = Duration(milliseconds: 250);

  void _onHdRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _routeSettled = true;
      _tryFlushHd();
    }
  }

  /// flush 条件检查（四源驱动收敛点：onFrameReady / 路由 settled /
  /// zoom 停稳 Timer / 翻页滚动结束）。
  ///
  /// 主路径：渐进 provider 已在屏（updfl/补建换上），此处只 flush 推帧，
  /// widget 零 rebuild。换链分支是兜底：attach 了但 provider 尚未上屏的
  /// 场景（理论不可达，防「帧推给空气」）——帧进 completer current 后再
  /// 换 provider，build 时 resolve 命中 cache 同 completer 同步回放。
  /// hasFrame 守卫：无帧时不 flush（提前开闸会让帧到时绕过静止闸直推），
  /// 等 onFrameReady 再驱动。
  void _tryFlushHd() {
    if (!mounted || !_routeSettled) return;
    // 【翻页中扣帧】PageView 滚动中（含 ballistic）不推帧：4096 大纹理
    // 上传（~50MB GPU）与动画帧抢主线程/GPU =「翻页动画卡一下」（用户
    // 实证）。帧保持 held，滚动结束事件（下方 pageScrollingNotifier
    // listener）会再驱动本方法完成 flush。
    if (_inherited?.pageScrollingNotifier.value ?? false) return;
    if (DateTime.now().difference(_lastZoomActivityAt) < _kZoomIdleForFlush) {
      _hdFlushTimer?.cancel();
      _hdFlushTimer = Timer(_kZoomIdleForFlush, _tryFlushHd);
      return;
    }
    final completer = _progressiveStream?.completer;
    if (completer is! ProgressiveImageCompleter || !completer.hasFrame) return;
    final provider = _progressiveProvider;
    if (provider != null && !identical(_imageProvider, provider)) {
      setState(() => _imageProvider = provider);
    }
    completer.flushHeldFrame();
  }

  /// 翻页滚动结束（pageScrollingNotifier true→false）驱动的 flush 入口。
  void _onPageScrollingChanged() {
    if (mounted && !(_inherited?.pageScrollingNotifier.value ?? true)) {
      _tryFlushHd();
    }
  }

  /// 放大态信号 → 4096 升档请求（p150）。幂等安全，可从多处调用。
  void _requestUltraUpgrade() {
    final completer = _progressiveStream?.completer;
    if (completer is! ProgressiveImageCompleter) return;
    cachePerfEvent('hd-req id=${_photo.id} tw=${kViewerUltraThumbSize}');
    completer.requestUpTo(kViewerUltraThumbSize,
        priority: RequestPriority.viewerHd);
  }
  bool _firedOnReady = false;
  ValueChanged<PhotoViewScaleState>? _scaleStateChangedCallback;
  bool _isZooming = false;
  PhotoViewController _photoViewController = PhotoViewController();
  final _scaleStateController = PhotoViewScaleStateController();
  StreamSubscription<dynamic>? _zoomStreamSubscription;

  /// 切原图防跳变的基准：photo_view scale 是绝对像素比，
  /// 换 provider 时按 preview/final 尺寸比修正。
  double? _initialScale;

  MsImageInfo get _photo => widget.photo;
  ImageRef get _ref =>
      imageRefFromMediaStoreId(_photo.id, extension: extOf(_photo.name));

  @override
  void initState() {
    super.initState();
    _scaleStateChangedCallback = (value) {
      if (widget.shouldDisableScroll != null) {
        widget.shouldDisableScroll!(value != PhotoViewScaleState.initial);
      }
      _isZooming = value != PhotoViewScaleState.initial;
      final state = InheritedDetailPageState.maybeOf(context);
      state?.isZoomedNotifier.value = _isZooming;
      // 【放大升档触发】离散状态信号（无数值判据边界）：进入放大态即
      // 请求 4096（immich loadOriginal 语义的按需版）。幂等——重复
      // zoomedIn/已到位请求被 requestUpTo 吞。放大态与翻页/条/网格
      // 天然互斥（shouldDisableScroll 锁死），p150 不挤任何预取。
      if (value == PhotoViewScaleState.zoomedIn) {
        _requestUltraUpgrade();
      }
      if (!_isZooming) {
        _initialScale = _photoViewController.scale ?? _initialScale;
        state?.zoomTransformNotifier.value = ZoomTransform.identity;
      }
    };
    // 新页初始上报（scaleStateChangedCallback 只在状态变化时触发，新页
    // initial 不回调 → 上一页放大标志跨页残留 = 翻页失灵/沉浸模式不退出）。
    // postFrame 覆盖所有翻页路径（filmstrip 跳转/删除补位/边缘翻页）。
    //
    // 【双击意图重放】SystemChrome 隐藏系统栏的 insets 变化（进沉浸等）
    // 会销毁重建本页 element——旧 State 上刚启动的双击放大动画随旧 core
    // 死亡 =「双击没反应 + 顶/底栏抖动」。新 State 首帧发现本图的待处理
    // 双击意图（1s 窗内）时：恢复 zoom/沉浸上报并重放放大动画，观感 =
    // 放大继续，而非无响应。重放经 _handleTopDoubleTap 会续写 pending
    //（insets 动画期多轮重建逐次重放，时间窗兜底防无限）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final inh = InheritedDetailPageState.maybeOf(context);
      final pending = inh?.doubleTapIntent.takeFor(widget.photo.id);
      final hasPendingZoom = pending != null;
      widget.shouldDisableScroll?.call(hasPendingZoom);
      inh?.isZoomedNotifier.value = hasPendingZoom;
      if (hasPendingZoom) {
        _handleTopDoubleTap(pending);
        return;
      }
      inh?.isZoomedNotifier.value = false;
    });
    _subscribeToZoomStream();
  }

  @override
  void didUpdateWidget(covariant ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.id == widget.photo.id) {
      // 同图（PageView item 按 file.id 建 key，补位移位时 element 跟图走）：
      // 仅 pageIndex 可能变化——双击路由表须跟着挪，否则顶层双击分发到错页。
      final oldIdx = oldWidget.pageIndex;
      final newIdx = widget.pageIndex;
      if (oldIdx != newIdx) {
        final handlers = _inherited?.doubleTapHandlers;
        // 只清自己注册的项：同索引槽位可能已被替换页（删除补位场景）
        // 重新注册——无条件 remove 会误删新 handler，双击从此失灵。
        if (handlers != null &&
            oldIdx != null &&
            handlers[oldIdx] == _handleTopDoubleTap) {
          handlers.remove(oldIdx);
        }
        if (handlers != null && newIdx != null) {
          handlers[newIdx] = _handleTopDoubleTap;
        }
      }
      return;
    }
    // 删除补位：PageView 同 index 复用本 state 但 photo 已换——必须整体
    // 重置三级加载链与缩放，否则沿用旧 provider = 主图停留被删那张。
    // 起始 provider 按 ImageCache 分级取最高可用级：补位图（原下一张）
    // 通常已完成三级加载（原图在 cache）→ 直接原图，同帧显示、无
    // "缩略图回退再渐进"闪烁；未命中则退 512/cell，观感同首次渐进。
    _loadGeneration++;
    // 换图：旧图的重加载延迟作废（gen 校验也会拦，主动取消更省）。
    _heavyLoadTimer?.cancel();
    _heavyLoadTimer = null;
    // 复位三级链状态（复用 State 上残留旧图的 provider/加载 flag 会阻塞
    // _loadLocalImage 对缺失级别的重启加载；miss 时旧 provider 还会继续
    // 显示被删那张图）。_pickCachedProvider 按 cache 重新分级。
    _imageProvider = null;
    _loadedSmallThumbnail = false;
    _loadedLargeThumbnail = false;
    _loadedFinalImage = false;
    _loadingLargeThumbnail = false;
    _loadingFinalImage = false;
    _passThroughProbed = false;
    _passThroughInFlight = false;
    _progressiveStream = null;
    _progressiveProvider = null;
    _hdFlushTimer?.cancel();
    _hdFlushTimer = null;
    _lastZoomActivityAt = DateTime.now();
    _pickCachedProvider(allowCellThumb: false);
    _showingThumbnailFallback = false;
    _firedOnReady = false;
    _initialScale = null;
    _photoViewController.reset();
    _scaleStateController.reset();
    // 补位换图：_isZooming 是本 State 字段，控制器 reset 不会经
    // scaleStateChangedCallback 带回回调（setInvisibly/reset 均不通知）——
    // 被删图若处于放大态，残留 true 会锁 PageView 翻页（shouldDisableScroll）
    // 并禁用上下滑手势。与 initState postFrame 的初始上报对齐，同步复位。
    if (_isZooming) {
      _isZooming = false;
      widget.shouldDisableScroll?.call(false);
      final state = _inherited;
      state?.isZoomedNotifier.value = false;
      state?.zoomTransformNotifier.value = ZoomTransform.identity;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 无条件设 cell 同款缩略图 provider → PhotoView（含 Hero）首帧必存在，
    // push 飞行层才能启动（否则 imageProvider 未就绪时 build 的是 loading，
    // 无 Hero → flight 不启动 → 黑屏后加载，真机复现）。
    // ImageCache 命中（网格刚显示过 cell）立即有图；miss 时 loadingBuilder
    // 显示占位，大图渐进。
    // 注意：_cellThumbSize 依赖 MediaQuery——initState 里调用会触发
    // dependOnInheritedWidgetOfExactType assert（红屏）；didChangeDependencies
    // 在 initState 之后、首帧 build 之前执行，Hero 首帧不受影响。
    if (_imageProvider == null) {
      _inherited = InheritedDetailPageState.maybeOf(context);
      // 【防降级·State 重建场景】当前页且 4096 渐进 completer 仍存活在
      // 大图缓存（insets/沉浸切换销毁重建 element，completer 不随 State
      // 死）：直接恢复 Progressive 显示，不落 1152 档——降级再恢复 =
      // 「图闪一下变糊又变清」。恢复失败（缓存真被逐）回落原分级 pick。
      var recovered = false;
      if (_isCurrentPage) {
        final progressive = _attachProgressive();
        final completer = _progressiveStream?.completer;
        if (progressive != null &&
            completer is ProgressiveImageCompleter &&
            completer.hasFrame) {
          _imageProvider = progressive;
          _loadedFinalImage = true;
          _loadedSmallThumbnail = true;
          _loadedLargeThumbnail = true;
          recovered = true;
        }
      }
      if (!recovered) {
        _pickCachedProvider();
      }
      _notifyReadyOnce();
    } else {
      _inherited = InheritedDetailPageState.maybeOf(context);
    }
    // 翻页升级链的即时驱动（见 _onSelectedChanged doc）：sel listener 必须挂
    // ——快甩 ballistic ~700ms 期间 ZoomableImage.build 不会重跑（外层
    // ValueListenableBuilder 只包 HeroMode，sel 变化不触发本 State.build），
    // 不监听的话显示升级被压到滚动停止后 = 翻页糊图期恒等于惯性时长
    //（真机实测恒定 ~720ms，2026-09-06）。先摘再加：didChangeDependencies
    // 可重跑（MediaQuery 变化），防重复挂载。
    _inherited?.selectedIndexNotifier.removeListener(_onSelectedChanged);
    _inherited?.selectedIndexNotifier.addListener(_onSelectedChanged);
    final idx = widget.pageIndex;
    if (idx != null) {
      _inherited?.doubleTapHandlers[idx] = _handleTopDoubleTap;
    }
  }

  /// 本页成为当前显示页的瞬间（selectedIndexNotifier == pageIndex）：
  /// 立即发起显示升级链（盘缓存探测 / heavy 加载），不等 build 潮。
  ///
  /// 为什么必须监听：升级链（_probePassThrough / _fireHeavyLoads）挂在
  /// build() 里，而 PageView 翻页时 sel 变化只重建外层 HeroMode 壳——
  /// ZoomableImage.build 不重跑；下一次全页 build 要等 PageView 滚动
  /// 完全停止（_pageGapVisible setState），FastScrollPhysics(speedFactor 4)
  /// 甩动惯性 ~700ms = 「翻页糊图 0.5~1s」根因（真机 zbuild 时间线实证：
  /// page→build潮恒定 715-725ms，updfl 与潮同刻）。
  void _onSelectedChanged() {
    if (!mounted || !_isCurrentPage) return;
    // 【实验·原图直出·翻页让位】上一页/更早页的在队 4096 立即压到队列
    // 最低档：原图直出后每页一个 400-900ms 长任务，连翻 N 页不压级 =
    // 当前页排队等前面 N-1 页份。先压级再 attach——本页自己的 4096 尚
    // 未入队（下方补建发起 p50 恒排最前）；在跑的不可中断（MethodChannel
    // 语义），最坏等一份解码时长。
    ServicePolicy.instance.deprioritizeQueued(
      (t) => t.tag?.startsWith('full4096:') ?? false,
    );
    // 【pick 短路页的渐进补建】1152 已就绪（pick 命中 full，_loadedFinalImage
    // = true）的页在成为当前页时必须补上 progressive 接线 + 4096 发起——
    // 否则该页恒糊（预取就绪页的短路，真机实证）。直通/heavy 路径的页由
    // _updateViewWithFinalImage 内的 _attachProgressive 覆盖（幂等）。
    if (_loadedFinalImage && _progressiveStream == null) {
      final progressive = _attachProgressive();
      if (progressive != null) {
        setState(() => _imageProvider = progressive);
      }
    }
    if (_loadedFinalImage || _loadingFinalImage) return;
    // 掠过页 p120 直通在途时翻到本页：立即提速到当前页级（不等 150ms
    // heavy 窗的 bump 分支——「停稳即清晰」不被掠过页语义拖慢；同 key
    // 合并下 bump 改的就是那一个在队任务）。
    if (_passThroughInFlight) {
      _bumpFullToPriority(
        computeViewerTargetWidth(
          MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context),
        ),
        RequestPriority.viewerImage,
      );
    }
    // 与 build 同链（probe 直通 → p50 full → updfl），一图一次守卫在
    // _probePassThrough 内（_passThroughProbed）。
    _loadLocalImage(context);
  }

  /// 初始 provider 按 ImageCache 分级取最高可用级（原图 > 512 > cell）。
  /// 删除补位/翻页切到已加载过的图时，若从 cell 缩略图起步再升级原图，
  /// 会有一帧"糊图→清晰图"跳变闪烁；cache 命中直接同帧显示最高级。
  /// didChangeDependencies（新 element）与 didUpdateWidget（复用 element）
  /// 共用。
  ///
  /// ⚠️ 必须判「已完成」（statusProvider().completed）而非 containsKey：
  /// _openViewer 在 push 前发起原图 precache，push 时 cache 里已有 full 的
  /// 【pending】条目——containsKey 误判为可用 → 起始 provider 指向解码中
  /// 的原图 → photo_view wrapper 的 _loading 分支【没有 Hero】（heroAttributes
  /// 挂在 PhotoViewCore 上）→ HeroController 首帧找不到目标端 Hero →
  /// flight 不启动，第一次打开只剩路由 200ms 淡入（无飞行动画的根因）。
  /// 只有「已完成」条目 resolve 才同步回调（synchronousCall）→ 首帧
  /// _loading=false → Hero 在树。pending 一律不选，回落 cell（正在网格
  /// 显示中 = live 条目，必已完成）。
  void _pickCachedProvider({bool allowCellThumb = true}) {
    final _tIn = DateTime.now().microsecondsSinceEpoch ~/ 1000;
    debugPrint('[B] pick-in t=$_tIn');
    final full = buildImageProvider(
      _ref,
      targetWidth: computeViewerTargetWidth(
        MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context),
      ),
    );
    // large 用【等比】请求框（squareCrop:false）：childSize 宽高比与原图
    // 一致 → 补位/慢图过渡期 contain 视觉与原图完全相同（仅清晰度差），
    // 原图到货后无大小跳变。方形版（centerCrop 裁切 + 方形 childSize）会让
    // 过渡期横图视野变小/竖图裁切放大，宽高比交替的序列（竖→横→竖连续
    // 删除）频繁可见（真机实证）。
    final large = buildThumbnailProvider(
      _ref,
      size: kViewerLargeThumbSize,
      squareCrop: false,
    );
    final cell = buildThumbnailProvider(_ref, size: _cellThumbSize(), squareCrop: true);
    // mid900 自产档（detail_page 条快甩 dist1~2 预取，kViewerMidThumbSize
    // 同 key）：掠过页首帧 0.625× 屏宽——MediaStore thumb 640 尺寸不可控
    //（240 mini / 360 欠采样），900 自产 blob 才是「过渡不糊」的保障档。
    final mid = buildImageProvider(
      _ref,
      targetWidth: 900,
      priority: RequestPriority.prefetchFull,
    );
    bool completed(ImageProvider p) => _probeSyncComplete(p);
    String picked = 'none';
    if (completed(full)) {
      picked = 'full';
      // 1152 已就绪（预取/回看命中）：直接显示 full。渐进接线和 4096 发起
      // 由 [_onSelectedChanged] 补（本页成为当前页时）——【不可在 pick 里
      // attach】：pick 在预建页（PageView ±1）也跑，预建页 attach 会让
      // 快甩/翻页途中的每页都发 4096(p150)——多个不可抢占任务占满 6 门
      // → 条 p100/掠过页 p50/网格 p200 全部饿死 = 大图黑屏 + 条缩略图
      // 重复 + 返回网格占位（真机实证三连回归）。
      _imageProvider = full;
      _loadedFinalImage = true;
      _loadedSmallThumbnail = true;
      _loadedLargeThumbnail = true;
    } else if (completed(mid)) {
      picked = 'mid900';
      _imageProvider = mid;
      _loadedLargeThumbnail = true;
      _loadedSmallThumbnail = true;
    } else if (completed(large)) {
      picked = 'large512';
      _imageProvider = large;
      _loadedLargeThumbnail = true;
      _loadedSmallThumbnail = true;
    } else if (allowCellThumb) {
      // strip 兜底级：与底栏缩略图条条目同一 key（kFilmstripThumbLoadSize）——
      // 条滚过的图必已完成解码，同步命中。快甩到网格未渲染过的远处时
      //（cell 无缓存）主图区从「黑屏等解码」变「糊图即显」，停稳后 512/
      // 原图到达替换。等比解码（fit-inside/长图等比路径），aspect 与原图
      // 一致，无 contain 大小跳变。
      final strip = buildThumbnailProvider(
        _ref,
        size: kFilmstripThumbLoadSize,
        squareCrop: true,
      );
      if (completed(strip)) {
        picked = 'strip96';
        _imageProvider = strip;
        _loadedSmallThumbnail = true;
      } else if (PaintingBinding.instance.imageCache.containsKey(cell)) {
        // cell 兜底：网格显示过/正在加载（含 pending）才落——无条件赋值会
        // 让 PhotoView resolve 缓存外 cell 即发起解码（见 _probeSyncComplete
        /// 守卫注释的洪泛链）。
        picked = 'cell';
        _imageProvider = cell;
        _loadedSmallThumbnail = true;
      }
      // 两者皆无：保持 null 走 loading 分支（Hero 常在），重加载延迟起跳
      // 后 full(p50) 在无拥塞队列 ~200ms 出图。
    }
    // 补位路径（allowCellThumb=false）full/large 均未就绪时不落方形 cell：
    // 保持 null 走 loadingBuilder（按 _photo 宽高比显示占位框，无裁切
    // 变形），large 很快到货（翻页预加载已发起）替换——方形裁剪图的
    // childSize 会造成过渡期大小跳变。
    _loadingLargeThumbnail = false;
    // 保持 false：让 _loadLocalImage 正常启动缺失级别的加载（若置 true
    // 会阻塞对应分支的 precache，又没有实际加载在跑 → 缩略图永不清晰）。
    _loadingFinalImage = false;
    cachePerfEvent('pick id=${_photo.id} L=$picked${allowCellThumb ? '' : ' noCell'}');
    debugPrint('[B] pick-out t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}');
  }

  /// 探测 provider 在 ImageCache 中是否已有【已完成】的解码条目。
  ///
  /// ⚠️ 只读探测——[containsKey] 前置守卫是关键：resolve 对缓存外 provider
  /// 会经 ImageCache.putIfAbsent **发起真实解码**（真机打点实证：快甩时
  /// 每个途经页在 _pickCachedProvider 探测 full/512/strip96 三个 key 就地
  /// 灌入 3 个无观众请求，队列深至 431-508，当前页 FIFO 排队 1.7-2s =
  /// 「主图黑屏/第一张转圈」的根因）。无条目直接 false 不发起；有条目
  /// （含 pending，如 _openViewer push 前 precache）resolve 只挂 listener。
  ///
  /// ImageCache 无公开的 pending/completed 状态查询（statusProvider 非公开
  /// API），利用机制本身判定：已完成 completer 的 addListener 会【同步】
  /// 回调（synchronousCall=true）；pending 条目不会同步回调 → false。探测
  /// listener 无论同步/异步/出错触发都立即摘除，不留悬挂监听（挂着的
  /// listener 会阻止 completer 释放）。
  bool _probeSyncComplete(ImageProvider provider) {
    // containsKey 不查 liveImages：切后台 onTrimMemory→imageCache.clear()
    // 后，在屏图的 completer 仍在 liveImages 里活着，但 containsKey=false
    // → 探测假 miss（切后台回来首开黑块/网格全冷的根因）。statusForKey
    // 含 live 态；live 命中时 resolve 会在 putIfAbsent 内零解码复活该
    // completer（同步出图），无新解码副作用。
    final status = PaintingBinding.instance.imageCache.statusForKey(provider);
    if (!status.live && !status.keepAlive && !status.pending) {
      return false; // 三态皆空：不发起新加载
    }
    final stream = provider.resolve(const ImageConfiguration());
    final completer = stream.completer;
    if (completer == null) return false;
    var syncDone = false;
    late final ImageStreamListener probe;
    probe = ImageStreamListener(
      (_, synchronousCall) {
        if (synchronousCall) syncDone = true;
        completer.removeListener(probe);
      },
      onError: (_, _) => completer.removeListener(probe),
    );
    completer.addListener(probe);
    return syncDone;
  }

  /// 顶层双击（global）→ core 局部坐标 → 精准缩放。
  void _handleTopDoubleTap(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    // 【双击意图重放】记录待处理意图（State 持有单例，见 initState 注释）：
    // 本 core 若随后被 element 重建（insets 变化）杀死，新 State 首帧凭
    // 此重放放大。
    final inh = _inherited ?? InheritedDetailPageState.maybeOf(context);
    final intent = inh?.doubleTapIntent;
    if (intent != null) {
      // 方向记录（见 DoubleTapIntentHolder.zoomIn doc）：当前已放大 →
      // 本次双击是缩小意图（重建后不重放）；当前 initial → 放大意图。
      final zoomed = _scaleStateController.scaleState !=
          PhotoViewScaleState.initial;
      intent
        ..global = globalPosition
        ..photoId = _photo.id
        ..at = DateTime.now()
        ..zoomIn = !zoomed;
    }
    _coreKey.currentState?.doubleTapZoom(box.globalToLocal(globalPosition));
  }

  /// 本页是否为当前显示页（PageView/条联动 selectedIndex）：预建途经页
  /// 跳过重加载与盘缓存探测——push 窗口请求收敛（对齐 immich：打开只发
  /// 当前页请求，邻页翻到时再发）。翻到时 PageView 为该页重新 build →
  /// 探测与 timer 自然重排。信息缺失（pageIndex/inherited 不可得）不拦截。
  bool get _isCurrentPage {
    final sel = _inherited?.selectedIndexNotifier.value;
    final idx = widget.pageIndex;
    if (sel == null || idx == null) return true;
    return sel == idx;
  }

  /// 回退/加载态 Hero 的原比例紧框：cover 展开式飞行（immich，shuttle
  /// 取网格端方形 cover child）要求 viewer 端 hero rect 恒为原比例
  /// contain 框（与 PhotoViewCore 态的 hero rect 同尺寸，飞行终点框与
  /// 落位图框一致）——Center 会被父约束撑成全屏 → 飞行终点错位。
  /// AspectRatio 在任意父约束下取最大等比容纳框；宽高元数据缺失兜底居中。
  Widget _aspectHeroFrame(Widget child) {
    final w = _photo.width;
    final h = _photo.height;
    if (w <= 0 || h <= 0) return Center(child: child);
    return AspectRatio(aspectRatio: w / h, child: Center(child: child));
  }

  void _subscribeToZoomStream() {
    _zoomStreamSubscription = _photoViewController.outputStateStream.listen((
      value,
    ) {
      if (!mounted) return;
      final state = InheritedDetailPageState.maybeOf(context);
      if (value.scale == null) return;
      // 替换时机闸：缩放活跃即暂缓 flush（帧照常解，停稳 250ms 后推）。
      _lastZoomActivityAt = DateTime.now();
      if (!_isZooming) {
        _initialScale = value.scale;
        state?.zoomTransformNotifier.value = ZoomTransform.identity;
        return;
      }
      _initialScale ??= value.scale;
      state?.zoomTransformNotifier.value = ZoomTransform(
        scale: value.scale! / _initialScale!,
        offset: value.position,
      );
    });
  }

  @override
  void dispose() {
    _inherited?.selectedIndexNotifier.removeListener(_onSelectedChanged);
    _inherited?.pageScrollingNotifier.removeListener(_onPageScrollingChanged);
    if (_routeListenerAttached) {
      ModalRoute.of(context)?.animation?.removeStatusListener(_onHdRouteStatus);
    }
    _hdFlushTimer?.cancel();
    _hdFlushTimer = null;
    if (kLiveViewerProviders[_photo.id] == _imageProvider) {
      kLiveViewerProviders.remove(_photo.id);
    }
    // 路过页被扫过销毁：重加载延迟取消（快甩守门的关键路径——timer 内
    // gen/mounted 双校验本也能拦，主动取消少一次唤醒）。
    _heavyLoadTimer?.cancel();
    _heavyLoadTimer = null;
    final idx = widget.pageIndex;
    final handlers = _inherited?.doubleTapHandlers;
    // 只清自己注册的项：删除补位时本 State 的 dispose 在帧末 finalizeTree
    // 执行，晚于替换页 didChangeDependencies 的注册——无条件 remove 会把
    // 替换页刚注册的 handler 清掉，当前页及相邻页顶层双击静默失灵。
    if (idx != null && handlers != null && handlers[idx] == _handleTopDoubleTap) {
      handlers.remove(idx);
    }
    _zoomStreamSubscription?.cancel();
    _photoViewController.dispose();
    _scaleStateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // [B] 排查打点：本页 build 潮时刻 + 当时选中页（selectedIndex 已更新
    // 而本页 build 晚到 = 显示升级的真正起点延迟）。
    debugPrint(
      '[B] zbuild idx=${widget.pageIndex} sel=${_inherited?.selectedIndexNotifier.value} '
      'prov=${_imageProvider.runtimeType} '
      't=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
    );
    _loadLocalImage(context);
    // 飞行层图源注册（见 kLiveViewerProviders doc）：正在显示的 provider，
    // Hero shuttle 第一优先级取用（同步出图，不受 evict/LRU 影响）。
    if (_imageProvider != null) {
      kLiveViewerProviders[_photo.id] = _imageProvider!;
    }
    Widget content;

    if (_imageProvider != null) {
      content = PhotoViewGestureDetectorScope(
        axis: Axis.vertical,
        child: PhotoView(
          // 切原图时 key 变化强制重建 PhotoView，让调整后的 zoom 生效
          //（ente 同款；gaplessPlayback 让同尺寸替换不闪底层）。
          key: ValueKey(_loadedFinalImage),
          // 双击由 detail_page 顶层捕获分发（ballistic 中 ignorePointer
          // 屏蔽页内 tap）→ core 内不注册双击手势，防双重触发。
          enableDoubleTap: false,
          coreKey: _coreKey,
          imageProvider: _imageProvider,
          controller: _photoViewController,
          filterQuality: FilterQuality.high,
          scaleStateController: _scaleStateController,
          scaleStateChangedCallback: _scaleStateChangedCallback,
          minScale: PhotoViewComputedScale.contained,
          onEdgeX: widget.onEdgeX,
          gaplessPlayback: true,
          heroAttributes: PhotoViewHeroAttributes(
            tag: 'photo_${_photo.id}',
            transitionOnUserGestures: true,
          ),
          backgroundDecoration:
              (widget.backgroundDecoration as BoxDecoration?) ??
              const BoxDecoration(color: Colors.black),
          loadingBuilder: (context, event) {
            // 与 Hero 动画期图片在屏尺寸一致：loading 层按 contain 尺寸渲染，
            // 避免飞行中占位尺寸跳变（ente 同款公式）。
            final screenDimensions = MediaQuery.sizeOf(context);
            final screenWidth = screenDimensions.width;
            final screenHeight = screenDimensions.height;
            final aspectRatioOfScreen = screenWidth / screenHeight;
            final aspectRatioOfImage = _photo.width / _photo.height;
            final double screenRelativeImageWidth;
            final double screenRelativeImageHeight;
            if (aspectRatioOfImage > aspectRatioOfScreen) {
              screenRelativeImageWidth = screenWidth;
              screenRelativeImageHeight = screenWidth / aspectRatioOfImage;
            } else if (aspectRatioOfImage < aspectRatioOfScreen) {
              screenRelativeImageHeight = screenHeight;
              screenRelativeImageWidth = screenHeight * aspectRatioOfImage;
            } else {
              screenRelativeImageWidth = screenWidth;
              screenRelativeImageHeight = screenHeight;
            }
            // 原比例紧框（不套 Center——Center 会把 hero rect 撑成全屏，
            // cover 展开式飞行终点错位，见 _aspectHeroFrame）：本框即
            // wrappers loading 分支 Hero 的 rect，与 PhotoViewCore 态一致。
            // 占位用灰底图框（ThumbnailPlaceHolder）而非透黑：快甩掠过页
            // 连 strip96 都 miss 时（真机 L=none 实证），纯黑底 + 黑框 =
            // 「穿插闪黑」；灰框保留「这里有张图」的空间感。
            return SizedBox(
              width: screenRelativeImageWidth,
              height: screenRelativeImageHeight,
              child: const ThumbnailPlaceHolder(
                color: Color(0xFF161616),
              ),
            );
          },
        ),
      );
    } else if (_showingThumbnailFallback) {
      // Hero 必须常在（与 PhotoView heroAttributes 同 tag）：原图解码失败的
      // 回退态直接 pop 时，无源端 Hero = flight 不启动（返回动画被吞）。
      // 飞行 shuttle 由网格端 Hero 的 flightShuttleBuilder 提供（toHero.child
      // = 网格缩略图），这里只需 tag 配对存在。
      content = Hero(
        tag: 'photo_${_photo.id}',
        transitionOnUserGestures: true,
        // 原比例紧框（_aspectHeroFrame）：hero rect 与 PhotoViewCore 态
        // 同为原比例 contain 框，cover 展开式飞行的终点框不错位。
        child: _aspectHeroFrame(
          Image(
            // 等比（同 large key），错误兜底显示也不裁切变形。
            image: buildThumbnailProvider(
              _ref,
              size: kViewerLargeThumbSize,
              squareCrop: false,
            ),
            fit: BoxFit.contain,
            // 审查实证 P2：full 失败后若 large 也读不出（文件彻底损坏），
            // 无 errorBuilder 会渲染空白 Hero 飞行；gaplessPlayback 避免
            // 相同 key 内容替换闪底层。
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const _DelayedLoadingIndicator(),
          ),
        ),
      );
    } else {
      // 加载态（连 strip/cell 都未就绪的极短窗口）：同上补 Hero——快甩到
      // 远处立即返回时源端有 Hero，pop 飞行照常起飞（显示网格缩略图飞回）。
      // 同样用 _aspectHeroFrame 原比例紧框保终点框一致。
      content = Hero(
        tag: 'photo_${_photo.id}',
        transitionOnUserGestures: true,
        child: _aspectHeroFrame(const _DelayedLoadingIndicator()),
      );
    }

    // 垂直手势（ente 原版）：缩放中禁用；下滑关闭、上滑详情。阈值 8px。
    final GestureDragUpdateCallback? verticalDragCallback = _isZooming
        ? null
        : (d) {
            if (!_isZooming) {
              if (d.delta.dy > _kDragSensitivity) {
                if (widget.onSwipeDown != null) {
                  widget.onSwipeDown!();
                } else {
                  unawaited(Navigator.maybePop(context));
                }
              } else if (d.delta.dy < (_kDragSensitivity * -1)) {
                widget.onSwipeUp?.call();
              }
            }
          };
    return GestureDetector(
      onVerticalDragUpdate: verticalDragCallback,
      child: Stack(
        children: [
          content,
          // [模拟器调试] 双击入口按钮：adb input 的两次 tap 间隔超双击窗口，
          // 无法自动化复刻「反复双击」场景——debug 包专用悬浮按钮直接调
          // core 的 doubleTapZoom（与顶层双击分发同一入口），二态切换放大/缩回。
          if (const bool.fromEnvironment('debug_hd_btn'))
            Positioned(
              right: 24,
              bottom: 120,
              child: IgnorePointer(
                ignoring: false,
                child: FloatingActionButton(
                  mini: true,
                  backgroundColor: const Color(0xCC6750A3),
                  onPressed: () {
                    cachePerfEvent('dbgtap zoom id=${_photo.id}');
                    _coreKey.currentState
                        ?.doubleTapZoom(const Offset(360, 700));
                  },
                  child: const Icon(Icons.zoom_in),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _notifyReadyOnce() {
    if (_firedOnReady) return;
    _firedOnReady = true;
    scheduleMicrotask(() {
      if (!mounted) return;
      widget.onFullLoaded?.call(_photo.id);
    });
  }

  /// 当前页「盘缓存直通」：full exists 探测命中即 p50 发起（盘就绪
  /// decodeByteArray 22-46ms，停稳即清晰）；miss 零请求零副作用，150ms
  /// 延迟窗路径兜底。洪泛防线：只有全库预缓存就绪的图才发起，ImageCache
  /// 峰值由 detail_page 的 _trimDistantViewerCache 翻页窗口兜底。每图一次
  ///（_passThroughProbed），换图随 generation 复位。
  ///
  /// ⚠️ 快甩掠过页/当前页的「清晰起步档」（等比 640）**不在这里发**——
  /// 页到达才发起的解码（640 ~80ms / full 30-45ms）永远追不上 14-30ms/页
  /// 的甩速（真机日志三轮实证：pick 恒落 strip96、wait 被自身洪泛推高）。
  /// 由 detail_page 的 _prefetchStripAhead 在甩动方向上**提前** 3 档预热，
  /// 页到达时 _pickCachedProvider 同步命中 large 档 = 第一帧即清晰。
  void _probePassThrough(BuildContext context) {
    if (!Platform.isAndroid) return; // 盘缓存在 MediaStore 侧
    if (!_isCurrentPage) return;
    if (_passThroughProbed) return;
    if (_loadedFinalImage || _loadingFinalImage) return;
    if (_photo.mime == 'image/gif') return; // GIF 走 readBytes 多帧，不读盘缓存
    _passThroughProbed = true;
    final gen = _loadGeneration;
    final tw = computeViewerTargetWidth(
      MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context),
    );
    // full 已在 ImageCache completed（预取/回看命中）：零等待直接升级显示。
    // 盘缓存探测是 channel 往返，解码洪峰下回调可延迟数百 ms（真机实测
    // page→pass hit 369-743ms，期间 full 明明已在缓存）——缓存命中场景
    // 无需任何探测，build 同步帧即上屏。
    final cachedFull = buildImageProvider(_ref, targetWidth: tw);
    if (_probeSyncComplete(cachedFull)) {
      _loadingFinalImage = true;
      _updateViewWithFinalImage(cachedFull);
      return;
    }
    // [PROBE] 排查打点：缓存命中失败的条目三态（live=在屏 / keep=缓存持有
    // / pend=解码在途）——full 明明解码完成（[SP] 行）却未同步命中时，
    // 此行指认条目真实状态。
    final st = PaintingBinding.instance.imageCache.statusForKey(cachedFull);
    debugPrint(
      '[PROBE] id=${_photo.id} miss live=${st.live} keep=${st.keepAlive} '
      'pend=${st.pending} t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
    );
    // 探测在即：把队列中本图 full 任务（无论谁先入队——150ms 窗的
    // _fireHeavyLoads / onPageChanged 的 p250 邻居预取）升到当前页级 p50。
    // precacheImage 同 key 只合并 listener，改不了先入队任务的优先级
    //（onPageChanged 同步段的 p250 恒早于下一帧 build 的本探测 → 不 bump
    // 则 full 以预取级排在 640 清晰层 p200 后面，当前页 full 反而最后跑）。
    // bump 只动未启动任务，已跑/已完任务不受影响。
    _bumpFullToPriority(tw, RequestPriority.viewerImage);
    // ImageConfiguration 在 async gap 前捕获：exists 回调里预热不再触碰
    // BuildContext（precacheImage 的 context 也只在同步首行构 config 用）。
    final config = createLocalImageConfiguration(context);
    // [PROBE] 排查打点：exists channel 往返时长（同步化修复后应 ~几 ms；
    // 数百 ms = Kotlin 侧仍被阻塞）。
    final existsT0 = DateTime.now().microsecondsSinceEpoch ~/ 1000;
    MediaStoreChannel()
        .fullCacheExists(_photo.id, targetWidth: tw)
        .then((hit) {
      debugPrint(
        '[PROBE] exists-back id=${_photo.id} dt=${(DateTime.now().microsecondsSinceEpoch ~/ 1000) - existsT0}ms '
        'hit=$hit t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
      );
      if (!mounted || gen != _loadGeneration) return;
      if (!hit || _loadedFinalImage || _loadingFinalImage) return;
      _loadingFinalImage = true;
      _passThroughInFlight = true;
      cachePerfEvent('pass hit id=${_photo.id} tw=$tw');
      final full = buildImageProvider(
        _ref,
        targetWidth: tw,
        priority: RequestPriority.viewerImage,
      );
      _precacheWithConfig(full, config, probeTag: 'pass id=${_photo.id}')
          .then((_) {
        if (gen != _loadGeneration) return;
        _passThroughInFlight = false;
        if (!mounted) return;
        // 解码失败时这里同样会到（precacheImage 语义：错误也 complete，
        // 不抛）——与 _fireHeavyLoads 的 full 分支同款，坏 provider 由
        // PhotoView 错误态兜底（源图损坏场景，无图可显示）。
        if (!_loadedFinalImage) {
          _updateViewWithFinalImage(full);
        }
      });
    });
  }

  /// 把本页 full 的队列任务（任意发起者）升到 [priority]。precacheImage
  /// 同 key 合并 listener 改不了已入队任务的优先级——bump 是唯一插队手段
  ///（service_policy.bumpPriority doc）。tag 与 _loadRawImage 的入队 tag
  /// 同格式（full$tw:$id）。
  void _bumpFullToPriority(int tw, int priority) {
    ServicePolicy.instance.bumpPriority(
      (t) => t.tag == 'full$tw:${_photo.id}',
      priority,
    );
  }

  /// precacheImage 的 context-free 变体（语义对齐 SDK：resolve + 首帧/
  /// 错误均 complete + 帧末摘 listener），供 async gap 后预热——gap 前把
  /// ImageConfiguration 捕获好，回调里不再触碰 BuildContext。
  /// [probeTag]：[PROBE] 打点标识（onImage 到达时刻/是否同步）。
  Future<void> _precacheWithConfig(
    ImageProvider provider,
    ImageConfiguration config, {
    String? probeTag,
  }) {
    final completer = Completer<void>();
    final t0 = probeTag == null
        ? 0
        : DateTime.now().microsecondsSinceEpoch ~/ 1000;
    final stream = provider.resolve(config);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo? image, bool sync) {
        if (probeTag != null) {
          debugPrint(
            '[PROBE] onImage $probeTag sync=$sync dt=${t0 == 0 ? -1 : (DateTime.now().microsecondsSinceEpoch ~/ 1000) - t0}ms '
            't=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
          );
        }
        if (!completer.isCompleted) completer.complete();
        // 帧末再摘 listener（给 ImageCache live 追踪留一帧窗口，同 SDK）。
        SchedulerBinding.instance.addPostFrameCallback((_) {
          image?.dispose();
          stream.removeListener(listener);
        });
      },
      onError: (Object e, StackTrace? st) {
        // 对齐 precacheImage：错误也 complete，不作异常抛出。
        if (!completer.isCompleted) completer.complete();
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// 三级加载（ente 同款顺序）：
  /// 1) cell 同款缩略图（cache 命中首帧，同步廉价）→ 2) 大缩略图(512) →
  /// 3) 下采样原图。2/3 为重加载，延迟 [_kHeavyLoadDelay] 起跳（快甩路过
  /// 页零入队，见其 doc）；已起跳/终态由 _loading 标志幂等，不再重排 timer。
  void _loadLocalImage(BuildContext context) {
    // 【pick 短路页渐进补建·build 驱动兜底】覆盖「本页已是 sel 且 pick
    // 命中过」的首开场景（无 sel 变化，_onSelectedChanged 不触发）。幂等
    // （_attachProgressive 内 null 守卫），预建页被 _isCurrentPage 拦。
    // 直接赋字段（本方法在 build 中被调，不能 setState——本帧 build 用
    // 新 provider 渲染，渐进 provider 首帧同步偷 1152 帧视觉无缝）。
    if (_loadedFinalImage && _progressiveStream == null && _isCurrentPage) {
      _imageProvider = _attachProgressive() ?? _imageProvider;
    }
    _probePassThrough(context);
    if (!_loadedSmallThumbnail &&
        !_loadedLargeThumbnail &&
        !_loadedFinalImage) {
      final cellThumb = buildThumbnailProvider(_ref, size: _cellThumbSize(), squareCrop: true);
      // 同 _probeSyncComplete：containsKey 漏 live 态（切后台 clear 后在屏
      // 图仍活），statusForKey 三态任一命中即可安全 resolve。
      final cellStatus =
          PaintingBinding.instance.imageCache.statusForKey(cellThumb);
      final cellHit =
          cellStatus.live || cellStatus.keepAlive || cellStatus.pending;
      cachePerfProbe(cacheLevelThumb(_cellThumbSize(), true), cellHit);
      if (cellHit) {
        _imageProvider = cellThumb;
        _loadedSmallThumbnail = true;
        _notifyReadyOnce();
      }
    }
    if (_heavyLoadTimer != null) return;
    // 已起跳或已就绪（含失败终态：不复位标志防无限重试，见 catchError）。
    if (_loadingLargeThumbnail || _loadingFinalImage || _loadedFinalImage) {
      return;
    }
    final gen = _loadGeneration;
    _heavyLoadTimer = Timer(_kHeavyLoadDelay, () {
      _heavyLoadTimer = null;
      if (!mounted || gen != _loadGeneration) return;
      _fireHeavyLoads(context);
    });
  }

  /// 延迟窗结束真正发起 512 + 原图 precache（页仍在树上 = 观众还在）。
  void _fireHeavyLoads(BuildContext context) {
    debugPrint('[B] heavy-in t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}');
    // 【邻页 1152 预解码·2026-09-10】dist==1 预建页也预解码 1152 显示档：
    // 此前 heavy 链仅当前页，慢拖露出邻页只有 cell/低档，翻到才发起
    // 1152 =「露出低清、挪动中突然变清晰」的拖动抖动感（用户实证）。
    // p250 让位当前页一切请求（p50/p100 恒先）；快甩途经页同样满足
    // dist==1 但高速掠过不可见，p250 排队无害。4096 渐进接线仍仅当前页
    //（_updateViewWithFinalImage 的 _isCurrentPage 分支不动，快甩洪泛
    // 防线不动）。
    final sel = _inherited?.selectedIndexNotifier.value;
    final idx = widget.pageIndex;
    final isCur = _isCurrentPage;
    final isNeighbor = !isCur &&
        sel != null &&
        idx != null &&
        (idx - sel).abs() == 1;
    if (!isCur && !isNeighbor) return;
    // 512 large：仅当前页（邻页直接 1152 档，无需低清过渡档）。
    if (isCur &&
        !_loadingLargeThumbnail &&
        !_loadedLargeThumbnail &&
        !_loadedFinalImage) {
      _loadingLargeThumbnail = true;
      final gen = _loadGeneration;
      // 等比 512（与 _pickCachedProvider 的 large 同 key，翻页预加载即补位
      // 缓存命中）：过渡期 childSize 宽高比与原图一致，无大小跳变。
      final large = buildThumbnailProvider(
        _ref,
        size: kViewerLargeThumbSize,
        squareCrop: false,
      );
      precacheImage(large, context)
          .then((_) {
            if (!mounted || gen != _loadGeneration) return;
            if (!_loadedFinalImage) {
              setState(() {
                _imageProvider = large;
                _loadedLargeThumbnail = true;
              });
              _notifyReadyOnce();
            }
          })
          .catchError((_) {
            // 失败保持"已尝试"终态（不复位 _loadingLargeThumbnail）：
            // 复位会让下一帧 build 重新 precacheImage → 再失败 → 无限
            // 重试循环（setState 风暴 + 反复解码空转）。重试仅由换图
            //（didUpdateWidget generation++ 复位全部加载标志）触发。
          });
    }
    final fullTw = computeViewerTargetWidth(
      MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context),
    );
    if (isNeighbor) {
      // 邻页：p250 预解码 1152；完成走 _updateViewWithFinalImage 的
      // 「预建页只换 1152 显示」分支（非当前页不 attach 4096）。
      if (!_loadingFinalImage && !_loadedFinalImage) {
        _loadingFinalImage = true;
        final gen = _loadGeneration;
        final full = buildImageProvider(
          _ref,
          targetWidth: fullTw,
          priority: RequestPriority.prefetchFull,
        );
        precacheImage(full, context)
            .then((_) {
              if (!mounted || gen != _loadGeneration) return;
              if (!_loadedFinalImage) {
                _updateViewWithFinalImage(full);
              }
            })
            .catchError((Object e) {
              if (gen != _loadGeneration) return;
              if (mounted) {
                setState(() => _showingThumbnailFallback = true);
                _notifyReadyOnce();
              }
            });
      }
      return;
    }
    if (_passThroughInFlight) {
      // 直通在途而页已存活过延迟窗（停稳/翻页预建）：把队列中该图的
      // 直通任务升级到当前页级插队（探测入口已 bump 过一次，此处是
      // 防御性兜底——快甩积压的其它任务不再排在它前面，「停稳即清晰」
      // 不回归）。已在跑的不动（盘读 22-46ms 本就秒完）。
      _bumpFullToPriority(fullTw, RequestPriority.viewerImage);
    } else if (!_loadingFinalImage && !_loadedFinalImage) {
      _loadingFinalImage = true;
      final gen = _loadGeneration;
      // [PROBE] 排查打点：full 重加载起跳（150ms 延迟窗后）——与 page 行
      // 的间隔 = 当前页 build 潮实际到达本方法的延迟。
      debugPrint(
        '[PROBE] fire-full id=${_photo.id} t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}',
      );
      final full = buildImageProvider(
        _ref,
        targetWidth: fullTw,
      );
      // 同 key 合并防御（见 _probePassThrough 的 bump 注释）：早先 p250
      // 预取任务可能已带着本 key 在队，precache 改不了它的优先级。
      _bumpFullToPriority(fullTw, RequestPriority.viewerImage);
      precacheImage(full, context)
          .then((_) {
            if (!mounted || gen != _loadGeneration) return;
            if (!_loadedFinalImage) {
              _updateViewWithFinalImage(full);
            }
          })
          .catchError((Object e) {
            if (gen != _loadGeneration) return;
            // 同 large 分支：不复位 _loadingFinalImage，保持终态防无限
            // 重试；损坏图停留期间仅显示缩略图回退，不再空转。
            if (mounted) {
              // 原图解码失败（损坏/超时）：回退大缩略图显示，不崩不黑屏。
              setState(() => _showingThumbnailFallback = true);
              _notifyReadyOnce();
            }
          });
    }
    debugPrint('[B] heavy-out t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}');
  }

  /// 渐进 provider 接线（full 1152 就绪的所有路径统一走此）：resolve 持流
  /// + 构造并行发起的 4096（p150）+ 替换时机闸（onFrameReady / 路由 settled）。
  /// 调用点：_pickCachedProvider 的 full 同步命中（pick 短路修复）与
  /// _updateViewWithFinalImage（直通/heavy 异步路径）。幂等：已有活流返回
  /// 先前 provider。返回渐进 provider（GIF/非安卓返回 null，调用方回退）。
  ImageProvider? _attachProgressive() {
    if (_progressiveStream != null) return null; // 已接（幂等）
    if (!Platform.isAndroid || _photo.mime == 'image/gif') return null;
    final tw = computeViewerTargetWidth(
      MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context),
    );
    final progressive = buildProgressiveViewerProvider(
      _ref,
      baseTargetWidth: tw,
    );
    _progressiveProvider = progressive;
    _progressiveStream = progressive.resolve(const ImageConfiguration());
    widget.onHdLoaded?.call(_photo.id); // trim 记录（翻页窄窗用）
    final completer = _progressiveStream!.completer;
    if (completer is ProgressiveImageCompleter) {
      completer.setOnFrameReady(_tryFlushHd);
    }
    if (!_routeListenerAttached) {
      _routeListenerAttached = true;
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _routeSettled = true;
      } else {
        animation.addStatusListener(_onHdRouteStatus);
      }
    }
    // 翻页滚动结束驱动 flush（见 _tryFlushHd 扣帧注释）：先摘再加防重。
    _inherited?.pageScrollingNotifier.removeListener(_onPageScrollingChanged);
    _inherited?.pageScrollingNotifier.addListener(_onPageScrollingChanged);
    return progressive;
  }

  Future<void> _updateViewWithFinalImage(ImageProvider imageProvider) async {
    debugPrint('[B] updfl-in t=${DateTime.now().microsecondsSinceEpoch ~/ 1000}');
    // 【升档接线】非 GIF 换上渐进 provider（_attachProgressive 统一入口）。
    // ⚠️ 仅当前页 attach：本方法可被「翻走后才完成的 precache 回调」触发
    //（发起时是当前页、完成时已是预建页）——无守卫会让快甩途中的每个
    // 预建页都发 4096，门被占满 → 条 96px 饿死 → 条项复用 widget
    // 显示旧帧 =「甩动全残留同一张缩略图、停稳几秒才恢复」（真机实证）。
    // 预建页只换 1152 显示（便宜），翻到时 _onSelectedChanged 补 attach。
    //
    // 换链无感靠 completer 构造偷 1152 帧作 initial（1152 = immich preview
    // 显示档语义，flight 清晰度的来源）；此后 4096 帧由 completer 推进，
    // widget 不再 rebuild（「换源」动作整体消失）。
    if (_isCurrentPage) {
      final progressive = _attachProgressive();
      if (progressive != null) {
        imageProvider = progressive;
      }
    }
    // 仅【真放大态】（用户主动 zoomedIn）才做 ente 式尺寸修正保持视角；
    // 其余态静默把 scaleState 归位 initial（setInvisibly 无通知、零副作用）。
    //
    // 归位原因：起始 provider 是方形裁剪缩略图（cell/large 均 squareCrop），
    // core 按方形 contain 写回过很大的绝对 scale（竖屏约屏高/300≈8），且
    // _blindScaleListener 把初始 contain 误标 zoomedOut。该残留若带到
    // PhotoView key 重建（ValueKey(_loadedFinalImage)）之后：新 core 的
    // markNeedsScaleRecalc 被 isScaleStateZooming（含 zoomedOut）抑制 →
    // 沿用方形时代绝对 scale × 等比 childSize = 巨图（删除补位、原图未
    // 缓存的下一张真机实证）。归位 initial 让新 core 按 initial 重算
    // contain(等比)。
    // ⚠️ 不可用 _scaleStateController.reset()/控制器 reset()：reset 是普通
    // 通知，会同步触发 _blindScaleStateListener → setScaleInvisibly(旧值)
    // 与 scaleStateChangedCallback 链，首开慢图（precache 未完成、有方形
    // 过渡）实证引入显示放大回归。
    if (_scaleStateController.scaleState == PhotoViewScaleState.zoomedIn) {
      await _updatePhotoViewController(
        previewImageProvider: _imageProvider,
        finalImageProvider: imageProvider,
      );
    } else {
      _scaleStateController.setInvisibly(PhotoViewScaleState.initial);
    }
    if (!mounted) return;
    setState(() {
      _imageProvider = imageProvider;
      _loadedFinalImage = true;
    });
    _notifyReadyOnce();
    widget.onFullLoaded?.call(_photo.id);
  }

  /// 缩放中切原图的位置修正（ente 原版）：
  /// photo_view 的 scale 是绝对像素比，preview→final 尺寸比变化时按
  /// previousScale / (finalW/prevW) 修正，避免切换瞬间跳变。
  Future<void> _updatePhotoViewController({
    required ImageProvider? previewImageProvider,
    required ImageProvider finalImageProvider,
  }) async {
    // 真放大态判据用 zoomedIn 而非 _isZooming：后者被 photo_view 把初始
    // contain 误标的 zoomedOut 污染（zoomedOut≠initial → _isZooming=true），
    // 而本修正公式隐含按宽适配，方形 contain 实为按高适配 → 换算错数倍。
    final bool shouldFixPosition =
        previewImageProvider != null &&
        _scaleStateController.scaleState == PhotoViewScaleState.zoomedIn &&
        _photoViewController.scale != null;
    if (!shouldFixPosition) return;
    final prevImageInfo = await _resolveImageInfo(previewImageProvider);
    if (!mounted) return; // await 期间 dispose：下文重建 controller/订阅已无意义
    final finalImageInfo = await _resolveImageInfo(finalImageProvider);
    final previousScale = _photoViewController.scale!;
    final previousRelativeScale = _initialScale != null && _initialScale! > 0
        ? previousScale / _initialScale!
        : null;
    final scale =
        previousScale /
        (finalImageInfo.image.width / prevImageInfo.image.width);
    final currentPosition = _photoViewController.value.position;
    // 旧 controller 的订阅已取消，重建前 dispose 旧实例（stream/notifier
    // 不 close 会随每张「缩放中切原图」累积泄漏，审查实证 P2）。
    final oldController = _photoViewController;
    unawaited(_zoomStreamSubscription?.cancel());
    _photoViewController = PhotoViewController(
      initialPosition: currentPosition,
      initialScale: scale,
    );
    if (previousRelativeScale != null &&
        previousRelativeScale.isFinite &&
        previousRelativeScale > 0) {
      _initialScale = scale / previousRelativeScale;
    } else {
      _initialScale = null;
    }
    _subscribeToZoomStream();
    oldController.dispose();
    // 防止原图就绪后自动缩放（双击状态保持）。
    _scaleStateController.scaleState = PhotoViewScaleState.zoomedIn;
  }

  /// 解析 ImageProvider 首帧拿尺寸（ente 用 Flutter getImageInfo 顶层函数，
  /// 3.44 已移除，改用 resolve + listener 等价实现）。
  Future<ImageInfo> _resolveImageInfo(ImageProvider provider) {
    final stream = provider.resolve(ImageConfiguration.empty);
    final completer = Completer<ImageInfo>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info);
        stream.removeListener(listener);
      },
      onError: (Object e, StackTrace? s) {
        if (!completer.isCompleted)
          completer.completeError(e, s ?? StackTrace.empty);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// 与相册网格 cell 完全一致的缩略图尺寸（cell 宽 × dpr，clamp 160~512）。
  /// ImageCache key = provider+size —— 与 cell 同款才能命中已加载缩略图，
  /// 避免飞行层/Hero shuttle 首帧重新解码。
  int _cellThumbSize() {
    final mq = MediaQuery.of(context);
    final cols = widget.gridCols;
    // 与 album_screen 网格一致：4×2 padding + (cols-1)*2 间距（ente Gallery）。
    final cellW =
        (mq.size.width - 8 - (cols - 1) * GalleryGroups.spacing) / cols;
    return (cellW * mq.devicePixelRatio).round().clamp(160, 512);
  }
}

/// 延迟 spinner：prefetch 的图在页间切换时不闪 loading（ente 同款）。
class _DelayedLoadingIndicator extends StatefulWidget {
  const _DelayedLoadingIndicator();

  @override
  State<_DelayedLoadingIndicator> createState() =>
      _DelayedLoadingIndicatorState();
}

class _DelayedLoadingIndicatorState extends State<_DelayedLoadingIndicator> {
  static const Duration _delay = Duration(milliseconds: 400);
  Timer? _timer;
  bool _showSpinner = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _showSpinner = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSpinner) return const SizedBox.expand();
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
      ),
    );
  }
}
