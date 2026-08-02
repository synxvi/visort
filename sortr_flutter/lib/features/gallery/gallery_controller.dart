// 相册浏览控制器 —— 独立于 Sort/Review 流程
//
// 职责：
//   - 列出所有相册（bucket）并按用户排序偏好展示
//   - 进入某相册后扫描其图片（keyset 分页，游标法）
//   - 内存中对 bucket 排序（不重新查询 MediaStore）；相册内列表用 SQL 原序
//   - 单张删除（requestDelete + 本地移除 + imageCache 清理）
//   - 排序偏好持久化到 AppConfig（跨 profile 全局）
//   - 订阅 MediaStore ContentObserver 变更，静默刷新列表
//
// 数据流：MediaStoreChannel（经 [mediaStoreChannelProvider] 注入）→ List<MsBucket>/List<MsImageInfo>
// keyset 分页：GalleryState.nextCursor 持有下一页游标，loadMore 据此取下一页，
//   天然免疫删除导致的偏移（offset 分页的固有问题）。
// 缩略图渲染时由 UI 层把 MsImageInfo.id 包成 ImageRef（imageRefFromMediaStoreId）。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/fs/mediastore_events.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';

/// MediaStore channel Provider（可被测试 override 以注入 fake channel）。
final mediaStoreChannelProvider = Provider<MediaStoreChannel>((ref) {
  return const MediaStoreChannel();
});

/// MediaStore 变更事件流 Provider（ContentObserver 推送）。
/// 测试时可 override 为空 stream，避免触碰 EventChannel。
final mediaStoreChangeStreamProvider = Provider<Stream<MsChangeEvent>>((ref) {
  return mediaStoreChanges();
});

/// copyWith 的 nextCursor 哨兵：区分「未传参（保持原值）」与「显式传 null（置空）」。
/// Dart 命名参数无法区分两者，故用独占 sentinel 对象。
class _UnsetCursorSentinel {
  const _UnsetCursorSentinel();
}

const _unsetCursor = _UnsetCursorSentinel();

/// 相册浏览状态
class GalleryState {
  const GalleryState({
    this.buckets = const [],
    this.photos = const [],
    this.currentBucketId,
    this.loading = false,
    this.loadingMore = false,
    this.nextCursor,
    this.error,
    this.albumSortBy = SortBy.name,
    this.albumSortAsc = true,
    this.photoSortBy = SortBy.dateCreated,
    this.photoSortAsc = false,
    this.isFavoritesView = false,
    this.isTrashView = false,
  });

  final List<MsBucket> buckets;
  final List<MsImageInfo> photos;

  /// 当前正在浏览的相册 id；null = 在相册列表页
  final String? currentBucketId;

  final bool loading;
  final bool loadingMore;
  /// 下一页 keyset 游标；null = 无更多数据。
  final String? nextCursor;
  final String? error;

  final SortBy albumSortBy;
  final bool albumSortAsc;
  final SortBy photoSortBy;
  final bool photoSortAsc;

  /// 当前是否在「收藏」视图（跨相册的收藏图集合，P1b）
  final bool isFavoritesView;

  /// 当前是否在「回收站」视图（跨相册的回收站图集合，P1a）
  final bool isTrashView;

  /// 当前视图实际生效的图片排序。
  /// 回收站视图允许 dateTrashed（DATE_EXPIRES）；其他视图遇到 dateTrashed 时
  /// 回退 dateCreated——DATE_EXPIRES 仅回收站项有值，普通查询会全 NULL 导致乱序。
  SortBy get effectivePhotoSortBy => isTrashView
      ? photoSortBy
      : (photoSortBy == SortBy.dateTrashed ? SortBy.dateCreated : photoSortBy);

  /// 是否还有更多图片可加载（游标非 null）
  bool get hasMore => nextCursor != null;

  /// 排序后的相册列表（不改动原始顺序，仅展示用）
  List<MsBucket> get sortedBuckets {
    final list = List<MsBucket>.of(buckets);
    list.sort((a, b) {
      int cmp;
      switch (albumSortBy) {
        case SortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortBy.dateCreated:
          cmp = a.dateCreatedMs.compareTo(b.dateCreatedMs);
          break;
        case SortBy.dateModified:
          cmp = a.dateModifiedMs.compareTo(b.dateModifiedMs);
          break;
        case SortBy.dateTrashed:
          // 相册（bucket）无删除日期概念；回退创建时间。
          cmp = a.dateCreatedMs.compareTo(b.dateCreatedMs);
          break;
      }
      return albumSortAsc ? cmp : -cmp;
    });
    return list;
  }

