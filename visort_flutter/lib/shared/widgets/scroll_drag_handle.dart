// 滚动拖拽手柄 —— 紧凑竖向胶囊 + 上下双箭头 + 亚克力模糊背景，贴列表右侧。
//
// ★ 终极稳定性方案（解决分页加载乱跳）：
//   相册分页加载（每页60张），每次 loadMore 后 maxScrollExtent 阶梯暴涨
//   （15994→18361→20727...）。任何用 maxScrollExtent 做分母的进度算法
//   都会在分页瞬间让手柄回跳（实测 thumb/pixels/item 三种算法全败）。
//
//   解法：进度完全基于【固定几何】+【真实图片总数】：
//     progress = 已滚行数 / 可滚动总行数
//     已滚行数 = pixels / rowExtent（rowExtent 是屏幕宽度算出的固定值）
//     可滚动总行数 = (totalItems / 列数) - 一屏行数
//   totalItems 用 MediaStore bucket.count（相册真实总数，查询时确定，
//   不随分页变化），rowExtent 固定 → 分母恒定 → 手柄绝不回跳。

import 'dart:ui';
import 'package:flutter/material.dart';

import 'package:visort_flutter/core/theme/app_colors.dart';

class ScrollDragHandle extends StatefulWidget {
  const ScrollDragHandle({
    super.key,
    required this.controller,
    required this.totalItems,
    required this.rowExtent,
    this.columns = 3,
    this.viewportRows = 5,
    this.useActualExtent = false,
    this.monotonicExtent = false,
    this.margin = const EdgeInsets.only(right: 8),
    this.topInset = 0,
    this.labelBuilder,
    this.snapOffset,
  });

  final ScrollController controller;
  /// 列表【真实】总 item 数（用 MediaStore bucket.count，固定不变）。
  /// 这是稳定性的关键——不能用 photos.length（分页时增长）或预估。
  final int totalItems;
  /// 单行高度（固定几何量，由屏幕宽度算出，分页时不抖）
  final double rowExtent;
  final int columns;
  /// 一屏可见的行数
  final int viewportRows;
  /// true=进度/拖拽基于实际 maxScrollExtent（到底=100%，适合日期分组）；
  /// false=基于全量几何分母（loadMore 不跳，适合沉浸均匀网格）。
  final bool useActualExtent;
  /// 单调化 maxScrollExtent：变高项 SliverList 的 maxScrollExtent 滚动中估算抖
  /// → 手柄慢拖"先退再进"；记录滚动中见过的最大值（只增不减）作分母，消除抖动。
  /// 比 useActualExtent 稳（不抖），比几何估算准（用 SliverList 自身 layout 值）。
  final bool monotonicExtent;
  final EdgeInsets margin;
  /// track 顶部避让高度：日期视图顶部有吸附组头（PinnedGroupHeader），
  /// 手柄行程起点下移到组头下方，不与其叠加显示；沉浸网格传 0。
  /// 影响 build 定位与拖拽 handleMovable 换算（两者严格同步，保 1:1 跟手）。
  final double topInset;
  /// 拖动时在手柄旁显示当前位置文本（如日期）的构建器（aves 拖动气泡）。
  /// null 或返回 null 时不显示气泡（沉浸网格无分组场景）。
  final String? Function(double pixels)? labelBuilder;
  /// 松手吸附目标（aves 同款：吸附到最近分组头）；null 时不吸附。
  final double? Function(double pixels)? snapOffset;

  @override
  State<ScrollDragHandle> createState() => _ScrollDragHandleState();
}

class _ScrollDragHandleState extends State<ScrollDragHandle> {
  bool _dragging = false;
  static const _handleH = 34.0;
  /// 底部安全边距：圆角屏幕会裁掉贴底手柄，行程底部留出圆角高度。
  static const _bottomSafe = 24.0;
  // 由 LayoutBuilder 记录的 track 实际高度，供拖拽 1:1 跟手换算用
  double _trackH = 0.0;
  /// monotonicExtent 模式：滚动中见过的最大 maxScrollExtent（只增不减）。
  double _maxEverExtent = 0.0;

