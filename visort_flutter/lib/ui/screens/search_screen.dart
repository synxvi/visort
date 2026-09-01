// 搜索页 —— 相册页右上角搜索按钮进入
//
// v2.4 结构对齐 Aves 版（真机反馈第二轮修正）：
//   - 顶栏即搜索框（[aves 对齐]：无大标题、无边框[三态显式 none，聚焦
//     不亮主题描边]、hint「搜索相片」、转场后自动聚焦呼出键盘——仅
//     建议态；点空白/滚动列表/进看图/选 chip 都收键盘）；leading =
//     侧栏图形 morph 成返回箭头（终态逐坐标等于 BackGlyphIcon，与其
//     他页面返回位置严格一致；[aves 对齐] menu_arrow 语义）；
//   - 区顺序同 Aves：类型（无标题首行，恒展开无箭头）/ 日期 / 格式 /
//     相册 / 省份 / 地点 / 元数据（评分标签 visort 无数据不做）；各
//     区右侧恒显折叠/展开箭头（只箭头无文字），手风琴单开；折叠露前
//     N 个，展开 Wrap 全铺，超 50 截断「更多」；
//   - 日期区跨年聚合（[aves 对齐] DateFilter，不写死年月——绝对年月
//     同月份逐年重复无法分辨）：日期选择器 → 最近添加 → 1~12 月 →
//     周一~周日；picked chip 在注册表重建时保留；
//   - 相册区排序跟随相册页偏好（albumSortBy/Asc），空名兜底「根目录」；
//   - 点 chip 即过滤：同维度 OR、跨维度 AND，结果同页实时出网格；
//     输入实时过滤 chips（label contains）；文本匹配 文件名+地名+
//     相册名；
//   - route 返回本页静默重扫（看图删除/收藏变更后结果网格刷新）。
// 日期恒可用（EXIF 拍摄时间缺失兜底 dateAdded）；地点/元数据依赖
// 「智能识别索引」（设置页开关驱动，search_index SQLite 表）。
// 看图复用 Gallery 网格 + DetailPage（tagPrefix 'search' 防跨路由 tag 冲突）。
//
// 历史：v1 文件名搜索 + 坐标网格两组；v2 大卡片五维度（未按 Aves 交互
// 设计，废弃）；v2.2 chip 组合过滤；人物分类已移除（人脸识别未采用）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart' show SortBy;
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
import 'package:visort_flutter/ui/router.dart' show currentRouteName;
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

  /// 相册 bucket 元数据（相册区排序键：创建/修改时间，跟相册页偏好）。
  List<MsBucket> _buckets = const [];

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
    // 条件：仅当仍处建议态（无输入无选中）——用户已点 chip 进结果
    // 网格时再弹键盘是干扰（用户反馈）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        if (_queryCtrl.text.isEmpty && _selected.isEmpty) {
          _searchFocus.requestFocus();
        }
      });
    });
    // 从看图/其他页返回本页：静默重扫（删除/收藏变更后结果网格与 chips
    // 计数需刷新——否则已删照片的缩略图/计数残留，用户实测）。
    currentRouteName.addListener(_onRouteChanged);
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
    currentRouteName.removeListener(_onRouteChanged);
    _queryCtrl.dispose();
    _searchFocus.dispose();
    _menuBackCtrl.dispose();
    super.dispose();
  }

  /// 回到本页时静默重扫：看图中删除/收藏变更会改变 _photos 与分组，
  /// 不刷新则已删照片的缩略图/ids 残留（用户实测）。不置 _loading，
  /// 旧列表照常渲染，扫完一次性换新。
  void _onRouteChanged() {
    if (currentRouteName.value == AlbumRoutes.search) _loadPhotos(silent: true);
  }

  Future<void> _loadPhotos({bool silent = false}) async {
    try {
      final photos = await scanAllImages(_channel);
      final buckets = await _channel.listBuckets();
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _buckets = buckets;
        _bucketNames = {for (final b in buckets) b.id: b.name};
        if (!silent) _loading = false;
      });
      _rebuildGroups();
    } catch (_) {
      if (!mounted) return;
      if (!silent) setState(() => _loading = false);
    }
  }

  /// 五维度分组。日期用 EXIF 拍摄时间（缺失兜底 dateAdded）；
  /// 地点优先城市名（索引 geocode 产物），无地名有坐标时坐标网格兜底；
  /// 相机取索引 camera 字段；相册/类型纯本地。
  void _rebuildGroups() {
    final photos = _photos;
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;

    // 日期（[aves 对齐] DateFilter 跨年聚合：月份 1~12 每月一个 chip、
    // 星期一~日各一个，不绑定年份——绝对年月会让同月份逐年重复，用户
    // 无法分辨）。展示顺序（注册序）：日期选择器 → 最近添加 → 月份 →
    // 星期几（Aves 同序：onThisDay/RecentlyAdded/月份/星期）。
    final byMonth = <int, List<MsImageInfo>>{};
    final byWeekday = <int, List<MsImageInfo>>{};
    final recentIds = <String>{};
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));
    for (final p in photos) {
      final taken = metas[p.id]?.dateTakenMs ?? p.dateAddedMs;
      if (taken <= 0) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(taken);
      byMonth.putIfAbsent(dt.month, () => []).add(p);
      byWeekday.putIfAbsent(dt.weekday, () => []).add(p);
      if (dt.isAfter(weekAgo)) recentIds.add(p.id);
    }
    final monthFmt = t(ref, 'search_month_only');
    final weekdayNames = t(ref, 'search_weekday_names').split(',');
    final monthGroups = [
      for (var m = 1; m <= 12; m++)
        if (byMonth.containsKey(m))
          _Group('$m', monthFmt.replaceFirst('{m}', '$m'), byMonth[m]!),
    ];
    final weekdayGroups = [
      for (var d = 1; d <= 7; d++)
        if (byWeekday.containsKey(d))
          _Group('$d', weekdayNames[d - 1], byWeekday[d]!),
    ];

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

    // 相册：bucketId 分组；排序跟随相册页偏好（albumSortBy/Asc——用户
    // 反馈「排序规则跟随相册页」）。空名 bucket 显示「根目录」（同
    // home 相册列表 root_dir 兜底，用户反馈「没有名字的相册」）。
    final albums = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      albums.putIfAbsent(p.bucketId, () => []).add(p);
    }
    final cfg = ref.read(configProvider);
    // bucket 元数据（名称/创建/修改时间）按 id 索引——排序键用。
    final bucketById = {for (final b in _buckets) b.id: b};
    String albumLabel(String id) =>
        (_bucketNames[id]?.isNotEmpty ?? false) ? _bucketNames[id]! : t(ref, 'root_dir');
    int albumCmp(_Group a, _Group b) {
      final ba = bucketById[a.key];
      final bb = bucketById[b.key];
      int cmp;
      switch (cfg.albumSortBy) {
        case SortBy.name:
          cmp = albumLabel(a.key)
              .toLowerCase()
              .compareTo(albumLabel(b.key).toLowerCase());
          break;
        case SortBy.dateCreated:
        case SortBy.dateTrashed: // bucket 无删除时间，回退创建（同 home）
          cmp = (ba?.dateCreatedMs ?? 0).compareTo(bb?.dateCreatedMs ?? 0);
          break;
        case SortBy.dateModified:
          cmp = (ba?.dateModifiedMs ?? 0).compareTo(bb?.dateModifiedMs ?? 0);
          break;
      }
      return cfg.albumSortAsc ? cmp : -cmp;
    }
    final albumList = albums.entries
        .map((e) => _Group(e.key, albumLabel(e.key), e.value))
        .toList()
      ..sort(albumCmp);

    // 文件类型：mime 分组（v1 行为）。
    final types = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      types.putIfAbsent(p.mime, () => []).add(p);
    }
    final typeList = types.entries
        .map((e) => _Group(e.key, _mimeLabel(e.key), e.value))
        .toList()
      ..sort((a, b) => b.photos.length.compareTo(a.photos.length));

    // 拍摄设备（索引 camera 字段分组；Make+Model 字符串）。
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
      // 日期区（[aves 对齐] 顺序：日期选择器 → 最近添加 → 月份 → 星期几；
      // picker 是特殊入口 chip，toggle 特判弹日期面板）。
      SearchFilterData(
        key: 'date:picker',
        label: t(ref, 'search_date_picker'),
        category: 'date',
        icon: Icons.edit_calendar_outlined,
        ids: const {},
      ),
      if (recentIds.isNotEmpty)
        SearchFilterData(
          key: 'date:recent',
          label: t(ref, 'search_recent'),
          category: 'date',
          icon: Icons.schedule,
          ids: recentIds,
        ),
      for (final g in monthGroups)
        f(g, 'date', Icons.calendar_month_outlined),
      for (final g in weekdayGroups)
        f(g, 'date', Icons.date_range_outlined),
      // 快捷行（[aves 对齐] Aves 首行无标题 typeFilters 位）类型集
      //（顺序同 Aves：收藏/动图/竖屏/横屏/HDR/RAW；图片/视频/全景等
      // visort 无数据源不做）。
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
      // 省份 + 地点两级（[aves 对齐] 国家/省/市拆行；全库单一国家行无
      // 过滤价值，省行取 adminArea）。
      for (final g in provinceList) f(g, 'province', Icons.map_outlined),
      for (final g in placeList) f(g, 'place', Icons.location_on_outlined),
      for (final g in albumList) f(g, 'album', Icons.photo_library_outlined),
      for (final g in typeList) f(g, 'mime', Icons.image_outlined),
      for (final g in cameraList) f(g, 'camera', Icons.photo_camera_outlined),
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
    // 保留动态「具体日期」chips：_pickDate 生成的 picked 项不在静态分组
    // 里，重建注册表会丢（索引完成回调/route 返回刷新都触发重建），
    // 丢了连 _selected 里的选中项也会被幽灵清理误删。
    list.addAll(
        _filters.values.where((x) => x.key.startsWith('date:picked-')));

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

  /// mime → 显示名（常见格式友好名映射；未收录的回退尾段大写——
  /// `image/x-ms-bmp` 这类私有串不会裸露）。
  static const _mimeNames = {
    'jpeg': 'JPEG',
    'jpg': 'JPEG',
    'png': 'PNG',
    'gif': 'GIF',
    'webp': 'WebP',
    'heic': 'HEIC',
    'heif': 'HEIF',
    'avif': 'AVIF',
    'bmp': 'BMP',
    'tiff': 'TIFF',
    'tif': 'TIFF',
    'svg+xml': 'SVG',
    'mp4': 'MP4',
    'mpeg': 'MPEG',
    'quicktime': 'MOV',
    '3gpp': '3GP',
  };

  String _mimeLabel(String mime) {
    if (_isRawMime(mime)) return 'RAW';
    final last = mime.split('/').last.toLowerCase();
    return _mimeNames[last] ?? last.toUpperCase();
  }

  /// 竖屏/横屏（MediaStore WIDTH/HEIGHT；0=未知不参与，正方形两边都不算）。
  bool _isPortrait(MsImageInfo p) => p.width > 0 && p.height > p.width;
  bool _isLandscape(MsImageInfo p) => p.height > 0 && p.width > p.height;

  @override
  Widget build(BuildContext context) {
    final query = _queryCtrl.text.trim();
    // 返回键分层（用户定稿，Aves/系统搜索同款语义）：有文字先清文字
    // 停留在本页；再有选中 chips 清筛选回建议页；都空才真正退出到
    // 相册页——结果态不会一键被弹回相册页。
    return PopScope(
      canPop: query.isEmpty && _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (query.isNotEmpty) {
          _queryCtrl.clear();
          setState(() {});
        } else {
          setState(() => _selected.clear());
        }
      },
      child: Scaffold(
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
            // 无边框须三态显式置 none：focusedBorder 缺省回落主题，聚焦
            // 时会亮出主题高亮描边（用户反馈"不需要聚焦的高亮边框"）。
            decoration: InputDecoration(
              hintText: t(ref, 'search_hint'),
              hintStyle: const TextStyle(
                color: AppColors.muted,
                fontSize: 15,
              ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              filled: false,
            ),
          ),
        ),
        // [aves 对齐] buildActions：有输入时给清除按钮。清空后仅当回到
        // 建议态（无选中 chips）才回焦——结果网格中清文本不该弹键盘。
        actions: [
          if (query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.muted, size: 20),
              tooltip: t(ref, 'search_clear'),
              onPressed: () {
                _queryCtrl.clear();
                if (_selected.isEmpty) _searchFocus.requestFocus();
                setState(() {});
              },
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        bottom: false,
        // 点击空白收键盘（chips 自带手势在前，不与之冲突）。
        child: GestureDetector(
          onTap: () => _searchFocus.unfocus(),
          behavior: HitTestBehavior.opaque,
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
  /// 选 chip 即进结果网格——同时收键盘（结果页不该有输入法）。
  void _toggleFilter(String key) {
    _searchFocus.unfocus();
    if (key == 'date:picker') {
      _pickDate();
      return;
    }
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  /// 输入过滤后的维度 chips（label contains，大小写不敏感；
  /// [aves 对齐] Aves containQuery 同款语义）。顺序保持注册序——
  /// 各维度列表构建时已按数量排好；quick 行须保序（日期选择器恒最前）。
  /// [categories] 支持多维度合并（地点栏 = 省份在前 + 地点在后；category
  /// 仍各自独立，跨维度 AND 语义不受显示合并影响）。
  List<SearchFilterData> _sectionChips(List<String> categories, String q) {
    final chips = _filters.values
        .where((f) => categories.contains(f.category))
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
        // 已选药丸行三段节奏（用户定稿）：顶栏→药丸 12 / 药丸→计数
        // 文字 6 / 计数文字→图片网格 8。
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
      // 滚动即收键盘（用户反馈：滚动页面应自动收起输入法）。
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      // top 12：quick 首行距顶栏（用户定稿 12dp，与相册页新顶距一致）。
      padding: const EdgeInsets.only(top: 12, bottom: 24),
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
        // 快捷行（无标题，[aves 对齐] Aves 首行 typeFilters 位）：恒展开
        // 无折叠箭头（[用户定稿]「第一行保持展开状态，把折叠按钮去掉」）。
        _buildSection(
            categories: const ['quick'], query: query, alwaysExpanded: true),
        // [用户定稿] 栏目顺序：文件类型 → 日期 → 相册 → 地点（省份+地点
        // 合并一栏，省份在前地点在后；category 各自独立保 AND 语义）→
        // 拍摄设备 → 元数据。
        _buildSection(
            title: t(ref, 'search_types'),
            categories: const ['mime'],
            query: query),
        // 日期（[aves 对齐]：选择日期/最近添加/月份/星期，注册序即显示序）。
        _buildSection(
          title: t(ref, 'search_dates'),
          categories: const ['date'],
          query: query,
        ),
        _buildSection(
            title: t(ref, 'search_albums'),
            categories: const ['album'],
            query: query),
        // 地点：省份 chips 在前、市/地点在后（注册序），索引驱动，空态
        // 按配置分流引导。
        if (hasPlace)
          _buildSection(
            title: t(ref, 'search_places'),
            categories: const ['province', 'place'],
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
        // 拍摄设备（索引 camera 字段，元数据上面）。
        _buildSection(
            title: t(ref, 'search_cameras'),
            categories: const ['camera'],
            query: query),
        // 元数据（[aves 对齐] 负向过滤区：缺日期/未定位/无相机）。
        _buildSection(
            title: t(ref, 'search_metadata'),
            categories: const ['meta'],
            query: query),
      ],
    );
  }

  /// 日期选择器：选日后生成「2025年6月15日」过滤 chip 并选中。
  Future<void> _pickDate() async {
    if (_photos.isEmpty) return; // 全量扫描未完，无据可滤
    _searchFocus.unfocus(); // 弹日期面板前收键盘
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
  /// 定稿] 每行恒显、初始朝右展开旋 90°）。同一时刻至多一个区展开。
  /// 折叠态按宽度截断一行（TextPainter 实测 chip 宽，放满即止——不按
  /// 数量，固定数量在 Wrap 下会折成多行，用户反馈「默认行数过多」）；
  /// 展开态 Wrap 全铺，超 [_kTopFilterCount] 截断给「更多」。
  /// 切换无任何尺寸/透明动画（四轮真机实证：AnimatedSize/AnimatedCrossFade/
  /// AnimatedSwitcher 的尺寸或交叉淡化插值分别造成进页「从左向右飞入」、
  /// 原有胶囊闪烁、展开晃动；高度瞬跳 + 单树前缀复用是唯一干净形态，
  /// 动画感由箭头旋转单独承担）；输入过滤跨折叠态生效。
  Widget _buildSection({
    String? title,
    required List<String> categories,
    required String query,
    int Function(SearchFilterData, SearchFilterData)? sort,
    bool alwaysExpanded = false,
  }) {
    final sectionKey = categories.join('+');
    var chips = _sectionChips(categories, query);
    if (chips.isEmpty) return const SizedBox.shrink();
    if (sort != null) chips = chips.toList()..sort(sort);
    // 恒展开区（quick 类型行）：无折叠箭头、不参与手风琴（[用户定稿]
    // 「第一行保持展开状态，把折叠按钮去掉」）。
    final expanded = alwaysExpanded || _expandedSection == sectionKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 恒展开区（quick 类型行）无标题无箭头，整行 header 不渲染。
        // 标题左缘 / 箭头图形右缘都对齐 16dp（=「暂无地点信息」空态
        // 卡片左右外缘、chips 行边线；用户定稿）。标题内联不走
        // _SectionHeader（其自带 16 padding 会叠加成 32）。
        if (!alwaysExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 6, 4),
            child: Row(
              children: [
                if (title != null)
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        height: 1.2,
                        fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                // 折叠/展开箭头（每行恒显；语义同 Aves collapse/expand
                // icon）。基础态朝右，展开旋 90° 朝下（用户定稿）；旋转
                // 过渡 200ms easeOutCubic（同 home 折叠箭头形制）。
                // 按钮内 padding 10 + header 右 6 → 图形右缘 16。
                GestureDetector(
                  onTap: () {
                    _searchFocus.unfocus(); // 展开/收起也收起输入法（用户定稿）
                    setState(() {
                      if (expanded) {
                        _expandedSection = null;
                      } else {
                        // 单值：开新区旧区自动收起（[aves 对齐] 手风琴）；
                        // 「更多」态随区收起重置。
                        _expandedSection = sectionKey;
                        _showAllSections.remove(sectionKey);
                      }
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: AnimatedRotation(
                      turns: expanded ? 0.25 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: const Icon(
                        Icons.keyboard_arrow_right,
                        size: 18,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 折叠(一行，按宽度截断) ↔ 展开(全量 Wrap)：单树、无任何尺寸/
        // 透明动画。四轮真机实证的教训（尺寸/淡化插值方案全灭）：
        //   - AnimatedSize 数据到达时跑尺寸插值 → 进页「从左向右飞入」；
        //   - 双树交叉淡化 → 位置未变的前几个胶囊闪烁；
        //   - 插值期间 child 重排重启插值 → 展开晃动/顶抬。
        // 高度瞬跳 + 单树前缀复用是唯一干净形态（前缀 chips Element
        // 原位不动零闪烁），动画感由箭头旋转单独承担。
        // 折叠态一行：TextPainter 实测 chip 宽度累加，放满即止（固定
        // 数量在 Wrap 下折多行——用户反馈「默认行数过多」）。
        LayoutBuilder(
          builder: (ctx, constraints) {
            final avail = constraints.maxWidth - 32; // Wrap 水平 padding
            var w = 0.0;
            final visible = <SearchFilterData>[];
            var hiddenCount = 0;
            if (!expanded) {
              for (final c in chips) {
                final cw = _chipWidth(c);
                if (visible.isNotEmpty && w + 8 + cw > avail) break;
                visible.add(c);
                w += 8 + cw;
              }
              hiddenCount = chips.length - visible.length;
            } else if (chips.length > _kTopFilterCount &&
                !_showAllSections.contains(sectionKey)) {
              visible.addAll(chips.take(_kTopFilterCount));
              hiddenCount = chips.length - _kTopFilterCount;
            } else {
              visible.addAll(chips);
            }
            return Padding(
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
                  if (expanded && hiddenCount > 0)
                    GestureDetector(
                      onTap: () =>
                          setState(() => _showAllSections.add(sectionKey)),
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
            );
          },
        ),
      ],
    );
  }

  /// chip 宽度（折叠态一行截断用）：水平 padding 24 + icon 13 + gap 6 +
  /// 文本实测宽（TextPainter 同款 TextStyle）+ 边框 2。
  double _chipWidth(SearchFilterData f) {
    final tp = TextPainter(
      text: TextSpan(
        text: f.label,
        style: const TextStyle(
          fontFamily: 'Space Mono',
          fontFamilyFallback: AppFonts.cjkFallback,
          fontSize: 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return 24 + 13 + 6 + tp.width + 2;
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
    _searchFocus.unfocus(); // 进看图页收起输入法（用户反馈）
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

/// 顶栏 leading：侧栏图形 → 返回箭头 morph（[aves 对齐]
/// AnimatedIcons.menu_arrow 语义；用户定稿「原抽屉按钮位置过渡为返回，
/// 而不是生硬替换页面」）。起点 = 相册页左侧抽屉按钮的侧栏图形
///（面板框+竖分隔线，几何抄 app_shell _SidebarMorphPainter 的 t=0 态）；
/// 终点 = BackGlyphIcon 精确字形（横线 7.2→17.4，头 6.9~11.4——morph
/// 落位必须逐坐标等于它，否则返回箭头与其他页面错位偏移）。
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

  /// morph 进度：0 = 侧栏图形（抽屉收起态），1 = 返回箭头。
  final double t;

  /// 返回箭头字形坐标（与 BackGlyphPainter 完全一致）。
  static const _arrowLine1 = Offset(7.2, 12);
  static const _arrowLine2 = Offset(17.4, 12);
  static const _arrowHeadTop = Offset(11.4, 7.5);
  static const _arrowHeadTip = Offset(6.9, 12);
  static const _arrowHeadBottom = Offset(11.4, 16.5);
  static const _c = Offset(12, 12);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 侧栏图形：面板框绕中心收缩（1 → 0.4）并淡出（同抽屉按钮形制）。
    final frameAlpha = (1 - t).clamp(0.0, 1.0);
    if (frameAlpha > 0) {
      stroke.color = AppColors.text.withValues(alpha: frameAlpha);
      final s = 1 - 0.6 * t;
      final rect = Rect.fromCenter(
        center: _c,
        width: 14 * s,
        height: 13 * s,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        stroke,
      );
      final dx = rect.left + rect.width * 0.32;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), stroke);
    }

    // 返回箭头：淡入并自中心生长（端点从中心插值到字形坐标，落位
    // t=1 时逐坐标等于 BackGlyphIcon，位置与其他页面严格一致）。
    final arrowAlpha = t.clamp(0.0, 1.0);
    if (arrowAlpha > 0) {
      stroke.color = AppColors.text.withValues(alpha: arrowAlpha);
      Offset grow(Offset p) =>
          Offset(_c.dx + (p.dx - _c.dx) * t, _c.dy + (p.dy - _c.dy) * t);
      canvas.drawLine(grow(_arrowLine1), grow(_arrowLine2), stroke);
      final head = Path()
        ..moveTo(grow(_arrowHeadTop).dx, grow(_arrowHeadTop).dy)
        ..lineTo(grow(_arrowHeadTip).dx, grow(_arrowHeadTip).dy)
        ..lineTo(grow(_arrowHeadBottom).dx, grow(_arrowHeadBottom).dy);
      canvas.drawPath(head, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MenuBackPainter oldDelegate) =>
      oldDelegate.t != t;
}
