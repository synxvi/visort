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
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

import 'album_common.dart';

class PhotoDetailsSheet extends ConsumerStatefulWidget {
  const PhotoDetailsSheet({
    super.key,
    required this.info,
    this.scrollController,
    this.scrollable = true,
  });
  final MsImageInfo info;

  /// 由 DraggableScrollableSheet 注入的滚动控制器;null 时回退自有控制器。
  final ScrollController? scrollController;

  /// true=内容可滚动(ListView,旧 DSS 用);false=固定不滚动(Overlay 自有面板用,
  /// 避免内部 ListView 与外层拖拽手势冲突)。内容超出时由父级裁剪,不溢出黄线。
  final bool scrollable;

  @override
  ConsumerState<PhotoDetailsSheet> createState() => _PhotoDetailsSheetState();
}

class _PhotoDetailsSheetState extends ConsumerState<PhotoDetailsSheet> {
  bool _loading = true;
  MsMetaInfo? _meta;
  Map<String, String> _exif = const {};
  Map<String, String> _gps = const {};
  String? _filePath;
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
      _filePath = md['FILE']?['Path'];
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
        child: _loading ? _buildLoading() : _bodyContent(bottomInset),
      ),
    );
  }

  /// 面板内容:scrollable=true 用 ListView(旧 DSS);false 用固定 Column(Overlay
  /// 自有面板,不滚动 → 外层拖拽手势不被 ListView 抢)。
  Widget _bodyContent(double bottomInset) {
    final padding = EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset);
    final children = <Widget>[
      _grabHandle(),
      const SizedBox(height: 8),
      _buildTimeCard(),
      const SizedBox(height: 10),
      _buildLensCard(),
      if (_hasCameraParams(_exif)) ...[
        const SizedBox(height: 10),
        _buildImageParamCard(),
      ],
      const SizedBox(height: 10),
      _buildFileInfoCard(),
    ];
    if (widget.scrollable) {
      return ListView(
          controller: _scrollCtrl, padding: padding, children: children);
    }
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
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
    final dateText = formatSmartDate(
      dateMs,
      todayLabel: t(ref, 'today'),
      yesterdayLabel: t(ref, 'yesterday'),
    );
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
          if (_filePath != null && _filePath!.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildPathRow(),
          ],
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
          // 位置:visort 无反地理编码与地图,显示原始经纬度;无 GPS 给占位。
          Row(
            children: [
              const Icon(
                Icons.place_outlined,
                color: AppColors.muted,
                size: 15,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasGps
                      ? '${_fmtCoord(lat)}, ${_fmtCoord(lng)}'
                      : t(ref, 'detail_no_location_info'),
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

  /// 绝对路径行:/storage/emulated/0 前缀换成「手机存储」灰色圆角胶囊,
  /// 后接剩余路径(过长可水平拖动选中看全)。
  Widget _buildPathRow() {
    // 只显示到文件所在目录(含末尾 /);文件名由第三行单独展示,避免重复。
    var dir = _filePath!;
    final slash = dir.lastIndexOf('/');
    if (slash >= 0) dir = dir.substring(0, slash + 1);
    const prefix = '/storage/emulated/0';
    final match = dir.startsWith(prefix);
    final rest = match ? dir.substring(prefix.length) : dir;
    return Row(
      children: [
        if (match) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.muted.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              '手机存储',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                fontFamily: 'Space Mono',
                height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: SelectableText(
            rest,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              fontFamily: 'Space Mono',
              height: 1.3,
              fontFamilyFallback: AppFonts.cjkFallback,
            ),
            maxLines: 1,
          ),
        ),
      ],
    );
  }

  // ─────────────── 卡片:② 镜头(型号大字 + 分辨率|像素|大小|类型)───────────────

  Widget _buildLensCard() {
    final info = widget.info;
    final make = _exif['Make'] ?? '';
    final model = _exif['Model'] ?? '';
    final device = _pickDeviceName(make, model);
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
          // 非相机图片(截图等)无型号 → 不显示大字,直接展示分辨率行。
          if (device.isNotEmpty) ...[
            Text(
              device,
              style: const TextStyle(
                color: AppColors.text,
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
          ],
          // 参数药丸分两行(竖线分隔):窄屏上 4 格一排会被截断,拆成 2×2 保证值完整。
          // 第一行:分辨率(MP) | 像素尺寸;第二行:文件大小 | MIME 类型。
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PillRow(
                cells: [
                  _PillCell(value: mp, label: t(ref, 'detail_resolution')),
                  _PillCell(
                    value: (w > 0 && h > 0) ? '$w × $h' : '-',
                    label: t(ref, 'detail_pixels'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _PillRow(
                cells: [
                  _PillCell(
                    value: formatSize(info.size),
                    label: t(ref, 'photo_size'),
                  ),
                  _PillCell(
                    value: mimeShortName(info.mime),
                    label: t(ref, 'photo_type'),
                  ),
                ],
              ),
            ],
          ),
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
      _PillCell(
        value: iso.isEmpty ? '-' : iso,
        label: t(ref, 'meta_iso'),
        horizontal: false,
        fitWidth: false,
      ),
      _PillCell(
        value: ev,
        label: t(ref, 'detail_ev'),
        horizontal: false,
        fitWidth: false,
      ),
      _PillCell(
        value: shutter,
        label: t(ref, 'detail_shutter'),
        horizontal: false,
        fitWidth: false,
      ),
      _PillCell(
        value: aperture,
        label: t(ref, 'meta_aperture'),
        horizontal: false,
        fitWidth: false,
      ),
      _PillCell(
        value: focal,
        label: t(ref, 'meta_focal'),
        horizontal: false,
        fitWidth: false,
      ),
    ];
    // 仅在有相机参数时被调用(见 build 的 _hasCameraParams 判断)。
    // spaceEvenly 均匀分布:5 值按自然宽 + 4 短竖线等距排布,两端留白 = 值间留白,
    // 数值宽度差异大时也均匀(短值不单侧空一大截、长值不挤)。竖线缩短至 ~3/5 格高。
    return _SectionCard(
      child: _PillRow(cells: cells, evenly: true, dividerHeight: 16),
    );
  }

  // ─────────────── 卡片:④ 文件信息(创建 / 修改 / 方向)───────────────

  Widget _buildFileInfoCard() {
    final info = widget.info;
    // 方向:1=正常(绝大多数照片),对用户无意义 → 不显示;其余值映射为可读角度。
    final orient = _formatOrientation(_exif['Orientation']);
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
          _kv(t(ref, 'photo_modified_at'), formatDateTime(info.dateModifiedMs)),
          if (orient != null) _kv(t(ref, 'meta_orientation'), orient),
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
      16,
      8,
      16,
      24 + MediaQuery.viewPaddingOf(context).bottom,
    ),
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
      // 水平居中：label 与 value 垂直方向对齐（避免小字号差异导致错位）
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          // 110 容纳英文 "Orientation"（11 字符 Space Mono 13px），避免尾字母换行
          width: 110,
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

/// 经纬度格式化:Android 端 GPS 来自 ExifInterface.latLong 的 Double.toString(),
/// 精度高达 14+ 位小数(如 39.90421111111111)→ 截断到 5 位(≈1 米),显示更紧凑。
/// 解析失败(非数字)则原样返回,不丢信息。
String _fmtCoord(String? raw) {
  final v = double.tryParse(raw ?? '');
  if (v == null) return raw ?? '';
  // 经度 ±180、纬度 ±90,整数位最多 3 位;5 位小数足够定位。
  return v.toStringAsFixed(5);
}

/// 设备型号去重:EXIF Make(如 "OnePlus")常是 Model(如 "OnePlus 13")的前缀,
/// 直接拼接会得到 "OnePlus OnePlus 13"。当 Model 已包含 Make(忽略大小写)时只取 Model。
String _pickDeviceName(String make, String model) {
  final m = model.trim();
  final mk = make.trim();
  if (m.isEmpty) return mk;
  if (mk.isEmpty) return m;
  // Model 以 Make 开头 → 重复,只保留 Model。
  if (m.toLowerCase().startsWith(mk.toLowerCase())) return m;
  return '$mk $m';
}

/// EXIF Orientation → 可读角度;1(正常/0°)返回 null 表示无需展示。
/// 标准:1=0°、3=180°、6=90°顺时针、8=270°顺时针;2/4/5/7 为镜像(罕见)原样返回。
String? _formatOrientation(String? raw) {
  switch (raw?.trim()) {
    case '3':
      return '180°';
    case '6':
      return '90°';
    case '8':
      return '270°';
    default:
      // 0/1/2/4/5/7/null/空:1=正常(绝大多数照片),其余罕见或无效。
      // 都是用户看不懂的原始数字 → 不显示方向行。
      return null;
  }
}

/// 是否存在相机参数(ISO / EV / 快门 / 光圈 / 焦距 任一非空)。
/// 用于决定③图片参数卡是否渲染:截图、非相机图片无这些 EXIF → 不显示该卡。
bool _hasCameraParams(Map<String, String> exif) {
  const keys = [
    'ISO',
    'ExposureBiasValue',
    'ExposureTime',
    'FNumber',
    'FocalLength',
  ];
  return keys.any((k) {
    final v = exif[k];
    return v != null && v.isNotEmpty;
  });
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
  const _PillCell({
    required this.value,
    required this.label,
    this.horizontal = true,
    this.fitWidth = true,
  });
  final String value;
  final String label;

  /// true=项名左/数值右(分辨率行用);false=数值上/项名下(ISO/EV 等相机参数行用)。
  final bool horizontal;

  /// true=用 FittedBox 撑满列宽(等分格时保证值完整);false=按自然宽度
  /// (配合 _PillRow.evenly 的 spaceEvenly 均匀分布:值不撑满、自然宽完整)。
  final bool fitWidth;

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(
      color: AppColors.muted,
      fontSize: 11,
      fontFamily: 'Space Mono',
      height: 1.2,
      fontFamilyFallback: AppFonts.cjkFallback,
    );
    const valueStyle = TextStyle(
      color: AppColors.text,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      fontFamily: 'Space Mono',
      height: 1.2,
      fontFamilyFallback: AppFonts.cjkFallback,
    );
    return Tooltip(
      // 点击格子显示完整值的小气泡(对标系统相册:点击弹气泡看全)。
      message: value,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 3),
      preferBelow: false,
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
      // 两端贴卡片边(与上方文本左右对齐);竖线两侧间距由 _PillRow 的竖线 margin 提供。
      child: horizontal
          ? Row(
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: valueStyle,
                  ),
                ),
              ],
            )
          : fitWidth
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  // 等分格撑满列宽时:整体等比缩小保证值完整(如 "5 mm"、"1/125"),
                  // 值/标签同比例缩放,不会出现值比标签小的怪相。够宽时不放大。
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(value, style: valueStyle),
                      const SizedBox(height: 4),
                      Text(label, style: labelStyle),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      value,
                      textAlign: TextAlign.center,
                      style: valueStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: labelStyle,
                    ),
                  ],
                ),
    );
  }
}

