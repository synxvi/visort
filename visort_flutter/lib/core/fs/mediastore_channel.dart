// MediaStore MethodChannel 客户端 —— Dart 侧对 Kotlin MediaStorePlugin 的薄封装
//
// channel: visort/mediastore
// 对接 MediaStore.Images.Media，实现相册列表/扫描/读取/批量删除。
// 取代 A0-A3 的 saf_channel.dart（SAF 方案）。
//
// 分页：keyset 分页（游标法），取代 offset 分页。
//   offset 分页在删除/新增条目后会错位（重复或跳过），keyset 用"上一页最后一条的
//   排序值 + _ID"作为 WHERE 条件，天然免疫条目增删导致的偏移，是相册 App 的标准做法。
//   游标编码："sortValue|id"（sortValue 为秒级时间戳，id 为 MediaStore _ID）。

import 'package:flutter/services.dart';
import 'package:visort_flutter/core/config/models.dart';

const _kChannel = 'visort/mediastore';

/// MethodChannel 单例（整个 app 共享一个 channel，底层无状态）。
final MethodChannel msMethodChannel = const MethodChannel(_kChannel);

// ───────────────────────── 错误类型 ─────────────────────────

/// MediaStore 错误码（与 Kotlin 侧 MsError.code 对齐）。
enum MsErrorCode {
  permissionDenied,
  queryFailed,
  invalidArg,
  deleteCancelled,
  unknown;

  static MsErrorCode fromString(String? code) => switch (code) {
        'PERMISSION_DENIED' => MsErrorCode.permissionDenied,
        'QUERY_FAILED' => MsErrorCode.queryFailed,
        'INVALID_ARG' => MsErrorCode.invalidArg,
        'DELETE_CANCELLED' => MsErrorCode.deleteCancelled,
        _ => MsErrorCode.unknown,
      };
}

/// MediaStore 调用异常（携带类型化 code，UI 可据此分支处理）。
class MsException implements Exception {
  const MsException(this.code, this.message);
  final MsErrorCode code;
  final String message;

  /// 是否权限相关（UI 可引导授权）。
  bool get isPermission => code == MsErrorCode.permissionDenied;

  @override
  String toString() => 'MsException($code): $message';
}

/// 用户取消删除（保留向后兼容的具名异常）。
class MsDeleteCancelledException extends MsException {
  const MsDeleteCancelledException()
      : super(MsErrorCode.deleteCancelled, '用户取消删除');
}

// ───────────────────────── 数据模型 ─────────────────────────

class MsBucket {
  const MsBucket({
    required this.id,
    required this.name,
    required this.count,
    required this.dateCreatedMs,
    required this.dateModifiedMs,
    this.coverId,
  });
  final String id;
  final String name;
  final int count;
  /// 相册建立时间 = min(DATE_ADDED)（MediaStore 相册无原生时间戳，由内图片聚合）
  final int dateCreatedMs;
  /// 相册最近变动时间 = max(DATE_MODIFIED)
  final int dateModifiedMs;
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
    required this.dateModifiedMs,
    this.isFavorite = false,
    this.isTrashed = false,
    this.dateTrashedMs = 0,
    this.width = 0,
    this.height = 0,
  });
  final String id; // MediaStore _ID（ImageRef.relativePath 编码此值）
  final String name;
  final int size;
  final String mime;
  final String bucketId;
  final int dateAddedMs;     // 创建/入库时间（DATE_ADDED * 1000）
  final int dateModifiedMs;  // 修改时间（DATE_MODIFIED * 1000）
  final bool isFavorite;  // IS_FAVORITE（Android R+）；低版本始终 false
  final bool isTrashed;  // IS_TRASHED（Android R+）；低版本始终 false
  final int dateTrashedMs;  // DATE_EXPIRES * 1000（回收站删除日期；非回收站项为 0）
  /// 原图像素宽/高（MediaStore WIDTH/HEIGHT）。损坏/未知项为 0；
  /// viewer 双击自适应铺满按宽高比算 coverRatio，为 0 时 fallback readMeta 或 2.5×。
  final int width;
  final int height;

  /// 持久化用（snapshot 磁盘缓存）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'mime': mime,
        'bucketId': bucketId,
        'dateAddedMs': dateAddedMs,
        'dateModifiedMs': dateModifiedMs,
        'isFavorite': isFavorite,
        'isTrashed': isTrashed,
        'dateTrashedMs': dateTrashedMs,
        'width': width,
        'height': height,
      };

  factory MsImageInfo.fromJson(Map<String, dynamic> j) => MsImageInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        size: j['size'] as int,
        mime: j['mime'] as String,
        bucketId: j['bucketId'] as String,
        dateAddedMs: j['dateAddedMs'] as int,
        dateModifiedMs: j['dateModifiedMs'] as int? ?? j['dateAddedMs'] as int,
        isFavorite: j['isFavorite'] as bool? ?? false,
        isTrashed: j['isTrashed'] as bool? ?? false,
        dateTrashedMs: j['dateTrashedMs'] as int? ?? 0,
        width: j['width'] as int? ?? 0,
        height: j['height'] as int? ?? 0,
      );
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