  /// 刷新单调分母（monotonicExtent 模式用）。
  void _refreshMaxEver() {
    final c = widget.controller;
    if (c.hasClients && c.position.hasViewportDimension) {
      final me = c.position.maxScrollExtent;
      if (me > _maxEverExtent) _maxEverExtent = me;
    }
  }

  bool get _shouldShow {
    if (_dragging) return true;
    if (!widget.controller.hasClients) return false;
    return widget.controller.offset > 4;
  }


  /// 进度 [0,1]。useActualExtent=实际可滚范围（到底=100%，日期分组用，
  /// loadMore 时跳、由调用处防抖缓解）；否则=全量几何分母（沉浸网格用，
  /// loadMore 不跳但已加载到底时手柄未到 100%）。
  double get _progress {
    final c = widget.controller;
    if (!c.hasClients) return 0.0;
    final pos = c.position;
    if (widget.monotonicExtent) {
      if (_maxEverExtent <= 0) return 0.0;
      return (pos.pixels / _maxEverExtent).clamp(0.0, 1.0);
    }
    if (widget.useActualExtent) {
      final me = pos.maxScrollExtent;
      if (me <= 0) return 0.0;
      return (pos.pixels / me).clamp(0.0, 1.0);
    }
    final h = widget.rowExtent;
    final total = widget.totalItems;
    if (h <= 0 || total <= 0) return 0.0;
    final totalRows = (total / widget.columns).ceil();
    final viewportRows =
        _trackH > 0 ? _trackH / h : widget.viewportRows.toDouble();
    final scrollableRows =
        (totalRows - viewportRows).clamp(1.0, totalRows.toDouble());
    final denom = scrollableRows * h;
    if (denom <= 0) return 0.0;
    return (pos.pixels / denom).clamp(0.0, 1.0);
  }

  void _update() {
    _refreshMaxEver();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
  }

