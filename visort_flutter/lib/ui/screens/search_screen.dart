// 搜索页 —— 相册页右上角搜索按钮进入
//
// v2 多维度版（[aves 对齐] Aves 无输入态按维度聚合浏览 + 内存谓词过滤，
// 见 lib/model/filters/ Aves 源码调研）：
//   - 无输入态五维度分类（横向卡片行）：日期（年 → 月钻取）/ 地点
//     （城市名，Geocoder 不可用降级坐标网格）/ 相册 / 文件类型 / 相机；
//   - 日期维度恒可用（EXIF 拍摄时间缺失兜底 dateAdded）；地点/相机
//     依赖「智能识别索引」（设置页开关驱动，search_index SQLite 表）；
//   - 文本搜索：文件名 + 地名 + 相机 + 相册名 匹配（内存过滤，实时）。
// 结果页/看图复用现有组件：Gallery 网格 + DetailPage（无 Hero 飞行——
// tagPrefix 取 'search' 与相册页 'photo_$id' 区分，避免跨路由 tag 冲突）。
//
// 历史：v1 仅文件名搜索 + 位置坐标网格/文件类型两组分类（ml_index_service
// 纯 GPS 索引）；人物分类已移除（人脸识别未采用）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/search/search_index_service.dart';
import 'package:visort_flutter/shared/widgets/back_glyph_button.dart';
import 'package:visort_flutter/ui/ente_viewer/detail_page.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery_boundaries_provider.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery_files_inherited_widget.dart';
import 'package:visort_flutter/ui/ente_viewer/group_type.dart';
import 'package:visort_flutter/ui/ente_viewer/selected_files.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/ui/route_transitions.dart';

/// 坐标兜底网格精度（度）：0.01° ≈ 1.1km，Geocoder 无地名时同一格算一个「地点」。
const double _kPlaceGrid = 0.01;

/// 分类封面卡边长（[ente 对齐] 108 系缩略卡，visort 统一 96）。
const double _kCardSize = 96;

/// 一条已聚合的分类项（维度值 → 照片组），五维度共用的中间结构。
/// key 为稳定去重键（坐标/年月等），label 为展示名。
class _Group {
  const _Group(this.key, this.label, this.photos);

  final String key;
  final String label;
  final List<MsImageInfo> photos;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _queryCtrl = TextEditingController();
  final MediaStoreChannel _channel = const MediaStoreChannel();

  /// 多选状态恒传（非选择模式恒空）：Gallery 依赖 SelectionState 包裹
  /// 结构恒定（album_screen 同款，见其 610 行注释）。
  final SelectedFiles _selection = SelectedFiles();
  List<MsImageInfo> _photos = const [];
  bool _loading = true;

  /// bucketId → 相册名（文本搜索「按相册名」匹配 + 相册维度卡片标签）。
  Map<String, String> _bucketNames = const {};

  // ── 五维度分组（_photos 与索引数据齐了才在 _rebuildGroups 算）──
  List<(int, _Group)> _yearGroups = const [];
  Map<int, List<_Group>> _monthGroupsByYear = const {};
  List<_Group> _placeGroups = const [];
  List<_Group> _albumGroups = const [];
  List<_Group> _typeGroups = const [];
  List<_Group> _cameraGroups = const [];

