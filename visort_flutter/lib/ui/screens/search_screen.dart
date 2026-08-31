// 搜索页 —— 相册页右上角搜索按钮进入
//
// v2.2 chip 组合过滤版（[aves 对齐] CollectionSearchDelegate 交互 +
// visort UI；v2 大卡片版已废弃）：
//   - 首行快捷（无标题，Aves typeFilters 位）：日期选择器（showDatePicker
//     动态生成某日 chip）/ 最近添加 / 收藏 / HDR；
//   - 各维度可折叠区（Aves ExpandableFilterRow）：标题右侧展开/收起；
//     折叠态日期只露近几月（近→远排序）、其余露前 8；
//   - 点 chip 即过滤：同维度多选 OR、跨维度 AND，已选行可逐个移除，
//     结果同页实时出网格（Aves 跳 CollectionPage，我们少一跳）；
//   - 输入实时过滤各维度 chips（label contains，Aves containQuery 同款）；
//   - 文本 ∩ chips 组合；文本匹配 文件名+地名+相机+相册名。
// 日期恒可用（EXIF 拍摄时间缺失兜底 dateAdded）；地点/相机依赖
// 「智能识别索引」（设置页开关驱动，search_index SQLite 表）。
// 看图复用 Gallery 网格 + DetailPage（tagPrefix 'search' 防跨路由 tag 冲突）。
//
// 历史：v1 文件名搜索 + 坐标网格/文件类型两组；v2 大卡片五维度（用户
// 反馈未按 Aves 交互设计，废弃）；人物分类已移除（人脸识别未采用）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:visort_flutter/ui/screens/search_filter_chip.dart';
import 'package:visort_flutter/ui/route_transitions.dart';

