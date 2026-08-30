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
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/features/review/review_controller.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/session/session_models.dart';

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

  group('skipRemaining（审核按钮提前收尾）', () {
    test('剩余全部标记 skip，游标到末尾进完成态', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a.jpg → idx 1
      controller.skipRemaining();
      final s = controller.state;
      expect(s.currentIndex, 3);
      expect(s.isComplete, true, reason: '完成态由 SortSessionGate 自动跳 Review');
      expect(s.decisions!.length, 3);
      expect(s.decisions!['a.jpg']!.action, DecisionAction.move,
          reason: '已决策的 a 不被覆盖');
      expect(s.decisions!['b.jpg']!.action, DecisionAction.skip);
      expect(s.decisions!['c.jpg']!.action, DecisionAction.skip);
    });

    test('中途调用：当前未决策的这张也一并跳过', () {
      initSession();
      controller.decide(DecisionAction.delete); // a.jpg → idx 1
      controller.skipRemaining();
      final s = controller.state;
      expect(s.decisions!.length, 3);
      expect(s.decisions!['b.jpg']!.action, DecisionAction.skip);
      expect(s.decisions!['c.jpg']!.action, DecisionAction.skip);
    });

    test('已完成 session 调用不产生新决策', () {
      initSession();
      controller.decide(DecisionAction.skip); // a
      controller.decide(DecisionAction.skip); // b
      controller.decide(DecisionAction.skip); // c → 完成
      controller.skipRemaining();
      expect(controller.state.decisions!.length, 3);
      expect(controller.state.currentIndex, 3);
    });

    test('审核后仍可逐个 undo 回退（Review 返回继续整理的兜底）', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a → idx 1
      controller.skipRemaining(); // b, c skip → idx 3
      controller.undo(); // 撤 c
      final s = controller.state;
      expect(s.currentIndex, 2);
      expect(s.decisions!.containsKey('c.jpg'), false);
      expect(s.decisions!['b.jpg']!.action, DecisionAction.skip);
    });

    test('审核后统计：undecided=0，skipped 含剩余张数', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a
      controller.skipRemaining(); // b, c skip
      final stats = computeReviewStats(controller.state);
      expect(stats.moved, 1);
      expect(stats.skipped, 2);
      expect(stats.undecided, 0);
      expect(stats.undecidedIds, isEmpty);
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

  group('pruneTrashedPhotos（恢复会话剔除回收站项）', () {
    test('剔除当前及之后的未决策 trashed 图，index 不动', () {
      initSession(); // a/b/c, index=0
      controller.pruneTrashedPhotos({'b.jpg'});
      final s = controller.state;
      expect(s.images.map((i) => i.relativePath), ['a.jpg', 'c.jpg']);
      expect(s.currentIndex, 0);
      expect(s.currentImage?.relativePath, 'a.jpg');
    });

    test('剔除 index 之前的图，index 前移保持指向原图', () {
      initSession();
      controller.goToIndex(2); // 指向 c
      controller.pruneTrashedPhotos({'a.jpg'});
      final s = controller.state;
      expect(s.images.map((i) => i.relativePath), ['b.jpg', 'c.jpg']);
      expect(s.currentIndex, 1, reason: '前面少了一张，index 前移仍指向 c');
      expect(s.currentImage?.relativePath, 'c.jpg');
    });

    test('已决策的 trashed 图同样剔除，决策作废', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a 已决策, index=1
      controller.pruneTrashedPhotos({'a.jpg'});
      final s = controller.state;
      expect(s.images.map((i) => i.relativePath), ['b.jpg', 'c.jpg']);
      expect(s.decisions, isNot(contains('a.jpg')),
          reason: '决策一并作废，不参与 Run');
      expect(s.currentIndex, 0, reason: '前面少一张，index 前移');
      expect(s.currentImage?.relativePath, 'b.jpg');
    });

    test('剔除后 undo 只作用于存活决策，不复活被作废的', () {
      initSession();
      controller.decide(DecisionAction.move, destKey: 'A'); // a, index=1
      controller.decide(DecisionAction.move, destKey: 'S'); // b, index=2
      controller.pruneTrashedPhotos({'b.jpg'});
      expect(controller.state.decisions?.keys, ['a.jpg']);
      final undone = controller.undo();
      expect(undone, isTrue);
      expect(controller.state.decisions, isEmpty);
      expect(controller.state.currentImage?.relativePath, 'a.jpg');
    });

    test('剔除后 index 越界则 clamp 到末张', () {
      initSession();
      controller.goToIndex(2); // 指向 c（未决策）
      controller.pruneTrashedPhotos({'c.jpg'});
      final s = controller.state;
      expect(s.images.map((i) => i.relativePath), ['a.jpg', 'b.jpg']);
      expect(s.currentIndex, 1);
      expect(s.currentImage?.relativePath, 'b.jpg');
    });
  });
}
