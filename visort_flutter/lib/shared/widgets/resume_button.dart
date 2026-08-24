// 「继续」按钮(P2)—— Home 底栏「开始」左侧的中断恢复入口
//
// 交互分端:
//   - 桌面(freeDrag=false):鼠标悬停时按钮右上角浮出圆形红色叉叉,
//     点击叉叉丢弃持久化会话(160ms 缩淡离场);按钮本体点击恢复。
//   - 手机(freeDrag=true):拖动把按钮推走——拖动过程中按钮透明度随
//     距离渐淡,超过阈值松手沿拖动方向加速飞出(丢弃持久化会话),
//     不过阈值弹簧回位(AppSprings,与弹窗同一套物理,带真实过冲)。

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

  /// 移除记录生效后回调:丢弃记录 + 收起按钮。
  final VoidCallback onDismiss;

  /// 任意方向拖拽清除(手机端);false(桌面)悬停叉叉清除。
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
  double _scale = 1;
  bool _hover = false;

  // 回位/飞出/叉叉离场的补间参数(_t 驱动,见 _onTick)。
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;
  int _mode = 0; // 0=idle 1=回位 2=飞出 3=叉叉离场

  /// 飞出起点的透明度(从拖淡状态继续淡到 0,不闪白)。
  double _startOpacity = 1;

  @override
  void initState() {
    super.initState();
    // unbounded 时钟:回位走 1s 弹簧、飞出/叉叉离场走短线性,统一 _onTick 换算。
    _t = AnimationController.unbounded(vsync: this)..addListener(_onTick);
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  // ───────────── 手机端:拖动清除 ─────────────

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

  // ───────────── 桌面端:叉叉清除 ─────────────

  void _dismissByX() {
    if (_mode != 0) return;
    _mode = 3;
    _t.value = 0;
    _t.animateTo(1,
        duration: const Duration(milliseconds: 160), curve: Curves.linear);
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
    } else if (_mode == 3) {
      // 叉叉离场:快速淡出 + 轻微缩小,播完丢弃记录。
      final p = Curves.easeIn.transform(_t.value.clamp(0.0, 1.0));
      setState(() {
        _opacity = 1 - p;
        _scale = 1 - 0.12 * p;
      });
      if (_t.isCompleted && mounted) {
        widget.onDismiss();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton(
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: AppColors.accent),
        foregroundColor: AppColors.text,
        // 尺寸按端分叉(freeDrag=安卓):桌面与 FilledButton(40)齐平;
        // 安卓保持触屏尺寸(vertical 14 ≈ 48),与安卓「开始」按钮齐平。
        padding: widget.freeDrag
            ? const EdgeInsets.symmetric(horizontal: 20, vertical: 14)
            : const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
        minimumSize: Size(0, widget.freeDrag ? 48 : 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      // 离场过程中禁点(即将消失)。
      onPressed: _mode == 2 || _mode == 3 ? null : widget.onResume,
      child: Text(
        tr('resume_btn'),
        style: const TextStyle(
          fontFamily: 'Space Mono',
          height: 1.2,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
      ),
    );

    final visual = Opacity(
      opacity: _opacity,
      child: Transform.scale(
        scale: _scale,
        child: Transform.translate(
          offset: _offset,
          child: button,
        ),
      ),
    );

    // 拖动清除手势仅手机端注册;桌面无拖动,清除走悬停叉叉。
    final interactive = widget.freeDrag
        ? GestureDetector(
            onPanUpdate: (d) => _onDragUpdate(d.delta),
            onPanEnd: (_) => _onDragEnd(),
            child: visual,
          )
        : visual;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          interactive,
          if (!widget.freeDrag)
            Positioned(top: -8, right: -8, child: _buildDismissX()),
        ],
      ),
    );
  }

  /// 悬停浮出的圆形红色叉叉(右上角骑缝):点击丢弃记录。
  Widget _buildDismissX() {
    return IgnorePointer(
      ignoring: !_hover,
      child: AnimatedOpacity(
        opacity: _hover ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedScale(
          scale: _hover ? 1 : 0.5,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutBack,
          child: GestureDetector(
            onTap: _dismissByX,
            behavior: HitTestBehavior.opaque,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  shape: BoxShape.circle,
                  // 与背景同色描边:红色圆在按钮边角上「隔底」更利落。
                  border: Border.all(color: AppColors.bg, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(Icons.close, size: 12, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
