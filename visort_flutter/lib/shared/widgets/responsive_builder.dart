// 响应式布局辅助 —— 把 LayoutBuilder 约束里的可用宽度交给回调。
// 平台无关的通用件；断点语义（如桌面宽屏 >800px 双栏）由调用方决定。
// 2026-08 从 home_screen / sort_screen 的两份重复定义收编至此。

import 'package:flutter/material.dart';

class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({super.key, required this.builder});
  final Widget Function(BuildContext, double) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) => builder(ctx, constraints.maxWidth),
    );
  }
}
