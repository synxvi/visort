// 自绘 Glyph 图标库 —— 安卓端顶栏/底栏操作按钮共用
//
// 形制规范（2026-09 定稿，以相册页顶栏三按钮为基准，详见 AGENTS.md
// "Android top-bar icon glyph spec"）：
//  · 24 基准视口 × 28px 画布：painter 坐标按 24×24 设计，
//    canvas.scale(size.width/24) 适配；28/24 放大后 stroke 1.9 的视觉
//    线宽 ≈2.2dp。图形包络大的（抽屉侧栏框）才用 24 画布。
//  · stroke 1.9、圆头笔帽（StrokeCap.round）+ 圆角连接（round），
//    颜色 AppColors.text（语义色 danger/accent 由调用方传 paint 色）。
//  · 图形包络 ~10.4–14dp 近方形，不撑满视口——相邻按钮图形间隙
//    ~22dp 的视觉前提。
//  · 壳 = 原生 IconButton（默认 48×48 点击盒，不覆写 iconSize）；
//    光学微调用 Transform.translate（只动像素不动布局盒/点击区）。
//  · morph ✕ 家族端点统一 (7.2,7.2)–(16.8,16.8)。
//
// 替代对象：勾选态顶栏的 Icons.select_all/more_vert/close、看图器底栏的
// Icons.info_outline/favorite(+border)/delete_outline/restore/more_vert
// ——stock Material 图标满格 24 包络，与细线家族并排显粗显大（风格断档）。
// 菜单行内小图标（16/18/20px 语义列表图标）不属于本规范，维持 Material。
//
// 线宽变体（2026-09 真机反馈）：看图器底栏纯黑背景高对比，同 1.9 线宽
// 观感偏重——底栏场景（心形/垃圾桶/恢复/ⓘ）用 **stroke 1.7**；顶栏场景
// 维持基准 1.9（ⓘ 说明按钮 strokeWidth 参数默认 1.9，底栏传 1.7）。
// ⋮ 圆点两场景统一 r 1.7（实心点密度高于线，略细于线宽是合理搭配，
// 参照三线筛选滑点 r1.75 vs 线 1.9 先例）。

import 'dart:math' show pi;

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

/// 自绘全选框（勾选态顶栏）：圆角方框 +（[checked] 时）框内勾。
///
/// 勾 = 选择状态指示（2026-09 用户定稿）：当前一项都没勾 → 空框；
/// 勾了任意一项及以上 → 框内显示小勾。
class SelectAllGlyphIcon extends StatelessWidget {
  const SelectAllGlyphIcon({super.key, this.checked = false, this.color});

  /// true = 框内显示小勾（已有 ≥1 项被勾选）。
  final bool checked;

  /// 线色；null 用默认 AppColors.text。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _SelectAllGlyphPainter(checked, color),
    );
  }
}

class _SelectAllGlyphPainter extends CustomPainter {
  const _SelectAllGlyphPainter(this.checked, this.color);

  final bool checked;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color ?? AppColors.text;
    // 方框中心线 6.1~17.9（包络 ≈13.7），圆角 3
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(6.1, 6.1, 17.9, 17.9),
        const Radius.circular(3),
      ),
      paint,
    );
    // 框内勾（三折，端点圆头）——仅选中态显示
    if (checked) {
      final check = Path()
        ..moveTo(8.7, 12.2)
        ..lineTo(10.9, 14.4)
        ..lineTo(15.3, 9.6);
      canvas.drawPath(check, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SelectAllGlyphPainter oldDelegate) =>
      oldDelegate.checked != checked || oldDelegate.color != color;
}

/// 自绘 ⋮（选项菜单）：三枚实心圆点竖排（点 r 1.7——实心点密度高于
/// 线，略细于线宽是合理搭配，参照 morph 滑点 r1.75 先例）。
class MoreVertGlyphIcon extends StatelessWidget {
  const MoreVertGlyphIcon({super.key, this.color});

  /// 点色；null 用默认 AppColors.text。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _MoreVertGlyphPainter(color),
    );
  }
}

class _MoreVertGlyphPainter extends CustomPainter {
  const _MoreVertGlyphPainter(this.color);

  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color ?? AppColors.text;
    // 竖排 y 7.2/12/16.8 与 morph ✕ 端点同档（包络 ≈13.4 高）
    canvas.drawCircle(const Offset(12, 7.2), 1.7, paint);
    canvas.drawCircle(const Offset(12, 12), 1.7, paint);
    canvas.drawCircle(const Offset(12, 16.8), 1.7, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MoreVertGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 自绘 ✕（关闭）：与 morph 家族同端点几何 (7.2,7.2)–(16.8,16.8)。
class CloseGlyphIcon extends StatelessWidget {
  const CloseGlyphIcon({super.key, this.color});

  /// 线色；null 用默认 AppColors.text。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _CloseGlyphPainter(color),
    );
  }
}

