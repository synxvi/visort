import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/config/folder_name_validator.dart';

void main() {
  group('folderNameInvalidKey — 目录名合法性', () {
    test('合法名返回 null', () {
      expect(folderNameInvalidKey('photos'), isNull);
      expect(folderNameInvalidKey('  photos  '), isNull); // trim 后合法
      expect(folderNameInvalidKey('2026-回顾'), isNull);
      expect(folderNameInvalidKey('中文目录'), isNull);
      expect(folderNameInvalidKey(''), isNull); // 空行走 folder N 兜底
      expect(folderNameInvalidKey('   '), isNull);
    });

    test('路径分隔符 / 与 \\ 非法', () {
      expect(folderNameInvalidKey('a/b'), 'folder_name_invalid_char');
      expect(folderNameInvalidKey(r'a\b'), 'folder_name_invalid_char');
      expect(folderNameInvalidKey('/a'), 'folder_name_invalid_char');
    });

    test('Windows 保留字符 : * ? " < > | 非法', () {
      for (final ch in [':', '*', '?', '"', '<', '>', '|']) {
        expect(folderNameInvalidKey('a${ch}b'), 'folder_name_invalid_char',
            reason: '字符 $ch 应被判非法');
      }
    });

    test('. 与 .. 路径穿越非法', () {
      expect(folderNameInvalidKey('.'), 'folder_name_invalid_char');
      expect(folderNameInvalidKey('..'), 'folder_name_invalid_char');
    });
  });

  group('folderEffectiveName — 空行兜底', () {
    test('空行按 folder N 兜底（N 从 1 起）', () {
      expect(folderEffectiveName(0, ['', '']), 'folder1');
      expect(folderEffectiveName(1, ['', '']), 'folder2');
      expect(folderEffectiveName(2, ['', '', '']), 'folder3');
    });

    test('非空名 trim 后原样返回', () {
      expect(folderEffectiveName(0, [' photos ']), 'photos');
    });
  });

  group('folderNameDupKey — 子目录重名', () {
    test('两个同名输入判重', () {
      expect(folderNameDupKey(0, ['photos', 'photos']), 'folder_name_dup');
      expect(folderNameDupKey(1, ['photos', 'photos']), 'folder_name_dup');
    });

    test('不同名不判重', () {
      expect(folderNameDupKey(0, ['photos', 'videos']), isNull);
      expect(folderNameDupKey(1, ['photos', 'videos']), isNull);
    });

    test('空行不报重（兜底名与行号绑定唯一）', () {
      expect(folderNameDupKey(0, ['', '']), isNull);
      expect(folderNameDupKey(1, ['', '']), isNull);
    });

    test('输入名与空行兜底名碰撞时，非空行判重', () {
      // 行 0 输入 "folder2"，行 1 空 → 兜底 "folder2" → 行 0 判重。
      expect(folderNameDupKey(0, ['folder2', '']), 'folder_name_dup');
      // 空行本身不报。
      expect(folderNameDupKey(1, ['folder2', '']), isNull);
    });

    test('trim 后比较，前后空格不产生假重复', () {
      expect(folderNameDupKey(0, ['photos ', 'photos']), 'folder_name_dup');
      expect(folderNameDupKey(0, ['photos', ' videos']), isNull);
    });
  });
}
