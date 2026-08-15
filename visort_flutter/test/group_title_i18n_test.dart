// 日期分组标题 i18n：en 下用英文月份（Aug 15, 2026 / August 2026），
// 无中文字符。getTitle 的 context 参数未参与格式化，仅需合法实例。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/ui/ente_viewer/group_type.dart';

void main() {
  testWidgets('en: 日期标题用英文月份缩写', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(
      builder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      },
    ));
    MsImageInfo fileAt(DateTime dt) => MsImageInfo(
          id: '1',
          name: 'a.jpg',
          size: 1,
          mime: 'image/jpeg',
          bucketId: 'b',
          dateAddedMs: dt.millisecondsSinceEpoch,
          dateModifiedMs: 0,
        );
    final day =
        GroupType.day.getTitle(ctx, fileAt(DateTime(2026, 8, 10)));
    expect(day, 'Aug 10, 2026');
    final month =
        GroupType.month.getTitle(ctx, fileAt(DateTime(2026, 8, 10)));
    expect(month, 'August 2026');
    final year =
        GroupType.year.getTitle(ctx, fileAt(DateTime(2026, 8, 10)));
    expect(year, '2026');
    final week =
        GroupType.week.getTitle(ctx, fileAt(DateTime(2026, 8, 10)));
    // 2026-08-15 是周六 → 周一 8/10 - 周日 8/16
    expect(week, 'Aug 10 – Aug 16, 2026');
  });
}
