// Session 状态机核心逻辑测试 —— 验证 decide/undo/recompute 对齐 Python 版
//
// 重点覆盖：
//   - decide 四种动作（move-folder / move-root / delete / skip）的决策格式
//   - currentIndex 递增与 done 标志
//   - undo 撤销最后一个 + 索引回退
//   - recomputeFolders 路径拼接（\ 与 / 分隔符）
//   - review 统计派生

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
import 'package:sortr_flutter/features/review/review_controller.dart';
import 'package:sortr_flutter/features/session/session_controller.dart';
import 'package:sortr_flutter/features/session/session_models.dart';

ImageRef _img(String root, String rel) =>
    ImageRef(root: root, relativePath: rel, extension: '.jpg');

void main() {
  late ProviderContainer container;
  late SessionController controller;

  setUp(() {
    container = ProviderContainer();
    controller = container.read(sessionControllerProvider.notifier);
  });

  tearDown(() => container.dispose());

  /// 模拟扫描初始化一个 3 张图的 session
  void initSession({String dest = r'D:\Photos'}) {
    controller.initFromScan(
      sourceDir: r'D:\src',
      destinationParent: dest,
      images: [
        _img(r'D:\src', 'a.jpg'),
        _img(r'D:\src', 'b.jpg'),
        _img(r'D:\src', 'c.jpg'),
      ],
      folderTemplates: [
        FolderTemplate(key: 'A', label: 'General'),
        FolderTemplate(key: 'S', label: 'Screens'),
      ],
    );
  }

  group('initFromScan', () {
    test('初始化后状态正确', () {
      initSession();
      final s = controller.state;
      expect(s.images.length, 3);
      expect(s.currentIndex, 0);
      expect(s.decisions, isEmpty);
      expect(s.folders.length, 2);
      expect(s.folders[0].path, r'D:\Photos\General');
      expect(s.folders[1].path, r'D:\Photos\Screens');
    });
  });

  group('decide', () {
    test('move 到普通文件夹：决策格式与索引递增', () {
      initSession();
      final r = controller.decide(DecisionAction.move, destKey: 'A');
      expect(r.nextIndex, 1);
      expect(r.done, false);

      final decision = controller.state.decisions!['a.jpg']!;
      expect(decision.action, DecisionAction.move);
      expect(decision.destKey, 'A');
      expect(decision.destLabel, 'General');
      expect(decision.destPath, r'D:\Photos\General');
    });

    test('move 到根目录：destKey=__root__', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: kRootDestKey);
      final decision = controller.state.decisions!['a.jpg']!;
      expect(decision.isMoveToRoot, true);
      expect(decision.destKey, kRootDestKey);
      expect(decision.destPath, r'D:\Photos'); // 根目录路径
    });

    test('delete：决策格式', () {
      initSession();
      controller.decide(DecisionAction.delete);
      final decision = controller.state.decisions!['a.jpg']!;
      expect(decision.action, DecisionAction.delete);
      expect(decision.destKey, isNull);
    });

    test('skip：决策格式', () {
      initSession();
      controller.decide(DecisionAction.skip);
      final decision = controller.state.decisions!['a.jpg']!;
      expect(decision.action, DecisionAction.skip);
    });

    test('最后一张决策后 done=true', () {
      initSession();
      controller.decide(DecisionAction.skip); // a.jpg → idx 1
      controller.decide(DecisionAction.skip); // b.jpg → idx 2
      final r = controller.decide(DecisionAction.skip); // c.jpg → idx 3
      expect(r.nextIndex, 3);
      expect(r.done, true);
      expect(controller.state.currentIndex, 3);
    });

    test('重新决策同一张图会覆盖', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A');
      // 回到第一张重新决策
      controller.goToIndex(0);
      controller.decide(DecisionAction.delete);
      final decision = controller.state.decisions!['a.jpg']!;
      expect(decision.action, DecisionAction.delete);
      expect(controller.state.decisions!.length, 1);
    });
  });

  group('undo', () {
    test('撤销最后一个决策，索引回退到该图', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a.jpg, idx→1
      controller.decide(DecisionAction.delete); // b.jpg, idx→2
      expect(controller.state.currentIndex, 2);

      final ok = controller.undo();
      expect(ok, true);
      // b.jpg 被撤销，索引回到 b.jpg 的位置（1）
      expect(controller.state.currentIndex, 1);
      expect(controller.state.decisions!.containsKey('b.jpg'), false);
      expect(controller.state.decisions!.containsKey('a.jpg'), true);
    });

    test('空决策时 undo 返回 false', () {
      initSession();
      expect(controller.undo(), false);
    });

    test('撤销后可重新决策', () {
      initSession();
      controller.decide(DecisionAction.delete); // a.jpg
      controller.undo(); // 回到 a.jpg
      controller.decide(DecisionAction.skip); // a.jpg 改为 skip
      final decision = controller.state.decisions!['a.jpg']!;
      expect(decision.action, DecisionAction.skip);
    });
  });

  group('recomputeFolders', () {
    test('Windows 反斜杠分隔', () {
      initSession(dest: r'D:\Photos');
      controller.recomputeFolders(destinationParent: r'D:\NewDest');
      expect(controller.state.folders[0].path, r'D:\NewDest\General');
    });

    test('正斜杠分隔', () {
      initSession();
      controller.recomputeFolders(destinationParent: 'D:/Photos/');
      // 去掉末尾斜杠后用 / 拼接
      expect(controller.state.folders[0].path, 'D:/Photos/General');
    });

    test('模板变化时重算', () {
      initSession();
      controller.recomputeFolders(
        templates: [FolderTemplate(key: 'X', label: 'NewFolder')],
      );
      expect(controller.state.folders.length, 1);
      expect(controller.state.folders[0].key, 'X');
      expect(controller.state.folders[0].label, 'NewFolder');
    });
  });

  group('导航', () {
    test('goToIndex 范围检查', () {
      initSession();
      controller.goToIndex(2);
      expect(controller.state.currentIndex, 2);
      controller.goToIndex(-1); // 越界忽略
      expect(controller.state.currentIndex, 2);
      controller.goToIndex(99); // 越界忽略
      expect(controller.state.currentIndex, 2);
    });
  });

  group('review 统计派生', () {
    test('moves/deletes/skips/undecided 计数正确', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a.jpg
      controller.decide(DecisionAction.delete); // b.jpg
      // c.jpg 未决策

      final stats = computeReviewStats(controller.state);
      expect(stats.moved, 1);
      expect(stats.deleted, 1);
      expect(stats.skipped, 0);
      expect(stats.undecided, 1);
      expect(stats.moveEntries.single.destLabel, 'General');
      expect(stats.deleteEntries.single, 'b.jpg');
      expect(stats.undecidedIds.single, 'c.jpg');
    });
  });
}
