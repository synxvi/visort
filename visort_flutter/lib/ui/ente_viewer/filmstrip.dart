// 底栏缩略图条（filmstrip）——系统相册（ColorOS Gallery）同款行为，2026-09 定稿重写。
//
// 行为契约：
//   1. 拖动/甩动中：无聚焦项——全部统一小样式（23×32 半透明），白框随
//      聚焦态缩小淡出（跨档轻震/主图跟手联动照常，只是视觉不表达聚焦）；
//   2. 停稳吸附：吸附项自动聚焦——撑开为大格、图片放大全亮、白框与图片
//      同步生长（所有聚焦动画同 duration + linear 曲线，线性插值下任意
//      中间帧白框与图片边缘恒差 1.5 = 边框宽，无先后残影）；
//   3. 变格宽布局：普通格 28 / 聚焦格 36——相邻间隙恒 5px，全条密度均匀，
//      聚焦项与两侧邻居留正常间距。固定格宽下聚焦项（图 31/框 34）必然
//      溢出嵌入邻居或砍尺寸（两轮真机实证），变格宽是系统相册的真实结构；
//   4. 滚动物理：格点吸附（ballistic 速度外推落格 + PageView 同款 spring），
//      松手后 item 永远完整对进聚焦位。
//
// 联动接口（宿主 = 大图页 detail_page）：
//   - [center] 双向桥：外部写 = 程序滚动 + 保持聚焦（主图翻页/删除同步）；
//     组件用户滚动中实时写（_selfCenter 自标记，自身上报不回环）；
//   - [onCenterChanged]：用户滚动跨档（实时，宿主跟手 jumpToPage 主图）；
//   - [onSettled]：停稳吸附落定（宿主 animateToPage 主图）；
//   - [onTap]：点按单项（组件已完成吸附聚焦，宿主只管主图跳转）；
//   - [onItemBuild]：条目构建钩子（解码预取策略由宿主注入）；
//   - [frozen]：pop 冻结/删除流程期间忽略一切联动（渲染照常；删除流程
//     offset 冻结天然自洽——删除前后聚焦格模型同构，中心项不动，下一项
//     顶入原聚焦格，frozen 解除时组件对齐 center 即可）。

import 'dart:async' show scheduleMicrotask;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/ui/ente_viewer/thumbnail_widget.dart';

// ─────────────── 常量（单点定义；宿主页布局只引用导出项） ───────────────

/// 条高（竖屏）：容纳放大后的当前项(42)+上下边距。
const double kFilmstripHeight = 44.0;

/// 普通项格宽（含间距）：图 23 + 两侧各 2.5 → 相邻间隙 5px。
const double _kNormalExtent = 28.0;

/// 聚焦项格宽：图 31 + 两侧各 5.5 → 与邻居图间隙 8px（2026-09 用户定稿；
/// 普通项间 5px），白框 34 小于格宽不压邻居图。滚动中回缩
/// [_kNormalExtent]（等距格点，吸附物理成立）。
const double _kCenterExtent = 42.0;

/// 普通项图片 23×32 / 聚焦项图片 31×39（贴白框内沿 34−1.5×2 / 42−1.5×2）。
const double _kNormalImgW = 23.0;
const double _kNormalImgH = 32.0;
const double _kCenterImgW = 31.0;
const double _kCenterImgH = 39.0;

/// 白框外沿 34×42、边框 1.5、圆角（内沿圆角 = 外沿 − 1.5，与普通项一致
/// 无跳变）。
const double _kFrameW = 34.0;
const double _kFrameH = 42.0;
const double _kFrameStroke = 1.5;
const double _kRadiusCenter = 4.0;
const double _kRadiusNormal = 2.5;

/// 聚焦切换动画：格宽 / 图片尺寸 / 白框生长 / 透明度 / offset 修正全部
/// 用同一参数（同 duration + linear）——几何关系在插值全程恒定。
const Duration kFilmstripFocusDuration = Duration(milliseconds: 120);