  @override
  void initState() {
    super.initState();
    // 恢复智能识别索引（日期/地点/相机维度数据）；完成回调会更新分组。
    ref.read(searchIndexServiceProvider.notifier).load().then((_) {
      if (mounted) _rebuildGroups();
    });
    _loadPhotos();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPhotos() async {
    try {
      final photos = await scanAllImages(_channel);
      final buckets = await _channel.listBuckets();
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _bucketNames = {for (final b in buckets) b.id: b.name};
        _loading = false;
      });
      _rebuildGroups();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 五维度分组。日期用 EXIF 拍摄时间（缺失兜底 dateAdded）；
  /// 地点优先城市名（索引 geocode 产物），无地名有坐标时坐标网格兜底；
  /// 相机取索引 camera 字段；相册/类型纯本地。
  void _rebuildGroups() {
    final photos = _photos;
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;

    // 日期：年 + 年内月（两张索引，月页钻取用）。
    final years = <int, List<MsImageInfo>>{};
    final months = <(int, int), List<MsImageInfo>>{};
    for (final p in photos) {
      final taken = metas[p.id]?.dateTakenMs ?? p.dateAddedMs;
      if (taken <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(taken);
      years.putIfAbsent(dt.year, () => []).add(p);
      months.putIfAbsent((dt.year, dt.month), () => []).add(p);
    }
    final yearFmt = t(ref, 'search_year_fmt');
    final monthFmt = t(ref, 'search_month_fmt');
    final yearList = years.entries
        .map((e) => (
              e.key,
              _Group(
                '${e.key}',
                yearFmt.replaceFirst('{y}', '${e.key}'),
                e.value,
              )
            ))
        .toList()
      ..sort((a, b) => b.$1.compareTo(a.$1));
    final monthMap = <int, List<_Group>>{};
    months.forEach((k, v) {
      monthMap.putIfAbsent(k.$1, () => []).add(
            _Group(
              '${k.$1}-${k.$2}',
              monthFmt
                  .replaceFirst('{y}', '${k.$1}')
                  .replaceFirst('{m}', '${k.$2}'),
              v,
            ),
          );
    });
    for (final list in monthMap.values) {
      list.sort((a, b) => b.key.compareTo(a.key)); // '2024-12' 字符串序=月份序
    }

    // 地点：城市名分组（country+省+市 三元组为键防同城名撞车）；
    // 无名有坐标 → 坐标网格兜底（v1 行为）。
    final places = <String, _Group>{};
    final coordBuckets = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      final m = metas[p.id];
      if (m == null) continue;
      final label = m.placeLabel;
      if (label.isNotEmpty) {
        final key = '${m.country}|${m.adminArea}|${m.locality}';
        places.putIfAbsent(key, () => _Group(key, label, [])).photos.add(p);
      } else if (m.lat != null && m.lng != null) {
        final lat =
            (m.lat! / _kPlaceGrid).roundToDouble() * _kPlaceGrid;
        final lng =
            (m.lng! / _kPlaceGrid).roundToDouble() * _kPlaceGrid;
        coordBuckets.putIfAbsent('$lat,$lng', () => []).add(p);
      }
    }
    final placeList = places.values.toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));
    for (final e in coordBuckets.entries) {
      final parts = e.key.split(',');
      placeList.add(_Group(
        e.key,
        '${_fmtCoord(parts[0])}, ${_fmtCoord(parts[1])}',
        e.value,
      ));
    }
    placeList.sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 相册：bucketId 分组。
    final albums = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      albums.putIfAbsent(p.bucketId, () => []).add(p);
    }
    final albumList = albums.entries
        .map((e) => _Group(e.key, _bucketNames[e.key] ?? e.key, e.value))
        .toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 文件类型：mime 分组（v1 行为）。
    final types = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      types.putIfAbsent(p.mime, () => []).add(p);
    }
    final typeList = types.entries
        .map((e) => _Group(e.key, _mimeLabel(e.key), e.value))
        .toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 相机：索引 camera 字段分组。
    final cameras = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      final cam = metas[p.id]?.camera;
      if (cam != null && cam.isNotEmpty) {
        cameras.putIfAbsent(cam, () => []).add(p);
      }
    }
    final cameraList = cameras.entries
        .map((e) => _Group(e.key, e.key, e.value))
        .toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    if (!mounted) return;
    setState(() {
      _yearGroups = yearList;
      _monthGroupsByYear = monthMap;
      _placeGroups = placeList;
      _albumGroups = albumList;
      _typeGroups = typeList;
      _cameraGroups = cameraList;
    });
  }

  /// 坐标兜底标签数值（'31.0' → '31'，去尾零）。
  String _fmtCoord(String s) {
    final d = double.tryParse(s);
    if (d == null) return s;
    return d.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  /// mime → 显示名：`image/jpeg` → `JPEG`；RAW 私有类型统一 `RAW`。
  String _mimeLabel(String mime) {
    final last = mime.split('/').last.toLowerCase();
    const rawMarkers = ['dng', 'cr2', 'nef', 'arw', 'rw2', 'orf', 'raw'];
    if (rawMarkers.any(last.contains)) return 'RAW';
    return last.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final query = _queryCtrl.text.trim();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        leading: BackGlyphButton(
          tooltip: t(ref, 'back'),
          hideWhenCannotPop: true,
          onPressed: () => Navigator.maybePop(context),
        ),
        titleSpacing: 0,
        title: Text(
          t(ref, 'search'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            height: 1.2,
            fontFamilyFallback: AppFonts.cjkFallback,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildSearchField(),
            Expanded(
              child: query.isEmpty ? _buildCategories() : _buildResults(query),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索输入框：前缀放大镜、非空时后缀清除按钮。
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _queryCtrl,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(
          fontFamily: 'Space Mono',
          fontFamilyFallback: AppFonts.cjkFallback,
          color: AppColors.text,
          fontSize: 14,
        ),
        decoration: InputDecoration(
          hintText: t(ref, 'search_hint'),
          hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
          prefixIcon: const Icon(Icons.search, color: AppColors.muted, size: 20),
          suffixIcon: _queryCtrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close,
                      color: AppColors.muted, size: 18),
                  tooltip: t(ref, 'search_clear'),
                  onPressed: () {
                    _queryCtrl.clear();
                    setState(() {});
                  },
                ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  // ──────────── 维度分类列表（无输入时）────────────

  Widget _buildCategories() {
    final index = ref.watch(searchIndexServiceProvider);
    final config = ref.watch(configProvider);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        // 全量扫描加载中：顶部轻量指示（各维度分类依赖全量列表）。
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        // 索引进度 banner（设置页「智能识别」区同源）。
        if (index.running || index.geocoding)
          _MlProgressBanner(state: index, onTap: null),
        // 日期：恒可用（拍摄时间缺失兜底 dateAdded）。年卡片 → 月钻取。
        _SectionHeader(t(ref, 'search_dates')),
        _buildCardRow([
          for (final (year, g) in _yearGroups)
            _CategoryCard(
              title: g.label,
              count: g.photos.length,
              coverId: g.photos.first.id,
              onTap: () => _openMonths(year, g),
            ),
        ]),
        // 地点：索引数据驱动（城市名，Geocoder 不可用降级坐标网格）。
        // 空态文案按配置分流：索引未开 / 地点识别未开 / 已开但无数据。
        _SectionHeader(t(ref, 'search_places')),
        if (config.mlIndexEnabled &&
            config.mlPlaceEnabled &&
            _placeGroups.isNotEmpty)
          _buildCardRow([
            for (final g in _placeGroups)
              _CategoryCard(
                title: g.label,
                count: g.photos.length,
                coverId: g.photos.first.id,
                onTap: () => _openCategory(
                    g.label, g.photos, Icons.location_on_outlined),
              ),
          ])
        else if (config.mlIndexEnabled && config.mlPlaceEnabled)
          _SectionEmpty(
            icon: Icons.location_on_outlined,
            title: t(ref, 'search_places_empty'),
            hint: t(ref, 'search_places_hint'),
          )
        else if (!config.mlIndexEnabled)
          _SectionEmpty(
            icon: Icons.location_on_outlined,
            title: t(ref, 'search_places_empty'),
            hint: t(ref, 'search_places_hint_index'),
          )
        else
          _SectionEmpty(
            icon: Icons.location_on_outlined,
            title: t(ref, 'search_places_empty'),
            hint: t(ref, 'search_places_hint_place'),
          ),
        // 相册：bucket 分组，纯本地即时可用。
        _SectionHeader(t(ref, 'search_albums')),
        _buildCardRow([
          for (final g in _albumGroups)
            _CategoryCard(
              title: g.label,
              count: g.photos.length,
              coverId: g.photos.first.id,
              onTap: () =>
                  _openCategory(g.label, g.photos, Icons.photo_library_outlined),
            ),
        ]),
        // 文件类型：纯本地即时可用（v1 行为）。
        _SectionHeader(t(ref, 'search_types')),
        _buildCardRow([
          _CategoryCard(
            title: t(ref, 'gallery_title'),
            count: _photos.length,
            coverId: _photos.isEmpty ? null : _photos.first.id,
            onTap: _photos.isEmpty
                ? null
                : () => _openCategory(
                    t(ref, 'gallery_title'), _photos, Icons.photo_library_outlined),
          ),
          for (final g in _typeGroups)
            _CategoryCard(
              title: g.label,
              count: g.photos.length,
              coverId: g.photos.first.id,
              onTap: () =>
                  _openCategory(g.label, g.photos, Icons.image_outlined),
            ),
        ]),
        // 相机：索引数据驱动；无数据整节隐藏（避免空态噪音）。
        if (_cameraGroups.isNotEmpty) ...[
          _SectionHeader(t(ref, 'search_cameras')),
          _buildCardRow([
            for (final g in _cameraGroups)
              _CategoryCard(
                title: g.label,
                count: g.photos.length,
                coverId: g.photos.first.id,
                onTap: () => _openCategory(
                    g.label, g.photos, Icons.photo_camera_outlined),
              ),
          ]),
        ],
      ],
    );
  }

  Widget _buildCardRow(List<Widget> cards) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [for (final c in cards) Padding(
          padding: const EdgeInsets.only(right: 10),
          child: c,
        )],
      ),
    );
  }

  /// 年 → 月钻取页（该年月份卡片 + 全部），月卡片再进结果网格。
  void _openMonths(int year, _Group yearGroup) {
    final months = _monthGroupsByYear[year] ?? const <_Group>[];
    Navigator.of(context).push(enteFadeRoute(
      builder: (_) => _SubCategoriesPage(
        title: yearGroup.label,
        icon: Icons.calendar_today_outlined,
        groups: [
          // 「全部」置顶：该年全部照片。
          _Group('all', t(ref, 'search_all'), yearGroup.photos),
          ...months,
        ],
      ),
    ));
  }

  void _openCategory(String title, List<MsImageInfo> photos, IconData icon) {
    Navigator.of(context).push(enteFadeRoute(
      builder: (_) => _CategoryResultPage(
        title: title,
        icon: icon,
        photos: photos,
      ),
    ));
  }

  // ──────────── 搜索结果网格（有输入时）────────────

  /// 文本匹配：文件名 + 地名 + 相机 + 相册名（全小写 contains）。
  Widget _buildResults(String query) {
    final q = query.toLowerCase();
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;
    final filtered = _photos.where((p) {
      if (p.name.toLowerCase().contains(q)) return true;
      if ((_bucketNames[p.bucketId] ?? '').toLowerCase().contains(q)) {
        return true;
      }
      final m = metas[p.id];
      if (m == null) return false;
      return m.placeLabel.toLowerCase().contains(q) ||
          (m.camera?.toLowerCase().contains(q) ?? false);
    }).toList();
    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: AppColors.muted, size: 40),
            const SizedBox(height: 10),
            Text(
              t(ref, 'search_no_result'),
              style: const TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: AppFonts.cjkFallback,
                color: AppColors.muted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }
    final cols = ref.watch(configProvider).photoGridColumns;
    // Gallery 依赖外层 GalleryFilesState + GalleryBoundariesProvider
    //（ente CollectionPage 同款包装；缺此包裹渲染异常 → 顶栏下灰屏，
    // 文件类型结果页真机实证）。
    return GalleryBoundariesProvider(
      key: const ValueKey('search-results'),
      child: GalleryFilesState(
        child: Gallery(
          allFiles: filtered,
          // tagPrefix 取 'search'：与相册页 cell 的 'photo_$id' 区分，跨路由
          // 同 id 照片的 Hero tag 不冲突（搜索页叠在相册页之上，详见文件头）。
          tagPrefix: 'search',
          groupType: GroupType.none,
          selectedFiles: _selection,
          crossAxisCount: cols,
          sortOrderAsc: false,
          emptyState: null,
          onFileTap: (info) => _openPhoto(filtered, info),
        ),
      ),
    );
  }

  /// 大图浏览（[ente 对齐] ente routeToPage 淡入转场；无 Hero 飞行——
  /// 搜索页网格 tagPrefix 与 viewer 的 'photo_$id' 不同，飞行不配对）。
  void _openPhoto(List<MsImageInfo> files, MsImageInfo info) {
    final index = files.indexWhere((f) => f.id == info.id);
    if (index < 0) return;
    Navigator.of(context).push(enteFadeRoute(
      builder: (_) => DetailPage(
        files: files,
        initialIndex: index,
        gridCols: ref.read(configProvider).photoGridColumns,
      ),
      settings: const RouteSettings(name: AlbumRoutes.photoViewer),
      fullscreenDialog: true,
    ));
  }
}

