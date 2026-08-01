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

import 'package:sortr_flutter/core/theme/app_colors.dart';

class ScrollDragHandle extends StatefulWidget {
  const ScrollDragHandle({
    super.key,
    required this.controller,
    required this.totalItems,
    required this.rowExtent,
    this.columns = 3,
    this.viewportRows = 5,
    this.margin = const EdgeInsets.only(right: 8),
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
  final EdgeInsets margin;

  @override
  State<ScrollDragHandle> createState() => _ScrollDragHandleState();
}

class _ScrollDragHandleState extends State<ScrollDragHandle> {
  bool _dragging = false;
  static const _handleH = 34.0;
  // 由 LayoutBuilder 记录的 track 实际高度，供拖拽 1:1 跟手换算用
  double _trackH = 0.0;

  bool get _shouldShow {
    if (_dragging) return true;
    if (!widget.controller.hasClients) return false;
    return widget.controller.offset > 4;
  }

  /// 纯几何稳定进度 [0,1]。分母恒定（totalItems 固定 + rowExtent 固定）。
  double get _progress {
    final c = widget.controller;
    if (!c.hasClients) return 0.0;
    final pos = c.position;
    final h = widget.rowExtent;
    final total = widget.totalItems;
    if (h <= 0 || total <= 0) return 0.0;
    final totalRows = (total / widget.columns).ceil();
    final scrollableRows = (totalRows - widget.viewportRows).clamp(1, totalRows);
    final scrolledRows = (pos.pixels / h).clamp(0.0, scrollableRows.toDouble());
    return (scrolledRows / scrollableRows).clamp(0.0, 1.0);
  }

  void _update() => setState(() {});

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

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final pos = c.position;
    // 手柄在 track 上的可移动区间（与 build 定位严格一致）
    final handleMovable = (_trackH - _handleH).clamp(1.0, double.infinity);
    // 列表的总可滚动像素（纯几何）
    final h = widget.rowExtent;
    final totalRows = (widget.totalItems / widget.columns).ceil();
    final scrollableRows = (totalRows - widget.viewportRows).clamp(1, totalRows);
    final maxPixels = scrollableRows * h;
    // 1:1 跟手：手指 Δy → 手柄移动 Δy → 对应列表滚动 Δy/maxPixels 比例
    final deltaRatio = details.delta.dy / handleMovable;
    final target = (pos.pixels + deltaRatio * maxPixels).clamp(0.0, pos.maxScrollExtent);
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
        child: AnimatedOpacity(
          opacity: _shouldShow ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(
            ignoring: !_shouldShow,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackH = constraints.maxHeight;
                if (trackH != _trackH) _trackH = trackH;
                final top = progress * (trackH - _handleH);
                return Stack(
                  children: [
                    Positioned(
                      top: top,
                      right: 0,
                      height: _handleH,
                      width: 19,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: (_) =>
                            setState(() => _dragging = true),
                        onVerticalDragUpdate: _onVerticalDragUpdate,
                        onVerticalDragEnd: (_) =>
                            setState(() => _dragging = false),
                        child: _AcrylicCapsule(enlarged: _dragging),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
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
