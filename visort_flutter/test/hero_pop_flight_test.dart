// hero pop flight（SDK 补丁契约）回归测试：
//   - 跑在本机打过补丁的 heroes.dart 上（~/Dev/Env/flutter + visort patch，
//     CI 用归档 flutter-sdk-patches/heroes_3.47.1_patched.dart 覆盖——
//     两端同源，契约一致）；
//   - 核心契约：pop flight 无论同步启动还是 deferred（app 置
//     HeroController.deferNextPopFlight，网格 band 重建后再启动），to 侧
//     hero 的 placeholder（push 时 keepPlaceholder 遗留，child 在
//     Offstage 内 = 黑块 + 手势失效）必须被恢复；
//   - 源自 2026-09 真机「相册缩略图黑块/闪烁」连环时序 bug 的最小骨架
//     （home tile flightTag 门控 + 无配对 pop），真机全链路回归靠
//     probe.log 事后拉取（core/diag/probe_log.dart）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderOffstage;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pop deferred flight：to hero 必须恢复（黑块回归）', (tester) async {
    const tileKey = ValueKey('tile_child');
    final flightTag = <String?>['photo_a']; // push 后残留（app 在 pop 完成后才清）

    Widget home() => Scaffold(
          body: GridView.count(
            crossAxisCount: 3,
            children: [
              for (final t in ['a', 'b', 'c'])
                GestureDetector(
                  onTap: () {},
                  child: HeroMode(
                    enabled: flightTag[0] == null || flightTag[0] == 'photo_$t',
                    child: Hero(
                      tag: 'photo_$t',
                      child: KeyedSubtree(
                        key: t == 'a' ? tileKey : ValueKey('c_$t'),
                        child: const ColoredBox(color: Colors.red),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );

    // album 路由：无 photo_a 的 hero（模拟网格滚走第一张/配不上）。
    Widget album() => Scaffold(
          body: GridView.count(
            crossAxisCount: 3,
            children: [
              for (final t in ['x', 'y', 'z'])
                Hero(
                  tag: 'photo_$t',
                  child: ColoredBox(color: Colors.blue),
                ),
            ],
          ),
        );

    final albumRoute = PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => album(),
      transitionsBuilder: (_, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    );

    await tester.pumpWidget(MaterialApp(home: home()));
    await tester.pumpAndSettle();

    // ── push album：tile 'a' 飞行 → keepPlaceholder ──
    tester.state<NavigatorState>(find.byType(Navigator).first).push(albumRoute);
    await tester.pump(); // push 首帧（flight manifest postFrame 构建）
    await tester.pump(const Duration(milliseconds: 250)); // 动画完成
    await tester.pumpAndSettle();

    // ── pop album：deferred flight 路径（模拟 album_screen 置标志）──
    // ignore: invalid_use_of_protected_member
    HeroController.deferNextPopFlight = true;
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump(); // pop 首帧 + deferred postFrame
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 断言：tile 'a' 的 child 恢复渲染（placeholder 已撤）。
    // 黑块形态 = Hero build 走 showPlaceholder 分支（child 在 Offstage 内）。
    // 父链上最近的 RenderOffstage 即 Hero 的（placeholder 包装层）。
    RenderObject? node = tester.renderObject(find.byKey(tileKey));
    RenderOffstage? off;
    while (node != null) {
      if (node is RenderOffstage) {
        off = node;
        break;
      }
      node = node.parent;
    }
    expect(off?.offstage, isFalse, reason: 'pop 后 tile child 必须恢复显示');
  });
}
