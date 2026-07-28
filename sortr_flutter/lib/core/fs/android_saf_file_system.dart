// 安卓 SAF 文件系统实现 —— 骨架（里程碑 A1 完整实现）
//
// 安卓 11+ 的 Scoped Storage 禁止用 java.io.File 访问任意目录，必须走 SAF：
//   - pickDirectory  → ACTION_OPEN_DOCUMENT_TREE，返回 content:// tree URI
//   - scanImages     → DocumentsContract.buildChildDocumentsUriUsingTree 递归
//   - move/delete    → DocumentsContract.renameDocument / deleteDocument
//   - readBytes      → ContentResolver.openInputStream
//
// 因 SAF 必须原生 Kotlin 实现，全部通过 platform channel 桥接。
// 本文件为占位，方法抛 UnimplementedError；里程碑 A0/A1 完成 channel 联调后填充。

import 'file_system_repository.dart';
import 'image_ref.dart';

class AndroidSafFileSystem implements FileSystemRepository {
  @override
  Future<String?> pickDirectory() {
    throw UnimplementedError('SAF pickDirectory 待里程碑 A1 实现');
  }

  @override
  Future<ScanResult> scanImages(String root, {required bool recursive}) {
    throw UnimplementedError('SAF scanImages 待里程碑 A1 实现');
  }

  @override
  Future<List<String>> listSubdirs(String parent) {
    throw UnimplementedError('SAF listSubdirs 待里程碑 A1 实现');
  }

  @override
  Future<ImageMeta> readMeta(ImageRef ref) {
    throw UnimplementedError('SAF readMeta 待里程碑 A1 实现');
  }

  @override
  Future<MoveResult> move(ImageRef src, String destDir) {
    throw UnimplementedError('SAF move 待里程碑 A1 实现');
  }

  @override
  Future<bool> delete(ImageRef ref) {
    throw UnimplementedError('SAF delete 待里程碑 A1 实现');
  }

  @override
  Future<bool> exists(ImageRef ref) {
    throw UnimplementedError('SAF exists 待里程碑 A1 实现');
  }

  @override
  String joinPath(String parent, String name) {
    // SAF 路径用 / 分隔
    final p = parent.endsWith('/') ? parent.substring(0, parent.length - 1) : parent;
    return '$p/$name';
  }

  @override
  Future<List<int>> readBytes(ImageRef ref) {
    throw UnimplementedError('SAF readBytes 待里程碑 A1 实现');
  }
}
