// Sort 屏幕（安卓）—— 全屏沉浸式布局：图片铺满物理屏幕 + 顶部/底部浮层。
//
// 交互（roadmap 共识 #4/#5）：全屏单图（BoxFit.contain 物理居中）+ 底部横滑
// 目标文件夹按钮列 + 撤销/删除/跳过操作行；顶部浮层为返回/文件名/进度/元信息。
// 安卓端无物理键盘，不做键盘处理。
//
// 平台分叉（2026-08）：本文件由 router.dart 在安卓平台实例化；桌面键盘布局见
// sort_screen.dart；双端共用的会话守卫（空回退/完成跳 Review）见 sort_common.dart。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/fs_provider.dart';
import 'package:visort_flutter/core/fs/file_system_repository.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/session/session_models.dart';
import 'package:visort_flutter/shared/widgets/middle_ellipsis_text.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/screens/sort_common.dart';

class SortScreenAndroid extends StatelessWidget {
  const SortScreenAndroid({super.key});

  @override
  Widget build(BuildContext context) {
    return SortSessionGate(
      builder: (context, session) => Scaffold(
        // 全屏沉浸——图片铺满物理屏幕在正中央居中，
        // 顶部信息栏与底部操作栏作为透明浮层叠加。
        // 桌面端保持实色 AppBar header（见 sort_screen.dart）。
        extendBodyBehindAppBar: true,
        appBar: null,
        body: _buildAndroidLayout(session),
      ),
    );
  }

  /// 安卓布局：全屏图片（物理居中）+ 底部操作栏浮层 + 顶部文件名/进度浮层。
  ///
  /// edge-to-edge 沉浸式：图片铺满整个 Scaffold body（含 AppBar 区与手势条区），
  /// 在物理屏幕正中央居中（BoxFit.contain）；AppBar、文件名、底栏均作为透明
  /// 浮层叠加，不再挤占图片空间 → 图片不再偏下。
  Widget _buildAndroidLayout(SessionState session) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底层：图片本体，铺满全屏，在物理屏幕正中央居中
        _FullscreenImage(session: session),
        // 顶层：顶部图片信息浮层（第一行与返回按钮对齐，背景透明露出页面黑色）
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _AndroidTopInfo(),
        ),
        // 顶层：底部操作栏（Positioned 在底，自带底部 inset 避让手势条）
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _AndroidBottomBar(session: session),
        ),
      ],
    );
  }
}

// ───────────── 全屏图片区（安卓沉浸式）─────────────

/// 安卓 sort 屏的全屏图片：铺满物理屏幕在正中央居中（BoxFit.contain），
/// 文件名/进度与元信息作为半透明浮层叠加在顶部/底部，不挤占图片空间。
class _FullscreenImage extends ConsumerStatefulWidget {
  const _FullscreenImage({required this.session});
  final SessionState session;

  @override
  ConsumerState<_FullscreenImage> createState() => _FullscreenImageState();
}

class _FullscreenImageState extends ConsumerState<_FullscreenImage> {
  bool _loadError = false;
  String? _currentImgId;

  @override
  void didUpdateWidget(_FullscreenImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final img = widget.session.currentImage;
    final newId = img?.id;
    if (newId != _currentImgId) {
      _currentImgId = newId;
      _loadError = false;
      _precacheNext(img);
    }
  }

  @override
  void initState() {
    super.initState();
    final img = widget.session.currentImage;
    _currentImgId = img?.id;
    // precacheNextImage → precacheImage → createLocalImageConfiguration 会访问
    // MediaQuery(inherited widget),initState 阶段不可用会红屏。延迟到首帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheNext(img);
    });
  }

  /// 预加载下一张图片（meta 读取已移至 _AndroidTopInfo，此处仅负责 precache）。
  void _precacheNext(ImageRef? img) {
    if (img == null) return;
    final session = ref.read(sessionControllerProvider);
    if (session.hasNext) {
      final next = session.images[session.currentIndex + 1];
      precacheNextImage(context, next, targetWidth: sortTargetWidth(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final img = session.currentImage;

    // 完成态由 SortSessionGate 拦截自动跳 Review；此处不会渲染，留空兜底
    if (img == null) {
      return const SizedBox.shrink();
    }

    // 图片区约束在顶栏底部 ↔ 底栏顶部之间的预览区内，避免高图溢出到顶栏
    // 造成切换时"瞬间变大→被遮盖"的闪烁。
    // 顶栏高度 = topInset + 56(返回按钮行) + ~24(大小日期行) ≈ topInset + 80
    // 底栏高度 ≈ 124（文件夹行52 + 操作行44 + padding/border + bottomInset）
    final mq = MediaQuery.of(context);
    final topPad = mq.viewPadding.top + 80;
    final bottomPad = mq.viewPadding.bottom + 124;

    return Padding(
      padding: EdgeInsets.only(top: topPad, bottom: bottomPad),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _loadError
              ? Center(
                  child: Text(t(ref, 'preview_na'),
                      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)))
              // 全图：保证清晰度 + 动图(GIF)可播放。预览区 padding 已约束图片
              // 不溢出到顶栏，配合 gaplessPlayback + precacheNext 消除切换闪烁。
              : Image(
                  image: buildImageProvider(img,
                      targetWidth: sortTargetWidth(context)),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (ctx, error, stack) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _loadError = true);
                    });
                    return const SizedBox.shrink();
                  },
                ),
        ],
      ),
    );
  }
}

