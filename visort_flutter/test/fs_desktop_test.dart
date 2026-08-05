// Desktop 文件系统逻辑验证 —— 确认扫描/移动/冲突改名行为与 Python 版一致
// 在临时目录中创建测试图片，验证 DesktopFileSystem 各方法

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:visort_flutter/core/fs/desktop_file_system.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';

void main() {
  late Directory tempDir;
  late DesktopFileSystem fs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sortr_test_');
    fs = DesktopFileSystem();
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> createImage(String relPath) async {
    final f = File(p.join(tempDir.path, relPath));
    await f.parent.create(recursive: true);
    // 写入最小合法 PNG（1x1 透明）
    const pngBytes = [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ];
    await f.writeAsBytes(pngBytes);
    return f;
  }

  group('scanImages', () {
    test('递归扫描：含子目录，按路径排序', () async {
      await createImage('b.jpg');
      await createImage('sub/a.jpg');
      await createImage('c.png');
      await createImage('ignore.txt'); // 非图片
      await createImage('.hidden.jpg'); // 不排除（Python 版也不排除隐藏文件）

      final result = await fs.scanImages([tempDir.path], recursive: true);
      expect(result.error, isNull);
      // 子目录文件排在前面（sub/a.jpg < b.jpg，因 's' > 'b'，实际 b 在前）
      final names = result.images.map((e) => e.relativePath).toList();
      expect(names, containsAll(['b.jpg', 'sub/a.jpg', 'c.png']));
      expect(names, isNot(contains('ignore.txt')));
      // 排序：b.jpg, c.png, sub/a.jpg（按字符串升序）
      expect(names, ['.hidden.jpg', 'b.jpg', 'c.png', 'sub/a.jpg']);
    });

    test('同层级：不含子目录文件', () async {
      await createImage('top.jpg');
      await createImage('sub/nested.jpg');
      final result = await fs.scanImages([tempDir.path], recursive: false);
      final names = result.images.map((e) => e.relativePath).toList();
      expect(names, ['top.jpg']);
    });

    test('扩展名过滤：18 种图片格式全部识别', () async {
      final exts = [
        '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tiff', '.tif',
        '.svg', '.ico', '.heic', '.heif', '.raw', '.cr2', '.nef', '.arw',
        '.dng', '.avif'
      ];
      for (final ext in exts) {
        await createImage('file$ext');
      }
      final result = await fs.scanImages([tempDir.path], recursive: false);
      expect(result.images.length, exts.length);
    });

    test('目录不存在 → dir_not_exist', () async {
      final result =
          await fs.scanImages([p.join(tempDir.path, 'nope')], recursive: true);
      expect(result.error, 'dir_not_exist');
    });
  });

  group('listSubdirs', () {
    test('列出直接子目录，过滤 . 开头，排序', () async {
      await Directory(p.join(tempDir.path, 'Bravo')).create();
      await Directory(p.join(tempDir.path, 'Alpha')).create();
      await Directory(p.join(tempDir.path, '.hidden')).create();
      await File(p.join(tempDir.path, 'file.txt')).create();

      final subdirs = await fs.listSubdirs(tempDir.path);
      expect(subdirs, ['Alpha', 'Bravo']);
    });
  });

  group('move + 冲突改名', () {
    test('普通移动：创建目标目录、移动成功', () async {
      await createImage('src.jpg');
      final destDir = p.join(tempDir.path, 'dest');
      final ref = ImageRef(
        root: tempDir.path,
        relativePath: 'src.jpg',
        extension: '.jpg',
      );
      final result = await fs.move(ref, destDir);
      expect(result.success, true);
      expect(result.finalPath, p.join(destDir, 'src.jpg'));
      // 源已不存在
      expect(File(p.join(tempDir.path, 'src.jpg')).existsSync(), false);
      // 目标存在
      expect(File(result.finalPath!).existsSync(), true);
    });

    test('同名冲突 → 追加 _1 后缀', () async {
      await createImage('src.jpg');
      final destDir = p.join(tempDir.path, 'dest');
      await Directory(destDir).create();
      // 预先放一个同名文件
      await File(p.join(destDir, 'src.jpg')).writeAsBytes([1, 2, 3]);

      final ref = ImageRef(
        root: tempDir.path,
        relativePath: 'src.jpg',
        extension: '.jpg',
      );
      final result = await fs.move(ref, destDir);
      expect(result.success, true);
      expect(result.finalPath, p.join(destDir, 'src_1.jpg'));
      expect(File(result.finalPath!).existsSync(), true);
      // 原同名文件未被覆盖
      expect(File(p.join(destDir, 'src.jpg')).lengthSync(), 3);
    });

    test('多重冲突 → _1, _2', () async {
      await createImage('src.jpg');
      final destDir = p.join(tempDir.path, 'dest');
      await Directory(destDir).create();
      await File(p.join(destDir, 'src.jpg')).writeAsBytes([1]);
      await File(p.join(destDir, 'src_1.jpg')).writeAsBytes([2]);

      final ref = ImageRef(
        root: tempDir.path,
        relativePath: 'src.jpg',
        extension: '.jpg',
      );
      final result = await fs.move(ref, destDir);
      expect(result.finalPath, p.join(destDir, 'src_2.jpg'));
    });

    test('源文件缺失 → source_missing', () async {
      final ref = ImageRef(
        root: tempDir.path,
        relativePath: 'ghost.jpg',
        extension: '.jpg',
      );
      final result = await fs.move(ref, p.join(tempDir.path, 'dest'));
      expect(result.success, false);
      expect(result.error, 'source_missing');
    });
  });

  group('delete / exists / readMeta', () {
    test('delete 删除成功', () async {
      await createImage('victim.jpg');
      final ref = ImageRef(
        root: tempDir.path,
        relativePath: 'victim.jpg',
        extension: '.jpg',
      );
      expect(await fs.exists(ref), true);
      expect(await fs.delete(ref), true);
      expect(await fs.exists(ref), false);
    });

    test('readMeta 返回格式化字段', () async {
      await createImage('meta.jpg');
      final ref = ImageRef(
        root: tempDir.path,
        relativePath: 'meta.jpg',
        extension: '.jpg',
      );
      final meta = await fs.readMeta(ref);
      expect(meta.sizeLabel, contains('KB'));
      // 日期格式 yyyy-MM-dd HH:mm
      expect(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$').hasMatch(meta.createdLabel), true);
    });
  });
}
