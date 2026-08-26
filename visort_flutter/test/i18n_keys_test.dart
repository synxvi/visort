// i18n key 对齐护栏 —— EN/ZH 两个字典的 key 集合必须完全一致。
//
// 历史事故：'photo_count' 只在 en 存在，中文界面直接显示英文原文
// "{0} photos"。新 key 漏加另一语言没有任何静态检查，此测试一分钟
// 成本防住整类事故。
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/i18n/strings_en.dart';
import 'package:visort_flutter/core/i18n/strings_zh.dart';

void main() {
  test('EN 与 ZH 的 i18n key 集合完全一致', () {
    final enKeys = stringsEn.keys.toSet();
    final zhKeys = stringsZh.keys.toSet();
    expect(enKeys.difference(zhKeys), isEmpty,
        reason: '这些 key 只有英文缺少中文：${enKeys.difference(zhKeys).toList()..sort()}');
    expect(zhKeys.difference(enKeys), isEmpty,
        reason: '这些 key 只有中文缺少英文：${zhKeys.difference(enKeys).toList()..sort()}');
  });

  test('i18n 占位符 {0} 在两种语言中个数一致', () {
    // 占位符个数不匹配时 t() 的 args 替换会静默缺失/错位。
    final enPh = <String, int>{
      for (final e in stringsEn.entries)
        if (e.value.contains('{0}')) e.key: '{0}'.allMatches(e.value).length,
    };
    for (final e in enPh.entries) {
      final zhVal = stringsZh[e.key];
      expect(zhVal, isNotNull, reason: '${e.key} 缺少中文');
      expect('{0}'.allMatches(zhVal!).length, e.value,
          reason: '${e.key} 的 {0} 占位符个数 EN(${e.value}) 与 ZH 不一致');
    }
  });
}
