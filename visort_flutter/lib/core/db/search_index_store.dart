// 搜索索引 store —— search_index 表读写
//
// 「智能识别索引」(设置页分区)的落盘层,搜索页日期/地点/相机维度的
// 唯一数据源(MediaStore 无 DATE_TAKEN/GPS 列,EXIF 只能读文件):
//   - putAll:索引批次完成批量 upsert(地名已由服务层 geocode 填充);
//   - loadAll:冷启动恢复全量 Map(id → MsSearchMeta);
//   - count/clear:设置页数据行展示与关开关清库。
// 降级红线:同其他 store,DB 不可用时全部 noop(搜索页退化回纯本地
// 分组——文件类型/相册维度不依赖索引,仍可用)。
//
// 数据量:每行 ~50B(id+时间+坐标+相机+地名),十万张 ≈ 10MB,无需淘汰;
// 照片本体增删以 MediaStore 为准,本表残留行按 id 查不到即自然失效。

import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

class SearchIndexStore {
  SearchIndexStore(this._db);

  /// 数据库句柄(经 DatabaseService.database 幂等 getter);null = 降级 noop。
  final Future<sqflite.Database?> _db;

  /// 批量写回(INSERT OR REPLACE,upsert 覆盖)。
  /// [mtimes] = 提取时各图的 DATE_MODIFIED(ms)——增量对账用它检测
  /// 「照片被外部编辑后需重提取」;null 行(升级前的旧数据)视为未知,
  /// 由 service 首见时回填。
  Future<void> putAll(
    List<MsSearchMeta> metas, {
    Map<String, int>? mtimes,
  }) async {
    if (metas.isEmpty) return;
    try {
      final db = await _db;
      if (db == null) return;
      final batch = db.batch();
      for (final m in metas) {
        batch.insert(
          'search_index',
          {
            'id': m.id,
            'date_taken_ms': m.dateTakenMs,
            'lat': m.lat,
            'lng': m.lng,
            'camera': m.camera,
            'country': m.country,
            'admin_area': m.adminArea,
            'locality': m.locality,
            'date_modified_ms': mtimes?[m.id],
          },
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (_) {
      // 写失败 = 该批索引丢失,下次开启索引重建,无损。
    }
  }

  /// 读回全部提取时间戳(id → DATE_MODIFIED)。只含已回填/新写入的行
  /// (旧升级行无值,不在结果里——service 首见回填)。
  Future<Map<String, int>> loadMtimes() async {
    try {
      final db = await _db;
      if (db == null) return const {};
      final rows = await db.query(
        'search_index',
        columns: ['id', 'date_modified_ms'],
        where: 'date_modified_ms IS NOT NULL',
      );
      return {
        for (final r in rows) r['id'] as String: r['date_modified_ms'] as int,
      };
    } catch (_) {
      return const {};
    }
  }

  /// 批量回填提取时间戳(不动其他列)。升级后首次对账对存量行补记
  /// 当前 mtime——接受升级前的历史现状,从今往后变更可检测。
  Future<void> updateMtimes(Map<String, int> mtimes) async {
    if (mtimes.isEmpty) return;
    try {
      final db = await _db;
      if (db == null) return;
      final batch = db.batch();
      for (final e in mtimes.entries) {
        batch.update(
          'search_index',
          {'date_modified_ms': e.value},
          where: 'id = ?',
          whereArgs: [e.key],
        );
      }
      await batch.commit(noResult: true);
    } catch (_) {}
  }

  /// 全量读回(id → 元数据)。DB 不可用/空表返回空 Map(调用方按
  /// 「未索引」处理,搜索页降级)。
  Future<Map<String, MsSearchMeta>> loadAll() async {
    try {
      final db = await _db;
      if (db == null) return const {};
      final rows = await db.query('search_index');
      final out = <String, MsSearchMeta>{};
      for (final r in rows) {
        final meta = MsSearchMeta(
          id: r['id'] as String,
          dateTakenMs: r['date_taken_ms'] as int?,
          lat: r['lat'] as double?,
          lng: r['lng'] as double?,
          camera: r['camera'] as String?,
          country: r['country'] as String?,
          adminArea: r['admin_area'] as String?,
          locality: r['locality'] as String?,
        );
        out[meta.id] = meta;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// 清空(关闭智能识别索引时,同旧 SP 位置数据清库语义)。
  Future<void> clear() async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.delete('search_index');
    } catch (_) {
      // 清失败 = 残留旧索引,数据无敏感内容,可接受。
    }
  }

  /// 按 id 批量删除(照片被用户删除后的索引级联清理——坐标/地名是超出
  /// 「删照片即删数据」预期的位置数据留存,安全审查建议;分块 500 防
  /// SQLite 999 变量上限)。失败静默:残留行按 id 查不到自然失效。
  Future<void> deleteByIds(Set<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final db = await _db;
      if (db == null) return;
      final list = ids.toList();
      for (var i = 0; i < list.length; i += 500) {
        final chunk = list.skip(i).take(500).toList();
        await db.delete(
          'search_index',
          where:
              'id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk,
        );
      }
    } catch (_) {}
  }
}