/// 安卓端顶部信息（放在 AppBar.actions，右对齐）。
///
/// 显示文件名 + 进度（第一行）和元信息 size/created/modified（第二行）。
/// 自身 ref.watch session + 加载 meta，独立于 _FullscreenImage。
/// 背景用主题 surface 半透明胶囊，与界面配色一致（不再用纯黑）。
class _AndroidTopInfo extends ConsumerStatefulWidget {
  const _AndroidTopInfo();

  @override
  ConsumerState<_AndroidTopInfo> createState() => _AndroidTopInfoState();
}

class _AndroidTopInfoState extends ConsumerState<_AndroidTopInfo> {
  ImageMeta? _meta;
  String? _currentImgId;

  /// 同桌面 _ImageAreaState._loadMeta 的竞态守卫（generation）。
  int _loadGeneration = 0;

  void _loadMeta(ImageRef? img) async {
    if (img == null) return;
    final fs = ref.read(fileSystemRepositoryProvider);
    final gen = ++_loadGeneration;
    try {
      final meta = await fs.readMeta(img);
      if (gen != _loadGeneration) return; // 已翻页，旧结果作废
      if (mounted) setState(() => _meta = meta);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    final img = session.currentImage;
    // build 里检测图片切换：session 变化必然触发 build（ref.watch 保证），
    // 在此比较 id 即可可靠捕获切换，不依赖 ref.listen/didUpdateWidget。
    final newId = img?.id;
    if (newId != _currentImgId) {
      _currentImgId = newId;
      _meta = null;
      _loadMeta(img);
    }
    final name = img?.label ?? '';
    final progress = session.totalCount > 0
        ? '${session.currentIndex + 1} / ${session.totalCount}'
        : '';
    // 第二行：大小 + 修改日期（安卓端 MediaStore 仅提供 modifiedMs；不显示前缀文字）。
    final sizeLabel = _meta?.sizeLabel ?? '';
    final dateLabel = _meta?.modifiedLabel ?? '';
    final secondLine = [sizeLabel, dateLabel]
        .where((s) => s.isNotEmpty && s != '-')
        .join('  ');

    final topInset = MediaQuery.viewPaddingOf(context).top;
    return Container(
      decoration: const BoxDecoration(color: AppColors.bg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  // 返回按钮（与 photo_viewer 顶部完全一致）
                  IconButton(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    icon: const Icon(Icons.arrow_back, color: AppColors.text),
                    tooltip: t(ref, 'back'),
                    onPressed: () => Navigator.pushNamedAndRemoveUntil(
                        context, AppRoutes.home, (_) => false),
                  ),
                  // 图片名称（中段省略保留扩展名）
                  // Expanded 占满空间把序号推到最右；内部 ConstrainedBox 收窄
                  // 实际文字宽度（左对齐），让省略号提前出现、不紧贴序号。
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: MiddleEllipsisText(
                          name,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 13,
                            fontFamily: 'Space Mono', height: 1.2,
                            fontFamilyFallback: AppFonts.cjkFallback,
                          ),
                          padding: const EdgeInsets.only(right: 12),
                        ),
                      ),
                    ),
                  ),
                  // 序号（与 photo_viewer 一致）
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(progress,
                        style: TextStyle(
                          color: AppColors.text.withValues(alpha: 0.7),
                          fontSize: 13,
                          fontFamily: 'Space Mono', height: 1.2,
                        )),
                  ),
                ],
              ),
            ),
          ),
          // 顶栏外：大小 + 创建日期，贴着顶栏右对齐
          if (secondLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 4),
              child: Text(secondLine,
                  style: const TextStyle(
                      fontFamily: 'Space Mono', height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 10,
                      color: AppColors.muted)),
            ),
        ],
      ),
    );
  }
}