class _CloseGlyphPainter extends CustomPainter {
  const _CloseGlyphPainter(this.color);

  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..color = color ?? AppColors.text;
    canvas.drawLine(const Offset(7.2, 7.2), const Offset(16.8, 16.8), paint);
    canvas.drawLine(const Offset(16.8, 7.2), const Offset(7.2, 16.8), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloseGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 自绘心形（看图器底栏收藏）：[filled] 切换实心/空心（同一 path，
/// Material favorite/favorite_border 同语义）。
class HeartGlyphIcon extends StatelessWidget {
  const HeartGlyphIcon({super.key, this.filled = false, this.color});

  /// true = 实心（已收藏，调用方传 danger）；false = 空心细线。
  final bool filled;

  /// 前景色（空心 = 线色，实心 = 填充色）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _HeartGlyphPainter(filled, color),
    );
  }
}

class _HeartGlyphPainter extends CustomPainter {
  const _HeartGlyphPainter(this.filled, this.color);

  final bool filled;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    // 底栏黑底场景 stroke 1.7（1.9 在纯黑背景观感偏重，2026-09 真机反馈）
    final paint = Paint()
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color ?? AppColors.text;
    // 对称双瓣贝塞尔：底尖 (12,18)，凹口 (12,9.4)；中心线包络
    // x 4.6~19.4（心形天然偏宽，含 stroke ≈16.7，与抽屉侧栏框同档）
    final heart = Path()
      ..moveTo(12, 18)
      ..cubicTo(6.8, 14.3, 4.6, 10.9, 7.2, 8.5)
      ..cubicTo(8.9, 6.9, 11.0, 7.6, 12, 9.4)
      ..cubicTo(13.0, 7.6, 15.1, 6.9, 16.8, 8.5)
      ..cubicTo(19.4, 10.9, 17.2, 14.3, 12, 18)
      ..close();
    canvas.drawPath(heart, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HeartGlyphPainter oldDelegate) =>
      oldDelegate.filled != filled || oldDelegate.color != color;
}

/// 自绘垃圾桶（看图器底栏删除）：盖横线 + 提手 + 桶身 + 两道竖纹
/// （Lucide trash 同构，笔画密度对齐三线筛选）。
class TrashGlyphIcon extends StatelessWidget {
  const TrashGlyphIcon({super.key, this.color});

  /// 线色；调用方传语义色（删除位 AppColors.danger）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _TrashGlyphPainter(color),
    );
  }
}

class _TrashGlyphPainter extends CustomPainter {
  const _TrashGlyphPainter(this.color);

  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    // 底栏黑底场景 stroke 1.7（1.9 在纯黑背景观感偏重，2026-09 真机反馈）
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color ?? AppColors.text;
    // 盖横线
    canvas.drawLine(const Offset(7.6, 6.6), const Offset(16.4, 6.6), paint);
    // 提手：两竖 + 顶部圆弧
    final handle = Path()
      ..moveTo(9.9, 6.6)
      ..lineTo(9.9, 5.0)
      ..quadraticBezierTo(12, 3.3, 14.1, 5.0)
      ..lineTo(14.1, 6.6);
    canvas.drawPath(handle, paint);
    // 桶身：两侧内收 + 圆角底
    final body = Path()
      ..moveTo(7.0, 6.6)
      ..lineTo(7.8, 17.0)
      ..quadraticBezierTo(7.9, 17.8, 8.7, 17.8)
      ..lineTo(15.3, 17.8)
      ..quadraticBezierTo(16.1, 17.8, 16.2, 17.0)
      ..lineTo(17.0, 6.6);
    canvas.drawPath(body, paint);
    // 两道竖纹
    canvas.drawLine(const Offset(10.3, 9.8), const Offset(10.5, 14.4), paint);
    canvas.drawLine(const Offset(13.7, 9.8), const Offset(13.5, 14.4), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrashGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 自绘恢复（看图器底栏回收站态）：逆时针大弧 + 左上向箭头翼
/// （undo 语义；底尖弧与返回箭头的直线 chevron 区分）。
class RestoreGlyphIcon extends StatelessWidget {
  const RestoreGlyphIcon({super.key, this.color});

  /// 线色；调用方传语义色（恢复位 AppColors.accent）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _RestoreGlyphPainter(color),
    );
  }
}

