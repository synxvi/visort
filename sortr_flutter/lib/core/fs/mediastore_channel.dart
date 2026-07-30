// MediaStore MethodChannel 客户端 —— Dart 侧对 Kotlin MediaStorePlugin 的薄封装
//
// channel: sortr/mediastore
// 对接 MediaStore.Images.Media，实现相册列表/扫描/读取/批量删除。
// 取代 A0-A3 的 saf_channel.dart（SAF 方案）。

import 'package:flutter/services.dart';
import 'package:sortr_flutter/core/config/models.dart';

const _kChannel = 'sortr/mediastore';

final MethodChannel msMethodChannel = const MethodChannel(_kChannel);

/// 一个相册（bucket）
class MsBucket {
  const MsBucket({
    required this.id,
    required this.name,
    required this.count,
    this.coverId,
  });
  final String id;
  final String name;
  final int count;
  /// 封面图 _ID（该相册最新一张图）。用于首页缩略图。null = 无封面。
  final String? coverId;
  @override
  String toString() => 'MsBucket($name, $count, cover=$coverId)';
}

/// 扫描到的单张图片信息
class MsImageInfo {
  const MsImageInfo({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.bucketId,
    required this.dateAddedMs,
    required this.dateTakenMs,
  });
  final String id; // MediaStore _ID（ImageRef.relativePath 编码此值）
  final String name;
  final int size;
  final String mime;
  final String bucketId;
  final int dateAddedMs;  // 入库时间（DATE_ADDED * 1000）
  final int dateTakenMs;  // 拍摄时间（DATE_TAKEN，为空回退 dateAddedMs）
}

/// 单图元信息
class MsMetaInfo {
  const MsMetaInfo({
    required this.name,
    required this.size,
    required this.modifiedMs,
    required this.width,
    required this.height,
  });
  final String name;
  final int size;
  final int modifiedMs;
  final int width;
  final int height;
}

/// 用户取消删除
class MsDeleteCancelledException implements Exception {
  const MsDeleteCancelledException();
  @override
  String toString() => '用户取消删除';
}

class MediaStoreChannel {
  const MediaStoreChannel();

