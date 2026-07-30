// Scan 控制器 —— 协调文件系统扫描 + 配置 + 初始化 session
//
// 对应 Python 版 /api/scan（app.py:527-555）:
//   1. 调用 fs.scanImages 扫描目录
//   2. 读取当前 active profile 的 folders 模板
//   3. 调用 session.initFromScan 初始化会话
//   4. 持久化 lastSourceDir / lastDestParent
//
// UI 通过此 Provider 触发扫描，观察扫描状态（idle/scanning/error/done）

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/file_system_repository.dart';
import 'package:sortr_flutter/core/fs/fs_provider.dart';
import 'package:sortr_flutter/features/session/session_controller.dart';

enum ScanStatus { idle, scanning, done, error }

class ScanState {
  const ScanState({
    this.status = ScanStatus.idle,
    this.errorKey,
    this.imageCount = 0,
  });
  final ScanStatus status;
  /// 错误 i18n key（如 'dir_not_exist' / 'no_images'）
  final String? errorKey;
  final int imageCount;

  ScanState copyWith({ScanStatus? status, String? errorKey, int? imageCount}) =>
      ScanState(
        status: status ?? this.status,
        errorKey: errorKey ?? this.errorKey,
        imageCount: imageCount ?? this.imageCount,
      );
}

class ScanController extends StateNotifier<ScanState> {
  ScanController(this._fs, this._sessionController)
      : super(const ScanState());

  final FileSystemRepository _fs;
  final SessionController _sessionController;

  /// 执行扫描。
  /// [source] 源标识列表（Windows=目录路径 / 安卓=bucket id 列表）
  /// [sourceRoot] ImageRef.root 用的根标识（Windows=source.first / 安卓=MediaStore authority 常量）
  /// [destinationParent] 目标父目录
  /// [prebuiltFolders] 安卓 MediaStore 模式下预构建的 folders（path 存 RELATIVE_PATH）
  /// 返回 null 表示成功，否则返回错误 i18n key
  Future<String?> scan({
    required List<String> source,
    required String sourceRoot,
    required String destinationParent,
    required bool recursive,
    required AppConfig config,
    List<FolderDescriptor>? prebuiltFolders,
  }) async {
    state = const ScanState(status: ScanStatus.scanning);

    final result = await _fs.scanImages(source, recursive: recursive);
    if (result.error != null) {
      state = ScanState(status: ScanStatus.error, errorKey: result.error);
      return result.error;
    }
    if (result.images.isEmpty) {
      state = const ScanState(status: ScanStatus.error, errorKey: 'no_images');
      return 'no_images';
    }

    // 取当前 active profile 的文件夹模板
    final profile = config.activeProfileData;
    final templates = profile.folders;

    // 初始化 session（sourceDir = sourceRoot，run 阶段用它重建 ImageRef.root）
    _sessionController.initFromScan(
      sourceDir: sourceRoot,
      destinationParent: destinationParent,
      images: result.images,
      folderTemplates: templates,
      prebuiltFolders: prebuiltFolders,
    );

    state = ScanState(status: ScanStatus.done, imageCount: result.images.length);
    return null;
  }

  void reset() {
    state = const ScanState(status: ScanStatus.idle);
  }
}

final scanControllerProvider =
    StateNotifierProvider<ScanController, ScanState>((ref) {
  return ScanController(
    ref.watch(fileSystemRepositoryProvider),
    ref.watch(sessionControllerProvider.notifier),
  );
});
