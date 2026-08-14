// [ente 移植] 自定义滚动条 —— 原文件：ente .../ui/viewer/gallery/scrollbar/custom_scroll_bar.dart
// 适配：
//   - ScrollbarWithUseNotifer 内联移植（原 ente scrollbar/scroll_bar_with_use_notifier.dart，
//     Flutter RawScrollbar 的 BSD 派生）：拇指按下/抬起上报 inUseNotifier，
//     驱动 PinnedGroupHeader 放大与分区标题浮层。
//   - 主题 ente_theme → AppColors；getIntrinsicSizeOfWidget → TextPainter 同步测量；
//     MiscUtil.getNonZeroDoubleWithRetry → 本地 _getNonZeroDoubleWithRetry。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

import 'gallery_groups.dart';
import 'group_type.dart';

// ScrollBarDivider 的文本样式（ente miniMuted 等价：12px muted）。
const _dividerTextStyle = TextStyle(
  fontSize: 12,
  height: 1.4,
  color: AppColors.muted,
);

/// 网格滚动条：拇指 + 长画廊分区标题浮层（拖动时跟随 thumb 显示分区标题）。
class CustomScrollBar extends StatefulWidget {
  final Widget child;
  final ValueNotifier<double> bottomPadding;
  final double topPadding;
  final ScrollController scrollController;
  final GalleryGroups galleryGroups;
  final ValueNotifier<bool> inUseNotifier;
  final double heighOfViewport;
  const CustomScrollBar({
    super.key,
    required this.child,
    required this.scrollController,
    required this.galleryGroups,
    required this.inUseNotifier,
    required this.heighOfViewport,
    required this.bottomPadding,
    required this.topPadding,
  });

  @override
  State<CustomScrollBar> createState() => _CustomScrollBarState();
}

class _CustomScrollBarState extends State<CustomScrollBar> {
  final _scrollbarKey = GlobalKey();
  List<({double position, String title})>? positionToTitleMap;
  double? heightOfScrollbarDivider;
  double? heightOfScrollTrack;
  late bool _showThumb;

  // Divisions only appear in long galleries, where the thumb stays at this
  // minimum height.
  static const _kScrollbarMinLength = 36.0;

  @override
  void initState() {
    super.initState();
    _init();
    widget.bottomPadding.addListener(_computePositionToTitleMap);
  }

  @override
  void didUpdateWidget(covariant CustomScrollBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _init();
  }

  @override
  void dispose() {
    widget.bottomPadding.removeListener(_computePositionToTitleMap);
    super.dispose();
  }

