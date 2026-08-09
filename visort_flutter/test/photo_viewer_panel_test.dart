// PhotoViewer 详情面板 z-order 契约测试 —— 详情面板必须从底栏后面滑出/收回
//
// 背景:面板条目(_panelEntry)曾以 insert() 插入 Overlay 末尾,绘制在底栏条目
// (_barEntry)之上 —— 上滑/弹出动画期间面板可见部分覆盖底栏。修复:面板条目
// 以 insert(below: _barEntry) 插入到底栏之下,底栏绘制在面板之上。
//
// 验证方式(端到端行为断言):
//   1. 打开面板后向下拖拽,把面板冻结在「底部越过 delete 按钮顶部、但仍部分
//      在屏内」的滑入中间态(第一指按住不抬,无 snap 介入);
//   2. 第二指点击 delete 按钮 —— 若面板条目在底栏之上,opaque 手势层会拦截
//      hit-test,按钮收不到事件,删除确认框不出现;若面板在底栏之下(修复后),
//      按钮正常命中,删除确认框弹出。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/ui/screens/photo_details_sheet.dart';
import 'package:visort_flutter/ui/screens/photo_viewer.dart';

MsImageInfo _photo(String id) => MsImageInfo(
      id: id,
      name: '$id.jpg',
      size: 1024,
      mime: 'image/jpeg',
      bucketId: 'b1',
      dateAddedMs: 0,
      dateModifiedMs: 0,
      width: 100,
      height: 100,
    );

void main() {
  testWidgets('详情面板从底栏后面滑出:滑入中间态不遮挡底栏按钮', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PhotoViewer(photos: [_photo('1')], initialIndex: 0),
        ),
      ),
    );
    // 底栏条目在 post-frame 插入;随后 _insertBars 的 post-frame 把
    // _chromeFade 置 1(否则底栏 IgnorePointer(ignoring:true) 不可点)。
    // 两次 pump:第一帧渲染 opacity=0 的底栏,第二帧应用 value=1 的 rebuild。
    await tester.pump();
    await tester.pump();

    // 打开详情面板(点击底栏 info 按钮),等打开动画(220ms)完成
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final panelFinder = find.byType(PhotoDetailsSheet);
    final deleteIconRect = tester.getRect(find.byIcon(Icons.delete_outline));
    final screenH = tester.getSize(find.byType(Scaffold)).height;
    // delete 按钮 48x48,Icon 居中;按钮顶 = iconRect.top - 12。
    // hit 点取按钮顶部内侧(仍属按钮热区),保证它被中间态面板覆盖。
    final hitPoint = Offset(deleteIconRect.center.dx, deleteIconRect.top - 8);

    // 第一指:拖拽面板到中间态并按住(冻结,避免松手 snap 弹回)。
    final drag = await tester.startGesture(tester.getCenter(panelFinder));
    var moved = 0.0;
    while (moved < 400) {
      await drag.moveBy(const Offset(0, 20));
      moved += 20;
      await tester.pump();
      final bottom = tester.getBottomRight(panelFinder).dy;
      if (bottom > hitPoint.dy && bottom < screenH) break;
    }

    // 前置:面板确实处于「底部越过 hit 点、部分在屏内」的中间态
    final bottom = tester.getBottomRight(panelFinder).dy;
    expect(bottom, greaterThan(hitPoint.dy),
        reason: '前置失败:面板底部应越过 hit 点(否则未覆盖按钮区域)');
    expect(bottom, lessThan(screenH),
        reason: '前置失败:面板应处于滑入中间态(未完全关闭)');

    // 第二指:点击 delete 按钮。面板在底栏之上会拦截(opaque 手势层,
    // 且无 onTap → tap 无效果);在底栏之下则按钮正常触发删除确认框。
    final tap = await tester.startGesture(hitPoint);
    await tap.up();
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: '滑入中间态下面板不应遮挡底栏 delete 按钮');

    // 收尾:关闭删除确认框,抬起第一指(snap 弹回动画),等动画落定
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
