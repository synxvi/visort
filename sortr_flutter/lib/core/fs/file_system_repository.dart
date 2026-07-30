// 文件系统仓储接口 —— 两端共享契约
//
// 业务逻辑（session/run/scan controllers）只依赖此抽象。
// 平台差异在此分叉：
//   - Windows: DesktopFileSystem（dart:io + file_picker）
//   - 安卓:    AndroidMediaStoreFileSystem（platform channel → MediaStore）
//
// scanImages/pickDirectories 改为多根（List）语义：
//   - Windows: 单目录包成单元素 list
//   - 安卓 MediaStore: 多个相册 bucket id 的列表

import 'image_ref.dart';

/// 图片元信息。对应 Python /api/image/`<index>`/meta 返回结构（app.py:585-614）
class ImageMeta {
  const ImageMeta({
    required this.absolutePath,
    required this.sizeLabel,
    required this.createdLabel,
    required this.modifiedLabel,
  });

  /// 完整路径（仅用于显示）
  final String absolutePath;
  /// "1234.5 KB"（size/1024，1 位小数）
  final String sizeLabel;
  /// "2024-01-15 14:30"
  final String createdLabel;
  /// "2024-01-16 09:00"
  final String modifiedLabel;
}

/// 移动结果
class MoveResult {
  const MoveResult({
    required this.success,
    this.finalPath,
    this.error,
  });
  final bool success;
  /// 实际落地路径（可能因冲突改名而不同于原文件名）
  final String? finalPath;
  final String? error;
}

/// 扫描结果
class ScanResult {
  const ScanResult({
    required this.images,
    this.error,
  });
  final List<ImageRef> images;
  final String? error;
}

/// 文件系统仓储抽象
abstract class FileSystemRepository {
  /// 选择一个或多个目录。
  /// Windows：返回 `[path]`（单目录，单元素 list）
  /// 安卓 MediaStore：返回所有相册 bucket id 列表（UI 层做勾选筛选）
  /// 用户取消返回空列表
  Future<List<String>> pickDirectories();

  /// 扫描多个根下的图片（按扩展名过滤、排序）。
  /// [roots] 是 pickDirectories 返回的标识列表：
  ///   - Windows = 目录路径列表
  ///   - 安卓 MediaStore = bucket id 列表
  Future<ScanResult> scanImages(List<String> roots, {required bool recursive});

  /// 列出目录的直接子文件夹（过滤 . 开头、排序）。
  /// 对应 Python /api/scan-subdirs
  Future<List<String>> listSubdirs(String parent);

  /// 读取图片元信息
  Future<ImageMeta> readMeta(ImageRef ref);

  /// 移动图片到目标目录。含同名 _1/_2 冲突改名逻辑。
  Future<MoveResult> move(ImageRef src, String destDir);

  /// 删除图片
  Future<bool> delete(ImageRef ref);

  /// 批量移动（按 id 列表 + 目标路径）。
  /// - 安卓 MediaStore：走 createWriteRequest 改 RELATIVE_PATH（系统弹窗一次确认）
  /// - Windows：逐个移动
  /// 返回成功移动的 id 集合
  Future<Set<String>> moveBatch(List<String> ids, String destPath);

  /// 批量删除（按 id 列表 + root）。
  /// - 安卓 MediaStore：走 createDeleteRequest（系统弹窗一次确认）
  /// - Windows：逐个删除
  /// 返回成功删除的 id 集合
  Future<Set<String>> deleteBatch(List<String> ids, String root);

  /// 图片是否存在
  Future<bool> exists(ImageRef ref);

  /// 拼接路径：parent + name
  String joinPath(String parent, String name);

  /// 读取图片字节（用于 UI 显示）。安卓需经 ContentResolver
  Future<List<int>> readBytes(ImageRef ref);
}

/// 支持的图片扩展名（18 种），与 Python 版 IMAGE_EXTENSIONS 一致
const imageExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
  '.tiff', '.tif', '.svg', '.ico', '.heic', '.heif',
  '.raw', '.cr2', '.nef', '.arw', '.dng', '.avif',
};
