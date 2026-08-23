// GallerySnapshotStore 单测(P1)—— ffi 内存库直测
//
// schema 从 DatabaseService.createAll 复用(与生产 openDatabase 同一方法,
// 保证测试与真实库不漂移)。覆盖:往返保真 / 覆写 / clear / 空列表 /
// DB 不可用降级(降级红线:null db 全 noop 不抛)。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:visort_flutter/core/config/models.dart' show SortBy;
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/gallery_snapshot_store.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart' show MsImageInfo;

MsImageInfo _photo(int i, {String bucket = 'b1'}) => MsImageInfo(
      id: '$i',
      name: 'IMG_$i.jpg',
      size: 1000 + i,
      mime: 'image/jpeg',
      bucketId: bucket,
      dateAddedMs: 1700000000000 + i,
      dateModifiedMs: 1700000001000 + i,
      isFavorite: i % 2 == 0,
      isTrashed: i % 3 == 0,
      dateTrashedMs: i % 3 == 0 ? 1700000005000 : 0,
      width: 4000 + i,
      height: 3000 + i,
      isHdr: i % 4 == 0,
    );

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

  group('GallerySnapshotStore', () {
    test('save → load 往返保真:字段 / 顺序 / 游标 / 排序', () async {
      final db = await _memDb();
      final store = GallerySnapshotStore(Future.value(db));
      final photos = [for (var i = 0; i < 5; i++) _photo(i)];
      await store.save('b1', BucketSnapshotData(
        photos: photos,
        nextCursor: 'cursor_abc',
        sortBy: SortBy.dateModified,
        asc: true,
      ));

      final loaded = await store.load('b1');
      expect(loaded, isNotNull);
      expect(loaded!.photos.length, 5);
      // 顺序(seq)保真
      expect(loaded.photos.map((p) => p.id).toList(), ['0', '1', '2', '3', '4']);
      // 字段保真(抽样全字段比对)
      final p0 = loaded.photos.first;
      expect(p0.name, 'IMG_0.jpg');
      expect(p0.size, 1000);
      expect(p0.mime, 'image/jpeg');
      expect(p0.bucketId, 'b1');
      expect(p0.dateAddedMs, 1700000000000);
      expect(p0.dateModifiedMs, 1700000001000);
      expect(p0.isFavorite, true); // i=0 偶数
      expect(p0.isTrashed, true); // i=0 被 3 整除
      expect(p0.dateTrashedMs, 1700000005000);
      expect(p0.width, 4000);
      expect(p0.height, 3000);
      expect(p0.isHdr, true); // i=0 被 4 整除
      final p1 = loaded.photos[1];
      expect(p1.isFavorite, false);
      expect(p1.isTrashed, false);
      expect(p1.dateTrashedMs, 0);
      expect(loaded.nextCursor, 'cursor_abc');
      expect(loaded.sortBy, SortBy.dateModified);
      expect(loaded.asc, true);
      await db.close();
    });

    test('无快照返回 null;游标为 null 正常往返', () async {
      final db = await _memDb();
      final store = GallerySnapshotStore(Future.value(db));
      expect(await store.load('nope'), isNull);
      await store.save('b1', BucketSnapshotData(
        photos: [_photo(7)],
        nextCursor: null,
        sortBy: SortBy.dateCreated,
        asc: false,
      ));
      final loaded = await store.load('b1');
      expect(loaded!.nextCursor, isNull);
      expect(loaded.asc, false);
      await db.close();
    });

    test('同桶二次 save 覆写:旧 photo 行不残留', () async {
      final db = await _memDb();
      final store = GallerySnapshotStore(Future.value(db));
      await store.save('b1', BucketSnapshotData(
        photos: [for (var i = 0; i < 3; i++) _photo(i)],
        nextCursor: null,
        sortBy: SortBy.dateCreated,
        asc: false,
      ));
      await store.save('b1', BucketSnapshotData(
        photos: [_photo(9)],
        nextCursor: 'c2',
        sortBy: SortBy.name,
        asc: true,
      ));
      final loaded = await store.load('b1');
      expect(loaded!.photos.map((p) => p.id).toList(), ['9']);
      expect(loaded.sortBy, SortBy.name);
      // 其他桶不受影响(不同 bucket_id 隔离)
      await store.save('b2', BucketSnapshotData(
        photos: [_photo(1, bucket: 'b2')],
        nextCursor: null,
        sortBy: SortBy.dateCreated,
        asc: false,
      ));
      expect((await store.load('b2'))!.photos.length, 1);
      expect((await store.load('b1'))!.photos.length, 1);
      await db.close();
    });

    test('空 photos 列表:head 行存在,load 返回空列表而非 null', () async {
      final db = await _memDb();
      final store = GallerySnapshotStore(Future.value(db));
      await store.save('empty', BucketSnapshotData(
        photos: const [],
        nextCursor: null,
        sortBy: SortBy.dateCreated,
        asc: false,
      ));
      final loaded = await store.load('empty');
      expect(loaded, isNotNull);
      expect(loaded!.photos, isEmpty);
      await db.close();
    });

    test('clear 后 load 返回 null', () async {
      final db = await _memDb();
      final store = GallerySnapshotStore(Future.value(db));
      await store.save('b1', BucketSnapshotData(
        photos: [_photo(0)],
        nextCursor: null,
        sortBy: SortBy.dateCreated,
        asc: false,
      ));
      await store.clear('b1');
      expect(await store.load('b1'), isNull);
      await db.close();
    });

    test('降级红线:db 为 null 时 save/load/clear 全部不抛', () async {
      final store = GallerySnapshotStore(Future.value(null));
      await store.save('b1', BucketSnapshotData(
        photos: [_photo(0)],
        nextCursor: null,
        sortBy: SortBy.dateCreated,
        asc: false,
      )); // 不抛
      expect(await store.load('b1'), isNull);
      await store.clear('b1'); // 不抛
    });
  });
}
