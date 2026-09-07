// Filmstrip（第三版：锚点式布局）组件测试：
//  - 冒烟：构建/拖动/甩动/停稳/程序滑移不抛异常；
//  - 几何：稳态聚焦图居中（±0.5px）、聚焦图方形 32×32 高度恒定、
//    相邻间隙 5px / 聚焦两侧 16px（布局纯函数防回归）；
//  - 联动契约：用户手势跨档实时上报、停稳上报；程序指令（外部 center
//    写）全程静默；组件不回写 center；
//  - 深位：千张相册中后段打开 O(1) 定位、图源 index 对位；
//  - 高速甩动视口不空窗；外部跳格同帧落位；慢滑不漂移；
//  - 锁步：pagePos fraction 双项插值跟随、pagerDriven 让位。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/ui/ente_viewer/filmstrip.dart';

/// 1x1 透明 PNG：解码成功，隔离「图片加载失败」噪音。
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const _viewportW = 400.0;

Widget _wrap(Filmstrip strip) => MaterialApp(
      home: Scaffold(
        // 不用 Center：tester.getRect 是全局坐标，条贴 (0,0) 使其全局
        // 中心 = _viewportW/2，断言坐标系才对得上。
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: _viewportW, height: 38, child: strip),
        ),
      ),
    );

/// 全部可见 Image 的 Rect 列表。
List<Rect> _imageRects(WidgetTester tester) {
  final n = tester.widgetList<Image>(find.byType(Image)).length;
  return [
    for (var k = 0; k < n; k++) tester.getRect(find.byType(Image).at(k)),
  ];
}

/// 水平中心最接近视口中心的 Image（= 聚焦项图片）的 Rect。
Rect _centerImageRect(WidgetTester tester) {
  var best = _imageRects(tester).first;
  for (final r in _imageRects(tester)) {
    if ((r.center.dx - _viewportW / 2).abs() <
        (best.center.dx - _viewportW / 2).abs()) {
      best = r;
    }
  }
  return best;
}

