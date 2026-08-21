// Desktop 文件系统实现（Windows / macOS / Linux）
//
// 对应 Python 版的文件操作逻辑：
//   - 扫描:    Path.rglob/glob + sorted + 扩展名过滤（app.py:527-534）
//   - 移动:    makedirs + 同名改名 + shutil.move（含跨盘 copy+delete 回退）（app.py:749-761）
//   - 删除:    os.remove（app.py:727-732）
//   - 元数据:  os.stat（app.py:585-614）
//   - 选目录:  tkinter filedialog（app.py:801-814）→ 改用 file_picker
//   - 子目录:  Path.iterdir 过滤 . 开头（app.py:820-836）

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:visort_flutter/core/config/models.dart';

import 'file_system_repository.dart';
import 'image_ref.dart';

class DesktopFileSystem implements FileSystemRepository {
  DesktopFileSystem();

  @override
  Future<List<String>> pickDirectories() async {
    // file_picker 12：getDirectoryPath 改静态方法（原 FilePicker.platform 已移除）
    final result = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select directory',
    );
    // 单目录包成单元素 list（用户取消返回空 list）
    return result == null ? const [] : [result];
  }

  @override
  Future<ScanResult> scanImages(
    List<String> roots, {
    required bool recursive,
    SortBy? sortBy,
    bool asc = false,
  }) async {
    // 桌面端按相对路径排序(sortBy/asc 仅安卓 MediaStore 用,此处忽略)。
    final images = <ImageRef>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) {
        return ScanResult(images: const [], error: 'dir_not_exist');
      }
      // 递归 vs 同层级
      final entities = dir.list(recursive: recursive, followLinks: false);
      await for (final entry in entities) {
        if (entry is File) {
          final ext = p.extension(entry.path).toLowerCase();
          if (imageExtensions.contains(ext)) {
            final rel = p.relative(entry.path, from: root);
            // 统一用 / 作为相对路径分隔符（与 Python relative_to 跨平台一致）
            final relNormalized = rel.replaceAll(r'\', '/');
            images.add(
              ImageRef(root: root, relativePath: relNormalized, extension: ext),
            );
          }
        }
      }
    }
    // 按全相对路径字符串升序，对应 sorted(entries)
    images.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return ScanResult(images: images);
  }

  @override
  Future<List<String>> listSubdirs(String parent) async {
    final dir = Directory(parent);
    if (!dir.existsSync()) return const [];
    final names = <String>[];
    await for (final entry in dir.list(recursive: false, followLinks: false)) {
      if (entry is Directory) {
        final name = p.basename(entry.path);
        if (!name.startsWith('.')) names.add(name);
      }
    }
    names.sort();
    return names;
  }

  @override
  Future<ImageMeta> readMeta(ImageRef ref) async {
    final file = File(p.join(ref.root, ref.relativePath));
    final stat = file.statSync();
    final sizeKb = stat.size / 1024;
    return ImageMeta(
      absolutePath: file.absolute.path,
      sizeLabel: '${sizeKb.toStringAsFixed(1)} KB',
      createdLabel: _formatDateTime(stat.changed),
      modifiedLabel: _formatDateTime(stat.modified),
    );
  }

  @override
  Future<MoveResult> move(ImageRef src, String destDir) async {
    final srcFile = File(p.join(src.root, src.relativePath));
    if (!srcFile.existsSync()) {
      return const MoveResult(success: false, error: 'source_missing');
    }
    try {
      // 创建目标目录
      await Directory(destDir).create(recursive: true);

      // 同名冲突改名：base_1.ext, base_2.ext, ...
      final baseName = p.basename(srcFile.path);
      var destPath = p.join(destDir, baseName);
      if (File(destPath).existsSync()) {
        final ext = p.extension(baseName);
        final baseNoExt = p.basenameWithoutExtension(baseName);
        var counter = 1;
        while (File(destPath).existsSync()) {
          destPath = p.join(destDir, '${baseNoExt}_$counter$ext');
          counter++;
        }
      }

      // 移动：同盘 rename（原子），跨盘 rename 抛异常 → copy+delete 回退
      try {
        await srcFile.rename(destPath);
      } on FileSystemException {
        // 跨设备：复制后删除
        await srcFile.copy(destPath);
        await srcFile.delete();
      }
      return MoveResult(success: true, finalPath: destPath);
    } catch (e) {
      return MoveResult(success: false, error: e.toString());
    }
  }

  @override
  Future<bool> delete(ImageRef ref) async {
    final file = File(p.join(ref.root, ref.relativePath));
    if (!file.existsSync()) return false;
    try {
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Set<String>> deleteBatch(List<String> ids, String root) async {
    // 桌面端逐个删除，返回成功集合
    final ok = <String>{};
    for (final id in ids) {
      final file = File(p.join(root, id));
      try {
        if (file.existsSync()) {
          await file.delete();
          ok.add(id);
        }
      } catch (_) {}
    }
    return ok;
  }

  @override
  Future<Set<String>> moveBatch(
    List<String> ids,
    String destPath,
    String root,
  ) async {
    // 桌面端逐个移动：ids 是相对 root 的路径，拼成绝对路径再移。
    // （历史 bug：旧签名无 root，调用方传相对路径而实现当绝对路径用 → existsSync 恒 false → 全部 move_failed）
    final ok = <String>{};
    for (final id in ids) {
      try {
        await Directory(destPath).create(recursive: true);
        final srcFile = File(p.join(root, id));
        if (srcFile.existsSync()) {
          // 同名冲突改名：base_1.ext, base_2.ext, ...
          var finalPath = p.join(destPath, p.basename(id));
          if (File(finalPath).existsSync()) {
            final ext = p.extension(id);
            final baseNoExt = p.basenameWithoutExtension(id);
            var counter = 1;
            while (File(finalPath).existsSync()) {
              finalPath = p.join(destPath, '${baseNoExt}_$counter$ext');
              counter++;
            }
          }
          try {
            await srcFile.rename(finalPath);
          } on FileSystemException {
            // 跨设备：复制后删除
            await srcFile.copy(finalPath);
            await srcFile.delete();
          }
          ok.add(id);
        }
      } catch (_) {}
    }
    return ok;
  }

  @override
  Future<bool> exists(ImageRef ref) async {
    final file = File(p.join(ref.root, ref.relativePath));
    return file.existsSync();
  }

  @override
  String joinPath(String parent, String name) => p.join(parent, name);

  @override
  Future<List<int>> readBytes(ImageRef ref) async {
    final file = File(p.join(ref.root, ref.relativePath));
    return file.readAsBytes();
  }

  String _formatDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