  @override
  void didUpdateWidget(covariant ScrollDragHandle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _onVerticalDragEnd() {
    setState(() => _dragging = false);
    // 松手吸附（aves 同款）：滚到最近分组头，组头标题对齐视口顶。
    // 到底/到顶豁免：拖到底（最后一张）松手不吸附——回到最近组头会
    // 从最末项回弹一眼（用户反馈：到底回弹到最后一个分组标题不合理）。
    final snap = widget.snapOffset;
    if (snap == null) return;
    final c = widget.controller;
    if (!c.hasClients || !c.position.hasViewportDimension) return;
    final pos = c.position;
    final pixels = pos.pixels;
    if (pixels >= pos.maxScrollExtent - 1.0 || pixels <= 1.0) return;
    final target = snap(pixels);
    if (target == null || (target - pixels).abs() < 1) return;
    c.animateTo(
      target.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final pos = c.position;
    if (!pos.hasViewportDimension) return;
    // 手柄在 track 上的可移动区间（与 build 定位严格一致，同步避让 topInset）
    final handleMovable =
        (_trackH - _handleH - _bottomSafe - widget.topInset)
            .clamp(1.0, double.infinity);
    // 列表的总可滚动像素（与 build 的 _progress 分母一致）
    final double maxPixels;
    if (widget.monotonicExtent) {
      // 拖动分母用**实时** maxScrollExtent，不用单调值——单调值（_maxEverExtent）
      // 初始 0、只在滚动"见过"后更新：首次触摸拖拽（页面刚打开/未滚过）时
      // 分母偏小 → 拖一点点就停或完全拖不动；第二次拖时单调值已刷新才正常。
      // SectionedListSliver.estimateMaxScrollOffset 是精确全量预计算
      //（sectionLayouts.last.maxOffset），maxScrollExtent 并不抖——单调
      // 值仅保留在 _progress（显示）里防抖。
      maxPixels = pos.maxScrollExtent;
      if (maxPixels > _maxEverExtent) _maxEverExtent = maxPixels;
    } else if (widget.useActualExtent) {
      maxPixels = pos.maxScrollExtent;
    } else {
      final h = widget.rowExtent;
      final totalRows = (widget.totalItems / widget.columns).ceil();
      final viewportRows =
          _trackH > 0 ? _trackH / h : widget.viewportRows.toDouble();
      final scrollableRows =
          (totalRows - viewportRows).clamp(1.0, totalRows.toDouble());
      maxPixels = scrollableRows * h;
    }
    if (maxPixels <= 0) return;
    // 1:1 跟手：手指 Δy → 手柄移动 Δy → 对应列表滚动 Δy/maxPixels 比例
    final deltaRatio = details.delta.dy / handleMovable;
    final target = (pos.pixels + deltaRatio * maxPixels).clamp(0.0, maxPixels);
    pos.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: widget.margin,
        width: 44,
        height: double.maxFinite,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final trackH = constraints.maxHeight;
            if (trackH != _trackH) _trackH = trackH;
            // 行程起点下移 topInset（日期视图避让吸附组头），终点不变
            final top = widget.topInset +
                progress * (trackH - _handleH - _bottomSafe - widget.topInset);
            // 拖动气泡：手柄左侧亚克力胶囊显示当前位置文本（日期），
            // 随手柄 top 移动（aves 拖动滚动条体验）。
            final label = _dragging
                ? widget.labelBuilder?.call(
                    widget.controller.hasClients
                        ? widget.controller.position.pixels
                        : 0.0,
                  )
                : null;
            // ⚠️ 手势层必须在 AnimatedOpacity **外**：AnimatedOpacity 在
            // opacity=0（页面刚打开 offset<=4 未显示）时 hitTest 直接返回
            // false——旧结构 GestureDetector 藏在渐隐层内，第一次触摸整个
            // 落到下层 CustomScrollView（页面滚动/手柄无反应），滚一下
            // opacity>0 后第二次才能拖（真机实证「第一次完全拖不动」）。
            // GestureDetector behavior=opaque 自身恒参与命中测试，视觉
            // 渐隐只作用于胶囊。
            //
            // ⚠️★ 两个 Positioned 必须带 key（真机实证「第一次拖一小截突然
            // 停住/直接拖不动，第二次才正常」）：拖动开始 label 首次非 null，
            // 气泡 Positioned 头部插入 Stack——无 key 时 Flutter 按位置+类型
            // 配对 element，手柄的 Positioned 被顶去配气泡，其手势子树
            // （GestureDetector→recognizer）整棵 unmount：正在拖拽的指针
            // 与 recognizer 的绑定随 dispose 静默消失（无 cancel/end），
            // 后续 move/up 全失联＝拖拽中断；松手无 dragEnd，_dragging 恒
            // true、气泡已在树上，第二次拖结构稳定才正常。加 key 后插入
            // 气泡只影响自身槽位，手柄 element 持续存活。
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (label != null)
                  Positioned(
                    key: const ValueKey('sdh_label'),
                    top: (top + _handleH / 2 - 15).clamp(
                      0.0,
                      (trackH - 30).clamp(0.0, double.infinity),
                    ),
                    right: 27,
                    height: 30,
                    child: _AcrylicLabel(label: label),
                  ),
                Positioned(
                  key: const ValueKey('sdh_handle'),
                  top: top,
                  right: 0,
                  height: _handleH,
                  width: 19,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) =>
                        setState(() => _dragging = true),
                    onVerticalDragUpdate: _onVerticalDragUpdate,
                    onVerticalDragEnd: (_) => _onVerticalDragEnd(),
                    child: AnimatedOpacity(
                      opacity: _shouldShow ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 180),
                      child: _AcrylicCapsule(enlarged: _dragging),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 拖动气泡：与手柄同款亚克力底 + 白字（数字/英文 Space Mono，中文回退思源）。
class _AcrylicLabel extends StatelessWidget {
  const _AcrylicLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: ColoredBox(
              color: AppColors.bg.withValues(alpha: 0.45),
            ),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.18)),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontSize: 12,
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 亚克力胶囊：BackdropFilter 模糊 + 半透明深底 + 上下双箭头。
class _AcrylicCapsule extends StatelessWidget {
  const _AcrylicCapsule({required this.enlarged});
  final bool enlarged;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: ColoredBox(
              color: AppColors.bg.withValues(alpha: enlarged ? 0.45 : 0.38),
            ),
          ),
          ColoredBox(
            color: Colors.black.withValues(alpha: enlarged ? 0.18 : 0.12),
          ),
          // FittedBox 兜底：图标必须适配胶囊尺寸，防溢出裁出残影
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.expand_less,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                  Icon(
                    Icons.expand_more,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
