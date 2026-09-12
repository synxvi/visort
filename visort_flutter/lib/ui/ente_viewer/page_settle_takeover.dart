import 'package:flutter/animation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

/// 【snap 弹簧最小微调档】原生 PageScrollPhysics spring 是 stiffness
/// 100 / ratio 1.1（过阻尼，尾巴慢）。130/1.0 档被用户判「太快」
///（2026-09-12）——最小微调档 110/1.05：比原生仅紧 5%/5%，主曲线与
/// 原生肉眼无差，只把尾巴稍收。仍快则回纯原生 100/1.1。
class SnapPageScrollPhysics extends PageScrollPhysics {
  const SnapPageScrollPhysics({super.parent});

  static final SpringDescription snapSpring = SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 110.0,
    ratio: 1.05,
  );

  @override
  SnapPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SnapPageScrollPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => snapSpring;
}

/// 页内回弹 + 跨页 snap 的全接管：松手后的 PageView 动画（无论回弹还是
/// 翻页落位）一律换成本组件的 spring 自驱 jumpTo。
///
/// **Why 全接管**：原生 ballistic 期间 Scrollable 会 IgnorePointer 整个
/// 视口（`ScrollPosition.shouldIgnorePointer` → `setIgnorePointer`）——
/// 动画中按住图片收不到事件 =「翻页动画没停稳前上滑看信息不生效 /
/// 反向平移无响应」（真机体感实证 2026-09-12）。逐帧 jumpTo（Jump/Idle
/// activity 不屏蔽指针）驱动的动画全程子树可交互：上滑详情立即生效、
/// 反向拖立即平移/翻页（recognizer 在 down 时刻正常参与 arena）。
///
/// **速度判定勿删**：接管目标必须复刻 `PageScrollPhysics._getTargetPixels`
/// 的目标页选择（page_view.dart：velocity 过 tolerance → page±0.5 再
/// round）——只看位置（round(frac)=当前页）会把快甩的弹射误判成「弹回
/// 当前页」→ 弹回 = 吞掉用户的快甩翻页（「拉三四次才翻过去」真机实证
/// 2026-09-12）。速度读第二帧的
/// `BallisticScrollActivity.velocity`（AnimationController 的
/// simulation.dx(elapsed)）——第一帧恒 0（Ticker 未 tick）、事件时间戳在
/// 测试环境失效，都不可用。
///
/// **速度通道重建（resampling 亡羊补牢）**：Android 引擎 resampling 开启
/// 后 move 大多为 synthesized，而 Scrollable 的 velocity tracker 只吃
/// `!synthesized`（monodrag.dart:656）→ 零样本 → 松手 velocity 恒 0 →
/// PageView 翻页只剩纯位置通道（50% 硬断点）＝轻扫（拖 30-60px 快速
/// 抬手）必弹回（「露出一点下一张的边缘瞬间弹回」真机日志实证
/// 2026-09-12：ballistic 起步即朝当前页回）。本组件在 Listener 层用
/// 含 synthesized 的完整轨迹自估速度，physics 判回当前页而速度朝邻页
/// 过阈值时，自驱翻过去。
///
/// **动画曲线**：统一 spring 自驱（[SnapPageScrollPhysics.snapSpring]，
/// 续接 physics 初速保证连贯）——原生 snap 的弹簧手感保留且尾巴更短；
/// DrivenScrollActivity/animateToPage 的 shouldIgnorePointer=true 不可用。
class PageSettleTakeOver extends StatefulWidget {
  const PageSettleTakeOver({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
    this.flingTakeOver = true,
  });

  final PageController controller;
  final Widget child;

  /// pop 冻结 / 手势锁定等场景关闭接管（动画交还原生）。
  final bool enabled;

  /// 速度通道（轻扫翻页）开关。放大态必须关：贴边外拖是【精细操作】
  /// ——手指速度天然超阈值（自然拖动 300-800px/s 常见），位移却小
  /// （图片贴边不动，PageView 接管前位移全被吃）→ 速度通道会把
  /// 「贴边轻拖松手」误判成轻扫强制翻页（真机实证 2026-09-12
  /// 「轻微平移一点就立马翻页」）。放大态翻页只认位置通道（拖过半
  /// 页）或大位移快甩（physics 位置通道过断点）。
  final bool flingTakeOver;

  @override
  State<PageSettleTakeOver> createState() => _PageSettleTakeOverState();
}

