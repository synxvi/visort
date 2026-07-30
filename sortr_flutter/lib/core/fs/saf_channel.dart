// SAF MethodChannel 客户端 —— Dart 侧对 Kotlin SafPlugin 的薄封装
//
// 里程碑 A0：仅 pickDirectory / scanImages / persistedUriPermissions 三个方法。
// 里程碑 A1 将由 AndroidSafFileSystem 调用本类填充其余方法。
//
// 设计：纯 channel 调用，不持有状态。AndroidSafFileSystem 注入此实例。
// 错误传递：Kotlin 侧通过 error(code, message, details) 上报，这里转成自定义异常。

import 'package:flutter/services.dart';

/// SAF channel 通道名（与 Kotlin SafPlugin.CHANNEL 对齐）
const _kChannel = 'sortr/saf';

/// 通道单例（plugin 注册在 MainActivity，全局复用）
final MethodChannel safMethodChannel = const MethodChannel(_kChannel);

/// 用户取消选择
class SafCancelledException implements Exception {
  const SafCancelledException();
  @override
  String toString() => '用户取消 SAF 目录选择';
}

/// SAF 扫描到的一张图片（与 Kotlin SafImageInfo.toMap 对齐）
class SafImageInfo {
  const SafImageInfo({
    required this.name,
    required this.docId,
    required this.size,
    required this.mime,
  });

  /// 显示名（含扩展名）
  final String name;

  /// DocumentsContract 文档 ID（A1 move/delete/readBytes 的关键凭证）
  final String docId;

  /// 字节数
  final int size;

  /// MIME 类型（image/jpeg 等）
  final String mime;

  @override
  String toString() => 'SafImageInfo($name, $size B, $mime)';
}

/// 持久化授权记录（与 Kotlin SafPermissionInfo.toMap 对齐）
class SafPermissionInfo {
  const SafPermissionInfo({
    required this.uri,
    required this.isReadPermission,
    required this.isWritePermission,
  });

  final String uri;
  final bool isReadPermission;
  final bool isWritePermission;

  @override
  String toString() =>
      'SafPermissionInfo($uri, R=$isReadPermission, W=$isWritePermission)';
}

/// 文档元信息（A1 readMeta 返回，与 Kotlin SafMetaInfo 对齐）
class SafMetaInfo {
  const SafMetaInfo({
    required this.name,
    required this.size,
    required this.modifiedMs,
  });

  final String name;
  final int size; // 字节数
  final int modifiedMs; // Unix 毫秒

  @override
  String toString() => 'SafMetaInfo($name, $size B, mod=$modifiedMs)';
}

/// 移动操作结果（A1 move 返回，与 Kotlin SafMoveResult 对齐）
class SafMoveResult {
  const SafMoveResult({
    required this.success,
    this.finalName,
    this.finalDocId,
    this.error,
  });

  final bool success;
  final String? finalName;
  final String? finalDocId;
  final String? error;

  @override
  String toString() =>
      'SafMoveResult(success=$success, finalName=$finalName, error=$error)';
}

/// SAF channel 客户端
class SafChannel {
  const SafChannel();

