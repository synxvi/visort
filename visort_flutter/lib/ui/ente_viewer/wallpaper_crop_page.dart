// 壁纸范围调整页 —— 模仿 Aves WallpaperPage + WallpaperSettingsDialog 交互
//
// 流程（Aves 同款）：
//   全屏视口（初始 covered，可拖动/捏合调整）→ 右下「设为壁纸」→
//   dialog（主屏/锁屏/主屏+锁屏 radio + 「滚动效果」开关，默认开）→
//   可见区域 → Canvas 渲染 PNG → 原生 setStream(bytes)
//
// 照抄 Aves（wallpaper_buttons.dart）：像素工作全在 Dart——用渲染预览的
// 【同一张解码图】做 Canvas 裁剪（drawImageRect → toImage → PNG bytes），
// 原生只 setStream 哑管道。所见即所得的关键：不存在二次解码，坐标系/
// EXIF/尺寸声明差异全部消灭（此前原生按 MediaStore 尺寸二次裁剪导致的
// 「预览≠结果」即此根因）。
//
// 滚动效果数学（Aves 同款）：可见区域左右【对称扩展到图片极限】
// （deltaX = min(左余量, 右余量)），无黑边，滚动幅度由图片宽度余量决定
// ——横图滚动空间大，竖图几乎无滚动。
//
// 拖不出屏（Aves 同款「无论放没放大都拖不出边界」）：InteractiveViewer
// 原生约束——contain 尺寸 child + minScale=cover + boundaryMargin=0，
// 库在手势回调内部逐帧 clamp 平移。

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui show Image, ImageByteFormat, ImageFilter, PictureRecorder, PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart' show MsImageInfo;
import 'package:visort_flutter/core/fs/wallpaper_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart' show t;
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/screens/album_common.dart' show extOf;

/// 大图查看器 → 壁纸调整页（返回手势退出，无栏位）。
Future<void> pushWallpaperCropPage(BuildContext context, MsImageInfo photo) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => WallpaperCropPage(photo: photo)),
  );
}

class WallpaperCropPage extends ConsumerStatefulWidget {
  const WallpaperCropPage({super.key, required this.photo});

  final MsImageInfo photo;

  @override
  ConsumerState<WallpaperCropPage> createState() => _WallpaperCropPageState();
}

class _WallpaperCropPageState extends ConsumerState<WallpaperCropPage> {
  final _ctrl = TransformationController();

  ImageProvider? _provider;
  bool _decodeFailed = false;
  bool _applying = false;

  /// 解码图（预览与裁剪共用同一张——所见即所得的根基）。listener 常挂
  /// 保活（completer 持 image 引用），dispose 摘除交还 ImageCache。
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  ui.Image? _image;

  /// 视口逻辑尺寸（build 时 LayoutBuilder 捕获）。
  double _vw = 0, _vh = 0;

  /// contain 布局参数（child=等比 contain 尺寸，cover 需 kCover× 缩放）：
  /// InteractiveViewer 的 pan clamp 按 child 实际尺寸×scale 算——cover 态
  /// 溢出维度有平移空间（初始可拖），缩放被 minScale 挡在 cover（不露
  /// 黑边），boundaryMargin=0 保证图片边缘永不出屏（库原生逐帧 clamp）。
  ///
  /// 比例基准 = 解码图尺寸（唯一坐标系；不取 MediaStore 声明尺寸——
  /// 两者 EXIF 处理不一致时会错位）。
  double? _cw, _ch, _kCover;
  bool _laidOut = false;

  int? get _imgW => _image?.width;
  int? get _imgH => _image?.height;

