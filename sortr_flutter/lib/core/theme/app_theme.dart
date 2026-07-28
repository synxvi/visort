// 应用主题 —— 暗色主题，对应 index.html 的整体视觉
//
// 字体策略（源 index.html:95,130-135,248,568 等）：
//   - logo / 大标题：Syne（ExtraBold 800）
//   - 技术信息（文件名/快捷键/统计/表格）：SpaceMono
//   - 正文 / 按钮：系统 sans（Segoe UI / 微软雅黑）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: AppColors.bg,
      secondary: AppColors.accent2,
      surface: AppColors.surface,
      onSurface: AppColors.text,
      error: AppColors.danger,
      onError: Colors.white,
    ),
    dividerColor: AppColors.border,
    // 字体在 textTheme 内逐个指定（Syne / SpaceMono / 系统 sans）
    textTheme: _buildTextTheme(base.textTheme),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.headerBg,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: const TextStyle(color: AppColors.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    iconTheme: const IconThemeData(color: AppColors.text),
  );
}

TextTheme _buildTextTheme(TextTheme base) {
  // 正文：系统 sans（Flutter 不支持 CSS 的逗号列表，主字体单独指定，
  // 中文/其他字符通过 fontFamilyFallback 回退）
  final sansFamily = AppFonts.sans.first;
  // logo / 标题：Syne
  const syneFamily = AppFonts.syne;
  // 技术信息：SpaceMono
  const monoFamily = AppFonts.spaceMono;

  // 中文回退字体（SpaceMono / Syne 都不含中文，必须回退）
  const cjkFallback = ['Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'sans-serif'];

  TextStyle syneStyle(TextStyle? s, {FontWeight? w, Color? c}) => TextStyle(
        fontFamily: syneFamily,
        fontWeight: w ?? s?.fontWeight,
        color: c ?? s?.color,
        fontSize: s?.fontSize,
        fontFamilyFallback: cjkFallback,
      );
  TextStyle monoStyle(TextStyle? s, {Color? c}) => TextStyle(
        fontFamily: monoFamily,
        fontWeight: s?.fontWeight,
        color: c ?? s?.color,
        fontSize: s?.fontSize,
        fontFamilyFallback: cjkFallback,
      );
  TextStyle sansStyle(TextStyle? s, {Color? c, FontWeight? w}) => TextStyle(
        fontFamily: sansFamily,
        fontWeight: w ?? s?.fontWeight,
        color: c ?? s?.color,
        fontSize: s?.fontSize,
        fontFamilyFallback: cjkFallback,
      );

  return base.copyWith(
    // 大标题（Results h2 等）：Syne ExtraBold
    displayLarge: syneStyle(base.displayLarge, w: FontWeight.w800, c: AppColors.text),
    displayMedium: syneStyle(base.displayMedium, w: FontWeight.w800, c: AppColors.text),
    // 普通标题
    titleLarge: syneStyle(base.titleLarge, w: FontWeight.w700, c: AppColors.text),
    titleMedium: sansStyle(base.titleMedium, w: FontWeight.w700, c: AppColors.text),
    // 正文
    bodyLarge: sansStyle(base.bodyLarge, c: AppColors.text),
    bodyMedium: sansStyle(base.bodyMedium, c: AppColors.text),
    bodySmall: sansStyle(base.bodySmall, c: AppColors.muted),
    // 技术信息（文件名/统计/快捷键/表格）
    labelLarge: monoStyle(base.labelLarge, c: AppColors.text),
    labelMedium: monoStyle(base.labelMedium, c: AppColors.text),
    labelSmall: monoStyle(base.labelSmall, c: AppColors.muted),
  );
}
