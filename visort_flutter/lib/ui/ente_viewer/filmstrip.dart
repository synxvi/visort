// 底栏缩略图条（filmstrip）——第三版整体重写（2026-09-06）。
//
// 本版按 ColorOS 系统相册主图页 thumbline 的反编译实证（jadx + smali，
// _reverse/gallery3d）重建机制，替换上一版 ListView + 窗口滑窗 + padding
// 补偿 + 渲染层校准 jumpTo 的补丁堆叠。反编译关键结构：
//   - ThumbLineLayoutManager —— 自研 LayoutManager：锚点式布局
//     （selection + anchorOffset 定义全部几何，从锚点向两侧按步距累积），
//     深位定位 O(视口)；scrollHorizontallyBy 只递减 anchorOffset 并按
//     首/末项居中钳制——**无 snap 物理、无橡皮筋**；
//   - ds70（ThumbLineContract）—— 状态机与联动仲裁：选区变更统一走
//     F() 通知主图跟随；主图滚动事件 e() 在条非静止时被忽略；
//   - 联动几何 p()：主图拖动 fraction 实时映射为条的双项连续插值
//     （出项 1-f 缩小、入项 f 长大、整体偏移 −35×f）——逐帧锁步；
//   - 停稳行为：fling 自然减速停在任意位置（LinearSnapHelper 未挂载），
//     IDLE 后由 animExpandCenter 把中心最近项拉正 + 撑大（同弹簧）；
//   - 拖动跨档：onSelectionChanged → 旧聚焦项弹簧缩回 + 轻震 tick；
//   - fling 速度钳 ±12000 物理 px（ThumbLineRecyclerView）。
//   尺寸实证（photopage_thumbline_* dimens，普通手机竖屏）：普通项
//   21.33×32 / 聚焦项 32×32（高度不变仅变宽），普通间隙 4 / 聚焦两侧
//   间隙 16，条高 38 = 4+32+2，圆角 3，无聚焦边框。聚焦项样式照搬系统
//   （2026-09 用户定稿）；普通项沿用 visort 稍大定稿 23×32 / 间隙 5。
//
// 本版行为契约：
//   1. 布局 = 纯函数 (selection, selDx, 各项 focus fraction)：selection
//      项中心位于视口中心 + selDx，其余项按步距累积展开；只构建视口
//      ±缓冲内的 item。无滚动 offset、无窗口、无坐标系换算——上一版
//      漂移类 bug（滑窗错位/校准跳变/深位 O(N)）的根因整体消失；
//   2. 手势：拖动开始 → 聚焦项缩回（~180ms）；拖动/甩动中选区连续
//      跟随「中心最近项」（跨档轻震 + onCenterChanged 实时上报，宿主
//      jumpToPage 主图跟手）；fling 用标准摩擦减速**不吸附**，完全停稳
//      后把最近项拉到中心并同时撑开（对标 animExpandCenter）；
//   3. 端点钳制：首/末项居中即滚动极限（硬钳，无回弹）；
//   4. 外部指令（主图翻页/删除同步写 center）：近距弹簧滑移（运动中
//      无聚焦，到达后撑开——2026-09 用户定稿），远距（> 一屏）同帧
//      落位；条自身拖动/甩动中忽略外部指令（对标 e() 的静止门控）；
//   5. 锁步（可选 pagePos 输入）：主图用户拖动时，条按翻页 fraction
//      逐帧双项插值跟随（对标 p()）；主图正被条程序驱动（pagerDriven）
//      时锁步让位，避免与条自身动画互搏。
//
// 联动接口（宿主 = detail_page，与上一版签名兼容）：
//   - [center] 入向桥：外部写 = 程序滑移指令；组件自身**永不回写**
//     （上报只走回调，回声问题不存在）；
//   - [onCenterChanged]：用户拖动/甩动跨档（实时，宿主跟手联动主图）；
//   - [onSettled]：停稳撑开完成 / 点按滑移到位（宿主 animateToPage）；
//   - [onTap]：点按单项（组件先滑移，宿主管主图跳转）；
//   - [onItemBuild]：条目构建钩子（宿主注入解码预取）；
//   - [frozen]：pop 冻结/删除流程：忽略一切输入与指令，渲染照常；
//     解除时对齐 center（删除流程的补聚焦在此发生）；
//   - [pagePos]/[pagerDriven]：主图翻页连续位置（PageController.page）
//     与「主图正被条程序驱动」标记——锁步跟随的门控。

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show HorizontalDragGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;

