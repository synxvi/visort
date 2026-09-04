// Filmstrip 组件冒烟 + 几何测试：
//  - 冒烟：构建/拖动/吸附/程序滚动不抛异常（复现真机「条黄底感叹号」，
//    release ErrorWidget = 同步 build 异常，pump 一帧即暴露堆栈）
//  - 几何：稳态聚焦图居中于视口中心（±0.5px）、白框套图、相邻图间隙 = 5px
//    （变格宽 28/36 设计值，防「聚焦图偏出框」回归——曾因等距/聚焦格
//    公式混用偏右 4px，真机实证）
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
        // ⚠️ 不用 Center：tester.getRect 是全局坐标，条贴 (0,0) 厃其
        // 全局中心 = _viewportW/2，断言坐标系才对得上（Center 会把条挪到
        // 测试视口中央，坐标全偏——曾把几何正确的布局误判为偏移）。
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _viewportW,
            height: 44,
            child: strip,
          ),
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

/// 找到水平中心最接近视口中心的 Image（= 聚焦项图片）的 Rect。
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
  testWidgets('Filmstrip 构建/滚动/吸附不抛异常', (tester) async {
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
    await tester.fling(find.byType(ListView), const Offset(-200, 0), 800);
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '拖动路径应无异常');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '吸附聚焦路径应无异常');

    center.value = 1;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '程序滚动路径应无异常');
  });

  testWidgets('Filmstrip 聚焦图居中于白框且间隙均匀（变格宽 28/42）', (
    tester,
  ) async {
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

    // 初始态：聚焦图片中心 ≈ 视口中心（吸附修正公式含 +4）。
    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '初始定位聚焦图应居中（偏移 = 跑出白框，真机实证过偏右 4px）',
    );
    // 聚焦图尺寸 = 31×39。
    expect(img.width, closeTo(31, 0.5));
    expect(img.height, closeTo(39, 0.5));
    // 白框 34×42 套住聚焦图（框中心 = 视口中心，框内沿 = 图）。
    final frame = tester.getRect(find.byKey(const ValueKey(
      'filmstrip_focus_frame',
    )));
    expect(
      (frame.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '白框应钉在条正中',
    );
    expect(
      frame.contains(img.topCenter) && frame.contains(img.bottomCenter),
      isTrue,
      reason: '聚焦图应完整落在白框内',
    );

    // 相邻普通项间隙 = 格 28 − 图 23 = 5px；聚焦项两侧 = (42−31)/2 +
    // (28−23)/2 = 8px（2026-09 用户定稿：聚焦项两侧间距 8px）。
    final rects = _imageRects(tester)
      ..sort((a, b) => a.left.compareTo(b.left));
    final gaps = <double>[];
    for (var k = 0; k + 1 < rects.length; k++) {
      final gap = rects[k + 1].left - rects[k].right;
      if (gap.abs() < 20) gaps.add(gap); // 排除视口两端被裁剪的
    }
    var gap5 = 0, gap8 = 0;
    for (final g in gaps) {
      if ((g - 5).abs() < 0.75) {
        gap5++;
      } else if ((g - 8).abs() < 0.75) {
        gap8++;
      } else {
        fail('间隙既非 5 也非 8：$g');
      }
    }
    expect(gap8, 2, reason: '聚焦项左右各一个 8px 间隙');
  });

  testWidgets('Filmstrip 末项聚焦居中（右侧 padding 补 origin）', (tester) async {
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
      reason: '末项聚焦位 (n−1)×28+7 需可达（右侧 padding 已补偿），'
          '否则被 clamp 在等距位 = 聚焦图偏出框',
    );
  });

  testWidgets('Filmstrip 拖动停稳后聚焦图回到白框中心（吸附修正幂等）', (
    tester,
  ) async {
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

    // 拖动跨几格后停稳：吸附 + 撑开 + 修正应收敛（不能停在等距格 i×28
    // ——聚焦图会偏出框右 4px）。
    await tester.fling(find.byType(ListView), const Offset(-250, 0), 600);
    await tester.pumpAndSettle();

    final img = _centerImageRect(tester);
    expect(
      (img.center.dx - _viewportW / 2).abs(),
      lessThan(0.5),
      reason: '吸附停稳后聚焦图应居中（曾因 snap/修正来回拉扯偏右 4px）',
    );
  });
}
