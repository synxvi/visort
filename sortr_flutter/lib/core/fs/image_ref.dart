// 图片引用模型 —— Windows 与安卓的统一抽象
//
// Python 版用"相对路径字符串"作为 decisions 的 key，用"绝对路径"做文件操作。
// Flutter 两端差异：
//   - Windows: 根目录是普通文件路径，操作用 dart:io File
//   - 安卓 MediaStore: 根是 content authority，操作用 MediaStore content uri
//
// 抽象方式：每个 ImageRef 持有 [root]（根标识）+ [relativePath]（相对路径/标识，统一）。
//   - Windows: root = 绝对源目录路径（如 D:\Photos），relativePath = 相对路径
//   - 安卓 MediaStore: root = `content://media/external/images/media`（authority 常量），
//     relativePath = MediaStore `_ID`（行 id，跨重启稳定的决策字典 key）
// [id] = relativePath，作为 decisions 的 key（与 Python 版语义一致）。

import 'package:path/path.dart' as p;

class ImageRef {
  const ImageRef({
    required this.root,
    required this.relativePath,
    required this.extension,
  });

  /// 根目录标识。Windows = 文件路径；安卓 = tree URI 字符串
  final String root;

  /// 相对路径（用 / 分隔，与 Python 版 entry.relative_to(source) 语义一致）
  /// 同时也作为 decisions 字典的 key（[id]）
  final String relativePath;

  /// 小写扩展名（含点，如 '.jpg'）
  final String extension;

  /// 唯一标识 = 相对路径
  String get id => relativePath;

  /// 文件名（含扩展名）
  String get name => p.split(relativePath).last;

  /// 供 Desktop 实现拼接完整路径用
  String absolutePathOn(String rootPath) => p.join(rootPath, relativePath);
}
