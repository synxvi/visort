// [ente 移植] 大图页共享状态 —— 原样复制（去掉 EnteFile 依赖的标识函数）
// 原文件：ente mobile/apps/photos/lib/states/detail_page_state.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Scale is relative to the contained image; offset is in logical pixels.
@immutable
class ZoomTransform {
  static const ZoomTransform identity = ZoomTransform(
    scale: 1.0,
    offset: Offset.zero,
  );

  final double scale;
  final Offset offset;

  const ZoomTransform({required this.scale, required this.offset});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomTransform && other.scale == scale && other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);
}

enum FullScreenRequestReason { userInteraction, playbackStateChange }

/// 底栏缩略图条单项的解码尺寸（px）：detail_page 条渲染与 zoomable_image
/// 加载兜底**共用同一 ImageCache key**（provider = (id, size, squareCrop)）——
/// 条滚过的图必已解码，viewer 主图兜底直接命中（快甩到远处时主图区不再
/// 黑屏等待）。改此值必须两端同改（key 不匹配 = 兜底永远 miss）。
const int kFilmstripThumbLoadSize = 96;

/// viewer 渐进「清晰层」解码宽度（px，等比）：甩条滚动期间大图区显示档
/// （pick 链第二级），停稳后由 full（computeViewerTargetWidth ~1152）覆盖。
/// 512→640（2026-08-28）：滚动期放大 2.25→1.8 倍，竖图 640×~1130 ≈2.9MB/条。
/// 改此值必须与 zoomable_image（pick/heavy/错误兜底）+ detail_page 条目
/// 预取（当前项/±1）同改——ImageCache key = (id, size, squareCrop)，
/// 单点定义防漂移。
const int kViewerLargeThumbSize = 640;

/// viewer 远邻清晰档（物理 px）：条快甩 dist1~2 预取/掠过页显示档，走
/// readSampledImage 自产通道（readFullCache blob 秒读 + 尺寸精确）。
/// 对齐系统相册 THUMB 档 0.625×屏宽（1440 屏 = 900px）。此前用 MediaStore
/// thumb 通道的 640 请求——真机实证尺寸不可控（同请求返回 240x320 mini
/// 污染 59%、360x792 欠采样），360px 上 1440 屏 = 「过渡还是糊」的根因。
const int kViewerMidThumbSize = 900;

/// viewer 放大升档（HD 档，物理 px）：相对 contained 倍率越过 1.3 时懒加载
/// 整图替换 1152 显示档（此前放大只靠 FilterQuality 插值拉伸——
/// computeViewerTargetWidth doc 里的 _hdTriggered 曾是死注释，2026-09-08 补实）。
/// 取 2304 = 2×1152（系统相册 log2 分层同款语义），且是 readSampledImage
/// 尺寸数学的硬约束：inSampleSize 只取 2 的幂，请求 ≥2304 才能保证
/// ≥4600px 原图落到 sampleSize=2（半宽）档——请求 2048 会退回 sampleSize=4
/// 拿 1150 宽（等于白干）。通道零改动：readSampledImage 的 targetWidth
/// clamp [960,4096] 天然支持，盘缓存自动落 {visort_full}/2304/ 桶
///（blob ~300-500KB/张，与 1152 桶共享配额 LRU）。内存 ~16MB/张
///（2304×~1720×4），远重于 1152 档 3MB——trim 走独立窄窗（距离 >1，
/// detail_page._trimDistantHdCache），不进 1152 的 ±6 宽窗。
const int kViewerHdThumbSize = 2304;

/// viewer 放大升档第二级（原图等效档，物理 px）：相对倍率越过 2.3（2304 档
/// 已开始插值）时加载。对 ≤4096 宽的原图【无损等价原图】；对 40-50MP 旗舰
/// 图，4× 放大前显示需求（1440 屏双击 2.5× = 2880px 宽）仍在 4096 之内——
/// 真·全像素只服务极端变焦段，却不值得付它的代价：无 targetWidth 通道绕过
/// ServicePolicy 门（readBytes 裸跑）+ 引擎 codec 队列停摆（当年「翻页糊半秒」
/// 同根）+ 50MP 位图 200MB。内存 ~50MB/张（4096×3072×4）——trim 窗口与
/// 2304 共用但更严（翻页即逐，见 detail_page._trimDistantHdCache）。
const int kViewerUltraThumbSize = 4096;

/// viewer 端正在显示的图源注册表（photoId → provider）。zoomable_image
/// build 时写入、dispose 时移除、detail_page dispose 时整体兜底清空。
/// 飞行层（Hero shuttle）第一优先级图源：正在显示的 provider 其
/// completer 必然存活，resolve 同步出图——不受 ImageCache evict/LRU
/// 影响（pop 时被 evictViewerImageCache/逐出的档位照常可用），push 首帧
/// 与 viewer 端落位图完全同源。
final Map<String, ImageProvider> kLiveViewerProviders = {};

