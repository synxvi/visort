// 「继续」按钮(P2)—— Home 底栏「开始」左侧的中断恢复入口
//
// 交互:点击恢复上次整理;拖动把按钮本身推走——拖动过程中按钮透明度
// 随距离渐淡,超过阈值松手则沿拖动方向加速飞出+淡出(丢弃持久化会话),
// 不过阈值则弹簧回位(AppSprings,与弹窗/浮动手环同一套物理,带真实
// 过冲)。不做 Dismissible 式色块底衬,按钮就是被拖动的主体。
//
// [freeDrag]=true(手机端):任意方向拖拽;false(桌面):仅水平。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

class ResumeButton extends StatefulWidget {
  const ResumeButton({
    super.key,
    required this.onResume,
    required this.onDismiss,
    this.freeDrag = false,
  });

  final VoidCallback onResume;

  /// 拖过阈值松手(飞出动画播完)后回调:丢弃记录 + 收起按钮。
  final VoidCallback onDismiss;

  /// 任意方向拖拽(手机端);false 仅水平。
  final bool freeDrag;

  @override
  State<ResumeButton> createState() => _ResumeButtonState();
}

class _ResumeButtonState extends State<ResumeButton>
    with SingleTickerProviderStateMixin {
  /// 拖动阈值(逻辑像素,按位移距离):超过即视为「推走清除」。
  static const _kDismissDist = 88.0;

  /// 飞出距离:在松手位移的基础上沿原方向继续推远。
  static const _kFlyExtra = 260.0;

  /// 拖动渐淡:阈值距离时淡到 0.25(仍可见可回弹),拖远趋近透明。
  static final _kFadeSpan = _kDismissDist * 2.2;

  late final AnimationController _t;
  Offset _offset = Offset.zero;
  double _opacity = 1;

  // 回位/飞出的补间参数(_t 驱动,见 _onTick)。
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  int _mode = 0; // 0=idle 1=回位 2=飞出

  @override
  void initState() {
    super.initState();
    // unbounded 时钟:回位走 1s 弹簧、飞出走 220ms easeIn,统一由 _onTick 换算。
    _t = AnimationController.unbounded(vsync: this)..addListener(_onTick);
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _onDragUpdate(Offset delta) {
    if (_mode != 0) return;
    setState(() {
      _offset += delta;
      _opacity = (1 - _offset.distance / _kFadeSpan).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd() {
    if (_mode != 0) return;
    if (_offset.distance >= _kDismissDist) {
      // 飞出:沿拖动方向继续推远 + 淡出(加速离场,220ms)。
      _mode = 2;
      _from = _offset;
      _startOpacity = _opacity;
      final dir = _offset.distance == 0 ? const Offset(1, 0) : _offset / _offset.distance;
      _to = _offset + dir * _kFlyExtra;
      _t.value = 0;
      _t.animateTo(1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.linear);
    } else {
      // 回位:弹簧(AppSprings.gentle),progress 过冲 >1 时位移反向过零
      // ——按钮轻微越过原位再稳住,真实弹簧味。
      _mode = 1;
      _from = _offset;
      _to = Offset.zero;
      _t.value = 0;
      _t.animateTo(1,
          duration: const Duration(seconds: 1), curve: Curves.linear);
    }
  }

  void _onTick() {
    if (_mode == 1) {
      final tSec = _t.value; // 1s 线性时钟,直接当秒
      final progress =
          AppSprings.simulation(from: 0, to: 1, spring: AppSprings.gentle)
              .x(tSec);
      setState(() {
        final k = (1 - progress.clamp(-0.35, 1.35));
        _offset = _from * k;
        _opacity = (1 - _offset.distance / _kFadeSpan).clamp(0.0, 1.0);
      });
      if (progress > 0.999) {
        _mode = 0;
        _t.stop();
        _offset = Offset.zero;
        _opacity = 1;
      }
    } else if (_mode == 2) {
      final p = Curves.easeInCubic.transform(_t.value.clamp(0.0, 1.0));
      setState(() {
        _offset = Offset.lerp(_from, _to, p)!;
        _opacity = (1 - p) * _startOpacity;
      });
      if (_t.isCompleted && mounted) {
        widget.onDismiss();
      }
    }
  }

  /// 飞出起点的透明度(从拖淡状态继续淡到 0,不闪白)。
  double _startOpacity = 1;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: widget.freeDrag ? (d) => _onDragUpdate(d.delta) : null,
      onPanEnd: widget.freeDrag ? (_) => _onDragEnd() : null,
      onHorizontalDragUpdate:
          widget.freeDrag ? null : (d) => _onDragUpdate(Offset(d.delta.dx, 0)),
      onHorizontalDragEnd: widget.freeDrag ? null : (_) => _onDragEnd(),
      child: Opacity(
        opacity: _opacity,
        child: Transform.translate(
          offset: _offset,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.accent),
              foregroundColor: AppColors.text,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            // 飞出过程中禁点(即将消失);拖动回位后位移归零正常可点。
            onPressed: _mode == 2 ? null : widget.onResume,
            child: Text(
              tr('resume_btn'),
              style: const TextStyle(
                fontFamily: 'Space Mono',
                height: 1.2,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
