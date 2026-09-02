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
  favoriteCancelled,
  trashCancelled,
  restoreCancelled,
  nameExists,
  unknown;

  static MsErrorCode fromString(String? code) => switch (code) {
        'PERMISSION_DENIED' => MsErrorCode.permissionDenied,
        'QUERY_FAILED' => MsErrorCode.queryFailed,
        'INVALID_ARG' => MsErrorCode.invalidArg,
        'DELETE_CANCELLED' => MsErrorCode.deleteCancelled,
        'FAVORITE_CANCELLED' => MsErrorCode.favoriteCancelled,
        'TRASH_CANCELLED' => MsErrorCode.trashCancelled,
        'RESTORE_CANCELLED' => MsErrorCode.restoreCancelled,
        'NAME_EXISTS' => MsErrorCode.nameExists,
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

/// exists 三态结果：error=查询失败（不可当"已删除/未恢复"证据）。
enum MsExistsStatus { found, notFound, error }

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

  /// 全字段 copyWith——此前缺失导致调用方手写 7 字段构造，每加一个字段
  /// 都要在多处手写拷贝里同步漏改（曾漏 isHdr 使收藏操作清掉 HDR 徽标）。
  MsBucket copyWith({
    String? id,
    String? name,
    int? count,
    int? dateCreatedMs,
    int? dateModifiedMs,
    String? coverId,
    bool clearCoverId = false,
  }) =>
      MsBucket(
        id: id ?? this.id,
        name: name ?? this.name,
        count: count ?? this.count,
        dateCreatedMs: dateCreatedMs ?? this.dateCreatedMs,
        dateModifiedMs: dateModifiedMs ?? this.dateModifiedMs,
        coverId: clearCoverId ? null : (coverId ?? this.coverId),
      );

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
    this.isHdr = false,
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
  /// JPEG Ultra HDR（Kotlin 读文件头检测 XMP hdrgm:Version gainmap）；
  /// 非 JPEG 恒 false。网格 HDR 徽标用。
  final bool isHdr;

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
        'isHdr': isHdr,
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
        isHdr: j['isHdr'] as bool? ?? false,
      );

  /// 全字段 copyWith。此前只有 {isHdr, name}，调用方为改一个字段手写
  /// 13 字段构造——三处手写拷贝全都漏了 isHdr（收藏/取消后 HDR 徽标被
  /// 静默清掉）。新字段一律加到这里，禁止再手写整对象构造。
  MsImageInfo copyWith({
    String? id,
    String? name,
    int? size,
    String? mime,
    String? bucketId,
    int? dateAddedMs,
    int? dateModifiedMs,
    bool? isFavorite,
    bool? isTrashed,
    int? dateTrashedMs,
    int? width,
    int? height,
    bool? isHdr,
  }) =>
      MsImageInfo(
        id: id ?? this.id,
        name: name ?? this.name,
        size: size ?? this.size,
        mime: mime ?? this.mime,
        bucketId: bucketId ?? this.bucketId,
        dateAddedMs: dateAddedMs ?? this.dateAddedMs,
        dateModifiedMs: dateModifiedMs ?? this.dateModifiedMs,
        isFavorite: isFavorite ?? this.isFavorite,
        isTrashed: isTrashed ?? this.isTrashed,
        dateTrashedMs: dateTrashedMs ?? this.dateTrashedMs,
        width: width ?? this.width,
        height: height ?? this.height,
        isHdr: isHdr ?? this.isHdr,
      );
}

/// 搜索索引元数据（智能识别索引产物，存 SQLite `search_index` 表）。
/// 全字段可空：EXIF 缺什么就空什么（PNG 无 GPS/相机、截图无拍摄时间）。
class MsSearchMeta {
  const MsSearchMeta({
    required this.id,
    this.dateTakenMs,
    this.lat,
    this.lng,
    this.camera,
    this.country,
    this.adminArea,
    this.locality,
  });

  final String id;

  /// EXIF 拍摄时间（DateTimeOriginal；null = 无 EXIF 时间，展示时
  /// 由调用方兜底 MsImageInfo.dateAddedMs）。
  final int? dateTakenMs;

  /// GPS 坐标（null = 无定位）。
  final double? lat;
  final double? lng;

  /// 相机 "Make Model"（null = 无相机信息，如截图）。
  final String? camera;

  /// 反地理编码地名（country 国家 / adminArea 省 / locality 市；
  /// null = Geocoder 不可用或未解析）。
  final String? country;
  final String? adminArea;
  final String? locality;