  @override
  void initState() {
    super.initState();
    final ref = imageRefFromMediaStoreId(
      widget.photo.id,
      extension: extOf(widget.photo.name),
    );
    final provider = buildImageProvider(ref, targetWidth: _cropDecodeWidth());
    _provider = provider;
    _imageStream = provider.resolve(const ImageConfiguration());
    _imageListener = ImageStreamListener((info, _) {
      _image = info.image;
      // setState 包 postFrame——cache 命中时 listener 同步回调，initState
      // 期间直接 setState 会 assert。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }, onError: (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _decodeFailed = true);
      });
    });
    _imageStream!.addListener(_imageListener!);
  }

  /// 裁剪页解码目标宽：屏物理宽 ×2（预览 cover 后仍有 2× 放大余量，
  /// 内存 ~2432×N raw，可控）。
  ///
  /// ⚠️ initState 里调用——不可用 MediaQuery/View.of（dependOnInherited
  /// 在 initState 期间 assert 红屏），走 PlatformDispatcher。
  int _cropDecodeWidth() {
    final view = ui.PlatformDispatcher.instance.views.first;
    return (view.physicalSize.width * 2).round().clamp(1600, 3200);
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageListener!);
    _image = null;
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (ctx, constraints) {
          _vw = constraints.maxWidth;
          _vh = constraints.maxHeight;
          _ensureLayout();
          return Stack(
            children: [
              Positioned.fill(child: _buildViewer()),
              _buildApplyButton(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildViewer() {
    final provider = _provider;
    if (provider == null || !_laidOut || _image == null) {
      if (_decodeFailed) {
        return Center(
          child: Text(
            t(ref, 'wallpaper_set_failed'),
            style: const TextStyle(color: AppColors.muted, fontSize: 13),
          ),
        );
      }
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white,
          ),
        ),
      );
    }
    return InteractiveViewer(
      transformationController: _ctrl,
      constrained: false,
      // child 是 contain 尺寸（无 transform = 1.0×），cover 需 kCover×。
      // 手势 scale 上下限相对 child 初始尺寸，min=kCover 挡住缩小露黑边。
      minScale: _kCover!,
      maxScale: _kCover! * 5,
      boundaryMargin: EdgeInsets.zero,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: _cw,
        height: _ch,
        child: Image(
          image: provider,
          fit: BoxFit.fill,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) {
            if (!_decodeFailed) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _decodeFailed = true);
              });
            }
            return const SizedBox.expand();
          },
        ),
      ),
    );
  }

  /// 计算布局并注入初始 cover 矩阵（一次）。写 controller.value 发生在
  /// LayoutBuilder 内、InteractiveViewer 挂载前（controller 尚无监听）——
  /// 无 setState-during-build 风险，且 InteractiveViewer 首挂即 covered。
  void _ensureLayout() {
    final img = _image;
    if (_laidOut || img == null || _vw <= 0 || _vh <= 0) return;
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    final s = math.min(_vw / iw, _vh / ih); // contain
    _cw = iw * s;
    _ch = ih * s;
    _kCover = math.max(_vw / _cw!, _vh / _ch!);
    // 初始 covered：cover 居中（Aves ViewerController initialScale: covered）。
    final dw = _cw! * _kCover! - _vw;
    final dh = _ch! * _kCover! - _vh;
    _ctrl.value = Matrix4.identity()
      ..translateByDouble(-dw / 2, -dh / 2, 0, 1)
      ..scaleByDouble(_kCover!, _kCover!, 1, 1);
    _laidOut = true;
  }

  /// 当前可见区域（解码图像素）= viewport 逆变换到 child（contain 逻辑）
  /// → ×(解码像素/child 逻辑)。与预览共用同一张解码图，所见即所得。
  Rect _visibleDecodedRect() {
    final inv = Matrix4.inverted(_ctrl.value);
    final tl = MatrixUtils.transformPoint(inv, Offset.zero);
    final br = MatrixUtils.transformPoint(inv, Offset(_vw, _vh));
    final fx = _imgW! / _cw!;
    final fy = _imgH! / _ch!;
    return Rect.fromLTRB(
      (tl.dx * fx).clamp(0.0, _imgW!.toDouble()),
      (tl.dy * fy).clamp(0.0, _imgH!.toDouble()),
      (br.dx * fx).clamp(0.0, _imgW!.toDouble()),
      (br.dy * fy).clamp(0.0, _imgH!.toDouble()),
    );
  }

  /// 滚动效果（Aves 同款）：左右对称扩展到图片极限，无黑边。
  Rect _expandScroll(Rect r) {
    final dx = math.min(r.left, _imgW! - r.right);
    return Rect.fromLTRB(r.left - dx, r.top, r.right + dx, r.bottom);
  }

  /// 高分辨率重取（Aves getFullImage 同思路，防下采样源输出发软）：
  /// 同一解码管线按 4096 上限二次解码——与预览图等比，坐标换算用两图
  /// 【真实解码尺寸】（不碰 MediaStore 声明尺寸）。大图内存可控
  /// （4096×3072 raw ≈ 50MB，一次性）。
  Future<ui.Image?> _loadHiResImage() async {
    final ref = imageRefFromMediaStoreId(
      widget.photo.id,
      extension: extOf(widget.photo.name),
    );
    final provider = buildImageProvider(ref, targetWidth: _hiResDecodeWidth());
    final stream = provider.resolve(const ImageConfiguration());
    final completer = Completer<ImageInfo?>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!completer.isCompleted) completer.complete(info);
    }, onError: (_, _) {
      if (!completer.isCompleted) completer.complete(null);
    });
    stream.addListener(listener);
    final info = await completer.future;
    stream.removeListener(listener);
    return info?.image;
  }

  /// 高清解码目标宽：输出高恒 = 屏高（~2664），滚动全宽输出可达 ~2× 屏宽
  /// ——源宽 4× 屏物理宽（clamp 3200~4096）覆盖所有裁剪方向仍有富余。
  int _hiResDecodeWidth() {
    final v = ui.PlatformDispatcher.instance.views.first;
    return (v.physicalSize.width * 4).round().clamp(3200, 4096);
  }

  /// region（预览解码像素）→ PNG bytes（Aves _getBytes 的 Canvas 链路）：
  /// 高清重取 → 等比换算 region → drawImageRect → toImage(region 原尺寸)
  /// → PNG。输出尺寸照抄 Aves（renderSize = displayRegion 尺寸）——不
  /// 强制屏高比例，最终尺寸交系统 setStream 的 desired 缩放处理；否则
  /// 位图比 Aves 宽（同内容被拉到屏高），ColorOS 桌面按位图宽分配滚动
  /// 量 → 滚动过远、右缘滚不到。
  Future<Uint8List?> _renderBytes(Rect previewRegion) async {
    final preview = _image;
    if (preview == null) return null;
    var image = preview;
    var region = previewRegion;
    // 高清源可用且与预览严格等比（±1% 防御：管线异常时宁低清不错位）
    // 才用高清坐标，否则回退预览图直接渲染。
    final hiRes = await _loadHiResImage();
    if (hiRes != null && _imgW != null && _imgH != null && _imgW! > 0) {
      final sx = hiRes.width / _imgW!;
      final sy = hiRes.height / _imgH!;
      if ((sy - sx).abs() / sx <= 0.01) {
        final bounds = Rect.fromLTWH(
          0, 0, hiRes.width.toDouble(), hiRes.height.toDouble(),
        );
        final scaled = Rect.fromLTRB(
          previewRegion.left * sx,
          previewRegion.top * sy,
          previewRegion.right * sx,
          previewRegion.bottom * sy,
        ).intersect(bounds);
        if (!scaled.isEmpty) {
          image = hiRes;
          region = scaled;
        }
      }
    }
    final outW = region.width.round().clamp(1, 8192);
    final outH = region.height.round().clamp(1, 8192);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      region,
      Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(outW, outH);
    picture.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    return data?.buffer.asUint8List();
  }

  // ─────────────── chrome ───────────────

  Widget _buildApplyButton() {
    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: _GlassPillButton(
          label: t(ref, 'set_wallpaper'),
          loading: _applying,
          // _image == null（解码未完成/失败）时 _cw 等仍是 null，
          // _visibleDecodedRect 的 `!` 断言会炸——必须一并禁用（审查 P1）。
          onTap: (_applying || _vw <= 0 || _image == null) ? null : _apply,
        ),
      ),
    );
  }

  // ─────────────── 设置与应用 ───────────────

  Future<void> _apply() async {
    final (WallpaperTarget, bool)? picked = await _showSettingsDialog();
    if (picked == null || !mounted) return;
    final (target, scroll) = picked;

    setState(() => _applying = true);
    try {
      // region 计算收进 try：门控与执行之间解码态可能变化，坐标换算
      // 一旦抛错也走统一失败提示，而非无 catch 的异步逃逸（审查 P1）。
      var region = _visibleDecodedRect();
      if (scroll) region = _expandScroll(region);
      // 渲染在先（可能失败），channel 在后（异常映射 WallpaperException）。
      final bytes = await _renderBytes(region);
      if (bytes == null) throw const WallpaperException('RENDER_FAILED', '渲染失败');
      await setWallpaper(bytes, target);
      if (!mounted) return;
      toast(context, t(ref, 'wallpaper_set'));
      Navigator.pop(context);
    } on WallpaperException {
      if (!mounted) return;
      toast(context, t(ref, 'wallpaper_set_failed'));
    } catch (e) {
      // 渲染管线/OOM 等非 WallpaperException：同样复位 + 提示，不能让
      // _applying 卡 true（应用按钮永久禁用）。
      debugPrint('[wallpaper] apply 异常: $e');
      if (!mounted) return;
      toast(context, t(ref, 'wallpaper_set_failed'));
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// 目标选择 dialog（Aves WallpaperSettingsDialog 同款：三选 radio +
  /// 滚动效果开关，默认开）。
  Future<(WallpaperTarget, bool)?> _showSettingsDialog() {
    var selected = WallpaperTarget.system;
    var useScrollEffect = true;
    return showCenterDialog<(WallpaperTarget, bool)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(
            t(ref, 'set_wallpaper'),
            style: const TextStyle(
              fontFamily: 'Space Mono',
              fontFamilyFallback: ['Noto Sans Mono CJK SC'],
              color: AppColors.text,
              fontSize: 15,
            ),
          ),
          // 最小宽明确化：Column(min) 内 Row 的 Expanded 在 intrinsic 宽度
          // 计算中贡献为 0 → AlertDialog 被收窄到 280 下限，英文（Space Mono
          // 等宽、字距大）换行后挤溢。给足内容宽（AlertDialog 自身仍会按
          // 屏宽上限裁剪）。
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (icon, label, value) in [
                  (
                    Icons.smartphone,
                    t(ref, 'wallpaper_target_system'),
                    WallpaperTarget.system
                  ),
                  (
                    Icons.lock_outline,
                    t(ref, 'wallpaper_target_lock'),
                    WallpaperTarget.lock
                  ),
                  (
                    Icons.playlist_add_check,
                    t(ref, 'wallpaper_target_both'),
                    WallpaperTarget.both
                  ),
                ])
                  _targetOption(
                    icon,
                    label,
                    value,
                    selected,
                    onTap: (v) => setState(() => selected = v),
                  ),
                const Divider(height: 24, color: AppColors.border),
                _scrollEffectSwitch(
                  useScrollEffect,
                  onChanged: (v) => setState(() => useScrollEffect = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(
                t(ref, 'cancel'),
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                  color: AppColors.muted,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.bg,
              ),
              onPressed: () =>
                  Navigator.pop(ctx, (selected, useScrollEffect)),
              child: Text(t(ref, 'apply')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetOption(
    IconData icon,
    String label,
    WallpaperTarget value,
    WallpaperTarget selected, {
    required ValueChanged<WallpaperTarget> onTap,
  }) {
    final active = value == selected;
    return InkWell(
      onTap: () => onTap(value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // 高度自适应（不锁 44）：英文换行到两行也不垂直溢出。
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: AppColors.text, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.text,
                  fontSize: 14,
                ),
              ),
            ),
            Icon(
              active ? Icons.check_circle : Icons.radio_button_unchecked,
              color: active ? AppColors.accent : AppColors.muted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _scrollEffectSwitch(
    bool value, {
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.swap_horiz, color: AppColors.text, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                t(ref, 'wallpaper_use_scroll_effect'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.text,
                  fontSize: 14,
                ),
              ),
            ),
            Switch(
              value: value,
              activeThumbColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// 毛玻璃胶囊按钮（Aves ScalingOverlayTextButton 同款观感：背景高斯
/// 模糊 + 半透明白 + 白色文字；loading 时换白色细环 spinner，最小宽
/// 占位避免文字宽度跳动）。
class _GlassPillButton extends StatelessWidget {
  const _GlassPillButton({
    required this.label,
    required this.loading,
    this.onTap,
  });

  final String label;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: disabled ? 0.08 : 0.14),
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minWidth: 96),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              alignment: Alignment.center,
              child: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        strokeCap: StrokeCap.round,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: AppFonts.cjkFallback,
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