  GalleryState copyWith({
    List<MsBucket>? buckets,
    List<MsImageInfo>? photos,
    String? currentBucketId,
    bool clearCurrentBucket = false,
    bool? loading,
    bool? loadingMore,
    /// 下一页游标。默认 [_unsetCursor] = 保持原值；显式传 String?（含 null）= 更新。
    Object? nextCursor = _unsetCursor,
    String? error,
    bool clearError = false,
    SortBy? albumSortBy,
    bool? albumSortAsc,
    SortBy? photoSortBy,
    bool? photoSortAsc,
    bool? isFavoritesView,
    bool? isTrashView,
  }) {
    return GalleryState(
      buckets: buckets ?? this.buckets,
      photos: photos ?? this.photos,
      currentBucketId:
          clearCurrentBucket ? null : (currentBucketId ?? this.currentBucketId),
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      nextCursor: identical(nextCursor, _unsetCursor)
          ? this.nextCursor
          : nextCursor as String?,
      error: clearError ? null : (error ?? this.error),
      albumSortBy: albumSortBy ?? this.albumSortBy,
      albumSortAsc: albumSortAsc ?? this.albumSortAsc,
      photoSortBy: photoSortBy ?? this.photoSortBy,
      photoSortAsc: photoSortAsc ?? this.photoSortAsc,
      isFavoritesView: isFavoritesView ?? this.isFavoritesView,
      isTrashView: isTrashView ?? this.isTrashView,
    );
  }
}

class GalleryController extends Notifier<GalleryState> {
  static const _pageSize = 60;

  MediaStoreChannel get _channel => ref.read(mediaStoreChannelProvider);
  ProfilesService get _service => ref.read(profilesServiceProvider);

  /// ContentObserver 订阅（build 时建立，dispose 时自动清理）。
  StreamSubscription<MsChangeEvent>? _changeSub;

  @override
  GalleryState build() {
    final config = ref.read(configProvider);
    // 订阅 MediaStore 变更：图库增删时静默刷新当前视图。
    // 通过 provider 取流，便于测试 override（绕过 EventChannel）。
    // 非安卓端 EventChannel 无 handler，订阅 onError 静默忽略。
    _changeSub = ref.read(mediaStoreChangeStreamProvider).listen(
      (event) => _onMediaStoreChanged(event),
      onError: (_) {}, // 非安卓端无 channel，静默忽略
    );
    ref.onDispose(() {
      _changeSub?.cancel();
      _changeSub = null;
    });
    return GalleryState(
      albumSortBy: config.albumSortBy,
      albumSortAsc: config.albumSortAsc,
      photoSortBy: config.photoSortBy,
      photoSortAsc: config.photoSortAsc,
    );
  }

  // ───────────────────────── 相册列表 ─────────────────────────

