// [ente 移植] 分组类型 —— 原文件：ente .../component/group/type.dart
// 简化：去掉 ente_strings/intl 依赖，标题中文硬编码，creationTime → dateAddedMs。

import 'package:flutter/widgets.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

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

  bool areFromSameGroup(MsImageInfo first, MsImageInfo second) {
    final f = DateTime.fromMicrosecondsSinceEpoch(first.dateAddedMs * 1000);
    final s = DateTime.fromMicrosecondsSinceEpoch(second.dateAddedMs * 1000);
    switch (this) {
      case GroupType.day:
        return f.year == s.year && f.month == s.month && f.day == s.day;
      case GroupType.month:
        return f.year == s.year && f.month == s.month;
      case GroupType.year:
        return f.year == s.year;
      case GroupType.week:
        final fw = f.subtract(Duration(days: f.weekday - 1));
        final sw = s.subtract(Duration(days: s.weekday - 1));
        return fw.year == sw.year && fw.month == sw.month && fw.day == sw.day;
      default:
        throw UnimplementedError("not implemented for $this");
    }
  }

  String _getDayTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month) {
      if (date.day == now.day) return "今天";
      if (date.day == now.day - 1) return "昨天";
    }
    return '${date.year}年${date.month}月${date.day}日';
  }

  String _getWeekTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    final start = date.subtract(Duration(days: date.weekday - 1));
    final end = start.add(const Duration(days: 6));
    return '${start.month}月${start.day}日 - ${end.month}月${end.day}日, ${end.year}';
  }

  String _getMonthTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    return '${date.year}年${date.month}月';
  }

  String _getYearTitle(int ts) {
    final date = DateTime.fromMicrosecondsSinceEpoch(ts);
    return '${date.year}年';
  }
}