/// 程序滚动时长（外部 center 指令 → 滚动+聚焦；与主图翻页联动同手感）。
const Duration kFilmstripSyncDuration = Duration(milliseconds: 220);

/// 吸附兜底时长（ScrollEnd 后未落格的防御性修正，略短手感利落）。
const Duration _kSnapDuration = Duration(milliseconds: 180);

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
  });

  final int itemCount;
  final int initialIndex;

  /// 居中项双向桥：外部写 = 程序滚动 + 聚焦指令；组件用户滚动中实时写。
  final ValueNotifier<int> center;

  /// 图源（96 方形档 provider，与网格 cell 共享 ImageCache）。
  final ImageProvider Function(int index) thumbnail;

  /// 用户滚动跨档（实时，宿主跟手联动主图）。
  final ValueChanged<int>? onCenterChanged;

  /// 停稳吸附落定（宿主 animateToPage 主图）。
  final ValueChanged<int>? onSettled;

  /// 点按单项（组件已完成吸附聚焦）。
  final ValueChanged<int>? onTap;

  /// 条目构建钩子（解码预取策略由宿主注入）。
  final void Function(BuildContext context, int index)? onItemBuild;

  /// 联动抑制（pop 冻结/删除流程）：true 时忽略滚动联动与外部指令。
  final ValueNotifier<bool>? frozen;

  /// 删除补位动画（透传渲染：被删项保持聚焦态原地淡出；后续项平移
  /// 补位——变格宽分档：紧邻项跨入聚焦格(36)平移多，其余平移一格(28)）。
  final Animation<double>? deleteAnim;

  /// 正在删除的条索引（-1 = 无删除动画）。
  final int deleteIndex;

  @override
  State<Filmstrip> createState() => _FilmstripState();
}

class _FilmstripState extends State<Filmstrip> {
  late final ScrollController _ctrl;

  /// 聚焦态：true = 聚焦样式（大格+放大+白框）；false = 用户滚动中小样式。
  late final ValueNotifier<bool> _focused;

  /// 组件视角的当前居中项（渲染依据）。外部 [Filmstrip.center] 的自标记：
  /// 组件自身写入/上报的值记在此，监听器据此区分回声与外部指令。
  late int _selfCenter;

  /// 程序滚动中（外部指令/吸附兜底/聚焦 offset 修正）：忽略 ScrollEnd 联动。
  bool _syncing = false;

  /// 首帧定位完成标记（initialScrollOffset 常规直达，postFrame jumpTo 兜底）。
  bool _located = false;

  @override
  void initState() {
    super.initState();
    _selfCenter = widget.initialIndex;
    _focused = ValueNotifier(true); // 进入即聚焦（吸附位）
    _ctrl = ScrollController(
      // 初始定位直达聚焦格（含 +4 居中修正）：attach 帧即渲染在正确位置，
      // 消灭 offset=0 首帧闪现（打开末尾图片时整条跳变的残影，真机实证）。
      // ⚠️ 必须用纯公式 _centerOffset：此时 _ctrl 尚未赋值。
      initialScrollOffset: _centerOffset(widget.initialIndex, focused: true),
    )..addListener(_onScroll);
    widget.center.addListener(_onExternalCenter);
    widget.frozen?.addListener(_onFrozenChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateOnce());
  }

  @override
  void dispose() {
    widget.frozen?.removeListener(_onFrozenChanged);
    widget.center.removeListener(_onExternalCenter);
    _ctrl.dispose();
    _focused.dispose();
    super.dispose();
  }

  // ─────────────── 几何 ───────────────

  /// 居中 offset 纯公式（不触实例状态，initState 的 initialScrollOffset
  /// 也在 _ctrl 赋值前求值——不能走 [_offsetFor] 的 hasClients 分支）：
  /// 聚焦项前序全部普通格（聚焦项唯一），前缀和恒定
  /// i×28 +（聚焦 ? (36−28)/2 : 0）——+4 使撑开后的中心（i×28+18）对齐
  /// 视口中心。
  static double _centerOffset(int i, {required bool focused}) =>
      i * _kNormalExtent +
      (focused ? (_kCenterExtent - _kNormalExtent) / 2 : 0);