  void _init() {
    final groupLayouts = widget.galleryGroups.groupLayouts;
    if (groupLayouts.isEmpty) {
      _showThumb = false;
      return;
    }
    final showScrollbarDivisions =
        widget.galleryGroups.groupType.showScrollbarDivisions() &&
        groupLayouts.last.maxOffset > widget.heighOfViewport * 8;

    _showThumb = groupLayouts.last.maxOffset > widget.heighOfViewport * 3;

    if (showScrollbarDivisions) {
      heightOfScrollbarDivider = _measureDividerHeight();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _computePositionToTitleMap();
      });
    }
  }

  /// ScrollBarDivider 的固有高度（文本行高 + 上下 padding 4×2）。
  double _measureDividerHeight() {
    final textPainter = TextPainter(
      text: const TextSpan(text: 'Temp', style: _dividerTextStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    try {
      return textPainter.height + 8;
    } finally {
      textPainter.dispose();
    }
  }

  // Division positions ignore header and footer heights. They are negligible
  // in the long galleries that show divisions.
  Future<void> _computePositionToTitleMap() async {
    final result = <({double position, String title})>[];
    heightOfScrollTrack = await _getHeightOfScrollTrack();
    if (!mounted ||
        heightOfScrollTrack == null ||
        heightOfScrollTrack! <= 0 ||
        heightOfScrollbarDivider == null ||
        !widget.scrollController.hasClients) {
      return;
    }
    final maxScrollExtent = widget.scrollController.position.maxScrollExtent;
    if (maxScrollExtent <= 0) {
      return;
    }

    for (final scrollbarDivision in widget.galleryGroups.scrollbarDivisions) {
      final scrollOffsetOfGroup = widget
          .galleryGroups
          .groupIdToScrollOffsetMap[scrollbarDivision.groupID];
      if (scrollOffsetOfGroup == null) {
        continue;
      }

      final groupScrollOffsetToUse = scrollOffsetOfGroup - heightOfScrollTrack!;
      if (groupScrollOffsetToUse < 0) {
        result.add((position: 0, title: scrollbarDivision.title));
      } else {
        // Account for the thumb's height so each label lines up with its
        // gallery section while dragging.
        final fractionOfGroupScrollOffsetWrtMaxExtent =
            groupScrollOffsetToUse / maxScrollExtent;
        late final double positionCorrection;

        // Offset between the thumb and label centers at the top.
        final value = (_kScrollbarMinLength - heightOfScrollbarDivider!) / 2;

        if (fractionOfGroupScrollOffsetWrtMaxExtent < 0.5) {
          positionCorrection =
              value * fractionOfGroupScrollOffsetWrtMaxExtent -
              (heightOfScrollbarDivider! *
                  fractionOfGroupScrollOffsetWrtMaxExtent);
        } else {
          positionCorrection =
              -value * fractionOfGroupScrollOffsetWrtMaxExtent -
              (heightOfScrollbarDivider! *
                  fractionOfGroupScrollOffsetWrtMaxExtent);
        }

        final adaptedPosition =
            heightOfScrollTrack! * fractionOfGroupScrollOffsetWrtMaxExtent +
            positionCorrection;

        result.add((position: adaptedPosition, title: scrollbarDivision.title));
      }
    }
    final filteredResult = <({double position, String title})>[];

    if (result.isEmpty) {
      return;
    }

    // The first division marks the top and adds no useful landmark.
    result.removeAt(0);

    // Keep division labels at least 48 pixels apart.
    if (result.isNotEmpty) {
      filteredResult.add(result.first);
      for (int i = 1; i < result.length; i++) {
        if ((result[i].position - filteredResult.last.position).abs() >= 48) {
          filteredResult.add(result[i]);
        }
      }
    }
    if (mounted) {
      setState(() {
        positionToTitleMap = filteredResult;
      });
    }
  }

  Future<double> _getHeightOfScrollTrack() {
    final renderBox =
        _scrollbarKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return Future.value(0);
    }
    // RenderBox height may initially be zero:
    // https://github.com/flutter/flutter/issues/25827
    return _getNonZeroDoubleWithRetry(() => renderBox.size.height).then(
      (value) => value - widget.bottomPadding.value - widget.topPadding,
    );
  }

  Future<double> _getNonZeroDoubleWithRetry(
    double Function() getValue, {
    int maxRetries = 10,
    Duration retryInterval = const Duration(milliseconds: 100),
  }) async {
    for (int i = 0; i < maxRetries; i++) {
      final value = getValue();
      if (value != 0) return value;
      await Future<void>.delayed(retryInterval);
    }
    return getValue();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerLeft,
      children: [
        _ScrollbarWithUseNotifier(
          key: _scrollbarKey,
          controller: widget.scrollController,
          interactive: true,
          inUseNotifier: widget.inUseNotifier,
          minScrollbarLength: _kScrollbarMinLength,
          showThumb: _showThumb,
          radius: const Radius.circular(4),
          thickness: 8,
          scrollbarPadding: EdgeInsets.only(
            bottom: widget.bottomPadding.value,
            top: widget.topPadding,
            right: 3,
          ),
          child: widget.child,
        ),
        positionToTitleMap == null || heightOfScrollbarDivider == null
            ? const SizedBox.shrink()
            : Padding(
                padding: EdgeInsets.only(
                  top: widget.topPadding,
                  bottom: widget.bottomPadding.value,
                ),
                child: ValueListenableBuilder<bool>(
                  valueListenable: widget.inUseNotifier,
                  builder: (context, inUse, _) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      child: !inUse
                          ? const SizedBox.shrink()
                          : Stack(
                              clipBehavior: Clip.none,
                              children: positionToTitleMap!.map((record) {
                                return Positioned(
                                  top: record.position,
                                  right: 32,
                                  child: ScrollBarDivider(title: record.title),
                                );
                              }).toList(),
                            ),
                    );
                  },
                ),
              ),
      ],
    );
  }
}

