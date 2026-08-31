// 搜索页 —— 相册页右上角搜索按钮进入
//
// v2.3 结构对齐 Aves 版（v2.2 chip 组合过滤 + 用户定稿修正）：
//   - 顶栏即搜索框（[aves 对齐] SearchPage：无大标题、无边框输入框、
//     hint「搜索相片」、转场后自动聚焦呼出键盘）；leading = 抽屉三线
//     morph 成返回箭头（[aves 对齐] AnimatedIcons.menu_arrow 语义）；
//   - 区顺序同 Aves：类型（无标题首行）/ 日期 / 格式 / 相册 / 省份 /
//     地点 / 元数据（评分、标签 visort 不做）；每行右侧恒显折叠/展开
//     箭头（[用户定稿] 只留箭头无文字），手风琴单开（[aves 对齐]
//     expandedNotifier 单值）；折叠露前 N 个（[用户定稿] 不横滑全列，
//     日期近月优先近→远排序），展开 Wrap 全铺（[aves 对齐]
//     _ExpandedFilterRow），超 50 截断给「更多」；
//   - 首行 = 日期选择器（特殊入口 chip）+ 最近添加 + 类型集（收藏/
//     动图/竖屏/横屏/HDR/RAW，[aves 对齐] typeFilters 子集）；
//   - 点 chip 即过滤：同维度多选 OR、跨维度 AND，已选行可逐个移除，
//     结果同页实时出网格（Aves 跳 CollectionPage，我们少一跳）；
//   - 输入实时过滤各维度 chips（label contains，Aves containQuery 同款）；
//   - 文本 ∩ chips 组合；文本匹配 文件名+地名+相机+相册名。
// 日期恒可用（EXIF 拍摄时间缺失兜底 dateAdded）；地点/元数据依赖
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

/// RAW 私有 mime 尾段标记（quick 行与格式区共用）。
const List<String> _kRawMarkers = [
  'dng', 'cr2', 'nef', 'arw', 'rw2', 'orf', 'raw',
];

/// 展开态全铺时的截断数（[aves 对齐] ExpandableFilterRow.topFilterCount），
/// 超出截断并给「更多」按钮。
const int _kTopFilterCount = 50;

bool _isRawMime(String mime) {
  final last = mime.split('/').last.toLowerCase();
  return _kRawMarkers.any(last.contains);
}

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

