// 视图选项按钮 —— 相册首页 / 快速整理 / 相册内（含收藏/回收站）AppBar 右侧共用
//
// [ente 对齐] 交互移植自 Ente Photos 相册列表页选项菜单（albums_tab.dart）：
//  · 视图切换（沉浸↔日期，仅相册内）与布局切换（列表↔网格）都是**单个
//    条目**：label 与图标显示「目标」态（当前沉浸 → 显示「日期视图」），
//    点一下互换（对应 Ente _toggleViewMode / toggleView）。
//  · 排序**不设独立升/降序按钮**：点已激活维度 = 升/降互换，点其他维度 =
//    切过去并重置升序（对应 Ente _setSortMode）；方向由激活行尾部上/下
//    箭头表达，选中维度以 accent + 加粗表达（无勾选、无背景高亮）。
//  · 网格列数是步进行（[−] N [+]），仅当前布局为网格时显示（列表布局
//    无列数概念）；范围按页面传入（bucket 网格 2–4，照片网格 3–5）。
//
// 面板行为：所有行点击**即时生效、面板不关闭**（列数步进需要连续调节；
// 排序方向点一下换一下也需要面板驻留），点面板外/返回键收回。面板自身
// 状态为本地 State（快照自打开时参数），每次点击 setState + 回调，页面侧
// watch 自己的 provider 跟着刷新——面板不感知各页状态拓扑。
//
// 弹出方式：showSpringPopupFromAnchor —— 与设置选择器动画完全统一
// （展开 1000ms 弹簧 / 收回 450ms）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';

/// 视图选项按钮：视图/布局（单条目切换）+ 网格列数 + 排序，一个入口收口。
///
/// [timelineView] / [layout] 为 null 表示页面无此切换（相册内恒网格不传
/// layout；收藏/回收站无视图切换不传 timelineView），面板不显示对应行。
/// [gridColumns] 为 null 表示页面不支持调列数（当前无此页，预留）。
class ViewOptionsToggle extends ConsumerStatefulWidget {
  const ViewOptionsToggle({
    super.key,
    this.timelineView,
    this.onTimelineViewChanged,
    this.layout,
    this.onLayoutChanged,
    this.gridColumns,
    this.onGridColumnsChanged,
    this.gridColumnsMin = 2,
    this.gridColumnsMax = 4,
    required this.sortBy,
    required this.asc,
    required this.onSortChanged,
    this.showDateTrashed = false,
    this.showDateFavorited = false,
  });

  /// 当前是否日期分组视图；null = 页面无视图切换（收藏/回收站）。
  final bool? timelineView;

  /// 视图切换回调（点视图行时触发；切换副作用由页面处理）。
  final VoidCallback? onTimelineViewChanged;

  /// 当前布局；null = 页面恒网格（相册内），不显示布局行。
  final HomeLayout? layout;

  /// 布局切换回调（点布局行时触发，参数为目标布局）。
  final ValueChanged<HomeLayout>? onLayoutChanged;

  /// 当前列数；null = 不显示列数行。
  final int? gridColumns;

  /// 列数步进回调（点 [−]/[+] 时触发，参数为新列数，已 clamp 到范围）。
  final ValueChanged<int>? onGridColumnsChanged;

  /// 列数步进范围（bucket 网格默认 2–4；照片网格调用方传 3–5）。
  final int gridColumnsMin;
  final int gridColumnsMax;

  final SortBy sortBy;
  final bool asc;
  final void Function(SortBy sortBy, bool asc) onSortChanged;

  /// 回收站视图：排序段显示「按删除日期」(dateTrashed) 维度选项。
  final bool showDateTrashed;

  /// 收藏视图：排序段显示「按收藏日期」(dateFavorited) 维度选项
  /// （本地记录的收藏时刻，Dart 内存排序）。
  final bool showDateFavorited;

  @override
  ConsumerState<ViewOptionsToggle> createState() => _ViewOptionsToggleState();
}

