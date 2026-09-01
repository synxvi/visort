// 搜索页数据底座 —— 与页面生命周期解耦的全量数据 + 分组缓存
//
// [用户定稿] 提前渲染好、进页零加载：搜索页是 push route，此前每次
// 进页 initState 现拉 MediaStore 全量 → setState 渲染 chips，页面销毁
// 全丢。所有「入场闪烁」的本质都是这一帧从空到满的布局变化与键盘
// /转场动画撞车（[KBD] 打点实证：route 双扫、HDR 回填、入场帧 y 跳变
// 全部落在此窗口）。解法是把数据就绪与进页解耦：
//   - app 启动 idle 预热（相册首屏稳定后，快照缓存下 ~50ms 无感）；
//   - 搜索页首帧直接读现成 state——零入场 setState；
//   - 进页/返回后后台对账（新增/删除照片），无差异零 setState；
//   - HDR 结果（detectHdrs，Kotlin mtime 缓存）与索引增量
//     （syncNewPhotos/resolvePendingPlaces）完成后的分组刷新都在
//     store 层合并，页面只 watch。
// UI 态（选中 chips/展开区/文本）留在页面；「日期选择器」的 picked
// chips 由页面合并（见 SearchScreen._picked）。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visort_flutter/core/config/models.dart' show SortBy;
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/features/search/search_index_service.dart';
import 'package:visort_flutter/ui/screens/search_filter_chip.dart';

/// 坐标兜底网格精度（度）：0.01° ≈ 1.1km（与页面 v1 行为一致）。
const double _kPlaceGrid = 0.01;

/// RAW 私有 mime 尾段标记。
const List<String> _kRawMarkers = [
  'dng', 'cr2', 'nef', 'arw', 'rw2', 'orf', 'raw',
];

bool _isRawMime(String mime) {
  final last = mime.split('/').last.toLowerCase();
  return _kRawMarkers.any(last.contains);
}

class _Group {
  const _Group(this.key, this.label, this.photos);
  final String key;
  final String label;
  final List<MsImageInfo> photos;
}

/// 搜索页常驻数据（photos/buckets/分组产物 filters/HDR 集）。
class SearchDataState {
  const SearchDataState({
    this.photos = const [],
    this.buckets = const [],
    this.filters = const {},
    this.hdrIds = const {},
    this.ready = false,
  });

  final List<MsImageInfo> photos;
  final List<MsBucket> buckets;

  /// 全量可选 chips（key → 定义），分组产物。
  final Map<String, SearchFilterData> filters;

  /// JPEG HDR 检测结果（id 集）。
  final Set<String> hdrIds;

  /// 首载完成（空库也算完成——只是没有 chips）。
  final bool ready;

  /// bucketId → 相册名。
  Map<String, String> get bucketNames =>
      {for (final b in buckets) b.id: b.name};
}

/// 搜索数据 store（单例）。页面与预热方共用。
final searchDataProvider =
    NotifierProvider<SearchDataNotifier, SearchDataState>(SearchDataNotifier.new);

class SearchDataNotifier extends Notifier<SearchDataState> {
  final MediaStoreChannel _channel = const MediaStoreChannel();
  bool _loading = false;

  /// HDR 持久化 key（id 逗号串）：Kotlin detectHdrs 的 mtime 缓存是进程
  /// 内存，冷启动清空 → 全量 JPEG 重读文件头数百 ms，HDR chip 迟到
  /// （用户实测「第一次进搜索页 HDR 不在，过会才出现」）。冷启动先
  /// 用上次结果秒渲染，后台检测校准（无差异零 setState）。
  static const _kHdrPrefsKey = 'search_hdr_ids';

