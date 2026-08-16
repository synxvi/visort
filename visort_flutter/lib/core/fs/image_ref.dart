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
//
// [displayName]：用户可见文件名（含扩展名）。
//   - Windows = 恒为 null（调用方用 [name] 即可，name 取 relativePath 末段）
//   - 安卓 MediaStore = 真实 DISPLAY_NAME（如 "IMG_20240101.jpg"）。
//     不能用 [name]——安卓下 name 取 relativePath 末段 = _ID 数字，不可读。
//     由 MediaStore scanImages 从 MsImageInfo.name 带入。UI 统一走 [label]。

import 'package:path/path.dart' as p;

class ImageRef {
  const ImageRef({
    required this.root,
    required this.relativePath,
    required this.extension,
    this.displayName,
  });

  /// 根目录标识。Windows = 文件路径；安卓 = tree URI 字符串
  final String root;

  /// 相对路径（用 / 分隔，与 Python 版 entry.relative_to(source) 语义一致）
  /// 同时也作为 decisions 字典的 key（[id]）
  final String relativePath;

  /// 小写扩展名（含点，如 '.jpg'）
  final String extension;

  /// 用户可见文件名（安卓从 DISPLAY_NAME 带入；Windows 恒为 null）。
  /// null 时调用方应回退到 [name]。UI 统一用 [label]。
  final String? displayName;

  /// 唯一标识 = 相对路径
  String get id => relativePath;

  /// 文件名（含扩展名）—— 桌面端 = relativePath 末段。
  ///
  /// 注意：安卓 MediaStore 下 relativePath 是 _ID 数字，故此 getter 返回数字，
  /// 不是文件名。安卓 UI 应优先用 [displayName] / [label]。
  String get name => p.split(relativePath).last;

  /// 用户可见文件名：优先 [displayName]，回退 [name]。两端通用。
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : name;

  /// 值等值：ImageCache key（provider 等值）依赖本类字段相等——
  /// 缺省 identity 会让"同参数两次构造"的 provider 永远 cache miss
  ///（删除补位时 containsKey 分级全部失灵 → 回退缩略图闪烁）。
  @override
  bool operator ==(Object other) =>
      other is ImageRef &&
      other.root == root &&
      other.relativePath == relativePath &&
      other.extension == extension &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(root, relativePath, extension, displayName);

  /// 供 Desktop 实现拼接完整路径用
  String absolutePathOn(String rootPath) => p.join(rootPath, relativePath);
}
