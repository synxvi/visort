// 照片详情面板 —— ColorOS 相册式卡片栈(上划展开 / 下划关闭)
//
// 重构自两列 label-value 列表,复刻系统相册反编译(_reverse/gallery3d,包
// com.oplus.gallery)的视觉语言:
//   - 黑色面板背景(AppColors.bg)+ 顶部圆角,对标系统相册 details overlay;
//   - 卡片栈:① 时间卡(拍摄日期大字 + 文件名 + 位置)② 镜头卡(型号大字 +
//     分辨率|像素|大小|类型 横排药丸)③ 图片参数卡(ISO|EV|快门|光圈|焦距
//     横排等分)④ 文件信息卡(创建/修改/方向);
//   - 大字锚点 + 横向竖线分隔的参数药丸行(系统相册的核心设计语言,非 key-value 表);
//   - 信息缺失态占位(无相机信息 / 暂无地点信息),而非隐藏整块。
// 容器由 PhotoViewer 的 DraggableScrollableSheet 提供,本组件用其 scrollController
// 做可滚动卡片栈(上划展开、下划收起至关闭)。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

import 'album_common.dart';

class PhotoDetailsSheet extends ConsumerStatefulWidget {
  const PhotoDetailsSheet({
    super.key,
    required this.info,
    this.scrollController,
  });
  final MsImageInfo info;
  /// 由 DraggableScrollableSheet 注入的滚动控制器;null 时回退自有控制器。
  final ScrollController? scrollController;

  @override
  ConsumerState<PhotoDetailsSheet> createState() => _PhotoDetailsSheetState();
}

class _PhotoDetailsSheetState extends ConsumerState<PhotoDetailsSheet> {
  bool _loading = true;
  MsMetaInfo? _meta;
  Map<String, String> _exif = const {};
  Map<String, String> _gps = const {};
  ScrollController? _ownCtrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        const MediaStoreChannel().readMeta(widget.info.id),
        const MediaStoreChannel().getMetadata(widget.info.id),
      ]);
      _meta = results[0] as MsMetaInfo;
      final md = results[1] as Map<String, Map<String, String>>;
      _exif = md['EXIF'] ?? const {};
      _gps = md['GPS'] ?? const {};
    } catch (_) {
      // 失败不阻塞:卡片按缺省占位渲染。
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ownCtrl?.dispose();
    super.dispose();
  }

  ScrollController get _scrollCtrl =>
      widget.scrollController ?? (_ownCtrl ??= ScrollController());

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      // ★ 黑色面板背景(用户要求),顶部圆角对标系统相册 overlay 面板。
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: _loading
            ? _buildLoading()
            : ListView(
                controller: _scrollCtrl,
                padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset),
                children: [
                  _grabHandle(),
                  const SizedBox(height: 8),
                  _buildTimeCard(),
                  const SizedBox(height: 10),
                  _buildLensCard(),
                  const SizedBox(height: 10),
                  _buildImageParamCard(),
                  const SizedBox(height: 10),
                  _buildFileInfoCard(),
                ],
              ),
      ),
    );
  }

  // ─────────────── 卡片:① 时间(拍摄日期大字 + 文件名 + 位置)───────────────

  Widget _buildTimeCard() {
    final info = widget.info;
    // 拍摄时间优先 EXIF DateTime(真实拍摄时刻),否则回退 MediaStore DATE_ADDED。
    final exifDateMs = _parseExifDateTime(_exif['DateTime'] ?? '');
    final dateMs = exifDateMs ?? info.dateAddedMs;
    final dateText = formatSmartDate(dateMs,
        todayLabel: t(ref, 'today'), yesterdayLabel: t(ref, 'yesterday'));
    final lat = _gps['Latitude'];
    final lng = _gps['Longitude'];
    final hasGps = lat != null && lat.isNotEmpty;

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 拍摄日期大字锚点(对标系统相册 PhotoDetailsTimeCardView.tv_date)。
          Text(
            dateText,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 19,
              fontWeight: FontWeight.w600,
              fontFamily: 'Space Mono',
              height: 1.25,
              fontFamilyFallback: AppFonts.cjkFallback,
            ),
          ),
          const SizedBox(height: 8),
          // 文件名(次要小字)。
          Text(
            info.name,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 13,
              fontFamily: 'Space Mono',
              height: 1.3,
              fontFamilyFallback: AppFonts.cjkFallback,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          // 位置:sortr 无反地理编码与地图,显示原始经纬度;无 GPS 给占位。
          Row(
            children: [
              const Icon(Icons.place_outlined, color: AppColors.muted, size: 15),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasGps ? '$lat, $lng' : t(ref, 'detail_no_location_info'),
                  style: TextStyle(
                    color: hasGps ? AppColors.text : AppColors.muted,
                    fontSize: 12,
                    fontFamily: 'Space Mono',
                    height: 1.3,
                    fontFamilyFallback: AppFonts.cjkFallback,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────── 卡片:② 镜头(型号大字 + 分辨率|像素|大小|类型)───────────────

  Widget _buildLensCard() {
    final info = widget.info;
    final make = _exif['Make'] ?? '';
    final model = _exif['Model'] ?? '';
    final device = [make, model].where((s) => s.isNotEmpty).join(' ');
    final w = _meta?.width ?? 0;
    final h = _meta?.height ?? 0;
    final mp = (w > 0 && h > 0)
        ? '${(w * h / 1000000.0).toStringAsFixed(1)} MP'
        : '-';

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 设备型号大字锚点(对标 PhotoDetailsLensCardView.tv_model);
          // 无相机信息时占位(对标 photopage_details_no_camera_information)。
          Text(
            device.isNotEmpty ? device : t(ref, 'detail_no_camera_info'),
            style: TextStyle(
              color: device.isNotEmpty ? AppColors.text : AppColors.muted,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              fontFamily: 'Space Mono',
              height: 1.25,
              fontFamilyFallback: AppFonts.cjkFallback,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 14),
          // 横排参数药丸:分辨率(MP) | 像素尺寸 | 文件大小 | MIME 类型(竖线分隔)。
          _PillRow(cells: [
            _PillCell(value: mp, label: t(ref, 'detail_resolution')),
            _PillCell(
                value: (w > 0 && h > 0) ? '$w × $h' : '-',
                label: t(ref, 'detail_pixels')),
            _PillCell(value: formatSize(info.size), label: t(ref, 'photo_size')),
            _PillCell(
                value: mimeShortName(info.mime), label: t(ref, 'photo_type')),
          ]),
        ],
      ),
    );
  }

  // ─────────────── 卡片:③ 图片参数(ISO | EV | 快门 | 光圈 | 焦距)───────────────

  Widget _buildImageParamCard() {
    final iso = _exif['ISO'] ?? '';
    final ev = formatEv(_exif['ExposureBiasValue']);
    final shutter = formatExposureTime(_exif['ExposureTime']);
    final aperture = formatAperture(_exif['FNumber']);
    final focal = formatFocalLength(_exif['FocalLength']);
    final cells = [
      _PillCell(value: iso.isEmpty ? '-' : iso, label: t(ref, 'meta_iso')),
      _PillCell(value: ev, label: t(ref, 'detail_ev')),
      _PillCell(value: shutter, label: t(ref, 'detail_shutter')),
      _PillCell(value: aperture, label: t(ref, 'meta_aperture')),
      _PillCell(value: focal, label: t(ref, 'meta_focal')),
    ];
    final any = cells.any((c) => c.value != '-');

    return _SectionCard(
      child: any
          // 5 等分横排(对标 PhotoDetailsImageParamCardView:constraintWidth 0.2)。
          ? _PillRow(cells: cells)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                t(ref, 'detail_no_camera_info'),
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 13,
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                ),
              ),
            ),
    );
  }

  // ─────────────── 卡片:④ 文件信息(创建 / 修改 / 方向)───────────────

  Widget _buildFileInfoCard() {
    final info = widget.info;
    final orient = _exif['Orientation'] ?? '';
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t(ref, 'detail_file_info'),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: 'Space Mono',
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ),
          _kv(t(ref, 'photo_created_at'), formatDateTime(info.dateAddedMs)),
          _kv(
              t(ref, 'photo_modified_at'), formatDateTime(info.dateModifiedMs)),
          if (orient.isNotEmpty) _kv(t(ref, 'meta_orientation'), orient),
        ],
      ),
    );
  }

  // ─────────────── 小部件 ───────────────

  Widget _grabHandle() => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.muted.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _buildLoading() => ListView(
        controller: _scrollCtrl,
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          _grabHandle(),
          const SizedBox(height: 32),
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.muted,
              ),
            ),
          ),
        ],
      );

  /// key-value 行:左 muted 标签 / 右值(文件信息卡用)。
  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80,
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 13,
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                ),
              ),
            ),
          ],
        ),
      );
}