class _PageSettleTakeOverState extends State<PageSettleTakeOver>
    with TickerProviderStateMixin {
  /// 自积分 Ticker 驱动弹簧：AnimationController.unbounded+animateWith 的
  /// Ticker elapsed 在 stop/start 复用后可能携带进程级历史（真机+测试
  /// 双实证 [SPR] t=408s → 弹簧被瞬间推到收敛终点 =「翻页瞬移」的根，
  /// 2026-09-12）。Ticker 回调的 elapsed 自本次 start 起算，与历史无关。
  Ticker? _springTicker;

  VelocityTracker? _tracker;
  /// 抬手速度（goBallistic 语义：-dx，主轴正向为正），含 synthesized
  /// 事件的完整轨迹估计——physics 的速度通道（tracker 只吃非合成事件）
  /// 失效时的替代源。
  double _dragVelocity = 0;

  /// 轻扫翻页阈值（px/s）：physics 判回当前页但速度朝邻页过此值时，
  /// 速度通道接管翻页。kMinFlingVelocity(175) 上方留余量防误翻。
  static const double _kFlingTakeOver = 250;

  /// spring 自驱到目标像素（续接 velocity 保连贯）。
  void _springTo(double target, double velocity) {
    final ctrl = widget.controller;
    final from = ctrl.hasClients ? ctrl.position.pixels : target;
    final sim = ScrollSpringSimulation(
      SnapPageScrollPhysics.snapSpring,
      from,
      target,
      velocity.clamp(-6000, 6000),
    );
    // 同值 jumpTo：把 ballistic 换成 Idle（解除 IgnorePointer），再起自驱。
    ctrl.jumpTo(from);
    _stopSpring();
    _springTicker = createTicker((Duration elapsed) {
      // Ticker.elapsed 自 start() 起算（首 tick 即首帧时长），直接当 dt。
      final dt = elapsed.inMicroseconds / 1e6;
      if (!ctrl.hasClients) return;
      if (sim.isDone(dt)) {
        ctrl.jumpTo(target);
        _stopSpring();
        return;
      }
      ctrl.jumpTo(sim.x(dt));
    })
      ..start();
  }

  void _stopSpring() {
    _springTicker?.stop();
    _springTicker?.dispose();
    _springTicker = null;
  }

  /// 活动是否为松手后的 ballistic（接管前提）。drag/hold/idle 均不是。
  /// activity 是 protected（release 可用，警告 ignore 压制）。
  bool _isBallistic(ScrollPosition pos) {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    return pos.activity is BallisticScrollActivity;
  }

  _BallisticInfo? _ballisticInfo(ScrollPosition pos) {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final activity = pos.activity;
    if (activity is! BallisticScrollActivity) return null;
    final v = activity.velocity;
    final tol = pos.physics.toleranceFor(pos).velocity;
    if (v.abs() <= tol) return null; // v≈0：physics 走纯位置通道
    var page = pos.pixels / pos.viewportDimension;
    page += v > 0 ? 0.5 : -0.5;
    // Dart 的 round(-0.4)==(-0.0)==0.0：朝回弹（朝当前页）时目标==当前页。
    if (page.roundToDouble() ==
        (pos.pixels / pos.viewportDimension).roundToDouble()) {
      return null; // physics 弹回当前页（我们接管，速度通道再判）
    }
    return _BallisticInfo(velocity: v);
  }

  void _scheduleTakeOver() {
    // postFrame 第一拍：等 PageView 自身 ballistic 启动（drag.end →
    // goBallistic 同帧晚于本 up）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled) return;
      final ctrl = widget.controller;
      if (!ctrl.hasClients) return;
      final pos = ctrl.position;
      // ⚠️ 守卫必须是 activity 类型级：isScrollingNotifier 对
      // DragScrollActivity（用户 drag 进行中）同样为 true——只查它会把
      // 「两拍窗口内用户开始新拖动」误判成 ballistic 在跑 → springTo
      // 抢走 drag 锁死页面（[TSO] 实证 drag 中被 tick x=0 逐帧拉回）。
      // 只有 Ballistic（松手后的无人动画）才允许接管。
      if (!_isBallistic(pos)) return;
      // postFrame 第二拍：ballistic 已 tick 一帧，velocity 可读。
      WidgetsBinding.instance.addPostFrameCallback((__) {
        if (!mounted || !widget.enabled) return;
        if (!ctrl.hasClients) return;
        final pos2 = ctrl.position;
        if (!_isBallistic(pos2)) return; // 第一拍到第二拍间用户已 down/拖动：交还
        final vp = pos2.viewportDimension;
        if (vp <= 0) return;
        // physics 自己去邻页（速度有效）：同目标同初速【自驱接管】——
        // 自驱 spring 与原生 ballistic 是同一数学（同参数同初速同目标，
        // 逐帧写同一位置函数）= 观感原味；差别仅在 jumpTo 的 activity 不
        // 屏蔽指针：动画中上滑可达、down 停走不抖（交还原生时 down 抢救
        // 会杀动画在半路 =「抖一下 + 上滑失败 + 弹回错页」三症状的根，
        // 真机实证 2026-09-12）。
        final fling = _ballisticInfo(pos2);
        final settlePage = (pos2.pixels / vp).roundToDouble();
        final maxPage = pos2.maxScrollExtent / vp;
        var targetPage = settlePage;
        var velocity = 0.0;
        if (fling != null) {
          targetPage = fling.velocity > 0 ? settlePage + 1 : settlePage - 1;
          // 初速不续接：resampling 时代原生从未有过高初速弹射（tracker
          // 饿死恒 0），用户始终体验「低速 + 弹簧拉过去」的翻页节奏；
          // 速度通道重建后全速续接第一次让 1000-6000px/s 生效 = 一页
          // 被初速推完 =「瞬移感」（真机实证 2026-09-12 连续两轮）。
          // 速度只用于【决定去哪页】，动画由弹簧从当前位置从容拉过去。
        } else if (widget.flingTakeOver) {
          // 速度通道：physics 判回当前页（velocity 饿死），自估速度过阈
          // 值 → 翻邻页（轻扫语义）。同上：速度只决定目标页，不续接。
          if (_dragVelocity > _kFlingTakeOver) {
            targetPage = settlePage + 1;
          } else if (_dragVelocity < -_kFlingTakeOver) {
            targetPage = settlePage - 1;
          }
        }
        if (targetPage < 0 || targetPage > maxPage) {
          targetPage = settlePage; // 首/末页外甩：回最近页
        }
        if ((targetPage * vp - pos2.pixels).abs() < 0.5) return;
        _springTo(targetPage * vp, velocity);
      });
    });
  }

  /// 按住处理：接管动画中 → 立即停（spring 停在当前位置交给用户——
  /// 子树可交互，上滑详情/反向拖/翻页立即生效）。用户快于第二拍的
  /// 极限场景（原生 ballistic 还在）→ 立即杀掉解屏蔽：本 down 序列的
  /// hit test 已错过子树（拖动归 PageView/外层），下个手势起完全恢复
  /// ——比锁死到动画结束（原生行为）好。
  void _onDown(PointerDownEvent _) {
    _tracker = null; // 新指针序列：速度基线重置
    _stopSpring();
    final ctrl = widget.controller;
    if (ctrl.hasClients && _isBallistic(ctrl.position)) {
      ctrl.jumpTo(ctrl.position.pixels);
    }
  }

  @override
  void dispose() {
    _stopSpring();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listener 在 PageView 外层，不受其 IgnorePointer 影响。
    return Listener(
      onPointerDown: _onDown,
      // 速度采样【含 synthesized】（与 Scrollable tracker 的取舍相反）：
      // resampling 场景下合成 move 是唯一完整轨迹，滤掉即饿死速度
      // 通道（physics 的教训）。合成事件的时间戳同样单调推进，拟合
      // 可靠。
      onPointerMove: (e) {
        _tracker ??= VelocityTracker.withKind(e.kind);
        _tracker!.addPosition(e.timeStamp, e.position);
      },
      onPointerUp: (e) {
        final v = _tracker?.getVelocity().pixelsPerSecond;
        _tracker = null;
        // 主导轴过滤：垂直手势（上滑面板/下滑关闭）的松手动量含水平
        // 抖动/回勾（250+px/s 常见），只看 dx 会把垂直意图劫持成水平
        // 轻扫 =「上滑面板多翻一页/回前一页」（真机实证 2026-09-12）。
        // dy 主导时速度通道静默（垂直语义归 zoomable 外层，与本组件
        // 无关）。
        final dx = v?.dx ?? 0.0;
        final dy = v?.dy ?? 0.0;
        _dragVelocity = dy.abs() <= dx.abs() ? -dx : 0.0;
        _scheduleTakeOver();
      },
      onPointerCancel: (_) {
        _tracker = null;
        _dragVelocity = 0;
        _stopSpring();
      },
      child: widget.child,
    );
  }
}

class _BallisticInfo {
  const _BallisticInfo({required this.velocity});
  final double velocity;
}
