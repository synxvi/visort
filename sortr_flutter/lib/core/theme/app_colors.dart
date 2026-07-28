// 应用配色 —— 完整还原 index.html CSS 变量（:root）
//
// 源: index.html:75-88
//   --bg:#0d0d0d  --surface:#161616  --border:#2a2a2a
//   --accent:#e8ff47  --accent2:#ff6b35
//   --text:#f0f0f0  --muted:#666
//   --danger:#ff3b3b  --success:#3bff8a

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
  // 系统正文字体（源 --sans）
  static const sans = ['Segoe UI', 'Microsoft YaHei', 'PingFang SC', 'Roboto'];

  /// CJK 回退字体。首选用打包的 NotoSansSC（确定可用，不依赖系统字体安装）。
  ///
  /// 背景：Flutter 桌面端 fontFamilyFallback 引用系统已安装字体不可靠
  /// （flutter/flutter#103811），Windows 上 Microsoft YaHei 经常不生效，
  /// 中文渲染成豆腐块。因此必须打包一个支持中文的字体文件。
  /// NotoSansSC 已子集化（仅 GB2312 常用字 + 标点，约 7MB）。
  static const cjkFallback = ['NotoSansSC', 'Microsoft YaHei', 'PingFang SC'];
}
