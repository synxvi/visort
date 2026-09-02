// SearchIndexStore 单测 —— ffi 内存库直测(schema 复用 createAll)。
// 覆盖 mtime 持久化三件套(putAll 带 mtimes / loadMtimes / updateMtimes)
// 与按 id 级联删除(含 >500 分块路径)——2026-09 审查 P1-3/安全加固的
// 回归锁定。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/search_index_store.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart'
    show MsSearchMeta;

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

  group('SearchIndexStore', () {
    test('putAll(带 mtimes) → loadAll/loadMtimes 往返', () async {
      final db = await _memDb();
      final store = SearchIndexStore(Future.value(db));
      await store.putAll(
        [
          const MsSearchMeta(id: '1', dateTakenMs: 100, lat: 1.5, lng: 2.5),
          const MsSearchMeta(id: '2', camera: 'X A5'),
          const MsSearchMeta(id: '3'), // 无 EXIF tombstone(P1-4)
        ],
        mtimes: {'1': 111, '2': 222}, // 3 不带 → mtime null
      );
      final metas = await store.loadAll();
      expect(metas.length, 3);
      expect(metas['1']!.lat, 1.5);
      expect(metas['3']!.camera, isNull); // 空行字段全 null
      final mtimes = await store.loadMtimes();
      expect(mtimes, {'1': 111, '2': 222}); // null 行不在结果
      await db.close();
    });

    test('updateMtimes 回填不动其他列', () async {
      final db = await _memDb();
      final store = SearchIndexStore(Future.value(db));
      await store.putAll(
        [const MsSearchMeta(id: '1', dateTakenMs: 100)],
        mtimes: {'1': 111},
      );
      await store.updateMtimes({'1': 999, '2': 888}); // 2 无行 → no-op
      final mtimes = await store.loadMtimes();
      expect(mtimes['1'], 999);
      expect(mtimes.containsKey('2'), false);
      final metas = await store.loadAll();
      expect(metas['1']!.dateTakenMs, 100); // 其他列未被动
      await db.close();
    });

    test('deleteByIds 分块删除(>500 走两块)与 clear', () async {
      final db = await _memDb();
      final store = SearchIndexStore(Future.value(db));
      final metas = [
        for (var i = 0; i < 1200; i++) MsSearchMeta(id: '$i'),
      ];
      await store.putAll(metas, mtimes: {
        for (var i = 0; i < 1200; i++) '$i': 1000 + i,
      });
      var all = await store.loadAll();
      expect(all.length, 1200);
      // 删 600 个(跨 500 分块边界)。
      await store.deleteByIds({
        for (var i = 0; i < 600; i++) '$i',
      });
      all = await store.loadAll();
      expect(all.length, 600);
      expect(all.containsKey('599'), false);
      expect(all.containsKey('600'), true);
      await store.clear();
      all = await store.loadAll();
      expect(all.isEmpty, true);
      await db.close();
    });
  });
}
