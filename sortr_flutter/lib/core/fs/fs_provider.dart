// 按平台返回 FileSystemRepository 实现
// Windows/macOS/linux → DesktopFileSystem
// Android            → AndroidMediaStoreFileSystem（platform channel → MediaStore）
//
// 注：A0-A3 的 AndroidSafFileSystem 已标 deprecated，保留备用（非媒体文件场景）

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'android_mediastore_file_system.dart';
import 'desktop_file_system.dart';
import 'file_system_repository.dart';

/// 全局文件系统仓储 Provider
final fileSystemRepositoryProvider = Provider<FileSystemRepository>((ref) {
  if (Platform.isAndroid) {
    return AndroidMediaStoreFileSystem();
  }
  return DesktopFileSystem();
});