void main() {
  testWidgets('构建/拖动/甩动/程序滑移不抛异常', (tester) async {
    final center = ValueNotifier<int>(2);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 5,
          initialIndex: 2,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '首帧 build 应无异常');

    await tester.pumpAndSettle();
    await tester.fling(find.byType(Filmstrip), const Offset(-200, 0), 800);
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '拖动路径应无异常');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '停稳聚焦路径应无异常');

    center.value = 1;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '程序滑移路径应无异常');
  });

  testWidgets('聚焦图方形居中且间隙均匀（变格宽 28/43.5）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: ValueNotifier<int>(10),
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '初始聚焦图应精确居中（布局纯函数，无滚动定位误差）',
    );
    expect(img.width, closeTo(32, 0.5), reason: '聚焦图方形宽 32（系统同款）');
    expect(img.height, closeTo(32, 0.5), reason: '聚焦图高度与普通项一致（恒定）');
    // 白框已随系统同款样式移除：不再有聚焦框元素。
    expect(
      find.byKey(const ValueKey('filmstrip_focus_frame')),
      findsNothing,
      reason: '聚焦样式 = 变宽成方形 + 提亮，无边框',
    );

    // 相邻普通项间隙 = 格 28 − 图 23 = 5px；聚焦项两侧 = 13.5+2.5 = 16px。
    final rects = _imageRects(tester)
      ..sort((a, b) => a.left.compareTo(b.left));
    final gaps = <double>[];
    for (var k = 0; k + 1 < rects.length; k++) {
      final gap = rects[k + 1].left - rects[k].right;
      if (gap.abs() < 24) gaps.add(gap); // 排除视口两端被裁剪的
    }
    var gap5 = 0, gap16 = 0;
    for (final g in gaps) {
      if ((g - 5).abs() < 0.75) {
        gap5++;
      } else if ((g - 16).abs() < 0.75) {
        gap16++;
      } else {
        fail('间隙既非 5 也非 16：$g');
      }
    }
    expect(gap16, 2, reason: '聚焦项左右各一个 16px 间隙（系统同款推开）');
    expect(gap5, greaterThan(0), reason: '普通项间 5px 间隙应存在');
  });

  testWidgets('末项聚焦居中（端点钳制不吞末项）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 29,
          center: ValueNotifier<int>(29),
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '末项应可居中（锚点布局无 padding/extent 限制）',
    );
  });

  testWidgets('拖动跨档实时上报 + 停稳上报 + 聚焦图回中心', (tester) async {
    var reported = <int>[];
    var settled = <int>[];
    final center = ValueNotifier<int>(10);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onCenterChanged: reported.add,
          onSettled: settled.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(find.byType(Filmstrip), const Offset(-250, 0), 600);
    await tester.pumpAndSettle();
    expect(
      reported,
      isNotEmpty,
      reason: '用户拖动的跨档上报必须保留（主图跟手联动依赖它）',
    );
    expect(settled, isNotEmpty, reason: '手势停稳应上报 onSettled');
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '停稳后聚焦图应精确居中（selDx 补间收敛到 0）',
    );
  });

  testWidgets('程序滑移全程静默（不回调、不回写 center）', (tester) async {
    var reported = <int>[];
    var settled = <int>[];
    final center = ValueNotifier<int>(10);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onCenterChanged: reported.add,
          onSettled: settled.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 连续写 + 动画中打断（模拟主图拖动中 onPageChanged 连续到达）。
    center.value = 11;
    await tester.pump(const Duration(milliseconds: 60));
    center.value = 12;
    await tester.pump(const Duration(milliseconds: 40));
    center.value = 10;
    await tester.pump(const Duration(milliseconds: 50));
    center.value = 13;
    await tester.pumpAndSettle();

    expect(
      reported,
      isEmpty,
      reason: '程序滑移不得上报 onCenterChanged——上报会被宿主当作用户'
          '滚动执行 jumpToPage，打断主图拖动',
    );
    expect(settled, isEmpty, reason: '程序滑移到位不报 onSettled（宿主自驱）');
    expect(center.value, 13, reason: '组件不得回写 center');
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '程序滑移终态目标项居中',
    );
  });

  testWidgets('点按单项：onTap 即时上报 + 到位聚焦', (tester) async {
    var tapped = <int>[];
    var settled = <int>[];
    final center = ValueNotifier<int>(10);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onTap: tapped.add,
          onSettled: settled.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点视口右侧可见项：第 11 项中心 = 200+43.5 = 243.5；第 12 项 =
    // 243.5+28 = 271.5（视口半宽 200，均在内）。点第 12 项。
    await tester.tapAt(const Offset(271.5, 19));
    await tester.pumpAndSettle();
    expect(tapped, [12], reason: '点按上报被点项');
    expect(settled, isEmpty, reason: '点按路径不双报 onSettled（onTap 已报）');
    expect(center.value, 10, reason: '组件不回写 center（宿主管选中态）');
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '点按滑移到位后目标项居中',
    );
  });

  testWidgets('千张中后段打开：O(1) 定位、不上报、图源 index 对位', (
    tester,
  ) async {
    var reported = <int>[];
    final called = <int>{};
    final center = ValueNotifier<int>(500);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 500,
          center: center,
          thumbnail: (i) {
            called.add(i);
            return MemoryImage(_png);
          },
          onCenterChanged: reported.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(center.value, 500, reason: '初始定位后 center 不得漂移');
    expect(reported, isEmpty, reason: '初始定位不是用户滚动，不得上报');
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '中后段打开聚焦图应精确居中（锚点布局 O(视口)）',
    );
    // 构建只允许请求可见带（500 ± ~8 格 + 缓冲）——深位不碰相册开头。
    expect(
      called,
      everyElement(greaterThan(480)),
      reason: '可见带外的 index 不该被构建（含 global 对位回归）',
    );
    expect(called, everyElement(lessThan(520)));
  });

  testWidgets('千张连甩到尾部：上报序列单调、停稳居中', (tester) async {
    var reported = <int>[];
    var settled = <int>[];
    final center = ValueNotifier<int>(500);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 500,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onCenterChanged: reported.add,
          onSettled: settled.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    var last = -1;
    for (var k = 0; k < 30; k++) {
      await tester.fling(find.byType(Filmstrip), const Offset(-4000, 0), 4000);
      await tester.pumpAndSettle();
      // 组件不回写 center：用 settled 末值跟踪进度。
      if (settled.isNotEmpty && settled.last == last) break;
      last = settled.isNotEmpty ? settled.last : -1;
    }
    expect(settled.last, 999, reason: '连甩后应停在末项（端点钳制收尾）');

    expect(reported.first, greaterThan(500));
    for (var k = 0; k + 1 < reported.length; k++) {
      final d = reported[k + 1] - reported[k];
      expect(d, greaterThanOrEqualTo(0), reason: '右甩序列应单调不减');
      expect(
        d,
        lessThanOrEqualTo(64),
        reason: '相邻跨档差有界（单帧位移 = 真实减速帧跨档数；序列：'
            '${reported.take(40).toList()}...）',
      );
    }
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '连甩停稳后聚焦图居中',
    );
  });

  testWidgets('高速甩动全程视口不空窗', (tester) async {
    final center = ValueNotifier<int>(500);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 500,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(find.byType(Filmstrip), const Offset(-30000, 0), 60000);
    for (var k = 0; k < 20; k++) {
      await tester.pump(const Duration(milliseconds: 16));
      final imgs = _imageRects(tester);
      expect(imgs, isNotEmpty, reason: '甩动途中任何一帧不得空窗（第 $k 帧）');
      expect(
        (imgs[0].center.dx - _viewportW / 2).abs(),
        lessThan(_viewportW),
        reason: '甩动途中可见 item 须覆盖视口（第 $k 帧）',
      );
    }
    await tester.pumpAndSettle();
    expect(
      (_centerImageRect(tester).center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '快甩停稳后聚焦图应居中',
    );
  });

  testWidgets('外部跳格（远距）同帧落位', (tester) async {
    final center = ValueNotifier<int>(500);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 500,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pumpAndSettle();

    center.value = 600; // 跨 100 格 > 一屏 → 落位分支
    await tester.pump();
    final imgs = _imageRects(tester);
    expect(imgs, isNotEmpty, reason: '跳格落位帧不得空窗');
    expect(
      (_centerImageRect(tester).center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '跳格须同帧落位到目标项居中',
    );
    await tester.pumpAndSettle();
    expect(
      (_centerImageRect(tester).center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '终态目标项保持居中',
    );
  });

  testWidgets('逐格慢滑：吸附居中不随次数漂移', (tester) async {
    final center = ValueNotifier<int>(500);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 500,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final errs = <double>[];
    for (var k = 0; k < 12; k++) {
      await tester.drag(find.byType(Filmstrip), const Offset(-56, 0)); // 2 格
      await tester.pumpAndSettle();
      final err = (_centerImageRect(tester).center.dx - _viewportW / 2).abs();
      errs.add(err);
      expect(
        err,
        lessThan(0.5),
        reason:
            '第 $k 次慢滑吸附后聚焦图应居中（偏差 $err；序列 $errs）',
      );
    }
  });

  testWidgets('拖动中间帧跟手（未松手时几何已实时移动）', (tester) async {
    // 回归：_onDragUpdate 改几何必须当帧 setState——曾漏掉导致拖动僵住
    // 直到松手（测试只断言终态时被掩盖）。
    final center = ValueNotifier<int>(10);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(200, 19));
    // 先过 touch-slop（slop 内的位移不进 onUpdate），再滑 30px 计量。
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 16));
    final anchorCx = _centerImageRect(tester).center.dx;
    await gesture.moveBy(const Offset(30, 0)); // 手指右滑 30px（未松手）
    // 等 shrink（180ms）收完再断言——收缩中邻居步距随 f 连续变化，
    // 混入会污染位移计量。
    await tester.pump(const Duration(milliseconds: 220));
    // 跨档换基后「中心最近图」会换人：断言 +30 位置上存在一张图
    //（整条平移不变性——换基不改变任何项的屏幕位置）。
    final targetCx = anchorCx + 30;
    final nearest = _imageRects(tester).reduce(
      (a, b) =>
          (a.center.dx - targetCx).abs() <= (b.center.dx - targetCx).abs()
              ? a
              : b,
    );
    expect(
      nearest.center.dx - anchorCx,
      inInclusiveRange(18, 44),
      reason: '拖动位移必须实时反映（跟手重绘；容差覆盖 slop 计量与 '
          'shrink 收缩的二阶位移——新步距 43.5 下 +30 目标位最近图可为右'
          '侧第二张；回归修复前 Actual=0 拖动僵死）',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final after = _centerImageRect(tester);
    expect(
      (after.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '松手停稳后回中',
    );
  });

  testWidgets('连续慢拖多格（单手势跨档+松手吸附）：不漂移', (tester) async {
    var reported = <int>[];
    final center = ValueNotifier<int>(500);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 500,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onCenterChanged: reported.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var k = 0; k < 8; k++) {
      final gesture = await tester.startGesture(const Offset(200, 19));
      for (var s = 0; s < 5; s++) {
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 32));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      final err = (_centerImageRect(tester).center.dx - _viewportW / 2).abs();
      expect(
        err,
        lessThan(0.5),
        reason: '第 $k 次连续拖（100px ≈ 3.5 格）吸附后应居中（偏差 $err）',
      );
    }
    for (var k = 0; k + 1 < reported.length; k++) {
      final d = reported[k + 1] - reported[k];
      expect(d, inInclusiveRange(-1, 2),
          reason: '慢拖跨档步进应 ≤1 格（序列 ${reported.take(30).toList()}）');
    }
  });

  testWidgets('锁步：pagePos fraction 双项插值跟随，pagerDriven 让位', (
    tester,
  ) async {
    var reported = <int>[];
    final center = ValueNotifier<int>(2);
    final pagePos = ValueNotifier<double>(2.0);
    final driven = ValueNotifier<bool>(false);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 10,
          initialIndex: 2,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onCenterChanged: reported.add,
          pagePos: pagePos,
          pagerDriven: driven,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 主图拖到 50%：出项 2 与入项 3 各半插值，整体左移 43.5×0.5。
    pagePos.value = 2.5;
    await tester.pump();
    expect(reported, isEmpty, reason: '锁步跟随不得上报（宿主在驱动）');
    final rects = _imageRects(tester)..sort((a, b) => a.left.compareTo(b.left));
    // 找到中间两张（插值项）：宽 = 23+9×0.5 = 27.5。
    final mid = rects.where((r) => (r.width - 27.5).abs() < 0.75).toList();
    expect(mid.length, 2, reason: '应有恰好两张半插值图（27.5 宽）');
    if (mid.length == 2) {
      // 两项中心距 = 43.5；中心点 ≈ 视口中心（出项 +21.75 / 入项 −21.75）。
      final pairCx = (mid[0].center.dx + mid[1].center.dx) / 2;
      expect(
        (pairCx - _viewportW / 2).abs(),
        lessThan(0.5),
        reason: '插值对应跨视口中心对称',
      );
      expect(
        (mid[1].center.dx - mid[0].center.dx - 43.5).abs(),
        lessThan(0.5),
        reason: '插值对中心步距恒 43.5',
      );
    }

    // 到达整页：入项 3 完整聚焦居中。
    pagePos.value = 3.0;
    await tester.pump();
    await tester.pumpAndSettle();
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '锁步到达整页后入项居中',
    );
    expect(img.width, closeTo(32, 0.5), reason: '入项完整聚焦尺寸（方形）');

    // pagerDriven = true（宿主程序驱动翻页）：锁步让位，不跟随 fraction。
    driven.value = true;
    await tester.pump();
    pagePos.value = 4.5;
    await tester.pump();
    final img2 = _centerImageRect(tester);
    expect(
      img2.width,
      closeTo(32, 0.5),
      reason: 'pagerDriven 时保持聚焦静止（锁步让位）',
    );
    expect(reported, isEmpty, reason: '全程无用户手势上报');
  });

  testWidgets('主图滑动锁步归一化后甩动：选区必须跟随（回弹回归）', (
    tester,
  ) async {
    // 真机复现链路（18:40:58 日志实证）：快甩停在 X → 主图手动滑一个
    // 往返（锁步跟随 + 归一化）→ 再甩条 → sel 卡死不跟、selDx 飙到
    // 数千 px，settle 一把拉回 = 用户看到的「条回弹」。
    var reported = <int>[];
    final center = ValueNotifier<int>(191);
    final pagePos = ValueNotifier<double>(191.0);
    final driven = ValueNotifier<bool>(false);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 1000,
          initialIndex: 191,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          onCenterChanged: reported.add,
          pagePos: pagePos,
          pagerDriven: driven,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 主图手动滑动：191 → 190.95 → 190.45 → 190（锁步 + 归一化）。
    pagePos.value = 190.95;
    await tester.pump();
    pagePos.value = 190.45;
    await tester.pump();
    pagePos.value = 190.0;
    await tester.pump();
    await tester.pumpAndSettle();

    // 甩条（向右 = 往回看，日志中 dir=+1 路径）。
    await tester.fling(find.byType(Filmstrip), const Offset(600, 0), 4200);
    await tester.pumpAndSettle();

    expect(
      reported,
      isNotEmpty,
      reason: '甩动位移数倍于格宽，选区必须跨档上报（真机实证 sel 卡死、'
          'settle 把整条拉回数千 px = 「条回弹」）',
    );
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '甩动停稳后聚焦图应居中',
    );
  });

  testWidgets('frozen：忽略手势与指令，解除后对齐 center', (tester) async {
    var reported = <int>[];
    final center = ValueNotifier<int>(10);
    final frozen = ValueNotifier<bool>(false);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          frozen: frozen,
          onCenterChanged: reported.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    frozen.value = true;
    await tester.pump();
    await tester.fling(find.byType(Filmstrip), const Offset(-250, 0), 600);
    await tester.pumpAndSettle();
    expect(reported, isEmpty, reason: 'frozen 中手势全忽略');
    var img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: 'frozen 中几何不动',
    );

    center.value = 5; // 冻结中的外部指令（删除流程同步）
    frozen.value = false; // 解除 → 对齐
    await tester.pumpAndSettle();
    img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '解除后对齐外部 center',
    );
  });

  testWidgets('frozen 置位截断在途甩动/吸附（pop 淡出窗口无滚动残留）', (tester) async {
    // 真机实证回归：pop 时 frozen 只拦新输入不拦已起跑的自驱动画——
    // fling 惯性/settle 补间在 200ms 淡出窗口继续滚 = 「滚动中的大图/
    // 条残留」轻微闪烁。置位瞬间必须断动画、几何冻结在当前值。
    final center = ValueNotifier<int>(10);
    final frozen = ValueNotifier<bool>(false);
    await tester.pumpWidget(
      _wrap(
        Filmstrip(
          itemCount: 30,
          initialIndex: 10,
          center: center,
          thumbnail: (i) => MemoryImage(_png),
          frozen: frozen,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 惯性进行中置 frozen。
    await tester.fling(find.byType(Filmstrip), const Offset(-250, 0), 600);
    await tester.pump(const Duration(milliseconds: 50));
    final during = _imageRects(tester);
    frozen.value = true;
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    final after = _imageRects(tester);
    expect(after.length, during.length, reason: '截断后视口 item 集不变');
    for (var k = 0; k < during.length; k++) {
      expect(
        after[k].topLeft,
        during[k].topLeft,
        reason: 'frozen 置位后几何必须纹丝不动（第 $k 项；旧实现惯性/'
            'settle 继续跑 = pop 淡出窗口滚动残留）',
      );
    }

    // settle 吸附中置 frozen 同样截断：惯性尾声（已转 settle 补间）再验一次。
    frozen.value = false;
    await tester.pumpAndSettle();
    await tester.fling(find.byType(Filmstrip), const Offset(-150, 0), 400);
    await tester.pump(const Duration(milliseconds: 260)); // 惯性尽，settle 中
    final settling = _imageRects(tester);
    frozen.value = true;
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    final settled = _imageRects(tester);
    for (var k = 0; k < settling.length; k++) {
      expect(
        settled[k].topLeft,
        settling[k].topLeft,
        reason: 'settle 补间中 frozen 同样立即截断（第 $k 项）',
      );
    }
  });
}