class _ViewOptionsToggleState extends ConsumerState<ViewOptionsToggle>
    with SingleTickerProviderStateMixin {
  /// 配套 morph 驱动：0 = 收起态（三线筛选 + accent 滑点，Ente
  /// FilterHorizontal 风格），1 = 展开态 ✕。450ms 与面板收回时长一致
  /// （展开弹簧 1000ms 的主要运动段也在前 ~500ms，观感同步）。
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  @override
  void dispose() {
    _morph.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      // 自绘矢量 morph（见 _FilterMorphIcon）：SDK 的 AnimatedIcons.menu_close
      // 收起态是标准 ☰，会与左侧抽屉按钮撞脸，故自绘「三线筛选 ↔ ✕」对。
      // 面板打开期间图标变 ✕——按钮区域点按命中的是关闭屏障，语义闭环。
      icon: _FilterMorphIcon(animation: _morph),
      tooltip: t(ref, 'view_options'),
      onPressed: _openPanel,
    );
  }

  Future<void> _openPanel() async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    // 宽度按「最坏情况」测量（列数行可能在中途出现：列表→网格切换后），
    // 面板尺寸在打开期间保持恒定，行内容增减不跳动。
    final menuWidth = _measurePanelWidth();

    _morph.forward();
    // 面板不因行点击而关闭（见文件头注释），返回值无意义；future 完成
    // （屏障点按/返回键收回）即反向 morph 复位。
    await showSpringPopupFromAnchor<void>(
      context: context,
      barrierLabel: 'view_options',
      // 弹簧起点 = 按钮中心 × 面板顶边（与首页 ⋮ / 设置 ▾ 一致）
      anchorGlobalDx: pos.dx + box.size.width / 2,
      anchorGlobalDy: pos.dy + box.size.height + 4,
      // 面板右缘离按钮右缘 8dp（不贴屏幕右边；上限先钳非负——menuWidth
      // 可超屏宽（大字号/窄屏），负上限进 clamp 即 ArgumentError，审查 F12）
      menuLeft: (pos.dx + box.size.width - menuWidth - 8).clamp(
        0.0,
        (screen.width - menuWidth).clamp(0.0, double.infinity),
      ),
      menuTop: pos.dy + box.size.height + 4,
      menuWidth: menuWidth,
      menuBuilder: (ctx) => _ViewOptionsPanel(
        initialTimelineView: widget.timelineView,
        onTimelineViewChanged: widget.onTimelineViewChanged,
        initialLayout: widget.layout,
        onLayoutChanged: widget.onLayoutChanged,
        initialGridColumns: widget.gridColumns,
        onGridColumnsChanged: widget.onGridColumnsChanged,
        gridColumnsMin: widget.gridColumnsMin,
        gridColumnsMax: widget.gridColumnsMax,
        sortBy: widget.sortBy,
        asc: widget.asc,
        onSortChanged: widget.onSortChanged,
        showDateTrashed: widget.showDateTrashed,
        showDateFavorited: widget.showDateFavorited,
      ),
    );
    if (mounted) _morph.reverse();
  }

  /// 测量面板内容宽度（弹簧锚点定位 + Positioned 定宽用）。
  /// 行结构 = 左右内边距(16×2) + 图标(16) + 间距(8) + 文字 + 尾部控件；
  /// 取所有行（含最坏情况下的列数行）的最大值。
  double _measurePanelWidth() {
    const style = TextStyle(
      fontFamily: 'Space Mono',
      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
      fontSize: 12,
    );
    final scaler = MediaQuery.textScalerOf(context);
    double textW(String s) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width;
    }

    double rowWidth(String label, [double trailing = 0]) =>
        16 * 2 + 16 + 8 + textW(label) + trailing;

    final candidates = <double>[
      // 视图切换行 / 布局行（label 为目标态名）
      if (widget.timelineView != null) ...[
        rowWidth(t(ref, 'view_immersive')),
        rowWidth(t(ref, 'view_date')),
      ],
      if (widget.layout != null) ...[
        rowWidth(t(ref, 'layout_list')),
        rowWidth(t(ref, 'layout_grid')),
      ],
      // 列数行：图标 + label + 16 空隙 + 步进器（30+4+24+4+30）
      if (widget.gridColumns != null)
        rowWidth(t(ref, 'grid_columns'), 16 + 30 + 4 + 24 + 4 + 30),
      // 排序维度行（最坏情况 = 沉浸视图全维度）：激活行尾部方向箭头（8+14）
      rowWidth(t(ref, 'sort_by_name'), 8 + 14),
      rowWidth(t(ref, 'sort_by_date_created'), 8 + 14),
      rowWidth(t(ref, 'sort_by_date_modified'), 8 + 14),
      if (widget.showDateTrashed) rowWidth(t(ref, 'sort_by_date_trashed'), 8 + 14),
      if (widget.showDateFavorited)
        rowWidth(t(ref, 'sort_by_date_favorited'), 8 + 14),
    ];
    // 尾部 +2：测量余量。
    return candidates.reduce((a, b) => a > b ? a : b) + 2;
  }
}

