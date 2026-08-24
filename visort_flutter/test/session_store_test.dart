// SessionStore 单测 —— ffi 内存库直测(schema 复用 DatabaseService.createAll)


import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:visort_flutter/core/config/models.dart' show FolderTemplate;
import 'package:visort_flutter/core/config/profiles_service.dart'
    show FolderDescriptor;
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/session_store.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/features/session/session_models.dart';

ImageRef _img(int i) => ImageRef(
      root: '/tmp/src',
      relativePath: 'sub/IMG_$i.jpg',
      extension: '.jpg',
      displayName: 'IMG_$i.jpg',
    );

SessionState _state({
  List<ImageRef>? images,
  Map<String, Decision>? decisions,
  int currentIndex = 0,
}) {
  return SessionState(
    sourceDir: '/tmp/src',
    destinationParent: '/tmp/dst',
    images: images ?? [_img(1), _img(2), _img(3)],
    currentIndex: currentIndex,
    folderTemplates: const [FolderTemplate(key: 'A', label: '风景')],
    folders: const [FolderDescriptor(key: 'A', label: '风景', path: '/tmp/dst/风景')],
    decisions: decisions,
  );
}

Future<sqflite.Database> _memDb() async {
  sqflite.databaseFactory = databaseFactoryFfi;
  return sqflite.databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: sqflite.OpenDatabaseOptions(
      version: kDbVersion,
      onCreate: (db, _) => DatabaseService.createAll(db),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqflite.databaseFactory = databaseFactoryFfi;
  });

  group('SessionStore', () {
    test('saveNewSession → loadActive 往返保真', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      final decisions = <String, Decision>{}
        ..['sub/IMG_2.jpg'] = Decision.delete()
        ..['sub/IMG_3.jpg'] = Decision.move(
            destKey: 'A', destLabel: '风景', destPath: '/tmp/dst/风景');
      await store.saveNewSession(_state(decisions: decisions, currentIndex: 2));

      final r = await store.loadActive();
      expect(r, isNotNull);
      final s = r!.state;
      expect(s.sourceDir, '/tmp/src');
      expect(s.destinationParent, '/tmp/dst');
      expect(s.currentIndex, 2);
      expect(s.folderTemplates.length, 1);
      expect(s.folderTemplates.first.key, 'A');
      expect(s.folders.first.path, '/tmp/dst/风景');
      expect(s.images.length, 3);
      expect(s.images[1].relativePath, 'sub/IMG_2.jpg');
      expect(s.images[1].displayName, 'IMG_2.jpg');
      expect(s.images[1].root, '/tmp/src');
      // decisions 按 seq 重建插入序
      expect(s.decisions!.keys.toList(),
          ['sub/IMG_2.jpg', 'sub/IMG_3.jpg']);
      expect(s.decisions!['sub/IMG_2.jpg']!.action, DecisionAction.delete);
      final move = s.decisions!['sub/IMG_3.jpg']!;
      expect(move.action, DecisionAction.move);
      expect(move.destKey, 'A');
      expect(move.destPath, '/tmp/dst/风景');
      // seq 表 + nextSeq
      expect(r.seqById['sub/IMG_2.jpg'], 0);
      expect(r.seqById['sub/IMG_3.jpg'], 1);
      expect(r.nextSeq, 2);
      await db.close();
    });

    test('upsertDecision 新增 / REPLACE 重写;deleteDecision 撤销', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      await store.saveNewSession(_state());
      await store.upsertDecision('sub/IMG_1.jpg', Decision.skip(), 0);
      // 重 decide:REPLACE 覆盖,seq 保持调用方给的值
      await store.upsertDecision(
          'sub/IMG_1.jpg',
          Decision.move(
              destKey: 'A', destLabel: '风景', destPath: '/tmp/dst/风景'),
          0);
      var r = await store.loadActive();
      expect(r!.state.decisions!.length, 1);
      expect(r.state.decisions!['sub/IMG_1.jpg']!.action, DecisionAction.move);
      expect(r.seqById['sub/IMG_1.jpg'], 0);

      await store.deleteDecision('sub/IMG_1.jpg');
      r = await store.loadActive();
      expect(r!.state.decisions!.length, 0);
      expect(r.nextSeq, 0);
      await db.close();
    });

    test('updateCurrentIndex 持久化(goToIndex/undo 索引)', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      await store.saveNewSession(_state(currentIndex: 0));
      await store.updateCurrentIndex(5);
      expect((await store.loadActive())!.state.currentIndex, 5);
      await db.close();
    });

    test('hasActive 生命周期:空 false → save true → clear false', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      expect(await store.hasActive(), false);
      await store.saveNewSession(_state());
      expect(await store.hasActive(), true);
      await store.clear();
      expect(await store.hasActive(), false);
      expect(await store.loadActive(), isNull);
      await db.close();
    });

    test('summary:无会话 null;有会话返回 total/decided/currentIndex', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      expect(await store.summary(), isNull);
      final decisions = <String, Decision>{}
        ..['sub/IMG_1.jpg'] = Decision.skip();
      await store.saveNewSession(
          _state(decisions: decisions, currentIndex: 2));
      final s = await store.summary();
      expect(s, isNotNull);
      expect(s!.total, 3);
      expect(s.decided, 1);
      expect(s.currentIndex, 2);
      await db.close();
    });

    test('saveNewSession 覆写:新会话整体替换旧数据', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      await store.saveNewSession(_state());
      final decisions = <String, Decision>{}
        ..['sub/IMG_9.jpg'] = Decision.skip();
      await store.saveNewSession(_state(
        images: [_img(9)],
        decisions: decisions,
        currentIndex: 1,
      ));
      final r = await store.loadActive();
      expect(r!.state.images.length, 1);
      expect(r.state.images.first.relativePath, 'sub/IMG_9.jpg');
      expect(r.state.decisions!.length, 1);
      expect(r.state.currentIndex, 1);
      await db.close();
    });

    test('空 images 的会话 loadActive 返回 null(无恢复价值)', () async {
      final db = await _memDb();
      final store = SessionStore(Future.value(db));
      await store.saveNewSession(_state(images: const []));
      expect(await store.loadActive(), isNull);
      await db.close();
    });

    test('降级红线:null db 全部不抛、hasActive false', () async {
      final store = SessionStore(Future.value(null));
      await store.saveNewSession(_state()); // 不抛
      await store.upsertDecision('x', Decision.skip(), 0); // 不抛
      await store.deleteDecision('x'); // 不抛
      await store.updateCurrentIndex(1); // 不抛
      expect(await store.hasActive(), false);
      expect(await store.loadActive(), isNull);
      await store.clear(); // 不抛
    });
  });
}
