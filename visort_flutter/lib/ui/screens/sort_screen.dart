// Sort 屏幕 —— 图片逐张浏览 + 键盘决策（对应前端 #screen-sort）
//
// 还原 K2 UI:
//   - 左列：图片区（文件名 + 进度 + 大图 + 元信息 size/created/modified）
//   - 右列：文件夹按钮列表 + 根目录按钮 + 撤销/删除/跳过/Review
//
// 图片加载：Image.file（拼接绝对路径），失败显示 [预览不可用]
// 预加载：当前图加载完后 precacheImage 下一张

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/fs_provider.dart';
import 'package:visort_flutter/core/fs/file_system_repository.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/session/session_models.dart';
import 'package:visort_flutter/shared/widgets/kbd_badge.dart';
import 'package:visort_flutter/shared/widgets/middle_ellipsis_text.dart';
import 'package:visort_flutter/ui/adaptive/windows_keyboard_handler.dart';
import 'package:visort_flutter/ui/router.dart';

class SortScreen extends ConsumerWidget {
  const SortScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);

    // 完成时自动跳 Review：ref.listen 仅在 session"变完成"时触发一次，
    // 从 Review pop 回不会重复触发（配合 continue_sort 回退 index 避免完成态空白）。
    // 删除了原先最后一张图之后的"审核变更"中间页——它会多算一页，
    // 导致进度显示成 (length+1)/length（如 5/4）。
    ref.listen<SessionState>(sessionControllerProvider, (prev, next) {
      if (next.isComplete && (prev == null || !prev.isComplete)) {
        Navigator.pushNamed(context, AppRoutes.review);
      }
    });

    // 空 session（未扫描直接进入）→ 回 Home
    if (session.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (_) => false);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    // 完成态：不再渲染"审核变更"中间页，留一帧空白作跳转过渡。
    // 恢复场景(P2)补跳:会话在 Review 屏被杀后恢复进来即完成态,
    // ref.listen 听不到"变完成"(无状态变化)——首帧主动 push Review,
    // 否则永远停在空白屏(真机实测黑屏,返回才回 Home)。
    // isCurrent 去重:正常完成路径 listen 已先 push Review(本路由非栈顶),
    // 此时不再重复压栈。
    if (session.isComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final isTop = ModalRoute.of(context)?.isCurrent ?? false;
        if (isTop) Navigator.pushNamed(context, AppRoutes.review);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    // 安卓端无物理键盘，跳过 WindowsKeyboardHandler；两端布局分叉
    final useAndroidLayout = Platform.isAndroid;
    final scaffold = Scaffold(
      // 安卓端：全屏沉浸——图片铺满物理屏幕在正中央居中，
      // 顶部信息栏与底部操作栏作为透明浮层叠加。
      // 桌面端保持实色 AppBar header。
      extendBodyBehindAppBar: useAndroidLayout,
      appBar: useAndroidLayout
          ? null
          : AppBar(
              backgroundColor: AppColors.headerBg,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pushNamedAndRemoveUntil(
                    context, AppRoutes.home, (_) => false),
              ),
              title: const _Logo(),
              // 语言切换已移入「设置」（settings_section_general）。
            ),
      body: useAndroidLayout
          ? _buildAndroidLayout(session)
          : _buildDesktopLayout(session),
    );

    // Windows 键盘处理仅桌面端需要
    if (Platform.isWindows) {
      return WindowsKeyboardHandler(child: scaffold);
    }
    return scaffold;
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

  /// 桌面布局：宽屏左右分栏，窄屏上下
  Widget _buildDesktopLayout(SessionState session) {
    return ResponsiveBuilder(builder: (context, width) {
      final isWide = width > 800;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: isWide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _ImageArea(session: session)),
                  const SizedBox(width: 16),
                  SizedBox(width: 320, child: _SortPanel(session: session)),
                ],
              )
            : Column(
                children: [
                  Expanded(child: _ImageArea(session: session)),
                  const SizedBox(height: 16),
                  SizedBox(height: 280, child: _SortPanel(session: session)),
                ],
              ),
      );
    });
  }
}

// ───────────── 图片区 ─────────────

class _ImageArea extends ConsumerStatefulWidget {
  const _ImageArea({required this.session});
  final SessionState session;

  @override
  ConsumerState<_ImageArea> createState() => _ImageAreaState();
}

class _ImageAreaState extends ConsumerState<_ImageArea> {
  ImageMeta? _meta;
  bool _loadError = false;
  String? _currentImgId;

  @override
  void didUpdateWidget(_ImageArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    final img = widget.session.currentImage;
    final newId = img?.id;
    if (newId != _currentImgId) {
      _currentImgId = newId;
      _loadError = false;
      _meta = null;
      _loadMeta(img);
    }
  }

  @override
  void initState() {
    super.initState();
    final img = widget.session.currentImage;
    _currentImgId = img?.id;
    _loadMeta(img);
  }

