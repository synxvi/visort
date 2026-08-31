// ML 位置索引服务 —— 搜索页「位置」分类的数据源与进度载体
//
// [ente 对齐] ENTE 的 ML 是 Rust ONNX 管线（人脸/CLIP embedding）+ 服务端
// 水合，visort 无此基建，落地裁剪为**本地 EXIF GPS 索引**：
//   - 开启总开关后后台分批扫描全部照片（scanImages 分页拉 id），
//     每批 300 张经 Kotlin `indexLocations` 批量读 EXIF GPS（读文件头，
//     单张几 ms，Kotlin ioExecutor 不卡主线程）；
//   - 进度（done/total）与结果（id → [lat, lng]）持久化 SharedPreferences，
//     设置页 ML 区轮询展示「已索引 x / y 张」，搜索页「位置」分类直接读；
//   - 关闭开关清空数据（[ente 对齐] ENTE 关 ML 清库语义）。
// 文件类型分类纯本地不依赖索引。人物识别已移除（本地人脸方案未采用）。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/fs/mediastore_channel.dart';

/// 全量照片分页拉取（空 bucketIds = 全部相册；Kotlin 侧查询已显式排除
/// 回收站项）。搜索页与 ML 索引共用——全库扫描只做一次。
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

/// 索引运行态（设置页 ML 区与搜索页 banner 共用）。
class MlIndexState {
  const MlIndexState({this.running = false, this.processed = 0, this.total = 0});

  final bool running;
  final int processed;
  final int total;

  /// 是否已完整跑过一轮（total>0 且全处理）。
  bool get done => total > 0 && processed >= total;
}

/// ML 索引服务：全库扫描 + EXIF GPS 提取 + 持久化。
final mlIndexServiceProvider =
    NotifierProvider<MlIndexService, MlIndexState>(MlIndexService.new);

class MlIndexService extends Notifier<MlIndexState> {
  static const _kLocationsKey = 'ml_locations';
  static const _kProgressKey = 'ml_index_progress';
  static const _kBatchSize = 300;

  final MediaStoreChannel _channel = const MediaStoreChannel();
  Map<String, List<double>> _locations = const {};
  bool _cancel = false;

  /// id → [lat, lng]（启动时 [load] 恢复；索引完成后更新）。
  Map<String, List<double>> get locations => _locations;

  @override
  MlIndexState build() => const MlIndexState();

  /// 启动/切页时从 SP 恢复索引结果与进度（设置页、搜索页 initState 调）。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLocationsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _locations = decoded.map((k, v) => MapEntry(
            k, (v as List).map((e) => (e as num).toDouble()).toList()));
      } catch (_) {
        // 损坏数据丢弃，下次索引重建
      }
    }
    final prog = prefs.getString(_kProgressKey);
    if (prog != null) {
      final parts = prog.split('/');
      if (parts.length == 2) {
        state = MlIndexState(
          processed: int.tryParse(parts[0]) ?? 0,
          total: int.tryParse(parts[1]) ?? 0,
        );
      }
    }
  }

  /// 开启索引：全量扫描全部照片提取 EXIF GPS（分批跑，进度实时落 SP）。
  /// 已完整跑过一轮时直接复用（照片增删的增量重建留待后续版本）。
  Future<void> start() async {
    if (state.running) return;
    if (state.done && _locations.isNotEmpty) return;
    state = MlIndexState(running: true);
    _cancel = false;
    try {
      final photos = await _scanAll();
      final total = photos.length;
      final locs = <String, List<double>>{};
      var done = 0;
      for (var i = 0; i < total; i += _kBatchSize) {
        if (_cancel) return;
        final batch = photos
            .skip(i)
            .take(_kBatchSize)
            .map((p) => p.id)
            .toList();
        final r = await _channel.indexLocations(batch);
        if (_cancel) return; // 清库竞态：关开关后不再写
        for (var j = 0; j < r.ids.length; j++) {
          locs[r.ids[j]] = [r.lats[j], r.lngs[j]];
        }
        done += batch.length;
        state = MlIndexState(running: true, processed: done, total: total);
        await _saveProgress(done, total);
      }
      _locations = locs;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLocationsKey, jsonEncode(locs));
    } finally {
      if (!_cancel) {
        state = MlIndexState(processed: state.processed, total: state.total);
      }
    }
  }

  /// 全量照片 id 列表（scanAllImages 共享实现，见文件头）。
  Future<List<MsImageInfo>> _scanAll() => scanAllImages(_channel);

  /// 取消当前索引（开关关闭时先 cancel 再 clear，避免清完又被写回）。
  void cancel() => _cancel = true;

  /// 关闭索引：清空位置数据与进度（[ente 对齐] 关 ML 清库语义）。
  Future<void> clear() async {
    _cancel = true;
    _locations = const {};
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLocationsKey);
    await prefs.remove(_kProgressKey);
    state = const MlIndexState();
  }

  Future<void> _saveProgress(int done, int total) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProgressKey, '$done/$total');
  }
}
