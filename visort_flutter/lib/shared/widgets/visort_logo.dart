// VISORT logo —— 标题栏品牌字（V 主题绿 + ISORT 继承前景色）
//
// 入场特效：六个字母依次从下往上滑入，轨迹被 ClipRect 裁在 logo 自身
// 边界内 → 动画不会溢出到标题栏以外的区域。
// 触发时机：仅冷启动（进程创建后的首个实例）播放一次。是否播放由
// static _entrancePlayed 闸门控制（跨实例共享）：流程页 popTo Home、
// 相册返回等场景重建首页时 logo 已播过，直接静态呈现；后台热启动
// （moveTaskToBack 后进程未死）同样不重播。

import 'package:flutter/material.dart';

import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

/// 标题栏 logo。默认 22px Syne ExtraBold，与各屏既有样式一致。
class VisortLogo extends StatefulWidget {
  const VisortLogo({super.key, this.fontSize = 22});

  final double fontSize;

  @override
  State<VisortLogo> createState() => _VisortLogoState();
}

class _VisortLogoState extends State<VisortLogo>
    with SingleTickerProviderStateMixin {
  /// 冷启动闸门：入场特效每进程只播一次。
  static bool _entrancePlayed = false;

  /// 本实例是否承担播放（即冷启动时挂载的那一个）。
  late final bool _playing;

  static const _letters = ['V', 'I', 'S', 'O', 'R', 'T'];

  /// 单字母上滑时长 / 相邻字母错峰间隔。
  static const _perLetterMs = 300;
  static const _staggerMs = 55;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _playing = !_entrancePlayed;
    _entrancePlayed = true;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: _perLetterMs + _staggerMs * (_letters.length - 1),
      ),
    );
    if (_playing) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _letters.length; i++) _buildLetter(i),
        ],
      ),
    );
  }

  Widget _buildLetter(int index) {
    final style = TextStyle(
      fontFamily: AppFonts.syne,
      fontFamilyFallback: AppFonts.cjkFallback,
      fontWeight: FontWeight.w800,
      fontSize: widget.fontSize,
      // 首字母 V 主题绿，其余继承 AppBar 前景色（与原 _Logo 一致）。
      color: index == 0 ? AppColors.accent : null,
    );
    if (!_playing) return Text(_letters[index], style: style);

    // 错峰区间 [i×stagger, i×stagger+perLetter] 映射到总时长；
    // couiInEase（极速起步、缓慢落位）贴合「从下往上弹起」的观感。
    final totalMs = _perLetterMs + _staggerMs * (_letters.length - 1);
    final begin = (_staggerMs * index) / totalMs;
    final end = (_staggerMs * index + _perLetterMs) / totalMs;
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Interval(begin, end, curve: AppCurves.couiInEase),
    );
    return SlideTransition(
      position:
          Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(curved),
      child: Text(_letters[index], style: style),
    );
  }
}
