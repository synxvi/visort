// 回归测试：删除子目录行的焦点处理 + 退场动画布局健康。
//
// 背景 bug：删除末位子目录行时「所在行位置延伸到下方 + 灰屏闪烁」，
// 删中间行无此现象。根因：删末位持焦行后下方无输入框可自然接焦，
// 焦点丢失 → IME 收起 → 窗口 resize → SurfaceView resize 闪灰。
// 修复：删除持焦行前先把焦点转给父目录输入框（键盘保持展开）。
//
// harness 与 home_screen_android.dart 的 _buildNewDirConfig/_SubDirRow
// 结构同构（AnimatedList(shrinkWrap+NeverScroll) + SizeTransition +
// FocusNode 行内持有 + 删除前焦点转移）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Harness extends StatefulWidget {
  const Harness({super.key});
  @override
  State<StatefulWidget> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  final _listKey = GlobalKey<AnimatedListState>();
  final parentFocus = FocusNode();
  final List<String> _dirs = ['alpha', 'beta', 'gamma'];

  void removeAt(int idx) {
    if (_dirs.length <= 1) return;
    final removed = _dirs[idx];
    _listKey.currentState?.removeItem(
      idx,
      (ctx, animation) => IgnorePointer(child: _row(idx, removed, animation)),
    );
    setState(() => _dirs.removeAt(idx));
  }

  Widget _row(int idx, String value, Animation<double> animation) {
    return _Row(
      value: value,
      keyLabel: String.fromCharCode(65 + idx),
      animation: animation,
      // —— 与生产修复同构：父级闭包拿到行 focusNode，删除前转移焦点 ——
      onDelete: (focusNode) {
        if (focusNode.hasFocus) parentFocus.requestFocus();
        removeAt(idx);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        TextField(
          focusNode: parentFocus,
          decoration: const InputDecoration(hintText: 'parent'),
        ),
        AnimatedList(
          key: _listKey,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          initialItemCount: _dirs.length,
          itemBuilder: (ctx, idx, animation) => _row(idx, _dirs[idx], animation),
        ),
      ],
    );
  }
}

/// 单行：State 持有 controller 与 FocusNode（与 _SubDirRow 同构）。
class _Row extends StatefulWidget {
  const _Row({
    required this.value,
    required this.keyLabel,
    required this.animation,
    required this.onDelete,
  });
  final String value;
  final String keyLabel;
  final Animation<double> animation;
  final void Function(FocusNode focusNode) onDelete;
  @override
  State<_Row> createState() => RowState();
}

class RowState extends State<_Row> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);
  final focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: widget.animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: widget.animation,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Container(color: Colors.blue[300], alignment: Alignment.center, child: Text(widget.keyLabel)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: focusNode,
                    decoration: const InputDecoration(hintText: 'folder'),
                  ),
                ),
                GestureDetector(
                  onTap: () => widget.onDelete(focusNode),
                  child: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  Future<HarnessState> pumpHarness(WidgetTester tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Harness(key: key)),
    ));
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  testWidgets('删除持焦末位行：焦点先转父目录框（键盘不收，无 resize 闪灰路径）', (tester) async {
    final h = await pumpHarness(tester);
    // 聚焦末位行输入框（模拟用户刚在编辑子目录名）
    final lastField = find.byType(TextField).last;
    await tester.tap(lastField);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);

    // 点末位行删除按钮
    await tester.tap(find.byIcon(Icons.remove_circle_outline).last);
    await tester.pump();

    // 修复断言：焦点必须仍落在某个输入框上（父目录框），而不是丢失。
    expect(FocusManager.instance.primaryFocus, isNotNull,
        reason: '删末位持焦行后焦点不得丢失——IME 收起会触发窗口 resize 闪灰');
    // 退场动画走完无异常
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(h._dirs, ['alpha', 'beta']);
  });

  testWidgets('删除持焦中间行：同样先转父目录框，动画健康', (tester) async {
    final h = await pumpHarness(tester);
    await tester.tap(find.byType(TextField).at(2)); // beta 行
    await tester.pump();
    await tester.tap(find.byIcon(Icons.remove_circle_outline).at(1));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(h._dirs, ['alpha', 'gamma']);
  });

  testWidgets('退场动画期间列表布局健康（无异常高度）', (tester) async {
    await pumpHarness(tester);
    (tester.state(find.byType(Harness)) as HarnessState).removeAt(2);
    var maxHeight = 0.0;
    for (var i = 0; i <= 7; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      for (final q in find.byType(SizeTransition).evaluate()) {
        final box = q.findRenderObject() as RenderBox?;
        if (box != null && box.attached) {
          maxHeight = maxHeight > box.size.height ? maxHeight : box.size.height;
        }
      }
    }
    expect(tester.takeException(), isNull);
    expect(maxHeight < 200, isTrue, reason: '退场行高度不应爆炸');
  });
}
