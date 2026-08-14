// [ente 移植] 文件类型 —— 简化版（去掉 photo_manager/ente_strings 依赖）
// 原文件：ente mobile/apps/photos/lib/models/file/file_type.dart

enum FileType { image, video, livePhoto, other }

/// 由 MediaStore mime 推断文件类型（ente 用 photo_manager AssetType）。
FileType fileTypeFromMime(String mime) {
  final m = mime.toLowerCase();
  if (m.startsWith('image/')) return FileType.image;
  if (m.startsWith('video/')) return FileType.video;
  return FileType.other;
}