/// 配套 morph 图标：收起态 = 三线筛选 + accent 滑点（Ente 原版按钮
/// HugeIcons FilterHorizontal 的同构复刻——三细横线各带一枚交错圆点），
/// 展开态 = ✕。上下两线端点向 ✕ 对角臂连续插值（矢量形变，非两图标
/// 切换），中线与滑点随进度收缩淡出；驱动源为 450ms AnimationController
/// （与面板收回时长一致，见 _ViewOptionsToggleState）。
class _FilterMorphIcon extends StatelessWidget {
  const _FilterMorphIcon({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => CustomPaint(
        // 28px 画布（> 标准 24）：三线+滑点图形留白多、24px 显小（用户
        // 反馈"有点小"），放大后线宽随比例到 ~2.2，视觉分量与 ☰ 一致。
        size: const Size.square(28),
        painter: _FilterMorphPainter(animation.value),
      ),
    );
  }
}

class _FilterMorphPainter extends CustomPainter {
  _FilterMorphPainter(this.t);

  /// morph 进度：0 = 收起态（三线筛选），1 = 展开态（✕）。
  final double t;

  /// 收起态三线端点（24 视口，线宽 1.9 圆头）。整体轮廓收窄成近方形
  /// （~11×10），与左侧抽屉按钮的侧栏图形（14×13 方框）轮廓呼应
  /// （2026-08 用户反馈：宽扁条 → 接近方形矩形）。
  static const _topA = Offset(6.4, 7.9), _topB = Offset(17.6, 7.9);
  static const _botA = Offset(6.4, 16.1), _botB = Offset(17.6, 16.1);

  /// 展开态 ✕ 两臂端点（上线 → ↘ 臂，下线 → ↗ 臂）。
  static const _xTL = Offset(7.2, 7.2), _xBR = Offset(16.8, 16.8);
  static const _xTR = Offset(16.8, 7.2), _xBL = Offset(7.2, 16.8);

  Offset _mix(Offset a, Offset b) =>
      Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..color = AppColors.text;
    final knob = Paint()
      ..style = PaintingStyle.fill
      ..color = AppColors.accent.withValues(alpha: (1 - t).clamp(0.0, 1.0));

    // 上线 / 下线 → ✕ 两臂（端点插值 = 线段连续旋转伸缩）。
    final topA = _mix(_topA, _xTL), topB = _mix(_topB, _xBR);
    final botA = _mix(_botA, _xBL), botB = _mix(_botB, _xTR);
    canvas.drawLine(topA, topB, line);
    canvas.drawLine(botA, botB, line);

    // 中线：随进度向中心收缩并淡出（收起态比上下线短，filter 语义）。
    final fade = (1 - t).clamp(0.0, 1.0);
    if (fade > 0) {
      final half = 3.4 * fade;
      canvas.drawLine(
        Offset(12 - half, 12),
        Offset(12 + half, 12),
        line..color = AppColors.text.withValues(alpha: fade),
      );
      line.color = AppColors.text;
    }

    // 滑点（accent）：收起态三枚交错（上右/中左/下右，Ente 同构）；上线/
    // 下线的滑点沿线参数滑动（随线形变），全部随进度收缩淡出。
    if (fade > 0) {
      final r = 1.75 * (1 - 0.35 * t);
      Offset along(Offset a, Offset b, double k) =>
          Offset(a.dx + (b.dx - a.dx) * k, a.dy + (b.dy - a.dy) * k);
      canvas.drawCircle(along(topA, topB, 0.68), r, knob);
      canvas.drawCircle(Offset(12 - 2.6 * fade, 12), r, knob);
      canvas.drawCircle(along(botA, botB, 0.68), r, knob);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FilterMorphPainter oldDelegate) => oldDelegate.t != t;
}

