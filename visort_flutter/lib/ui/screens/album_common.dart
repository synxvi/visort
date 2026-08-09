// 相册浏览共享辅助 —— album_screen / photo_viewer / photo_details_sheet 共用
//
// 抽出纯函数与小部件，避免 album_screen.dart 膨胀（原 825 行 → 拆分后各文件单一职责）。

import 'package:visort_flutter/core/fs/mediastore_channel.dart';

/// 从文件名取小写扩展名（含点）。无扩展名回退 '.jpg'。
String extOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '.jpg';
  return name.substring(dot).toLowerCase();
}

/// 人类可读的文件大小（B/KB/MB/GB）。
String formatSize(int bytes) {
  if (bytes <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// 毫秒时间戳 → "YYYY-MM-DD HH:MM"。
String formatDateTime(int ms) {
  if (ms <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

/// 系统相册式智能日期(用于详情时间卡大字锚点)。
/// 今天/昨天用调用方传入的本地化 label(经 t(ref,...)),其余回退纯数字日期。
/// 不在 album_common 内硬编码语言——保持 i18n 一致(label 由 UI 层提供)。
String formatSmartDate(int ms,
    {String todayLabel = '', String yesterdayLabel = ''}) {
  if (ms <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dt.year, dt.month, dt.day);
  final diffDays = today.difference(that).inDays;
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(dt.hour)}:${two(dt.minute)}';
  final ymd = '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  if (diffDays == 0 && todayLabel.isNotEmpty) return '$todayLabel $hm';
  if (diffDays == 1 && yesterdayLabel.isNotEmpty) return '$yesterdayLabel $hm';
  return '$ymd $hm';
}

/// 把 EXIF 有理数字符串("1/100"、"-3/10"、"4/1")解析为 double。失败返回 null。
double? _parseRational(String raw) {
  final s = raw.trim();
  if (s.contains('/')) {
    final parts = s.split('/');
    if (parts.length != 2) return null;
    final num = double.tryParse(parts[0]);
    final den = double.tryParse(parts[1]);
    if (num == null || den == null || den == 0) return null;
    return num / den;
  }
  return double.tryParse(s);
}

String _trimDouble(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 曝光时间(快门)。ExifInterface 返回 "1/100" 形式 → "1/100 s"。
/// ≥1s 的长曝光(如 "1/1"=1s、"5/1"=5s)直接显示秒数。无效返回 '-'。
String formatExposureTime(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '-';
  final v = _parseRational(raw);
  if (v == null || v <= 0) return '-';
  // 长曝光(≥1s)显示秒数;短曝光统一用 1/N 分数(相机标准快门标示)。
  // ExifInterface 常返回小数字符串(如 "0.008333")而非 "1/120",此处统一换算,
  // 否则会显示成 0.008333 这种一串小数。
  if (v >= 1) return '${_trimDouble(v)} s';
  final n = (1 / v).round();
  return n > 0 ? '1/$n' : '-';
}

/// 光圈。ExifInterface 的 FNumber 形如 "1.8" 或 "f/1.8" → 统一 "f/1.8"。
String formatAperture(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '-';
  if (raw.trim().toLowerCase().startsWith('f/')) return raw.trim();
  final v = _parseRational(raw);
  return v == null ? '-' : 'f/${_trimDouble(v)}';
}

/// 焦距。ExifInterface 的 FocalLength 是有理数毫米("4/1") → "4 mm"。
String formatFocalLength(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '-';
  final v = _parseRational(raw);
  return v == null ? '-' : '${_trimDouble(v)} mm';
}

/// 曝光补偿 EV。ExifInterface 返回 "-3/10" → "-0.3"；"0/1" → "0"。
String formatEv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '-';
  final v = _parseRational(raw);
  if (v == null) return '-';
  return _trimDouble(v);
}

/// MIME 短名:"image/jpeg" → "JPEG","image/png" → "PNG"。无 '/' 原样大写。
String mimeShortName(String mime) {
  if (mime.isEmpty) return '-';
  final slash = mime.indexOf('/');
  final sub = slash >= 0 ? mime.substring(slash + 1) : mime;
  return sub.toUpperCase();
}

/// 图片信息（缩略图、时间、尺寸）的展示工具，供 viewer/details 复用。
extension MsImageInfoX on MsImageInfo {
  /// 是否为横向图（宽 > 高）。仅用于布局提示；实际尺寸需 readMeta。
  bool get isLandscapeHint => false; // MsImageInfo 无尺寸，占位
}