import 'package:visort_flutter/ui/ente_viewer/thumbnail_widget.dart';

// ─────────────── 视觉常量（2026-09 定稿：聚焦项照搬系统相册，单点定义） ───────────────

/// 条高（竖屏）：系统 list_height 38 = 顶 4 + 图 32 + 底 2。
const double kFilmstripHeight = 38.0;

/// 普通项图片 23×32（visort 定稿稍大档；系统 21.33×32）。
const double _kImgWN = 23.0, _kImgHN = 32.0;

/// 聚焦项图片宽 32 = 方形（系统 width_center 32；高度不变只变宽——
/// 系统实证 item_height_center == item_height_normal == 32）。
const double _kImgWF = 32.0;

/// 普通项两侧半间隙 2.5（相邻普通项间隙 = 5）；聚焦项两侧半间隙 13.5
///（与邻居图间隙 = 13.5+2.5 = 16，系统 gap_center_horizontal）。
const double _kEdgeN = 2.5, _kEdgeF = 13.5;

/// 图片圆角 3（系统 item_drawable_radius；普通/聚焦统一，切换无跳变）。
const double _kRadius = 3.0;

/// 图片底距条底 2（系统 gap_normal_bottom == gap_center_bottom）。
const double _kGapBottom = 2.0;

/// 撑开/停稳修正时长（对标系统 animExpandCenter 400ms，略收紧）。
const Duration kFilmstripFocusDuration = Duration(milliseconds: 300);

/// 程序滑移参考时长（宿主与主图 animateToPage 对齐用；实际位移为弹簧
/// 物理驱动，时长随距离自适应）。
const Duration kFilmstripSyncDuration = Duration(milliseconds: 220);

/// 拖动开始时聚焦项缩回时长。
const Duration _kShrinkDuration = Duration(milliseconds: 180);

/// 程序滑移时长（对标系统 k() 的定时 400ms + 弹簧插值曲线；与宿主主图
/// animateToPage 220ms 同量级——弹簧物理尾部收敛过慢，曾致「主图已到位
/// 条还要等近 1s」，故定时）。
const Duration _kTravelDuration = Duration(milliseconds: 260);

/// fling 速度钳（逻辑 px/s；对标系统 ±12000 物理 px @3x 密度）。
const double _kMaxFlingVelocity = 4200.0;

/// 视口两侧多构建的缓冲（px）。
const double _kCullBuffer = 90.0;

// ─────────────── 组件 ───────────────

/// 缩略图条：见文件头行为契约。
class Filmstrip extends StatefulWidget {
  const Filmstrip({
    super.key,
    required this.itemCount,
    required this.initialIndex,
    required this.center,
    required this.thumbnail,
    this.onCenterChanged,
    this.onSettled,
    this.onTap,
    this.onItemBuild,
    this.frozen,
    this.deleteAnim,
    this.deleteIndex = -1,
    this.pagePos,
    this.pagerDriven,
  });

  final int itemCount;
  final int initialIndex;

  /// 居中项入向桥：外部写 = 程序滑移指令（组件不回写）。
  final ValueNotifier<int> center;

  /// 图源（96 方形档 provider，与网格 cell 共享 ImageCache）。
  final ImageProvider Function(int index) thumbnail;

  /// 用户滚动跨档（实时，宿主跟手联动主图）。
  final ValueChanged<int>? onCenterChanged;

  /// 停稳撑开完成 / 点按滑移到位（宿主 animateToPage 主图）。
  final ValueChanged<int>? onSettled;

  /// 点按单项。
  final ValueChanged<int>? onTap;

  /// 条目构建钩子（解码预取由宿主注入）。
  final void Function(BuildContext context, int index)? onItemBuild;

  /// 联动抑制（pop 冻结/删除流程）。
  final ValueNotifier<bool>? frozen;

  /// 删除补位动画（透传渲染：被删项原地淡出；后续项平移补位）。
  final Animation<double>? deleteAnim;