  /// 让 item i 居中所需的 scroll offset（clamp 到滚动范围）。
  double _offsetFor(int i, {required bool focused}) {
    final target = _centerOffset(i, focused: focused);
    if (!_ctrl.hasClients) return target;
    final pos = _ctrl.position;
    // 末项聚焦 +4 会越 maxScrollExtent：clamp（视觉差 4px 无感）。
    return target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
  }

  /// 离视口中心最近的项（等距原点 round(offset/28)——滚动中/停稳位/聚焦
  /// 位（+7 < 半格 14）判定连续一致）。
  int _nearestCenter() {
    if (!_ctrl.hasClients) return _selfCenter;
    return (_ctrl.offset / _kNormalExtent)
        .round()
        .clamp(0, widget.itemCount - 1);
  }

  /// 首帧就绪（hasClients）后居中到进入时的图片（只执行一次，幂等兜底）。
  void _locateOnce() {
    if (_located || !_ctrl.hasClients) return;
    final pos = _ctrl.position;
    if (!pos.hasContentDimensions) return;
    _located = true;
    _ctrl.jumpTo(_offsetFor(widget.initialIndex, focused: true));
  }

  // ─────────────── 联动 ───────────────

  /// 程序滚动代际：animateTo 互相打断时旧动画的 .then 会晚于新动画启动
  /// 执行——无代际防护的话旧 then 把 _syncing 错误复位为 false，新动画
  /// 余程的跨档被当作用户滚动上报 → 宿主 jumpToPage 把未松手的主图程序
  /// 跳页（主图拖动中 onPageChanged 连续写 center 即触发，真机实证）。
  int _syncToken = 0;

  /// 滚动中：实时算最近项，跨档上报（tick + 宿主跟手联动主图）。
  void _onScroll() {
    if (_isFrozen) return;
    // ⚠️ 程序滚动全程静默（含 _syncing 被打断竞态弄丢的窗口——token 防
    // 护）：上报只属于用户真实滚动。程序滚动上报会让宿主 jumpToPage
    // （打断主图拖动/与其 onPageChanged 打架），tick 震动也只属于手势。
    if (_syncing) return;
    final c = _nearestCenter();
    if (c == _selfCenter) return;
    // 跨档轻震（系统相册同款）：用户拖动慢扫每跨一档 tick 一次，甩动
    // fling 连续跨档随减速自然降频。
    HapticFeedback.selectionClick();
    _selfCenter = c;
    // 上报宿主（先自标记：center 写入触发自身监听时按回声忽略）。
    widget.center.value = c;
    widget.onCenterChanged?.call(c);
  }

  /// 外部指令（主图翻页/删除同步/点按后宿主回写）：程序滚动 + 聚焦。
  void _onExternalCenter() {
    final i = widget.center.value;
    if (i == _selfCenter) return; // 自身上报的回声
    if (_isFrozen) return; // 删除流程：数据同步由宿主管，组件只渲染
    _animateToCenter(i, duration: kFilmstripSyncDuration);
  }

  /// frozen 解除（删除流程结束）：对齐外部 center（删除末项时宿主写入了
  /// 新 center，frozen 期间被忽略，此处补齐聚焦）。
  void _onFrozenChanged() {
    if (_isFrozen) return;
    final i = widget.center.value;
    if (i != _selfCenter) {
      _animateToCenter(i, duration: kFilmstripFocusDuration);
    }
  }

  bool get _isFrozen => widget.frozen?.value ?? false;

  /// 程序滚动到 i 并保持聚焦（大格随滚动滑入聚焦位）。
  void _animateToCenter(int i, {required Duration duration}) {
    _selfCenter = i;
    _focused.value = true;
    if (!_ctrl.hasClients) return;
    _syncing = true;
    // 代际 token：本动画若被下一个 animateTo 打断，旧 then 的复位被
    // 忽略（只有最新代际能关 _syncing），见 _syncToken 注释。
    final token = ++_syncToken;
    _ctrl
        .animateTo(
          _offsetFor(i, focused: true),
          duration: duration,
          curve: Curves.easeOut,
        )
        .then((_) {
          if (token == _syncToken) _syncing = false;
        });
  }

