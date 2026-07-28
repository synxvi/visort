// Run 控制器测试 —— 验证执行流程（move/delete/skip/源缺失/进度流/dest 解析）
//
// 用 FakeFileSystemRepository（内存实现）隔离真实 IO，
// 验证 run_controller 的行为对齐 Python /api/run。

import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/file_system_repository.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
import 'package:sortr_flutter/features/run/run_controller.dart';
import 'package:sortr_flutter/features/session/session_models.dart';

/// 内存版文件系统：用 Map 模拟已存在文件，记录移动/删除操作
class FakeFileSystem implements FileSystemRepository {
  /// 已存在的文件集合（key = root/relativePath）
  final Set<String> existing = {};
  /// 记录的移动操作（src → destDir）
  final List<({ImageRef src, String destDir})> moves = [];
  /// 记录的删除操作
  final List<ImageRef> deletes = [];

  String _key(String root, String rel) => '$root/$rel';

  @override
  Future<bool> exists(ImageRef ref) async =>
      existing.contains(_key(ref.root, ref.relativePath));

  @override
  Future<MoveResult> move(ImageRef src, String destDir) async {
    moves.add((src: src, destDir: destDir));
    existing.remove(_key(src.root, src.relativePath));
    return MoveResult(success: true, finalPath: '$destDir/${src.name}');
  }

  @override
  Future<bool> delete(ImageRef ref) async {
    deletes.add(ref);
    existing.remove(_key(ref.root, ref.relativePath));
    return true;
  }

  // 以下方法本测试不用
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeFileSystem fs;
  late RunController runner;

  setUp(() {
    fs = FakeFileSystem();
    runner = RunController(fs);
  });

  ImageRef _img(String rel) =>
      ImageRef(root: r'D:\src', relativePath: rel, extension: '.jpg');

  /// 构造一个 session：3 张图，decisions 为 move/delete/skip 各一
  SessionState _buildSession(LinkedHashMap<String, Decision> decisions) {
    final images = [_img('a.jpg'), _img('b.jpg'), _img('c.jpg')];
    final folders = [
      FolderDescriptor(key: 'A', label: 'General', path: r'D:\Dest\General'),
    ];
    return SessionState(
      sourceDir: r'D:\src',
      images: images,
      destinationParent: r'D:\Dest',
      folders: folders,
      decisions: decisions,
    );
  }

  test('三种动作混合执行：move/delete/skip 各正确分发', () async {
    fs.existing
      ..add(r'D:\src' + '/' + 'a.jpg')
      ..add(r'D:\src' + '/' + 'b.jpg')
      ..add(r'D:\src' + '/' + 'c.jpg');

    final decisions = LinkedHashMap<String, Decision>();
    decisions['a.jpg'] = Decision.move(
        destKey: 'A', destLabel: 'General', destPath: r'D:\Dest\General');
    decisions['b.jpg'] = Decision.delete();
    decisions['c.jpg'] = Decision.skip();

    final session = _buildSession(decisions);
    final events = await runner.run(session).toList();

    // 最后一个事件应是 done + results
    final done = events.lastWhere((e) => e.done == true);
    expect(done.results, isNotNull);
    expect(done.results!.moved.length, 1);
    expect(done.results!.deleted.length, 1);
    expect(done.results!.skipped.length, 1);
    expect(done.results!.errors, isEmpty);

    // fs 操作记录
    expect(fs.moves.length, 1);
    expect(fs.moves.single.destDir, r'D:\Dest\General');
    expect(fs.deletes.length, 1);
  });

  test('move 到根目录：destDir = destinationParent', () async {
    fs.existing.add(r'D:\src' + '/' + 'a.jpg');
    final decisions = LinkedHashMap<String, Decision>();
    decisions['a.jpg'] =
        Decision.moveToRoot(rootPath: r'D:\Dest', rootLabel: '@root@');
    final session = _buildSession(decisions);

    final events = await runner.run(session).toList();
    final done = events.lastWhere((e) => e.done == true);
    expect(done.results!.moved.length, 1);
    expect(fs.moves.single.destDir, r'D:\Dest'); // 根目录
  });

  test('源文件缺失 → 记入 errors', () async {
    // 不添加任何 existing 文件
    final decisions = LinkedHashMap<String, Decision>();
    decisions['a.jpg'] = Decision.delete();
    final session = _buildSession(decisions);

    final events = await runner.run(session).toList();
    final done = events.lastWhere((e) =>e.done == true);
    expect(done.results!.errors.length, 1);
    expect(done.results!.errors.single.reason, 'source_missing');
    expect(done.results!.deleted, isEmpty);
  });

  test('进度流：每处理一张发一条进度', () async {
    fs.existing
      ..add(r'D:\src' + '/' + 'a.jpg')
      ..add(r'D:\src' + '/' + 'b.jpg');
    final decisions = LinkedHashMap<String, Decision>();
    decisions['a.jpg'] = Decision.skip();
    decisions['b.jpg'] = Decision.skip();
    final session = _buildSession(decisions);

    final events = await runner.run(session).toList();
    // 2 张图 → 2 条进度 + 1 条 done = 3 条
    expect(events.length, 3);
    expect(events[0].current, 1);
    expect(events[0].total, 2);
    expect(events[0].currentFile, 'a.jpg');
    expect(events[1].current, 2);
    expect(events[1].currentFile, 'b.jpg');
    expect(events[2].done, true);
  });

  test('空 decisions → 立即 done', () async {
    final session = _buildSession(LinkedHashMap());
    final events = await runner.run(session).toList();
    expect(events.length, 1);
    expect(events.single.done, true);
    expect(events.single.results!.moved, isEmpty);
  });
}