  /// 加载所有相册。封面跟随「相册内排序」（photoSortBy），
  /// 保证封面 = 进相册看到的第一张。
  ///
  /// [silent]：静默更新（不触发 loading 闪烁）。相册内切排序时用，
  /// 避免相册内网格因 loading 切换而闪烁。
  Future<void> loadBuckets({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(loading: true, clearError: true);
    }
    try {
      final buckets = await _channel.listBuckets(
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
      );
      if (buckets.isEmpty) {
        state = state.copyWith(buckets: const [], loading: false);
        return;
      }
      // 静默更新只改 buckets，不碰 loading
      state = silent
          ? state.copyWith(buckets: buckets)
          : state.copyWith(buckets: buckets, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// 切换相册内图片排序并持久化。
  /// 切换「相册内排序」并持久化。
  /// - 相册内（currentBucketId != null）：用新排序重新加载该相册第一页，
  ///   保证分页顺序与新排序一致（不能只靠内存重排已加载页，
  ///   否则排序维度变化后已加载页不是新排序下的前 N 张）。
  /// - 回收站/收藏视图：用新排序重新加载该视图第一页。
  /// - 首页：重查相册封面（封面跟随此排序）。
  Future<void> setPhotoSort(SortBy sortBy, bool asc) async {
    final inBucket = state.currentBucketId;
    final favView = state.isFavoritesView;
    final trashView = state.isTrashView;
    state = state.copyWith(photoSortBy: sortBy, photoSortAsc: asc);
    await _persistSortPrefs();
    if (inBucket != null) {
      // 相册内：重新加载当前相册（顺序已跟随新排序）
      await enterBucket(inBucket, silent: true);
    } else if (favView || trashView) {
      // 收藏/回收站视图：重查当前视图第一页（顺序跟随新排序）
      // currentBucketId 为 null，必须单独处理，否则会落到 loadBuckets 分支。
      await (favView ? enterFavorites() : enterTrash());
    }
    // 重查封面（首页用，相册内静默不闪烁）
    await loadBuckets(silent: inBucket != null || favView || trashView);
  }

  /// 切换相册列表排序并持久化（仅影响列表顺序，不影响封面）
  Future<void> setAlbumSort(SortBy sortBy, bool asc) async {
    state = state.copyWith(albumSortBy: sortBy, albumSortAsc: asc);
    await _persistSortPrefs();
  }

  // ───────────────────────── 相册内浏览 ─────────────────────────

  /// 进入某相册，加载第一页图片。
  /// [silent]：静默重载（切排序时用，保留旧数据直到新数据到达，避免闪烁）。
  Future<void> enterBucket(String bucketId, {bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(
        currentBucketId: bucketId,
        photos: const [],
        nextCursor: null,
        loading: true,
        isFavoritesView: false,
        isTrashView: false,
        clearError: true,
      );
    } else {
      state = state.copyWith(currentBucketId: bucketId, clearError: true);
    }
    try {
      final page = await _channel.scanImages(
        [bucketId],
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
      );
      state = state.copyWith(
        photos: page.images,
        loading: false,
        nextCursor: page.nextCursor,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// 退出相册，回到相册列表
  void exitBucket() {
    state = state.copyWith(
      clearCurrentBucket: true,
      photos: const [],
      isFavoritesView: false,
      isTrashView: false,
      nextCursor: null,
    );
  }

  // ───────────────────────── 收藏（P1b）─────────────────────────

  /// 进入「收藏」视图：扫描所有 IS_FAVORITE=1 的图（跨相册）。
  Future<void> enterFavorites({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(
        currentBucketId: null,
        isFavoritesView: true,
        isTrashView: false,
        photos: const [],
        nextCursor: null,
        loading: true,
        clearError: true,
      );
    }
    try {
      final page = await _channel.scanImages(
        const [], // 不限 bucket
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
        favoritesOnly: true,
      );
      state = state.copyWith(
        photos: page.images,
        loading: false,
        nextCursor: page.nextCursor,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  // ───────────────────────── 回收站（P1a）─────────────────────────

  /// 进入「回收站」视图：扫描所有 IS_TRASHED=1 的图（跨相册）。
  Future<void> enterTrash({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(
        currentBucketId: null,
        isFavoritesView: false,
        isTrashView: true,
        photos: const [],
        nextCursor: null,
        loading: true,
        clearError: true,
      );
    }
    try {
      final page = await _channel.scanImages(
        const [],
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
        trashedOnly: true,
      );
      state = state.copyWith(
        photos: page.images,
        loading: false,
        nextCursor: page.nextCursor,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// 移入回收站单张（系统弹窗确认）。成功后从当前列表移除 + 清缓存。
  Future<String?> trashPhoto(String id) async {
    try {
      await _channel.requestTrash([id]);
      evictImageCache(id);
      state = state.copyWith(
        photos: state.photos.where((p) => p.id != id).toList(),
      );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 从回收站恢复单张。成功后从回收站列表移除 + 清缓存。
  Future<String?> restorePhoto(String id) async {
    try {
      await _channel.requestRestore([id]);
      evictImageCache(id);
      state = state.copyWith(
        photos: state.photos.where((p) => p.id != id).toList(),
      );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 收藏/取消收藏单张（乐观更新本地 isFavorite，失败回滚）。返回错误 key 或 null。
  Future<String?> toggleFavorite(MsImageInfo photo) async {
    final newFav = !photo.isFavorite;
    state = state.copyWith(
      photos: state.photos
          .map((p) => p.id == photo.id ? _copyWithFavorite(p, newFav) : p)
          .toList(),
    );
    try {
      await _channel.requestFavorite([photo.id], newFav);
      return null;
    } catch (e) {
      // 回滚
      state = state.copyWith(
        photos: state.photos
            .map((p) => p.id == photo.id ? _copyWithFavorite(p, !newFav) : p)
            .toList(),
      );
      return e.toString();
    }
  }

  MsImageInfo _copyWithFavorite(MsImageInfo p, bool fav) => MsImageInfo(
        id: p.id,
        name: p.name,
        size: p.size,
        mime: p.mime,
        bucketId: p.bucketId,
        dateAddedMs: p.dateAddedMs,
        dateModifiedMs: p.dateModifiedMs,
        isFavorite: fav,
        isTrashed: p.isTrashed,
        dateTrashedMs: p.dateTrashedMs,
      );

  /// 加载下一页（滚动到底触发）。keyset 游标法：用上一页返回的游标取下一页。
  Future<void> loadMore() async {
    final bucketId = state.currentBucketId;
    final cursor = state.nextCursor;
    final favView = state.isFavoritesView;
    final trashView = state.isTrashView;
    if ((bucketId == null && !favView && !trashView) ||
        state.loadingMore ||
        cursor == null) return;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await _channel.scanImages(
        (favView || trashView) ? const [] : [bucketId!],
        afterCursor: cursor,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
        favoritesOnly: favView,
        trashedOnly: trashView,
      );
      if (page.images.isEmpty) {
        // 无新数据
        state = state.copyWith(loadingMore: false, nextCursor: null);
        return;
      }
      state = state.copyWith(
        photos: [...state.photos, ...page.images],
        loadingMore: false,
        nextCursor: page.nextCursor,
      );
    } catch (e) {
      state = state.copyWith(loadingMore: false, error: e.toString());
    }
  }

  // ───────────────────────── 删除 ─────────────────────────

  /// 删除单张图片。成功后从内存列表移除并清理缩略图缓存。
  /// 返回 null 表示成功，否则返回错误信息。
  ///
  /// 注意：不可盲目信任 requestDelete 的返回值——部分 ROM（如 ColorOS）即使
  /// AppOps 报告 MANAGE_MEDIA 已授权，实际 contentResolver.delete 仍会失败，
  /// 但 Kotlin 端旧逻辑会返回 0（误报）。故此处用 exists(id) 二次确认文件是否
  /// 真的消失，只有确认删除才更新本地 state，避免"缩略图消失但返回又出现"。
  Future<String?> deletePhoto(String id) async {
    try {
      await _channel.requestDelete([id]);
      // 二次确认：文件是否真的被删除（防御 ROM 误报）
      if (await _channel.exists(id)) {
        // 文件仍在 → 删除未生效，不更新本地 state
        return 'delete_failed';
      }
      // 确认删除成功：清理该图的所有缓存（缩略图 + 全图）
      evictImageCache(id);
      state = state.copyWith(
        photos: state.photos.where((p) => p.id != id).toList(),
        // 同步更新 bucket 列表中对应相册的 count
        buckets: state.buckets
            .map((b) => b.id == state.currentBucketId
                ? MsBucket(
                    id: b.id,
                    name: b.name,
                    count: b.count > 0 ? b.count - 1 : 0,
                    dateCreatedMs: b.dateCreatedMs,
                    dateModifiedMs: b.dateModifiedMs,
                    coverId: b.coverId == id ? null : b.coverId,
                  )
                : b)
            .toList(),
      );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // ───────────────────────── ContentObserver 刷新 ─────────────────────────

  /// MediaStore 发生变更时静默刷新当前视图（相册列表或相册内）。
  /// 不触发 loading 闪烁；切排序/分页进行中则跳过避免打断。
  void _onMediaStoreChanged(MsChangeEvent event) {
    if (state.loading || state.loadingMore) return;
    switch (event.type) {
      case MsChangeType.delete:
        // 精准删除：从当前列表移除该 id（仅当它在当前视图）
        final id = event.id;
        if (id != null && state.photos.any((p) => p.id == id)) {
          state = state.copyWith(
            photos: state.photos.where((p) => p.id != id).toList(),
            buckets: state.buckets
                .map((b) => b.id == state.currentBucketId && b.count > 0
                    ? MsBucket(
                        id: b.id,
                        name: b.name,
                        count: b.count - 1,
                        dateCreatedMs: b.dateCreatedMs,
                        dateModifiedMs: b.dateModifiedMs,
                        coverId: b.coverId == id ? null : b.coverId,
                      )
                    : b)
                .toList(),
          );
        } else if (state.currentBucketId == null) {
          // 首页收到 item 删除 → 静默重查相册数
          loadBuckets(silent: true);
        }
        break;
      case MsChangeType.insert:
      case MsChangeType.update:
      case MsChangeType.refresh:
        // 新增/修改/兜底：重载当前视图（相册内重查第一页，首页重查相册数）
        if (state.isFavoritesView) {
          enterFavorites(silent: true);
        } else if (state.isTrashView) {
          enterTrash(silent: true);
        } else if (state.currentBucketId != null) {
          enterBucket(state.currentBucketId!, silent: true);
        } else {
          loadBuckets(silent: true);
        }
        break;
    }
  }

  // ───────────────────────── 内部 ─────────────────────────

  /// 持久化排序偏好到 AppConfig
  Future<void> _persistSortPrefs() async {
    final config = ref.read(configProvider);
    final updated = config.copyWith(
      albumSortBy: state.albumSortBy,
      albumSortAsc: state.albumSortAsc,
      photoSortBy: state.photoSortBy,
      photoSortAsc: state.photoSortAsc,
    );
    ref.read(configProvider.notifier).state = updated;
    await _service.save(updated);
  }
}

// ───────────────────────── Provider 注册 ─────────────────────────

final galleryControllerProvider =
    NotifierProvider<GalleryController, GalleryState>(
  () => GalleryController(),
);