/// 坐标兜底网格精度（度）：0.01° ≈ 1.1km，Geocoder 无地名时同一格算一个「地点」。
const double _kPlaceGrid = 0.01;

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

  // ── chip 注册表与已选集合（[aves 对齐] 建议 chip + 组合过滤）──
  /// 全量可选 chips（key → 定义）；_rebuildGroups 从五维度分组派生。
  Map<String, SearchFilterData> _filters = const {};

  /// 已选 chip keys（同维度 OR / 跨维度 AND）；非空时切结果网格。
  final Set<String> _selected = {};

  /// 处于展开态的维度（category）；折叠/展开由各 section 标题右侧按钮切换。
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    // 恢复智能识别索引（日期/地点/相机维度数据）；完成回调会更新分组。
    ref.read(searchIndexServiceProvider.notifier).load().then((_) {
      if (!mounted) return;
      _rebuildGroups();
      // 自愈：开关已开但索引未完成（开启时用户离开设置页/中断）→
      // 进搜索页自动续跑，不再依赖用户回设置页重开（真机 '…'/0 张
      // 排查结论：start 未跑完时 UI 停在 total 未就绪暂态）。
      final notifier = ref.read(searchIndexServiceProvider.notifier);
      final enabled = ref.read(configProvider).mlIndexEnabled;
      final st = ref.read(searchIndexServiceProvider);
      if (enabled && !st.running && !st.done) {
        notifier.start().then((_) {
          if (mounted) _rebuildGroups();
        });
      }
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

    // 日期（[aves 对齐] 相对时间优先，不写死年月）：绝对月份分组
    // （ym:2025-06 键）+ 年分组；展示层按「离当前最近」排序，折叠态
    // 只露近几个月（见 _dateOrder）。
    final byAbsMonth = <String, List<MsImageInfo>>{};
    final years = <int, List<MsImageInfo>>{};
    final recentIds = <String>{};
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    for (final p in photos) {
      final taken = metas[p.id]?.dateTakenMs ?? p.dateAddedMs;
      if (taken <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(taken);
      byAbsMonth
          .putIfAbsent('${dt.year}-${dt.month.toString().padLeft(2, '0')}', () => [])
          .add(p);
      years.putIfAbsent(dt.year, () => []).add(p);
      if (dt.isAfter(weekAgo)) recentIds.add(p.id);
    }
    final yearFmt = t(ref, 'search_year_fmt');
    final monthFmt = t(ref, 'search_month_only');
    final yearGroups = years.entries
        .map((e) => _Group(
              '${e.key}',
              yearFmt.replaceFirst('{y}', '${e.key}'),
              e.value,
            ))
        .toList()
      ..sort((a, b) => b.key.compareTo(a.key)); // 年份降序
    // 绝对月份 → Group；排序交给展示层（_absMonthRank 按离当前近远）。
    final monthGroups = byAbsMonth.entries
        .map((e) {
          final parts = e.key.split('-');
          final m = int.parse(parts[1]);
          return _Group(e.key, monthFmt.replaceFirst('{m}', '$m'), e.value);
        })
        .toList();

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

    // chip 注册表：各维度分组 → SearchFilterData（id 集合谓词）。
    SearchFilterData f(_Group g, String cat, IconData icon) => SearchFilterData(
          key: '$cat:${g.key}',
          label: g.label,
          category: cat,
          icon: icon,
          ids: g.photos.map((p) => p.id).toSet(),
        );
    final list = <SearchFilterData>[
      // 快捷行（[aves 对齐] Aves 首行无标题的 typeFilters 位）：最近添加 /
      // 收藏 / HDR（纯本地字段）。
      if (recentIds.isNotEmpty)
        SearchFilterData(
          key: 'quick:recent',
          label: t(ref, 'search_recent'),
          category: 'quick',
          icon: Icons.schedule,
          ids: recentIds,
        ),
      if (photos.any((p) => p.isFavorite))
        SearchFilterData(
          key: 'quick:fav',
          label: t(ref, 'search_favorites'),
          category: 'quick',
          icon: Icons.favorite_outline,
          ids: photos.where((p) => p.isFavorite).map((p) => p.id).toSet(),
        ),
      if (photos.any((p) => p.isHdr))
        SearchFilterData(
          key: 'quick:hdr',
          label: 'HDR',
          category: 'quick',
          icon: Icons.brightness_high_outlined,
          ids: photos.where((p) => p.isHdr).map((p) => p.id).toSet(),
        ),
      // 日期：绝对月份（ym:2025-06，展示层按近远排序）+ 年。
      for (final g in monthGroups) f(g, 'date', Icons.calendar_month_outlined),
      for (final g in yearGroups) f(g, 'date', Icons.calendar_today_outlined),
      for (final g in placeList) f(g, 'place', Icons.location_on_outlined),
      for (final g in albumList) f(g, 'album', Icons.photo_library_outlined),
      for (final g in typeList) f(g, 'mime', Icons.image_outlined),
      for (final g in cameraList) f(g, 'camera', Icons.photo_camera_outlined),
    ];

    setState(() {
      _filters = {for (final x in list) x.key: x};
      // 索引重建后 key 可能失效，清掉幽灵选中项。
      _selected.removeWhere((k) => !_filters.containsKey(k));
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
        child: Builder(
          builder: (context) {
            // 组合结果 = 文本过滤 ∩ 已选 chips（任一存在即出网格）。
            final results = _applyQueryAndFilters(query);
            final showResults = query.isNotEmpty || _selected.isNotEmpty;
            return Column(
              children: [
                _buildSearchField(),
                if (showResults) _buildSelectedRow(results),
                Expanded(
                  child: showResults
                      ? _buildResults(results)
                      : _buildSuggestions(query),
                ),
              ],
            );
          },
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

  // ──────────── 维度 chip 建议（[aves 对齐] 建议 chip 行 + 组合过滤）────────────

  /// 组合谓词：同维度（category）多 chip 取并（OR），跨维度取交（AND）。
  bool _matchSelected(String id) {
    if (_selected.isEmpty) return true;
    final byCat = <String, List<SearchFilterData>>{};
    for (final k in _selected) {
      final f = _filters[k];
      if (f == null) continue;
      byCat.putIfAbsent(f.category, () => []).add(f);
    }
    return byCat.values.every((fs) => fs.any((f) => f.contains(id)));
  }

  /// 点 chip：toggle 选中集合（同页实时过滤，不跳页）。
  void _toggleFilter(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  /// 输入过滤后的某维度 chips（label contains，大小写不敏感；
  /// [aves 对齐] Aves containQuery 同款语义）。
  List<SearchFilterData> _sectionChips(String category, String q) {
    final chips = _filters.values
        .where((f) => f.category == category)
        .toList(growable: false)
      ..sort((a, b) => b.ids.length.compareTo(a.ids.length));
    if (q.isEmpty) return chips;
    final lq = q.toLowerCase();
    return chips.where((f) => f.label.toLowerCase().contains(lq)).toList();
  }

  /// 已选过滤 chip 行（可逐个移除）+ 结果数与清空入口。
  Widget _buildSelectedRow(List<MsImageInfo> results) {
    if (_selected.isEmpty) return const SizedBox.shrink();
    final chips = [
      for (final k in _selected)
        if (_filters.containsKey(k)) _filters[k]!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Row(
            children: [
              for (var i = 0; i < chips.length; i++)
                Padding(
                  padding: EdgeInsets.only(right: i == chips.length - 1 ? 0 : 8),
                  child: FilterChipWidget(
                    filter: chips[i],
                    selected: true,
                    onTap: () => _toggleFilter(chips[i].key),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Row(
            children: [
              Text(
                t(ref, 'search_match_count').replaceFirst(
                    '{n}', '${results.length}'),
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.muted,
                  fontSize: 11,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _selected.clear()),
                child: Text(
                  t(ref, 'search_clear_filters'),
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    color: AppColors.accent,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 维度建议列表。有输入时各维度 chips 按词过滤（跨维度联动检索）。
  /// 每栏标题右侧折叠/展开（[aves 对齐] ExpandableFilterRow）：
  /// 折叠态只露常用项（日期=近几月，其余=前 8），展开看全量。
  Widget _buildSuggestions(String query) {
    final index = ref.watch(searchIndexServiceProvider);
    final config = ref.watch(configProvider);
    final hasPlace = config.mlIndexEnabled &&
        config.mlPlaceEnabled &&
        _filters.values.any((f) => f.category == 'place');
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        // 全量扫描加载中：顶部轻量指示（chips 依赖全量列表）。
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
        // 快捷行（无标题，[aves 对齐] Aves 首行 typeFilters 位）：
        // 日期选择器 + 最近添加 + 收藏 + HDR。
        _buildQuickRow(query),
        // 日期：近月优先；展开看全部年/月。
        _buildSection(
          title: t(ref, 'search_dates'),
          category: 'date',
          query: query,
          collapsedCount: 5,
          sort: _byAbsMonthDesc,
        ),
        // 地点：索引驱动；空态按配置分流引导。
        if (hasPlace)
          _buildSection(
            title: t(ref, 'search_places'),
            category: 'place',
            query: query,
          )
        else if (query.isEmpty) ...[
          _SectionHeader(t(ref, 'search_places')),
          _SectionEmpty(
            icon: Icons.location_on_outlined,
            title: t(ref, 'search_places_empty'),
            hint: !config.mlIndexEnabled
                ? t(ref, 'search_places_hint_index')
                : (!config.mlPlaceEnabled
                    ? t(ref, 'search_places_hint_place')
                    : t(ref, 'search_places_hint')),
          ),
        ],
        // 相册 / 格式 / 相机。
        _buildSection(
            title: t(ref, 'search_albums'), category: 'album', query: query),
        _buildSection(
            title: t(ref, 'search_types'), category: 'mime', query: query),
        _buildSection(
            title: t(ref, 'search_cameras'), category: 'camera', query: query),
      ],
    );
  }

  /// 绝对月份键（'2025-06'）距当前月数——日期维度排序键（近→远）。
  int _absMonthRank(String key) {
    final parts = key.split('-');
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final now = DateTime.now();
    return (now.year - y) * 12 + (now.month - m);
  }

  /// 日期维度排序：月份按距当前近远在前，年份按新旧排其后（展开态用）。
  /// 年份 key（'2026'）无 '-'，不能走 [_absMonthRank] 的 parts[1]——
  /// 真机红屏 RangeError 实证。
  int _byAbsMonthDesc(SearchFilterData a, SearchFilterData b) {
    int rank(SearchFilterData f) {
      final k = f.key.replaceFirst('date:', '');
      if (!k.contains('-')) return 100000 - (int.tryParse(k) ?? 0);
      return _absMonthRank(k);
    }

    return rank(a).compareTo(rank(b));
  }

  /// 快捷行：日期选择器（特殊入口 chip）+ quick 维度 chips。无标题。
  Widget _buildQuickRow(String query) {
    final chips = _sectionChips('quick', query);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChipWidget(
              filter: SearchFilterData(
                key: 'date:picker',
                label: t(ref, 'search_date_picker'),
                category: 'date',
                icon: Icons.edit_calendar_outlined,
                ids: const {},
              ),
              selected: false,
              onTap: _pickDate,
            ),
          ),
          for (var i = 0; i < chips.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i == chips.length - 1 ? 0 : 8),
              child: FilterChipWidget(
                filter: chips[i],
                selected: _selected.contains(chips[i].key),
                onTap: () => _toggleFilter(chips[i].key),
              ),
            ),
        ],
      ),
    );
  }

  /// 日期选择器：选日后生成「2025年6月15日」过滤 chip 并选中。
  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
      helpText: t(ref, 'search_date_picker'),
    );
    if (d == null || !mounted) return;
    final ids = <String>{};
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;
    for (final p in _photos) {
      final taken = metas[p.id]?.dateTakenMs ?? p.dateAddedMs;
      if (taken <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(taken);
      if (dt.year == d.year && dt.month == d.month && dt.day == d.day) {
        ids.add(p.id);
      }
    }
    final fmt = t(ref, 'search_picked_fmt')
        .replaceFirst('{y}', '${d.year}')
        .replaceFirst('{m}', '${d.month}')
        .replaceFirst('{d}', '${d.day}');
    setState(() {
      _filters['date:picked-${d.toIso8601String()}'] = SearchFilterData(
        key: 'date:picked-${d.toIso8601String()}',
        label: fmt,
        category: 'date',
        icon: Icons.today,
        ids: ids,
      );
      _selected.add('date:picked-${d.toIso8601String()}');
    });
  }

  /// 一个可折叠维度区（[aves 对齐] TitledExpandableFilterRow）：
  /// 标题 + 右侧展开/收起按钮；折叠只露前 [collapsedCount] 个（日期按
  /// 近远、其余按数量），展开全量；输入过滤跨折叠态生效。
  Widget _buildSection({
    required String title,
    required String category,
    required String query,
    int collapsedCount = 8,
    int Function(SearchFilterData, SearchFilterData)? sort,
  }) {
    var chips = _sectionChips(category, query);
    if (chips.isEmpty) return const SizedBox.shrink();
    if (sort != null) chips = chips.toList()..sort(sort);
    final expanded = _expanded.contains(category);
    final visible = expanded || chips.length <= collapsedCount
        ? chips
        : chips.take(collapsedCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              Expanded(child: _SectionHeader(title)),
              if (chips.length > collapsedCount)
                GestureDetector(
                  onTap: () => setState(() {
                    expanded ? _expanded.remove(category) : _expanded.add(category);
                  }),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Row(
                      children: [
                        Text(
                          expanded
                              ? t(ref, 'search_collapse')
                              : t(ref, 'search_expand'),
                          style: const TextStyle(
                            fontFamily: 'Space Mono',
                            fontFamilyFallback: AppFonts.cjkFallback,
                            color: AppColors.accent,
                            fontSize: 11,
                          ),
                        ),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 14,
                          color: AppColors.accent,
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (var i = 0; i < visible.length; i++)
                Padding(
                  padding:
                      EdgeInsets.only(right: i == visible.length - 1 ? 0 : 8),
                  child: FilterChipWidget(
                    filter: visible[i],
                    selected: _selected.contains(visible[i].key),
                    onTap: () => _toggleFilter(visible[i].key),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ──────────── 搜索结果网格（文本/chips 触发时）────────────

  /// 组合过滤：文本匹配（文件名+地名+相机+相册名 contains）∩ 已选 chips
  /// （同维度 OR / 跨维度 AND）。文本为空时仅 chips 生效。
  List<MsImageInfo> _applyQueryAndFilters(String query) {
    final q = query.toLowerCase();
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;
    return _photos.where((p) {
      if (!_matchSelected(p.id)) return false;
      if (q.isEmpty) return true;
      if (p.name.toLowerCase().contains(q)) return true;
      if ((_bucketNames[p.bucketId] ?? '').toLowerCase().contains(q)) {
        return true;
      }
      final m = metas[p.id];
      if (m == null) return false;
      return m.placeLabel.toLowerCase().contains(q) ||
          (m.camera?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  Widget _buildResults(List<MsImageInfo> filtered) {
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
