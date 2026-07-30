// @deprecated 安卓 SAF 文件系统实现 —— 已被 MediaStore 方案取代（2026-07-28）
//
// 保留原因：SAF 对"非媒体文件"场景仍有价值，未来可能复用。
// 当前 fs_provider 已改指 AndroidMediaStoreFileSystem，本类不再被实例化。
//
// 历史说明（A0-A3 实现）：
//   通过 platform channel 对接 Kotlin SafPlugin。所有文件操作走 SAF：
//   - pickDirectory  → ACTION_OPEN_DOCUMENT_TREE，返回 content:// tree URI
//   - scanImages     → DocumentsContract 递归，返回 List<ImageRef>
//   - listSubdirs    → 列直接子目录
//   - move/delete    → renameDocument / deleteDocument（同 tree）或 copy+delete（跨 tree）
//   - readBytes      → ContentResolver.openInputStream
//   - readMeta       → DocumentsContract COLUMN_SIZE/LAST_MODIFIED

import 'file_system_repository.dart';
import 'image_ref.dart';
import 'saf_channel.dart';

@deprecated
class AndroidSafFileSystem implements FileSystemRepository {
  AndroidSafFileSystem({SafChannel? channel})
      : _channel = channel ?? const SafChannel();

  final SafChannel _channel;

  @override
  Future<List<String>> pickDirectories() async {
    try {
      final uri = await _channel.pickDirectory();
      return uri == null ? const [] : [uri];
    } on SafCancelledException {
      return const [];
    }
  }

  @override
  Future<ScanResult> scanImages(List<String> roots,
      {required bool recursive}) async {
    // SAF 兼容旧单根语义：取 roots 第一个作为 tree URI
    if (roots.isEmpty) return const ScanResult(images: []);
    final root = roots.first;
    // SAF scanImages 本身就是递归的；recursive=false 时忽略（SAF 无简单层级过滤，
    // 且 MVP 场景都是递归扫描，这里保持一致行为）
    try {
      final infos = await _channel.scanImages(root);
      final images = infos
          .map((info) => ImageRef(
                root: root,
                // docId 作为 relativePath（SAF 文件唯一凭证）
                relativePath: info.docId,
                extension: _extensionOf(info.name),
              ))
          .toList(growable: false);
      // 按 docId 升序，与 DesktopFileSystem 的 relativePath 排序语义对齐
      images.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      return ScanResult(images: images);
    } catch (e) {
      return ScanResult(images: const [], error: e.toString());
    }
  }

  @override
  Future<List<String>> listSubdirs(String parent) async {
    try {
      return await _channel.listSubdirs(parent);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<ImageMeta> readMeta(ImageRef ref) async {
    final meta = await _channel.readMeta(ref.root, ref.relativePath);
    final sizeKb = meta.size / 1024;
    return ImageMeta(
      absolutePath: ref.relativePath, // SAF 下显示 docId
      sizeLabel: '${sizeKb.toStringAsFixed(1)} KB',
      createdLabel: '-', // SAF 不暴露创建时间
      modifiedLabel: _formatMs(meta.modifiedMs),
    );
  }

  @override
  Future<MoveResult> move(ImageRef src, String destDir) async {
    // 安卓 SAF 下 destDir 语义：它是目标父目录的 tree URI（通常与 src.root 相同）。
    // MVP 阶段目标子目录在父 tree 内 → 同 tree 移动（renameDocument，毫秒级）。
    // destDir 格式约定：<treeUri>|<destDirDocId>（用 | 分隔，docId 可空表示 tree 根）
    final parts = destDir.split('|');
    final destTreeUri = parts[0];
    final destDirDocId = parts.length > 1 ? parts[1] : '';

    final name = _nameFromDocId(src.relativePath);
    try {
      final res = await _channel.move(
        srcTreeUri: src.root,
        srcDocId: src.relativePath,
        destTreeUri: destTreeUri,
        destDirDocId: destDirDocId,
        suggestedName: name,
      );
      return MoveResult(
        success: res.success,
        finalPath: res.finalName,
        error: res.error,
      );
    } catch (e) {
      return MoveResult(success: false, error: e.toString());
    }
  }

  @override
  Future<bool> delete(ImageRef ref) async {
    try {
      return await _channel.delete(ref.root, ref.relativePath);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Set<String>> deleteBatch(List<String> ids, String root) async {
    final ok = <String>{};
    for (final id in ids) {
      try {
        if (await _channel.delete(root, id)) ok.add(id);
      } catch (_) {}
    }
    return ok;
  }

  @override
  Future<Set<String>> moveBatch(List<String> ids, String destPath) async {
    final ok = <String>{};
    for (final id in ids) {
      // destPath = <treeUri>|<destDirDocId>
      final parts = destPath.split('|');
      if (parts.length < 2) continue;
      final name = id.split('/').last;
      try {
        final res = await _channel.move(
          srcTreeUri: parts[0],
          srcDocId: id,
          destTreeUri: parts[0],
          destDirDocId: parts[1],
          suggestedName: name,
        );
        if (res.success) ok.add(id);
      } catch (_) {}
    }
    return ok;
  }

  @override
  Future<bool> exists(ImageRef ref) async {
    try {
      return await _channel.exists(ref.root, ref.relativePath);
    } catch (_) {
      return false;
    }
  }

  @override
  String joinPath(String parent, String name) {
    // SAF 路径用 / 分隔
    final p = parent.endsWith('/')
        ? parent.substring(0, parent.length - 1)
        : parent;
    return '$p/$name';
  }

  @override
  Future<List<int>> readBytes(ImageRef ref) async {
    return await _channel.readBytes(ref.root, ref.relativePath);
  }

  // ──────────── 辅助 ────────────

  /// 从文件名提取小写扩展名（含点）
  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  /// SAF docId 形如 "primary:DCIM/IMG_001.jpg"，取最后一段作为显示名
  String _nameFromDocId(String docId) {
    final slash = docId.lastIndexOf('/');
    return slash >= 0 ? docId.substring(slash + 1) : docId;
  }

  String _formatMs(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
