// MediaStore 变更事件流 —— 对接 Kotlin 侧 EventChannel（sortr/mediastore-events）
//
// Kotlin 端 ContentObserver 监听 MediaStore.Images 变化，图库增删/扫描完成时
// 通过 EventChannel 推送「结构化事件」（P1c）：{type, id?, bucketId?}。
// type ∈ {refresh, insert, update, delete}：
//   - refresh  → 全量刷新（兜底；旧版 "changed" 字符串也归为此类）
//   - insert   → 新增（DATE_ADDED 距今 <30s）
//   - update   → 修改（如收藏/移动）
//   - delete   → 删除（查询不到行）
// GalleryController 据此做精准增量刷新，而非每次全量重查。
// 移植自 photo_manager PhotoManagerNotifyChannel 的分类启发式。

import 'package:flutter/services.dart';

const _kEventsChannel = 'sortr/mediastore-events';

/// 变更事件类型。
enum MsChangeType { refresh, insert, update, delete }

/// MediaStore 单条变更事件（P1c）。
class MsChangeEvent {
  const MsChangeEvent(this.type, {this.id, this.bucketId});
  final MsChangeType type;

  /// 变更图片的 _ID（insert/update/delete 携带；refresh 为 null）。
  final String? id;

  /// 所属相册 BUCKET_ID（可能为 null）。
  final String? bucketId;

  @override
  String toString() => 'MsChangeEvent($type, id=$id, bucketId=$bucketId)';
}

MsChangeType _parseType(String? s) {
  switch (s) {
    case 'insert':
      return MsChangeType.insert;
    case 'update':
      return MsChangeType.update;
    case 'delete':
      return MsChangeType.delete;
    default:
      return MsChangeType.refresh;
  }
}

/// MediaStore 变更事件流。
///
/// 调用 [mediaStoreChanges] 获取 Stream；订阅后图库变化时收到 [MsChangeEvent]。
/// 仅安卓有意义（桌面端无此 channel，调用会静默失败）。
/// 兼容旧载荷：裸字符串 "changed" 解析为 refresh。
Stream<MsChangeEvent> mediaStoreChanges() {
  const eventChannel = EventChannel(_kEventsChannel);
  return eventChannel.receiveBroadcastStream().map((e) {
    if (e is Map) {
      return MsChangeEvent(
        _parseType(e['type']?.toString()),
        id: e['id']?.toString(),
        bucketId: e['bucketId']?.toString(),
      );
    }
    // 旧载荷（字符串 "changed"）或未知 → 全量刷新
    return const MsChangeEvent(MsChangeType.refresh);
  });
}
