// 搜索页 —— 相册页右上角搜索按钮进入（[ente 对齐] ENTE 搜索 tab 结构）
//
// 结构模仿 ENTE search_tab.dart：
//   - 顶部搜索输入框（本地过滤文件名，实时出结果网格）；
//   - 无输入时垂直分类列表（人物 / 位置 / 文件类型），每类横向卡片行；
//   - 数据全部本地 MediaStore：文件类型按 mime 分组（即时可用）；
//     位置按 EXIF GPS 网格分桶（ML 索引服务产物，设置页开关驱动）；
//     人物为预留空态（人脸识别模型未内置，说明文案引导）。
// 结果页/看图复用现有组件：Gallery 网格 + DetailPage（无 Hero 飞行——
// tagPrefix 取 'search' 与相册页 'photo_$id' 区分，避免跨路由 tag 冲突）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/search/ml_index_service.dart';
import 'package:visort_flutter/shared/widgets/back_glyph_button.dart';
import 'package:visort_flutter/ui/ente_viewer/detail_page.dart';
import 'package:visort_flutter/ui/ente_viewer/gallery.dart';
import 'package:visort_flutter/ui/ente_viewer/group_type.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/ui/route_transitions.dart';

/// 位置分组网格精度（度）：0.01° ≈ 1.1km，同一格的照片算一个「地点」。
const double _kPlaceGrid = 0.01;

/// 分类封面卡边长（[ente 对齐] 108 系缩略卡，visort 统一 96）。
const double _kCardSize = 96;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _queryCtrl = TextEditingController();
  final MediaStoreChannel _channel = const MediaStoreChannel();
  List<MsImageInfo> _photos = const [];
  bool _loading = true;

  /// 位置分组（按 0.01° 网格分桶，组内日期降序）：[组名, 照片]。
  List<(String, List<MsImageInfo>)> _placeGroups = const [];

  /// 文件类型分组（按 mime，数量降序）。
  List<(String, List<MsImageInfo>)> _typeGroups = const [];

  @override
  void initState() {
    super.initState();
    // 恢复 ML 索引（位置分类数据）；完成回调会更新分组。
    ref.read(mlIndexServiceProvider.notifier).load().then((_) {
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
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _loading = false;
      });
      _rebuildGroups();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 位置/类型分组（全量照片 + 索引数据齐了才算）。
  void _rebuildGroups() {
    final photos = _photos;
    final locations = ref.read(mlIndexServiceProvider.notifier).locations;
    // 位置：id 命中索引 → 0.01° 网格分桶，组名 = 归一化坐标。
    final buckets = <String, List<MsImageInfo>>{};
    final meta = <String, (double, double)>{};
    for (final p in photos) {
      final loc = locations[p.id];
      if (loc == null) continue;
      final lat = (loc[0] / _kPlaceGrid).roundToDouble() * _kPlaceGrid;
      final lng = (loc[1] / _kPlaceGrid).roundToDouble() * _kPlaceGrid;
      final key = '$lat,$lng';
      buckets.putIfAbsent(key, () => []).add(p);
      meta[key] = (lat, lng);
    }
    final places = buckets.entries.map((e) {
      final (lat, lng) = meta[e.key]!;
      final name = _placeLabel(lat, lng);
      return (name, e.value);
    }).toList()
      ..sort((a, b) => b.$2.length.compareTo(a.$2.length));
    // 文件类型：mime 分组，数量降序（全量「全部照片」卡放最前，不进这里）。
    final types = <String, List<MsImageInfo>>{};
    for (final p in photos) {
      types.putIfAbsent(p.mime, () => []).add(p);
    }
    final typeList = types.entries
        .map((e) => (_mimeLabel(e.key), e.value))
        .toList()
      ..sort((a, b) => b.$2.length.compareTo(a.$2.length));
    if (!mounted) return;
    setState(() {
      _placeGroups = places;
      _typeGroups = typeList;
    });
  }

  /// 位置组名：归一化坐标（Space Mono 等宽呈现，如 `31.23, 121.47`）。
  String _placeLabel(double lat, double lng) =>
      '${lat.toStringAsFixed(2)}, ${lng.toStringAsFixed(2)}';

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

  // ──────────── 分类列表（无输入时）────────────

  Widget _buildCategories() {
    final ml = ref.watch(mlIndexServiceProvider);
    final config = ref.watch(configProvider);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        // 全量扫描加载中：顶部轻量指示（文件类型/位置分类依赖全量列表）。
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
        // [ente 对齐] ML 进度 banner：索引进行中显示进度条（不点跳设置，
        // 设置为一级页，避免导航栈混淆；进度同时可见于设置页 ML 区）。
        if (ml.running)
          _MlProgressBanner(state: ml, onTap: null),
        // 人物：预留空态（人脸识别模型未内置）。
        _SectionHeader(t(ref, 'search_people')),
        _SectionEmpty(
          icon: Icons.face_outlined,
          title: t(ref, 'search_people_empty'),
          hint: t(ref, 'search_people_hint'),
        ),
        // 位置：索引数据驱动；mlPlaceEnabled 或空数据时展示空态引导。
        _SectionHeader(t(ref, 'search_places')),
        if (config.mlPlaceEnabled && _placeGroups.isNotEmpty)
          _buildCardRow([
            for (final (name, photos) in _placeGroups)
              _CategoryCard(
                title: name,
                count: photos.length,
                coverId: photos.first.id,
                onTap: () => _openCategory(
                    name, photos, Icons.location_on_outlined),
              ),
          ])
        else
          _SectionEmpty(
            icon: Icons.location_on_outlined,
            title: t(ref, 'search_places_empty'),
            hint: t(ref, 'search_places_hint'),
          ),
        // 文件类型：纯本地即时可用。
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
          for (final (name, photos) in _typeGroups)
            _CategoryCard(
              title: name,
              count: photos.length,
              coverId: photos.first.id,
              onTap: () =>
                  _openCategory(name, photos, Icons.image_outlined),
            ),
        ]),
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

  void _openCategory(
      String title, List<MsImageInfo> photos, IconData icon) {
    Navigator.of(context).push(enteFadeRoute(
      builder: (_) => _CategoryResultPage(
        title: title,
        icon: icon,
        photos: photos,
      ),
    ));
  }

  // ──────────── 搜索结果网格（有输入时）────────────

  Widget _buildResults(String query) {
    final q = query.toLowerCase();
    final filtered = _photos
        .where((p) => p.name.toLowerCase().contains(q))
        .toList();
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
    return Gallery(
      allFiles: filtered,
      // tagPrefix 取 'search'：与相册页 cell 的 'photo_$id' 区分，跨路由
      // 同 id 照片的 Hero tag 不冲突（搜索页叠在相册页之上，详见文件头）。
      tagPrefix: 'search',
      groupType: GroupType.none,
      crossAxisCount: cols,
      sortOrderAsc: false,
      emptyState: null,
      onFileTap: (info) => _openPhoto(filtered, info),
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

/// [ente 对齐] ML 进度 banner（搜索页分类列表顶部）：LinearProgressIndicator
/// + 已索引 x/y；索引完成/关闭后自动消失。
class _MlProgressBanner extends ConsumerWidget {
  const _MlProgressBanner({required this.state, this.onTap});

  final MlIndexState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = state.total == 0 ? 0.0 : state.processed / state.total;
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
                      t(ref, 'settings_ml_indexed_of',
                          [state.processed, state.total]),
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
        child: Gallery(
          allFiles: widget.photos,
          tagPrefix: 'search',
          groupType: GroupType.none,
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
    );
  }
}
