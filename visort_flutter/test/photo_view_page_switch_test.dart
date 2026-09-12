// [photo_view fork·aves 对齐] 放大态 X 贴边外拖 → recognizer arena 让位 →
// PageView 原生滚动接管（跟手翻页）测试。
//
// 用 PhotoView.customChild（显式 childSize，不依赖异步图片解码——
// 测试环境 MemoryImage 解码不完成，PhotoViewCore 不会 build）。
//
// fork 语义（PhotoViewGestureRecognizer.resolve 覆写）：
// - 图内拖动（未贴边）→ recognizer accept → 平移图片，PageView 不动。
// - X 贴边外拖 → resolve(rejected) 让位 → PageView 的 drag recognizer
//   赢 arena → 原生滚动（offset 变化）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:visort_flutter/ui/ente_viewer/page_settle_takeover.dart';

void main() {
  Widget buildApp({
    required PageController pageController,
    PhotoViewController? controller,
    PhotoViewScaleStateController? scaleStateController,
    bool flingTakeOver = true,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PhotoViewGestureDetectorScope(
          axis: Axis.vertical,
          child: PageSettleTakeOver(
            controller: pageController,
            flingTakeOver: flingTakeOver,
            child: PageView(
              controller: pageController,
              children: [
                PhotoView.customChild(
                  child: const ColoredBox(color: Color(0xFF224422)),
                  childSize: const Size(1, 1),
                  controller: controller,
                  scaleStateController: scaleStateController,
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3,
                  backgroundDecoration:
                      const BoxDecoration(color: Color(0xFF111111)),
                ),
                const ColoredBox(color: Color(0xFF442222)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 双击中心 → 放大（viewport 800×600：initial 600 → target 1500，
  /// 视觉 1500×1500，X 可移 ±350）。
  Future<void> doubleTapZoom(
    WidgetTester tester, {
    PhotoViewController? controller,
    PhotoViewScaleStateController? scaleStateController,
  }) async {
    final center = tester.getCenter(find.byType(PhotoView));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    // 300ms decelerate 双击动画。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (controller != null && scaleStateController != null) {
      expect(scaleStateController.scaleState, PhotoViewScaleState.zoomedIn,
          reason: '双击放大未生效（前置自检）');
      expect(controller.scale, closeTo(1500, 0.5),
          reason: '双击放大 scale 前置自检');
      expect(controller.position, Offset.zero,
          reason: '中心双击 position 归零前置自检');
    }
  }

  testWidgets('放大后 X 未到边平移 → 图片平移，PageView 不动', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 拖 -200：position 0 → -200，未到 -350 边界 → 纯平移（图片动、页不动）。
    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(pageController.hasClients ? pageController.offset : 0.0, 0.0,
        reason: '图内平移不应被 PageView 抢走');
    expect(controller.position.dx, closeTo(-200, 1),
        reason: '未贴边拖动应平移图片');
  });

  testWidgets('放大后 X 贴边外拖 → recognizer 让位，PageView 原生滚动', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 手势 1：平移图片到左边界（position -350，图片贴边）后松手。
    // （中途到边的手势已锁定平移——aves 同语义，本手势不翻页。）
    final g1 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(-50, 0)); // 总 -400：图内 -350 + 贴边溢出
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.dx, lessThanOrEqualTo(-349),
        reason: '前置自检：图片应已贴左边界');

    // 手势 2：从贴边状态直接左拖——手势起始即「X 贴边外拖」（shouldMove
    // 自始 false，recognizer 不 accept / resolve 让位）→ PageView 的 drag
    // recognizer 赢 arena → 原生滚动（下一页从右侧滑入，offset 增大）。
    final g2 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 10; i++) {
      await g2.moveBy(const Offset(-50, 0)); // 总 -500
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 断言取拖动中（让位→原生滚动的事实本身）；松手后 spring 接管
    // 快收尾，位置随时窗变化不可断言。
    final offsetDuringDrag = pageController.hasClients ? pageController.offset : 0.0;
    await g2.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(offsetDuringDrag > 0, true,
        reason: '贴边外拖应让位给 PageView 原生滚动（offset > 0）');
  });

  // P0 回归：贴边外拖 15px（半 slop 过限但 shouldMove=false 不声明）→
  // 回摆 3px（单帧朝内 shouldMove=true + 累计 12px 仍过半 slop）——修复前
  // 此帧直调 acceptGesture：基类 _state=started 但 arena 未决；随后继续
  // 回摆累计朝内过 PageView slop → rival 声明获胜 → 本 recognizer 被
  // reject → didStopTrackingLastPointer 在 started 态 assert 崩溃
  // （scale.dart:847）。修复后声明走 resolve 覆写自查 → 让位，全程无异常。
  testWidgets('贴边外拖后回摆 → 让位不崩溃（P0 回归）', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 平移到左边界贴边（同上一测试前置）。
    final g1 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.dx, lessThanOrEqualTo(-349),
        reason: '前置自检：图片应已贴左边界');

    // 崩溃序列：外拖 15px → 回摆 3px（触发旧崩溃帧）→ 继续回摆 40px
    // （累计朝内 25px 过 PageView slop 18 → PageView 声明获胜）。
    final g2 = await tester.startGesture(const Offset(400, 300));
    await g2.moveBy(const Offset(-5, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g2.moveBy(const Offset(-5, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g2.moveBy(const Offset(-5, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g2.moveBy(const Offset(3, 0)); // ← 修复前：直调 acceptGesture → started
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 8; i++) {
      await g2.moveBy(const Offset(5, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g2.up();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull,
        reason: '回摆场景不得触发基类状态机断言');
    expect(controller.position.dx, lessThanOrEqualTo(-348),
        reason: '让位后图片位置不得被手势残留挪动');
  });

  // 用户复现（2026-09-11）：贴边外拖让位（PageView 露出下一张跟手）→
  // 拖回 → 松手 → 再按住往回（朝内）拖——图片应恢复平移能力（让位状态
  // 不得残留到新手势序列）。修复前症状：此后怎么拖都只有翻页。
  testWidgets('让位松手后反方向拖 → 图片恢复平移', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 1) 平移到左边界贴边（position -350）。
    final g1 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.dx, lessThanOrEqualTo(-349),
        reason: '前置自检：图片应已贴左边界');

    // 2) 贴边外拖让位：PageView 接管露出下一张（offset > 0）。
    // 断言取拖动中（让位事实）；松手后 spring 快收尾位置随时窗变化。
    final g2 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 4; i++) {
      await g2.moveBy(const Offset(-30, 0)); // 总 -120
      await tester.pump(const Duration(milliseconds: 16));
    }
    final offsetAtYield = pageController.hasClients ? pageController.offset : 0.0;
    expect(offsetAtYield, greaterThan(0),
        reason: '前置自检：外拖应让位 PageView（露出下一张）');

    // 3) 按住不松手，原路拖回（PageView 回滚到 0），再松手。
    for (var i = 0; i < 4; i++) {
      await g2.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g2.up();
    await tester.pump(const Duration(milliseconds: 400)); // 弹回完成

    // 4) 新手势往右（朝内）拖：图片应平移（position 从贴边回移），
    //    而不是又一次翻页。
    final g3 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 4; i++) {
      await g3.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g3.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.position.dx, greaterThan(-340),
        reason: '让位松手后反方向拖必须恢复图片平移（position 应离开贴边）');
    expect(pageController.hasClients ? pageController.offset : 0.0, 0.0,
        reason: '朝内拖不应触发翻页');
  });

  // 用户反馈（2026-09-12）：贴边外拖稍带垂直分量就变成上下移动，翻页
  // 必须一点不抖的水平移动——根因是双轴 scope「任一轴可移即声明」，
  // Y 可移劫持了 X 主导的翻页意图。修复后主导轴判定：X 主导斜拖贴边
  // 外拖 → 让位 PageView 翻页。
  testWidgets('斜向拖动 X 主导贴边外拖 → 翻页（主导轴判定）', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 平移到左边界贴边。
    final g1 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.dx, lessThanOrEqualTo(-349),
        reason: '前置自检：图片应已贴左边界');

    // 斜向拖动（X:Y = 12:4，手带垂直抖动）：X 主导 + X 贴边朝外 →
    // 不得声明 → PageView 接管滚动。
    final g2 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 10; i++) {
      await g2.moveBy(const Offset(-12, -4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g2.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(pageController.hasClients && pageController.offset > 0, true,
        reason: 'X 主导斜向贴边外拖应翻页（offset > 0）');
  });

  // 反向回归：Y 主导斜拖 → 图片垂直平移（不得声明失败/被翻页劫持）。
  testWidgets('斜向拖动 Y 主导图内拖 → 垂直平移（主导轴判定）', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 斜向拖动（X:Y = 4:12，Y 主导）：图片垂直可移 → 应声明平移，
    // 图片跟手（position.dy 变化），PageView 不滚。
    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(4, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.position.dy, greaterThan(40),
        reason: 'Y 主导斜拖应垂直平移图片（跟手）');
    expect(pageController.hasClients ? pageController.offset : 0.0, 0.0,
        reason: 'Y 主导斜拖不应翻页');
  });

  // 用户反馈（2026-09-12）：外拖让位松手后，必须等 PageView 弹回动画
  // 完全停稳才能反向平移——体感差。期望：弹回（ballistic）中途按住
  // 反向拖即应平移图片（PageView down 即 hold 停页，arena 里我们半
  // slop 9px 先于 drag 18px 声明）。
  testWidgets('弹回动画中途反向拖 → 立即平移不等停稳', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 平移到左边界贴边。
    final g1 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.dx, lessThanOrEqualTo(-349),
        reason: '前置自检：图片应已贴左边界');

    // 外拖让位：PageView 接管露出下一张。
    final g2 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 6; i++) {
      await g2.moveBy(const Offset(-25, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g2.up();
    // 泵两帧（两拍 postFrame：第一拍挂基线、第二拍接管判定并换
    // activity 解除指针屏蔽）——真机 up→down 间隔远大于两帧。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final midOffset = pageController.hasClients ? pageController.offset : 0.0;
    expect(midOffset, greaterThan(0.0),
        reason: '前置自检：弹回应仍在进行中（offset 尚未回到 0）');

    // 弹回中途按住反向（朝内）拖：应立即平移图片。
    final g3 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 6; i++) {
      await g3.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g3.up();
    await tester.pump(const Duration(milliseconds: 150));

    expect(controller.position.dx, greaterThan(-340),
        reason: '弹回中途反向拖应立即平移图片（不等动画停稳）');
  });

  // 用户反馈（2026-09-12）：快甩翻页被吞——接管判定只看位置
  // （round(frac)=当前页 → 杀弹射弹回），必须拉三四次才翻过。修复：
  // 复刻 PageScrollPhysics._getTargetPixels 的速度判定（velocity 过
  // tolerance → 目标页 ±0.5 再 round），快甩的弹射目标是邻页 → 不接管。
  testWidgets('快甩翻页不被回弹接管吞掉', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 快甩（fling 生成带真实时间戳的事件链，recognizer 估速可靠）：
    // 位移 -250（0.3 页，未过半页断点）速度 6000px/s——速度决定弹射
    // 目标=下一页。
    await tester.fling(
        find.byType(PageView), const Offset(-250, 0), 6000);
    // 泵两帧过两拍接管判定窗（误判会在此杀掉弹射）。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final midOffset = pageController.hasClients ? pageController.offset : 0.0;
    expect(midOffset, greaterThan(251),
        reason: '快甩弹射应朝下一页进行（offset 离开起点递增），不得被杀回');
    // 弹射完成落位第 2 页。
    await tester.pumpAndSettle();
    expect(pageController.hasClients ? pageController.offset : 0.0, 800.0,
        reason: '快甩应翻到下一页（offset = 一页宽）');
  });

  // 用户反馈（2026-09-12）：打开图片轻扫翻页失败——「露出一点点下一张
  // 图的边缘，瞬间又弹回」。根因：Android 引擎 resampling 使 move 大多
  // 为 synthesized，Scrollable 的 velocity tracker 只吃非合成事件（
  // monodrag.dart `!event.synthesized`）→ 松手 velocity 恒 0 → PageView
  // 只剩纯位置通道（50% 硬断点）→ 轻扫必弹回（真机日志实证 ballistic
  // 起步即朝当前页回）。修复：组件速度通道（含 synthesized 的完整
  // 轨迹自估速度，physics 判回当前页而速度朝邻页过阈值 → 自驱翻页）。
  // 本测试手发 synthesized move（显式时间戳）复刻真机分裂：Scrollable
  // tracker 饿死（v=0 回当前页），组件 tracker 有速 → 翻页。
  testWidgets('resampling 轻扫：physics 速度饿死 → 组件速度通道翻页', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 轻扫：synthesized move（真机 resampling 同款），5 步 ×10px/16ms
    // ≈ 625px/s，总位移 50px（0.06 页，远未过半页断点）。全手写事件
    //（TestGesture 不暴露 pointer id，无法与之混发）。
    const pointer = 7;
    await tester.sendEventToBinding(PointerDownEvent(
      pointer: pointer,
      position: const Offset(400, 300),
      timeStamp: Duration.zero,
    ));
    await tester.pump(const Duration(milliseconds: 16));
    var t = 16;
    for (var i = 1; i <= 5; i++) {
      await tester.sendEventToBinding(PointerMoveEvent(
        pointer: pointer,
        position: Offset(400 - i * 10.0, 300),
        delta: const Offset(-10, 0),
        synthesized: true,
        timeStamp: Duration(milliseconds: t),
      ));
      t += 16;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(PointerUpEvent(
      pointer: pointer,
      position: const Offset(350, 300),
      timeStamp: Duration(milliseconds: t),
    ));
    // 两拍接管判定窗。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();

    expect(pageController.hasClients ? pageController.offset : 0.0, 800.0,
        reason: '轻扫（速度 625px/s、位移 0.06 页）应由速度通道翻到下一页');
  });

  // 用户反馈（2026-09-12）：速度通道引入后，放大态平移到边缘轻微外拖
  // 松手就被强制翻页——贴边外拖是精细操作（手指速度天然超阈值，位移
  // 却小），与轻扫语义不同。修复：flingTakeOver=false（放大态）关速度
  // 通道，翻页只认位置通道（拖过半页）或 physics 自身有效的弹射。
  testWidgets('放大态贴边快拖松手 → 弹回不翻页（速度通道关闭）', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    final controller = PhotoViewController();
    final scaleStateController = PhotoViewScaleStateController();
    await tester.pumpWidget(buildApp(
      pageController: pageController,
      controller: controller,
      scaleStateController: scaleStateController,
      flingTakeOver: false, // 放大态
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await doubleTapZoom(tester,
        controller: controller, scaleStateController: scaleStateController);

    // 平移到左边界贴边。
    final g1 = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.position.dx, lessThanOrEqualTo(-349),
        reason: '前置自检：图片应已贴左边界');

    // 贴边快拖（synthesized 复刻真机 resampling：physics 速度饿死）：
    // 6 步 ×10px/16ms（手指速度 625px/s > 250 阈值）——放大态速度通道
    // 关闭 → 不得翻页。
    const pointer = 7;
    await tester.sendEventToBinding(PointerDownEvent(
      pointer: pointer,
      position: const Offset(400, 300),
      timeStamp: Duration.zero,
    ));
    await tester.pump(const Duration(milliseconds: 16));
    var t = 16;
    for (var i = 1; i <= 6; i++) {
      await tester.sendEventToBinding(PointerMoveEvent(
        pointer: pointer,
        position: Offset(400 - i * 10.0, 300),
        delta: const Offset(-10, 0),
        synthesized: true,
        timeStamp: Duration(milliseconds: t),
      ));
      t += 16;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(PointerUpEvent(
      pointer: pointer,
      position: const Offset(340, 300),
      timeStamp: Duration(milliseconds: t),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();

    expect(pageController.hasClients ? pageController.offset : 0.0, 0.0,
        reason: '放大态贴边外拖松手应弹回当前页，不得被速度通道强制翻页');
  });

  // 过程断言（2026-09-12 用户实证「后半动画没有直接显示下一张」）：
  // 拖一半松手翻页 → 两拍接管 → 动画进行中（50ms 处）offset 必须仍在
  // 途中——瞬到 800 = 动画被瞬完。
  testWidgets('拖一半松手翻页：动画过程可见（不瞬跳）', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    await tester.pumpWidget(buildApp(pageController: pageController));
    await tester.pump(const Duration(milliseconds: 300));

    // 慢拖到 0.56 页（450px，过半页断点）松手——零速位置通道翻页。
    final g = await tester.startGesture(const Offset(400, 300));
    for (var i = 0; i < 9; i++) {
      await g.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await g.up();
    // 两拍接管窗。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final afterBeats = pageController.offset;
    // 动画进行中（首 tick dt=0 是 Ticker 语义，第二帧起 dt 递增）：
    // 再两帧（16+50ms）后 offset 必须在途中。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 50));
    final mid = pageController.offset;
    expect(mid, greaterThan(afterBeats + 5),
        reason: '动画应进行中（offset 持续增长），瞬到终点=动画瞬完');
    expect(mid, lessThan(799),
        reason: '50ms 处不应已到终点（弹簧 110 从 450 走 350px 需 ~250ms）');
    await tester.pumpAndSettle();
    expect(pageController.offset, 800.0, reason: '最终落位下一页');
  });

  // 用户实证（2026-09-12）：上滑面板偶尔多翻一页/回前一页——垂直手势
  // 松手时的水平抖动/回勾被速度通道（只采 dx）劫持成水平轻扫。修复：
  // dy 主导的手势速度通道静默。手写事件复刻：垂直大位移 + 收尾水平抖。
  testWidgets('垂直手势松手（水平抖动）→ 速度通道静默不翻页', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pageController = PageController();
    await tester.pumpWidget(buildApp(pageController: pageController));
    await tester.pump(const Duration(milliseconds: 300));

    // 上滑：dy -160（垂直主导），仅末步带水平回勾 dx -8（累计 < 18
    // slop 不滚 PageView；16ms/-8px ≈ -500px/s > 250 阈值——修复前
    // 速度通道劫持翻页）。harness 无垂直手势层（真机 zoomable 有，
    // 垂直 slop 先赢），此处验证组件的速度采样静默。
    const pointer = 7;
    await tester.sendEventToBinding(PointerDownEvent(
      pointer: pointer,
      position: const Offset(400, 400),
      timeStamp: Duration.zero,
    ));
    await tester.pump(const Duration(milliseconds: 16));
    var t = 16;
    final path = <Offset>[
      const Offset(400, 380), const Offset(400, 355),
      const Offset(400, 330), const Offset(400, 305),
      const Offset(400, 280), const Offset(400, 260),
      const Offset(392, 244),
    ];
    Offset prev = const Offset(400, 400);
    for (final pos in path) {
      await tester.sendEventToBinding(PointerMoveEvent(
        pointer: pointer,
        position: pos,
        delta: pos - prev,
        timeStamp: Duration(milliseconds: t),
      ));
      prev = pos;
      t += 16;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(PointerUpEvent(
      pointer: pointer,
      position: prev,
      timeStamp: Duration(milliseconds: t),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();

    expect(pageController.offset, 0.0,
        reason: '垂直主导手势（上滑面板）不得被水平速度通道翻页');
  });
}