class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.cells,
    this.evenly = false,
    this.dividerHeight,
  });
  final List<_PillCell> cells;
  /// true=spaceEvenly 均匀分布:各值按自然宽度,与竖线一起在长条上等距排布,
  /// 两端留白 = 值间留白,数值宽度差异大时也均匀(短值不单侧空、长值不挤)。
  /// 配合 cell.fitWidth=false。
  final bool evenly;
  /// evenly 模式下竖线的固定高度(null=不指定,由交叉轴决定)。
  final double? dividerHeight;
  @override
  Widget build(BuildContext context) {
    if (evenly) {
      final items = <Widget>[];
      for (var i = 0; i < cells.length; i++) {
        if (i > 0) {
          items.add(
            Container(
              width: 1,
              height: dividerHeight,
              color: AppColors.border,
            ),
          );
        }
        items.add(cells[i]);
      }
      return IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: items,
        ),
      );
    }
    final items = <Widget>[];
    for (var i = 0; i < cells.length; i++) {
      if (i > 0) {
        items.add(
          Container(
            width: 1,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: AppColors.border,
          ),
        );
      }
      items.add(Expanded(child: cells[i]));
    }
    // IntrinsicHeight + stretch:竖线高度自适应最高 cell
    // (②卡左右单行 ~20px、③卡上下两行 ~30px,各自 _PillRow 内适配,不再固定错配)。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: items,
      ),
    );
  }
}
