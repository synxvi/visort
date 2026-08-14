// [photo_view fork] 双击精准缩放测试（主分支算法移植）
//
// 用 PhotoView.customChild（显式 childSize，不依赖异步图片解码——
// 测试环境 MemoryImage 解码不完成，PhotoViewCore 不会 build）。
//
// - 2 段循环：initial → 放大 → initial（无中间 originalSize 段）
// - 目标倍率 = max(initialScale×2.5, cover)：cover 铺满视口
//   （viewport 800×200 / 1×1 图 → cover 800 > initial 200×2.5=500 → cover 分支；
//    viewport 800×600 → cover 800 < 600×2.5=1500 → 2.5 分支）
// - 锚点：双击落点像素钉在屏幕原位（终态 position 满足
//    p' = (tap − c) − q·target，q = (tap − c − p₀)/begin），再经
//   clampPosition 铺满 clamp（图像 ≥ 视口的轴贴边）。
// - 缩回后 scaleState 归 initial（否则外层 shouldDisableScroll/
//   isZoomedNotifier 残留 → 翻页失灵/沉浸模式不退出）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

void main() {
  Widget buildApp({
    required PhotoViewController controller,
    required PhotoViewScaleStateController scaleStateController,
    List<PhotoViewScaleState>? states,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PhotoViewGestureDetectorScope(
          axis: Axis.vertical,
          child: PhotoView.customChild(
            child: const ColoredBox(color: Color(0xFF224422)),
            childSize: const Size(1, 1),
            controller: controller,
            scaleStateController: scaleStateController,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            scaleStateChangedCallback: states?.add,
          ),
        ),
      ),
    );
  }

  Future<void> doubleTapAt(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    // 300ms decelerate 双击动画。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('双击角落 → cover 铺满倍率 + 锚点精准 + zoomedIn；再双击回 initial', (
    tester,
  ) async {
    // 扁视口：1×1 图 contained=200，cover=800 > 200×2.5=500 → cover 分支。
    tester.view.physicalSize = const Size(800, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    final states = <PhotoViewScaleState>[];
    await tester.pumpWidget(buildApp(
      controller: controller,
      scaleStateController: scaleStateController,
      states: states,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 双击右下角 (700,150)：c=(400,100)。
    // q = (300,50)/200 = (1.5,0.25)；p' = (300,50) − (1200,200) = (−900,−150)；
    // clamp：图 800×800 vs 视口 800×200 → X 贴边 [0,0]→0，Y ∈ ±300 保持。
    await doubleTapAt(tester, const Offset(700, 150));

    expect(scaleStateController.scaleState, PhotoViewScaleState.zoomedIn,
        reason: '双击放大后应进入 zoomedIn（外层依赖它禁翻页+沉浸模式）');
    expect(controller.scale, closeTo(800, 0.5),
        reason: 'cover 分支：max(initial 200×2.5, cover 800) = 800');
    expect(controller.position, const Offset(0, -150),
        reason: "锚点公式 p'.dy = -150 且 clamp 后保持（图高 800 > 视口 200）");

    // 再次双击 → 缩回 initial（2 段循环，无 originalSize 中间段）。
    await doubleTapAt(tester, const Offset(700, 150));

    expect(controller.scale, closeTo(200, 0.5), reason: '再次双击缩回 initialScale');
    expect(controller.position, Offset.zero, reason: '缩回 position 归零');
    expect(scaleStateController.scaleState, PhotoViewScaleState.initial,
        reason: '缩回后状态归 initial（残留 zoomedOut 会让外层禁翻页）');
    expect(
      states,
      containsAllInOrder(
          [PhotoViewScaleState.zoomedIn, PhotoViewScaleState.initial]),
    );
  });

  testWidgets('宽视口 → 2.5 倍分支，中心双击 position 归零', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // contained=600，cover=800 < 600×2.5=1500 → target = 1500。
    // 中心双击：q=(0,0) → p'=(0,0)。
    await doubleTapAt(tester, const Offset(400, 300));

    expect(controller.scale, closeTo(1500, 0.5),
        reason: '2.5 分支：initial 600 × 2.5 = 1500');
    expect(controller.position, Offset.zero, reason: '中心双击锚点即中心，position 归零');
    expect(scaleStateController.scaleState, PhotoViewScaleState.zoomedIn);
  });
}
