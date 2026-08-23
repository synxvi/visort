// HDR 检测缓存 store —— hdr_cache 表读写
//
// Kotlin MediaStoreRepository.hdrCache(进程内 HashMap)的落盘层:
//   - 语义一致:id + dateModifiedMs 匹配才复用(mtime 变了 = 图被编辑,须重测);
//   - 收益:冷启动二次进桶零文件 IO(Kotlin 缓存随进程死),且跨桶/跨视图
//     (favorites/trash)共享同一张图的检测结果;
//   - 降级红线:同其他 store,DB 不可用时全部 noop(退化为纯 Kotlin
//     进程内缓存,行为回到现状)。
//
// 数据量:每行 ~(10B id + 8B mtime + 1B bool),十万张图 ≈ 数 MB,无需淘汰。

import 'package:sqflite/sqflite.dart' as sqflite;

class HdrCacheStore {
  HdrCacheStore(this._db);

  /// 数据库句柄(经 DatabaseService.database 幂等 getter);null = 降级 noop。
  final Future<sqflite.Database?> _db;

  /// 批量查命中:id+mtime 都匹配才返回。返回 `Map<id, isHdr>`(只含命中项)。
  ///
  /// 一次 IN 查询取回 id → (mtime, is_hdr),再在 Dart 侧比对 mtime——
  /// 避免拼 (id, mtime) 复合 IN 的 SQL 复杂度(几百上千对值时两步更快)。
  Future<Map<String, bool>> lookup(
      Map<String, int> idToMtime) async {
    if (idToMtime.isEmpty) return const {};
    try {
      final db = await _db;
      if (db == null) return const {};
      final ids = idToMtime.keys.toList(growable: false);
      // SQLite 变量上限 999:分块 IN 查询(每块 500)。
      final hits = <String, bool>{};
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.skip(i).take(500).toList(growable: false);
        final rows = await db.query(
          'hdr_cache',
          columns: const ['id', 'date_modified_ms', 'is_hdr'],
          where: 'id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk,
        );
        for (final r in rows) {
          final id = r['id'] as String;
          if (r['date_modified_ms'] == idToMtime[id]) {
            hits[id] = (r['is_hdr'] as int) == 1;
          }
        }
      }
      return hits;
    } catch (_) {
      return const {};
    }
  }

  /// 批量写回(INSERT OR REPLACE,upsert 覆盖旧 mtime/结果)。
  Future<void> putAll(Map<String, (int, bool)> entries) async {
    if (entries.isEmpty) return;
    try {
      final db = await _db;
      if (db == null) return;
      final batch = db.batch();
      entries.forEach((id, e) {
        batch.insert(
          'hdr_cache',
          {
            'id': id,
            'date_modified_ms': e.$1,
            'is_hdr': e.$2 ? 1 : 0,
          },
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
        );
      });
      await batch.commit(noResult: true);
    } catch (_) {
      // 写失败 = 下次重测,无损。
    }
  }
}