class _SearchScreenState extends ConsumerState<SearchScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _queryCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final MediaStoreChannel _channel = const MediaStoreChannel();

  /// leading morph：进页时抽屉三线过渡为返回箭头（[aves 对齐]
  /// AnimatedIcons.menu_arrow；用户定稿「原抽屉按钮位置过渡为返回」）。
  late final AnimationController _menuBackCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 0,
  );

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

  /// 当前展开的维度（category）——手风琴语义（[aves 对齐]
  /// expandedNotifier 单值：同一时刻至多一个区展开，开新区自动收旧区）。
  String? _expandedSection;

  /// 展开态里点过「更多」的维度（区收起时重置，[aves 对齐]
  /// _showAllNotifier 随 _ExpandedFilterRow 重建归零）。
  final Set<String> _showAllSections = {};

  @override
  void initState() {
    super.initState();
    // leading morph 进页播放：抽屉三线 → 返回箭头（下一帧启动，等首帧
    // 布局就绪，避免与路由转场同帧竞争）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuBackCtrl.forward();
    });
    // 搜索框自动聚焦呼出键盘（[aves 对齐] 转场完成后聚焦——立即聚焦会
    // 在转场中压缩布局晃动）。350ms ≈ enteFadeRoute 200ms + 余量。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) _searchFocus.requestFocus();
      });
    });
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
    _searchFocus.dispose();
    _menuBackCtrl.dispose();
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

    // 省份：地点上一级（[aves 对齐] 国家/省/市三行拆分；全库单一国家
    // 的行无过滤价值，只做省/市两级）。
    final provinces = <String, _Group>{};
    for (final p in photos) {
      final m = metas[p.id];
      if (m == null) continue;
      final area = m.adminArea;
      if (area == null || area.isEmpty) continue;
      final key = '${m.country}|$area';
      provinces.putIfAbsent(key, () => _Group(key, area, [])).photos.add(p);
    }
    final provinceList = provinces.values.toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 元数据（[aves 对齐] 负向过滤区：缺日期/未定位/无相机）。仅当库内
    // 存在对应正向数据时才露出——否则全库皆「缺」，chip 无过滤价值。
    bool hasDate(MsImageInfo p) =>
        (metas[p.id]?.dateTakenMs ?? p.dateAddedMs) > 0;
    bool hasLoc(MsImageInfo p) =>
        metas[p.id]?.lat != null && metas[p.id]?.lng != null;
    final hasAnyDate = photos.any(hasDate);
    final hasAnyLoc = photos.any(hasLoc);
    final hasAnyCamera =
        photos.any((p) => (metas[p.id]?.camera ?? '').isNotEmpty);
    final missingDateIds = hasAnyDate
        ? photos.where((p) => !hasDate(p)).map((p) => p.id).toSet()
        : <String>{};
    final unlocatedIds = hasAnyLoc
        ? photos.where((p) => !hasLoc(p)).map((p) => p.id).toSet()
        : <String>{};
    final noCameraIds = hasAnyCamera
        ? photos
            .where((p) => (metas[p.id]?.camera ?? '').isEmpty)
            .map((p) => p.id)
            .toSet()
        : <String>{};

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
      // 快捷行（[aves 对齐] Aves 首行无标题 typeFilters 位）：日期选择器
      //（[用户定稿] 首位特殊入口 chip，toggle 特判弹日期面板）+ 最近添加
      // + 类型集（顺序同 Aves：收藏/动图/竖屏/横屏/HDR/RAW；图片/视频/
      // 全景等 visort 无数据源不做）。
      SearchFilterData(
        key: 'date:picker',
        label: t(ref, 'search_date_picker'),
        category: 'quick',
        icon: Icons.edit_calendar_outlined,
        ids: const {},
      ),
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
      if (photos.any((p) => p.mime == 'image/gif'))
        SearchFilterData(
          key: 'quick:animated',
          label: t(ref, 'search_animated'),
          category: 'quick',
          icon: Icons.animation_outlined,
          ids: photos
              .where((p) => p.mime == 'image/gif')
              .map((p) => p.id)
              .toSet(),
        ),
      if (photos.any(_isPortrait))
        SearchFilterData(
          key: 'quick:portrait',
          label: t(ref, 'search_portrait'),
          category: 'quick',
          icon: Icons.portrait_outlined,
          ids: photos.where(_isPortrait).map((p) => p.id).toSet(),
        ),
      if (photos.any(_isLandscape))
        SearchFilterData(
          key: 'quick:landscape',
          label: t(ref, 'search_landscape'),
          category: 'quick',
          icon: Icons.crop_16_9_outlined,
          ids: photos.where(_isLandscape).map((p) => p.id).toSet(),
        ),
      if (photos.any((p) => p.isHdr))
        SearchFilterData(
          key: 'quick:hdr',
          label: 'HDR',
          category: 'quick',
          icon: Icons.brightness_high_outlined,
          ids: photos.where((p) => p.isHdr).map((p) => p.id).toSet(),
        ),
      if (photos.any((p) => _isRawMime(p.mime)))
        SearchFilterData(
          key: 'quick:raw',
          label: 'RAW',
          category: 'quick',
          icon: Icons.camera_roll_outlined,
          ids: photos.where((p) => _isRawMime(p.mime)).map((p) => p.id).toSet(),
        ),
      // 日期：绝对月份（ym:2025-06，展示层按近远排序）+ 年。
      for (final g in monthGroups) f(g, 'date', Icons.calendar_month_outlined),
      for (final g in yearGroups) f(g, 'date', Icons.calendar_today_outlined),
      // 省份 + 地点两级（[aves 对齐] 国家/省/市拆行；全库单一国家行无
      // 过滤价值，省行取 adminArea）。
      for (final g in provinceList) f(g, 'province', Icons.map_outlined),
      for (final g in placeList) f(g, 'place', Icons.location_on_outlined),
      for (final g in albumList) f(g, 'album', Icons.photo_library_outlined),
      for (final g in typeList) f(g, 'mime', Icons.image_outlined),
      // 元数据（[aves 对齐] 负向过滤：缺日期/未定位/无相机）。
      if (missingDateIds.isNotEmpty)
        SearchFilterData(
          key: 'meta:nodate',
          label: t(ref, 'search_missing_date'),
          category: 'meta',
          icon: Icons.event_busy_outlined,
          ids: missingDateIds,
        ),
      if (unlocatedIds.isNotEmpty)
        SearchFilterData(
          key: 'meta:noloc',
          label: t(ref, 'search_unlocated'),
          category: 'meta',
          icon: Icons.location_off_outlined,
          ids: unlocatedIds,
        ),
      if (noCameraIds.isNotEmpty)
        SearchFilterData(
          key: 'meta:nocam',
          label: t(ref, 'search_no_camera'),
          category: 'meta',
          icon: Icons.no_photography_outlined,
          ids: noCameraIds,
        ),
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
    if (_isRawMime(mime)) return 'RAW';
    return mime.split('/').last.toUpperCase();
  }

  /// 竖屏/横屏（MediaStore WIDTH/HEIGHT；0=未知不参与，正方形两边都不算）。
  bool _isPortrait(MsImageInfo p) => p.width > 0 && p.height > p.width;
  bool _isLandscape(MsImageInfo p) => p.height > 0 && p.width > p.height;

  @override
  Widget build(BuildContext context) {
    final query = _queryCtrl.text.trim();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        // [aves 对齐] leading：抽屉三线 morph 成返回箭头（用户定稿「原
        // 抽屉按钮位置过渡为返回」，替代生硬替换页面）。
        leading: IconButton(
          padding: const EdgeInsets.fromLTRB(9, 8, 19, 8),
          icon: _MenuBackMorph(progress: _menuBackCtrl),
          tooltip: t(ref, 'back'),
          onPressed: () => Navigator.maybePop(context),
        ),
        titleSpacing: 0,
        // [aves 对齐] 无大标题，搜索框直接集成进顶栏：无边框，hint
        // 「搜索相片」，自动聚焦呼出键盘（initState）。
        title: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: TextField(
            controller: _queryCtrl,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchFocus.unfocus(),
            onChanged: (_) => setState(() {}),
            style: const TextStyle(
              fontFamily: 'Space Mono',
              fontFamilyFallback: AppFonts.cjkFallback,
              color: AppColors.text,
              fontSize: 15,
            ),
            decoration: InputDecoration(
              hintText: t(ref, 'search_hint'),
              hintStyle: const TextStyle(
                color: AppColors.muted,
                fontSize: 15,
              ),
              border: InputBorder.none,
              isDense: true,
              filled: false,
            ),
          ),
        ),
        // [aves 对齐] buildActions：有输入时给清除按钮，清空后焦点回框。
        actions: [
          if (query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.muted, size: 20),
              tooltip: t(ref, 'search_clear'),
              onPressed: () {
                _queryCtrl.clear();
                _searchFocus.requestFocus();
                setState(() {});
              },
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Builder(
          builder: (context) {
            // 组合结果 = 文本过滤 ∩ 已选 chips（任一存在即出网格）。
            final results = _applyQueryAndFilters(query);
            final showResults = query.isNotEmpty || _selected.isNotEmpty;
            if (!showResults) return _buildSuggestions(query);
            return Column(
              children: [
                _buildSelectedRow(results),
                Expanded(child: _buildResults(results)),
              ],
            );
          },
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
  /// 「日期选择器」是特殊入口 chip（不进选中集合，点了弹日期面板）。
  void _toggleFilter(String key) {
    if (key == 'date:picker') {
      _pickDate();
      return;
    }
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  /// 输入过滤后的某维度 chips（label contains，大小写不敏感；
  /// [aves 对齐] Aves containQuery 同款语义）。顺序保持注册序——
  /// 各维度列表构建时已按数量排好；quick 行须保序（日期选择器恒最前）。
  List<SearchFilterData> _sectionChips(String category, String q) {
    final chips = _filters.values
        .where((f) => f.category == category)
        .toList(growable: false);
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
        // 快捷行（无标题，[aves 对齐] Aves 首行 typeFilters 位）：同样
        // 可折叠（[用户定稿] 所有横向列表都要有折叠箭头）。
        _buildSection(category: 'quick', query: query),
        // 日期：近月优先；展开看全部年/月。
        _buildSection(
          title: t(ref, 'search_dates'),
          category: 'date',
          query: query,
          collapsedCount: 5,
          sort: _byAbsMonthDesc,
        ),
        // 省份 + 地点两级（[aves 对齐] 国家/省/市拆行，国库无国家行）；
        // 索引驱动，空态按配置分流引导。
        if (hasPlace) ...[
          _buildSection(
              title: t(ref, 'search_states'),
              category: 'province',
              query: query),
          _buildSection(
            title: t(ref, 'search_places'),
            category: 'place',
            query: query,
          ),
        ] else if (query.isEmpty) ...[
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
        // 格式 → 相册（[aves 对齐] 区顺序：类型/日期/格式/相册/地点/元数据）。
        _buildSection(
            title: t(ref, 'search_types'), category: 'mime', query: query),
        _buildSection(
            title: t(ref, 'search_albums'), category: 'album', query: query),
        // 元数据（[aves 对齐] 负向过滤区：缺日期/未定位/无相机）。
        _buildSection(
            title: t(ref, 'search_metadata'), category: 'meta', query: query),
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

  /// 一个可折叠维度区（[aves 对齐] TitledExpandableFilterRow + 手风琴）：
  /// 标题（可空——quick 快捷行无标题）+ 右侧展开/折叠箭头按钮（[用户
  /// 定稿] 每行恒显、只留箭头无文字；[aves 对齐] 无条件显示 IconButton）。
  /// 同一时刻至多一个区展开（开新区自动收旧区，见 _expandedSection）。
  /// 折叠露前 [collapsedCount] 个（日期按近远、其余按数量，[用户定稿]
  /// 折叠态不横滑全列）；展开改 Wrap 流式铺满（[aves 对齐]
  /// _ExpandedFilterRow），超 [_kTopFilterCount] 截断并给「更多」按钮；
  /// 输入过滤跨折叠态生效。
  Widget _buildSection({
    String? title,
    required String category,
    required String query,
    int collapsedCount = 8,
    int Function(SearchFilterData, SearchFilterData)? sort,
  }) {
    var chips = _sectionChips(category, query);
    if (chips.isEmpty) return const SizedBox.shrink();
    if (sort != null) chips = chips.toList()..sort(sort);
    final expanded = _expandedSection == category;
    List<SearchFilterData> visible;
    var hiddenCount = 0;
    if (!expanded) {
      visible = chips.take(collapsedCount).toList();
    } else if (chips.length > _kTopFilterCount &&
        !_showAllSections.contains(category)) {
      visible = chips.take(_kTopFilterCount).toList();
      hiddenCount = chips.length - _kTopFilterCount;
    } else {
      visible = chips;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              if (title != null) Expanded(child: _SectionHeader(title)),
              // 折叠/展开箭头（每行恒显；语义同 Aves collapse/expand icon）。
              GestureDetector(
                onTap: () => setState(() {
                  if (expanded) {
                    _expandedSection = null;
                  } else {
                    // 单值：开新区旧区自动收起（[aves 对齐] 手风琴）；
                    // 「更多」态随区收起重置。
                    _expandedSection = category;
                    _showAllSections.remove(category);
                  }
                }),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: AppColors.muted,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in visible)
                  FilterChipWidget(
                    filter: c,
                    selected: _selected.contains(c.key),
                    onTap: () => _toggleFilter(c.key),
                  ),
                if (hiddenCount > 0)
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showAllSections.add(category)),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        '${t(ref, 'search_more')}($hiddenCount)',
                        style: const TextStyle(
                          fontFamily: 'Space Mono',
                          fontFamilyFallback: AppFonts.cjkFallback,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (var i = 0; i < visible.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                        right: i == visible.length - 1 ? 0 : 8),
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

/// 顶栏 leading：抽屉三线 → 返回箭头 morph（[aves 对齐]
/// AnimatedIcons.menu_arrow 语义；用户定稿「原抽屉按钮位置过渡为返回，
/// 而不是生硬替换页面」）。自绘 stroke 1.9 圆头与抽屉/返回/选项按钮
/// 同形制：三线上下两条向中线并拢淡出，中线演变为箭头横线并向左生长。
class _MenuBackMorph extends StatelessWidget {
  const _MenuBackMorph({required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (ctx, _) => CustomPaint(
        size: const Size.square(28),
        painter: _MenuBackPainter(progress.value),
      ),
    );
  }
}

class _MenuBackPainter extends CustomPainter {
  const _MenuBackPainter(this.t);

  final double t; // 0 = 三线菜单，1 = 返回箭头

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final menuAlpha = 1.0 - Curves.easeOut.transform(t);
    if (menuAlpha > 0) {
      final p = base..color = AppColors.text.withValues(alpha: menuAlpha);
      // 上下两条线向中线（y=12）并拢淡出；中线保留到最后一刻，与箭头
      // 横线（同在 y=12）衔接形成「中线变横线」的 morph 感。
      canvas.drawLine(
          Offset(6.5 + t, 7.5 - 2.2 * t), Offset(17.5, 7.5 - 2.2 * t), p);
      canvas.drawLine(const Offset(6.5, 12), Offset(17.5, 12), p);
      canvas.drawLine(
          Offset(6.5 + t, 16.5 + 2.2 * t), Offset(17.5, 16.5 + 2.2 * t), p);
    }
    final arrowAlpha = Curves.easeIn.transform(t);
    if (arrowAlpha > 0) {
      final p = base..color = AppColors.text.withValues(alpha: arrowAlpha);
      // 横线自右端向左生长（终点位 7.2），chevron 头跟随线头位移。
      final w = 10.2 * Curves.easeOut.transform(t);
      final hx = 17.4 - (10.2 - w);
      canvas.drawLine(Offset(hx, 12), const Offset(17.4, 12), p);
      final head = Path()
        ..moveTo(hx + 4.5, 7.5)
        ..lineTo(hx, 12)
        ..lineTo(hx + 4.5, 16.5);
      canvas.drawPath(head, p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MenuBackPainter oldDelegate) =>
      oldDelegate.t != t;
}
