// [ente 移植] 大图页共享状态 —— 原样复制（去掉 EnteFile 依赖的标识函数）
// 原文件：ente mobile/apps/photos/lib/states/detail_page_state.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Scale is relative to the contained image; offset is in logical pixels.
@immutable
class ZoomTransform {
  static const ZoomTransform identity = ZoomTransform(
    scale: 1.0,
    offset: Offset.zero,
  );

  final double scale;
  final Offset offset;

  const ZoomTransform({required this.scale, required this.offset});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomTransform && other.scale == scale && other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);
}

enum FullScreenRequestReason { userInteraction, playbackStateChange }

typedef FullScreenRequestCallback =
    void Function(bool shouldEnable, FullScreenRequestReason reason);

class InheritedDetailPageState extends InheritedWidget {
  final ValueNotifier<bool> enableFullScreenNotifier;
  final ValueNotifier<bool> isInSharedCollectionNotifier;
  final ValueNotifier<String?> showingThumbnailFallbackNotifier;
  final ValueNotifier<bool> isZoomedNotifier;

  /// [顶层双击路由] pageIndex → 该页双击处理（global 坐标）。
  /// Scrollable ballistic 中 ignorePointer 屏蔽页内 tap，双击由
  /// DetailPage 顶层捕获后按当前页索引分发。
  final Map<int, void Function(Offset globalPosition)> doubleTapHandlers;
  final ValueNotifier<ZoomTransform> zoomTransformNotifier;

  /// 图片区单击回调（DetailPage 注入）：详情面板打开时收面板，否则全屏切换。
  final VoidCallback? onImageTap;

  // ignore: prefer_const_constructors_in_immutables
  InheritedDetailPageState({
    super.key,
    required super.child,
    required this.enableFullScreenNotifier,
    required this.isInSharedCollectionNotifier,
    required this.showingThumbnailFallbackNotifier,
    required this.isZoomedNotifier,
    required this.doubleTapHandlers,
    required this.zoomTransformNotifier,
    this.onImageTap,
  });

  static InheritedDetailPageState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedDetailPageState>()!;

  static InheritedDetailPageState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedDetailPageState>();

  void toggleFullScreenByUser() {
    // DetailPage 可注入单击覆盖（详情面板打开时收面板，而非切换全屏）。
    if (onImageTap != null) {
      onImageTap!();
      return;
    }
    _applyFullScreenState(!enableFullScreenNotifier.value);
  }

  void requestFullScreen({
    required bool shouldEnable,
    required FullScreenRequestReason reason,
  }) {
    if (!shouldEnable && reason != FullScreenRequestReason.userInteraction) {
      return;
    }
    if (enableFullScreenNotifier.value == shouldEnable) {
      return;
    }
    _applyFullScreenState(shouldEnable);
  }

  void _applyFullScreenState(bool shouldEnable) {
    if (enableFullScreenNotifier.value == shouldEnable) {
      return;
    }
    enableFullScreenNotifier.value = shouldEnable;
    if (shouldEnable) {
      Future.delayed(const Duration(milliseconds: 200), () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      });
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  @override
  bool updateShouldNotify(InheritedDetailPageState oldWidget) =>
      oldWidget.enableFullScreenNotifier != enableFullScreenNotifier ||
      oldWidget.isInSharedCollectionNotifier != isInSharedCollectionNotifier ||
      oldWidget.showingThumbnailFallbackNotifier !=
          showingThumbnailFallbackNotifier ||
      oldWidget.isZoomedNotifier != isZoomedNotifier ||
      oldWidget.zoomTransformNotifier != zoomTransformNotifier;
}
