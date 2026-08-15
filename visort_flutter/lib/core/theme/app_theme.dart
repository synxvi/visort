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
      // edge-to-edge：系统栏透明叠加在内容之上，图标用亮色适配深底。
      // 仅在 AppBar 出现的页面生效（作为兜底；main() 已全局设置一次）。
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted),
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
    // 全局去除 Material 的波纹/高亮点击动画（InkWell ripple & highlight）
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: AppColors.surface,
    // 菜单弹层（PopupMenu / MenuBar / Menu）—— 全局暗色 + 零阴影，
    // 避免展开动画起始帧用 M3 默认亮色 Material 绘制导致的白色闪烁。
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(AppColors.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          side: const BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(6),
        )),
      ),
    ),
    menuBarTheme: const MenuBarThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.surface),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
      ),
    ),
  );
}

TextTheme _buildTextTheme(TextTheme base) {
  // 全局字体规则：英文/数字 Space Mono，中文回退思源（Noto Sans Mono CJK SC）。
  // logo / 大标题保留 Syne 品牌字。
  const syneFamily = AppFonts.syne;
  const monoFamily = AppFonts.spaceMono;

  // 中文回退字体（SpaceMono / Syne 都不含中文，回退到打包的思源）
  const cjkFallback = AppFonts.cjkFallback;

  TextStyle syneStyle(TextStyle? s, {FontWeight? w, Color? c}) => TextStyle(
        fontFamily: syneFamily,
        fontWeight: w ?? s?.fontWeight,
        color: c ?? s?.color,
        fontSize: s?.fontSize,
        fontFamilyFallback: cjkFallback,
      );
  TextStyle monoStyle(TextStyle? s, {Color? c, FontWeight? w}) => TextStyle(
        fontFamily: monoFamily,
        fontWeight: w ?? s?.fontWeight,
        color: c ?? s?.color,
        fontSize: s?.fontSize,
        // SpaceMono 默认行高偏大(字符盒高),显式压到 1.2 避免纵向拉长感。
        height: 1.2,
        fontFamilyFallback: cjkFallback,
      );

  return base.copyWith(
    // 大标题（Results h2 等）：Syne ExtraBold
    displayLarge: syneStyle(base.displayLarge, w: FontWeight.w800, c: AppColors.text),
    displayMedium: syneStyle(base.displayMedium, w: FontWeight.w800, c: AppColors.text),
    // 普通标题
    titleLarge: syneStyle(base.titleLarge, w: FontWeight.w700, c: AppColors.text),
    titleMedium: monoStyle(base.titleMedium, w: FontWeight.w700, c: AppColors.text),
    // 正文
    bodyLarge: monoStyle(base.bodyLarge, c: AppColors.text),
    bodyMedium: monoStyle(base.bodyMedium, c: AppColors.text),
    bodySmall: monoStyle(base.bodySmall, c: AppColors.muted),
    // 技术信息（文件名/统计/快捷键/表格）
    labelLarge: monoStyle(base.labelLarge, c: AppColors.text),
    labelMedium: monoStyle(base.labelMedium, c: AppColors.text),
    labelSmall: monoStyle(base.labelSmall, c: AppColors.muted),
  );
}
