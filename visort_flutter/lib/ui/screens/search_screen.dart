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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/search/search_data_store.dart';
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

/// 展开态全铺时的截断数（[aves 对齐] ExpandableFilterRow.topFilterCount），
/// 超出截断并给「更多」按钮。
const int _kTopFilterCount = 50;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final TextEditingController _queryCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // [KBD] 闪烁排查打点（临时）：键盘弹出窗口内 window metrics / ListView
  // 滚动与视口的时序，logcat 采集。const false = 编译期剔除（打点在
  // 滚动/布局热路径上，release 残留是每帧字符串插值 + logcat 写入，
  // 审查 M2；取证时临时置 true）。
  static const bool _kKbdLog = false;

  final ScrollController _scrollCtrl = ScrollController();

  /// leading morph：进页时抽屉三线过渡为返回箭头（[aves 对齐]
  /// AnimatedIcons.menu_arrow；用户定稿「原抽屉按钮位置过渡为返回」）。
  late final AnimationController _menuBackCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: 0,
  );

  // ── 胶囊飞行动画（[用户定稿] 点胶囊从建议区原位飞到顶栏搜索框落位，
  // 类比点相册时封面飞行）──
  /// 顶栏已选胶囊的 GlobalKey（飞行目标坐标测量）。
  final Map<String, GlobalKey> _barChipKeys = {};

  /// 飞行中的胶囊 key（落点真实胶囊透明占位，落位后显现）。
  final Set<String> _flying = {};

  /// 最近移除的 chip keys（建议区这些 chips 挂 [_removedChipKeys] 供
  /// 飞回动画测目标坐标；系统返回清空是批量移除，坐标测完即清）。
  final Set<String> _recentlyRemoved = {};
  final Map<String, GlobalKey> _removedChipKeys = {};

  /// 进行中的飞行（entry + 独立 controller）：每次飞行自建 controller，
  /// 连点/系统返回批量飞回时多路并行互不打断（共享 controller 会被后
  /// 起飞的 reset 重启，先飞的瞬移）。dispose 时统一清。
  final List<({OverlayEntry entry, AnimationController ctrl})> _flies = [];

  /// 多选状态恒传（非选择模式恒空）：Gallery 依赖 SelectionState 包裹
  /// 结构恒定（album_screen 同款，见其 610 行注释）。
  final SelectedFiles _selection = SelectedFiles();

  // ── 数据源（[用户定稿] 提前渲染好，进页零加载）──
  /// 全量照片/buckets/分组产物/HDR 全在常驻 [searchDataProvider]
  /// （app 启动 idle 预热 + 进页对账，见 search_data_store.dart）；
  /// 页面只持 UI 态与「日期选择器」的动态 chips。
  SearchDataState get _data => ref.read(searchDataProvider);

  /// store filters + 页面 picked（date picker 产物）合并视图。
  Map<String, SearchFilterData> get _allFilters =>
      {..._data.filters, ..._picked};

  /// 日期选择器生成的「具体日期」chips（页面态；ids 随照片列表更新
  /// 重算，见 initState 的 store listen 回调）。
  final Map<String, SearchFilterData> _picked = {};

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
    WidgetsBinding.instance.addObserver(this);
    if (_kKbdLog) {
      _scrollCtrl.addListener(() {
        debugPrint('[KBD] scroll: offset=${_scrollCtrl.position.pixels} '
            'viewport=${_scrollCtrl.position.viewportDimension}');
      });
      _searchFocus.addListener(() {
        debugPrint('[KBD] focus: ${_searchFocus.hasFocus}');
      });
    }
    // leading morph 进页播放：抽屉三线 → 返回箭头（下一帧启动，等首帧
    // 布局就绪，避免与路由转场同帧竞争）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuBackCtrl.forward();
    });
    // 从看图/其他页返回本页：对账刷新（删除/收藏变更后结果网格与 chips
    // 计数刷新——store 层 id 集比对，无差异零 setState）。
    currentRouteName.addListener(_onRouteChanged);
    // store 数据变化（首载/对账/索引完成/HDR）：picked chips 重算 ids +
    // 幽灵选中清理。数据本体渲染由 watch 驱动，页面不 setState 数据。
    ref.listenManual(searchDataProvider, (prev, next) {
      if (!mounted || !next.ready) return;
      if (identical(prev?.photos, next.photos) &&
          identical(prev?.filters, next.filters)) {
        return;
      }
      setState(() {
        _refreshPickedIds(next.photos);
        _selected.removeWhere((k) => !_allFilters.containsKey(k));
      });
      _maybeAutoFocus();
    });
    // 数据对账（预热过则幂等秒回；照片集无变化零 setState）。
    unawaited(ref.read(searchDataProvider.notifier).warmUp());
    // 预热已就绪时页面首帧即完整内容——转场中聚焦，键盘伴随升起
    // （Google Photos 同款；此前所有「聚焦时机」问题的根源是页面自带
    // 入场数据帧，数据常驻后该帧不复存在）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(searchDataProvider).ready) _maybeAutoFocus();
    });
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final view = View.of(context);
    if (_kKbdLog) {
      debugPrint('[KBD] metrics: '
          'size=${view.physicalSize.width ~/ view.devicePixelRatio}x'
          '${view.physicalSize.height ~/ view.devicePixelRatio}dp '
          'insets=${view.viewInsets.bottom ~/ view.devicePixelRatio}dp '
          'padding=${view.padding.bottom ~/ view.devicePixelRatio}dp');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollCtrl.dispose();
    currentRouteName.removeListener(_onRouteChanged);
    for (final f in _flies) {
      f.entry.remove();
      f.ctrl.dispose();
    }
    _flies.clear();
    _queryCtrl.dispose();
    _searchFocus.dispose();
    _menuBackCtrl.dispose();
    super.dispose();
  }

  /// 回到本页时对账刷新：看图中删除/收藏变更会改变照片集与分组
  /// （store 层 id 集比对，无差异零 setState）。
  void _onRouteChanged() {
    if (currentRouteName.value == AlbumRoutes.search) {
      unawaited(ref.read(searchDataProvider.notifier).warmUp());
    }
  }

  /// 自动聚焦只做一次（route 返回刷新/索引回调不再弹键盘）；用户已
  /// 手动聚焦过或已离开建议态（有输入/已选 chip）则不打扰。
  bool _autoFocused = false;

  void _maybeAutoFocus() {
    if (_autoFocused || !mounted) return;
    _autoFocused = true;
    if (_searchFocus.hasFocus) return;
    if (_queryCtrl.text.isNotEmpty || _selected.isNotEmpty) return;
    _searchFocus.requestFocus();
  }
  /// picked chips 按最新照片列表重算 ids（新增同日照片也要进该日期
  /// 的结果；ids 是挑选时刻快照会漏——原 _rebuildGroups 平移逻辑）。
  void _refreshPickedIds(List<MsImageInfo> photos) {
    if (_picked.isEmpty) return;
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;
    for (final e in _picked.entries.toList()) {
      final d = DateTime.tryParse(e.key.replaceFirst('date:picked-', ''));
      if (d == null) continue;
      _picked[e.key] = SearchFilterData(
        key: e.key,
        label: e.value.label,
        category: 'date',
        icon: e.value.icon,
        ids: {for (final p in photos) if (_sameDay(p, d, metas)) p.id},
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final query = _queryCtrl.text.trim();
    // store 数据 watch（建议/结果两态共用）：数据常驻层变化（首载/对账/
    // 索引完成/HDR）驱动整页重建；picked（date picker 产物）合并进视图。
    final filters = {
      ...ref.watch(searchDataProvider.select((s) => s.filters)),
      ..._picked,
    };
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
        } else if (_selected.isNotEmpty) {
          // 系统返回清筛选与点胶囊移除同款飞回动画（用户反馈「只有点击
          // 胶囊才触发，系统返回不触发」）。
          _clearFiltersWithFlyBack();
        }
      },
      child: Scaffold(
      // 键盘弹出不再挤压 body（resize 会让整个内容列表上移跳动——进页
      // 自动聚焦时观感为「整体闪烁」，真机实测）；键盘盖在内容上层，
      // 与系统搜索页行为一致。
      resizeToAvoidBottomInset: false,
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
        // 搜索框保持 title 左起占满（[用户定稿]）；已选胶囊移到
        // actions 右侧（见下）。无边框须三态显式置 none：focusedBorder
        // 缺省回落主题，聚焦时会亮出主题高亮描边（用户反馈）。
        // 视觉对齐补偿（2026-09 跨页顶栏统一，不动布局盒/点击区）：
        //  · x −13.9：TextField 默认 contentPadding 水平 12 + 光标 ~0.8，
        //    左移后 hint/输入文字左缘 ~54.9dp —— 与返回箭头字形（右缘
        //    ~30.4dp）图形间隙 24.5dp，对齐首页「按钮→标题」基准。
        //  · y −1.2：输入文字（15px）重心偏下与 CJK 标题同因，上移贴
        //    AppBar 几何中线（同批四元素共线调校，见 app_bar_title.dart）。
        title: Transform.translate(
          offset: const Offset(-13.9, -1.2),
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
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              filled: false,
            ),
          ),
        ),
        // 右侧：已选胶囊（横滑，最大 210dp）+ 有输入时清除按钮。点顶栏
        // 胶囊移除并飞回建议区原位（仍处结果态时原地淡出）。
        actions: [
          if (_selected.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 210),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final k in _selected.toList())
                      if (_allFilters.containsKey(k))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Opacity(
                            opacity: _flying.contains(k) ? 0 : 1,
                            child: FilterChipWidget(
                              key: _barChipKeys.putIfAbsent(
                                  k, () => GlobalKey()),
                              filter: _allFilters[k]!,
                              selected: true,
                              onTap: () => _toggleFilter(k,
                                  source: _barChipKeys[k]?.currentContext),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
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
              // 已选胶囊/计数文字不上 body（[用户定稿] 胶囊进顶栏搜索框，
              // 匹配数与清除筛选文字删除；清除走返回键分层/点胶囊移除）。
              final results = _applyQueryAndFilters(query);
              final showResults = query.isNotEmpty || _selected.isNotEmpty;
              if (!showResults) return _buildSuggestions(query, filters);
              return _buildResults(results);
            },
          ),
        ),
      ),
      ),
    );
  }

  // ──────────── 维度 chip 建议（[aves 对齐] 建议 chip 行 + 组合过滤）────────────

  /// 组合谓词：同维度（category）多 chip 取并（OR），跨维度取交（AND）。
  /// 已并入 _applyQueryAndFilters（byCat 提升构建一次）。

  /// 点 chip：toggle 选中集合（同页实时过滤，不跳页）。
  /// 「日期选择器」是特殊入口 chip（不进选中集合，点了弹日期面板）。
  /// 选 chip 即进结果网格——同时收键盘（结果页不该有输入法）。
  /// [source] = 点击源 chip 的 context：添加时飞向顶栏、移除（顶栏胶囊）
  /// 时飞回建议区原位（仍处结果态、建议区不可见则原地淡出）。
  void _toggleFilter(String key, {BuildContext? source}) {
    _searchFocus.unfocus();
    if (key == 'date:picker') {
      _pickDate();
      return;
    }
    final from = _rectOf(source);
    if (_selected.contains(key)) {
      setState(() {
        _selected.remove(key);
        _recentlyRemoved.add(key);
      });
      _flyChipFromBar(key, from);
    } else {
      setState(() {
        _selected.add(key);
        // 飞行中的胶囊在落点透明占位（坐标可测），落位后显现。
        if (from != null) _flying.add(key);
      });
      if (from != null) _flyChipToBar(key, from);
    }
  }

  /// 系统返回清空筛选（返回键分层第二层）：与点胶囊移除同款批量飞回
  /// ——清空前逐个测顶栏胶囊源坐标，清空渲染建议区后各自飞回原位；
  /// 建议区未渲染该 chip（折叠截断/滚动出视口）的降级原地淡出。
  void _clearFiltersWithFlyBack() {
    final rects = <String, Rect>{};
    for (final k in _selected) {
      final r = _rectOf(_barChipKeys[k]?.currentContext);
      if (r != null) rects[k] = r;
    }
    final keys = _selected.toList();
    setState(() {
      _selected.clear();
      _recentlyRemoved.addAll(keys);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 建议区已渲染、目标 chips 已挂 key：本帧测完坐标即可摘标记
      // （setState 只标脏，重 build 在下一帧，不影响本次测量）。
      setState(() {
        _flying.addAll(keys);
        _recentlyRemoved.removeAll(keys);
      });
      for (final k in keys) {
        void clean() {
          if (mounted) setState(() => _flying.remove(k));
        }

        final filter = _allFilters[k];
        if (filter == null) {
          clean(); // 幽灵 key（理论上重建时已清）：只清占位
          continue;
        }
        final from = rects[k];
        final to = _rectOf(_removedChipKeys[k]?.currentContext);
        if (from == null) {
          clean(); // 无源坐标（顶栏胶囊未挂上）：无可飞的，只清占位
          continue;
        }
        if (to == null) {
          // 建议区未渲染该 chip（折叠截断/滚出视口）：原地淡出。
          _fadeOutFly(filter, from, onDone: clean);
          continue;
        }
        _startFly(filter, from, to, t0: 1, t1: 0, onDone: clean);
      }
    });
  }

  /// context 的屏幕矩形（飞行起/终点测量）；无效 context 返回 null。
  Rect? _rectOf(BuildContext? ctx) {
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.attached) {
      final o = box.localToGlobal(Offset.zero);
      return Rect.fromLTWH(o.dx, o.dy, box.size.width, box.size.height);
    }
    return null;
  }

  /// 通用飞行层：from → to 直线插值（easeOutCubic 260ms），选中色随程
  /// 插值（[用户定稿] 变色发生在飞行期间——飞去 t 0→1 渐变选中色、飞回
  /// 1→0 渐回普通色，起飞/落位两侧与真实胶囊零色差跳变）。每次飞行
  /// 独立 controller：并行多飞互不打断（共享会被后起飞的 reset 重启）。
  void _startFly(SearchFilterData filter, Rect from, Rect to,
      {double t0 = 0, double t1 = 1, VoidCallback? onDone}) {
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => AnimatedBuilder(
        animation: ctrl,
        builder: (ctx, _) {
          final k = Curves.easeOutCubic.transform(ctrl.value);
          return Positioned.fromRect(
            rect: Rect.lerp(from, to, k)!,
            child: Material(
              type: MaterialType.transparency,
              child: FilterChipWidget(
                filter: filter,
                selectedT: t0 + (t1 - t0) * k,
                onTap: () {},
              ),
            ),
          );
        },
      ),
    );
    _flies.add((entry: entry, ctrl: ctrl));
    Overlay.of(context, rootOverlay: true).insert(entry);
    ctrl.forward().whenComplete(() {
      entry.remove();
      _flies.removeWhere((f) => f.entry == entry);
      ctrl.dispose();
      onDone?.call();
    });
  }

  /// 添加选中：布局稳定后测顶栏落位坐标，从建议区源位飞过去
  /// （普通色 → 选中色）。
  void _flyChipToBar(String key, Rect from) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final to = _rectOf(_barChipKeys[key]?.currentContext);
      final filter = _allFilters[key];
      if (to == null || filter == null) {
        setState(() => _flying.remove(key));
        return;
      }
      _startFly(filter, from, to, onDone: () {
        if (mounted) setState(() => _flying.remove(key));
      });
    });
  }

  /// 移除选中：回到建议态时从顶栏飞回建议区原位（[_recentlyRemoved]
  /// 标记的 chip 挂临时 GlobalKey 测目标，选中色 → 普通色）；仍处
  /// 结果态（建议区不可见）时原地淡出。
  void _flyChipFromBar(String key, Rect? from) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final filter = _allFilters[key];
      if (filter == null) {
        setState(() => _recentlyRemoved.remove(key));
        return;
      }
      final to = _rectOf(_removedChipKeys[key]?.currentContext);
      if (from == null || to == null) {
        // 无源坐标或建议区未渲染（仍处结果态）：原地淡出（同步渐失色）。
        if (from != null) _fadeOutFly(filter, from);
        setState(() => _recentlyRemoved.remove(key));
        return;
      }
      setState(() => _flying.add(key));
      _startFly(filter, from, to, t0: 1, t1: 0, onDone: () {
        if (mounted) {
          setState(() {
            _flying.remove(key);
            _recentlyRemoved.remove(key);
          });
        }
      });
    });
  }

  /// 原地淡出（目标不可见时的移除动画）：透明度与选中色同步回落。
  void _fadeOutFly(SearchFilterData filter, Rect at, {VoidCallback? onDone}) {
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => AnimatedBuilder(
        animation: ctrl,
        builder: (ctx, _) => Positioned.fromRect(
          rect: at,
          child: Opacity(
            opacity: 1 - ctrl.value,
            child: Material(
              type: MaterialType.transparency,
              child: FilterChipWidget(
                filter: filter,
                selectedT: 1 - ctrl.value,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    _flies.add((entry: entry, ctrl: ctrl));
    Overlay.of(context, rootOverlay: true).insert(entry);
    ctrl.forward().whenComplete(() {
      entry.remove();
      _flies.removeWhere((f) => f.entry == entry);
      ctrl.dispose();
      onDone?.call();
    });
  }

  /// 输入过滤后的维度 chips（label contains，大小写不敏感；
  /// [aves 对齐] Aves containQuery 同款语义）。顺序保持注册序——
  /// 各维度列表构建时已按数量排好；date 区注册序=显示序（选择器/最近
  /// 添加/月份/星期在前）。
  /// [categories] 支持多维度合并（地点栏 = 省份在前 + 地点在后；category
  /// 仍各自独立，跨维度 AND 语义不受显示合并影响）。
  List<SearchFilterData> _sectionChips(
      List<String> categories, String q, Map<String, SearchFilterData> filters) {
    final chips = filters.values
        .where((f) => categories.contains(f.category))
        .toList(growable: false);
    if (q.isEmpty) return chips;
    final lq = q.toLowerCase();
    return chips.where((f) => f.label.toLowerCase().contains(lq)).toList();
  }


  /// 维度建议列表。有输入时各维度 chips 按词过滤（跨维度联动检索）。
  /// 每栏标题右侧折叠/展开（[aves 对齐] ExpandableFilterRow）：
  /// 折叠态只露常用项（日期=近几月，其余=前 8），展开看全量。
  Widget _buildSuggestions(String query, Map<String, SearchFilterData> filters) {
    final index = ref.watch(searchIndexServiceProvider);
    final config = ref.watch(configProvider);
    final hasPlace = config.mlIndexEnabled &&
        filters.values.any((f) => f.category == 'place');
    return ListView(
      controller: _scrollCtrl,
      // 滚动即收键盘（用户反馈：滚动页面应自动收起输入法）。
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      // top 12：quick 首行距顶栏（用户定稿 12dp，与相册页新顶距一致）。
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      children: [
        // 索引进度 banner（设置页「智能识别」区同源）。
        if (index.running)
          _MlProgressBanner(state: index, onTap: null),
        // 快捷行（无标题，[aves 对齐] Aves 首行 typeFilters 位）：恒展开
        // 无折叠箭头（[用户定稿]「第一行保持展开状态，把折叠按钮去掉」）。
        _buildSection(
          categories: const ['quick'],
          query: query,
          alwaysExpanded: true,
          filters: filters,
        ),
        // [用户定稿] 栏目顺序：文件类型 → 日期 → 相册 → 地点（省份+地点
        // 合并一栏，省份在前地点在后；category 各自独立保 AND 语义）→
        // 拍摄设备 → 元数据。
        _buildSection(
          title: t(ref, 'search_types'),
          categories: const ['mime'],
          query: query,
          filters: filters,
        ),
        // 日期（[aves 对齐]：选择日期/最近添加/月份/星期，注册序即显示序）。
        _buildSection(
          title: t(ref, 'search_dates'),
          categories: const ['date'],
          query: query,
          filters: filters,
        ),
        _buildSection(
            title: t(ref, 'search_albums'),
            categories: const ['album'],
            query: query,
            filters: filters),
        // 地点：省份 chips 在前、市/地点在后（注册序），索引驱动，空态
        // 按配置分流引导。
        if (hasPlace)
          _buildSection(
            title: t(ref, 'search_places'),
            categories: const ['province', 'place'],
            query: query,
            filters: filters,
          )
        else if (query.isEmpty) ...[
          _SectionHeader(t(ref, 'search_places')),
          _SectionEmpty(
            icon: Icons.location_on_outlined,
            title: t(ref, 'search_places_empty'),
            hint: !config.mlIndexEnabled
                ? t(ref, 'search_places_hint_index')
                : t(ref, 'search_places_hint'),
          ),
        ],
        // 拍摄设备（索引 camera 字段，元数据上面）。
        _buildSection(
            title: t(ref, 'search_cameras'),
            categories: const ['camera'],
            query: query,
            filters: filters),
        // 元数据（[aves 对齐] 负向过滤区：缺日期/未定位/无相机）。
        _buildSection(
            title: t(ref, 'search_metadata'),
            categories: const ['meta'],
            query: query,
            filters: filters),
      ],
    );
  }

  /// 照片拍摄日（EXIF 缺失兜底入库时间）是否与 [d] 同日（date picker
  /// 与 picked chip 重算共用）。
  bool _sameDay(MsImageInfo p, DateTime d, Map<String, MsSearchMeta> metas) {
    final taken = metas[p.id]?.dateTakenMs ?? p.dateAddedMs;
    if (taken <= 0) return false;
    final dt = DateTime.fromMillisecondsSinceEpoch(taken);
    return dt.year == d.year && dt.month == d.month && dt.day == d.day;
  }

  /// 日期选择器：选日后生成「2025年6月15日」过滤 chip 并选中。
  Future<void> _pickDate() async {
    if (_data.photos.isEmpty) return; // 数据未就绪，无据可滤
    _searchFocus.unfocus(); // 弹日期面板前收键盘
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
      helpText: t(ref, 'search_date_picker'),
    );
    if (d == null || !mounted) return;
    final ids = <String>{
      for (final p in _data.photos)
        if (_sameDay(p, d, ref.read(searchIndexServiceProvider.notifier).metas))
          p.id,
    };
    final fmt = t(ref, 'search_picked_fmt')
        .replaceFirst('{y}', '${d.year}')
        .replaceFirst('{m}', '${d.month}')
        .replaceFirst('{d}', '${d.day}');
    setState(() {
      _picked['date:picked-${d.toIso8601String()}'] = SearchFilterData(
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
    bool alwaysExpanded = false,
    required Map<String, SearchFilterData> filters,
  }) {
    final sectionKey = categories.join('+');
    final chips = _sectionChips(categories, query, filters);
    if (chips.isEmpty) return const SizedBox.shrink();
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
                        // 「更多」态全部重置（收起旧区的残留 showAll 会让
                        // 其重展开时仍处全显态，与注释语义不符，子代理 P3）。
                        _expandedSection = sectionKey;
                        _showAllSections.clear();
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
                    Builder(
                      // 飞回动画的目标 chips 临时挂 key（测落位坐标；
                      // 批量移除时多个并存）。
                      key: _recentlyRemoved.contains(c.key)
                          ? _removedChipKeys.putIfAbsent(
                              c.key, () => GlobalKey())
                          : null,
                      builder: (chipCtx) => Opacity(
                        opacity: _flying.contains(c.key) ? 0 : 1,
                        child: FilterChipWidget(
                          filter: c,
                          selected: _selected.contains(c.key),
                          onTap: () => _toggleFilter(c.key, source: chipCtx),
                        ),
                      ),
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
  /// byCat 按选中集构建一次复用到每张照片（此前每照片在 _matchSelected
  /// 里重建 map，2000 张 × 每次按键全量重算，子代理审查 P3）。
  List<MsImageInfo> _applyQueryAndFilters(String query) {
    final q = query.toLowerCase();
    final metas = ref.read(searchIndexServiceProvider.notifier).metas;
    // bucketNames 取一次复用（getter 每次访问重建整个 Map——循环内访问
    // 即 O(N×B)：万张库每按键百万次 Map 插入全在 UI isolate，审查 H1）。
    final bucketNames = _data.bucketNames;
    final byCat = <String, List<SearchFilterData>>{};
    for (final k in _selected) {
      final f = _allFilters[k];
      if (f == null) continue;
      byCat.putIfAbsent(f.category, () => []).add(f);
    }
    bool matchSelected(String id) =>
        byCat.isEmpty || byCat.values.every((fs) => fs.any((f) => f.contains(id)));
    return _data.photos.where((p) {
      if (!matchSelected(p.id)) return false;
      if (q.isEmpty) return true;
      if (p.name.toLowerCase().contains(q)) return true;
      if ((bucketNames[p.bucketId] ?? '').toLowerCase().contains(q)) {
        return true;
      }
      final m = metas[p.id];
      if (m == null) return false;
      // 地名匹配含省/国：placeLabel = locality ?? adminArea ?? country 是
      // 短路兜底链，搜「浙江」要能命中 placeLabel=「杭州市」的照片
      //（审查 P2 文本搜索不命中省份）。
      return m.placeLabel.toLowerCase().contains(q) ||
          (m.adminArea?.toLowerCase().contains(q) ?? false) ||
          (m.country?.toLowerCase().contains(q) ?? false) ||
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
