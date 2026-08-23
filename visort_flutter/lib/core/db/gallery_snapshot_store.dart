// 相册桶快照 store(P1)—— bucket_snapshot / bucket_photo 两表的读写
//
// 替代旧方案(整桶 JSON 塞 SharedPreferences 单字符串 visort_snap_*):
//   - 大相册不再全量字符串化 + 整体 JSON 解析,行级存取;
//   - 语义完全不变:仍是「首屏秒出」缓存,MediaStore + ContentObserver
//     照旧刷新覆盖,快照永远可丢(降级 = 回退无缓存)。
//
// 降级红线:构造收 Future<Database?>——null(初始化失败)时全部 noop,
// 异常全部吞掉。快照丢失不影响正确性,只影响下次进入的秒开。
//
// 测试:databaseFactoryFfi + 内存库直测(见 gallery_snapshot_store_test.dart)。

import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:visort_flutter/core/config/models.dart' show SortBy;
import 'package:visort_flutter/core/fs/mediastore_channel.dart' show MsImageInfo;

/// 桶快照的数据库形态(store 与 controller 之间的传输对象;
/// controller 侧仍用其私有 _BucketSnapshot,经此互转保持封装)。
class BucketSnapshotData {
  const BucketSnapshotData({
    required this.photos,
    required this.nextCursor,
    required this.sortBy,
    required this.asc,
  });

  final List<MsImageInfo> photos;
  final String? nextCursor;
  final SortBy sortBy;
  final bool asc;
}

class GallerySnapshotStore {
  GallerySnapshotStore(this._db);

  /// 数据库句柄(经 DatabaseService.database 幂等 getter);null = 降级 noop。
  final Future<sqflite.Database?> _db;

  /// 整桶覆写(事务:删旧 → 写 snapshot 头行 + photo 行)。
  /// 万级行用 batch 插入;失败静默(缓存语义)。
  Future<void> save(String bucketId, BucketSnapshotData snap) async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.transaction((txn) async {
        await txn.delete('bucket_snapshot',
            where: 'bucket_id = ?', whereArgs: [bucketId]);
        await txn.delete('bucket_photo',
            where: 'bucket_id = ?', whereArgs: [bucketId]);
        await txn.insert('bucket_snapshot', {
          'bucket_id': bucketId,
          'sort_by': snap.sortBy.name,
          'asc': snap.asc ? 1 : 0,
          'next_cursor': snap.nextCursor,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
        final batch = txn.batch();
        for (var i = 0; i < snap.photos.length; i++) {
          batch.insert('bucket_photo', _photoRow(bucketId, i, snap.photos[i]));
        }
        await batch.commit(noResult: true);
      });
    } catch (_) {
      // 写失败不影响功能(仅退化为下次无磁盘缓存)。
    }
  }

  /// 读快照;无快照 / 解析失败 / DB 不可用返回 null。
  /// photo 按 seq 升序恢复列表顺序;未知 sort_by 回退 dateCreated
  /// (与旧 JSON 方案 orElse 语义一致)。
  Future<BucketSnapshotData?> load(String bucketId) async {
    try {
      final db = await _db;
      if (db == null) return null;
      final head = await db.query('bucket_snapshot',
          where: 'bucket_id = ?', whereArgs: [bucketId], limit: 1);
      if (head.isEmpty) return null;
      final rows = await db.query('bucket_photo',
          where: 'bucket_id = ?',
          whereArgs: [bucketId],
          orderBy: 'seq ASC');
      return BucketSnapshotData(
        photos: [for (final r in rows) _photoFromRow(r)],
        nextCursor: head.first['next_cursor'] as String?,
        sortBy: SortBy.values.firstWhere(
          (s) => s.name == head.first['sort_by'],
          orElse: () => SortBy.dateCreated,
        ),
        asc: (head.first['asc'] as int? ?? 0) == 1,
      );
    } catch (_) {
      return null;
    }
  }

  /// 删快照(两表行)。目前无调用方(快照缓存语义,过期直接覆写),
  /// 留给后续按 updated_at 淘汰的策略用。
  Future<void> clear(String bucketId) async {
    try {
      final db = await _db;
      if (db == null) return;
      await db.delete('bucket_snapshot',
          where: 'bucket_id = ?', whereArgs: [bucketId]);
      await db.delete('bucket_photo',
          where: 'bucket_id = ?', whereArgs: [bucketId]);
    } catch (_) {
      // 同 save:缓存语义,失败静默。
    }
  }

  static Map<String, Object?> _photoRow(
      String bucketId, int seq, MsImageInfo p) {
    return {
      'bucket_id': bucketId,
      'id': p.id,
      'seq': seq,
      'name': p.name,
      'size': p.size,
      'mime': p.mime,
      'date_added_ms': p.dateAddedMs,
      'date_modified_ms': p.dateModifiedMs,
      'is_favorite': p.isFavorite ? 1 : 0,
      'is_trashed': p.isTrashed ? 1 : 0,
      'date_trashed_ms': p.dateTrashedMs,
      'width': p.width,
      'height': p.height,
      'is_hdr': p.isHdr ? 1 : 0,
    };
  }

  static MsImageInfo _photoFromRow(Map<String, Object?> r) {
    return MsImageInfo(
      id: r['id'] as String,
      name: r['name'] as String? ?? '',
      size: r['size'] as int? ?? 0,
      mime: r['mime'] as String? ?? '',
      bucketId: r['bucket_id'] as String? ?? '',
      dateAddedMs: r['date_added_ms'] as int? ?? 0,
      dateModifiedMs: r['date_modified_ms'] as int? ?? 0,
      isFavorite: (r['is_favorite'] as int? ?? 0) == 1,
      isTrashed: (r['is_trashed'] as int? ?? 0) == 1,
      dateTrashedMs: r['date_trashed_ms'] as int? ?? 0,
      width: r['width'] as int? ?? 0,
      height: r['height'] as int? ?? 0,
      isHdr: (r['is_hdr'] as int? ?? 0) == 1,
    );
  }
}
