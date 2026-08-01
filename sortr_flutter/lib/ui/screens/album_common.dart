// 相册浏览共享辅助 —— album_screen / photo_viewer / photo_details_sheet 共用
//
// 抽出纯函数与小部件，避免 album_screen.dart 膨胀（原 825 行 → 拆分后各文件单一职责）。

import 'package:flutter/material.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

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

/// 加载更多时的占位 cell（相册网格用）。
class LoadingCell extends StatelessWidget {
  const LoadingCell({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: const Center(
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
        ),
      ),
    );
  }
}

/// 图片信息（缩略图、时间、尺寸）的展示工具，供 viewer/details 复用。
extension MsImageInfoX on MsImageInfo {
  /// 是否为横向图（宽 > 高）。仅用于布局提示；实际尺寸需 readMeta。
  bool get isLandscapeHint => false; // MsImageInfo 无尺寸，占位
}
