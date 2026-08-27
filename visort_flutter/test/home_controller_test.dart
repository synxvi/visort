// HomeController 快捷键分配测试
//
// 覆盖：allocateFolderKey 纯逻辑（占用键跳过/按 KEY_ORDER 顺序/
// 大小写不敏感/回退 A-Z/全占用回退 '?'）——实例方法 allocateKey 委托它，
// 依赖 WidgetRef 的构造在 widget 测试里，纯逻辑抽顶层可单测。

import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/features/home/home_controller.dart';

FolderTemplate _t(String key) => FolderTemplate(key: key, label: 'F');

void main() {
  group('allocateFolderKey', () {
    test('空列表 → 取 KEY_ORDER 首位 A', () {
      expect(allocateFolderKey([]), 'A');
    });

    test('已占用键跳过 → 按 KEY_ORDER 顺序', () {
      expect(allocateFolderKey([_t('A'), _t('S')]), 'D');
    });

    test('小写占用同样跳过（大小写不敏感）', () {
      expect(allocateFolderKey([_t('a')]), 'S');
    });

    test('KEY_ORDER 全占用 → 回退 A-Z 剩余', () {
      // 占满 ASDFQWER1234（12 个）
      final used = 'ASDFQWER1234'.split('').map((c) => _t(c)).toList();
      expect(allocateFolderKey(used), 'B');
    });

    test('A-Z 全占用 → 数字键仍可用', () {
      // keyOrder 含数字（ASDFQWER1234），A-Z 占满后 '1' 仍返回
      final used = List.generate(
        26,
        (i) => _t(String.fromCharCode(65 + i)),
      );
      expect(allocateFolderKey(used), '1');
    });

    test('keyOrder+数字+A-Z 全占用（31 键）→ 回退 ?', () {
      // keyOrder 12 + A-Z 24（把 A-Z 中 keyOrder 已有字母算占用后仍剩 24）——
      // 全部常见键占满 → '?'。构造 42 键占满更保险。
      final used = 'ASDFQWER1234'.split('').map((c) => _t(c)).toList()
        ..addAll(List.generate(26, (i) => _t(String.fromCharCode(65 + i))));
      expect(allocateFolderKey(used), '?');
    });
  });
}