  /// 启动 ACTION_OPEN_DOCUMENT_TREE，返回 tree URI 字符串。
  /// Kotlin 侧已自动调 takePersistableUriPermission。
  /// 用户取消时抛 [SafCancelledException]。
  Future<String> pickDirectory() async {
    try {
      final result = await safMethodChannel.invokeMethod<String>('pickDirectory');
      if (result == null) {
        throw const SafCancelledException();
      }
      return result;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') {
        throw const SafCancelledException();
      }
      throw _convertError(e);
    }
  }

  /// 扫描 tree URI 下的图片。
  /// [max] 防御性上限，默认 500。
  Future<List<SafImageInfo>> scanImages(String treeUri, {int max = 500}) async {
    try {
      final raw = await safMethodChannel.invokeMethod<List<dynamic>>(
        'scanImages',
        {'treeUri': treeUri, 'max': max},
      );
      if (raw == null) return const [];
      return raw.cast<Map>().map(_toImageInfo).toList(growable: false);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 列出当前 App 持久化的所有 SAF 授权（用于重启后验证）。
  Future<List<SafPermissionInfo>> persistedUriPermissions() async {
    try {
      final raw = await safMethodChannel
          .invokeMethod<List<dynamic>>('persistedUriPermissions');
      if (raw == null) return const [];
      return raw.cast<Map>().map(_toPermissionInfo).toList(growable: false);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  // ──────────── A1 方法 ────────────

  /// 列出 tree URI 下的直接子目录（仅一层，过滤 . 开头）。
  Future<List<String>> listSubdirs(String treeUri) async {
    try {
      final raw = await safMethodChannel.invokeMethod<List<dynamic>>(
        'listSubdirs',
        {'treeUri': treeUri},
      );
      if (raw == null) return const [];
      return raw.cast<String>().toList(growable: false);
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取单张图片的元信息。
  Future<SafMetaInfo> readMeta(String treeUri, String docId) async {
    try {
      final raw = await safMethodChannel.invokeMethod<Map>(
        'readMeta',
        {'treeUri': treeUri, 'docId': docId},
      );
      if (raw == null) throw Exception('readMeta 返回 null');
      return SafMetaInfo(
        name: raw['name'] as String,
        size: (raw['size'] as num).toInt(),
        modifiedMs: (raw['modifiedMs'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 移动文件（自动分叉同 tree / 跨 tree）。
  /// [destDirDocId] 可为空字符串表示目标 tree 根目录。
  Future<SafMoveResult> move({
    required String srcTreeUri,
    required String srcDocId,
    required String destTreeUri,
    required String destDirDocId,
    required String suggestedName,
  }) async {
    try {
      final raw = await safMethodChannel.invokeMethod<Map>(
        'move',
        {
          'srcTreeUri': srcTreeUri,
          'srcDocId': srcDocId,
          'destTreeUri': destTreeUri,
          'destDirDocId': destDirDocId,
          'suggestedName': suggestedName,
        },
      );
      if (raw == null) throw Exception('move 返回 null');
      return SafMoveResult(
        success: raw['success'] as bool,
        finalName: raw['finalName'] as String?,
        finalDocId: raw['finalDocId'] as String?,
        error: raw['error'] as String?,
      );
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 删除文件。返回是否成功。
  Future<bool> delete(String treeUri, String docId) async {
    try {
      return await safMethodChannel.invokeMethod<bool>('delete',
              {'treeUri': treeUri, 'docId': docId}) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 检查文件是否存在。
  Future<bool> exists(String treeUri, String docId) async {
    try {
      return await safMethodChannel.invokeMethod<bool>('exists',
              {'treeUri': treeUri, 'docId': docId}) ??
          false;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  /// 读取文件字节。[maxBytes] 为 0 表示不限。
  Future<Uint8List> readBytes(String treeUri, String docId,
      {int maxBytes = 0}) async {
    try {
      final raw = await safMethodChannel.invokeMethod<Uint8List>('readBytes', {
        'treeUri': treeUri,
        'docId': docId,
        'maxBytes': maxBytes,
      });
      if (raw == null) throw Exception('readBytes 返回 null');
      return raw;
    } on PlatformException catch (e) {
      throw _convertError(e);
    }
  }

  SafImageInfo _toImageInfo(Map m) => SafImageInfo(
        name: m['name'] as String,
        docId: m['docId'] as String,
        size: (m['size'] as num).toInt(),
        mime: m['mime'] as String,
      );

  SafPermissionInfo _toPermissionInfo(Map m) => SafPermissionInfo(
        uri: m['uri'] as String,
        isReadPermission: m['isReadPermission'] as bool,
        isWritePermission: m['isWritePermission'] as bool,
      );

  Exception _convertError(PlatformException e) =>
      Exception('SAF 错误 [${e.code}]: ${e.message}');
}
