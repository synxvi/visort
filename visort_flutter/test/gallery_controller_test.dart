import 'dart:async';

// GalleryController 测试 —— 通过 fake MediaStoreChannel 注入，验证相册浏览核心逻辑
//
// 重点覆盖重构后的关键行为：
//   - keyset 分页：enterBucket 取第一页 → loadMore 用游标取下一页 → 无更多时停止
//   - 删除：deletePhoto 成功后本地移除 + bucket.count 递减 + 缓存清理
//   - 排序持久化：setPhotoSort / setAlbumSort 更新 AppConfig
//
// 这填补了 AGENTS.md 所述「features/gallery 测试盲区」，并锁定 keyset 分页契约
// （游标法、删除不偏移）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/fs/mediastore_events.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';

/// 假 MediaStoreChannel：不走 platform，按预设数据响应。
///
/// 构造时注入「相册列表」+「每个相册的全量图片列表」，scanImages 按当前
/// 排序对全量切片，用游标（index）模拟 keyset 分页——验证 controller 的
/// loadMore 会逐页推进直到耗尽。
class _FakeMediaStoreChannel extends MediaStoreChannel {
  _FakeMediaStoreChannel(this._buckets, this._photosByBucket)
      : super();

  final List<MsBucket> _buckets;
  final Map<String, List<MsImageInfo>> _photosByBucket;
  final Set<String> _deletedIds = {};
  final Set<String> _trashedIds = {};
  final Set<String> _favoriteIds = {};
  /// 模拟系统级 untrash 静默失败：这些 id 即使恢复弹窗确认后仍保持
  /// trashed（对默认查询不可见 → exists false）。
  final Set<String> restoreStuckIds = {};
  /// 模拟 ROM 误报：这些 id 即使 requestDelete 成功 exists 仍返回 true。
  final Set<String> stickyIds = {};
  /// 模拟权限未授予：listBuckets 抛 PERMISSION_DENIED（对齐原生
  /// handleListBuckets 的前置检查）。
  bool denyPermission = false;
  final List<String> scanCalls = []; // 记录每次 scanImages 的 afterCursor

  /// 模拟 MediaStore 查询语义：普通查询排除已删除/已回收站项；
  /// [trashedOnly] 时只返回回收站项。
  /// stickyIds（删除未生效的图）不视为已删除。
  Set<String> get _goneIds => _deletedIds.difference(stickyIds);

  List<MsImageInfo> _visible(String bucketId, {bool trashedOnly = false}) {
    final all = _photosByBucket[bucketId] ?? const <MsImageInfo>[];
    return all
        .where((p) => trashedOnly
            ? _trashedIds.contains(p.id)
            : !_goneIds.contains(p.id) && !_trashedIds.contains(p.id))
        .toList();
  }

  @override
  Future<List<MsBucket>> listBuckets({
    SortBy sortBy = SortBy.dateCreated,
    bool asc = false,
  }) async {
    if (denyPermission) {
      throw const MsException(
          MsErrorCode.permissionDenied, 'READ_MEDIA_IMAGES 权限未授予');
    }
    // 对齐 Kotlin listBuckets：count 实时派生，cover = 该排序下每桶首张。
    return _buckets.map((b) {
      final photos = _visible(b.id);
      final cover = photos.isEmpty
          ? null
          : _sortedForCover(photos, sortBy, asc).first.id;
      return MsBucket(
        id: b.id,
        name: b.name,
        count: photos.length,
        dateCreatedMs: b.dateCreatedMs,
        dateModifiedMs: b.dateModifiedMs,
        coverId: cover,
      );
    }).toList();
  }

  List<MsImageInfo> _sortedForCover(
      List<MsImageInfo> photos, SortBy sortBy, bool asc) {
    final list = List<MsImageInfo>.of(photos);
    int cmp(MsImageInfo a, MsImageInfo b) {
      switch (sortBy) {
        case SortBy.name:
          return a.name.compareTo(b.name);
        case SortBy.dateModified:
          return a.dateModifiedMs.compareTo(b.dateModifiedMs);
        case SortBy.dateCreated:
        case SortBy.dateTrashed:
        case SortBy.dateFavorited:
          return a.dateAddedMs.compareTo(b.dateAddedMs);
      }
    }

    list.sort((a, b) => asc ? cmp(a, b) : cmp(b, a));
    return list;
  }