  /// 检查 READ_MEDIA_IMAGES 权限是否已授予
  Future<bool> hasPermission() async {
    try {
      return await msMethodChannel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求 READ_MEDIA_IMAGES 权限。返回是否授予。
  Future<bool> requestPermission() async {
    try {
      return await msMethodChannel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 列出所有相册（bucket）。无权限时抛异常。
  ///
  /// [sortBy]/[asc] 同时决定：
  ///   - 每个相册的封面图（coverId）= 该相册在此排序下的第一张
  ///   - 与首页列表排序保持一致（列表顺序由 Dart 排，这里只管封面）
  Future<List<MsBucket>> listBuckets({
    SortBy sortBy = SortBy.dateTaken,
    bool asc = false,
  }) async {
    try {
      final raw = await msMethodChannel.invokeMethod<List<dynamic>>(
        'listBuckets',
        {'sortBy': sortBy.name, 'asc': asc},
      );
      if (raw == null) return const [];
      return raw.cast<Map>().map(_toBucket).toList(growable: false);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 按 bucket id 扫描图片。[bucketIds] 为空表示扫全部。
  /// [offset] 为跳过的条数（相册浏览分页用）。
  /// [sortBy]/[asc] 跟随「相册内排序」(photoSortBy)，保证返回顺序与首页封面
  /// （listBuckets 取首张）一致。分类流程不传则用默认值（顺序由调用方重排）。
  Future<List<MsImageInfo>> scanImages(List<String> bucketIds,
      {int max = 2000, int offset = 0, String sortBy = 'dateTaken', bool asc = false}) async {
    try {
      final raw = await msMethodChannel.invokeMethod<List<dynamic>>(
        'scanImages',
        {'bucketIds': bucketIds, 'max': max, 'offset': offset, 'sortBy': sortBy, 'asc': asc},
      );
      if (raw == null) return const [];
      return raw.cast<Map>().map(_toImageInfo).toList(growable: false);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取单图元信息
  Future<MsMetaInfo> readMeta(String id) async {
    try {
      final raw = await msMethodChannel.invokeMethod<Map>('readMeta', {'id': id});
      if (raw == null) throw Exception('readMeta 返回 null');
      return MsMetaInfo(
        name: raw['name'] as String,
        size: (raw['size'] as num).toInt(),
        modifiedMs: (raw['modifiedMs'] as num).toInt(),
        width: (raw['width'] as num).toInt(),
        height: (raw['height'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取字节流
  Future<Uint8List> readBytes(String id, {int maxBytes = 0}) async {
    try {
      final raw = await msMethodChannel
          .invokeMethod<Uint8List>('readBytes', {'id': id, 'maxBytes': maxBytes});
      if (raw == null) throw Exception('readBytes 返回 null');
      return raw;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取缩略图字节（JPEG 编码，API 29+ 用系统 loadThumbnail）。
  /// 返回空数组表示当前平台不支持（API <29），调用方应回退 readBytes。
  Future<Uint8List> readThumbnail(String id,
      {int width = 256, int height = 256}) async {
    try {
      final raw = await msMethodChannel.invokeMethod<Uint8List>(
        'readThumbnail',
        {'id': id, 'width': width, 'height': height},
      );
      return raw ?? Uint8List(0);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 存在性检查
  Future<bool> exists(String id) async {
    try {
      return await msMethodChannel.invokeMethod<bool>('exists', {'id': id}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 批量删除（系统弹窗确认）。返回成功删除的数量。
  /// 用户取消时抛 [MsDeleteCancelledException]。
  Future<int> requestDelete(List<String> ids) async {
    try {
      return await msMethodChannel
              .invokeMethod<int>('requestDelete', {'ids': ids}) ??
          0;
    } on PlatformException catch (e) {
      if (e.code == 'DELETE_CANCELLED') {
        throw const MsDeleteCancelledException();
      }
      throw _convertError(e);
    }
  }

  /// 查指定相册的 RELATIVE_PATH（如 "Pictures/QQ"）。模式二目标解析用。
  Future<String?> getBucketRelativePath(String bucketId) async {
    try {
      return await msMethodChannel
          .invokeMethod<String>('getBucketRelativePath', {'bucketId': bucketId});
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 检查是否有 MANAGE_MEDIA 特殊权限（Android 12+，零弹窗媒体操作）
  Future<bool> hasManageMedia() async {
    try {
      return await msMethodChannel.invokeMethod<bool>('hasManageMedia') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转系统「媒体管理应用」设置页。用户开启后返回 app。
  Future<bool> requestManageMedia() async {
    try {
      return await msMethodChannel.invokeMethod<bool>('requestManageMedia') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 批量移动（改 RELATIVE_PATH）。返回成功数。
  /// [relativePath] 如 "Pictures/QQ" 或 "Pictures/整理结果/保留"。
  /// Android 11+ 对其他 app 的文件会弹系统确认窗。
  Future<int> requestMove(List<String> ids, String relativePath) async {
    try {
      return await msMethodChannel.invokeMethod<int>(
              'requestMove', {'ids': ids, 'relativePath': relativePath}) ??
          0;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  MsBucket _toBucket(Map m) => MsBucket(
        id: m['id'].toString(),
        name: m['name'] as String,
        count: (m['count'] as num).toInt(),
        coverId: m['coverId']?.toString(),
      );

  MsImageInfo _toImageInfo(Map m) => MsImageInfo(
        id: m['id'].toString(),
        name: m['name'] as String,
        size: (m['size'] as num).toInt(),
        mime: m['mime'] as String,
        bucketId: m['bucketId'].toString(),
        dateAddedMs: (m['dateAddedMs'] as num).toInt(),
        dateTakenMs: (m['dateTakenMs'] as num?)?.toInt() ??
            (m['dateAddedMs'] as num).toInt(),
      );

  Exception _convertError(PlatformException e) =>
      Exception('MediaStore 错误 [${e.code}]: ${e.message}');
}