  // ─────────────── 滚动事件 ───────────────

  /// 用户手指拖动开始（dragDetails≠null，程序滚动不带）：取消聚焦——
  /// 全部回缩小样式、白框缩小淡出（系统相册同款）。
  void _onUserDragStart() {
    if (_isFrozen) return;
    _focused.value = false;
  }

  /// 滚动停止（fling 减速结束）：吸附 + 聚焦 + 宿主联动（一个动作完成，
  /// 幂等）。
  void _onScrollEnd() {
    if (_isFrozen) return;
    if (_syncing) return;
    // ⚠️ 必须延到 microtask（通知栈外）：ScrollEnd 发出时 ScrollPosition
    // 仍处 ballistic→idle 的 activity 转换栈内，回调里直接 animateTo 建立
    // 的 Driven 会被栈上后续 activity 切换销毁——animateTo 立即 complete
    // 且 offset 不动 = 聚焦图偏 7px（widget test 打点实证）。microtask 在
    // 同步栈退完后执行，Driven 与撑开动画同帧起跑，同步性不破。
    scheduleMicrotask(() {
      if (!mounted || _isFrozen || _syncing) return;
      _focus(_nearestCenter());
    });
  }

  /// 吸附落定 → 聚焦：格宽撑开(28→42)与 offset 修正(等距位→聚焦位)同
  /// 参数动画（120ms linear）——任一中间帧图片中心视口位置恒定（**原地
  /// 从两边长大**），左右邻居同时对称推开（此前 offset 落点=终位时左邻
  /// 首帧即跳终值、右邻渐推 = 「向右顶开」不对称观感，真机实证）。
  /// 静止后聚焦位被 physics 认作合法静止位（见类注释），不会被弹回。
  void _focus(int i) {
    if (!mounted) return;
    _selfCenter = i;
    widget.center.value = i; // == _selfCenter → 自身监听按回声忽略
    _focused.value = true;
    if (_ctrl.hasClients) {
      final target = _offsetFor(i, focused: true);
      if ((_ctrl.offset - target).abs() > 0.5) {
        // 未落格（防御非 ballistic 静止停位）也由此一并带到聚焦格点。
        // 代际 token 同 _animateToCenter（被打断时不复位 _syncing）。
        _syncing = true;
        final token = ++_syncToken;
        _ctrl
            .animateTo(
              target,
              duration: kFilmstripFocusDuration,
              curve: Curves.linear, // 与 AnimatedContainer 撑开同步（默认 linear）
            )
            .then((_) {
              if (token == _syncToken) _syncing = false;
            });
      }
    }
    widget.onSettled?.call(i);
  }

  /// 点按单项：吸附聚焦 + 上报（宿主只管主图跳转）。
  void _handleTap(int i) {
    if (_isFrozen) return;
    if (i == _selfCenter && _focused.value) return; // 已聚焦：无操作
    _animateToCenter(i, duration: _kSnapDuration);
    widget.onTap?.call(i);
  }

  // ─────────────── 渲染 ───────────────

