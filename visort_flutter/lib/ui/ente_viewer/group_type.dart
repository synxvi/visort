// [ente 移植] 分组类型 —— 原文件：ente .../component/group/type.dart
// 简化：去掉 ente_strings/intl 依赖，标题中文硬编码，creationTime → dateAddedMs。

import 'package:flutter/widgets.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';

enum GroupType { day, week, month, size, year, none }

const int _microSecondsInDay = 86400000000;

extension GroupTypeExtension on GroupType {
  String get name {
    switch (this) {
      case GroupType.day: return "Day";
      case GroupType.week: return "Week";
      case GroupType.month: return "Month";
      case GroupType.size: return "Size";
      case GroupType.year: return "Year";
      case GroupType.none: return "None";
    }
  }

  bool timeGrouping() =>
      this == GroupType.day ||
      this == GroupType.week ||
      this == GroupType.month ||
      this == GroupType.year;

  bool showGroupHeader() => timeGrouping();

  bool showScrollbarDivisions() => timeGrouping();

  String getTitle(BuildContext context, MsImageInfo file) {
    final ts = file.dateAddedMs * 1000; // ms → us
    switch (this) {
      case GroupType.day: return _getDayTitle(ts);
      case GroupType.week: return _getWeekTitle(ts);
      case GroupType.year: return _getYearTitle(ts);
      case GroupType.month: return _getMonthTitle(ts);
      default: throw UnimplementedError("getTitle not implemented for $this");
    }
  }

  (int, int) getGroupRange(MsImageInfo file) {
    final date = DateTime.fromMicrosecondsSinceEpoch(file.dateAddedMs * 1000);
    switch (this) {
      case GroupType.day:
        final s = DateTime(date.year, date.month, date.day);
        return (s.microsecondsSinceEpoch, s.microsecondsSinceEpoch + _microSecondsInDay - 1);
      case GroupType.week:
        final s = DateTime(date.year, date.month, date.day).subtract(Duration(days: date.weekday - 1));
        return (s.microsecondsSinceEpoch, s.add(const Duration(days: 7)).microsecondsSinceEpoch - 1);
      case GroupType.month:
        final s = DateTime(date.year, date.month);
        return (s.microsecondsSinceEpoch, DateTime(date.year, date.month + 1).microsecondsSinceEpoch - 1);
      case GroupType.year:
        final s = DateTime(date.year);
        return (s.microsecondsSinceEpoch, DateTime(date.year + 1).microsecondsSinceEpoch - 1);
      default:
        throw UnimplementedError("not implemented for $this");
    }
  }

  /// 分组键（审查 F18）：一趟 DateTime 构造导出整数键，相邻项比较纯 int
  /// ——原逐对比较（areFromSameGroup，已并入本键方案）每对相邻项构造
  /// 2 个 DateTime，万级列表一次分组 = ~2 万次对象分配。键相等 ⇔ 同组
  /// （本地时区的年/月/日/周语义不变；week 键 = 所在周的周一 yyyymmdd）。
  int groupKeyOf(MsImageInfo file) {
    final d = DateTime.fromMillisecondsSinceEpoch(file.dateAddedMs);
    switch (this) {
      case GroupType.day:
        return d.year * 10000 + d.month * 100 + d.day;
      case GroupType.month:
        return d.year * 100 + d.month;
      case GroupType.year:
        return d.year;
      case GroupType.week:
        final s = DateTime(d.year, d.month, d.day)
            .subtract(Duration(days: d.weekday - 1));
        return s.year * 10000 + s.month * 100 + s.day;
      default:
        throw UnimplementedError("not implemented for $this");
    }
  }

  String _getDayTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month) {
      if (date.day == now.day) return tr('date_today');
      if (date.day == now.day - 1) return tr('date_yesterday');
    }
    if (currentLang == 'zh') return '${date.year}年${date.month}月${date.day}日';
    return '${_monthAbbr[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _getWeekTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    final start = date.subtract(Duration(days: date.weekday - 1));
    final end = start.add(const Duration(days: 6));
    if (currentLang == 'zh') {
      return '${start.month}月${start.day}日 - ${end.month}月${end.day}日, ${end.year}';
    }
    return '${_monthAbbr[start.month - 1]} ${start.day} – '
        '${_monthAbbr[end.month - 1]} ${end.day}, ${end.year}';
  }

  String _getMonthTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    if (currentLang == 'zh') return '${date.year}年${date.month}月';
    return '${_monthFull[date.month - 1]} ${date.year}';
  }

  String _getYearTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    if (currentLang == 'zh') return '${date.year}年';
    return '${date.year}';
  }

  static const _monthAbbr = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _monthFull = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
}