  @override
  Future<MsScanPage> scanImages(
    List<String> bucketIds, {
    String? afterCursor,
    int limit = 60,
    SortBy sortBy = SortBy.dateCreated,
    bool asc = false,
    bool favoritesOnly = false,
    bool trashedOnly = false,
  }) async {
    scanCalls.add(afterCursor ?? '<first>');
    // 取首个 bucket 的图（测试只用单相册）
    final all = (bucketIds.isEmpty
            ? _photosByBucket.values.expand((e) => e)
            : _photosByBucket[bucketIds.first] ?? const <MsImageInfo>[])
        .where((p) => trashedOnly
            ? _trashedIds.contains(p.id)
            : !_goneIds.contains(p.id) && !_trashedIds.contains(p.id))
        .toList();
    // keyset：afterCursor 编码起始 index（测试简化为纯数字游标）
    final start = int.tryParse(afterCursor ?? '') ?? 0;
    final end = (start + limit < all.length) ? start + limit : all.length;
    final slice = all.sublist(start, end);
    final next = end < all.length ? end.toString() : null;
    return MsScanPage(images: slice, nextCursor: next);
  }

  @override
  Future<int> requestDelete(List<String> ids) async {
    _deletedIds.addAll(ids);
    return ids.length;
  }

  @override
  Future<bool> requestTrash(List<String> ids) async {
    _trashedIds.addAll(ids);
    return true;
  }

  @override
  Future<bool> requestRestore(List<String> ids) async {
    for (final id in ids) {
      if (restoreStuckIds.contains(id)) continue; // 系统 untrash 未生效
      _trashedIds.remove(id);
    }
    return true;
  }

  @override
  Future<bool> requestFavorite(List<String> ids, bool favorite) async {
    if (favorite) {
      _favoriteIds.addAll(ids);
    } else {
      ids.forEach(_favoriteIds.remove);
    }
    return true;
  }

  @override
  Future<bool> exists(String id) async =>
      // 对齐真机语义：trashed 行对默认查询不可见（restorePhotos 复查依赖）
      !_trashedIds.contains(id) &&
      (stickyIds.contains(id) || !_deletedIds.contains(id));

  @override
  Future<MsExistsStatus> existsStatus(String id) async =>
      await exists(id) ? MsExistsStatus.found : MsExistsStatus.notFound;
}

MsImageInfo _info(String id, {String bucket = 'b1', int added = 0}) =>
    MsImageInfo(
      id: id,
      name: '$id.jpg',
      size: 1024,
      mime: 'image/jpeg',
      bucketId: bucket,
      dateAddedMs: added,
      dateModifiedMs: added,
    );

MsBucket _bucket(String id, String name, int count) => MsBucket(
      id: id,
      name: name,
      count: count,
      dateCreatedMs: 1000,
      dateModifiedMs: 2000,
      coverId: null,
    );