  @override
  Widget build(BuildContext context) {
    // 黑底：与底栏视觉一体，缩略图条覆盖在图片上（图片在下层被黑底遮）。
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        // 首尾 padding 让端点项能滚到视口正中（每侧留自身宽/2 − 普通格半宽）。
        // ⚠️ 用自身约束而非 MediaQuery：条不一定全屏宽（测试视口缩放时
        // MediaQuery 屏宽 ≠ 条宽 → padding 错位 → 聚焦图跑出框，test 实证）。
        builder: (context, cons) {
          final pad = (cons.maxWidth - _kNormalExtent) / 2;
          // 右侧 padding 多留 origin：末项聚焦位 (n−1)×28+7 需 maxScrollExtent
          // ≥ 该值，否则 offset 被 clamp 在等距位 = 末项聚焦图偏出框。
          return _buildStrip(pad);
        },
      ),
    );
  }

  Widget _buildStrip(double pad) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // dragDetails 只在用户手势驱动时非 null（程序 animateTo/jumpTo
        // 的 Start 不带）——只对真实拖动取消聚焦。
        if (n is ScrollStartNotification && n.dragDetails != null) {
          _onUserDragStart();
        } else if (n is ScrollEndNotification) {
          _onScrollEnd();
        }
        return false;
      },
      child: Stack(
        children: [
          ListView.builder(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            // 格点吸附（等距 28 对齐聚焦位）：ballistic 落格，见类注释。
            physics: const _FilmstripSnapPhysics(),
            // 无固定 itemExtent：格宽由 item 自身动画驱动（28↔42 变格宽）。
            padding: EdgeInsets.only(
              left: pad,
              right: pad + (_kCenterExtent - _kNormalExtent) / 2,
            ),
            itemCount: widget.itemCount,
            itemBuilder: (ctx, i) {
              widget.onItemBuild?.call(ctx, i);
              return _buildItem(i);
            },
          ),
            // 固定聚焦框：白框钉在条正中不跟 item 走（吸附保证聚焦项中心
            // 恒在视口正中）。与图片同步生长：尺寸动画起点 = 普通项+边框 3
            // （线性插值下任意中间帧框线贴图外缘）；z 序在 ListView 之上。
            ValueListenableBuilder<bool>(
              valueListenable: _focused,
              builder: (_, isFocused, __) => IgnorePointer(
                child: AnimatedOpacity(
                  opacity: isFocused ? 1.0 : 0.0,
                  duration: kFilmstripFocusDuration,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedContainer(
                      key: const ValueKey('filmstrip_focus_frame'),
                      duration: kFilmstripFocusDuration,
                      width: isFocused ? _kFrameW : _kNormalImgW + 3,
                      height: isFocused ? _kFrameH : _kNormalImgH + 3,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_kRadiusCenter),
                        border: Border.all(
                          color: AppColors.text,
                          width: _kFrameStroke,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
  }

  /// 单项：外层格宽动画（28↔36，聚焦项撑开推开邻居）+ 图片尺寸/透明度
  /// 动画 + 图源渲染 + 删除补位动画。
  Widget _buildItem(int i) {
    return ValueListenableBuilder<bool>(
      valueListenable: _focused,
      builder: (_, focused, __) {
        final isCenter = focused && i == _selfCenter;
        Widget item = AnimatedContainer(
          duration: kFilmstripFocusDuration,
          width: isCenter ? _kCenterExtent : _kNormalExtent,
          child: GestureDetector(
            onTap: () => _handleTap(i),
            behavior: HitTestBehavior.opaque,
            child: Align(
              alignment: Alignment.bottomCenter,
              // 底基准 = 白框【内沿底】（框底贴条底 − 边框 1.5）：普通项与
              // 聚焦项统一垫底 1.5——聚焦项 39 高正好与内沿重合（不垫的话
              // 图片底压边框线、框内上沿露黑边，真机实证）；普通项整排底线
              // 上移 1.5 无感，且与框内沿对齐更整齐。
              child: Padding(
                padding: const EdgeInsets.only(bottom: _kFrameStroke),
                child: AnimatedOpacity(
                  opacity: isCenter ? 1.0 : 0.5,
                  duration: kFilmstripFocusDuration,
                  child: AnimatedContainer(
                    duration: kFilmstripFocusDuration,
                    width: isCenter ? _kCenterImgW : _kNormalImgW,
                    height: isCenter ? _kCenterImgH : _kNormalImgH,
                    // 图片裁剪圆角：聚焦项贴白框【内沿】（外沿 4.0 − 边框
                    // 1.5 = 2.5），普通项 = 自身 r（2.5）——两者数值一致，
                    // 高亮切换无跳变；不 clip 的话直角穿出圆角观感。
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        isCenter
                            ? _kRadiusCenter - _kFrameStroke
                            : _kRadiusNormal,
                      ),
                      // Image + frameBuilder 占位：首帧前垫占位色块，加载完
                      // 渐入，快速滑动不闪黑。
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
        final anim = widget.deleteAnim;
        if (anim != null && widget.deleteIndex >= 0) {
          if (i == widget.deleteIndex) {
            // 被删项：保持聚焦态原地缩小淡出（框内置空观感更强）。
            item = FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(anim),
              child: item,
            );
          } else if (i > widget.deleteIndex) {
            // 后续项：平移补位（位置动画不触发重排）。变格宽分档——删除
            // 后紧邻项顶入聚焦格(36)：平移跨聚焦格；其余平移一格(28)。
            final dx = i == widget.deleteIndex + 1
                ? _kCenterExtent
                : _kNormalExtent;
            item = AnimatedBuilder(
              animation: anim,
              child: item,
              builder: (_, child) => Transform.translate(
                offset: Offset(-anim.value * dx, 0),
                child: child,
              ),
            );
          }
        }
        return item;
      },
    );
  }
}

/// 缩略图条格点吸附物理（双静止位模型，2026-09 对称推开定稿）。
///
/// **落点 = 等距格 i×28**（速度外推选格）：停稳瞬间图片恰好居中于等距
/// 布局；随后的撑开(28→42)与 offset 修正(+7)由 Filmstrip._focus 同参数
/// （120ms linear）驱动——数学上任一中间帧图片中心视口位置恒定（原地
/// 从两边长大），左右邻居同时被对称推开（各 7px，方向相反）。
///
/// **静止判定认两个合法位**：等距格 i×28（滚动停稳）与聚焦位
/// i×28+origin（撑开终位）。⚠️ 只认等距位的话，_focus 修正动画完成时
/// goBallistic(0) 会把 offset 从聚焦位弹回等距格 = 聚焦图偏出框
/// （widget test 实证过 +4 版本的同类 bug）。
class _FilmstripSnapPhysics extends ScrollPhysics {
  const _FilmstripSnapPhysics({super.parent});

  @override
  _FilmstripSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _FilmstripSnapPhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // 边界外（overscroll）交给父类（Android clamping 回边）。
    if ((velocity > 0.0 && position.pixels > position.maxScrollExtent) ||
        (velocity < 0.0 && position.pixels < position.minScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tol = toleranceFor(position);
    final origin = (_kCenterExtent - _kNormalExtent) / 2;
    // 合法静止位②聚焦格点：撑开终位 → 静止（不弹回）。不检查 velocity：
    // _focus 的 offset 修正动画（linear）完成时 goBallistic 带残余末速
    // 进来（≈58px/s > tol.velocity），带速度检查会漏拦 → 速度外推弹回
    // 等距格 = 聚焦图偏 7px（widget test 实证）。聚焦位只可能是 Driven
    // 动画的确定终态（ballistic 起点恒为用户松手位，不在此），拦之安全。
    {
      final k = ((position.pixels - origin) / _kNormalExtent).round();
      final focusSnap = k * _kNormalExtent + origin;
      if ((focusSnap - position.pixels).abs() < tol.distance) return null;
    }
    // 速度外推（PageScrollPhysics 同系数）：轻拖回最近等距格，甩动跨多格。
    final projected = position.pixels + velocity * 0.125;
    final target = ((projected / _kNormalExtent)
                .round()
                .clamp(0, position.maxScrollExtent ~/ _kNormalExtent) *
            _kNormalExtent)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    // 已在格点且无速度 → 静止（默认流程）。
    if ((target - position.pixels).abs() < tol.distance &&
        velocity.abs() < tol.velocity) {
      return null;
    }
    // PageView 同款 spring（mass .5 / stiffness 100 / ratio 1.1）。
    return ScrollSpringSimulation(
      SpringDescription.withDampingRatio(mass: 0.5, stiffness: 100, ratio: 1.1),
      position.pixels,
      target,
      velocity,
      tolerance: tol,
    );
  }
}
