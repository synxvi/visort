// 返回按钮 —— 自绘细线箭头
//
// 与顶栏抽屉按钮（侧栏图形 morph，app_shell_android）和视图选项按钮
//（三线筛选 morph，view_options_toggle）同一形制：stroke 1.9 圆头细线、
// 24 视口基准 × 28px 画布、~12×11 近方形轮廓（2026-08 用户要求：返回
// 箭头与这两个按钮大小风格接近）。覆盖：相册内 push 返回（AppBar
// leading）、看图器顶栏（detail_page）、sort 屏顶栏（sort_screen_android）。
//
// [hideWhenCannotPop]：复刻系统 BackButton 的显隐语义——路由不可 pop
//（如勾选态 PopScope canPop=false）时渲染空盒（相册内 AppBar 返回用）。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

/// 返回按钮（自绘箭头字形 + IconButton 壳）。
class BackGlyphButton extends StatelessWidget {
  const BackGlyphButton({
    super.key,
    required this.onPressed,
    this.tooltip,
    this.padding = const EdgeInsets.fromLTRB(9, 8, 19, 8),
    this.hideWhenCannotPop = false,
  });

  final VoidCallback? onPressed;
  final String? tooltip;

  /// 默认复刻首页 AppBar 几何（与抽屉按钮 + 标题同行对齐，2026-08 用户
  /// 要求）：箭头字形左缘 16dp（对齐内容区左缘，= 抽屉图标字形位），
  /// 盒宽 56dp（= AppBar leading 槽宽）→ 自绘顶栏（看图器/sort 屏）的
  /// 文件名起点与首页标题起点（leadingWidth 56）一致。
  final EdgeInsetsGeometry padding;

  /// true = 路由不可 pop 时隐藏（系统 BackButton 同语义）。
  final bool hideWhenCannotPop;

  @override
  Widget build(BuildContext context) {
    if (hideWhenCannotPop) {
      final canPop = ModalRoute.of(context)?.canPop ?? false;
      if (!canPop) return const SizedBox.shrink();
    }
    return IconButton(
      padding: padding,
      icon: const BackGlyphIcon(),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

/// 自绘返回箭头字形（横线 + chevron 头）。独立公开：顶栏自绘布局
///（detail_page / sort_screen_android）可直接嵌入。
class BackGlyphIcon extends StatelessWidget {
  const BackGlyphIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(
      // 28px 画布：视觉分量与侧栏图形（24 画布×14dp 内容）同量级。
      size: Size.square(28),
      painter: _BackGlyphPainter(),
    );
  }
}

class _BackGlyphPainter extends CustomPainter {
  const _BackGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = AppColors.text;
    // 横线
    canvas.drawLine(const Offset(7.2, 12), const Offset(17.4, 12), paint);
    // chevron 头（圆角转折与线端同语言）
    final head = Path()
      ..moveTo(11.4, 7.5)
      ..lineTo(6.9, 12)
      ..lineTo(11.4, 16.5);
    canvas.drawPath(head, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BackGlyphPainter oldDelegate) => false;
}
