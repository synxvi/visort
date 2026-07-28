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
  /// [source] 源目录、[destinationParent] 目标父目录、[recursive] 是否递归
  /// 返回 null 表示成功，否则返回错误 i18n key
  Future<String?> scan({
    required String source,
    required String destinationParent,
    required bool recursive,
    required AppConfig config,
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

    // 初始化 session
    _sessionController.initFromScan(
      sourceDir: source,
      destinationParent: destinationParent,
      images: result.images,
      folderTemplates: templates,
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