  /// 正在删除的条索引（-1 = 无）。
  final int deleteIndex;

  /// 主图翻页连续位置（PageController.page）：条静止时按 fraction 锁步
  /// 跟随（双项插值，对标系统 p()）。null = 不启用锁步。
  final ValueListenable<double>? pagePos;

  /// 主图正被条程序驱动（宿主 animateToPage 进行中）：锁步让位。
  final ValueListenable<bool>? pagerDriven;

  @override
  State<Filmstrip> createState() => _FilmstripState();
}

/// 阶段状态机（对标 ds70 的 contract state；单线程单写者，无竞态）。
enum _Phase {
  /// 静止：selection 聚焦居中（或锁步跟随主图 fraction）。
  idle,

  /// 用户手指在条上拖动。
  dragging,

  /// 松手后惯性减速（摩擦模拟，无吸附目标）。
  flinging,

  /// 停稳修正：中心最近项拉到中心 + 撑开（并行单补间）。
  settling,

  /// 程序滑移（外部指令/点按）：弹簧位移，到达后转 settling 撑开。
  traveling,
}

class _FilmstripState extends State<Filmstrip>
    with SingleTickerProviderStateMixin {
  // ── 几何状态（唯一真相；布局为其纯函数）──
  late int _sel; // selection（锚点项）
  double _selDx = 0; // selection 中心相对视口中心的偏移（px）

  /// 非零 focus fraction（通常 0~2 项；1 = 聚焦大样式）。
  final Map<int, double> _focus = {};

  _Phase _phase = _Phase.idle;

  // ── 时钟（Ticker 按需启停；跨重启保持单调连续）──
  late final Ticker _ticker;
  Duration _clockBase = Duration.zero; // 停表期累计值
  Duration _now = Duration.zero;

  bool get _clockRunning => _ticker.isActive;

  void _startClock() {
    if (!_clockRunning) _ticker.start();
  }

  void _stopClock() {
    if (_clockRunning) {
      _clockBase = _now;
      _ticker.stop();
    }
  }

  // ── 动画驱动 ──
  /// fling：x(t) 沿 |v| 单调递增，每帧取增量 × 方向作用到 _selDx。
  ClampingScrollSimulation? _flingSim;
  int _flingDir = 1;
  Duration _simT0 = Duration.zero;
  double _simX0 = 0;

  /// 程序滑移补间（定时；对标系统 k() 的「位移与变形并行」）：selDx→0
  /// 的同时旧项 f→0、目标项 f→1——运动中不保留旧聚焦大图。
  double _travelFromDx = 0;
  int _travelOld = -1;
  double _travelOldF0 = 0, _travelNewF0 = 0;

  /// selDx / focus 补间（settling 双补间 + dragging 缩回单补间）。
  Duration _twStart0 = Duration.zero;
  Duration _twDur = Duration.zero;
  double _twFromDx = 0;
  double _twFromF = 0, _twToF = 1;
  int _twFocusIdx = -1;

  /// 视口宽（LayoutBuilder 实测）。
  double _vw = 0;

  /// settling 完成是否上报 onSettled：只有用户手势停稳路径上报（外部
  /// 指令/点按/frozen 补焦的到位是宿主自己驱动的，上报会造成双报或
  /// 把程序动作误判成用户滚动——旧版「程序滚动全程静默」契约）。
  bool _reportSettle = false;

  /// 锁步残留标记：锁步写入过几何后置位，退出锁步时归一化清零。
  bool _lockstepDirty = false;

  @override
  void initState() {
    super.initState();
    _sel = widget.initialIndex.clamp(0, widget.itemCount - 1);
    _focus[_sel] = 1.0;
    widget.center.addListener(_onExternalCenter);
    widget.frozen?.addListener(_onFrozenChanged);
    widget.pagePos?.addListener(_onPagePos);
    widget.pagerDriven?.addListener(_onPagePos);
    _ticker = createTicker(_onTick);
  }

  @override
  void didUpdateWidget(Filmstrip old) {
    super.didUpdateWidget(old);
    if (old.center != widget.center) {
      old.center.removeListener(_onExternalCenter);
      widget.center.addListener(_onExternalCenter);
    }
    if (old.frozen != widget.frozen) {
      old.frozen?.removeListener(_onFrozenChanged);
      widget.frozen?.addListener(_onFrozenChanged);
    }
    if (old.pagePos != widget.pagePos ||
        old.pagerDriven != widget.pagerDriven) {
      old.pagePos?.removeListener(_onPagePos);
      old.pagerDriven?.removeListener(_onPagePos);
      widget.pagePos?.addListener(_onPagePos);
      widget.pagerDriven?.addListener(_onPagePos);
    }
    // 数据收缩（删除流程 removeAt 后）：对齐外部 center、几何归零位。
    // focus 清为 0（下一项此刻是小图——补位动画终态）；frozen 解除时
    // 由 _onFrozenChanged 补撑开。
    if (old.itemCount != widget.itemCount) {
      _cancelAnims();
      _phase = _Phase.idle;
      _sel = widget.center.value.clamp(0, widget.itemCount - 1);
      _selDx = 0;
      _focus
        ..clear()
        ..[_sel] = 0.0;
      _stopClock();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    widget.pagePos?.removeListener(_onPagePos);
    widget.pagerDriven?.removeListener(_onPagePos);
    widget.frozen?.removeListener(_onFrozenChanged);
    widget.center.removeListener(_onExternalCenter);
    super.dispose();
  }

  bool get _isFrozen => widget.frozen?.value ?? false;

  // ─────────────── 几何（纯函数，对标 ThumbLineLayoutManager 步距） ───────────────

  /// focus fraction f ∈ [0,1] 的项宽 / 半间隙（高度恒定 32——系统实证
  /// 聚焦只变宽不变高，动画即纯水平撑开/缩回）。
  double _wOf(double f) => _kImgWN + (_kImgWF - _kImgWN) * f;
  double _edgeOf(double f) => _kEdgeN + (_kEdgeF - _kEdgeN) * f;

  /// 相邻两项中心步距 = w_a/2 + edge_a + edge_b + w_b/2。
  /// 普通对 28（间隙 5）；聚焦-普通对 43.5（间隙 16）；锁步插值对恒 43.5。
  double _step(double fa, double fb) =>
      _wOf(fa) / 2 + _edgeOf(fa) + _edgeOf(fb) + _wOf(fb) / 2;

  double _fOf(int i) => _focus[i] ?? 0.0;

  /// 从 a 到 b 的有符号中心距离（沿符号方向逐步累加；O(|b−a|)）。
  double _dist(int a, int b) {
    if (a == b) return 0;
    final asc = b > a;
    var d = 0.0;
    var j = a;
    while (j != b) {
      final nxt = asc ? j + 1 : j - 1;
      d += _step(_fOf(j), _fOf(nxt));
      j = nxt;
    }
    return asc ? d : -d;
  }

  /// 中心最近项（对标 LayoutManager.e() 的 findChildViewUnder(视口中心)；
  /// 这里是解析解：从 selection 沿 selDx 符号方向走，越过中心即止）。
  int _underCenter() {
    var best = _sel;
    var bestAbs = _selDx.abs();
    if (bestAbs < 1e-9) return best;
    final dir = _selDx > 0 ? -1 : 1; // 中心在 sel 的哪侧就往哪侧走
    var d = 0.0;
    var j = _sel;
    while (true) {
      final nxt = j + dir;
      if (nxt < 0 || nxt >= widget.itemCount) break;
      d += _step(_fOf(j), _fOf(nxt));
      // 沿 dir 走一步后的中心偏移 = selDx ∓ 步距（dir=−1 抵消正向偏移）。
      final abs = (_selDx + d * dir).abs();
      if (abs >= bestAbs) break; // 已越过中心：前一项更近
      bestAbs = abs;
      best = nxt;
      j = nxt;
    }
    return best;
  }

  /// _selDx 滚动域：[−dist(sel→末项), +dist(首项→sel)]——端点 = 首/末项
  /// 恰好居中（硬钳，对标 scrollHorizontallyBy 的端点钳制，无回弹）。
  double get _minDx => -_dist(_sel, widget.itemCount - 1);
  double get _maxDx => _dist(0, _sel);

  /// 可见条目 (index, dx)：dx = 项中心相对视口中心偏移；从 selection
  /// 向两侧展开到缓冲边界为止（O(视口)，与列表长度无关）。
  List<(int, double)> _visibleItems() {
    final n = widget.itemCount;
    final out = <(int, double)>[(_sel, _selDx)];
    var d = 0.0;
    for (var i = _sel + 1; i < n; i++) {
      d += _step(_fOf(i - 1), _fOf(i));
      final dx = _selDx + d;
      if (dx - _wOf(_fOf(i)) / 2 > _vw / 2 + _kCullBuffer) break;
      out.add((i, dx));
    }
    d = 0.0;
    for (var i = _sel - 1; i >= 0; i--) {
      d -= _step(_fOf(i), _fOf(i + 1));
      final dx = _selDx + d;
      if (dx + _wOf(_fOf(i)) / 2 < -_vw / 2 - _kCullBuffer) break;
      out.add((i, dx));
    }
    return out;
  }

  // ─────────────── 手势 ───────────────

  void _onDragStart() {
    if (_isFrozen) return;
    _cancelAnims();
    _phase = _Phase.dragging;
    // 拖动开始：聚焦项缩回（系统在首次跨档时弹簧缩回；提前到拖动开始
    // 观感更连续且语义等价——拖动中无聚焦项）。
    final f = _fOf(_sel);
    if (f > 0.01) {
      _twFocusIdx = _sel;
      _twFromF = f;
      _twToF = 0.0;
      _twDur = _kShrinkDuration;
      _twStart0 = _now;
      _startClock();
      setState(() {});
    }
  }

  void _onDragUpdate(double dx) {
    if (_isFrozen || _phase != _Phase.dragging) return;
    _shift(dx);
    setState(() {}); // 拖动跟手重绘（指针事件驱动，无 ticker 参与）
  }

  void _onDragEnd(double velocity) {
    if (_isFrozen) return;
    final v = velocity.clamp(-_kMaxFlingVelocity, _kMaxFlingVelocity);
    if (v.abs() < 50) {
      _settle();
    } else {
      _flingSim = ClampingScrollSimulation(position: 0, velocity: v.abs());
      _flingDir = v > 0 ? 1 : -1; // 内容位移方向 = 手势方向（拖动位移同号）
      _simT0 = _now;
      _simX0 = 0;
      _phase = _Phase.flinging;
      _startClock();
    }
  }

  /// 位移作用 + 端点钳制 + 选区跟随（拖动/甩动共用）。
  void _shift(double dx) {
    final nd = (_selDx + dx).clamp(_minDx, _maxDx);
    if (nd == _selDx) return;
    _selDx = nd;
    _updateSelectionToUnderCenter();
  }

  /// 选区换到中心最近项（锚点换基，布局不变）：跨档轻震 + 实时上报。
  void _updateSelectionToUnderCenter() {
    final u = _underCenter();
    if (u == _sel) return;
    _selDx += _dist(_sel, u); // 换基恒等式：各项屏幕位置不动
    _sel = u;
    HapticFeedback.selectionClick();
    widget.onCenterChanged?.call(u);
  }

  // ─────────────── 停稳 / 撑开 ───────────────

  /// 停稳修正（对标 animExpandCenter）：中心最近项拉到中心 + 撑开，
  /// 同一时间轴双补间（selDx→0 与 f→1）。用户手势停稳路径，完成上报
  /// onSettled。
  void _settle() {
    _cancelAnims();
    _reportSettle = true;
    final u = _underCenter();
    _sel = u;
    _phase = _Phase.settling;
    _twFromDx = _selDx;
    _twFocusIdx = _sel;
    _twFromF = _fOf(_sel);
    _twToF = 1.0;
    _twDur = kFilmstripFocusDuration;
    _twStart0 = _now;
    _startClock();
    setState(() {});
  }

  // ─────────────── 程序滑移（外部指令/点按） ───────────────

  void _onExternalCenter() {
    final g = widget.center.value;
    if (g == _sel &&
        _phase == _Phase.idle &&
        _fOf(g) >= 1.0 &&
        !_lockstepDirty) {
      return; // 已就位（回声/同位重写）
    }
    if (_isFrozen) return; // 删除流程：解除时统一对齐
    if (_lockstepActive) return; // 主图拖动中：pagePos 已锁步跟随
    if (_phase == _Phase.dragging || _phase == _Phase.flinging) {
      return; // 条自身手势进行中：忽略（对标 e() 静止门控）
    }
    if (_phase == _Phase.traveling && g == _sel) return; // 已在途中
    _travelTo(g);
  }

  /// 滑移到 g：近距弹簧（运动中无聚焦），远距（> 一屏）同帧落位。
  void _travelTo(int g) {
    g = g.clamp(0, widget.itemCount - 1);
    _cancelAnims();
    // 锚点换基（屏幕位置连续）：新 selDx = 旧值 + 有符号距离。
    final old = _sel;
    final nd = _selDx + _dist(old, g);
    _sel = g;
    if (nd.abs() > _vw) {
      // 跳格语义 = 同帧落位（系统 C() 的不可见分支）。
      _selDx = 0;
      _focus
        ..clear()
        ..[g] = 1.0;
      _phase = _Phase.idle;
      _stopClock();
      setState(() {});
      return;
    }
    _selDx = nd;
    _travelFromDx = nd;
    _travelOld = old;
    _travelOldF0 = _fOf(old);
    _travelNewF0 = _fOf(g);
    _twStart0 = _now;
    _twDur = _kTravelDuration;
    _phase = _Phase.traveling;
    _startClock();
    setState(() {});
  }

  /// frozen 解除（删除流程收尾）：对齐外部 center——同位只补撑开
  ///（删除补位后下一项已在中心但缺聚焦态），异位滑移过去。
  void _onFrozenChanged() {
    if (_isFrozen) {
      // 冻结瞬间必须断在途动画（fling 惯性 / settle 补间 / travel）：
      // pop 淡出 200ms 窗口内条若继续滚（frozen 只拦新输入不拦已起跑
      // 的自驱动画，真机实证「滚动中的残留」轻微闪烁）。几何停在当前
      // 值，phase 归 idle（onTick 的 idle 分支自动停表）。解除时由下方
      // 对齐逻辑补焦到位（删除流程同链路）。
      _cancelAnims();
      if (_phase != _Phase.idle) {
        _phase = _Phase.idle;
        setState(() {});
      }
      return;
    }
    final g = widget.center.value;
    if (g < 0 || g >= widget.itemCount) return;
    if (g == _sel) {
      if (_fOf(g) >= 1.0 && _selDx == 0) return;
      _reportSettle = false;
      _phase = _Phase.settling;
      _twFromDx = _selDx;
      _twFocusIdx = _sel;
      _twFromF = _fOf(_sel);
      _twToF = 1.0;
      _twDur = kFilmstripFocusDuration;
      _twStart0 = _now;
      _startClock();
      setState(() {});
    } else {
      _travelTo(g);
    }
  }

  // ─────────────── 点按 ───────────────

  void _handleTap(int i) {
    if (_isFrozen) return;
    if (i == _sel && _phase == _Phase.idle && _fOf(i) >= 1.0) return;
    // 先滑移再上报：上报同步链里宿主会写 center（外部指令），若先报
    // 后滑移，外部指令会先起一个 travel、这里再起第二个并覆盖缩回目标
    //（点按「前/后半条抖动」根因——双启动参数不一致）。先启动后，外部
    // 指令到达时命中「已在途中」守卫被忽略。
    _travelTo(i);
    widget.onTap?.call(i);
  }

  // ─────────────── 锁步（主图 fraction 跟随） ───────────────

  /// 锁步生效：pagePos 提供且 fraction 非整、条静止、主图非条程序驱动。
  bool get _lockstepActive {
    final pos = widget.pagePos?.value;
    if (pos == null) return false;
    if (widget.pagerDriven?.value ?? false) return false;
    if (_phase != _Phase.idle) return false;
    if (_isFrozen) return false;
    return (pos - pos.round()).abs() > 0.01;
  }

  void _onPagePos() {
    if (!mounted) return;
    if (_lockstepActive) {
      setState(() {}); // 布局是 pagePos 的纯函数，build 内重算
    } else if (_lockstepDirty && _phase == _Phase.idle && !_isFrozen) {
      // 锁步结束（fraction 归整/驱动方接管）：归一化到静止布局，
      // 清掉双项插值的 residue。
      setState(() {
        _lockstepDirty = false;
        final pos = widget.pagePos?.value;
        _sel = (pos == null ? _sel : pos.round())
            .clamp(0, widget.itemCount - 1);
        _selDx = 0;
        _focus
          ..clear()
          ..[_sel] = 1.0;
      });
    }
  }

  /// 锁步几何（对标 ds70.p）：出项 floor(p) 按 1−f 缩、入项 +1 按 f 长，
  /// 整体偏移 −step×f（插值对步距恒 35，见 _step 注释）。
  void _applyLockstep() {
    final p = widget.pagePos!.value;
    final floor = p.floor().clamp(0, widget.itemCount - 1);
    var frac = p - p.floor();
    if (floor == widget.itemCount - 1 && frac > 0) frac = 0; // 末项右侧无内容
    if (floor != _sel) {
    }
    _sel = floor;
    _selDx = -_step(1 - frac, frac) * frac;
    _focus
      ..clear()
      ..[floor] = 1 - frac;
    if (frac > 0 && floor + 1 < widget.itemCount) _focus[floor + 1] = frac;
    _lockstepDirty = true;
  }

  // ─────────────── 时钟推进 ───────────────

  void _onTick(Duration elapsed) {
    // Ticker 重启后 elapsed 归零：叠加停表期累计保持时钟单调。
    _now = _clockBase + elapsed;
    if (!mounted) return;
    switch (_phase) {
      case _Phase.idle:
        _stopClock(); // 无事可推（锁步由监听器驱动）
      case _Phase.dragging:
        // 只推进缩回补间；完成即停表（拖动本身由指针事件驱动）。
        if (_twDur != Duration.zero) {
          _advanceTween();
        } else {
          _stopClock();
        }
      case _Phase.flinging:
        final sim = _flingSim;
        if (sim == null) {
          _settle();
          return;
        }
        final t = (_now - _simT0).inMicroseconds / 1e6;
        final x = sim.x(t);
        _shift(_flingDir * (x - _simX0));
        _simX0 = x;
        final hitEdge = (_flingDir < 0 && _selDx <= _minDx + 0.5) ||
            (_flingDir > 0 && _selDx >= _maxDx - 0.5);
        if (sim.isDone(t) || hitEdge) {
          _flingSim = null;
          _settle();
        } else {
          setState(() {});
        }
      case _Phase.settling:
        _advanceTween();
      case _Phase.traveling:
        final p = _tweenProgress();
        final eased = Curves.easeOutCubic.transform(p);
        _selDx = _travelFromDx * (1 - eased);
        final fe = Curves.easeOut.transform(p);
        if (_travelOld >= 0 && _travelOld != _sel) {
          _focus[_travelOld] = _travelOldF0 * (1 - fe); // 旧项同步缩回
        }
        _focus[_sel] = _travelNewF0 + (1 - _travelNewF0) * fe; // 新项同步长大
        if (p >= 1.0) {
          _selDx = 0;
          _focus
            ..clear()
            ..[_sel] = 1.0;
          _phase = _Phase.idle;
          _twDur = Duration.zero;
          _stopClock();
          setState(() {});
          return;
        }
        setState(() {});
    }
  }

  /// 当前补间进度（0..1，按 [_twStart0]+[_twDur] 折算）。
  double _tweenProgress() => _twDur == Duration.zero
      ? 1.0
      : ((_now - _twStart0).inMicroseconds / _twDur.inMicroseconds)
          .clamp(0.0, 1.0);

  /// 补间推进：settling 双补间（selDx→0 与 f→1 同步）；dragging 只推
  /// focus（缩回）。settling 完成上报 onSettled 并停表。
  void _advanceTween() {
    final p = _tweenProgress();
    final eased = Curves.easeOut.transform(p);
    if (_phase == _Phase.settling) {
      _selDx = _twFromDx * (1 - Curves.easeOutCubic.transform(p));
      if (_twFocusIdx >= 0) {
        _focus[_twFocusIdx] = (_twFromF + (_twToF - _twFromF) * eased)
            .clamp(0.0, 1.0);
      }
    } else {
      if (_twFocusIdx >= 0) {
        _focus[_twFocusIdx] = (_twFromF + (_twToF - _twFromF) * eased)
            .clamp(0.0, 1.0);
      }
    }
    if (p >= 1.0) {
      if (_twFocusIdx >= 0 && _focus[_twFocusIdx]! <= 0.001) {
        _focus.remove(_twFocusIdx); // 缩回完成：清理零值
      }
      if (_phase == _Phase.settling) {
        _phase = _Phase.idle;
        _selDx = 0;
        _focus[_sel] = 1.0;
        _twDur = Duration.zero;
        _stopClock();
        setState(() {});
        if (_reportSettle) widget.onSettled?.call(_sel);
        return;
      }
      if (_phase == _Phase.dragging) {
        _twDur = Duration.zero; // 缩回完成，拖动继续（指针驱动）
      }
    }
    setState(() {});
  }

  void _cancelAnims() {
    _flingSim = null;
    _twDur = Duration.zero;
    _twFocusIdx = -1;
    _travelOld = -1;
  }

  // ─────────────── 渲染 ───────────────

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, cons) {
          _vw = cons.maxWidth;
          if (_lockstepActive) _applyLockstep();
          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    HorizontalDragGestureRecognizer
                  >(
                () => HorizontalDragGestureRecognizer(),
                (inst) {
                  inst.onStart = (_) => _onDragStart();
                  inst.onUpdate = (d) => _onDragUpdate(d.delta.dx);
                  inst.onEnd = (d) => _onDragEnd(d.velocity.pixelsPerSecond.dx);
                  inst.onCancel = () => _onDragEnd(0);
                },
              ),
            },
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final (i, dx) in _visibleItems()) _buildItem(i, dx),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 单项：宽度/透明度由 focus fraction 连续驱动（布局级变宽，高度
  /// 恒定——对标 PhotoCoordinateLayoutInfoManager 的 percent 插值与
  /// 系统「高度不变仅变宽」）。聚焦表现 = 变宽成方形 + 提亮，无边框。
  Widget _buildItem(int i, double dx) {
    widget.onItemBuild?.call(context, i);
    final f = _fOf(i).clamp(0.0, 1.0);
    final w = _wOf(f), h = _kImgHN;
    Widget item = Positioned(
      left: _vw / 2 + dx - w / 2,
      top: 0,
      width: w,
      height: kFilmstripHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _handleTap(i),
        child: Align(
          alignment: Alignment.bottomCenter,
          // 底基准 = 条底 2（系统 gap_bottom，普通/聚焦一致——高度恒定
          // 后垂直方向全程静止，动画纯水平）。
          child: Padding(
            padding: const EdgeInsets.only(bottom: _kGapBottom),
            child: Opacity(
              opacity: 0.5 + 0.5 * f,
              child: SizedBox(
                width: w,
                height: h,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(_kRadius),
                  child: Image(
                    image: widget.thumbnail(i),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    frameBuilder: (c, child, frame, wasSync) {
                      if (wasSync || frame != null) return child;
                      return Stack(
                        fit: StackFit.expand,
                        children: [ThumbnailPlaceHolder(), child],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 删除补位（透传渲染）：被删项保持当前样式原地淡出；其后项平移
    // 补位——紧邻项跨入聚焦格(43.5)平移多，其余平移一格(28)。
    final anim = widget.deleteAnim;
    if (anim != null && widget.deleteIndex >= 0) {
      if (i == widget.deleteIndex) {
        item = AnimatedBuilder(
          animation: anim,
          child: item,
          builder: (_, child) => Opacity(opacity: 1 - anim.value, child: child),
        );
      } else if (i > widget.deleteIndex) {
        final d = i == widget.deleteIndex + 1 ? _step(1.0, 0.0) : _step(0.0, 0.0);
        item = AnimatedBuilder(
          animation: anim,
          child: item,
          builder: (_, child) => Transform.translate(
            offset: Offset(-anim.value * d, 0),
            child: child,
          ),
        );
      }
    }
    return item;
  }
}
