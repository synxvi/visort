// ScanController 状态机 + 重入保护测试
//
// 覆盖：
//   - 正常扫描 → done + imageCount
//   - 空图库 → no_images 错误 key
//   - 扫描错误 → error + errorKey 透传
//   - 重入保护：首扫进行中第二次 scan 直接返回（不重复扫描/状态机不乱）

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/file_system_repository.dart';
import 'package:visort_flutter/core/fs/fs_provider.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/features/scan/scan_controller.dart';

/// 内存文件系统：scanImages 可注入延迟/结果，供重入并发测试。
class _FakeFs implements FileSystemRepository {
  _FakeFs({
    this.images = const [],
    this.error,
    this.scanDelay = Duration.zero,
  });

  final List<ImageRef> images;
  final String? error;
  final Duration scanDelay;

  /// 被调用的扫描次数（重入测试断言只扫一次）
  int scanCalls = 0;
  /// 已完成扫描次数（完成时 +1；重入测试第二次调用应在完成前返回 null）
  int scanCompleted = 0;
  final _scanStarted = Completer<void>();

  Future<ScanResult> scanImages(
    List<String> roots, {
    required bool recursive,
    SortBy? sortBy,
    bool asc = false,
  }) async {
    scanCalls++;
    if (!_scanStarted.isCompleted) _scanStarted.complete();
    if (scanDelay > Duration.zero) {
      await Future<void>.delayed(scanDelay);
    }
    scanCompleted++;
    return ScanResult(images: images, error: error);
  }

  Future<List<String>> pickDirectories() async => const [];
  Future<List<String>> listSubdirs(String parent) async => const [];
  Future<ImageMeta> readMeta(ImageRef ref) async =>
      const ImageMeta(
        absolutePath: '',
        sizeLabel: '0 KB',
        createdLabel: '2024-01-01 00:00',
        modifiedLabel: '2024-01-01 00:00',
      );
  Future<MoveResult> move(ImageRef src, String destDir) async =>
      const MoveResult(success: true);
  Future<bool> delete(ImageRef ref) async => true;
  Future<Set<String>> moveBatch(List<String> ids, String destPath, String root) async =>
      ids.toSet();
  Future<Set<String>> deleteBatch(List<String> ids, String root) async =>
      ids.toSet();
  Future<bool> exists(ImageRef ref) async => true;
  String joinPath(String parent, String name) => '$parent/$name';
  Future<List<int>> readBytes(ImageRef ref) async => const [];
}

ImageRef _img(String rel) =>
    ImageRef(root: r'D:\src', relativePath: rel, extension: '.jpg');

AppConfig _config() => const AppConfig(
      activeProfile: 'Default',
      profiles: {
        'Default': Profile(
          folders: [],
          actionKeys: ActionKeys(undo: 'Z', delete: 'X', skip: 'C'),
        ),
      },
    );

void main() {
  late ProviderContainer container;
  late _FakeFs fs;

  tearDown(() => container.dispose());

  Future<String?> scan() {
    return container.read(scanControllerProvider.notifier).scan(
          source: const [r'D:\src'],
          sourceRoot: r'D:\src',
          destinationParent: r'D:\Dest',
          recursive: true,
          config: _config(),
        );
  }

  ProviderContainer makeContainer(_FakeFs f) {
    fs = f;
    container = ProviderContainer(overrides: [
      fileSystemRepositoryProvider.overrideWithValue(f),
    ]);
    return container;
  }

  group('状态机', () {
    test('空图库 → no_images 错误 key', () async {
      makeContainer(_FakeFs());
      final err = await scan();
      expect(err, 'no_images');
      final st = container.read(scanControllerProvider);
      expect(st.status, ScanStatus.error);
      expect(st.errorKey, 'no_images');
    });

    test('扫描出错 → errorKey 透传', () async {
      makeContainer(_FakeFs(error: 'dir_not_exist'));
      final err = await scan();
      expect(err, 'dir_not_exist');
      final st = container.read(scanControllerProvider);
      expect(st.status, ScanStatus.error);
      expect(st.errorKey, 'dir_not_exist');
    });

    test('正常扫描 → done + imageCount', () async {
      makeContainer(_FakeFs(images: [_img('a.jpg'), _img('b.jpg')]));
      final err = await scan();
      expect(err, isNull);
      final st = container.read(scanControllerProvider);
      expect(st.status, ScanStatus.done);
      expect(st.imageCount, 2);
    });

    test('状态复位 → idle', () async {
      makeContainer(_FakeFs(images: [_img('a.jpg')]));
      await scan();
      container.read(scanControllerProvider.notifier).reset();
      expect(container.read(scanControllerProvider).status, ScanStatus.idle);
    });
  });

  group('重入保护', () {
    test('首扫进行中第二次 scan 直接返回 null 且不重复扫描', () async {
      final slow = _FakeFs(
        images: [_img('a.jpg')],
        scanDelay: const Duration(milliseconds: 100),
      );
      makeContainer(slow);
      final ctrl = container.read(scanControllerProvider.notifier);

      // 第一次扫描（异步，未等待完成）
      final f1 = ctrl.scan(
        source: const [r'D:\src'],
        sourceRoot: r'D:\src',
        destinationParent: r'D:\Dest',
        recursive: true,
        config: _config(),
      );
      // 等扫描真正启动（_scanning 已置位）
      await slow._scanStarted.future;
      // 第二次：应立即返回 null（重入拦截，不重复扫描）
      final r2 = await ctrl.scan(
        source: const [r'D:\src'],
        sourceRoot: r'D:\src',
        destinationParent: r'D:\Dest',
        recursive: true,
        config: _config(),
      );
      expect(r2, isNull);
      expect(slow.scanCalls, 1); // 只扫了一次
      await f1; // 首扫完成
      expect(slow.scanCompleted, 1);
      expect(container.read(scanControllerProvider).status, ScanStatus.done);
    });

    test('首扫完成后再扫（reset 后）允许扫描', () async {
      final fast = _FakeFs(images: [_img('a.jpg')]);
      makeContainer(fast);
      final ctrl = container.read(scanControllerProvider.notifier);
      await ctrl.scan(
        source: const [r'D:\src'],
        sourceRoot: r'D:\src',
        destinationParent: r'D:\Dest',
        recursive: true,
        config: _config(),
      );
      expect(fast.scanCalls, 1);
      // 扫描完成后重入标志已释放：再次扫描允许（二次扫描不同源也可扫）。
      // 但 ScanController 扫描成功不自动置 idle？_scanning 在 finally 释放即可。
      final r2 = await ctrl.scan(
        source: const [r'D:\src'],
        sourceRoot: r'D:\src',
        destinationParent: r'D:\Dest',
        recursive: true,
        config: _config(),
      );
      expect(r2, isNull); // 再次成功（非重入拦截）
      expect(fast.scanCalls, 2);
    });
  });
}