// ───────────────── [visort 追加] 沉浸退出后恢复无背景系统栏 ─────────────────
// 手势条（小横条）无背景：导航栏透明色用 alpha=0 但 RGB 非零的 workaround
// （部分 ROM 把全零当「未设置」而回退半透明 scrim；同 main.dart
// _enableEdgeToEdge）。immersive（overlays: []）进出在部分 ROM 上会把
// 导航栏色重置回默认 scrim，故每次退出沉浸都重申一遍（ente photos 在
// detail_page dispose 做同样重申）。
const Color kTransparentNavBarColor = Color(0x00010000);

/// 退出沉浸：恢复 edge-to-edge + 重申透明导航栏（手势条无背景悬浮）。
void restoreEdgeToEdgeBars() {
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: kTransparentNavBarColor,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
  // engine 的 edgeToEdge 会清零 legacy flags（ColorOS 判定依据），Android 侧补设。
  MethodChannel('visort/app').invokeMethod('reassertSystemUiFlags');
}

typedef FullScreenRequestCallback =
    void Function(bool shouldEnable, FullScreenRequestReason reason);

class InheritedDetailPageState extends InheritedWidget {
  final ValueNotifier<bool> enableFullScreenNotifier;
  final ValueNotifier<bool> isInSharedCollectionNotifier;
  final ValueNotifier<String?> showingThumbnailFallbackNotifier;
  final ValueNotifier<bool> isZoomedNotifier;

  /// 当前选中页索引（PageView/条联动）——子页 ZoomableImage 用它判断
  /// 自己是否为当前显示页：预建途经页（allowImplicitScrolling ±1）跳过
  /// 重加载/盘缓存探测/条 heavy 预取，翻到时 build 自然重排（push 窗口
  /// 请求收敛，对齐 immich 打开只发当前页请求的模型）。
  final ValueNotifier<int> selectedIndexNotifier;

  /// [顶层双击路由] pageIndex → 该页双击处理（global 坐标）。
  /// Scrollable ballistic 中 ignorePointer 屏蔽页内 tap，双击由
  /// DetailPage 顶层捕获后按当前页索引分发。
  final Map<int, void Function(Offset globalPosition)> doubleTapHandlers;
  final ValueNotifier<ZoomTransform> zoomTransformNotifier;

  /// 图片区单击回调（DetailPage 注入）：详情面板打开时收面板，否则全屏切换。
  final VoidCallback? onImageTap;

  // ignore: prefer_const_constructors_in_immutables
  InheritedDetailPageState({
    super.key,
    required super.child,
    required this.enableFullScreenNotifier,
    required this.isInSharedCollectionNotifier,
    required this.showingThumbnailFallbackNotifier,
    required this.isZoomedNotifier,
    required this.selectedIndexNotifier,
    required this.doubleTapHandlers,
    required this.zoomTransformNotifier,
    this.onImageTap,
  });

  static InheritedDetailPageState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedDetailPageState>()!;

  static InheritedDetailPageState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedDetailPageState>();

  void toggleFullScreenByUser() {
    // DetailPage 可注入单击覆盖（详情面板打开时收面板，而非切换全屏）。
    if (onImageTap != null) {
      onImageTap!();
      return;
    }
    _applyFullScreenState(!enableFullScreenNotifier.value);
  }

  void requestFullScreen({
    required bool shouldEnable,
    required FullScreenRequestReason reason,
  }) {
    if (!shouldEnable && reason != FullScreenRequestReason.userInteraction) {
      return;
    }
    if (enableFullScreenNotifier.value == shouldEnable) {
      return;
    }
    _applyFullScreenState(shouldEnable);
  }

  void _applyFullScreenState(bool shouldEnable) {
    if (enableFullScreenNotifier.value == shouldEnable) {
      return;
    }
    enableFullScreenNotifier.value = shouldEnable;
    if (shouldEnable) {
      Future.delayed(const Duration(milliseconds: 200), () {
        // 竞态守卫:延迟期间页面已 pop(dispose 已把 notifier 复位为 false)
        // → 不再进沉浸,否则会在网格上凭空隐藏手势条(真机实测残留)。
        if (!enableFullScreenNotifier.value) return;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      });
    } else {
      restoreEdgeToEdgeBars();
    }
  }

  @override
  bool updateShouldNotify(InheritedDetailPageState oldWidget) =>
      oldWidget.enableFullScreenNotifier != enableFullScreenNotifier ||
      oldWidget.isInSharedCollectionNotifier != isInSharedCollectionNotifier ||
      oldWidget.showingThumbnailFallbackNotifier !=
          showingThumbnailFallbackNotifier ||
      oldWidget.isZoomedNotifier != isZoomedNotifier ||
      oldWidget.selectedIndexNotifier != selectedIndexNotifier ||
      oldWidget.zoomTransformNotifier != zoomTransformNotifier;
}