  void _loadMeta(ImageRef? img) async {
    if (img == null) return;
    final fs = ref.read(fileSystemRepositoryProvider);
    try {
      final meta = await fs.readMeta(img);
      if (mounted) setState(() => _meta = meta);
      // 预加载下一张（跨平台）
      final session = ref.read(sessionControllerProvider);
      if (session.hasNext) {
        final next = session.images[session.currentIndex + 1];
        if (mounted) {
          precacheNextImage(context, next);
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final img = session.currentImage;
    if (img == null) {
      // 完成态由 SortScreen.build 拦截自动跳 Review；此处不会渲染，留空兜底
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 文件名 + 进度
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(img.label,
                    style: const TextStyle(
                        fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                        fontSize: 13,
                        color: AppColors.text)),
              ),
              Text(
                '${session.currentIndex + 1} / ${session.totalCount}',
                style: const TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 13,
                    color: AppColors.muted),
              ),
            ],
          ),
        ),
        // 大图（跨平台加载）
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: _loadError
                ? Center(
                    child: Text(t(ref, 'preview_na'),
                        style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)))
                : Image(
                    image: buildImageProvider(img),
                    fit: BoxFit.contain,
                    errorBuilder: (ctx, error, stack) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() => _loadError = true);
                      });
                      return const SizedBox.shrink();
                    },
                  ),
          ),
        ),
        // 元信息
        if (_meta != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 16,
              children: [
                _MetaChip(label: _meta!.sizeLabel),
                _MetaChip(label: '${t(ref, 'created')}${_meta!.createdLabel}'),
                _MetaChip(
                    label: '${t(ref, 'modified')}${_meta!.modifiedLabel}'),
              ],
            ),
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
      precacheNextImage(context, next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final img = session.currentImage;

    // 完成态由 SortScreen.build 拦截自动跳 Review；此处不会渲染，留空兜底
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
                  image: buildImageProvider(img),
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

  void _loadMeta(ImageRef? img) async {
    if (img == null) return;
    final fs = ref.read(fileSystemRepositoryProvider);
    try {
      final meta = await fs.readMeta(img);
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

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: const TextStyle(
            fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 11, color: AppColors.muted));
  }
}

// ───────────── 操作面板 ─────────────

class _SortPanel extends ConsumerWidget {
  const _SortPanel({required this.session});
  final SessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final actionKeys = config.activeProfileData.actionKeys;
    final controller = ref.read(sessionControllerProvider.notifier);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
                // 追加目标父目录全路径前缀（如 “X:\image\”），便于用户确认落点。
                () {
                  final parent = session.destinationParent;
                  final base = t(ref, 'move_to');
                  if (parent.isEmpty) return base;
                  final sep = parent.contains('\\') ? '\\' : '/';
                  final tail = parent.endsWith('\\') || parent.endsWith('/')
                      ? parent
                      : '$parent$sep';
                  return '$base $tail';
                }(),
                style: const TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.muted,
                    letterSpacing: 0.5)),
          ),
          // 文件夹按钮列表
          ...session.folders.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _FolderButton(
                  keyLabel: f.key,
                  label: f.label,
                  onTap: () {
                    controller.decide(DecisionAction.move, destKey: f.key);
                  },
                ),
              )),
          // 根目录按钮
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _RootButton(
              label: t(ref, 'root_dir'),
              onTap: () {
                controller.decide(DecisionAction.move, destKey: kRootDestKey);
              },
            ),
          ),
          // 操作行：撤销/删除/跳过
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: t(ref, 'undo'),
                  kbd: actionKeys.undo,
                  onTap: () => controller.undo(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  label: t(ref, 'delete_btn'),
                  kbd: actionKeys.delete,
                  danger: true,
                  onTap: () =>
                      controller.decide(DecisionAction.delete),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  label: t(ref, 'skip'),
                  kbd: actionKeys.skip,
                  onTap: () =>
                      controller.decide(DecisionAction.skip),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Review 按钮
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.review),
              child: Text(t(ref, 'review_go')),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderButton extends StatelessWidget {
  const _FolderButton(
      {required this.keyLabel, required this.label, required this.onTap});
  final String keyLabel;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Kbd(label: keyLabel, highlight: true),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RootButton extends StatelessWidget {
  const _RootButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.rootDirBg,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Kbd(label: 'Space', highlight: false),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppColors.text.withValues(alpha: 0.7))),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.kbd,
    required this.onTap,
    this.danger = false,
  });
  final String label;
  final String kbd;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: danger ? AppColors.danger.withValues(alpha: 0.1) : AppColors.surface,
          border: Border.all(
              color: danger ? AppColors.danger : AppColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: danger ? AppColors.danger : AppColors.text)),
            const SizedBox(height: 2),
            Text(kbd,
                style: const TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 10, color: AppColors.muted)),
          ],
        ),
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
    final isToAlbum = ref.watch(configProvider
        .select((c) => c.activeProfileData.classifyMode == ClassifyMode.toAlbum));
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
          // 操作行：撤销 / 删除 / 跳过（roadmap 共识 #4 可选手势）
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
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: danger ? AppColors.danger.withValues(alpha: 0.1) : AppColors.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: danger ? AppColors.danger : AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 18,
                  color: danger ? AppColors.danger : AppColors.text),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontFamily: 'Space Mono', height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      color: danger ? AppColors.danger : AppColors.text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // V 用主题绿(accent),ISORT 白色 —— VISORT logo。
        Text('V',
            style: TextStyle(
                fontFamily: 'Syne', fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w800,
                fontSize: 22,
                color: AppColors.accent)),
        Text('ISORT',
            style: TextStyle(
                fontFamily: 'Syne', fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w800,
                fontSize: 22)),
      ],
    );
  }
}

class ResponsiveBuilder extends StatelessWidget {
  const ResponsiveBuilder({super.key, required this.builder});
  final Widget Function(BuildContext, double) builder;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) => builder(ctx, constraints.maxWidth),
    );
  }
}
