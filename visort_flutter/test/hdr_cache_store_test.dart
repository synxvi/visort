// HdrCacheStore 单测 —— ffi 内存库直测(schema 复用 DatabaseService.createAll)

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/hdr_cache_store.dart';

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

  group('HdrCacheStore', () {
    test('putAll → lookup 往返:mtime 匹配命中,miss 不在结果', () async {
      final db = await _memDb();
      final store = HdrCacheStore(Future.value(db));
      await store.putAll({
        '1': (1000, true),
        '2': (2000, false),
      });
      final hits = await store.lookup({'1': 1000, '2': 2000, '3': 3000});
      expect(hits['1'], true);
      expect(hits['2'], false);
      expect(hits.containsKey('3'), false); // miss 不出现
      expect(hits.length, 2);
      await db.close();
    });

    test('mtime 不匹配 = miss(图被编辑须重测)', () async {
      final db = await _memDb();
      final store = HdrCacheStore(Future.value(db));
      await store.putAll({'1': (1000, true)});
      final stale = await store.lookup({'1': 999});
      expect(stale.isEmpty, true);
      await db.close();
    });

    test('putAll upsert:同 id 新 mtime 覆盖旧行', () async {
      final db = await _memDb();
      final store = HdrCacheStore(Future.value(db));
      await store.putAll({'1': (1000, true)});
      await store.putAll({'1': (2000, false)}); // 编辑后重测为 false
      final hits = await store.lookup({'1': 2000});
      expect(hits['1'], false);
      expect((await store.lookup({'1': 1000})).isEmpty, true); // 旧 mtime 不认
      await db.close();
    });

    test('超 500 个 id 分块 IN 查询不炸(999 变量上限)', () async {
      final db = await _memDb();
      final store = HdrCacheStore(Future.value(db));
      final entries = {
        for (var i = 0; i < 1200; i++) '$i': (i * 10, i % 2 == 0),
      };
      await store.putAll(entries);
      final hits = await store.lookup(entries.map((k, v) => MapEntry(k, v.$1)));
      expect(hits.length, 1200);
      expect(hits['0'], true);
      expect(hits['1'], false);
      await db.close();
    });

    test('空入参直接返回;null db 全部不抛', () async {
      final store = HdrCacheStore(Future.value(null));
      expect(await store.lookup(const {}), isEmpty);
      await store.putAll(const {}); // 不抛
      expect(await store.lookup({'x': 1}), isEmpty); // null db 降级
      await store.putAll({'x': (1, true)}); // 不抛
    });
  });
}