/// 面板本体：本地状态快照 + 即时回调（见文件头注释）。
class _ViewOptionsPanel extends ConsumerStatefulWidget {
  const _ViewOptionsPanel({
    required this.initialTimelineView,
    required this.onTimelineViewChanged,
    required this.initialLayout,
    required this.onLayoutChanged,
    required this.initialGridColumns,
    required this.onGridColumnsChanged,
    required this.gridColumnsMin,
    required this.gridColumnsMax,
    required this.sortBy,
    required this.asc,
    required this.onSortChanged,
    required this.showDateTrashed,
    required this.showDateFavorited,
  });

  final bool? initialTimelineView;
  final VoidCallback? onTimelineViewChanged;
  final HomeLayout? initialLayout;
  final ValueChanged<HomeLayout>? onLayoutChanged;
  final int? initialGridColumns;
  final ValueChanged<int>? onGridColumnsChanged;
  final int gridColumnsMin;
  final int gridColumnsMax;
  final SortBy sortBy;
  final bool asc;
  final void Function(SortBy sortBy, bool asc) onSortChanged;
  final bool showDateTrashed;
  final bool showDateFavorited;

  @override
  ConsumerState<_ViewOptionsPanel> createState() => _ViewOptionsPanelState();
}

class _ViewOptionsPanelState extends ConsumerState<_ViewOptionsPanel> {
  late bool? _timelineView = widget.initialTimelineView;
  late HomeLayout? _layout = widget.initialLayout;
  late int? _cols = widget.initialGridColumns;
  late SortBy _by = widget.sortBy;
  late bool _asc = widget.asc;

  /// 列数行显示条件：支持调列数 且（无布局概念 或 当前为网格）。
  bool get _showColsRow =>
      _cols != null && (_layout == null || _layout == HomeLayout.grid);

  /// 日期视图（有视图切换的页面 + 当前为日期分组）：排序段砍成单行。
  /// 由面板当前视图**动态推导**（非打开时快照）——视图切换后面板立即
  /// 跟着变（曾为快照：切视图后须重开面板才刷新）。
  bool get _dateOnly => widget.initialTimelineView != null && _timelineView!;

  void _toggleTimelineView() {
    setState(() {
      _timelineView = !(_timelineView ?? false);
      // 切进日期视图：页面会把排序强制为按创建日期（日期分组依赖
      // dateCreated 顺序，见 album_screen._toggleViewMode）——面板排序段
      // 同步重置，激活行与页面实际状态一致。
      if (_timelineView!) _by = SortBy.dateCreated;
    });
    widget.onTimelineViewChanged?.call();
  }

  void _toggleLayout() {
    final next =
        _layout == HomeLayout.grid ? HomeLayout.list : HomeLayout.grid;
    setState(() => _layout = next);
    widget.onLayoutChanged?.call(next);
  }

  void _bumpCols(int delta) {
    final next = (_cols! + delta)
        .clamp(widget.gridColumnsMin, widget.gridColumnsMax);
    if (next == _cols) return;
    setState(() => _cols = next);
    widget.onGridColumnsChanged?.call(next);
  }

