// VisortLogo 入场特效 —— 冷启动只播一次 + 字母依次上滑时序
//
// 用 tester.pump 精确推进动画时钟验证：
//   - 冷启动首帧：所有字母在裁剪区下方（不可见）
//   - 中途：V 已滑入、后续字母仍隐藏（依次入场）
//   - 结束：六个字母全部就位（最终 logo）
//   - 闸门：重建/新实例（模拟 popTo Home 重建）不再播放，直接静态呈现

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/shared/widgets/visort_logo.dart';

void main() {
  // static _entrancePlayed 是进程级闸门，每个用例需复位后重启 widget 树。
  Future<void> pumpLogo(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const VisortLogo()),
        body: const SizedBox.shrink(),
      ),
    ));
  }

  // AppBar 内部自带若干 SlideTransition，限定在 logo 子树内查找。
  final logoSlides = find.descendant(
    of: find.byType(VisortLogo),
    matching: find.byType(SlideTransition),
  );

  testWidgets('冷启动：字母依次从下往上滑入，最终全部就位', (tester) async {
    await pumpLogo(tester);

    // 首帧：SlideTransition 均在 Offset(0,1)——字母整体在 ClipRect 下方，
    // 不可见（裁剪区外）。
    var slides = tester.widgetList<SlideTransition>(logoSlides).toList();
    expect(slides.length, 6, reason: '六个字母各有独立上滑动画');
    for (final s in slides) {
      expect(s.position.value, const Offset(0, 1));
    }

    // 250ms 时：V（区间 [0,300]）临近落位，I（[55,355]）上滑中，
    // T（区间起点 275ms）尚未开始——体现「依次」错峰。
    await tester.pump(const Duration(milliseconds: 250));
    slides = tester.widgetList<SlideTransition>(logoSlides).toList();
    expect(slides[0].position.value.dy, lessThan(0.05), reason: 'V 临近落位');
    expect(slides[1].position.value.dy, lessThan(1), reason: 'I 正在上滑');
    expect(slides[5].position.value.dy, 1, reason: 'T 尚未开始');

    // 总时长 300+5×55=575ms 后：全部字母回到原位。
    await tester.pumpAndSettle();
    slides = tester.widgetList<SlideTransition>(logoSlides).toList();
    for (final s in slides) {
      expect(s.position.value, Offset.zero);
    }
    expect(find.text('V'), findsOneWidget);
    expect(find.text('I'), findsOneWidget);
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('非冷启动（闸门已关闭）：静态呈现，无动画', (tester) async {
    // 前一个用例已把 static 闸门置位（同进程），此时新建的 logo 应直接静态。
    await pumpLogo(tester);
    await tester.pump();

    // 不 playing → 不构建 SlideTransition，字母直接是静态 Text。
    expect(logoSlides, findsNothing);
    for (final letter in ['V', 'I', 'S', 'O', 'R', 'T']) {
      expect(find.text(letter), findsOneWidget, reason: '字母 $letter 静态渲染');
    }
  });
}