void main() {
  // deletePhoto → evictImageCache 访问 PaintingBinding.instance，需先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeMediaStoreChannel fakeChannel;
  late ProviderContainer container;
  late GalleryController controller;

  setUp(() {
    fakeChannel = _FakeMediaStoreChannel(
      [_bucket('b1', 'Camera', 5)],
      {
        'b1': [
          _info('1', added: 100),
          _info('2', added: 90),
          _info('3', added: 80),
          _info('4', added: 70),
          _info('5', added: 60),
        ],
      },
    );
    container = ProviderContainer(overrides: [
      mediaStoreChannelProvider.overrideWithValue(fakeChannel),
      mediaStoreChangeStreamProvider.overrideWith((ref) => const Stream<MsChangeEvent>.empty()),
    ]);
    controller = container.read(galleryControllerProvider.notifier);
    addTearDown(container.dispose);
  });

  group('keyset 分页', () {
    test('enterBucket 取第一页，loadMore 用游标逐页推进至耗尽', () async {
      // 第一页 limit=60，5 张全部返回，无下一页游标
      await controller.enterBucket('b1');
      final state = container.read(galleryControllerProvider);
      expect(state.photos.length, 5);
      expect(state.hasMore, false, reason: '不足一页应无更多');
      // 首屏完成标记：UI 据此切换「灰格占位 → 真实网格」
      expect(state.firstPageLoaded, true);
      expect(fakeChannel.scanCalls.length, 1);
    });

    test('大相册全量加载：enterBucket 一次查完，hasMore 始终 false', () async {
      // 全量加载策略（_pageSize 足够大）：一次查询返回所有图片，不分页。
      // 手柄 itemCount 固定 → maxScrollExtent 稳定 → 滚动不跳（对齐系统相册）。
      final big = List.generate(130, (i) => _info('p$i', added: 1000 - i));
      final fake = _FakeMediaStoreChannel(
        [_bucket('b2', 'Big', 130)],
        {'b2': big},
      );
      final c = ProviderContainer(overrides: [
        mediaStoreChannelProvider.overrideWithValue(fake),
        mediaStoreChangeStreamProvider.overrideWith((ref) => const Stream<MsChangeEvent>.empty()),
      ]);
      addTearDown(c.dispose);
      final ctrl = c.read(galleryControllerProvider.notifier);

      await ctrl.enterBucket('b2');
      final st = c.read(galleryControllerProvider);
      expect(st.photos.length, 130); // 全量一次查完
      expect(st.hasMore, false);
      expect(st.firstPageLoaded, true);

      // loadMore 在全量后是 no-op（nextCursor=null）
      final callsBefore = fake.scanCalls.length;
      await ctrl.loadMore();
      expect(c.read(galleryControllerProvider).photos.length, 130);
      expect(fake.scanCalls.length, callsBefore);
    });

    test('loadMore 在无更多时是 no-op', () async {
      await controller.enterBucket('b1');
      final callsBefore = fakeChannel.scanCalls.length;
      await controller.loadMore(); // hasMore=false，应直接返回
      await controller.loadMore();
      expect(fakeChannel.scanCalls.length, callsBefore);
    });

    test('exitBucket 后同桶重进：快照秒出 + 后台静默刷新', () async {
      await controller.enterBucket('b1');
      expect(container.read(galleryControllerProvider).photos.length, 5);

      controller.exitBucket();
      // 退出后清空当前网格，但桶快照已入内存
      expect(container.read(galleryControllerProvider).photos.length, 0);

      final callsBefore = fakeChannel.scanCalls.length;
      await controller.enterBucket('b1');
      // 快照直出：进入瞬间即有旧网格数据（无需等 query）
      expect(container.read(galleryControllerProvider).photos.length, 5);
      expect(container.read(galleryControllerProvider).firstPageLoaded, true);
      // 后台静默刷新一次（与首次 enterBucket 各一次 scan）
      expect(fakeChannel.scanCalls.length, callsBefore + 1);
      expect(container.read(galleryControllerProvider).photos.length, 5);
    });

    test('切桶后旧桶后台刷新结果被丢弃（token 竞态防护）', () async {
      await controller.enterBucket('b1');
      controller.exitBucket();
      // b1 快照直出（不 await 其后台刷新）→ 立刻切 b2
      final pending = controller.enterBucket('b1');
      await controller.enterBucket('b2'); // b2 在 fake 中不存在 → 空页
      expect(container.read(galleryControllerProvider).bucketId, 'b2');
      expect(container.read(galleryControllerProvider).photos.isEmpty, true);
      await pending; // 收尾：等 b1 刷新结束
      expect(container.read(galleryControllerProvider).bucketId, 'b2',
          reason: 'b1 后台刷新（旧 token）不得覆盖 b2');
      expect(container.read(galleryControllerProvider).photos.isEmpty, true);
    });
  });

  group('删除', () {
    test('deletePhoto 本地移除并递减 bucket count', () async {
      await controller.loadBuckets(); // 先载入 buckets，删图才能同步更新 count
      await controller.enterBucket('b1');
      expect(container.read(galleryControllerProvider).photos.length, 5);

      final err = await controller.deletePhoto('3');
      expect(err, isNull);

      final st = container.read(galleryControllerProvider);
      expect(st.photos.length, 4);
      expect(st.photos.any((p) => p.id == '3'), false);
      expect(st.buckets.first.count, 4, reason: 'bucket.count 应递减');
    });

    test('deletePhoto 删封面后首页封面推进到下一张', () async {
      // 重建带封面的相册（dateAdded 决定封面排序）
      final fake = _FakeMediaStoreChannel(
        [MsBucket(id: 'b3', name: 'X', count: 2, dateCreatedMs: 1, dateModifiedMs: 2, coverId: 'c1')],
        {'b3': [_info('c1', added: 100), _info('c2', added: 90)]},
      );
      final c = ProviderContainer(overrides: [
        mediaStoreChannelProvider.overrideWithValue(fake),
        mediaStoreChangeStreamProvider.overrideWith((ref) => const Stream<MsChangeEvent>.empty()),
      ]);
      addTearDown(c.dispose);
      final ctrl = c.read(galleryControllerProvider.notifier);
      await ctrl.loadBuckets();
      await ctrl.enterBucket('b3');

      await ctrl.deletePhoto('c1');
      final st = c.read(galleryControllerProvider);
      expect(st.buckets.first.coverId, 'c2', reason: '删封面后封面应推进到下一张');
    });

    test('trashPhoto 移入回收站后首页 count 递减', () async {
      await controller.loadBuckets();
      await controller.enterBucket('b1');

      final err = await controller.trashPhoto('3');
      expect(err, isNull);

      final st = container.read(galleryControllerProvider);
      expect(st.photos.any((p) => p.id == '3'), false);
      expect(st.buckets.first.count, 4, reason: '回收站项应从普通查询排除，首页 count 递减');
    });

    test('restorePhoto 恢复后首页 count 回升', () async {
      await controller.loadBuckets();
      await controller.enterBucket('b1');
      await controller.trashPhoto('3');
      expect(container.read(galleryControllerProvider).buckets.first.count, 4);

      final err = await controller.restorePhoto('3');
      expect(err, isNull);

      final st = container.read(galleryControllerProvider);
      expect(st.buckets.first.count, 5, reason: '恢复后回收站排除失效，count 回升');
    });
  });

  group('批量操作', () {
    test('trashPhotos 批量移入回收站：本地移除 + count 批量递减', () async {
      await controller.loadBuckets();
      await controller.enterBucket('b1');

      final err = await controller.trashPhotos(['3', '4']);
      expect(err, isNull);

      final st = container.read(galleryControllerProvider);
      expect(st.photos.map((p) => p.id), ['1', '2', '5'],
          reason: '批量回收后两张同时移除');
      expect(st.buckets.first.count, 3, reason: 'count 应一次性减 2');
    });

    test('restorePhotos 批量恢复：count 回升', () async {
      await controller.loadBuckets();
      await controller.enterBucket('b1');
      await controller.trashPhotos(['3', '4']);
      expect(container.read(galleryControllerProvider).buckets.first.count, 3);

      final err = await controller.restorePhotos(['3', '4']);
      expect(err, isNull);

      expect(container.read(galleryControllerProvider).buckets.first.count, 5,
          reason: '批量恢复后回收站排除失效，count 回升');
    });

    test('deletePhotos 批量彻底删除：确认消失的移除 + count 递减', () async {
      await controller.loadBuckets();
      await controller.enterBucket('b1');

      final err = await controller.deletePhotos(['3', '4']);
      expect(err, isNull);

      final st = container.read(galleryControllerProvider);
      expect(st.photos.map((p) => p.id), ['1', '2', '5']);
      expect(st.buckets.first.count, 3);
    });

    test('deletePhotos 部分残留（ROM 误报）：移除消失的，残留保留并返回失败', () async {
      await controller.loadBuckets();
      await controller.enterBucket('b1');
      fakeChannel.stickyIds.add('4'); // 模拟 '4' 删除未生效

      final err = await controller.deletePhotos(['3', '4']);
      expect(err, 'delete_failed', reason: '有残留时应报告失败');

      final st = container.read(galleryControllerProvider);
      expect(st.photos.map((p) => p.id), ['1', '2', '4', '5'],
          reason: '已确认消失的移除，残留的保留');
      expect(st.buckets.first.count, 4);
    });

    test('setFavorites 批量设置收藏状态（乐观更新）', () async {
      await controller.enterBucket('b1');

      final err = await controller.setFavorites(['3', '4'], true);
      expect(err, isNull);

      var st = container.read(galleryControllerProvider);
      expect(
          st.photos.where((p) => p.id == '3' || p.id == '4')
              .every((p) => p.isFavorite),
          true);

      await controller.setFavorites(['3', '4'], false);
      st = container.read(galleryControllerProvider);
      expect(st.photos.every((p) => !p.isFavorite), true);
    });
  });

  group('排序持久化', () {
    test('setAlbumSort 写入 AppConfig', () async {
      await controller.setAlbumSort(SortBy.dateModified, false);
      final config = container.read(configProvider);
      expect(config.albumSortBy, SortBy.dateModified);
      expect(config.albumSortAsc, false);
    });

    test('setPhotoSort 在相册内会静默重载第一页', () async {
      await controller.enterBucket('b1');
      final callsBefore = fakeChannel.scanCalls.length;
      await controller.setPhotoSort(SortBy.name, true);
      final config = container.read(configProvider);
      expect(config.photoSortBy, SortBy.name);
      expect(config.photoSortAsc, true);
      // 相册内切排序会重新 enterBucket（silent）→ 多一次 scanImages
      expect(fakeChannel.scanCalls.length, greaterThan(callsBefore));
    });
  });

  group('listBuckets', () {
    test('loadBuckets 载入相册列表', () async {
      await controller.loadBuckets();
      final st = container.read(galleryControllerProvider);
      expect(st.buckets.length, 1);
      expect(st.buckets.first.name, 'Camera');
    });

    test('loadBuckets 权限被拒：置 permissionDenied 而非 error', () async {
      fakeChannel.denyPermission = true;
      await controller.loadBuckets();
      final st = container.read(galleryControllerProvider);
      expect(st.permissionDenied, true, reason: '权限缺失走引导授权，非错误页');
      expect(st.error, isNull);

      // 授权后重查：标志清除、数据正常载入（提示条消失路径）。
      fakeChannel.denyPermission = false;
      await controller.loadBuckets();
      final ok = container.read(galleryControllerProvider);
      expect(ok.permissionDenied, false);
      expect(ok.error, isNull);
      expect(ok.buckets.length, 1);
    });
  });

  group('ContentObserver 增量刷新（P1c）', () {
    test('delete 事件精准移除当前相册内的图', () async {
      final ctl = StreamController<MsChangeEvent>();
      final c = ProviderContainer(overrides: [
        mediaStoreChannelProvider.overrideWithValue(fakeChannel),
        mediaStoreChangeStreamProvider.overrideWith((ref) => ctl.stream),
      ]);
      addTearDown(() {
        c.dispose();
        ctl.close();
      });
      final ctrl = c.read(galleryControllerProvider.notifier);
      await ctrl.enterBucket('b1');
      expect(c.read(galleryControllerProvider).photos.length, 5);

      ctl.add(const MsChangeEvent(MsChangeType.delete, id: '3'));
      await Future<void>.delayed(Duration.zero);

      final st = c.read(galleryControllerProvider);
      expect(st.photos.any((p) => p.id == '3'), false, reason: 'delete 事件应移除该图');
      expect(st.photos.length, 4);
    });

    test('refresh 事件触发当前相册静默重载（400ms 防抖合并）', () async {
      final ctl = StreamController<MsChangeEvent>();
      final c = ProviderContainer(overrides: [
        mediaStoreChannelProvider.overrideWithValue(fakeChannel),
        mediaStoreChangeStreamProvider.overrideWith((ref) => ctl.stream),
      ]);
      addTearDown(() {
        c.dispose();
        ctl.close();
      });
      final ctrl = c.read(galleryControllerProvider.notifier);
      await ctrl.enterBucket('b1');
      final callsBefore = fakeChannel.scanCalls.length;

      ctl.add(const MsChangeEvent(MsChangeType.refresh));
      ctl.add(const MsChangeEvent(MsChangeType.update));
      await Future<void>.delayed(Duration.zero);

      // 防抖窗口内不重查——批量操作触发的 N 个事件合并为一次刷新，
      // 避免逐个全量重查 + 万行快照落盘的 IO 风暴。
      expect(fakeChannel.scanCalls.length, callsBefore,
          reason: '防抖窗口内不应立即重查');

      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(fakeChannel.scanCalls.length, greaterThan(callsBefore),
          reason: '防抖到期后 refresh 应触发相册重载');
    });
  });

  group('restorePhotos exists 复查（回收站恢复防御）', () {
    test('恢复成功：从回收站列表移除并返回 null', () async {
      fakeChannel._trashedIds.addAll(['1', '2']);
      await controller.enterTrash();
      expect(container.read(galleryControllerProvider).photos.length, 2);

      final err = await controller.restorePhotos(['1', '2']);

      expect(err, isNull);
      expect(container.read(galleryControllerProvider).photos, isEmpty,
          reason: '恢复成功的应从回收站列表移除');
    });

    test('系统 untrash 静默失败：保留在列表并报 restore_failed，不再静默吞掉', () async {
      // 复现真机场景：恢复弹窗已确认（RESULT_OK），但被破坏的 trashed 行
      // 系统侧未生效——旧行为按成功本地移除 = 照片"静默消失"。
      fakeChannel._trashedIds.addAll(['1', '2']);
      fakeChannel.restoreStuckIds.add('1');
      await controller.enterTrash();

      final err = await controller.restorePhotos(['1', '2']);

      expect(err, 'restore_failed');
      final photos = container.read(galleryControllerProvider).photos;
      expect(photos.map((p) => p.id), contains('1'),
          reason: '未恢复的必须留在回收站列表（可见、可重试）');
      expect(photos.map((p) => p.id), isNot(contains('2')),
          reason: '恢复成功的应正常移除');
    });
  });
}
