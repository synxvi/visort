// ZoomableImage 回归：加载态/解码失败回退分支必须常带 Hero（tag
// photo_<id>，与网格 cell 配对）——否则快甩到未加载页直接 pop 时源端
// 无 Hero，flight 不启动（返回飞行动画被吞）。
//
// 宿主平台（测试 VM = linux）走 FileImage 分支：指向不存在的文件，
// 原图 precache 必然失败 → 触发 _showingThumbnailFallback 回退分支。
// 注意不能用 pumpAndSettle：延迟 spinner / PhotoView loading 会无限排帧。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/ui/ente_viewer/zoomable_image.dart';

MsImageInfo _photo(String id) => MsImageInfo(
      id: id,
      name: 'IMG_$id.jpg',
      size: 1024,
      mime: 'image/jpeg',
      bucketId: '1',
      dateAddedMs: 0,
      dateModifiedMs: 0,
      width: 400,
      height: 300,
    );

Finder _heroOf(String id) => find.byWidgetPredicate(
      (w) => w is Hero && w.tag == 'photo_$id',
      description: 'Hero(photo_$id)',
    );

void main() {
  testWidgets('解码失败（error 分支）：Hero 常在（tag 与网格配对）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ZoomableImage(_photo('1'), gridCols: 4)),
    ));
    // 重加载延迟起跳（150ms）→ cell/512/原图全部指向不存在文件 →
    // ImageWrapper 进入 error 分支（fork 补 Hero 的路径之一）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_heroOf('1'), findsOneWidget);
  });

  testWidgets('加载窗口期（重载未起跳）：Hero 也在（PhotoView 分支自带）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ZoomableImage(_photo('2'), gridCols: 4)),
    ));
    // 首帧即断言：cell 兜底无条件赋值 → PhotoView（heroAttributes）在树。
    expect(_heroOf('2'), findsOneWidget);
  });

  // cover 展开式飞行（immich 同款 shuttle）要求 viewer 端 hero rect 恒为
  // 原比例 contain 框：回退分支用 _aspectHeroFrame 包裹（Center 会把
  // hero rect 撑成全屏 → 飞行终点框与落位图框错位）。1:2 竖图在 4:3
  // 测试屏（800×600）上 contain 框 = 300×600，与全屏 800×600 可区分。
  testWidgets('解码失败回退：Hero rect 是原比例 contain 框（非全屏）', (tester) async {
    final photo = MsImageInfo(
      id: '3',
      name: 'IMG_3.jpg',
      size: 1024,
      mime: 'image/jpeg',
      bucketId: '1',
      dateAddedMs: 0,
      dateModifiedMs: 0,
      width: 200,
      height: 400,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ZoomableImage(photo, gridCols: 4)),
    ));
    // 触发 error 分支（同用例 1 的路径）→ _showingThumbnailFallback Hero。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(_heroOf('3')), const Size(300, 600));
  });
}