  /// [ente 对齐] 点已激活维度 = 升/降互换；点其他维度 = 切过去并重置升序。
  void _tapSortDim(SortBy key) {
    if (key == _by) {
      setState(() => _asc = !_asc);
      widget.onSortChanged(_by, _asc);
    } else {
      setState(() {
        _by = key;
        _asc = true;
      });
      widget.onSortChanged(key, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceElevated,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // stretch：行拉满面板宽（尾部控件右对齐，ente 行式：槽位 + label + 尾部）
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 视图切换行（第一行；仅相册内普通相册）：label/图标 = 目标视图 ──
          if (_timelineView != null)
            _PanelRow(
              icon: _timelineView! ? Icons.view_module : Icons.calendar_view_day,
              label: t(
                ref,
                _timelineView! ? 'view_immersive' : 'view_date',
              ),
              onTap: _toggleTimelineView,
            ),
          // ── 布局段：单条目切换（label/图标 = 目标布局）──
          if (_layout != null)
            _PanelRow(
              icon: _layout == HomeLayout.grid
                  ? Icons.view_list
                  : Icons.grid_view,
              label: t(
                ref,
                _layout == HomeLayout.grid ? 'layout_list' : 'layout_grid',
              ),
              onTap: _toggleLayout,
            ),
          // ── 列数行（仅网格布局）──
          if (_showColsRow)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.grid_on, size: 16, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Text(t(ref, 'grid_columns'), style: _labelStyle),
                  const Spacer(),
                  _StepButton(
                    icon: Icons.remove_circle_outlined,
                    onTap: _cols! > widget.gridColumnsMin
                        ? () => _bumpCols(-1)
                        : null,
                  ),
                  SizedBox(
                    width: 24,
                    child: Text(
                      '$_cols',
                      textAlign: TextAlign.center,
                      style: _labelStyle.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _StepButton(
                    icon: Icons.add_circle_outlined,
                    onTap: _cols! < widget.gridColumnsMax
                        ? () => _bumpCols(1)
                        : null,
                  ),
                ],
              ),
            ),
          // ── 分隔线 ──
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: AppColors.border,
          ),
          // ── 排序段：维度行，激活行尾部上/下箭头 = 当前方向 ──
          if (!_dateOnly) ...[
            _sortRow(SortBy.name, Icons.sort_by_alpha, 'sort_by_name'),
            _sortRow(
                SortBy.dateCreated, Icons.access_time, 'sort_by_date_created'),
            _sortRow(
                SortBy.dateModified, Icons.access_time, 'sort_by_date_modified'),
            // 回收站视图额外提供「按删除日期」（DATE_EXPIRES）
            if (widget.showDateTrashed)
              _sortRow(SortBy.dateTrashed, Icons.delete_outline,
                  'sort_by_date_trashed'),
            // 收藏视图额外提供「按收藏日期」（本地记录的收藏时刻）
            if (widget.showDateFavorited)
              _sortRow(SortBy.dateFavorited, Icons.favorite_border,
                  'sort_by_date_favorited'),
          ] else
            // 日期视图：维度固定按创建日期，点行只换方向
            _sortRow(
                SortBy.dateCreated, Icons.access_time, 'sort_by_date_created'),
        ],
      ),
    );
  }

  Widget _sortRow(SortBy by, IconData icon, String labelKey) {
    final active = _by == by;
    return _PanelRow(
      icon: icon,
      label: t(ref, labelKey),
      active: active,
      // 方向箭头只在激活行出现（点该行即换向）
      trailing: active
          ? Icon(
              _asc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: AppColors.accent,
            )
          : null,
      onTap: () => _tapSortDim(by),
    );
  }

  static TextStyle get _labelStyle => const TextStyle(
        fontFamily: 'Space Mono',
        fontFamilyFallback: ['Noto Sans Mono CJK SC'],
        fontSize: 12,
        color: AppColors.text,
      );
}

/// 面板单行：图标 + 文本 +（可选）尾部控件；激活态 accent + 加粗。
class _PanelRow extends StatelessWidget {
  const _PanelRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? AppColors.accent : AppColors.muted,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: const ['Noto Sans Mono CJK SC'],
                fontSize: 12,
                color: active ? AppColors.accent : AppColors.text,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
            const Spacer(),
            // 尾部控件右对齐（无则不占位；方向箭头仅激活行出现）
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 步进小按钮（30×30 圆形水波 + 20px 圆形描边图标对）：边界处禁用
/// （onTap = null，图标变淡）。裸 +/− 字形过简，换成成对的
/// remove/add_circle_outlined 与面板整体图标密度一致。
class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return SizedBox(
      width: 30,
      height: 30,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Center(
          child: Icon(
            icon,
            size: 20,
            color: enabled
                ? AppColors.text
                : AppColors.muted.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}