class _RestoreGlyphPainter extends CustomPainter {
  const _RestoreGlyphPainter(this.color);

  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    // 底栏黑底场景 stroke 1.7（1.9 在纯黑背景观感偏重，2026-09 真机反馈）
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color ?? AppColors.text;
    // 大弧：右下 (15.8,16.4) 逆时针经顶部到左下 (8.2,16.4)，
    // 半径 5.6 → 圆心 (12,12)，弧顶 y 6.4（包络 ≈11 高）
    final arc = Path()
      ..moveTo(15.8, 16.4)
      ..arcToPoint(
        const Offset(8.2, 16.4),
        radius: const Radius.circular(5.6),
        clockwise: false,
        largeArc: true,
      );
    canvas.drawPath(arc, paint);
    // 箭头翼：终点处逆时针运动切向朝左上，两翼各张开 ~30°
    final head = Path()
      ..moveTo(8.2, 16.4)
      ..lineTo(6.5, 15.9)
      ..moveTo(8.2, 16.4)
      ..lineTo(8.0, 14.6);
    canvas.drawPath(head, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RestoreGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 跑道形撤回图标（自绘）：上/下两条直线 + 右端半圆弧的体育场跑道
/// 轮廓，开放于左侧——路径从左下起（底线左端）→ 底直线 → 右端半圆弧
/// → 顶直线 → 左上止，箭头在左上端指向行进方向（左）。线条风格同
/// BackGlyphButton 自绘箭头（stroke 1.9 圆帽圆角）。
///
/// 用途：大图删除结果气泡的撤回按钮（size 28 画布，accent）；回收站
/// 批量栏「恢复」操作（size 22——批量栏图标位 18dp 档，细线图形按
/// 包络补偿略放大画布，2026-09 用户定稿：样式与删除 toast 同款）。
class UndoTrackGlyphIcon extends StatelessWidget {
  const UndoTrackGlyphIcon({super.key, this.size = 28, this.color});

  /// 画布边长（图形包络 13×10.8，按 24 视口等比缩放）。
  final double size;

  /// 线色；null 用默认 AppColors.accent（撤回/恢复语义色）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _UndoTrackPainter(color),
    );
  }
}

class _UndoTrackPainter extends CustomPainter {
  const _UndoTrackPainter(this.color);

  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..color = color ?? AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 几何（24 视口，形制对齐 BackGlyphIcon：stroke 1.9、字形 ~13×11）。
    final yTop = 7.2, yBottom = 18.0; // 字形高 10.8 ≈ 返回箭头 11
    final r = (yBottom - yTop) / 2; // 端弧半径 = 半高（两端正好半圆）
    final cy = (yTop + yBottom) / 2;
    const arcRightCx = 12.0; // 右弧圆心；最右缘 17.4 对齐返回横线右端
    const xLeft = 6.4; // 跑道开口端（左）x

    final track = Path()
      ..moveTo(xLeft, yBottom) // 左下起点
      ..lineTo(arcRightCx, yBottom) // 底直线 →
      ..arcTo(
        // 右端半圆：底部起经最右点到顶部（视觉逆时针）。
        Rect.fromCircle(center: Offset(arcRightCx, cy), radius: r),
        pi / 2,
        -pi,
        false,
      )
      ..lineTo(xLeft, yTop); // 顶直线 →（弧后笔已在右弧顶端）

    // 箭头：尖在 (tipX, yTop) 指向左（行进方向），两翼后张。
    const tipX = 4.2, wing = 2.6;
    final arrow = Path()
      ..moveTo(tipX + wing, yTop - wing)
      ..lineTo(tipX, yTop)
      ..lineTo(tipX + wing, yTop + wing);

    canvas.drawPath(track, paint);
    canvas.drawPath(arrow, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_UndoTrackPainter oldDelegate) => oldDelegate.color != color;
}

/// 自绘 ⓘ（看图器底栏照片详情 / 快速整理页说明）：细线圆圈 + 倒感叹号，
/// 顶点 accent 实心小圆（2026-09 用户定稿的唯一彩色点缀）。
///
/// 圆圈外径 ~13.1 与侧栏图形（14）同档（细线图形数学包络同宽仍显小，
/// 放大一档对齐视觉分量——单笔细圈低于多笔图形的笔画密度）。
class InfoGlyphIcon extends StatelessWidget {
  const InfoGlyphIcon({
    super.key,
    this.color,
    this.accentDot = true,
    this.strokeWidth = 1.9,
  });

  /// 线色；null 用默认 AppColors.text。
  final Color? color;

  /// 感叹号顶点是否用 accent 点（说明/详情按钮均为 true，保留定稿）。
  final bool accentDot;

  /// 线宽：顶栏基准 1.9（默认，快速整理页说明按钮）；看图器底栏黑底
  /// 高对比场景传 1.7（2026-09 真机反馈 1.9 偏重）。
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _InfoGlyphPainter(color, accentDot, strokeWidth),
    );
  }
}

class _InfoGlyphPainter extends CustomPainter {
  const _InfoGlyphPainter(this.color, this.accentDot, this.strokeWidth);

  final Color? color;
  final bool accentDot;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..color = color ?? AppColors.text
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    // 外圈：中心 (12,12) 半径 5.6，外缘直径 5.6×2+1.9 ≈ 13.1
    canvas.drawCircle(const Offset(12, 12), 5.6, stroke);
    // 倒感叹号：顶点 = accent 实心小圆（唯一彩色点缀）；短竖线下引，
    // 点/线间留空隙（i 的字面结构）。
    canvas.drawCircle(
      const Offset(12, 9.4),
      1.15,
      Paint()..color = accentDot ? AppColors.accent : (color ?? AppColors.text),
    );
    canvas.drawLine(
      const Offset(12, 12.1),
      const Offset(12, 14.7),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InfoGlyphPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.accentDot != accentDot ||
      oldDelegate.strokeWidth != strokeWidth;
}