  Future<Set<String>> _loadPersistedHdr() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHdrPrefsKey);
      if (raw == null || raw.isEmpty) return const {};
      return raw.split(',').toSet();
    } catch (_) {
      return const {};
    }
  }

  Future<void> _persistHdr(Set<String> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHdrPrefsKey, ids.join(','));
    } catch (_) {}
  }

  @override
  SearchDataState build() {
    // 语言切换 → 分组 label 重建（tr() 用全局 override，UI 的 t() 平时
    // 顺带同步；此处显式同步并监听，预热早于首个 UI build 也不缓存错
    // 语言的 label）。
    syncLang(ref.read(currentLanguageProvider));
    ref.listen(currentLanguageProvider, (prev, next) {
      if (state.ready && prev != next) rebuildFilters();
    });
    return const SearchDataState();
  }

  /// 幂等首载 + 进页对账：未就绪先全量扫（预热调过则秒回），就绪后
  /// 对账 MediaStore 实时列表，无差异零成本返回。
  Future<void> warmUp() async {
    if (_loading) return;
    _loading = true;
    try {
      if (!state.ready) {
        final photos = await scanAllImages(_channel);
        final buckets = await _channel.listBuckets();
        // HDR 上次结果先恢复（首帧 HDR chip 即在）；后台真检测校准。
        final persistedHdr = await _loadPersistedHdr();
        state = SearchDataState(
          photos: photos,
          buckets: buckets,
          hdrIds: persistedHdr,
          ready: true,
        );
        debugPrint('[SDS] first load: ${photos.length} photos, '
            'persisted hdr=${persistedHdr.length}');
        rebuildFilters();
        unawaited(_detectHdr());
        _syncIndex(photos);
        return;
      }
      // 对账：id 集与数量都未变则零 setState（进页高频路径）。
      final photos = await scanAllImages(_channel);
      final oldIds = {for (final p in state.photos) p.id};
      final newIds = {for (final p in photos) p.id};
      if (oldIds.length == newIds.length && oldIds.containsAll(newIds)) {
        debugPrint('[SDS] warmUp: unchanged');
        _syncIndex(photos);
        return;
      }
      final buckets = await _channel.listBuckets();
      state = SearchDataState(
        photos: photos,
        buckets: buckets,
        hdrIds: state.hdrIds,
        ready: true,
      );
      debugPrint('[SDS] warmUp: ${photos.length} photos (changed)');
      rebuildFilters();
      _syncIndex(photos);
    } catch (e) {
      debugPrint('[SDS] warmUp FAILED: $e');
    } finally {
      _loading = false;
    }
  }

  /// 索引恢复 + 增量对账 + 惰性补地名，完成后刷新分组。
  Future<void> _syncIndex(List<MsImageInfo> photos) async {
    final notifier = ref.read(searchIndexServiceProvider.notifier);
    await notifier.load();
    if (!ref.read(configProvider).mlIndexEnabled) return;
    await notifier.syncNewPhotos(photos);
    await notifier.resolvePendingPlaces();
    rebuildFilters();
  }

  /// HDR 检测（后台，mtime 缓存命中时 8ms）：结果只记 hdrIds 字段——
  /// 不换 photos 数组实例（整列表重建 = 全 chips 重建风暴，入场闪烁
  /// 根源之一，实证见 search_screen 历史）。
  Future<void> _detectHdr() async {
    final jpegs =
        state.photos.where((p) => p.mime == 'image/jpeg').toList();
    if (jpegs.isEmpty) return;
    try {
      final hdrs = await _channel.detectHdrs(
        jpegs.map((p) => p.id).toList(),
        jpegs.map((p) => p.dateModifiedMs).toList(),
        jpegs.map((p) => p.mime).toList(),
      );
      final hdrIds = <String>{};
      for (var i = 0; i < jpegs.length && i < hdrs.length; i++) {
        if (hdrs[i]) hdrIds.add(jpegs[i].id);
      }
      // 校准结果落盘（下次冷启动秒渲染）；与恢复值相同则零 setState。
      unawaited(_persistHdr(hdrIds));
      if (hdrIds.length == state.hdrIds.length &&
          hdrIds.containsAll(state.hdrIds)) {
        return;
      }
      debugPrint('[SDS] hdr: ${hdrIds.length}');
      state = SearchDataState(
        photos: state.photos,
        buckets: state.buckets,
        filters: state.filters,
        hdrIds: hdrIds,
        ready: true,
      );
      rebuildFilters();
    } catch (_) {
      // HDR 检测失败不阻塞（chip 缺席可接受）
    }
  }

  // ──────────── 分组（原 SearchScreen._rebuildGroups 平移）────────────

  /// 五维度分组重建。数据源：photos + 索引 metas + hdrIds + 相册排序
  /// 偏好。产物换新 filters map（页面 watch 后重渲染）。
  void rebuildFilters() {
    final photos = state.photos;
    final hdrIds = state.hdrIds;
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;

    // 日期（[aves 对齐] DateFilter 跨年聚合，注册序 = 显示序）。
    final byMonth = <int, List<MsImageInfo>>{};
    final byWeekday = <int, List<MsImageInfo>>{};
    final recentIds = <String>{};
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    for (final p in photos) {
      if (p.dateAddedMs > 0 &&
          DateTime.fromMillisecondsSinceEpoch(p.dateAddedMs)
              .isAfter(weekAgo)) {
        recentIds.add(p.id);
      }
      final taken = metas[p.id]?.dateTakenMs ?? p.dateAddedMs;
      if (taken <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(taken);
      byMonth.putIfAbsent(dt.month, () => []).add(p);
      byWeekday.putIfAbsent(dt.weekday, () => []).add(p);
    }
    final monthFmt = tr('search_month_only');
    final weekdayNames = tr('search_weekday_names').split(',');
    final monthGroups = [
      for (var m = 1; m <= 12; m++)
        if (byMonth.containsKey(m))
          _Group('$m', monthFmt.replaceFirst('{m}', '$m'), byMonth[m]!),
    ];
    final weekdayGroups = [
      for (var d = 1; d <= 7; d++)
        if (byWeekday.containsKey(d))
          _Group('$d', weekdayNames[d - 1], byWeekday[d]!),
    ];

    // 地点：城市名分组；无名有坐标 → 网格兜底。
    final places = <String, _Group>{};
    final coordBuckets = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      final m = metas[p.id];
      if (m == null) continue;
      final label = m.placeLabel;
      if (label.isNotEmpty) {
        final key = '${m.country}|${m.adminArea}|${m.locality}';
        places.putIfAbsent(key, () => _Group(key, label, [])).photos.add(p);
      } else if (m.lat != null && m.lng != null) {
        final lat = (m.lat! / _kPlaceGrid).roundToDouble() * _kPlaceGrid;
        final lng = (m.lng! / _kPlaceGrid).roundToDouble() * _kPlaceGrid;
        coordBuckets.putIfAbsent('$lat,$lng', () => []).add(p);
      }
    }
    final placeList = places.values.toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));
    for (final e in coordBuckets.entries) {
      final parts = e.key.split(',');
      placeList.add(_Group(
        e.key,
        '${_fmtCoord(parts[0])}, ${_fmtCoord(parts[1])}',
        e.value,
      ));
    }
    placeList.sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 相册：bucketId 分组，排序跟相册页偏好，空名兜底「根目录」。
    final albums = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      albums.putIfAbsent(p.bucketId, () => []).add(p);
    }
    final cfg = ref.read(configProvider);
    final names = state.bucketNames;
    final bucketById = {for (final b in state.buckets) b.id: b};
    String albumLabel(String id) =>
        (names[id]?.isNotEmpty ?? false) ? names[id]! : tr('root_dir');
    int albumCmp(_Group a, _Group b) {
      final ba = bucketById[a.key];
      final bb = bucketById[b.key];
      int cmp;
      switch (cfg.albumSortBy) {
        case SortBy.name:
          cmp = albumLabel(a.key)
              .toLowerCase()
              .compareTo(albumLabel(b.key).toLowerCase());
          break;
        case SortBy.dateCreated:
        case SortBy.dateTrashed:
          cmp = (ba?.dateCreatedMs ?? 0).compareTo(bb?.dateCreatedMs ?? 0);
          break;
        case SortBy.dateModified:
          cmp = (ba?.dateModifiedMs ?? 0).compareTo(bb?.dateModifiedMs ?? 0);
          break;
      }
      return cfg.albumSortAsc ? cmp : -cmp;
    }
    final albumList = albums.entries
        .map((e) => _Group(e.key, albumLabel(e.key), e.value))
        .toList()
      ..sort(albumCmp);

    // 文件类型：mime 分组。
    final types = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      types.putIfAbsent(p.mime, () => []).add(p);
    }
    final typeList = types.entries
        .map((e) => _Group(e.key, _mimeLabel(e.key), e.value))
        .toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 拍摄设备。
    final cameras = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      final cam = metas[p.id]?.camera;
      if (cam != null && cam.isNotEmpty) {
        cameras.putIfAbsent(cam, () => []).add(p);
      }
    }
    final cameraList = cameras.entries
        .map((e) => _Group(e.key, e.key, e.value))
        .toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 省份。
    final provinces = <String, _Group>{};
    for (final p in photos) {
      final m = metas[p.id];
      if (m == null) continue;
      final area = m.adminArea;
      if (area == null || area.isEmpty) continue;
      final key = '${m.country}|$area';
      provinces.putIfAbsent(key, () => _Group(key, area, [])).photos.add(p);
    }
    final provinceList = provinces.values.toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 元数据（负向过滤）：仅当库内存在对应正向数据时才露出。
    int takenMs(MsImageInfo p) => metas[p.id]?.dateTakenMs ?? 0;
    bool hasLoc(MsImageInfo p) =>
        metas[p.id]?.lat != null && metas[p.id]?.lng != null;
    final hasAnyDate = photos.any((p) => takenMs(p) > 0);
    final hasAnyLoc = photos.any(hasLoc);
    final hasAnyCamera =
        photos.any((p) => (metas[p.id]?.camera ?? '').isNotEmpty);
    final missingDateIds = hasAnyDate
        ? photos.where((p) => takenMs(p) <= 0).map((p) => p.id).toSet()
        : <String>{};
    final unlocatedIds = hasAnyLoc
        ? photos.where((p) => !hasLoc(p)).map((p) => p.id).toSet()
        : <String>{};
    final noCameraIds = hasAnyCamera
        ? photos
            .where((p) => (metas[p.id]?.camera ?? '').isEmpty)
            .map((p) => p.id)
            .toSet()
        : <String>{};

    SearchFilterData f(_Group g, String cat, IconData icon) =>
        SearchFilterData(
          key: '$cat:${g.key}',
          label: g.label,
          category: cat,
          icon: icon,
          ids: g.photos.map((p) => p.id).toSet(),
        );
    bool isPortrait(MsImageInfo p) => p.width > 0 && p.height > p.width;
    bool isLandscape(MsImageInfo p) => p.height > 0 && p.width > p.height;
    final list = <SearchFilterData>[
      SearchFilterData(
        key: 'date:picker',
        label: tr('search_date_picker'),
        category: 'date',
        icon: Icons.edit_calendar_outlined,
        ids: const {},
      ),
      if (recentIds.isNotEmpty)
        SearchFilterData(
          key: 'date:recent',
          label: tr('search_recent'),
          category: 'date',
          icon: Icons.schedule,
          ids: recentIds,
        ),
      for (final g in monthGroups)
        f(g, 'date', Icons.calendar_month_outlined),
      for (final g in weekdayGroups)
        f(g, 'date', Icons.date_range_outlined),
      if (photos.any((p) => p.isFavorite))
        SearchFilterData(
          key: 'quick:fav',
          label: tr('search_favorites'),
          category: 'quick',
          icon: Icons.favorite_outline,
          ids: photos.where((p) => p.isFavorite).map((p) => p.id).toSet(),
        ),
      if (photos.any((p) => p.mime == 'image/gif'))
        SearchFilterData(
          key: 'quick:animated',
          label: tr('search_animated'),
          category: 'quick',
          icon: Icons.animation_outlined,
          ids: photos
              .where((p) => p.mime == 'image/gif')
              .map((p) => p.id)
              .toSet(),
        ),
      if (photos.any(isPortrait))
        SearchFilterData(
          key: 'quick:portrait',
          label: tr('search_portrait'),
          category: 'quick',
          icon: Icons.portrait_outlined,
          ids: photos.where(isPortrait).map((p) => p.id).toSet(),
        ),
      if (photos.any(isLandscape))
        SearchFilterData(
          key: 'quick:landscape',
          label: tr('search_landscape'),
          category: 'quick',
          icon: Icons.crop_16_9_outlined,
          ids: photos.where(isLandscape).map((p) => p.id).toSet(),
        ),
      if (photos.any((p) => hdrIds.contains(p.id)))
        SearchFilterData(
          key: 'quick:hdr',
          label: 'HDR',
          category: 'quick',
          icon: Icons.brightness_high_outlined,
          ids: photos
              .where((p) => hdrIds.contains(p.id))
              .map((p) => p.id)
              .toSet(),
        ),
      if (photos.any((p) => _isRawMime(p.mime)))
        SearchFilterData(
          key: 'quick:raw',
          label: 'RAW',
          category: 'quick',
          icon: Icons.camera_roll_outlined,
          ids: photos
              .where((p) => _isRawMime(p.mime))
              .map((p) => p.id)
              .toSet(),
        ),
      for (final g in provinceList) f(g, 'province', Icons.map_outlined),
      for (final g in placeList) f(g, 'place', Icons.location_on_outlined),
      for (final g in albumList) f(g, 'album', Icons.photo_library_outlined),
      for (final g in typeList) f(g, 'mime', Icons.image_outlined),
      for (final g in cameraList) f(g, 'camera', Icons.photo_camera_outlined),
      if (missingDateIds.isNotEmpty)
        SearchFilterData(
          key: 'meta:nodate',
          label: tr('search_missing_date'),
          category: 'meta',
          icon: Icons.event_busy_outlined,
          ids: missingDateIds,
        ),
      if (unlocatedIds.isNotEmpty)
        SearchFilterData(
          key: 'meta:noloc',
          label: tr('search_unlocated'),
          category: 'meta',
          icon: Icons.location_off_outlined,
          ids: unlocatedIds,
        ),
      if (noCameraIds.isNotEmpty)
        SearchFilterData(
          key: 'meta:nocam',
          label: tr('search_no_camera'),
          category: 'meta',
          icon: Icons.no_photography_outlined,
          ids: noCameraIds,
        ),
    ];

    state = SearchDataState(
      photos: photos,
      buckets: state.buckets,
      filters: {for (final x in list) x.key: x},
      hdrIds: hdrIds,
      ready: true,
    );
  }

  static String _fmtCoord(String s) {
    final d = double.tryParse(s);
    if (d == null) return s;
    return d.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static const _mimeNames = {
    'jpeg': 'JPEG',
    'jpg': 'JPEG',
    'png': 'PNG',
    'gif': 'GIF',
    'webp': 'WebP',
    'heic': 'HEIC',
    'heif': 'HEIF',
    'avif': 'AVIF',
    'bmp': 'BMP',
    'tiff': 'TIFF',
    'tif': 'TIFF',
    'svg+xml': 'SVG',
    'mp4': 'MP4',
    'mpeg': 'MPEG',
    'quicktime': 'MOV',
    '3gpp': '3GP',
  };

  static String _mimeLabel(String mime) {
    if (_isRawMime(mime)) return 'RAW';
    final last = mime.split('/').last.toLowerCase();
    return _mimeNames[last] ?? last.toUpperCase();
  }
}