/// 分类区小标题（[ente 对齐] SectionHeader）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'Space Mono',
          height: 1.2,
          fontFamilyFallback: AppFonts.cjkFallback,
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: AppColors.text,
        ),
      ),
    );
  }
}

/// 分类空态（[ente 对齐] SectionEmptyState：图标 + 主文案 + 引导副文案）。
class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.muted, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      color: AppColors.text,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hint,
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      height: 1.3,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分类封面卡：96 封面（缩略图 + 圆角） + 名称 + 数量。
class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.title,
    required this.count,
    this.coverId,
    this.onTap,
  });

  final String title;
  final int count;

  /// 封面照片 id；null 时灰底占位图标。
  final String? coverId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _kCardSize,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: _kCardSize,
                height: _kCardSize,
                child: _buildCover(context),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Space Mono',
                height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                color: AppColors.text,
              ),
            ),
            Text(
              '$count',
              style: const TextStyle(
                fontFamily: 'Space Mono',
                color: AppColors.muted,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    final coverId = this.coverId;
    if (coverId == null || coverId.isEmpty) {
      return Container(
        color: AppColors.surface,
        child: const Icon(Icons.image_outlined, color: AppColors.muted, size: 26),
      );
    }
    final ref = imageRefFromMediaStoreId(coverId);
    final thumbSize = (_kCardSize * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(96, 512);
    return Image(
      image: buildThumbnailProvider(ref, size: thumbSize, squareCrop: true),
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) =>
          Container(color: AppColors.surface),
    );
  }
}

