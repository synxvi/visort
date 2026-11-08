import 'package:flutter/animation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

/// 【snap 弹簧最小微调档】原生 PageScrollPhysics spring 是 stiffness
/// 100 / ratio 1.1（过阻尼，尾巴慢）。110/1.05：比原生仅紧 5%/5%，
/// 主曲线与原生肉眼无差，只把尾巴稍收（130/1.0 档被用户判「太快」，
/// 2026-09-12）。
class SnapPageScrollPhysics extends PageScrollPhysics {
  const SnapPageScrollPhysics({super.parent});

  static final SpringDescription snapSpring =
      SpringDescription.withDampingRatio(
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
/// 翻页落位）一律换成本组件的 spring 自驱（[SnapPageScrollPhysics.snapSpring]
/// + 显式 physics 容差）。
///
/// **Why 全接管**：原生 ballistic 期间 Scrollable 会 IgnorePointer 整个
/// 视口（`ScrollPosition.shouldIgnorePointer` → `setIgnorePointer`）——
/// 动画中按住图片收不到事件 =「翻页动画没停稳前上滑看信息不生效 /
/// 反向平移无响应」。Jump/Idle activity 不屏蔽指针——自驱动画全程子树
/// 可交互。
///
/// **写入架构（勿回退到 jumpTo）**：SDK `jumpTo` 末尾无条件
/// `goBallistic(0.0)`——位置不在整页时【自建一个弹回最近页的 0 速
/// 弹簧】。逐帧 jumpTo = 每帧新生一个弹回动画与自驱对撞 =「闪烁/乱跳/
/// 瞬移」的总根源（[SPR] collide type=Ballistic 实证 2026-09-12）。
/// 正确入口是 `beginActivity(Idle)`（换 activity 不带副作用）+
/// `setPixels`（与 Flutter 内部 BallisticScrollActivity.applyMoveTo
/// 同款写入语义）。两者均 protected（自驱动画的正当需求，警告压制）。
///
/// **速度判定勿删**：接管目标必须复刻 `PageScrollPhysics._getTargetPixels`
/// 的目标页选择（velocity 过 tolerance → page±0.5 再 round）——只看
/// 位置会把快甩的弹射误判成「弹回当前页」→ 吞掉快甩翻页。速度读第二帧
/// 的 `BallisticScrollActivity.velocity`（首帧恒 0、事件时间戳测试环境
/// 失效，均不可用）。初速【不续接】：速度只决定去哪页（resampling 时代
/// 原生从未有高初速弹射，全速续接 = 一页被推完的瞬移感）。
///
/// **速度通道重建（resampling 亡羊补牢）**：Android 引擎 resampling 后
/// move 大多为 synthesized，Scrollable 的 velocity tracker 只吃
/// `!synthesized` → 松手 velocity 恒 0 → 翻页只剩纯位置通道（50% 硬
/// 断点）＝轻扫必弹回。本组件 Listener 层自估速度（含 synthesized——
/// 合成事件是唯一完整轨迹），physics 判回当前页而自估速度朝邻页过阈值
/// → 翻过去。放大态（flingTakeOver=false）关闭：贴边外拖是精细操作，
/// 手指速度天然超阈值，会误判成轻扫强制翻页。
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

  /// 速度通道（轻扫翻页）开关。放大态必须关（见 class doc）。
  final bool flingTakeOver;

  @override
  State<PageSettleTakeOver> createState() => _PageSettleTakeOverState();
}

class _PageSettleTakeOverState extends State<PageSettleTakeOver>
    with TickerProviderStateMixin {
  /// 自积分 Ticker：AnimationController 的 Ticker elapsed 在 stop/start
  /// 复用后携带进程级历史（[SPR] t=408s 实证 → 弹簧瞬间收敛 = 瞬移）；
  /// Ticker 回调 elapsed 自本次 start 起算，与历史无关。
  Ticker? _springTicker;
  double _springTarget = 0;

  VelocityTracker? _tracker;

  /// spring 被按下中断的标记（2026-09-13 审查 P2）：中断后若本指针序列是
  /// 纯点击（无 move 样本 → drag recognizer 未参战、tap 赢 arena，原生不
  /// 产生 ballistic），_scheduleTakeOver 两拍守卫不通过 = 页面停在两页之间
  /// 无任何恢复路径——up/cancel 时就地起回最近页的弹簧补上这条路。
  bool _springInterrupted = false;

  /// 回最近页恢复（审查 P2）：spring 中断后无 ballistic 兜底的序列终点。
  void _recoverToNearestPage() {
    if (!mounted || !widget.enabled) return;
    final ctrl = widget.controller;
    if (!ctrl.hasClients) return;
    final pos = ctrl.position;
    final vp = pos.viewportDimension;
    if (vp <= 0) return;
    var page = (pos.pixels / vp).roundToDouble();
    final maxPage = pos.maxScrollExtent / vp;
    if (page < 0) page = 0;
    if (page > maxPage) page = maxPage;
    if ((page * vp - pos.pixels).abs() >= 0.5) {
      _springTo(page * vp);
    }
  }

  /// 抬手速度（goBallistic 语义：-dx），含 synthesized 的完整轨迹估计
  /// ——physics 速度通道（只吃非合成事件）失效时的替代源。
  double _dragVelocity = 0;

  /// 轻扫翻页阈值（px/s）：kMinFlingVelocity(175) 上方留余量防误翻。
  static const double _kFlingTakeOver = 250;

  /// 活动是否为松手后的 ballistic（接管前提；drag/hold/idle 均不是）。
  /// activity 是 protected（自驱动画的正当需求，警告压制）。
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
    final vp = pos.viewportDimension;
    var page = pos.pixels / vp;
    page += v > 0 ? 0.5 : -0.5;
    // 朝回弹（朝当前页）时目标==当前页 → physics 在弹回（我们接管）。
    if (page.roundToDouble() == (pos.pixels / vp).roundToDouble()) {
      return null;
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
      // ⚠️ 守卫必须是 activity 类型级：isScrollingNotifier 对用户 drag
      // 同样为 true——只查它会把「两拍窗口内的新拖动」误判成可接管 →
      // spring 抢走 drag 锁死页面（[TSO] 实证）。只有 Ballistic（松手后
      // 的无人动画）才允许接管。
      if (!_isBallistic(pos)) return;
      // postFrame 第二拍：ballistic 已 tick 一帧，velocity 可读。
      WidgetsBinding.instance.addPostFrameCallback((__) {
        if (!mounted || !widget.enabled) return;
        if (!ctrl.hasClients) return;
        final pos2 = ctrl.position;
        if (!_isBallistic(pos2)) return; // 两拍间用户已 down：交还
        final vp = pos2.viewportDimension;
        if (vp <= 0) return;
        final fling = _ballisticInfo(pos2);
        final settlePage = (pos2.pixels / vp).roundToDouble();
        final maxPage = pos2.maxScrollExtent / vp;
        var targetPage = settlePage;
        if (fling != null) {
          // physics 去邻页：同目标接管（保可交互）。初速不续接（见
          // class doc——速度只决定去哪页）。
          targetPage = fling.velocity > 0 ? settlePage + 1 : settlePage - 1;
        } else if (widget.flingTakeOver) {
          // 速度通道：physics 判回当前页（其 velocity 被 resampling 饿死），
          // 自估速度过阈值 → 翻邻页（轻扫语义）。
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
        _springTo(targetPage * vp);
      });
    });
  }

