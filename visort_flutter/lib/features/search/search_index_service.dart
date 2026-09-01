// 智能识别索引服务 —— 搜索页多维度分类的数据源与进度载体
//
// [aves 对齐] Aves 的 CollectionFilter 体系按日期/地点/相册/格式过滤,
// 其数据底座是全量条目 EXIF 元数据缓存;visort 的照片数据源是
// MediaStore(无 DATE_TAKEN/GPS 列),本服务补齐该底座:
//   - 开启「智能识别索引」后后台分批扫描全部照片,每批一次 EXIF pass
//     经 Kotlin `indexSearchMeta` 同时提取拍摄时间/GPS/相机
//     (读文件头,单张几 ms,不卡主线程);
//   - 地名解析随索引恒开(2026-09 地点识别分开关并入总开关):批次内
//     新坐标(0.02° 网格去重,Kotlin 侧仅缓存成功结果)经 `geocodePlaces`
//     反地理编码为国家/省/市地名([aves 对齐] Aves GeocodingHandler 的
//     系统 Geocoder 方案);Geocoder 暂时不可用(无网/服务未就绪)时字段
//     为 null 且不落缓存,搜索页数据就绪后经 [resolvePendingPlaces]
//     惰性补解析,无地名时降级坐标分组;
//   - 产物写 SQLite `search_index` 表(SearchIndexStore),冷启动恢复;
//     进度(done/total)持久化 SharedPreferences,设置页轮询展示;
//   - 关闭总开关清空表([ente 对齐] ENTE 关 ML 清库语义)。
// 索引表只是 id → EXIF 富化缓存:照片本体增删以 MediaStore 为准,
// 残留行按 id 查不到自然失效;新增照片由 [syncNewPhotos] 前台增量
// 对账补录([precache 对齐] 缩略图缓存「前台增量」模式,2026-09)。
//
// 历史:v1(已移除)只索引 GPS 存 SharedPreferences('ml_locations'),
// 搜索页位置分类只能按坐标网格分组;v2 扩展为多维度并迁 SQLite,
// 旧 SP 键在 [load] 时清理。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visort_flutter/core/db/database_service.dart';
import 'package:visort_flutter/core/db/search_index_store.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

/// 全量照片分页拉取（空 bucketIds = 全部相册；Kotlin 侧查询已显式排除
/// 回收站项）。搜索页与索引服务共用——全库扫描只做一次。
Future<List<MsImageInfo>> scanAllImages(MediaStoreChannel channel) async {
  final out = <MsImageInfo>[];
  var cursor = '';
  while (true) {
    final page = await channel.scanImages(
      const [],
      afterCursor: cursor.isEmpty ? null : cursor,
      limit: 500,
    );
    out.addAll(page.images);
    if (page.nextCursor == null || page.nextCursor!.isEmpty) break;
    cursor = page.nextCursor!;
  }
  return out;
}

/// 索引运行态（设置页「智能识别」区与搜索页 banner 共用）。
class SearchIndexState {
  const SearchIndexState({
    this.running = false,
    this.processed = 0,
    this.total = 0,
  });

  final bool running;

  /// EXIF pass 进度分子（已处理照片数）。
  final int processed;
  final int total;

  /// 是否已完整跑过一轮（total>0 且全处理）。
  bool get done => total > 0 && processed >= total;
}

/// 搜索索引 store(单例,服务与测试共用)。
final searchIndexStoreProvider = Provider<SearchIndexStore>(
  (ref) => SearchIndexStore(ref.watch(databaseServiceProvider).database),
);

/// 智能识别索引服务：全库扫描 + EXIF 提取 + 地名解析 + SQLite 落盘。
final searchIndexServiceProvider =
    NotifierProvider<SearchIndexService, SearchIndexState>(
        SearchIndexService.new);

class SearchIndexService extends Notifier<SearchIndexState> {
  static const _kProgressKey = 'search_index_progress';
  // v1 遗留键(纯 GPS 时代),load 时清理。
  static const _kLegacyKeys = ['ml_locations', 'ml_index_progress'];
  static const _kBatchSize = 300;

  /// 地名坐标去重网格(度),与 Kotlin geocodePlaces 一致。
  static const _kGeocodeGrid = 0.02;

  final MediaStoreChannel _channel = const MediaStoreChannel();
  Map<String, MsSearchMeta> _metas = const {};
  bool _cancel = false;

  /// id → 索引元数据（启动时 [load] 恢复；索引完成后更新）。
  Map<String, MsSearchMeta> get metas => _metas;

  @override
  SearchIndexState build() => const SearchIndexState();

  SearchIndexStore get _store => ref.read(searchIndexStoreProvider);