/// [ente 对齐] 索引进度 banner（搜索页分类列表顶部）：LinearProgressIndicator
/// + 已索引 x/y；索引完成/关闭后自动消失。
class _MlProgressBanner extends ConsumerWidget {
  const _MlProgressBanner({required this.state, this.onTap});

  final SearchIndexState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = state.total == 0 ? 0.0 : state.processed / state.total;
    final pct = (progress * 100).round().clamp(0, 100);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.sync, color: AppColors.accent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${t(ref, 'settings_ml_running')} $pct%',
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: AppFonts.cjkFallback,
                        color: AppColors.text,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: AppColors.border,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 二级维度钻取页（年 → 月）：标题 + 分类卡片行，点卡片进结果网格。
/// 与 [_CategoryResultPage] 分层：本页只陈列子维度值，不出网格。
class _SubCategoriesPage extends ConsumerWidget {
  const _SubCategoriesPage({
    required this.title,
    required this.icon,
    required this.groups,
  });

  final String title;
  final IconData icon;
  final List<_Group> groups;

  void _openGroup(BuildContext context, WidgetRef ref, _Group g) {
    Navigator.of(context).push(enteFadeRoute(
      builder: (_) => _CategoryResultPage(
        title: g.label,
        icon: icon,
        photos: g.photos,
      ),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        leading: BackGlyphButton(
          tooltip: t(ref, 'back'),
          hideWhenCannotPop: true,
          onPressed: () => Navigator.maybePop(context),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            Icon(icon, color: AppColors.muted, size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final g in groups)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _CategoryCard(
                        title: g.label,
                        count: g.photos.length,
                        coverId: g.photos.first.id,
                        onTap: () => _openGroup(context, ref, g),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分类结果页：标题 + Gallery 网格（复用相册网格组件）+ 大图浏览。
class _CategoryResultPage extends ConsumerStatefulWidget {
  const _CategoryResultPage({
    required this.title,
    required this.icon,
    required this.photos,
  });

  final String title;
  final IconData icon;

  /// 分类下的全部照片（已按日期降序）。
  final List<MsImageInfo> photos;

  @override
  ConsumerState<_CategoryResultPage> createState() => _CategoryResultPageState();
}

class _CategoryResultPageState extends ConsumerState<_CategoryResultPage> {
  /// 同搜索页：Gallery 多选包裹恒传（结构恒定防重建灰屏）。
  final SelectedFiles _selection = SelectedFiles();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        leading: BackGlyphButton(
          tooltip: t(ref, 'back'),
          hideWhenCannotPop: true,
          onPressed: () => Navigator.maybePop(context),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            Icon(widget.icon, color: AppColors.muted, size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${widget.photos.length}',
              style: const TextStyle(
                fontFamily: 'Space Mono',
                color: AppColors.muted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: GalleryBoundariesProvider(
          key: const ValueKey('search-category'),
          child: GalleryFilesState(
            child: Gallery(
              allFiles: widget.photos,
              tagPrefix: 'search',
              groupType: GroupType.none,
              selectedFiles: _selection,
              crossAxisCount: ref.watch(configProvider).photoGridColumns,
              sortOrderAsc: false,
              onFileTap: (info) {
                final index = widget.photos.indexWhere((f) => f.id == info.id);
                if (index < 0) return;
                Navigator.of(context).push(enteFadeRoute(
                  builder: (_) => DetailPage(
                    files: widget.photos,
                    initialIndex: index,
                    gridCols: ref.read(configProvider).photoGridColumns,
                  ),
                  settings: const RouteSettings(name: AlbumRoutes.photoViewer),
                  fullscreenDialog: true,
                ));
              },
            ),
          ),
        ),
      ),
    );
  }
}
