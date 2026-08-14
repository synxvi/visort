// [photo_view fork] 放大后 X 边缘溢出翻页（onEdgeX）测试
//
// 用 PhotoView.customChild（显式 childSize，不依赖异步图片解码——
// 测试环境 MemoryImage 解码不完成，PhotoViewCore 不会 build，
// 旧版用 MemoryImage 的用例实际从未放大，断言的是 PageView 原生拖动）。
//
// fork 语义：放大态纯平移，target position 超出 clamp 边界的溢出量
// > 64px 才回调 onEdgeX——贴边平移（拖到边即止，溢出几 px）不翻页，
// 有意翻页继续拖过 64px 才切页。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

void main() {
  Widget buildApp({ValueChanged<int>? onEdgeX}) {
    return MaterialApp(
      home: Scaffold(
        body: PhotoViewGestureDetectorScope(
          axis: Axis.vertical,
          child: PhotoView.customChild(
            child: const ColoredBox(color: Color(0xFF224422)),
            childSize: const Size(1, 1),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
            backgroundDecoration: const BoxDecoration(
              color: Color(0xFF111111),
            ),
            onEdgeX: onEdgeX,
          ),
        ),
      ),
    );
  }

  /// 双击中心 → 放大（viewport 800×600：initial 600 → target 1500，
  /// 视觉 1500×1500，X 可移 ±350）。
  Future<void> doubleTapZoom(WidgetTester tester) async {
    final center = tester.getCenter(find.byType(PhotoView));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    // 300ms decelerate 双击动画。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('放大后 X 未到边平移 → onEdgeX 不触发', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var edgeCalls = 0;
    await tester.pumpWidget(buildApp(onEdgeX: (_) => edgeCalls++));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester);

    // 拖 -200：position 0 → -200，未到 -350 边界 → 纯平移。
    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(edgeCalls, 0, reason: '未到边时拖动应平移图片而非触发 onEdgeX');
  });

  testWidgets('贴边小溢出（40px < 64 阈值）→ 不翻页', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var edgeCalls = 0;
    await tester.pumpWidget(buildApp(onEdgeX: (_) => edgeCalls++));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester);

    // 拖到左边界（-350）后再拖 40px：溢出 40 < 64 阈值 → 不翻页
    // （用户"贴边"动作的真实场景）。
    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 7; i++) {
      await g.moveBy(const Offset(-56, 0)); // 总 -392 = 350 + 42 溢出
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(edgeCalls, 0, reason: '贴边平移（溢出 <64px）不应触发翻页');
  });

  testWidgets('到边继续拖（溢出 >64px）→ onEdgeX 触发翻页', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dirs = <int>[];
    await tester.pumpWidget(buildApp(onEdgeX: dirs.add));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester);

    // 拖到左边界后继续拖：总 -600 → 溢出 250 > 64 → onEdgeX(-1) 左拖翻下一张。
    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(dirs, contains(-1), reason: '放大后 X 到边继续拖（溢出>64px）应触发 onEdgeX(-1)');
  });
}
