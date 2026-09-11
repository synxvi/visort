import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'photo_view_hit_corners.dart';

class PhotoViewGestureDetector extends StatelessWidget {
  const PhotoViewGestureDetector({
    Key? key,
    this.hitDetector,
    this.onScaleStart,
    this.onScaleUpdate,
    this.onScaleEnd,
    this.onDoubleTap,
    this.onDoubleTapDown,
    this.child,
    this.onTapUp,
    this.onTapDown,
    this.behavior,
  }) : super(key: key);

  final GestureDoubleTapCallback? onDoubleTap;
  /// [visort fork] 双击落点（精准缩放锚点）：DoubleTapGestureRecognizer 的
  /// onDoubleTap 回调无位置参数，需 onDoubleTapDown 先记录 TapDownDetails。
  final GestureTapDownCallback? onDoubleTapDown;

  final HitCornersDetector? hitDetector;

  final GestureScaleStartCallback? onScaleStart;
  final GestureScaleUpdateCallback? onScaleUpdate;
  final GestureScaleEndCallback? onScaleEnd;

  final GestureTapUpCallback? onTapUp;
  final GestureTapDownCallback? onTapDown;

  final Widget? child;

  final HitTestBehavior? behavior;

  @override
  Widget build(BuildContext context) {
    final scope = PhotoViewGestureDetectorScope.of(context);

    final Axis? axis = scope?.axis;

    final Map<Type, GestureRecognizerFactory> gestures =
        <Type, GestureRecognizerFactory>{};

    if (onTapDown != null || onTapUp != null) {
      gestures[TapGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
        () => TapGestureRecognizer(debugOwner: this),
        (TapGestureRecognizer instance) {
          instance
            ..onTapDown = onTapDown
            ..onTapUp = onTapUp;
        },
      );
    }

    if (onDoubleTap != null || onDoubleTapDown != null) {
      gestures[DoubleTapGestureRecognizer] =
          GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
        () => DoubleTapGestureRecognizer(debugOwner: this),
        (DoubleTapGestureRecognizer instance) {
          instance
            ..onDoubleTapDown = onDoubleTapDown
            ..onDoubleTap = onDoubleTap;
        },
      );
    }

    gestures[PhotoViewGestureRecognizer] =
        GestureRecognizerFactoryWithHandlers<PhotoViewGestureRecognizer>(
      () => PhotoViewGestureRecognizer(
          hitDetector: hitDetector, debugOwner: this, validateAxis: axis),
      (PhotoViewGestureRecognizer instance) {
        instance
          ..dragStartBehavior = DragStartBehavior.start
          ..onStart = onScaleStart
          ..onUpdate = onScaleUpdate
          ..onEnd = onScaleEnd;
      },
    );

    return RawGestureDetector(
      behavior: behavior,
      child: child,
      gestures: gestures,
    );
  }
}

class PhotoViewGestureRecognizer extends ScaleGestureRecognizer {
  PhotoViewGestureRecognizer({
    this.hitDetector,
    Object? debugOwner,
    this.validateAxis,
    PointerDeviceKind? kind,
  }) : super(debugOwner: debugOwner);
  final HitCornersDetector? hitDetector;
  final Axis? validateAxis;

  Map<int, Offset> _pointerLocations = <int, Offset>{};

  Offset? _initialFocalPoint;
  Offset? _currentFocalPoint;

  /// 手势起点焦点（slop 判定用累计位移；[_initialFocalPoint] 是相邻帧
  /// 焦点，只够方向判定——单帧增量过不了 touchSlop）。
  Offset? _gestureStartPoint;

  /// 手势基线双指间距（span）：多指声明的「真捏合」判定基线。
  double _gestureStartSpan = 0;

  bool ready = true;
  int _ar2Logged = 0;

  /// 本指针序列已透传过 accepted（arena 已判我们赢，消费权锁定）。
  /// 置位后 resolve 一律透传 accepted——arena 裁决完成后基类每帧
  /// reaffirm resolve(accepted)（_advanceStateMachine 的 >=accepted
  /// 分支），此刻 arena 已销毁，改判 rejected 是空操作（PageView 早被
  /// 逐出不会接手），只会留下脏状态；且中途让位违反 aves 语义（声明
  /// 后锁定平移，拖到贴边撞墙不翻页）。
  bool _declared = false;

