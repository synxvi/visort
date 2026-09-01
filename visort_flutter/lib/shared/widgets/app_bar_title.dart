// AppBar 标题 —— 安卓各页顶栏共用（相册/快速整理/收藏/回收站/相册内/设置）
//
// 统一两件事（2026-09 真机像素实测定标，基准 = 相册首页顶栏）：
//  1. 字形样式：Space Mono 16 w700 height 1.2（CJK fallback）。
//  2. 视觉对齐补偿：Transform 只移字形不动布局盒——
//     · dy 按文本脚本自动分档（真机像素实测）：CJK −1.4（Noto Sans CJK
//       字形在行盒内重心偏下 ~1.38dp）；纯 ASCII −0.65（Space Mono 行盒
//       重心偏下 ~0.65dp，实测 SORT 过补偿 +0.75 / 含 descender 的
//       混大小写相册名 +0.5，取中）。上移后与 leading/actions 图标共线
//      （四元素同线调校：抽屉按钮 y 补偿归零、放大镜 y+1.1，见
//       gallery_screen / app_shell_android 同批注释）。
//     · dx（默认 0）：返回箭头 leading 页（相册内 push）传 −1.6——箭头
//       字形右缘（~30.4dp）比抽屉侧栏图形右缘（~32dp）窄 ~1.5dp，左移
//       抹平差值，使「按钮→标题」图形间隙跨页一致（24.5dp 基准）。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart' show AppFonts;

class AppBarTitleText extends StatelessWidget {
  const AppBarTitleText(
    this.text, {
    super.key,
    this.dx = 0,
    this.maxLines,
    this.overflow,
    this.fontWeight = FontWeight.w700,
  });

  final String text;

  /// 水平光学补偿（dp）：箭头 leading 页传 −1.6，侧栏 leading 页 0。
  final double dx;

  /// 默认 w700（各浏览页）；设置页历史为 w400（弱化），经此保留差异。
  /// 字重不影响行盒重心（同 metrics），−1.4 补偿对两者同样成立。
  final FontWeight fontWeight;

  final int? maxLines;
  final TextOverflow? overflow;

  /// dy 分档：含 CJK → −1.4；纯 ASCII → −0.65（依据见文件头注释）。
  static double _dyFor(String text) =>
      RegExp(r'[　-鿿]').hasMatch(text) ? -1.4 : -0.65;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(dx, _dyFor(text)),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Space Mono',
          height: 1.2,
          fontFamilyFallback: AppFonts.cjkFallback,
          fontWeight: fontWeight,
          fontSize: 16,
        ),
        maxLines: maxLines,
        overflow: overflow,
      ),
    );
  }
}
