import 'package:flutter/animation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 页内回弹接管：把「无速度意图的弹回」从 PageView 原生 ballistic 换成
/// 自驱动 jumpTo 回弹。
///
/// **Why**：原生 ballistic（in-bounds）期间 Scrollable 会 IgnorePointer 整个
/// 视口（ScrollPosition.shouldIgnorePointer → Scrollable.setIgnorePointer），
/// 弹回动画中按住图片收不到任何事件 =「必须等翻页动画完全停稳才能反向
/// 平移」（真机体感实证 2026-09-12）。Jump/Idle activity 的
/// shouldIgnorePointer=false——逐帧 jumpTo 驱动的回弹全程子树可交互：
/// 反向拖立即平移图片、朝外拖贴边让位翻页（recognizer/PageView drag 在
/// down 时刻正常参与 arena）。
///
/// **速度判定勿删**：接管必须复刻 PageScrollPhysics._getTargetPixels 的
/// 目标页选择（page_view.dart：velocity 过 tolerance → page±0.5 再 round）
/// ——只看位置（round(frac)=当前页）会把快甩的弹射误判成「弹回当前页」
/// → 杀掉弹射弹回 = 吞掉用户的快甩翻页（「拉三四次才翻过去」真机实证
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
/// 过阈值时，自驱 jumpTo 翻过去（DrivenScrollActivity/animateToPage 的
/// shouldIgnorePointer=true 不可用，同走 jumpTo 保全交互）。
///
/// 跨页 snap（过半页断点/快甩弹射）不接管，保持 PageView 原生弹簧手感。
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

  /// pop 冻结 / 手势锁定等场景关闭接管（回弹交还原生）。
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(_onTick);
  double _from = 0;
  double _to = 0;

  VelocityTracker? _tracker;
  /// 抬手速度（goBallistic 语义：-dx，主轴正向为正），含 synthesized
  /// 事件的完整轨迹估计——physics 的速度通道（tracker 只吃非合成事件）
  /// 失效时的替代源。
  double _dragVelocity = 0;

  /// 轻扫翻页阈值（px/s）：physics 判回当前页但自估速度朝邻页过此值
  /// 时，速度通道接管翻页。kMinFlingVelocity(175) 上方留余量防误翻。
  static const double _kFlingTakeOver = 250;

  void _onTick() {
    final ctrl = widget.controller;
    if (!ctrl.hasClients) return;
    final t = Curves.easeOutCubic.transform(_ctl.value);
    ctrl.jumpTo(_from + (_to - _from) * t);
  }

  /// ballistic 朝邻页弹射判定（复刻 _getTargetPixels 的 ±0.5 偏移后
  /// 目标 ≠ 最近页）。速度用两拍间的 ballistic 位移方向：spring 初速大
  /// → 一帧位移明显（>0.5px）；v≈0 → 首帧位移≈0。不用
  /// `ScrollPosition.activity`（protected/visibleForTesting）也不用墙钟
  /// 差——位移只依赖 fake/真实时钟均单调推进的帧序。
  bool _flingingToNeighbor(ScrollPosition pos, double p0) {
    final vp = pos.viewportDimension;
    final d = pos.pixels - p0;
    if (d.abs() < 0.5) return false; // v≈0：physics 走纯位置通道
    var page = pos.pixels / vp;
    page += d > 0 ? 0.5 : -0.5;
    // Dart 的 round(-0.4)==(-0.0)==0.0：朝回弹（朝当前页）时目标==当前页。
    return page.roundToDouble() != (pos.pixels / vp).roundToDouble();
  }

  void _scheduleTakeOver() {
    // postFrame 第一拍：等 PageView 自身 ballistic 启动（drag.end →
    // goBallistic 同帧晚于本 up）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.enabled) return;
      final ctrl = widget.controller;
      if (!ctrl.hasClients) return;
      final pos = ctrl.position;
      if (!pos.isScrollingNotifier.value) return; // 无弹回（已 idle）
      final p0 = pos.pixels;
      // postFrame 第二拍：ballistic 已 tick，位移方向可判。
      WidgetsBinding.instance.addPostFrameCallback((__) {
        if (!mounted || !widget.enabled) return;
        if (!ctrl.hasClients) return;
        final pos2 = ctrl.position;
        if (!pos2.isScrollingNotifier.value) return;
        final vp = pos2.viewportDimension;
        if (vp <= 0) return;
        if (_flingingToNeighbor(pos2, p0)) return; // 弹射跨页：交还原生
        // 速度通道接管：physics 判回当前页（其 velocity 因 resampling 饿死
        // 恒 0），但完整轨迹速度朝邻页过阈值 → 自驱翻过去（轻扫语义）。
        // 放大态（flingTakeOver=false）禁用（见字段注释）。
        final settlePage = (pos2.pixels / vp).roundToDouble();
        var targetPage = settlePage;
        if (widget.flingTakeOver) {
          if (_dragVelocity > _kFlingTakeOver) {
            targetPage = settlePage + 1;
          } else if (_dragVelocity < -_kFlingTakeOver) {
            targetPage = settlePage - 1;
          }
        }
        // clamp 到合法页范围（首/末页外甩无邻页 = 正常弹回）。
        final maxPage = pos2.maxScrollExtent / vp;
        if (targetPage < 0 || targetPage > maxPage) targetPage = settlePage;
        _from = pos2.pixels;
        _to = targetPage * vp;
        if ((_from - _to).abs() < 0.5) return;
        // 同值 jumpTo 不动位置，仅把 activity 换成 Jump（解除指针屏蔽）。
        ctrl.jumpTo(_from);
        _ctl.forward(from: 0);
      });
    });
  }

  /// 按住处理：接管回弹中 → 立即停（停在半路交给用户——子树可交互，
  /// 反向拖由页内 recognizer 接手平移）。ballistic 中（用户快于第二拍
  /// 的极限场景）→ 立即杀 ballistic 解除指针屏蔽：本 down 序列的
  /// hit test 已错过子树（图片收不到本序列事件，拖动归 PageView/
  /// 外层），但下一手势起完全恢复——比锁死到动画结束（原生行为）好。
  void _onDown(PointerDownEvent _) {
    _tracker = null; // 新指针序列：速度基线重置
    if (_ctl.isAnimating) {
      _ctl.stop();
      return;
    }
    final ctrl = widget.controller;
    if (ctrl.hasClients && ctrl.position.isScrollingNotifier.value) {
      ctrl.jumpTo(ctrl.position.pixels);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
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
        final dx = _tracker?.getVelocity().pixelsPerSecond.dx ?? 0.0;
        _tracker = null;
        _dragVelocity = -dx;
        _scheduleTakeOver();
      },
      onPointerCancel: (_) {
        _tracker = null;
        _dragVelocity = 0;
        if (_ctl.isAnimating) _ctl.stop();
      },
      child: widget.child,
    );
  }
}
