// Loading Overlay —— 全屏遮罩（对应前端 #loading-overlay）
//
// scan / run 时显示，含 spinner + 文字。

import 'package:flutter/material.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: AppColors.overlayBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                style: const TextStyle(
                  fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 13,
                  color: AppColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
