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
  Future<void> putAll(List<MsSearchMeta> metas) async {
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
          },
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (_) {
      // 写失败 = 该批索引丢失,下次开启索引重建,无损。
    }
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
}