// ───────────── 辅助组件 ─────────────

/// 安卓底部操作栏：横滑目标文件夹按钮 + 撤销/删除/跳过行
class _AndroidBottomBar extends ConsumerWidget {
  const _AndroidBottomBar({required this.session});
  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(sessionControllerProvider.notifier);
    // toAlbum 模式下目标是已有相册（bucket），不存在「父目录根」概念，
    // 且 destinationParent 被设为 MediaStore authority（非法 RELATIVE_PATH），
    // 选「根目录」会导致 Kotlin update 返回 0 行 → 移动失败。故此模式不显示根目录。
    // 模式取会话快照的 classifyMode（扫描时刻落盘）——恢复的会话不读当前
    // 首页配置，否则「恢复 toAlbum 会话 + 首页已切回 toNewDir」会错显根目录
    // 按钮（产生非法 move），反向则丢按钮。旧版会话无快照（null）回退当前配置。
    final ClassifyMode effectiveMode;
    final snapshotMode = session.classifyMode == null
        ? null
        : ClassifyMode.values.asNameMap()[session.classifyMode];
    if (snapshotMode != null) {
      effectiveMode = snapshotMode;
    } else {
      effectiveMode = ref.watch(configProvider
          .select((c) => c.activeProfileData.classifyMode));
    }
    final isToAlbum = effectiveMode == ClassifyMode.toAlbum;
    // edge-to-edge：补底部导航栏/手势条高度，让底栏内容不被遮挡、
    // 背景延伸到屏幕物理底边。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 横滑目标文件夹按钮列（roadmap 共识 #5）
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ...session.folders.map((f) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _AndroidFolderChip(
                        label: f.label,
                        onTap: () => controller.decide(DecisionAction.move,
                            destKey: f.key),
                      ),
                    )),
                // 根目录按钮 —— 仅 toNewDir 模式可用（toAlbum 模式无父目录根概念）
                if (!isToAlbum) ...[
                  const SizedBox(width: 8),
                  _AndroidFolderChip(
                    label: t(ref, 'root_dir'),
                    isRoot: true,
                    onTap: () => controller.decide(DecisionAction.move,
                        destKey: kRootDestKey),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 操作行：撤销 / 删除 / 跳过 / 审核（roadmap 共识 #4 可选手势；
          // 审核 = 剩余全部跳过，提前收尾直进 Review）
          Row(
            children: [
              Expanded(
                child: _AndroidActionChip(
                  label: t(ref, 'undo'),
                  icon: Icons.undo,
                  onTap: () => controller.undo(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _AndroidActionChip(
                  label: t(ref, 'delete_btn'),
                  icon: Icons.delete_outline,
                  danger: true,
                  onTap: () => controller.decide(DecisionAction.delete),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _AndroidActionChip(
                  label: t(ref, 'skip'),
                  icon: Icons.skip_next,
                  onTap: () => controller.decide(DecisionAction.skip),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _AndroidActionChip(
                  label: t(ref, 'audit'),
                  icon: Icons.fact_check_outlined,
                  accent: true,
                  onTap: () => controller.skipRemaining(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AndroidFolderChip extends StatelessWidget {
  const _AndroidFolderChip({
    required this.label,
    required this.onTap,
    this.isRoot = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool isRoot;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isRoot ? AppColors.rootDirBg : AppColors.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Space Mono', height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: isRoot
                    ? AppColors.text.withValues(alpha: 0.7)
                    : AppColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AndroidActionChip extends StatelessWidget {
  const _AndroidActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.accent = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  /// 主操作强调（审核按钮用）——accent 优先于 danger
  final bool accent;

  @override
  Widget build(BuildContext context) {
    // 三态配色：危险红 / 主操作黄绿 / 默认灰面
    final Color fg;
    final Color border;
    final Color bg;
    if (accent) {
      fg = AppColors.accent;
      border = AppColors.accent;
      bg = AppColors.accent.withValues(alpha: 0.08);
    } else if (danger) {
      fg = AppColors.danger;
      border = AppColors.danger;
      bg = AppColors.danger.withValues(alpha: 0.1);
    } else {
      fg = AppColors.text;
      border = AppColors.border;
      bg = AppColors.surface;
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Space Mono', height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}