  /// 让位即退出：resolve 自查改判 rejected 或 arena 判负后置位。基类
  /// rejectGesture 已把 _state 重置 ready——后续事件再喂 super.handleEvent
  /// 会撞 `assert(_state != _ScaleState.ready)`（scale.dart:546，2026-09-11
  /// 审查 P0 复现实证）。置位后本 recognizer 对余下事件静默（新指针序列
  /// 在 addAllowedPointer 重置）。
  bool _yielded = false;

  /// 当前双指间距（<2 指返回 0）。
  double _currentSpan() {
    if (_pointerLocations.length < 2) return 0;
    final pts = _pointerLocations.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  /// 位移主导轴：|dx| 与 |dy| 取大者（相等归水平）。声明与让位自查共用
  /// ——两侧同轴，判据同源。
  static Axis _dominantAxis(Offset move) =>
      move.dx.abs() >= move.dy.abs() ? Axis.horizontal : Axis.vertical;

  /// 双指间距相对基线的变化量（0 = 无变化/不足两指）。
  double _spanDelta() => (_currentSpan() - _gestureStartSpan).abs();

  @override
  void addAllowedPointer(event) {
    if (ready) {
      ready = false;
      _yielded = false;
      _declared = false;
      _pointerLocations = <int, Offset>{};
      _gestureStartPoint = null;
    }
    super.addAllowedPointer(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    ready = true;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _yielded = true;
    super.rejectGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    // 让位后基类状态机已重置 ready，事件不得再进入（含 super）。
    if (_yielded) {
      // 防御：非 rejectGesture 路径的让位（理论上自查改判，arena 已销毁
      // 时 rejectGesture 不会被回调）基类跟踪不解除，残留 _trackedPointers
      // 会把 ready 锁死 → 后续所有序列不初始化 = 手势永久静默（2026-09-11
      // 用户实证「让位松手后只能翻页」）。up/cancel 必须放行解除跟踪，
      // stopTrackingPointer 幂等（didStopTrackingLastPointer → ready=true）。
      if (event is PointerUpEvent || event is PointerCancelEvent) {
        stopTrackingPointer(event.pointer);
      }
      return;
    }
    if (validateAxis != null) {
      _computeEvent(event);
      _updateDistances();
      _decideIfWeAcceptEvent(event);
      if (_yielded) {
        // 本帧内主动让位（resolve 自查改判 rejected）：_decideIfWeAcceptEvent
        // → super.resolve(rejected) → arena → rejectGesture 已同步重置基类
        // 状态机，同一事件不能再喂 super.handleEvent（撞 ready 断言）。
        return;
      }
    }
    super.handleEvent(event);
  }

  void _computeEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      // ⚠️ synthesized move（高报点率触控的合成插值事件）必须同样更新：
      // 忽略会导致 _currentFocalPoint 冻结 → slop 累计位移恒 0 → recognizer
      // 永不主动声明 → PageView 恒赢 =「放大后左右拖直接翻页」（120Hz
      // 真机 move 大多为合成事件，真机实证 [AR] will-accept 零打出
      // 2026-09-11；测试环境 TestPointer 全非合成故掩盖）。
      _pointerLocations[event.pointer] = event.position;
    } else if (event is PointerDownEvent) {
      _pointerLocations[event.pointer] = event.position;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointerLocations.remove(event.pointer);
    }

    _initialFocalPoint = _currentFocalPoint;
  }

  void _updateDistances() {
    final int count = _pointerLocations.keys.length;
    Offset focalPoint = Offset.zero;
    for (int pointer in _pointerLocations.keys)
      focalPoint += _pointerLocations[pointer]!;
    _currentFocalPoint =
        count > 0 ? focalPoint / count.toDouble() : Offset.zero;
  }

