// 按平台返回 FileSystemRepository 实现
// Windows/macOS/linux → DesktopFileSystem
// Android            → AndroidSafFileSystem（platform channel）
// 注：安卓实现里程碑 A1，当前为骨架占位

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'android_saf_file_system.dart';
import 'desktop_file_system.dart';
import 'file_system_repository.dart';

/// 全局文件系统仓储 Provider
final fileSystemRepositoryProvider = Provider<FileSystemRepository>((ref) {
  if (Platform.isAndroid) {
    return AndroidSafFileSystem();
  }
  return DesktopFileSystem();
});
