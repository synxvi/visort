// Toast 组件 —— 右下角短暂提示（对应前端 #toast，3.5 秒消失）
//
// 用 Overlay，任意位置调用 toast(context, message)。

import 'package:flutter/material.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

/// 显示一条 toast，3.5 秒后自动消失
void toast(BuildContext context, String message) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(builder: (ctx) => _ToastView(message: message));
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 3500), () {
    entry.remove();
  });
}

class _ToastView extends StatefulWidget {
  const _ToastView({required this.message});
  final String message;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _controller.forward();
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) _controller.reverse();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      right: 24,
      child: FadeTransition(
        opacity: _controller,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              widget.message,
              style: const TextStyle(
                fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                fontSize: 13,
                color: AppColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