/// 一页扫描结果（keyset 分页）：图片列表 + 下一页游标。
class MsScanPage {
  const MsScanPage({required this.images, this.nextCursor});
  final List<MsImageInfo> images;
  /// 下一页的 keyset 游标；null 表示无更多数据。
  /// 编码："sortValue|id"（sortValue=秒级时间戳或空，id=MediaStore _ID）。
  final String? nextCursor;
  bool get hasMore => nextCursor != null;
}

// ───────────────────────── Channel 客户端 ─────────────────────────

/// MediaStore MethodChannel 客户端。
///
/// 默认走 `visort/mediastore` channel；测试/解耦时可注入自定义 channel
/// （GalleryController 经 Provider 注入，便于 fake）。构造函数保持 const——
/// 默认 channel 用 const MethodChannel 内联，使 `const MediaStoreChannel()` 合法。
class MediaStoreChannel {
  const MediaStoreChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_kChannel);

  final MethodChannel _channel;

  /// 检查 READ_MEDIA_IMAGES 权限是否已授予
  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求 READ_MEDIA_IMAGES 权限。返回是否授予。
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 列出所有相册（bucket）。无权限时抛 [MsException]。
  ///
  /// [sortBy]/[asc] 同时决定：
  ///   - 每个相册的封面图（coverId）= 该相册在此排序下的第一张
  ///   - 与首页列表排序保持一致（列表顺序由 Dart 排，这里只管封面）
  Future<List<MsBucket>> listBuckets({
    SortBy sortBy = SortBy.dateCreated,
    bool asc = false,
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listBuckets',
        {'sortBy': sortBy.name, 'asc': asc},
      );
      if (raw == null) return const [];
      return raw.cast<Map>().map(_toBucket).toList(growable: false);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 按 bucket id 扫描一页图片（keyset 分页）。
  ///
  /// [bucketIds] 为空表示扫全部。
  /// [afterCursor] = 上一页的 [MsScanPage.nextCursor]；null 表示从第一页开始。
  /// [sortBy]/[asc] 跟随「相册内排序」(photoSortBy)，与首页封面一致。
  /// 返回 [MsScanPage]（含本页图片 + 下一页游标）。
  Future<MsScanPage> scanImages(
    List<String> bucketIds, {
    String? afterCursor,
    int limit = 60,
    SortBy sortBy = SortBy.dateCreated,
    bool asc = false,
    bool favoritesOnly = false,
    bool trashedOnly = false,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'scanImages',
        {
          'bucketIds': bucketIds,
          'limit': limit,
          'afterCursor': afterCursor,
          'sortBy': sortBy.name,
          'favoritesOnly': favoritesOnly,
          'trashedOnly': trashedOnly,
          'asc': asc,
        },
      );
      if (raw == null) {
        return MsScanPage(images: const [], nextCursor: null);
      }
      // 扁平化传输：12 并行数组按索引重组（Kotlin ScanPage.toMap）。
      final ids = (raw['ids'] as List<dynamic>?) ?? const [];
      final next = raw['nextCursor'] as String?;
      if (ids.isEmpty) return MsScanPage(images: const [], nextCursor: next);
      final names = raw['names'] as List<dynamic>;
      final sizes = raw['sizes'] as List<dynamic>;
      final mimes = raw['mimes'] as List<dynamic>;
      final bucketIdArr = raw['bucketIds'] as List<dynamic>;
      final dateAddeds = raw['dateAddeds'] as List<dynamic>;
      final dateModifieds = raw['dateModifieds'] as List<dynamic>;
      final isFavorites = raw['isFavorites'] as List<dynamic>;
      final isTrasheds = raw['isTrasheds'] as List<dynamic>;
      final dateTrasheds = raw['dateTrasheds'] as List<dynamic>;
      final widths = raw['widths'] as List<dynamic>;
      final heights = raw['heights'] as List<dynamic>;
      final images = List<MsImageInfo>.generate(ids.length, (i) {
        final added = (dateAddeds[i] as num).toInt();
        return MsImageInfo(
          id: ids[i].toString(),
          name: names[i] as String,
          size: (sizes[i] as num).toInt(),
          mime: mimes[i] as String,
          bucketId: bucketIdArr[i].toString(),
          dateAddedMs: added,
          dateModifiedMs: (dateModifieds[i] as num?)?.toInt() ?? added,
          isFavorite: isFavorites[i] == true,
          isTrashed: isTrasheds[i] == true,
          dateTrashedMs: (dateTrasheds[i] as num?)?.toInt() ?? 0,
          width: (widths[i] as num?)?.toInt() ?? 0,
          height: (heights[i] as num?)?.toInt() ?? 0,
        );
      }, growable: false);
      return MsScanPage(images: images, nextCursor: next);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取单图元信息
  Future<MsMetaInfo> readMeta(String id) async {
    try {
      final raw = await _channel.invokeMethod<Map>('readMeta', {'id': id});
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

  /// 读取单图完整元数据（EXIF/GPS/相机参数），分组返回。
  /// 失败或无元数据返回空 Map（不抛错，调用方据此决定是否渲染 EXIF 区）。
  Future<Map<String, Map<String, String>>> getMetadata(String id) async {
    try {
      final raw = await _channel.invokeMethod<Map>('getMetadata', {'id': id});
      if (raw == null) return const {};
      return raw.map((g, v) {
        final inner = (v as Map).map((k2, v2) =>
            MapEntry(k2.toString(), v2.toString()));
        return MapEntry(g.toString(), inner);
      });
    } on PlatformException catch (_) {
      return const {};
    }
  }

  /// 收藏/取消收藏（Android R+，系统弹窗确认）。
  /// [favorite]=true 收藏，false 取消。返回是否成功（用户确认）。
  Future<bool> requestFavorite(List<String> ids, bool favorite) async {
    try {
      return await _channel.invokeMethod<bool>(
              'requestFavorite', {'ids': ids, 'favorite': favorite}) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 移入回收站（Android R+，系统弹窗确认）。
  Future<bool> requestTrash(List<String> ids) async {
    try {
      return await _channel.invokeMethod<bool>('requestTrash', {'ids': ids}) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 从回收站恢复（Android R+，系统弹窗确认）。
  Future<bool> requestRestore(List<String> ids) async {
    try {
      return await _channel.invokeMethod<bool>('requestRestore', {'ids': ids}) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取字节流
  Future<Uint8List> readBytes(String id, {int maxBytes = 0}) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>(
          'readBytes', {'id': id, 'maxBytes': maxBytes});
      if (raw == null) throw Exception('readBytes 返回 null');
      return raw;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取缩略图字节（JPEG 编码，API 29+ 用系统 loadThumbnail）。
  /// 返回空数组表示当前平台不支持（API <29），调用方应回退 readBytes。
  /// [dateModifiedMs]：源图 DATE_MODIFIED（毫秒，可空），供 Kotlin 磁盘缓存校验。
  Future<Uint8List> readThumbnail(String id,
      {int width = 256, int height = 256, int? dateModifiedMs}) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>(
        'readThumbnail',
        {
          'id': id,
          'width': width,
          'height': height,
          if (dateModifiedMs != null) 'dateModifiedMs': dateModifiedMs,
        },
      );
      return raw ?? Uint8List(0);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 下采样解码全图:返回 ARGB_8888 原始像素 + 宽高(不经 JPEG 中转),dart 用
  /// ImageDescriptor.raw 直接 instantiateCodec,跳过二次 JPEG decode。
  Future<({Uint8List pixels, int width, int height})> readSampledImage(
      String id, {required int targetWidth}) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'readSampledImage', {'id': id, 'targetWidth': targetWidth});
      if (raw == null) throw Exception('readSampledImage 返回 null');
      return (
        pixels: raw['pixels'] as Uint8List,
        width: (raw['width'] as num).toInt(),
        height: (raw['height'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 存在性检查
  Future<bool> exists(String id) async {
    try {
      return await _channel.invokeMethod<bool>('exists', {'id': id}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 批量删除（系统弹窗确认）。返回成功删除的数量。
  /// 用户取消时抛 [MsDeleteCancelledException]。
  Future<int> requestDelete(List<String> ids) async {
    try {
      return await _channel.invokeMethod<int>('requestDelete', {'ids': ids}) ??
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
      return await _channel.invokeMethod<String>(
          'getBucketRelativePath', {'bucketId': bucketId});
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 检查是否有 MANAGE_MEDIA 特殊权限（Android 12+，零弹窗媒体操作）
  Future<bool> hasManageMedia() async {
    try {
      return await _channel.invokeMethod<bool>('hasManageMedia') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转系统「媒体管理应用」设置页。用户开启后返回 app。
  Future<bool> requestManageMedia() async {
    try {
      return await _channel.invokeMethod<bool>('requestManageMedia') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 批量移动（改 RELATIVE_PATH）。返回成功数。
  /// [relativePath] 如 "Pictures/QQ" 或 "Pictures/整理结果/保留"。
  /// Android 11+ 对其他 app 的文件会弹系统确认窗。
  Future<int> requestMove(List<String> ids, String relativePath) async {
    try {
      return await _channel.invokeMethod<int>(
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
        dateCreatedMs: (m['dateCreatedMs'] as num?)?.toInt() ?? 0,
        dateModifiedMs: (m['dateModifiedMs'] as num?)?.toInt() ?? 0,
        coverId: m['coverId']?.toString(),
      );


  MsException _convertError(PlatformException e) => MsException(
        MsErrorCode.fromString(e.code),
        'MediaStore 错误 [${e.code}]: ${e.message}',
      );
}