  /// 市级标签（地点卡片标题）：市 → 省 → 国家 兜底链。
  String get placeLabel => locality ?? adminArea ?? country ?? '';
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

/// 系统同意弹窗类调用的超时兜底：Activity detach 时 Kotlin 侧
/// cleanupBinding 已回 DETACHED error；万一回调丢失（极端 ROM 行为），
/// 超时保证 Future 可完成，UI 不至于永久挂起。用户在系统弹窗前发呆
/// 通常不超过 2 分钟，故取 120s。
const _kConsentTimeout = Duration(seconds: 120);

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
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 非安卓端无 channel handler（降级为无权限）
    }
  }

  /// 请求 READ_MEDIA_IMAGES 权限。返回是否授予。
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 非安卓端无 channel handler
    }
  }

  /// 跳转本应用的系统设置详情页。权限被永久拒绝（「不再询问」）后，
  /// requestPermissions 立即回调 denied 不再弹窗——设置页是唯一出口。
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<bool>('openAppSettings');
    } on PlatformException {
      // 跳转失败静默（无 Activity 等极端场景）
    } on MissingPluginException {
      // 非安卓端无 channel handler
    }
  }

  /// 请求 ACCESS_MEDIA_LOCATION（EXIF 精确 GPS）。Android 10+ 未授权时
  /// 系统剥离 content URI 的位置标签 → 详情面板「位置」恒空。
  /// 详情面板首次打开时调用一次（调用方 static 闸门防重复弹窗）。
  Future<bool> requestAccessMediaLocation() async {
    try {
      return await _channel.invokeMethod<bool>('requestAccessMediaLocation') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 非安卓端无 channel handler
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
      final isHdrs = (raw['isHdrs'] as List<dynamic>?) ?? const [];
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
          // 旧包兼容：isHdrs 空数组时 false
          isHdr: isHdrs.isNotEmpty && isHdrs[i] == true,
        );
      }, growable: false);
      return MsScanPage(images: images, nextCursor: next);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 批量 HDR 检测（后台补测通道，Kotlin ioExecutor 读文件头 + 进程内
  /// 缓存）。与 scanImages 分离：网格先上屏，徽标数据到货后回填。
  /// [ids]/[mtimes]/[mimes] 并行数组，返回同序布尔列表。mimes 供 Kotlin
  /// mime 门禁——非 JPEG（HEIC/PNG 等）直接 false，不白读文件头 64KB。
  Future<List<bool>> detectHdrs(
      List<String> ids, List<int> mtimes, List<String> mimes) async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('detectHdrs', {
        'ids': ids,
        'mtimes': mtimes,
        'mimes': mimes,
      });
      return (raw ?? const []).map((e) => e == true).toList();
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取单图元信息
  Future<MsMetaInfo> readMeta(String id) async {
    try {
      final raw = await _channel.invokeMethod<Map>('readMeta', {'id': id});
      // 裸 Exception 换 MsException（审查 F12）：调用方 on MsException 接不住
      if (raw == null) {
        throw const MsException(MsErrorCode.unknown, 'readMeta 返回 null');
      }
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

  /// 批量提取搜索索引元数据（拍摄时间/GPS/相机，单次 EXIF pass）。
  /// 返回 id → 元数据（仅含有数据的项）；Dart 侧分批调用累计进度。
  /// 地名（country/adminArea/locality）由 [geocodePlaces] 二次填充。
  Future<Map<String, MsSearchMeta>> indexSearchMeta(List<String> ids) async {
    try {
      final raw =
          await _channel.invokeMethod<Map>('indexSearchMeta', {'ids': ids});
      if (raw == null) return const {};
      return raw.map((id, v) {
        final m = (v as Map).cast<String, dynamic>();
        double? d(String k) => m[k] == null ? null : (m[k] as num).toDouble();
        int? i(String k) => m[k] == null ? null : (m[k] as num).toInt();
        String? s(String k) => m[k]?.toString();
        return MapEntry(
          id.toString(),
          MsSearchMeta(
            id: id.toString(),
            dateTakenMs: i('dateTakenMs'),
            lat: d('lat'),
            lng: d('lng'),
            camera: s('camera'),
          ),
        );
      });
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 批量反地理编码：[lat, lng] 列表 → { country / adminArea / locality }。
  /// Geocoder 不可用/无结果时对应字段为 null（搜索页降级坐标分组）。
  /// Kotlin 侧 0.02° 网格去重 + 缓存，重复坐标不重复发起网络请求。
  Future<List<({String? country, String? adminArea, String? locality})>>
      geocodePlaces(List<List<double>> coords) async {
    try {
      final raw = await _channel
          .invokeMethod<List>('geocodePlaces', {'coords': coords});
      if (raw == null) return const [];
      return raw.map((e) {
        final m = (e as Map?)?.cast<String, dynamic>() ?? const {};
        String? s(String k) => m[k]?.toString();
        return (
          country: s('country'),
          adminArea: s('adminArea'),
          locality: s('locality'),
        );
      }).toList();
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
    } on PlatformException {
      return const {};
    }
  }

  /// 收藏/取消收藏（Android R+，系统弹窗确认）。
  /// [favorite]=true 收藏，false 取消。返回是否成功（用户确认）。
  Future<bool> requestFavorite(List<String> ids, bool favorite) async {
    try {
      return await _channel
          .invokeMethod<bool>(
              'requestFavorite', {'ids': ids, 'favorite': favorite})
          .timeout(_kConsentTimeout,
              // 超时转 MsException（审查 F12）：调用方 on MsException 接
              // 不住裸 TimeoutException。
              onTimeout: () => throw const MsException(
                  MsErrorCode.unknown, '系统弹窗确认超时')) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 移入回收站（Android R+，系统弹窗确认）。
  Future<bool> requestTrash(List<String> ids) async {
    try {
      return await _channel
          .invokeMethod<bool>('requestTrash', {'ids': ids})
          .timeout(_kConsentTimeout,
              // 超时转 MsException（审查 F12）：调用方 on MsException 接
              // 不住裸 TimeoutException。
              onTimeout: () => throw const MsException(
                  MsErrorCode.unknown, '系统弹窗确认超时')) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 从回收站恢复（Android R+，系统弹窗确认）。
  Future<bool> requestRestore(List<String> ids) async {
    try {
      return await _channel
          .invokeMethod<bool>('requestRestore', {'ids': ids})
          .timeout(_kConsentTimeout,
              // 超时转 MsException（审查 F12）：调用方 on MsException 接
              // 不住裸 TimeoutException。
              onTimeout: () => throw const MsException(
                  MsErrorCode.unknown, '系统弹窗确认超时')) ??
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
      // 裸 Exception 换 MsException（审查 F12）
      if (raw == null) {
        throw const MsException(MsErrorCode.unknown, 'readBytes 返回 null');
      }
      return raw;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取缩略图字节（JPEG 编码，API 29+ 用系统 loadThumbnail）。
  /// 返回空数组表示当前平台不支持（API <29），调用方应回退 readBytes。
  /// [dateModifiedMs]：源图 DATE_MODIFIED（毫秒，可空），供 Kotlin 磁盘缓存校验。
  Future<Uint8List> readThumbnail(String id,
      {int width = 256,
      int height = 256,
      int? dateModifiedMs,
      bool squareCrop = false}) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>(
        'readThumbnail',
        {
          'id': id,
          'width': width,
          'height': height,
          if (dateModifiedMs != null) 'dateModifiedMs': dateModifiedMs,
          'squareCrop': squareCrop,
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
      // 裸 Exception 换 MsException（审查 F12）
      if (raw == null) {
        throw const MsException(
            MsErrorCode.unknown, 'readSampledImage 返回 null');
      }
      return (
        pixels: raw['pixels'] as Uint8List,
        width: (raw['width'] as num).toInt(),
        height: (raw['height'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 设备总内存（MB）。[ente 对齐] 解码防崩阈值用（RAM < 5GB → 24MP 上限）。
  Future<int?> totalRamMb() async {
    try {
      final raw = await _channel.invokeMethod<int>('totalRamMb');
      return raw;
    } on PlatformException {
      return null;
    }
  }

  // ──────────── 空闲预缓存（全相册 screenNail 预生成） ────────────

  /// 空闲预生成单张全图缓存（只落盘不拷像素不跨 channel 传大 buffer）。
  /// [dateModifiedMs] 调用方已知的源图修改时间（scanImages 结果里有），
  /// 传入省去 Kotlin exists 分支的一次单行查询（全库重扫上千张 skip 时
  /// 收益显著）；null 则 Kotlin 自查。
  /// 返回码：0=已生成 1=缓存已存在跳过 3=失败（源图缺失/损坏）。
  Future<int> precacheFullImage(String id,
      {required int targetWidth, int? dateModifiedMs}) async {
    try {
      return await _channel.invokeMethod<int>('precacheFullImage', {
        'id': id,
        'targetWidth': targetWidth,
        if (dateModifiedMs != null) 'dateModifiedMs': dateModifiedMs,
      }) ??
          3;
    } on PlatformException {
      return 3;
    }
  }

  /// full 盘缓存轻量探测（快甩「盘缓存直通」前置门）：存在 + dm 失效校验，
  /// 不读不解。校验与真读路径（readSampledImage→readFullCache）完全对齐，
  /// 探测命中 ⇒ 真读命中。失败一律 false（回落延迟窗原路径，零副作用）。
  Future<bool> fullCacheExists(String id, {required int targetWidth}) async {
    try {
      return await _channel.invokeMethod<bool>('fullCacheExists', {
            'id': id,
            'targetWidth': targetWidth,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// 设置全图缓存配额（字节）并立即 LRU 收紧。64MB~2GB。
  Future<void> setFullCacheQuota(int bytes) async {
    try {
      await _channel.invokeMethod<void>(
          'setFullCacheQuota', {'bytes': bytes});
    } on PlatformException {
      // 静默：配额设置失败不影响功能（下轮再设）
    }
  }

  /// 清空图片磁盘缓存。clearThumb=true 连缩略图一起清（手动清理按钮）。
  /// 返回 {full: 释放字节, thumb: 释放字节}。
  Future<({int full, int thumb})> clearImageCaches(
      {bool clearThumb = false}) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'clearImageCaches', {'clearThumb': clearThumb});
      return (
        full: ((raw?['full'] as num?) ?? 0).toInt(),
        thumb: ((raw?['thumb'] as num?) ?? 0).toInt(),
      );
    } on PlatformException {
      return (full: 0, thumb: 0);
    }
  }

  /// 统计图片磁盘缓存占用 {full, thumb}（字节）。
  Future<({int full, int thumb})> imageCacheBytes() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('imageCacheBytes');
      return (
        full: ((raw?['full'] as num?) ?? 0).toInt(),
        thumb: ((raw?['thumb'] as num?) ?? 0).toInt(),
      );
    } on PlatformException {
      return (full: 0, thumb: 0);
    }
  }

  // ──────────── WorkManager 全库预缓存（充电窗口批量） ────────────

  /// 排队全库预缓存任务（约束：充电 + 存储不低，KEEP 幂等）。白天 app 内
  /// 排队不动，插电即跑。失败静默（下次冷启动再排）。
  Future<void> schedulePrecacheWork({required int targetWidth}) async {
    try {
      await _channel.invokeMethod<void>(
          'schedulePrecacheWork', {'targetWidth': targetWidth});
    } on PlatformException {
      // 静默：调度失败下次启动再排
    }
  }

  /// 取消预缓存任务（关开关/手动清缓存）。
  Future<void> cancelPrecacheWork() async {
    try {
      await _channel.invokeMethod<void>('cancelPrecacheWork');
    } on PlatformException {
      // 静默
    }
  }

  /// 预缓存任务状态：running（跑着）/ enqueued（排队等充电）/ idle。
  Future<String> precacheWorkState() async {
    try {
      return await _channel.invokeMethod<String>('precacheWorkState') ?? 'idle';
    } on PlatformException {
      return 'idle';
    }
  }

  /// 预缓存进度 {cached, total, full, thumb}：cached=已缓存张数（目录
  /// 文件数），total=全库应缓存张数（非回收站非 GIF），full/thumb=磁盘
  /// 占用字节。设置页进度行轮询数据源（一次往返全给齐）。
  Future<({int cached, int total, int full, int thumb})> fullCacheStats(
      {required int targetWidth}) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'fullCacheStats', {'targetWidth': targetWidth});
      return (
        cached: ((raw?['cached'] as num?) ?? 0).toInt(),
        total: ((raw?['total'] as num?) ?? 0).toInt(),
        full: ((raw?['full'] as num?) ?? 0).toInt(),
        thumb: ((raw?['thumb'] as num?) ?? 0).toInt(),
      );
    } on PlatformException {
      return (cached: 0, total: 0, full: 0, thumb: 0);
    }
  }

  /// 存在性检查三态：found / notFound / error（查询失败上抛 MsException）。
  /// 旧实现把查询失败吞成 false——删除复查方向把它当"已删除"证据，
  /// 本地列表误移除（破坏性）。Kotlin 两层吞错已解除。
  Future<MsExistsStatus> existsStatus(String id) async {
    try {
      return await _channel.invokeMethod<bool>('exists', {'id': id}) == true
          ? MsExistsStatus.found
          : MsExistsStatus.notFound;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 存在性检查（布尔薄包装；仅用于"失败按不存在处理"无破坏性的场景）。
  Future<bool> exists(String id) async {
    try {
      return await existsStatus(id) == MsExistsStatus.found;
    } on MsException {
      // 契约：「失败按不存在处理」仅限查询失败（MsException），编程错误
      // 不吞（审查 F12 收窄）。
      return false;
    }
  }

  /// 批量删除（系统弹窗确认）。返回成功删除的数量。
  /// 用户取消时抛 [MsDeleteCancelledException]。
  Future<int> requestDelete(List<String> ids) async {
    try {
      return await _channel
          .invokeMethod<int>('requestDelete', {'ids': ids})
          .timeout(_kConsentTimeout,
              // 超时转 MsException（审查 F12）：调用方 on MsException 接
              // 不住裸 TimeoutException。
              onTimeout: () => throw const MsException(
                  MsErrorCode.unknown, '系统弹窗确认超时')) ??
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
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 非安卓端无 channel handler
    }
  }

  /// 跳转系统「媒体管理应用」设置页。用户开启后返回 app。
  Future<bool> requestManageMedia() async {
    try {
      return await _channel.invokeMethod<bool>('requestManageMedia') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 非安卓端无 channel handler
    }
  }

  /// 批量移动（改 RELATIVE_PATH）。返回**实际成功移动的 id 集**——
  /// 部分成功如实上报（自有文件直移成功 + 他人文件弹窗被拒的组合下，
  /// 旧协议只回成功数，count != total 时上层把全部记失败，但其中
  /// 自有文件早已物理移走）。
  /// [relativePath] 如 "Pictures/QQ" 或 "Pictures/整理结果/保留"。
  /// Android 11+ 对其他 app 的文件会弹系统确认窗。
  Future<List<String>> requestMove(List<String> ids, String relativePath) async {
    try {
      // 超时结果未知（审查 F12 注记）：超时只代表「弹窗未在时限内确认」，
      // native 侧可能仍在执行且部分文件已物理移动——调用方按全败回滚
      // 会与磁盘脱节，须知情处理。
      final raw = await _channel
          .invokeMethod<List<dynamic>>(
              'requestMove', {'ids': ids, 'relativePath': relativePath})
          .timeout(_kConsentTimeout,
              onTimeout: () => throw const MsException(MsErrorCode.unknown,
                  '移动系统弹窗确认超时（结果未知，可能已部分移动）'));
      return raw?.cast<String>() ?? const [];
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 重命名单张（update DISPLAY_NAME，MediaStore 同步重命名底层文件，
  /// _ID 不变）。同名冲突抛 [MsException]（code=nameExists）。
  /// 他人文件走 createWriteRequest 授权；返回 1 成功，0 取消/失败。
  Future<int> requestRename(String id, String newName) async {
    try {
      return await _channel
          .invokeMethod<int>('requestRename', {'id': id, 'newName': newName})
          .timeout(_kConsentTimeout,
              // 超时转 MsException（审查 F12）：调用方 on MsException 接
              // 不住裸 TimeoutException。
              onTimeout: () => throw const MsException(
                  MsErrorCode.unknown, '系统弹窗确认超时')) ??
          0;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 重命名预检：同目录是否已存在同名（排除自身）。对话框实时校验用。
  Future<bool> nameExists(String id, String newName) async {
    try {
      return await _channel.invokeMethod<bool>(
              'nameExists', {'id': id, 'newName': newName}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 非安卓端无 channel handler
    }
  }

  /// 批量复制到目标 RELATIVE_PATH（insert 新条目 + 流拷贝）。
  /// 零弹窗（读源有 READ_MEDIA_IMAGES，写的是自己 insert 的条目）；
  /// 同名冲突系统自动加 " (1)" 后缀。返回成功数。
  Future<int> requestCopy(List<String> ids, String relativePath) async {
    try {
      return await _channel.invokeMethod<int>(
              'requestCopy', {'ids': ids, 'relativePath': relativePath}) ??
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
