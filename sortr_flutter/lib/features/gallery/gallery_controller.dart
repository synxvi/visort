// 相册浏览控制器 —— 独立于 Sort/Review 流程
//
// 职责：
//   - 列出所有相册（bucket）并按用户排序偏好展示
//   - 进入某相册后扫描其图片（支持 offset 分页）
//   - 内存中对 bucket/图片排序（不重新查询 MediaStore）
//   - 单张删除（requestDelete + 本地移除 + imageCache 清理）
//   - 排序偏好持久化到 AppConfig（跨 profile 全局）
//
// 数据流：MediaStoreChannel → List<MsBucket>/List<MsImageInfo>
// 缩略图渲染时由 UI 层把 MsImageInfo.id 包成 ImageRef（imageRefFromMediaStoreId）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';

/// 相册浏览状态
class GalleryState {
  const GalleryState({
    this.buckets = const [],
    this.photos = const [],
    this.currentBucketId,
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = true,
    this.error,
    this.albumSortBy = SortBy.name,
    this.albumSortAsc = true,
    this.photoSortBy = SortBy.dateTaken,
    this.photoSortAsc = false,
  });

  final List<MsBucket> buckets;
  final List<MsImageInfo> photos;

  /// 当前正在浏览的相册 id；null = 在相册列表页
  final String? currentBucketId;

  final bool loading;
  final bool loadingMore;
  /// 相册内是否还有更多图片可加载（分页用）
  final bool hasMore;
  final String? error;

  final SortBy albumSortBy;
  final bool albumSortAsc;
  final SortBy photoSortBy;
  final bool photoSortAsc;

  /// 排序后的相册列表（不改动原始顺序，仅展示用）
  List<MsBucket> get sortedBuckets {
    final list = List<MsBucket>.of(buckets);
    list.sort((a, b) {
      int cmp;
      if (albumSortBy == SortBy.name) {
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        // 按日期：用 coverId 是否存在粗略排序（最新封面在前）。
        // bucket 本身无日期字段，这里用 count 作为次要键保证稳定。
        cmp = a.count.compareTo(b.count);
      }
      return albumSortAsc ? cmp : -cmp;
    });
    return list;
  }

  /// 排序后的图片列表
  List<MsImageInfo> get sortedPhotos {
    final list = List<MsImageInfo>.of(photos);
    list.sort((a, b) {
      int cmp;
      switch (photoSortBy) {
        case SortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortBy.dateTaken:
          cmp = a.dateTakenMs.compareTo(b.dateTakenMs);
          break;
        case SortBy.dateAdded:
          cmp = a.dateAddedMs.compareTo(b.dateAddedMs);
          break;
      }
      return photoSortAsc ? cmp : -cmp;
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
    bool? hasMore,
    String? error,
    bool clearError = false,
    SortBy? albumSortBy,
    bool? albumSortAsc,
    SortBy? photoSortBy,
    bool? photoSortAsc,
  }) {
    return GalleryState(
      buckets: buckets ?? this.buckets,
      photos: photos ?? this.photos,
      currentBucketId:
          clearCurrentBucket ? null : (currentBucketId ?? this.currentBucketId),
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
      albumSortBy: albumSortBy ?? this.albumSortBy,
      albumSortAsc: albumSortAsc ?? this.albumSortAsc,
      photoSortBy: photoSortBy ?? this.photoSortBy,
      photoSortAsc: photoSortAsc ?? this.photoSortAsc,
    );
  }
}

class GalleryController extends Notifier<GalleryState> {
  static const _channel = MediaStoreChannel();
  static const _pageSize = 60;

  ProfilesService get _service => ref.read(profilesServiceProvider);

  @override
  GalleryState build() {
    final config = ref.read(configProvider);
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
        sortBy: state.photoSortBy,
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
  ///   保证分页顺序与新排序一致（不能只靠 sortedPhotos 内存重排已加载页，
  ///   否则排序维度变化后已加载页不是新排序下的前 N 张）。
  /// - 首页：重查相册封面（封面跟随此排序）。
  Future<void> setPhotoSort(SortBy sortBy, bool asc) async {
    final inBucket = state.currentBucketId;
    state = state.copyWith(photoSortBy: sortBy, photoSortAsc: asc);
    await _persistSortPrefs();
    if (inBucket != null) {
      // 相册内：重新加载当前相册（顺序已跟随新排序）
      await enterBucket(inBucket);
    }
    // 重查封面（首页用，相册内静默不闪烁）
    await loadBuckets(silent: inBucket != null);
  }

  /// 切换相册列表排序并持久化（仅影响列表顺序，不影响封面）
  Future<void> setAlbumSort(SortBy sortBy, bool asc) async {
    state = state.copyWith(albumSortBy: sortBy, albumSortAsc: asc);
    await _persistSortPrefs();
  }

  // ───────────────────────── 相册内浏览 ─────────────────────────

  /// 进入某相册，加载第一页图片
  Future<void> enterBucket(String bucketId) async {
    state = state.copyWith(
      currentBucketId: bucketId,
      photos: const [],
      hasMore: true,
      loading: true,
      clearError: true,
    );
    try {
      final photos = await _channel.scanImages([bucketId],
          max: _pageSize,
          offset: 0,
          sortBy: state.photoSortBy.name,
          asc: state.photoSortAsc);
      state = state.copyWith(
        photos: photos,
        loading: false,
        hasMore: photos.length >= _pageSize,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// 退出相册，回到相册列表
  void exitBucket() {
    state = state.copyWith(clearCurrentBucket: true, photos: const []);
  }

  /// 加载下一页（滚动到底触发）
  Future<void> loadMore() async {
    final bucketId = state.currentBucketId;
    if (bucketId == null || state.loadingMore || !state.hasMore) return;
    state = state.copyWith(loadingMore: true);
    try {
      final offset = state.photos.length;
      final more = await _channel.scanImages([bucketId],
          max: _pageSize,
          offset: offset,
          sortBy: state.photoSortBy.name,
          asc: state.photoSortAsc);
      if (more.isEmpty) {
        state = state.copyWith(loadingMore: false, hasMore: false);
        return;
      }
      state = state.copyWith(
        photos: [...state.photos, ...more],
        loadingMore: false,
        hasMore: more.length >= _pageSize,
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