  /// spring 自驱到目标像素（零初速：弹簧从当前位置从容拉过去）。
  void _springTo(double target) {
    final ctrl = widget.controller;
    // 无 clients 早退（2026-09-13 审查 P3）：旧写法 from 有 hasClients 兜底
    // 分支，但后续仍裸取 ctrl.position → 兜底形同虚设（StateError）。
    if (!ctrl.hasClients) return;
    final from = ctrl.position.pixels;
    final sim = ScrollSpringSimulation(
      SnapPageScrollPhysics.snapSpring,
      from,
      target,
      0,
      // ⚠️ tolerance 必须显式：默认 Tolerance()（0.001）让 isDone 永不
      // true → Ticker 永生 → 与后续动画逐帧互写（「乱跳后落位」实证）。
      tolerance: ctrl.hasClients
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          ? ctrl.position.physics.toleranceFor(ctrl.position)
          : const Tolerance(velocity: 800, distance: 0.5),
    );
    _springTarget = target;
    // beginActivity 换 activity（解除 IgnorePointer）；jumpTo 会
    // goBallistic(0) 自建弹回弹簧（见 class doc 写入架构段）。
    // _FreeScrollActivity：isScrolling=true 满足 setPixels 断言 +
    // shouldIgnorePointer=false 保动画中可交互。
    final dynamic dynPos = ctrl.position; // 运行时 implements delegate
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    dynPos.beginActivity(
        _FreeScrollActivity(dynPos as ScrollActivityDelegate));
    _stopSpring();
    _springTicker = createTicker((Duration elapsed) {
      final dt = elapsed.inMicroseconds / 1e6;
      if (!ctrl.hasClients) {
        _stopSpring();
        return;
      }
      // 【pop 冻结自停】（2026-09-14 审查 P2）：无指针 pop（返回键/手势导
      // 航）走 detail 的 beginActivity(IdleScrollActivity)——不落进下方
      // Ballistic/Driven 对撞表，弹簧继续 setPixels 会撞 SDK
      // assert(activity!.isScrolling)（debug 红屏）并在 pop 淡出中续写像
      // 素（release 下 sel/页错位、Hero flight 降级）。enabled 含 !_popping
      // ——冻结即自停，pop 场景像素冻结优先。
      if (!widget.enabled) {
        _stopSpring();
        return;
      }
      // 【对撞防御】activity 已被其它动画/手势接管 → spring 让位自停，杜绝
      // 互写。三类让位源：Ballistic（原生 fling）/ Driven（条驱动
      // animateToPage）/ **Idle（2026-09-15 闪图根因修复）**——
      // jumpToPage（条轻扫跟手硬跳，detail _onThumbCenterChanged）落地后
      // activity 恒为 Idle：旧表只认前两种，弹簧不知被跳页打断、ticker
      // 继续朝旧 target setPixels = 主图「新页↔旧 target 页」每档来回闪
      // （真机 probe.log 实证：cross i=N→opc N→2ms 后 opc idx=旧页+sel 被
      // onPageChanged 写回旧页，pick/attach 涟漪齐发，弹簧 sim 收敛 ~300ms
      // 后自愈）。自无误伤：弹簧运行期 activity 是自设的 _FreeScrollActivity
      // （非 Idle），收敛终点归位 Idle 发生在 _stopSpring 之后同帧。
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      final act = ctrl.position.activity;
      if (act is BallisticScrollActivity ||
          act is DrivenScrollActivity ||
          act is IdleScrollActivity) {
        _stopSpring();
        return;
      }
      final x = sim.x(dt);
      // 【收敛判定用距离不用 isDone】：速度容差在过阻尼尾巴要 1s+ 才
      // 满足 → Ticker 永生；距离 0.5px 视觉无差且 ~300ms 必达。
      if ((x - _springTarget).abs() < 0.5) {
        _writePixels(_springTarget);
        _stopSpring();
        // 归位 Idle（静止语义；setPixels 断言只在写入瞬间要求 scrolling）。
        final dynamic dynPos = ctrl.position;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        dynPos.beginActivity(IdleScrollActivity(dynPos as ScrollActivityDelegate));
        return;
      }
      _writePixels(x);
    })
      ..start();
  }

