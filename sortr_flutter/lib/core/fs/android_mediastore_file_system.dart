// 安卓 MediaStore 文件系统实现 —— 取代 SAF 方案
//
// 通过 platform channel 对接 Kotlin MediaStorePlugin。所有操作走 MediaStore.Images.Media：
//   - pickDirectories → listBuckets 返回所有 bucket id（UI 层做勾选）
//   - scanImages      → 按 bucket id 列表查询
//   - readMeta/readBytes → 按 _ID 查询
//   - move            → 打标签语义（不真移动，返回成功）
//   - deleteBatch     → createDeleteRequest 系统弹窗批量删除
//
// ImageRef 编码：
//   - root         = IMAGES_AUTHORITY 常量（content://media/external/images/media）
//   - relativePath = MediaStore _ID（稳定主键，决策字典 key）

import 'file_system_repository.dart';
import 'image_ref.dart';
import 'mediastore_channel.dart';

/// MediaStore Images 的 authority 常量（与 Kotlin IMAGES_AUTHORITY 对齐）
const kImagesAuthority = 'content://media/external/images/media';

class AndroidMediaStoreFileSystem implements FileSystemRepository {
  AndroidMediaStoreFileSystem({MediaStoreChannel? channel})
      : _channel = channel ?? const MediaStoreChannel();

  final MediaStoreChannel _channel;

  @override
  Future<List<String>> pickDirectories() async {
    // 返回所有相册 bucket id（UI 层 setup_screen 做勾选筛选）
    final hasPerm = await _channel.hasPermission();
    if (!hasPerm) {
      final granted = await _channel.requestPermission();
      if (!granted) return const [];
    }
    try {
      final buckets = await _channel.listBuckets();
      return buckets.map((b) => b.id).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<ScanResult> scanImages(List<String> roots,
      {required bool recursive}) async {
    // roots = bucket id 列表（recursive 在 MediaStore 无意义）
    try {
      final infos = await _channel.scanImages(roots);
      final images = infos
          .map((info) => ImageRef(
                root: kImagesAuthority,
                relativePath: info.id, // _ID 作为决策字典 key
                extension: _extensionOf(info.name),
              ))
          .toList(growable: false);
      // 按 _ID 排序（与桌面端 relativePath 排序语义对齐）
      images.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      return ScanResult(images: images);
    } catch (e) {
      return ScanResult(images: const [], error: e.toString());
    }
  }

  @override
  Future<List<String>> listSubdirs(String parent) async {
    // MediaStore 无子目录概念；返回 bucket 列表作为"子目录"
    try {
      final buckets = await _channel.listBuckets();
      return buckets.map((b) => b.name).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<ImageMeta> readMeta(ImageRef ref) async {
    final meta = await _channel.readMeta(ref.relativePath);
    final sizeKb = meta.size / 1024;
    return ImageMeta(
      absolutePath: ref.relativePath,
      sizeLabel: '${sizeKb.toStringAsFixed(1)} KB',
      createdLabel: '-',
      modifiedLabel: _formatMs(meta.modifiedMs),
    );
  }

  @override
  Future<MoveResult> move(ImageRef src, String destDir) async {
    // destDir = 目标 RELATIVE_PATH（如 "Pictures/QQ" 或 "Pictures/整理结果/保留"）
    // 单图移动：run_controller 实际走 moveBatch 批量，这里保留单图兼容
    try {
      final count = await _channel.requestMove([src.relativePath], destDir);
      return MoveResult(
        success: count > 0,
        finalPath: count > 0 ? destDir : null,
      );
    } catch (e) {
      return MoveResult(success: false, error: e.toString());
    }
  }

  @override
  Future<Set<String>> moveBatch(List<String> ids, String destPath) async {
    // 批量移动（createWriteRequest 改 RELATIVE_PATH，一次系统弹窗）
    if (ids.isEmpty) return const {};
    try {
      final count = await _channel.requestMove(ids, destPath);
      return count == ids.length ? ids.toSet() : <String>{};
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<bool> delete(ImageRef ref) async {
    // 单个删除（run_controller 实际走 deleteBatch 批量）
    try {
      final count = await _channel.requestDelete([ref.relativePath]);
      return count > 0;
    } on MsDeleteCancelledException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Set<String>> deleteBatch(List<String> ids, String root) async {
    // 批量删除（createDeleteRequest 一次系统弹窗）
    if (ids.isEmpty) return const {};
    try {
      final count = await _channel.requestDelete(ids);
      // requestDelete 返回成功数；系统弹窗确认后全部删除（返回 ids.size）
      // 若用户取消，抛 MsDeleteCancelledException（被 catch 返回空集）
      return count == ids.length ? ids.toSet() : <String>{};
    } on MsDeleteCancelledException {
      return const {};
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<bool> exists(ImageRef ref) async {
    return await _channel.exists(ref.relativePath);
  }

  @override
  String joinPath(String parent, String name) {
    final p = parent.endsWith('/')
        ? parent.substring(0, parent.length - 1)
        : parent;
    return '$p/$name';
  }

  @override
  Future<List<int>> readBytes(ImageRef ref) async {
    return await _channel.readBytes(ref.relativePath);
  }

  // ──────────── 辅助 ────────────

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot).toLowerCase();
  }

  String _formatMs(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
