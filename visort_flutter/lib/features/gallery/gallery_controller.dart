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
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/profiles_service.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/fs/mediastore_events.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';

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

/// 相册内存快照：exitBucket 时保留该桶的网格数据与游标，同桶重进时
/// 「秒出旧网格 + 后台静默刷新」（对标系统相册 loadFromCache → 后台校验）。
/// 排序维度变化（effectivePhotoSortBy/asc）后快照失效，直接重查。
class _BucketSnapshot {
  const _BucketSnapshot(this.photos, this.nextCursor, this.sortBy, this.asc);

  final List<MsImageInfo> photos;
  final String? nextCursor;
  final SortBy sortBy;
  final bool asc;
}

/// 相册浏览视图类型（互斥）。albums=相册列表首页；bucket=某相册内；
/// favorites=跨相册收藏集合；trash=跨相册回收站集合。
enum GalleryView { albums, bucket, favorites, trash }

/// 相册浏览状态
class GalleryState {
  const GalleryState({
    this.buckets = const [],
    this.photos = const [],
    this.view = GalleryView.albums,
    this.bucketId,
    this.loadingMore = false,
    this.firstPageLoaded = false,
    this.nextCursor,
    this.error,
    this.albumSortBy = SortBy.name,
    this.albumSortAsc = true,
    this.photoSortBy = SortBy.dateCreated,
    this.photoSortAsc = false,
  });

  final List<MsBucket> buckets;
  final List<MsImageInfo> photos;

  /// 当前视图类型（互斥）。与 [bucketId] 配合:仅 view==bucket 时 bucketId 有意义。
  final GalleryView view;

  /// 当前正在浏览的相册 id;仅 view==bucket 时非 null。
  /// 不变式:view != GalleryView.bucket ⟹ bucketId == null(各 enter/exit 方法维护)。
  final String? bucketId;

  final bool loadingMore;
  /// 当前视图是否已完成首次加载（成功返回过第一页）。
  /// UI 据此区分「加载中占位」与「真空相册」——加载中显示灰格占位而非"空"文案。
  final bool firstPageLoaded;
  /// 下一页 keyset 游标；null = 无更多数据。
  final String? nextCursor;
  final String? error;

  final SortBy albumSortBy;
  final bool albumSortAsc;
  final SortBy photoSortBy;
  final bool photoSortAsc;

  /// 当前视图实际生效的图片排序。
  /// 回收站视图允许 dateTrashed（DATE_EXPIRES）；其他视图遇到 dateTrashed 时
  /// 回退 dateCreated——DATE_EXPIRES 仅回收站项有值，普通查询会全 NULL 导致乱序。
  SortBy get effectivePhotoSortBy => view == GalleryView.trash
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
    GalleryView? view,
    String? bucketId,
    bool clearBucketId = false,
    bool? loadingMore,
    bool? firstPageLoaded,
    /// 下一页游标。默认 [_unsetCursor] = 保持原值；显式传 String?（含 null）= 更新。
    Object? nextCursor = _unsetCursor,
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
      view: view ?? this.view,
      bucketId: clearBucketId ? null : (bucketId ?? this.bucketId),
      loadingMore: loadingMore ?? this.loadingMore,
      firstPageLoaded: firstPageLoaded ?? this.firstPageLoaded,
      nextCursor: identical(nextCursor, _unsetCursor)
          ? this.nextCursor
          : nextCursor as String?,
      error: clearError ? null : (error ?? this.error),
      albumSortBy: albumSortBy ?? this.albumSortBy,
      albumSortAsc: albumSortAsc ?? this.albumSortAsc,
      photoSortBy: photoSortBy ?? this.photoSortBy,
      photoSortAsc: photoSortAsc ?? this.photoSortAsc,
    );
  }
}

class GalleryController extends Notifier<GalleryState> {
  /// 单次查询上限：足够大以一次查完全量（对齐系统相册「全量元数据 + 缩略图窗口化」）。
  /// 全量后 itemCount 固定 → maxScrollExtent 从一开始就稳定 → 滚动手柄不跳。
  /// 真正昂贵的是缩略图解码（UI 层懒加载 + 磁盘缓存），元数据 cursor 几万行毫秒级。
  static const _pageSize = 100000;

