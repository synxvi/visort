// [ente 移植] 滑动多选下发 —— 原文件：ente .../ui/viewer/gallery/state/gallery_swipe_helper.dart
//
// SwipeSelectionWrapper 向网格内所有 tile 下发 helper 与激活 notifier；
// tile（GalleryFileWidget）据此决定是否响应指针滑入。

import 'package:flutter/widgets.dart';

import 'swipe_to_select_helper.dart';

class GallerySwipeHelper extends InheritedWidget {
  final SwipeToSelectHelper? helper;
  final ValueNotifier<bool>? swipeActiveNotifier;

  const GallerySwipeHelper({
    super.key,
    this.helper,
    this.swipeActiveNotifier,
    required super.child,
  });

  static SwipeToSelectHelper? of(BuildContext context) {
    final widget = context
        .dependOnInheritedWidgetOfExactType<GallerySwipeHelper>();
    return widget?.helper;
  }

  static ValueNotifier<bool>? swipeActiveNotifierOf(BuildContext context) {
    final widget = context
        .dependOnInheritedWidgetOfExactType<GallerySwipeHelper>();
    return widget?.swipeActiveNotifier;
  }

  @override
  bool updateShouldNotify(GallerySwipeHelper oldWidget) {
    return helper != oldWidget.helper ||
        swipeActiveNotifier != oldWidget.swipeActiveNotifier;
  }
}