  void _stopSpring() {
    _springTicker?.stop();
    _springTicker?.dispose();
    _springTicker = null;
  }

  /// 逐帧位置写入（与 Flutter 内部 BallisticScrollActivity.applyMoveTo
  /// 同款 setPixels 语义：含 boundary 修正 + listener 通知；jumpTo 的
  /// goBallistic(0) 副作用见 class doc）。setPixels protected——自驱
  /// 动画的正当入口，警告压制。
  void _writePixels(double value) {
    final ctrl = widget.controller;
    if (!ctrl.hasClients) return;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    ctrl.position.setPixels(value);
  }

  /// 按住处理：spring 动画中 → 立即停（停在当前位置交给用户——子树
  /// 可交互，上滑详情/反向拖/翻页立即生效）。原生 ballistic 还在的极限
  /// 场景（用户快于第二拍）→ 立即杀掉解屏蔽：本 down 序列的 hit test
  /// 已错过子树，下个手势起完全恢复。
  void _onDown(PointerDownEvent _) {
    _tracker = null; // 新指针序列：速度基线重置
    if (_springTicker != null) _springInterrupted = true;
    _stopSpring();
    final ctrl = widget.controller;
    if (ctrl.hasClients && _isBallistic(ctrl.position)) {
      final dynamic dynPos = ctrl.position;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      dynPos.beginActivity(IdleScrollActivity(dynPos as ScrollActivityDelegate));
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
      // 速度采样【含 synthesized】（与 Scrollable tracker 取舍相反）：
      // resampling 下合成 move 是唯一完整轨迹，滤掉即饿死速度通道。
      onPointerMove: (e) {
        _tracker ??= VelocityTracker.withKind(e.kind);
        _tracker!.addPosition(e.timeStamp, e.position);
      },
      onPointerUp: (e) {
        final hadMoves = _tracker != null;
        final v = _tracker?.getVelocity().pixelsPerSecond;
        _tracker = null;
        // 主导轴过滤：垂直手势（上滑面板/下滑关闭）松手动量含水平抖动/
        // 回勾，只看 dx 会把垂直意图劫持成水平轻扫（「上滑面板多翻一页/
        // 回前一页」实证）。dy 主导时速度通道静默。
        final dx = v?.dx ?? 0.0;
        final dy = v?.dy ?? 0.0;
        _dragVelocity = dy.abs() <= dx.abs() ? -dx : 0.0;
        _scheduleTakeOver();
        // 【中断恢复】（审查 P2）：spring 期间按下且本序列纯点击——drag
        // recognizer 被 reject 无 ballistic，上面两拍守卫必然不通过，就地
        // 回最近页。拖动过的序列交还原生 ballistic 链（takeOver 正常接管）。
        final wasInterrupted = _springInterrupted;
        _springInterrupted = false;
        if (wasInterrupted && !hadMoves) _recoverToNearestPage();
      },
      onPointerCancel: (_) {
        _tracker = null;
        _dragVelocity = 0;
        // 系统打断（通知栏下拉等）：无后续事件也无 ballistic，spring 在跑
        // 或被中断过都同样回最近页（旧链 _stopSpring 后悬停两页间同族缺陷）。
        final wasSpringing = _springTicker != null || _springInterrupted;
        _springInterrupted = false;
        _stopSpring();
        if (wasSpringing) _recoverToNearestPage();
      },
      child: widget.child,
    );
  }
}

class _BallisticInfo {
  const _BallisticInfo({required this.velocity});
  final double velocity;
}

/// 自由活动：isScrolling=true（setPixels 的断言要求）但
/// shouldIgnorePointer=false（动画中子树可交互——本组件的存在意义）。
class _FreeScrollActivity extends ScrollActivity {
  _FreeScrollActivity(super.delegate);

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => 0.0;
}