  /// 桶快照缓存（内存）：exitBucket 写入，同桶重进直出。上限 8 桶 LRU 淘汰。
  final Map<String, _BucketSnapshot> _bucketSnapshots = {};

  /// 视图加载序号：enterBucket/enterFavorites/enterTrash 每次 +1，
  /// 异步返回时比对，旧请求结果直接丢弃（防止切桶/切视图竞态覆盖）。
  int _loadToken = 0;

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
  /// ⚠️ 无 loading 转圈：UI 层在 buckets 为空时显示占位（收藏/回收站入口行），
  /// 数据到达后列表直接填充，不闪不转。
  Future<void> loadBuckets({bool silent = false}) async {
    try {
      final buckets = await _channel.listBuckets(
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
      );
      if (buckets.isEmpty) {
        state = state.copyWith(buckets: const []);
        return;
      }
      state = state.copyWith(buckets: buckets);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// 切换相册内图片排序并持久化。
  /// 切换「相册内图片排序」并持久化,并按当前视图(单一枚举)重查对应第一页。
  /// - bucket:用新排序重新加载该相册第一页(不能只靠内存重排已加载页,
  ///   排序维度变化后已加载页不是新排序下的前 N 张)。
  /// - favorites/trash:用新排序重新加载该视图第一页。
  /// - albums:不重查相册内,仅重查封面。
  /// 按 view 分发(而非读多个标志位),杜绝"标志位不一致走错分支"导致串视图。
  Future<void> setPhotoSort(SortBy sortBy, bool asc) async {
    state = state.copyWith(photoSortBy: sortBy, photoSortAsc: asc);
    await _persistSortPrefs();
    switch (state.view) {
      case GalleryView.bucket:
        final id = state.bucketId;
        if (id != null) await enterBucket(id, silent: true);
      case GalleryView.favorites:
        // silent：切排序保留旧数据直到新数据到达（与 bucket 分支一致）。
        // 否则 photos 清空 → UI 渲染灰格占位网格 + AnimatedSwitcher
        // crossfade 叠加 = 收藏/回收站切排序"灰色遮罩"。
        await enterFavorites(silent: true);
      case GalleryView.trash:
        await enterTrash(silent: true);
      case GalleryView.albums:
        break;
    }
    // 重查封面（首页用；非首页静默不闪）
    await loadBuckets(silent: state.view != GalleryView.albums);
  }

  /// 切换相册列表排序并持久化（仅影响列表顺序，不影响封面）
  Future<void> setAlbumSort(SortBy sortBy, bool asc) async {
    state = state.copyWith(albumSortBy: sortBy, albumSortAsc: asc);
    await _persistSortPrefs();
  }

  // ───────────────────────── 相册内浏览 ─────────────────────────

  /// 进入某相册，加载第一页图片。
  /// [silent]：静默重载（切排序时用，保留旧数据直到新数据到达，避免闪烁）。
  ///
  /// ⚠️ 零转圈：不再设置 loading 全屏转圈——非 silent 时若有该桶内存快照
  /// （之前进过），直接「秒出旧网格 + 后台静默刷新」；无快照则清空显示
  /// 占位灰格（UI 层按 firstPageLoaded=false 渲染），第一页到达后填充。
  Future<void> enterBucket(String bucketId, {bool silent = false}) async {
    final token = ++_loadToken;
    var snap = _bucketSnapshots[bucketId];
    if (snap == null) {
      // 内存 miss（杀后台后进程重建）：尝试磁盘快照秒出，对标系统相册 loadFromCache。
      snap = await _loadDiskSnapshot(bucketId);
      if (snap != null) _bucketSnapshots[bucketId] = snap;
    }
    final snapValid = snap != null &&
        snap.sortBy == state.effectivePhotoSortBy &&
        snap.asc == state.photoSortAsc;
    if (!silent && snapValid) {
      // 快照直出：旧网格立即可见（缩略图仍在 ImageCache，秒开），后台刷新替换。
      state = state.copyWith(
        view: GalleryView.bucket,
        bucketId: bucketId,
        photos: snap.photos,
        nextCursor: snap.nextCursor,
        firstPageLoaded: true,
        clearError: true,
      );
      await _refreshBucketPage(bucketId, token);
      return;
    }
    state = state.copyWith(
      view: GalleryView.bucket,
      bucketId: bucketId,
      // silent（切排序/observer 刷新）：保留旧数据避免闪烁；否则清空走占位。
      photos: silent ? state.photos : const [],
      nextCursor: null,
      firstPageLoaded: silent ? state.firstPageLoaded : false,
      clearError: true,
    );
    try {
      final page = await _channel.scanImages(
        [bucketId],
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
      );
      if (token != _loadToken || state.bucketId != bucketId) return;
      _applyBucketPage(bucketId, token, page);
    } catch (e) {
      if (token != _loadToken) return;
      state = state.copyWith(error: e.toString());
    }
  }

  /// 后台静默刷新当前桶第一页（快照直出后/observer 刷新用）。
  Future<void> _refreshBucketPage(String bucketId, int token) async {
    try {
      final page = await _channel.scanImages(
        [bucketId],
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
      );
      if (token != _loadToken || state.bucketId != bucketId) return;
      _applyBucketPage(bucketId, token, page);
    } catch (e) {
      if (token != _loadToken) return;
      state = state.copyWith(error: e.toString());
    }
  }

  /// 应用第一页结果 + 更新桶快照（供下次直出）。
  void _applyBucketPage(String bucketId, int token, MsScanPage page) {
    state = state.copyWith(
      photos: page.images,
      nextCursor: page.nextCursor,
      loadingMore: false,
      firstPageLoaded: true,
    );
    _putSnapshot(bucketId,
        _BucketSnapshot(page.images, page.nextCursor,
            state.effectivePhotoSortBy, state.photoSortAsc));
    // 网格先上屏，HDR 异步补测回填（aves cataloguing 语义）。
    unawaited(_backfillHdr(bucketId, token, page.images));
  }

  /// HDR 后台补测：scanImages 不做文件 IO（曾内联 64KB 头读，全 JPEG
  /// 大相册一把梭页几十秒，真机 Camera 相册卡死实证），徽标数据经独立
  /// channel 批量检测，到货后 copyWith 回填列表。Kotlin hdrCache 保证
  /// 重复进桶/二次启动零文件 IO（缓存命中）。
  Future<void> _backfillHdr(
    String bucketId,
    int token,
    List<MsImageInfo> photos,
  ) async {
    final jpegs = photos.where((p) => p.mime == 'image/jpeg').toList();
    if (jpegs.isEmpty) return;
    try {
      final hdrs = await _channel.detectHdrs(
        jpegs.map((p) => p.id).toList(),
        jpegs.map((p) => p.dateModifiedMs).toList(),
      );
      if (token != _loadToken || state.bucketId != bucketId) return;
      // 全 false 不重建（无谓的全网格 rebuild）。
      final hdrIds = <String>{
        for (var i = 0; i < jpegs.length; i++)
          if (hdrs[i]) jpegs[i].id,
      };
      if (hdrIds.isEmpty) return;
      final updated = [
        for (final p in state.photos)
          if (hdrIds.contains(p.id)) p.copyWith(isHdr: true) else p,
      ];
      state = state.copyWith(photos: updated);
      _putSnapshot(
        bucketId,
        _BucketSnapshot(updated, state.nextCursor,
            state.effectivePhotoSortBy, state.photoSortAsc),
      );
    } catch (_) {
      // 补测失败静默：badge 缺失可接受，不阻塞网格。
    }
  }

  /// 桶快照 LRU：最多保留 8 桶，超出删最早写入的。
  void _putSnapshot(String bucketId, _BucketSnapshot snap) {
    _bucketSnapshots[bucketId] = snap;
    if (_bucketSnapshots.length > 8) {
      _bucketSnapshots.remove(_bucketSnapshots.keys.first);
    }
    _persistSnapshot(bucketId, snap); // fire-and-forget 磁盘持久化（杀后台后秒出）
  }

  /// 磁盘快照 key。
  static String _snapKey(String bucketId) => 'visort_snap_$bucketId';

  /// 写磁盘快照（异步，失败静默）。杀后台/进程重建后 [enterBucket] 可秒出。
  Future<void> _persistSnapshot(String bucketId, _BucketSnapshot snap) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _snapKey(bucketId),
        jsonEncode({
          'photos': snap.photos.map((p) => p.toJson()).toList(growable: false),
          'nextCursor': snap.nextCursor,
          'sortBy': snap.sortBy.name,
          'asc': snap.asc,
        }),
      );
    } catch (_) {
      // 磁盘写失败不影响功能（仅退化为下次无磁盘缓存）。
    }
  }
  Future<_BucketSnapshot?> _loadDiskSnapshot(String bucketId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_snapKey(bucketId));
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final photos = (j['photos'] as List)
          .map((e) => MsImageInfo.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
      final sortBy = SortBy.values.firstWhere(
        (s) => s.name == j['sortBy'],
        orElse: () => SortBy.dateCreated,
      );
      final nextCursor = (j['nextCursor'] == null || j['nextCursor'] == 'null')
          ? null
          : j['nextCursor'] as String?;
      return _BucketSnapshot(
        photos,
        nextCursor,
        sortBy,
        (j['asc'] as bool?) ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 退出相册，回到相册列表。退出前把当前网格数据存入桶快照，
  /// 同桶重进时秒出（对标系统相册内存缓存）。
  /// 同时静默重查相册列表：删除/恢复后返回首页，count 与封面以
  /// MediaStore 实时数据为准（兜底 mutation 后的重查，防时序竞争）。
  void exitBucket() {
    // 递增 token：使 snapValid 秒出后挂起的后台 _refreshBucketPage 失效，
    // 避免 album_screen pop（element defunct）后后台查询返回触发 state= →
    // riverpod notify 已 unmount 的 listener 报 defunct assertion。
    _loadToken++;
    final bucketId = state.bucketId;
    if (bucketId != null && state.firstPageLoaded) {
      _putSnapshot(
        bucketId,
        _BucketSnapshot(state.photos, state.nextCursor,
            state.effectivePhotoSortBy, state.photoSortAsc),
      );
    }
    state = state.copyWith(
      view: GalleryView.albums,
      clearBucketId: true,
      photos: const [],
      nextCursor: null,
      firstPageLoaded: false,
    );
    loadBuckets();
  }

  // ───────────────────────── 收藏（P1b）─────────────────────────

  /// 进入「收藏」视图：扫描所有 IS_FAVORITE=1 的图（跨相册）。
  Future<void> enterFavorites({bool silent = false}) async {
    final token = ++_loadToken;
    state = state.copyWith(
      view: GalleryView.favorites,
      clearBucketId: true,
      photos: silent ? state.photos : const [],
      nextCursor: null,
      firstPageLoaded: silent ? state.firstPageLoaded : false,
      clearError: true,
    );
    try {
      final page = await _channel.scanImages(
        const [], // 不限 bucket
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
        favoritesOnly: true,
      );
      if (token != _loadToken) return;
      state = state.copyWith(
        photos: page.images,
        nextCursor: page.nextCursor,
        loadingMore: false,
        firstPageLoaded: true,
      );
    } catch (e) {
      if (token != _loadToken) return;
      state = state.copyWith(error: e.toString());
    }
  }

  // ───────────────────────── 回收站（P1a）─────────────────────────

  /// 进入「回收站」视图：扫描所有 IS_TRASHED=1 的图（跨相册）。
  Future<void> enterTrash({bool silent = false}) async {
    final token = ++_loadToken;
    state = state.copyWith(
      view: GalleryView.trash,
      clearBucketId: true,
      photos: silent ? state.photos : const [],
      nextCursor: null,
      firstPageLoaded: silent ? state.firstPageLoaded : false,
      clearError: true,
    );
    try {
      final page = await _channel.scanImages(
        const [],
        afterCursor: null,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
        trashedOnly: true,
      );
      if (token != _loadToken) return;
      state = state.copyWith(
        photos: page.images,
        nextCursor: page.nextCursor,
        loadingMore: false,
        firstPageLoaded: true,
      );
    } catch (e) {
      if (token != _loadToken) return;
      state = state.copyWith(error: e.toString());
    }
  }

  /// 移入回收站单张（系统弹窗确认）。成功后从当前列表移除 + 清缓存，
  /// 并重查相册列表（首页 count/封面跟随 MediaStore 实时数据——回收站项
  /// 从普通查询排除，count 递减、封面自动推进）。
  Future<String?> trashPhoto(String id) async {
    try {
      await _channel.requestTrash([id]);
      evictImageCache(id);
      // 先本地同步首页相册列表（count-1 + 封面推进），再移除 photos——
      // 此时 state.photos 仍含该照片，可定位其所属相册（收藏视图亦可用）。
      _applyBucketDelta(id, countDelta: -1);
      state = state.copyWith(
        photos: state.photos.where((p) => p.id != id).toList(),
      );
      await loadBuckets();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 从回收站恢复单张。成功后从回收站列表移除 + 清缓存 + 重查相册列表
  /// （count 回升，恢复的图可能成为新封面）。
  Future<String?> restorePhoto(String id) async {
    try {
      await _channel.requestRestore([id]);
      evictImageCache(id);
      _applyBucketDelta(id, countDelta: 1);
      state = state.copyWith(
        photos: state.photos.where((p) => p.id != id).toList(),
      );
      await loadBuckets();
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
        width: p.width,
        height: p.height,
      );

  /// 加载下一页（滚动到底触发）。keyset 游标法：用上一页返回的游标取下一页。
  Future<void> loadMore() async {
    final view = state.view;
    final cursor = state.nextCursor;
    // albums 视图无分页(相册列表一次性加载);其余视图需有游标才继续。
    if (view == GalleryView.albums || state.loadingMore || cursor == null) {
      return;
    }
    state = state.copyWith(loadingMore: true);
    try {
      final page = await _channel.scanImages(
        view == GalleryView.bucket ? [state.bucketId!] : const [],
        afterCursor: cursor,
        limit: _pageSize,
        sortBy: state.effectivePhotoSortBy,
        asc: state.photoSortAsc,
        favoritesOnly: view == GalleryView.favorites,
        trashedOnly: view == GalleryView.trash,
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

  /// 删除/恢复后本地同步首页相册列表（count 增减、删除封面时推进到下一张）。
  /// 必须在移除 state.photos 之前调用（需从 photos 定位照片所属相册，
  /// 兼容收藏/回收站视图 bucketId 为 null 的场景）。
  /// 不依赖 listBuckets 查询——ColorOS 查询过滤回收站不可靠，
  /// 本地维护保证首页立即正确，loadBuckets 重查仅作权威校准。
  void _applyBucketDelta(String photoId, {required int countDelta}) {
    MsImageInfo? photo;
    for (final p in state.photos) {
      if (p.id == photoId) {
        photo = p;
        break;
      }
    }
    final bucketId = photo?.bucketId ?? state.bucketId;
    if (bucketId == null) return;
    state = state.copyWith(
      buckets: state.buckets.map((b) {
        if (b.id != bucketId) return b;
        final newCount = (b.count + countDelta).clamp(0, 1 << 31);
        String? newCoverId = b.coverId;
        if (countDelta < 0 && b.coverId == photoId) {
          // 删的是封面：推进到该相册剩余第一张（state.photos 按排序原序）
          final remaining = state.photos
              .where((p) => p.bucketId == bucketId && p.id != photoId)
              .toList();
          newCoverId = remaining.isEmpty ? null : remaining.first.id;
        }
        return MsBucket(
          id: b.id,
          name: b.name,
          count: newCount,
          dateCreatedMs: b.dateCreatedMs,
          dateModifiedMs: b.dateModifiedMs,
          coverId: newCoverId,
        );
      }).toList(),
    );
  }

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
      // 本地同步首页相册列表（count-1 + 封面推进）——删除可发生在回收站
      // 视图（bucketId 为 null），用 state.photos 里该照片定位相册。
      _applyBucketDelta(id, countDelta: -1);
      state = state.copyWith(
        photos: state.photos.where((p) => p.id != id).toList(),
      );
      // 重查相册列表校准（count 递减 + 封面推进到下一张）。
      await loadBuckets();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // ───────────────────────── 批量操作 ─────────────────────────

  /// 批量移入回收站（一次系统弹窗确认全部）。
  /// 成功后本地移除全部 + 清缓存 + 重查相册列表。返回 null 成功，否则错误信息。
  Future<String?> trashPhotos(List<String> ids) async {
    if (ids.isEmpty) return null;
    try {
      await _channel.requestTrash(ids);
      for (final id in ids) {
        evictImageCache(id);
      }
      _applyBucketDeltaBatch(ids, countDelta: -1);
      state = state.copyWith(
        photos: state.photos.where((p) => !ids.contains(p.id)).toList(),
      );
      await loadBuckets();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 批量从回收站恢复。成功后本地移除 + 清缓存 + 重查相册列表。
  Future<String?> restorePhotos(List<String> ids) async {
    if (ids.isEmpty) return null;
    try {
      await _channel.requestRestore(ids);
      for (final id in ids) {
        evictImageCache(id);
      }
      _applyBucketDeltaBatch(ids, countDelta: 1);
      state = state.copyWith(
        photos: state.photos.where((p) => !ids.contains(p.id)).toList(),
      );
      await loadBuckets();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 批量彻底删除（回收站视图）。
  /// requestDelete 后逐个 exists 二次确认（防御 ROM 误报）：确认已消失的
  /// 本地移除；仍有残留的保留。全部残留时返回 delete_failed。
  Future<String?> deletePhotos(List<String> ids) async {
    if (ids.isEmpty) return null;
    try {
      await _channel.requestDelete(ids);
      final gone = <String>[];
      final stuck = <String>[];
      for (final id in ids) {
        if (await _channel.exists(id)) {
          stuck.add(id);
        } else {
          gone.add(id);
        }
      }
      if (gone.isEmpty) return 'delete_failed';
      for (final id in gone) {
        evictImageCache(id);
      }
      _applyBucketDeltaBatch(gone, countDelta: -1);
      state = state.copyWith(
        photos: state.photos.where((p) => !gone.contains(p.id)).toList(),
      );
      await loadBuckets();
      return stuck.isEmpty ? null : 'delete_failed';
    } catch (e) {
      return e.toString();
    }
  }

  /// 批量设置收藏状态（乐观更新，失败回滚——批量取消收藏时全部原值一致，
  /// 回滚为取反即可）。
  Future<String?> setFavorites(List<String> ids, bool favorite) async {
    if (ids.isEmpty) return null;
    final idSet = ids.toSet();
    state = state.copyWith(
      photos: state.photos
          .map((p) => idSet.contains(p.id) ? _copyWithFavorite(p, favorite) : p)
          .toList(),
    );
    try {
      await _channel.requestFavorite(ids, favorite);
      return null;
    } catch (e) {
      // 回滚
      state = state.copyWith(
        photos: state.photos
            .map((p) =>
                idSet.contains(p.id) ? _copyWithFavorite(p, !favorite) : p)
            .toList(),
      );
      return e.toString();
    }
  }

  // ───────────────────────── 复制 / 移至相册 / 重命名 ─────────────────────────

  /// 批量移至指定相册（getBucketRelativePath 解析目标 → requestMove 改
  /// RELATIVE_PATH）。成功后本地移除 + 清缓存 + 重查相册列表。
  /// 返回 null 成功；'move_failed' / 'move_cancelled' 失败。
  Future<String?> movePhotosToAlbum(List<String> ids, String bucketId) async {
    if (ids.isEmpty) return null;
    try {
      final rel = await _channel.getBucketRelativePath(bucketId);
      if (rel == null || rel.isEmpty) return 'move_failed';
      final n = await _channel.requestMove(ids, rel);
      if (n <= 0) return 'move_cancelled';
      for (final id in ids) {
        evictImageCache(id);
      }
      // 先同步桶数（需 photos 定位所属相册），再移除本地列表。
      _applyBucketDeltaBatch(ids, countDelta: -1);
      state = state.copyWith(
        photos: state.photos.where((p) => !ids.contains(p.id)).toList(),
      );
      await loadBuckets();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 批量复制到指定相册（insert 新条目 + 流拷贝，零弹窗；同名自动加 " (1)"）。
  /// 原图不动（本地列表不移除），重查相册列表刷新目标桶 count。
  /// 返回 null 成功；'copy_failed' 失败。
  Future<String?> copyPhotosToAlbum(List<String> ids, String bucketId) async {
    if (ids.isEmpty) return null;
    try {
      final rel = await _channel.getBucketRelativePath(bucketId);
      if (rel == null || rel.isEmpty) return 'copy_failed';
      final n = await _channel.requestCopy(ids, rel);
      if (n <= 0) return 'copy_failed';
      await loadBuckets();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// 重命名单张（update DISPLAY_NAME）。同名抛 MsException(nameExists)
  /// 由调用方转 toast；成功后本地回填 name（_ID 不变，uri/缩略图缓存仍有效）。
  Future<String?> renamePhoto(String id, String newName) async {
    try {
      final n = await _channel.requestRename(id, newName);
      if (n <= 0) return 'rename_cancelled';
      state = state.copyWith(
        photos: state.photos
            .map((p) => p.id == id ? p.copyWith(name: newName) : p)
            .toList(),
      );
      return null;
    } on MsException catch (e) {
      // 同名冲突等类型化错误：原样透传 code 名，UI 层直接当 i18n key
      return e.code.name;
    } catch (e) {
      return e.toString();
    }
  }

  /// 批量删除/恢复后本地同步首页相册列表（按桶聚合 count 增减、删封面时
  /// 从剩余照片推进到下一张）。必须在移除 state.photos 之前调用。
  void _applyBucketDeltaBatch(List<String> ids, {required int countDelta}) {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    // 从 state.photos 定位每个 id 所属相册，按桶聚合 delta
    final bucketDeltas = <String, int>{};
    for (final p in state.photos) {
      if (idSet.contains(p.id)) {
        bucketDeltas[p.bucketId] =
            (bucketDeltas[p.bucketId] ?? 0) + countDelta;
      }
    }
    // 兜底：photos 里全找不到（罕见，observer 已移除）时退到当前桶
    if (bucketDeltas.isEmpty && state.bucketId != null) {
      bucketDeltas[state.bucketId!] = countDelta * ids.length;
    }
    if (bucketDeltas.isEmpty) return;
    state = state.copyWith(
      buckets: state.buckets.map((b) {
        final delta = bucketDeltas[b.id];
        if (delta == null) return b;
        final newCount = (b.count + delta).clamp(0, 1 << 31);
        String? newCoverId = b.coverId;
        if (countDelta < 0 &&
            b.coverId != null &&
            idSet.contains(b.coverId)) {
          // 删的是封面：推进到该相册剩余第一张（state.photos 按排序原序）
          final remaining = state.photos
              .where((p) => p.bucketId == b.id && !idSet.contains(p.id))
              .toList();
          newCoverId = remaining.isEmpty ? null : remaining.first.id;
        }
        return MsBucket(
          id: b.id,
          name: b.name,
          count: newCount,
          dateCreatedMs: b.dateCreatedMs,
          dateModifiedMs: b.dateModifiedMs,
          coverId: newCoverId,
        );
      }).toList(),
    );
  }

  // ───────────────────────── ContentObserver 刷新 ─────────────────────────

  /// MediaStore 发生变更时静默刷新当前视图（相册列表或相册内）。
  /// 不触发 loading 闪烁；分页进行中则跳过避免打断。
  void _onMediaStoreChanged(MsChangeEvent event) {
    if (state.loadingMore) return;
    switch (event.type) {
      case MsChangeType.delete:
        // 精准删除：从当前列表移除该 id（仅当它在当前视图）
        final id = event.id;
        if (id != null && state.photos.any((p) => p.id == id)) {
          state = state.copyWith(
            photos: state.photos.where((p) => p.id != id).toList(),
            buckets: state.buckets
                .map((b) => b.id == state.bucketId && b.count > 0
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
        } else if (state.view == GalleryView.albums) {
          // 首页收到 item 删除 → 静默重查相册数
          loadBuckets(silent: true);
        }
        break;
      case MsChangeType.insert:
      case MsChangeType.update:
      case MsChangeType.refresh:
        // 新增/修改/兜底：按当前视图(单一枚举)重载对应第一页/相册数
        switch (state.view) {
          case GalleryView.favorites:
            enterFavorites(silent: true);
          case GalleryView.trash:
            enterTrash(silent: true);
          case GalleryView.bucket:
            final id = state.bucketId;
            if (id != null) enterBucket(id, silent: true);
          case GalleryView.albums:
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
