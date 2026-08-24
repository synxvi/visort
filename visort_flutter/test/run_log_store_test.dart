// RunLogStore 单测 —— ffi 内存库直测(schema 复用 DatabaseService.createAll)

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/run_log_store.dart';

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

  group('RunLogStore', () {
    test('insert → recent 往返保真(计数/errors/session_id)', () async {
      final db = await _memDb();
      final store = RunLogStore(Future.value(db));
      await store.insert(
        moved: 3,
        deleted: 2,
        skipped: 1,
        errors: const [
          (file: 'sub/x.jpg', reason: 'move_failed'),
          (file: 'sub/y.jpg', reason: 'source_missing'),
        ],
      );

      final rows = await store.recent();
      expect(rows.length, 1);
      final e = rows.first;
      expect(e.moved, 3);
      expect(e.deleted, 2);
      expect(e.skipped, 1);
      expect(e.sessionId, 1); // 单活跃会话恒 1
      expect(e.finishedAt, greaterThan(0));
      expect(e.errors.length, 2);
      expect(e.errors[0].file, 'sub/x.jpg');
      expect(e.errors[0].reason, 'move_failed');
      expect(e.errors[1].reason, 'source_missing');
      await db.close();
    });

    test('recent 新→旧排序 + limit 截断', () async {
      final db = await _memDb();
      final store = RunLogStore(Future.value(db));
      for (var i = 0; i < 5; i++) {
        await store.insert(moved: i, deleted: 0, skipped: 0);
      }
      final rows = await store.recent(limit: 3);
      expect(rows.length, 3);
      // id 自增 → 最新在前
      expect(rows.map((e) => e.moved).toList(), [4, 3, 2]);
      await db.close();
    });

    test('空 errors 往返为空列表(不抛、不产生脏数据)', () async {
      final db = await _memDb();
      final store = RunLogStore(Future.value(db));
      await store.insert(moved: 1, deleted: 0, skipped: 0);
      expect((await store.recent()).single.errors, isEmpty);
      await db.close();
    });

    test('clear 清空历史', () async {
      final db = await _memDb();
      final store = RunLogStore(Future.value(db));
      await store.insert(moved: 1, deleted: 0, skipped: 0);
      await store.clear();
      expect(await store.recent(), isEmpty);
      await db.close();
    });

    test('降级红线:null db 全部不抛、recent 为空', () async {
      final store = RunLogStore(Future.value(null));
      await store.insert(moved: 1, deleted: 1, skipped: 1); // 不抛
      await store.clear(); // 不抛
      expect(await store.recent(), isEmpty);
    });
  });
}