  /// 启动/切页时从 SQLite 恢复索引与进度（设置页、搜索页 initState 调）。
  /// 保留 running 态：索引循环跑批中进搜索页会触发 load，若把 running
  /// 覆写为 false，搜索页自愈逻辑会并发拉起第二个 start()（双循环并发，
  /// 子代理审查 P1）。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // v1 SP 数据迁移清理:数据不可比(EXIF pass 会产出更全字段),直接弃。
    for (final k in _kLegacyKeys) {
      await prefs.remove(k);
    }
    _metas = await _store.loadAll();
    debugPrint('[SIDX] load: metas=${_metas.length}');
    final prog = prefs.getString(_kProgressKey);
    if (prog != null) {
      final parts = prog.split('/');
      if (parts.length == 2) {
        state = SearchIndexState(
          running: state.running,
          processed: int.tryParse(parts[0]) ?? 0,
          total: int.tryParse(parts[1]) ?? 0,
        );
      }
    } else if (_metas.isNotEmpty) {
      // 无进度但表有数据(异常中断/清进度):按行数近似恢复,允许复用。
      state = SearchIndexState(
        running: state.running,
        processed: _metas.length,
        total: _metas.length,
      );
    }
  }

  /// 开启索引：全量扫描提取 EXIF + 地名解析（随总开关恒开）。
  /// 已完整跑过一轮且表非空时直接复用（增量重建留待后续版本）。
  Future<void> start() async {
    debugPrint('[SIDX] start enter: running=${state.running} '
        'done=${state.done} metas=${_metas.length} cancel=$_cancel');
    if (state.running) return;
    if (state.done && _metas.isNotEmpty) return;
    state = const SearchIndexState(running: true);
    _cancel = false;
    try {
      // ACCESS_MEDIA_LOCATION（Android 10+ 未授权时系统剥离 MediaStore
      // 流的 EXIF GPS——真机实证：pm clear 撤销后索引 0 坐标）。跟随
      // 「智能识图索引」总开关在开跑前申请一次（用户定稿：地点识别子
      // 开关不单独触发权限弹窗）；拒绝则照常索引（地点维度无数据，
      // 不阻塞其余维度）。
      try {
        await _channel.requestAccessMediaLocation();
      } catch (_) {
        // 无 Activity/失败不阻塞索引
      }
      final photos = await scanAllImages(_channel);
      debugPrint('[SIDX] scanned ${photos.length} photos');
      final total = photos.length;
      final metas = <String, MsSearchMeta>{};
      var done = 0;
      for (var i = 0; i < total; i += _kBatchSize) {
        if (_cancel) return;
        final batch =
            photos.skip(i).take(_kBatchSize).map((p) => p.id).toList();
        final r = await _channel.indexSearchMeta(batch);
        debugPrint('[SIDX] batch $i: meta=${r.length}');
        if (_cancel) return; // 清库竞态：关开关后不再写
        var batchOut = r.values.toList();
        // 地名解析随索引恒开（用户定稿：地点识别开关已并入总开关）。
        batchOut = await _resolvePlaces(batchOut);
        // _resolvePlaces 是长 await（Kotlin 串行 geocode，首批可达数十秒），
        // 其后必须复查 cancel：关开关已 clear() 时继续执行会把该批写回
        // 已清空的表并覆写 state/进度 SP（清库复活，子代理审查 P1）。
        if (_cancel) return;
        for (final m in batchOut) {
          metas[m.id] = m;
        }
        await _store.putAll(batchOut);
        if (_cancel) return; // putAll 同为 async gap，落地后复查
        done += batch.length;
        state = SearchIndexState(
          running: true,
          processed: done,
          total: total,
        );
        await _saveProgress(done, total);
      }
      _metas = metas;
      debugPrint('[SIDX] finished: rows=${metas.length}');
    } catch (e, s) {
      // 不 rethrow：调用方（设置页 unawaited / 搜索页 .then）均无 catch，
      // rethrow 会成 unhandled async exception（子代理审查 P3）。
      debugPrint('[SIDX] FAILED: $e\n$s');
    } finally {
      if (!_cancel) {
        state = SearchIndexState(
          processed: state.processed,
          total: state.total,
        );
      }
      debugPrint('[SIDX] finally: $_cancel state=${state.processed}/${state.total}');
    }
  }

  /// 前台增量对账（[precache 对齐] 缩略图缓存「前台增量」同款模式）：
  /// MediaStore 实时列表与索引表的 id 差集 → 新照片补一轮 EXIF+地名
  /// 解析 → 落库合并。搜索页每次数据就绪后调用（开关开启时）；空差集
  /// 一趟 Set 扫描零成本，有新增则分批秒级补录——根治「新增照片不入
  /// 索引」（此前 start() 首轮 done 后永久早退，唯一出路开关重开）。
  ///
  /// 设计边界：首轮全量仍由开关驱动（done/SP 进度语义不动，只表达
  /// 首轮）；首轮跑批中跳过（循环自身覆盖全库，跑批中新导入的照片由
  /// 下次进页补）；删除方向不清表——残留行按 id 查不到自然失效（表
  /// 量级小，惰性失效已足够）。
  Future<void> syncNewPhotos(List<MsImageInfo> photos) async {
    if (state.running) return;
    final known = _metas.keys.toSet();
    final fresh =
        photos.where((p) => !known.contains(p.id)).map((p) => p.id).toList();
    if (fresh.isEmpty) return;
    debugPrint('[SIDX] syncNewPhotos: ${fresh.length} new');
    _cancel = false;
    final out = <MsSearchMeta>[];
    for (var i = 0; i < fresh.length; i += _kBatchSize) {
      if (_cancel) return;
      final batch = fresh.skip(i).take(_kBatchSize).toList();
      final r = await _channel.indexSearchMeta(batch);
      if (_cancel) return;
      var batchOut = r.values.toList();
      batchOut = await _resolvePlaces(batchOut);
      if (_cancel) return;
      await _store.putAll(batchOut);
      if (_cancel) return;
      out.addAll(batchOut);
    }
    for (final m in out) {
      _metas[m.id] = m;
    }
    debugPrint('[SIDX] syncNewPhotos done: +${out.length}');
  }

  /// 惰性补解析：首索引时无网/Geocoder 异常的行（有坐标但地名三元组
  /// 空）原本无恢复路径（补轮已随地点识别开关移除；Kotlin 侧失败已不
  /// 落缓存）。搜索页数据就绪后调用：pending 为空时 no-op（一趟 where
  /// 扫描），有则分批补 geocode 落库，通知方刷新分组。
  Future<void> resolvePendingPlaces() async {
    if (state.running) return;
    final pending = _metas.values
        .where((m) => m.lat != null && m.lng != null && m.placeLabel.isEmpty)
        .toList();
    if (pending.isEmpty) return;
    debugPrint('[SIDX] resolvePendingPlaces: ${pending.length}');
    _cancel = false;
    for (var i = 0; i < pending.length; i += _kBatchSize) {
      if (_cancel) return;
      final chunk = pending.skip(i).take(_kBatchSize).toList();
      final resolved = await _resolvePlaces(chunk);
      if (_cancel) return;
      await _store.putAll(resolved);
      if (_cancel) return;
      for (final m in resolved) {
        _metas[m.id] = m;
      }
    }
    debugPrint('[SIDX] resolvePendingPlaces done');
  }

  /// 批内地名解析:收集批内新坐标(0.02° 网格键去重)→ geocodePlaces →
  /// 填回各条目。同网格多张照片共享一次 Geocoder 调用(Kotlin 侧还有
  /// 跨批缓存,这里去重只为省通道数据量)。
  Future<List<MsSearchMeta>> _resolvePlaces(List<MsSearchMeta> batch) async {
    final needs = <String, (double, double)>{};
    for (final m in batch) {
      final lat = m.lat, lng = m.lng;
      if (lat == null || lng == null || m.placeLabel.isNotEmpty) continue;
      final key = '${(lat / _kGeocodeGrid).round()}:${(lng / _kGeocodeGrid).round()}';
      needs.putIfAbsent(key, () => (lat, lng));
    }
    if (needs.isEmpty) return batch;
    try {
      final places = await _channel
          .geocodePlaces(needs.values.map((e) => [e.$1, e.$2]).toList());
      final byKey = <String, MsSearchMeta>{};
      var j = 0;
      for (final key in needs.keys) {
        byKey[key] = j < places.length
            ? MsSearchMeta(
                id: key,
                country: places[j].country,
                adminArea: places[j].adminArea,
                locality: places[j].locality,
              )
            : const MsSearchMeta(id: '');
        j++;
      }
      return batch.map((m) {
        final lat = m.lat, lng = m.lng;
        if (lat == null || lng == null || m.placeLabel.isNotEmpty) return m;
        final key =
            '${(lat / _kGeocodeGrid).round()}:${(lng / _kGeocodeGrid).round()}';
        final place = byKey[key];
        if (place == null ||
            (place.country == null &&
                place.adminArea == null &&
                place.locality == null)) {
          return m; // Geocoder 无结果:保留坐标,搜索页降级坐标分组
        }
        return MsSearchMeta(
          id: m.id,
          dateTakenMs: m.dateTakenMs,
          lat: lat,
          lng: lng,
          camera: m.camera,
          country: place.country,
          adminArea: place.adminArea,
          locality: place.locality,
        );
      }).toList();
    } catch (_) {
      return batch; // geocode 整批失败:坐标照存,地名后续可补
    }
  }

  /// 取消当前索引（开关关闭时先 cancel 再 clear，避免清完又被写回）。
  void cancel() => _cancel = true;

  /// 关闭索引：清空索引表与进度（[ente 对齐] 关 ML 清库语义）。
  Future<void> clear() async {
    _cancel = true;
    _metas = const {};
    await _store.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kProgressKey);
    state = const SearchIndexState();
  }

  Future<void> _saveProgress(int done, int total) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProgressKey, '$done/$total');
  }
}
