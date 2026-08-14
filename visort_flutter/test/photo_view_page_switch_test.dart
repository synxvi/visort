// [photo_view fork] 放大后 X 平移边缘 → 翻页的双轴裁决测试
//
// 背景：photo_view 0.15.0 的 PhotoViewGestureRecognizer 只按 validateAxis
// 单轴裁决（axis: vertical 时 X 永不释放）——放大后图片平移到 X 边缘继续拖，
// Scale recognizer 仍赢 arena（只要 Y 还能动）→ PageView 收不到 → 无法翻页。
// fork patch：shouldMoveX || shouldMoveY 任一可移动即 accept——
//   - 放大后 X 未到边：X 平移图片
//   - X 已到边：释放给 PageView 翻页
//
// 测试用 TestGesture（非 synthesized、position 精确可控）——
// adb input swipe 在模拟器上 MOVE 事件 position 只更新 1px，无法验证平移。

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

/// 1×1 透明占位图（photo_view 无需真实图片即可驱动手势）。
final Uint8List _kPlaceholder = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 头
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  Widget buildApp({PageController? controller, ValueChanged<int>? onEdgeX}) {
    return MaterialApp(
      home: Scaffold(
        body: PageView.builder(
          controller: controller ?? PageController(),
          itemCount: 2,
          itemBuilder: (context, index) {
            return PhotoViewGestureDetectorScope(
              axis: Axis.vertical,
              child: PhotoView(
                imageProvider: MemoryImage(_kPlaceholder),
                onEdgeX: onEdgeX,
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 3,
                backgroundDecoration: const BoxDecoration(
                  color: Color(0xFF111111),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 双击图片中心 → 放大（photo_view zoomedIn）。
  Future<void> doubleTapZoom(WidgetTester tester) async {
    final center = tester.getCenter(find.byType(PageView));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    // photo_view 放大是 fling 动画（临界阻尼弹簧），pumpAndSettle 会等不到静止。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 当前第几页（PageView 的 page）。
  double pageOf(WidgetTester tester) {
    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    return controller.page ?? controller.initialPage.toDouble();
  }

  testWidgets('放大后 X 平移图片（未到边）不平页', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester);

    // 水平拖动 60px（右）：X 未到边 → 图片平移，PageView 不翻页。
    final g = await tester.startGesture(const Offset(200, 200));
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    await g.up();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(pageOf(tester), 0, reason: 'X 未到边时拖动应平移图片而非翻页');
  });

  testWidgets('放大后 X 平移到边缘继续拖 → 翻页', (tester) async {
    final controller = PageController();
    // 模拟 detail_page 的 onEdgeX 处理：左拖溢出 → nextPage。
    void pager(int dir) {
      if (dir < 0) {
        controller.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    }
    await tester.pumpWidget(buildApp(controller: controller, onEdgeX: pager));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester);

    // 持续向左拖动（多次 moveBy）：图片左移到 X 边缘后继续拖 → onEdgeX → 翻下一页。
    final g = await tester.startGesture(const Offset(300, 200));
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(pageOf(tester), 1, reason: '放大后 X 到边继续拖应触发 onEdgeX 翻页');
  });
}
