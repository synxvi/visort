// 照片详情底部抽屉 —— PhotoViewer 的 info 入口
//
// 从 album_screen.dart 拆出。两列详情列表（左标签 / 右值），分辨率异步从
// MediaStoreChannel.readMeta 取（MsMetaInfo.width/height）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

import 'album_common.dart';

/// 详情底部抽屉：两列详情列表（左标签 / 右值），按可读性排序。
/// 分辨率异步从 MediaStoreChannel.readMeta 取（MsMetaInfo.width/height）。
class PhotoDetailsSheet extends ConsumerStatefulWidget {
  const PhotoDetailsSheet({super.key, required this.info});
  final MsImageInfo info;

  @override
  ConsumerState<PhotoDetailsSheet> createState() => _PhotoDetailsSheetState();
}

class _PhotoDetailsSheetState extends ConsumerState<PhotoDetailsSheet> {
  late Future<MsMetaInfo> _metaFuture;
  late Future<Map<String, Map<String, String>>> _metaExifFuture;

  @override
  void initState() {
    super.initState();
    _metaFuture = const MediaStoreChannel().readMeta(widget.info.id);
    _metaExifFuture = const MediaStoreChannel().getMetadata(widget.info.id);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: bottomInset),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部拖拽指示条
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.muted.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 标题
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              t(ref, 'photo_details'),
              style: const TextStyle(fontFamily: 'Space Mono', 
                color: AppColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ),
          _row(t(ref, 'photo_filename'), info.name),
          // 分辨率行：异步
          FutureBuilder<MsMetaInfo>(
            future: _metaFuture,
            builder: (ctx, snap) {
              String value;
              if (snap.connectionState != ConnectionState.done) {
                value = '...';
              } else if (snap.hasError || snap.data == null) {
                value = '-';
              } else {
                final w = snap.data!.width;
                final h = snap.data!.height;
                final mp = (w * h) / 1000000.0;
                value = '$w × $h (${mp.toStringAsFixed(1)} MP)';
              }
              return _row(t(ref, 'photo_dimensions'), value);
            },
          ),
          _row(t(ref, 'photo_size'), formatSize(info.size)),
          _row(t(ref, 'photo_type'), info.mime.isEmpty ? '-' : info.mime),
          _row(t(ref, 'photo_created_at'), formatDateTime(info.dateAddedMs)),
          _row(t(ref, 'photo_modified_at'), formatDateTime(info.dateModifiedMs)),
          // EXIF/元数据（P0）：异步分组渲染
          FutureBuilder<Map<String, Map<String, String>>>(
            future: _metaExifFuture,
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return _row(t(ref, 'meta_section_exif'), '...');
              }
              final data = snap.data;
              if (snap.hasError || data == null || data.isEmpty) {
                return const SizedBox.shrink();
              }
              final rows = <Widget>[_row(t(ref, 'meta_section_exif'), '')];
              data.forEach((group, entries) {
                rows.add(_metaGroupTitle(group));
                entries.forEach((k, v) => rows.add(_row(_metaLabel(k), v)));
              });
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 一行详情：左标签（muted SpaceMono 小字）/ 右值（text，可折行）
  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontFamily: 'Space Mono', height: 1.2,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'Space Mono', 
                color: AppColors.text,
                fontSize: 13,
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// EXIF 原始 key → 可读 i18n 标签（未命中则原样返回）。
  String _metaLabel(String key) {
    const map = <String, String>{
      'Make': 'meta_make',
      'Model': 'meta_model',
      'Software': 'meta_software',
      'FNumber': 'meta_aperture',
      'ExposureTime': 'meta_exposure',
      'ISO': 'meta_iso',
      'FocalLength': 'meta_focal',
      'DateTime': 'meta_date_taken',
      'Orientation': 'meta_orientation',
      'Latitude': 'meta_lat',
      'Longitude': 'meta_lng',
    };
    final k = map[key];
    return k == null ? key : t(ref, k);
  }

  /// EXIF 分组标题（粗体小字）。
  Widget _metaGroupTitle(String group) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Text(
        group,
        style: const TextStyle(fontFamily: 'Space Mono', 
          color: AppColors.text,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: AppFonts.cjkFallback,
        ),
      ),
    );
  }
}
