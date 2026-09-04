// 滑动多选（ente SwipeToSelectHelper/Wrapper 移植）核心链路测试：
//   1. 水平轻扫（路径 B）起手图必须包含在选中范围（anchor 修复回归）
//   2. 小步序列轻扫（真机高频小 delta 模拟）同样包含起手图
//   3. 长按起手（路径 A）拖选包含起手图
//   4. 反向回拖撤销

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery_file_widget.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery_swipe_helper.dart';
import 'package:visort_flutter/ui/ente_viewer/selected_files.dart';
import 'package:visort_flutter/ui/ente_viewer/swipe_selection_wrapper.dart';
import 'package:visort_flutter/ui/ente_viewer/swipe_to_select_helper.dart';

MsImageInfo _f(int i) => MsImageInfo(
      id: 'f$i',
      name: 'f$i.jpg',
      size: 100,
      mime: 'image/jpeg',
      bucketId: 'b',
      dateAddedMs: 1000 - i,
      dateModifiedMs: 1000 - i,
    );

Future<void> _pumpGrid(
  WidgetTester tester, {
  required SwipeToSelectHelper helper,
  required ValueNotifier<bool> active,
  required SelectedFiles selection,
}) async {
  final tiles = [for (var i = 0; i < 5; i++) _f(i)]
      .map(
        (f) => SizedBox(
          width: 100,
          height: 100,
          child: GalleryFileWidget(
            file: f,
            selectedFiles: selection,
            photoGridSize: 5,
            onTap: (_) {},
            onLongPress: (_) {},
          ),
        ),
      )
      .toList();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GallerySwipeHelper(
          helper: helper,
          swipeActiveNotifier: active,
          child: SwipeSelectionWrapper(
            swipeHelper: helper,
            selectedFiles: selection,
            isEnabled: true,
            swipeActiveNotifier: active,
            scrollController: ScrollController(),
            child: Align(
              alignment: Alignment.topLeft,
              child: SingleChildScrollView(
                child: Row(children: tiles),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // 模拟 album_screen._onSelectionDelta：增量回写真源 + 渲染层
  // （测试里真源即 selection 本身，直接增量应用）。
  void applyDelta(SelectedFiles selection, Set<MsImageInfo> s, Set<MsImageInfo> u) {
    if (s.isNotEmpty) selection.selectAll(s);
    if (u.isNotEmpty) selection.unSelectAll(u);
  }

  testWidgets('水平轻扫：起手图包含在选中范围', (tester) async {
    final files = [for (var i = 0; i < 5; i++) _f(i)];
    final selection = SelectedFiles();
    selection.selectAll({files[4]}); // 勾选态已有选中（路径 B 前提，同源实例）
    final active = ValueNotifier<bool>(false);
    final deltas = <String>[];
    final helper = SwipeToSelectHelper(
      allFiles: files,
      selectedFiles: selection,
      onSelectionDelta: (s, u) {
        deltas.add('sel:{${s.map((f) => f.id)}} un:{${u.map((f) => f.id)}}');
        applyDelta(selection, s, u);
      },
    );
    await _pumpGrid(tester, helper: helper, active: active, selection: selection);

    // 按下 f0 中心 → 一次大步水平滑到 f2 中心 → 松手
    final g = await tester.startGesture(const Offset(50, 50));
    await g.moveBy(const Offset(200, 0));
    await g.up();
    await tester.pump();

    expect(selection.isFileSelected(_f(0)), isTrue, reason: '起手图 f0 必须被选中；deltas=$deltas');
    expect(selection.isFileSelected(_f(2)), isTrue, reason: '滑入的 f2 应被选中；deltas=$deltas');
  });

  testWidgets('小步轻扫（每步 <4px）：起手图仍包含', (tester) async {
    final files = [for (var i = 0; i < 5; i++) _f(i)];
    final selection = SelectedFiles();
    selection.selectAll({files[4]});
    final active = ValueNotifier<bool>(false);
    final helper = SwipeToSelectHelper(
      allFiles: files,
      selectedFiles: selection,
      onSelectionDelta: (s, u) => applyDelta(selection, s, u),
    );
    await _pumpGrid(tester, helper: helper, active: active, selection: selection);

    // 真机高频小步：每步 3px（<4 阈值）累计 200px，中间无单步超阈值——
    // 最后一步大一点触发激活
    final g = await tester.startGesture(const Offset(50, 50));
    for (var i = 0; i < 60; i++) {
      await g.moveBy(const Offset(3, 0));
    }
    await g.moveBy(const Offset(10, 0)); // delta>4 → 激活
    await g.up();
    await tester.pump();

    expect(selection.isFileSelected(_f(0)), isTrue, reason: '小步轻扫起手图 f0 必须被选中');
  });

  testWidgets('长按起手拖选：包含起手图', (tester) async {
    final files = [for (var i = 0; i < 5; i++) _f(i)];
    final selection = SelectedFiles();
    final active = ValueNotifier<bool>(false);
    final helper = SwipeToSelectHelper(
      allFiles: files,
      selectedFiles: selection,
      onSelectionDelta: (s, u) => applyDelta(selection, s, u),
    );
    await _pumpGrid(tester, helper: helper, active: active, selection: selection);

    // 长按 f0（进入选择态由 onLongPress 外层负责，此处直摸 helper 链路：
    // tile 长按后 _handleLongPressForSwipe 需要 files 非空——预选 f4）
    selection.selectAll({files[4]});
    await tester.pump();
    final g = await tester.startGesture(const Offset(50, 50));
    await tester.pump(const Duration(milliseconds: 600)); // 长按
    await g.moveBy(const Offset(120, 0));
    await tester.pump();
    await g.up();
    await tester.pump();

    expect(selection.isFileSelected(_f(0)), isTrue, reason: '长按起手 f0 必须被选中');
  });

  testWidgets('反向回拖：撤销刚才的选中', (tester) async {
    final files = [for (var i = 0; i < 5; i++) _f(i)];
    final selection = SelectedFiles();
    selection.selectAll({files[4]});
    final active = ValueNotifier<bool>(false);
    final helper = SwipeToSelectHelper(
      allFiles: files,
      selectedFiles: selection,
      onSelectionDelta: (s, u) => applyDelta(selection, s, u),
    );
    await _pumpGrid(tester, helper: helper, active: active, selection: selection);

    final g = await tester.startGesture(const Offset(50, 50));
    await g.moveBy(const Offset(200, 0)); // f0 → f2
    await tester.pump();
    await g.moveBy(const Offset(-100, 0)); // 回拖到 f1
    await g.up();
    await tester.pump();

    expect(selection.isFileSelected(_f(2)), isFalse, reason: '回拖后 f2 应被撤销');
    expect(selection.isFileSelected(_f(1)), isTrue, reason: 'f1 仍在区间内');
    expect(selection.isFileSelected(_f(0)), isTrue, reason: '起手图 f0 保留');
  });

  testWidgets('从唯一选中图轻扫：恒选语义（保持+扩展），会话不被清空误杀', (tester) async {
    // 真机实证场景：只勾了起手图 → 轻扫。原实现两重 bug：①方向=取消、
    // 取消它后选择集瞬时清空被 _onSelectionChanged 误判为"外部退出勾选态"
    // → 会话 reset → 二次锚定起手图丢失且方向翻转（[SWIPE] 日志实证）；
    // ②ente"起点已选→取消方向"语义与用户预期不符——拖选恒为选。
    final files = [for (var i = 0; i < 5; i++) _f(i)];
    final selection = SelectedFiles();
    selection.selectAll({files[0]}); // 起手图 f0 是唯一选中（同源实例）
    final active = ValueNotifier<bool>(false);
    final helper = SwipeToSelectHelper(
      allFiles: files,
      selectedFiles: selection,
      onSelectionDelta: (s, u) => applyDelta(selection, s, u),
    );
    await _pumpGrid(tester, helper: helper, active: active, selection: selection);

    final g = await tester.startGesture(const Offset(50, 50));
    await g.moveBy(const Offset(150, 0)); // 从 f0 滑到 f1
    await tester.pump();
    await g.moveBy(const Offset(100, 0)); // 继续到 f2
    await g.up();
    await tester.pump();

    expect(selection.isFileSelected(_f(0)), isTrue, reason: '起手图 f0 保持选中（包含在范围内）');
    expect(selection.isFileSelected(_f(1)), isTrue, reason: 'f1 被扩展选中');
    expect(selection.isFileSelected(_f(2)), isTrue, reason: 'f2 被扩展选中（方向恒选不翻转）');
  });
}