/// EXIF DateTime("2024:01:15 10:30:00") → 毫秒时间戳;解析失败返回 null。
int? _parseExifDateTime(String s) {
  final p = s.trim().split(RegExp(r'[: ]'));
  if (p.length < 6) return null;
  final dt = DateTime(
    int.tryParse(p[0]) ?? 0,
    int.tryParse(p[1]) ?? 0,
    int.tryParse(p[2]) ?? 0,
    int.tryParse(p[3]) ?? 0,
    int.tryParse(p[4]) ?? 0,
    int.tryParse(p[5]) ?? 0,
  );
  return dt.millisecondsSinceEpoch;
}

// ─────────────── 卡片容器 ───────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      );
}

// ─────────────── 参数药丸行(横向竖线分隔,对标系统相册等分参数行)───────────────

class _PillCell extends StatelessWidget {
  const _PillCell({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Tooltip(
        // 点击格子显示完整值的小气泡(对标系统相册:格子内 maxLines:1 截断,
        // 点击弹气泡看全)。triggerMode:tap → 点击触发(非默认长按)。
        message: value,
        triggerMode: TooltipTriggerMode.tap,
        showDuration: const Duration(seconds: 3),
        preferBelow: false,
        // 气泡背景与底栏/面板一致(Colors.black)。
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        textStyle: const TextStyle(
          color: AppColors.text,
          fontSize: 13,
          fontFamily: 'Space Mono',
          height: 1.2,
          fontFamilyFallback: AppFonts.cjkFallback,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFamily: 'Space Mono',
                height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                fontFamily: 'Space Mono',
                height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ],
        ),
      );
}

class _PillRow extends StatelessWidget {
  const _PillRow({required this.cells});
  final List<_PillCell> cells;
  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < cells.length; i++) {
      if (i > 0) {
        items.add(Container(
          width: 1,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          color: AppColors.border,
        ));
      }
      items.add(Expanded(child: cells[i]));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: items,
    );
  }
}