class ScrollBarDivider extends StatelessWidget {
  final String title;
  const ScrollBarDivider({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 3,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Center(
        child: Text(title, style: _dividerTextStyle, maxLines: 1),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Flutter 的 Scrollbar 修改版：拇指被按下/抬起时上报 inUseNotifier。
// 原文件：ente .../ui/viewer/gallery/scrollbar/scroll_bar_with_use_notifier.dart
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// ─────────────────────────────────────────────────────────────────────────────

const double _kScrollbarThickness = 8.0;
const double _kScrollbarThicknessWithTrack = 12.0;
const double _kScrollbarMargin = 2.0;
const Radius _kScrollbarRadius = Radius.circular(8.0);
const Duration _kScrollbarFadeDuration = Duration(milliseconds: 300);
const Duration _kScrollbarTimeToFade = Duration(milliseconds: 600);

class _ScrollbarWithUseNotifier extends RawScrollbar {
  final ValueNotifier<bool> inUseNotifier;
  final double minScrollbarLength;
  final bool? showThumb;
  final EdgeInsets? scrollbarPadding;
  const _ScrollbarWithUseNotifier({
    super.key,
    required super.child,
    required this.inUseNotifier,
    required this.minScrollbarLength,
    required this.showThumb,
    required this.scrollbarPadding,
    super.controller,
    super.thumbVisibility,
    super.trackVisibility,
    super.thickness,
    super.radius,
    ScrollNotificationPredicate? notificationPredicate,
    super.interactive,
    super.scrollbarOrientation,
  }) : super(
         fadeDuration: _kScrollbarFadeDuration,
         timeToFade: _kScrollbarTimeToFade,
         pressDuration: Duration.zero,
         notificationPredicate:
             notificationPredicate ?? defaultScrollNotificationPredicate,
       );

  @override
  _ScrollbarWithUseNotifierState createState() {
    return _ScrollbarWithUseNotifierState();
  }
}

class _ScrollbarWithUseNotifierState extends RawScrollbarState<
  _ScrollbarWithUseNotifier
> {
  late AnimationController _hoverAnimationController;
  bool _dragIsActive = false;
  bool _hoverIsActive = false;
  late ColorScheme _colorScheme;
  late ScrollbarThemeData _scrollbarTheme;
  late bool _useAndroidScrollbar;

  @override
  bool get showScrollbar =>
      widget.thumbVisibility ??
      _scrollbarTheme.thumbVisibility?.resolve(_states) ??
      false;

  @override
  bool get enableGestures =>
      widget.interactive ?? _scrollbarTheme.interactive ?? !_useAndroidScrollbar;

  WidgetStateProperty<bool> get _trackVisibility =>
      WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        return widget.trackVisibility ??
            _scrollbarTheme.trackVisibility?.resolve(states) ??
            false;
      });

  Set<WidgetState> get _states => <WidgetState>{
    if (_dragIsActive) WidgetState.dragged,
    if (_hoverIsActive) WidgetState.hovered,
  };

  WidgetStateProperty<Color> get _thumbColor {
    if (widget.showThumb == false) {
      return WidgetStateProperty.all(const Color(0x00000000));
    }
    // visort 主题色：AppColors.text 为 onSurface 基底。
    final Color onSurface = AppColors.text;
    final Brightness brightness = _colorScheme.brightness;
    late Color dragColor;
    late Color hoverColor;
    late Color idleColor;
    switch (brightness) {
      case Brightness.light:
        dragColor = onSurface.withValues(alpha: 0.6);
        hoverColor = onSurface.withValues(alpha: 0.5);
        idleColor = _useAndroidScrollbar
            ? Theme.of(context).highlightColor.withValues(alpha: 1.0)
            : onSurface.withValues(alpha: 0.1);
      case Brightness.dark:
        dragColor = onSurface.withValues(alpha: 0.75);
        hoverColor = onSurface.withValues(alpha: 0.65);
        idleColor = _useAndroidScrollbar
            ? Theme.of(context).highlightColor.withValues(alpha: 1.0)
            : onSurface.withValues(alpha: 0.3);
    }

    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.dragged)) {
        return _scrollbarTheme.thumbColor?.resolve(states) ?? dragColor;
      }

      // A visible track changes the thumb color without the hover animation.
      if (_trackVisibility.resolve(states)) {
        return _scrollbarTheme.thumbColor?.resolve(states) ?? hoverColor;
      }

      return Color.lerp(
        _scrollbarTheme.thumbColor?.resolve(states) ?? idleColor,
        _scrollbarTheme.thumbColor?.resolve(states) ?? hoverColor,
        _hoverAnimationController.value,
      )!;
    });
  }

  WidgetStateProperty<Color> get _trackColor {
    if (widget.showThumb == false) {
      return WidgetStateProperty.all(const Color(0x00000000));
    }
    final Color onSurface = AppColors.text;
    final Brightness brightness = _colorScheme.brightness;
    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (showScrollbar && _trackVisibility.resolve(states)) {
        return _scrollbarTheme.trackColor?.resolve(states) ??
            switch (brightness) {
              Brightness.light => onSurface.withValues(alpha: 0.03),
              Brightness.dark => onSurface.withValues(alpha: 0.05),
            };
      }
      return const Color(0x00000000);
    });
  }

  WidgetStateProperty<Color> get _trackBorderColor {
    if (widget.showThumb == false) {
      return WidgetStateProperty.all(const Color(0x00000000));
    }
    final Color onSurface = AppColors.text;
    final Brightness brightness = _colorScheme.brightness;
    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (showScrollbar && _trackVisibility.resolve(states)) {
        return _scrollbarTheme.trackBorderColor?.resolve(states) ??
            switch (brightness) {
              Brightness.light => onSurface.withValues(alpha: 0.1),
              Brightness.dark => onSurface.withValues(alpha: 0.25),
            };
      }
      return const Color(0x00000000);
    });
  }

  WidgetStateProperty<double> get _thickness {
    return WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.hovered) &&
          _trackVisibility.resolve(states)) {
        return widget.thickness ??
            _scrollbarTheme.thickness?.resolve(states) ??
            _kScrollbarThicknessWithTrack;
      }
      return widget.thickness ??
          _scrollbarTheme.thickness?.resolve(states) ??
          (_kScrollbarThickness / (_useAndroidScrollbar ? 2 : 1));
    });
  }

  @override
  void initState() {
    super.initState();
    _hoverAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _hoverAnimationController.addListener(() {
      updateScrollbarPainter();
    });
  }

  @override
  void didChangeDependencies() {
    final ThemeData theme = Theme.of(context);
    _colorScheme = theme.colorScheme;
    _scrollbarTheme = ScrollbarTheme.of(context);
    switch (theme.platform) {
      case TargetPlatform.android:
        _useAndroidScrollbar = true;
      case TargetPlatform.iOS:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        _useAndroidScrollbar = false;
    }
    super.didChangeDependencies();
  }

  @override
  void updateScrollbarPainter() {
    scrollbarPainter
      ..color = _thumbColor.resolve(_states)
      ..trackColor = _trackColor.resolve(_states)
      ..trackBorderColor = _trackBorderColor.resolve(_states)
      ..textDirection = Directionality.of(context)
      ..thickness = _thickness.resolve(_states)
      ..radius =
          widget.radius ??
          _scrollbarTheme.radius ??
          (_useAndroidScrollbar ? null : _kScrollbarRadius)
      ..crossAxisMargin =
          _scrollbarTheme.crossAxisMargin ??
          (_useAndroidScrollbar ? 0.0 : _kScrollbarMargin)
      ..mainAxisMargin = _scrollbarTheme.mainAxisMargin ?? 0.0
      ..minLength = widget.minScrollbarLength
      ..padding = widget.scrollbarPadding ?? MediaQuery.paddingOf(context)
      ..scrollbarOrientation = widget.scrollbarOrientation
      ..ignorePointer = !enableGestures;
  }

  @override
  void handleThumbPressStart(Offset localPosition) {
    super.handleThumbPressStart(localPosition);
    setState(() {
      _dragIsActive = true;
      widget.inUseNotifier.value = true;
    });
  }

  @override
  void handleThumbPressEnd(Offset localPosition, Velocity velocity) {
    super.handleThumbPressEnd(localPosition, velocity);
    setState(() {
      _dragIsActive = false;
      widget.inUseNotifier.value = false;
    });
  }

  @override
  void handleHover(PointerHoverEvent event) {
    super.handleHover(event);
    if (isPointerOverScrollbar(event.position, event.kind, forHover: true)) {
      setState(() {
        _hoverIsActive = true;
      });
      _hoverAnimationController.forward();
    } else if (_hoverIsActive) {
      setState(() {
        _hoverIsActive = false;
      });
      _hoverAnimationController.reverse();
    }
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    super.handleHoverExit(event);
    setState(() {
      _hoverIsActive = false;
    });
    _hoverAnimationController.reverse();
  }

  @override
  void dispose() {
    _hoverAnimationController.dispose();
    super.dispose();
  }
}
