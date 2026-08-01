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
import 'package:sortr_flutter/core/fs/fs_provider.dart';
import 'package:sortr_flutter/core/fs/file_system_repository.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/session/session_controller.dart';
import 'package:sortr_flutter/features/session/session_models.dart';
import 'package:sortr_flutter/shared/widgets/kbd_badge.dart';
import 'package:sortr_flutter/ui/adaptive/windows_keyboard_handler.dart';
import 'package:sortr_flutter/ui/router.dart';

class SortScreen extends ConsumerWidget {
  const SortScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);

    // 空 session（未扫描直接进入）→ 回 Setup
    if (session.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushNamedAndRemoveUntil(context, AppRoutes.setup, (_) => false);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    // 安卓端无物理键盘，跳过 WindowsKeyboardHandler；两端布局分叉
    final useAndroidLayout = Platform.isAndroid;
    final scaffold = Scaffold(
      // 安卓端：全屏沉浸——图片铺满物理屏幕在正中央居中，
      // AppBar 与底栏作为透明浮层叠加，不挤占图片空间。
      extendBodyBehindAppBar: useAndroidLayout,
      appBar: AppBar(
        // 安卓端 AppBar 透明叠加在图片之上；桌面端保持实色 header。
        backgroundColor:
            useAndroidLayout ? Colors.transparent : AppColors.headerBg,
        forceMaterialTransparency: useAndroidLayout,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pushNamedAndRemoveUntil(
              context, AppRoutes.setup, (_) => false),
        ),
        title: const _Logo(),
        actions: [
          TextButton(
            onPressed: () => setLanguage(ref,
                ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh'),
            child: Text(
                ref.read(currentLanguageProvider) == 'zh' ? '中文' : 'EN'),
          ),
        ],
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
      // 已处理完，引导去 Review
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t(ref, 'review_title'),
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.review),
              child: Text(t(ref, 'review_go')),
            ),
          ],
        ),
      );
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
                        fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                        fontSize: 13,
                        color: AppColors.text)),
              ),
              Text(
                '${session.currentIndex + 1} / ${session.totalCount}',
                style: const TextStyle(
                    fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
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
                        style: const TextStyle(color: AppColors.muted)))
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
  ImageMeta? _meta;
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
      final session = ref.read(sessionControllerProvider);
      if (session.hasNext) {
        final next = session.images[session.currentIndex + 1];
        if (mounted) precacheNextImage(context, next);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final img = session.currentImage;

    // 已处理完 → 引导去 Review
    if (img == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t(ref, 'review_title'), style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.review),
              child: Text(t(ref, 'review_go')),
            ),
          ],
        ),
      );
    }

    // 顶部 inset：避开状态栏 + AppBar 高度，让文件名浮层落在 AppBar 下方。
    final topInset = MediaQuery.viewPaddingOf(context).top;
    // AppBar 标准高度 56；用 SliverAppBar 可变高度较复杂，这里用固定值足够。
    const appBarHeight = 56.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 图片本体：铺满全屏，物理居中
        _loadError
            ? Center(
                child: Text(t(ref, 'preview_na'),
                    style: const TextStyle(color: AppColors.muted)))
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
        // 顶部文件名 + 进度浮层（避开状态栏 + AppBar）
        Positioned(
          left: 0,
          right: 0,
          top: topInset + appBarHeight + 8,
          child: IgnorePointer(
            child: _TopInfoOverlay(
              name: img.label,
              progress: '${session.currentIndex + 1} / ${session.totalCount}',
              meta: _meta == null
                  ? null
                  : [
                      _meta!.sizeLabel,
                      '${t(ref, 'created')}${_meta!.createdLabel}',
                      '${t(ref, 'modified')}${_meta!.modifiedLabel}',
                    ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 顶部信息浮层：文件名 + 进度 + 元信息，半透明胶囊，不拦截触摸。
class _TopInfoOverlay extends StatelessWidget {
  const _TopInfoOverlay({required this.name, required this.progress, this.meta});
  final String name;
  final String progress;
  final List<String>? meta;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'SpaceMono',
                            fontFamilyFallback: AppFonts.cjkFallback,
                            fontSize: 12,
                            color: AppColors.text)),
                  ),
                  const SizedBox(width: 10),
                  Text(progress,
                      style: const TextStyle(
                          fontFamily: 'SpaceMono',
                          fontFamilyFallback: AppFonts.cjkFallback,
                          fontSize: 12,
                          color: AppColors.muted)),
                ],
              ),
              if (meta != null && meta!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: meta!
                      .map((m) => Text(m,
                          style: const TextStyle(
                              fontFamily: 'SpaceMono',
                              fontFamilyFallback: AppFonts.cjkFallback,
                              fontSize: 10,
                              color: AppColors.muted)))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
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
            fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback, fontSize: 11, color: AppColors.muted));
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
            child: Text(t(ref, 'move_to'),
                style: const TextStyle(
                    fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
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
                      fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
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
                      fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
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
                    fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: danger ? AppColors.danger : AppColors.text)),
            const SizedBox(height: 2),
            Text(kbd,
                style: const TextStyle(
                    fontFamily: 'SpaceMono', fontFamilyFallback: AppFonts.cjkFallback, fontSize: 10, color: AppColors.muted)),
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
                fontFamily: 'SpaceMono',
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
                      fontFamily: 'SpaceMono',
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
        Text('SORT',
            style: TextStyle(
                fontFamily: 'Syne', fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w800,
                fontSize: 22)),
        Text('R',
            style: TextStyle(
                fontFamily: 'Syne', fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w800,
                fontSize: 22,
                color: AppColors.accent)),
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
