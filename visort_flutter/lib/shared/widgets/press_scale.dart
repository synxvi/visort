// 按压回缩 widget —— 对标一加相册 tile 的按压手感
//
// 一加相册的 tile 按下时有轻微 scale 回缩（约 0.97），用 COUIOutEase 曲线
// （快速回缩、缓慢恢复）。sortr 全局禁用了 Material ripple（NoSplash），
// 故用本 widget 提供"按压有反馈"的体感，不依赖 InkWell ripple。
//
// 用法：把本 widget 包在可点击内容外层，onTap 透传给内部的 InkWell/GestureDetector。

import 'package:flutter/material.dart';

import '../../core/theme/app_animations.dart';

/// 包裹子 widget，按下时 scale 回缩到 [pressedScale]（默认 0.97），松开弹回。
///
/// [onTap] 透传给内部 GestureDetector；与 InkWell 二选一（不要嵌套 InkWell，
/// 否则手势竞技冲突）。sortr 已全局禁用 ripple，故本 widget 即可替代 InkWell
/// 提供点击 + 按压视觉。
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
    this.duration = AppDurations.micro,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final Duration duration;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: widget.duration,
        curve: AppCurves.couiOutEase,
        child: widget.child,
      ),
    );
  }
}