  void _decideIfWeAcceptEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      // 按下基线（_updateDistances 已算出含本指针的焦点）：slop 竞争与
      // Scrollable 的 drag recognizer 同基线——首 move 才记会晚 1-2 帧位
      // 移，累计恒小 → PageView 先过 slop 先声明 = 图内平移被抢走。
      // 多指加入时 span 基线同步重建（含新指的当前间距）。
      _gestureStartPoint = _currentFocalPoint;
      _gestureStartSpan = _currentSpan();
      return;
    }
    if (!(event is PointerMoveEvent)) {
      return;
    }
    final move = _initialFocalPoint! - _currentFocalPoint!;
    // [visort fork·aves 对齐] 主动 accept 条件（同 aves MagnifierGestureRecognizer
    // 的 handleEvent）：多指（缩放语义）/ 图片在当前拖动方向上可平移，且
    // 累计位移过 touchSlop（对齐 aves _isOverSlop——无 slop 检查的首 move
    // 即声明会把 arena 提前关闭，micro-drag 误抢）。
    // 认输路径见 [resolve] 覆写：贴边外拖时让位，PageView/外层手势接管。
    final hitDetector = this.hitDetector;
    final axis = validateAxis;
    final bool shouldMove;
    if (axis == null || hitDetector == null) {
      shouldMove = true;
    } else if (axis == Axis.horizontal) {
      shouldMove = hitDetector.shouldMove(move, Axis.horizontal);
    } else if (axis == Axis.vertical) {
      // ⚠️ 主导轴判定（绝非 canX || canY）：双轴 scope（visort 下滑关闭）
      // 若任一轴可移即声明，贴边外拖稍带垂直分量（人手常态）时 Y 可移
      // → 抢先声明（半 slop 9px 先于 PageView 18px）→ 手势锁成垂直
      // 平移、翻页永远触发不了（真机实证 2026-09-12「必须一点不抖的
      // 水平移动才能翻页」）。取位移主分量方向查可移性——意图判定
      // 对齐人手：斜向拖动由主导轴说话。PageView 侧同样只看主轴分量
      // 过自己的 slop，两侧判定自然咬合。
      shouldMove =
          hitDetector.shouldMove(move, _dominantAxis(move));
    } else {
      shouldMove = true;
    }
    final start = _gestureStartPoint;
    final total = start != null ? start - _currentFocalPoint! : Offset.zero;
    // ⚠️ magnifier 的 slop 必须严格小于 Scrollable（PageView）的 touchSlop
    //（aves touchSlopFactor<1 注释同义：recognizer 要先于 PageView 接受）。
    // 同 slop 时真机竞争 PageView 恒赢（[AR2] 实证 total 8.1→18 途中被
    // 抢，零 will-accept）——取一半（~9px）：图内拖动先声明锁定，tap 的
    // 亚 9px 微动仍不误触。
    final overSlop = total.distance >
        computeHitSlop(event.kind, gestureSettings) * 0.5;
    // [AR2] 诊断打点：每次 move 的三判定值（限额 300——24 条一次平移就
    // 用光，拿不到让位时刻的数据，真机实证 2026-09-11）。
    if (_ar2Logged < 300) {
      _ar2Logged++;
      debugPrint('[AR2] move=(${move.dx.toStringAsFixed(1)},${move.dy.toStringAsFixed(1)}) '
          'shouldMove=$shouldMove total=${total.distance.toStringAsFixed(1)} '
          'slop=${computeHitSlop(event.kind, gestureSettings).toStringAsFixed(1)} '
          'over=$overSlop n=${_pointerLocations.length}');
    }
    // ⚠️ 多指声明要求【span 已有实际变化】而非仅指头数 ≥2（aves
    // _areMultiPointers 分支的落地修正）：双指刚按下的瞬间焦点从单指
    // 中点跳到双指中点——零位移合成 move 触发的立即声明会把手势锁死
    // 在跳变时刻 =「顶栏抖动 + 第一次缩放无效」（真机 [AR] 实证 n=2
    // total=0.0 即 accept，2026-09-11）。span 变化 >8px（真捏合）才声明：
    // 焦点跳变早已稳定，锁定混在真实缩放里不可见。单指走 shouldMove +
    // overSlop 路径。
    final multiPinching =
        _pointerLocations.keys.length > 1 && _spanDelta() > 8;
    if (multiPinching || (shouldMove && overSlop)) {
      debugPrint('[AR] will-accept total=${total.distance.toStringAsFixed(1)} '
          'shouldMove=$shouldMove multi=$multiPinching');
      // ⚠️ 必须走 [resolve] 而非直调 acceptGesture：直调只把基类状态机推进
      // started（派发 onStart），但不通知 arena——arena 层面我们仍是 pending。
      // 贴边外拖后回摆时：本帧朝内（shouldMove=true）但累计朝外贴边，若在此
      // 直调进 started，随后 arena 裁定 PageView 赢 → 我们被 reject →
      // didStopTrackingLastPointer 在 started 态断言崩溃（debug 闪退 /
      // release 悬空手势，2026-09-11 审查 P0）。resolve 路径下「基类进
      // started」与「arena 已定我们赢」由同一次裁决原子保证——自查改判
      // rejected 即让位，绝不进 started。
      resolve(GestureDisposition.accepted);
    }
  }

  /// [visort fork·aves 对齐] arena 裁决让位（aves MagnifierGestureRecognizer
  /// .resolve 的核心）：arena 判本 recognizer 赢时【自查】——多指/图片仍可
  /// 平移（当前手势方向未双向贴边）才真 accept；贴边外拖（X 让 PageView
  /// 翻页 / Y 让外层上下滑）时 resolve(rejected) 主动认输，让位给
  /// Scrollable/外层 gesture。无此覆写时 ScaleGestureRecognizer 基类一律
  /// accept——放大态贴边外拖手势悬空（PageView 被消费权封锁）=
  /// 「放大后无法翻页」的根（2026-09-11 真机实证）。
  @override
  void resolve(GestureDisposition disposition) {
    // [AR] 诊断：rejected（让位/败给 PageView）时打出当时的判定细节——
    // 「放大态左右滑误触发翻页」定位用（2026-09-11）。
    if (disposition == GestureDisposition.rejected && validateAxis != null) {
      final hitDetector = this.hitDetector;
      if (hitDetector != null) {
        final current = _currentFocalPoint;
        final start = _gestureStartPoint;
        final move = (start != null && current != null)
            ? start - current
            : Offset.zero;
        debugPrint(
            '[AR] reject-detail move=(${move.dx.toStringAsFixed(1)},${move.dy.toStringAsFixed(1)}) '
            'canX=${hitDetector.shouldMove(move, Axis.horizontal)} '
            'canY=${hitDetector.shouldMove(move, Axis.vertical)} '
            'n=${_pointerLocations.length}');
      }
    }
    if (disposition == GestureDisposition.accepted && validateAxis != null) {
      // 已声明赢定（arena 裁决完成）：基类每帧 reaffirm 的 resolve 一律
      // 透传。自查改判只属于竞争期——arena 销毁后 rejected 是空操作
      //（PageView 不会接手），反而吞掉 up 收尾 → _trackedPointers 残留 →
      // ready 锁死 → 手势永久静默（2026-09-11 用户实证）。
      if (_declared) {
        super.resolve(disposition);
        return;
      }
      final hitDetector = this.hitDetector;
      final bool canAccept;
      if (hitDetector == null) {
        canAccept = true;
      } else {
        final current = _currentFocalPoint;
        final start = _gestureStartPoint ?? _initialFocalPoint;
        final move = (start != null && current != null)
            ? start - current
            : Offset.zero;
        // 主导轴判定与声明侧同源（见 _decideIfWeAcceptEvent）：多指恒
        // 可（缩放语义）。
        canAccept = _pointerLocations.keys.length > 1 ||
            hitDetector.shouldMove(move, _dominantAxis(move));
      }
      if (canAccept) {
        _declared = true;
        super.resolve(GestureDisposition.accepted);
      } else {
        // 竞争期让位即退出（_yielded）：arena 收 rejected 会同步
        // rejectGesture 重置基类状态机，本序列余下事件由 handleEvent
        // 静默（up/cancel 走 stopTrackingPointer 解除跟踪）。
        _yielded = true;
        super.resolve(GestureDisposition.rejected);
      }
      return;
    }
    super.resolve(disposition);
  }
}

/// An [InheritedWidget] responsible to give a axis aware scope to [PhotoViewGestureRecognizer].
///
/// When using this, PhotoView will test if the content zoomed has hit edge every time user pinches,
/// if so, it will let parent gesture detectors win the gesture arena
///
/// Useful when placing PhotoView inside a gesture sensitive context,
/// such as [PageView], [Dismissible], [BottomSheet].
///
/// Usage example:
/// ```
/// PhotoViewGestureDetectorScope(
///   axis: Axis.vertical,
///   child: PhotoView(
///     imageProvider: AssetImage("assets/pudim.jpg"),
///   ),
/// );
/// ```
class PhotoViewGestureDetectorScope extends InheritedWidget {
  PhotoViewGestureDetectorScope({
    this.axis,
    required Widget child,
  }) : super(child: child);

  static PhotoViewGestureDetectorScope? of(BuildContext context) {
    final PhotoViewGestureDetectorScope? scope = context
        .dependOnInheritedWidgetOfExactType<PhotoViewGestureDetectorScope>();
    return scope;
  }

  final Axis? axis;

  @override
  bool updateShouldNotify(PhotoViewGestureDetectorScope oldWidget) {
    return axis != oldWidget.axis;
  }
}
