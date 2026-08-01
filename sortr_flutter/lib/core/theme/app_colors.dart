// 应用配色 —— 完整还原 index.html CSS 变量（:root）
//
// 源: index.html:75-88
//   --bg:#0d0d0d  --surface:#161616  --border:#2a2a2a
//   --accent:#e8ff47  --accent2:#ff6b35
//   --text:#f0f0f0  --muted:#666
//   --danger:#ff3b3b  --success:#3bff8a

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // 主色板
  static const bg = Color(0xFF0D0D0D);
  static const surface = Color(0xFF161616);
  static const border = Color(0xFF2A2A2A);
  static const accent = Color(0xFFE8FF47); // 主强调，亮黄绿
  static const accent2 = Color(0xFFFF6B35); // 次强调，橙红（用于 undecided）
  static const text = Color(0xFFF0F0F0);
  static const muted = Color(0xFF666666);
  static const danger = Color(0xFFFF3B3B);
  static const success = Color(0xFF3BFF8A);

  // 派生（hover 色，源 index.html:259,279,281）
  static const accentHover = Color(0xFFFFFFFF);
  static const dangerHover = Color(0xFFFF6060);
  static const successHover = Color(0xFF70FFB0);

  // 带透明度的语义色（源 index.html badge/root-dir）
  static Color accentWithOpacity(double a) => accent.withValues(alpha: a);
  static Color dangerWithOpacity(double a) => danger.withValues(alpha: a);
  static Color mutedWithOpacity(double a) => muted.withValues(alpha: a);

  // badge 透明背景
  static final badgeMove = accentWithOpacity(0.15);
  static final badgeDelete = dangerWithOpacity(0.15);
  static final badgeSkip = mutedWithOpacity(0.2);

  // root-dir 按钮
  static final rootDirBg = accentWithOpacity(0.05);
  static final rootDirBgHover = accentWithOpacity(0.10);

  // header / overlay 半透明背景（源 index.html:126, 756）
  static const headerBg = Color(0xEB0D0D0D); // rgba(13,13,13,0.92)
  static const overlayBg = Color(0xF00D0D0D); // rgba(13,13,13,0.94)
}

// ───────────────────── 字体族名常量 ─────────────────────
class AppFonts {
  AppFonts._();
  static const syne = 'Syne';
  static const spaceMono = 'SpaceMono';

  /// 系统正文字体（源 --sans）。按平台返回，避免在不存在的字体上浪费查找：
  /// 安卓用 Roboto（系统原生、零加载成本），Windows 用 Segoe UI。
  /// 仅在 app_theme.dart 通过 `.first` 取主字体，非 const 上下文。
  static List<String> get sans => Platform.isAndroid
      ? const ['Roboto', 'Segoe UI', 'Microsoft YaHei']
      : const ['Segoe UI', 'Microsoft YaHei', 'PingFang SC', 'Roboto'];

  /// CJK 回退字体链（保持 const，被 40+ 处 const TextStyle 引用）。
  ///
  /// 首选思源等宽（Noto Sans Mono CJK SC），与 SpaceMono 等宽英文风格统一；
  /// 其后按平台接系统 CJK 字体兜底（安卓 Noto/Source Han，Windows 微软雅黑/苹方）。
  static const cjkFallback = [
    'Noto Sans Mono CJK SC',
    // Android 系统兜底（设备无 Mono 版本时回退比例字体）
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'sans-serif',
    // Windows / macOS 兜底
    'Microsoft YaHei',
    'PingFang SC',
  ];
}
