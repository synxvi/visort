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
import 'package:path/path.dart' as p;
import 'package:sortr_flutter/core/fs/fs_provider.dart';
import 'package:sortr_flutter/core/fs/file_system_repository.dart';
import 'package:sortr_flutter/core/fs/image_ref.dart';
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

    return WindowsKeyboardHandler(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pushNamedAndRemoveUntil(
                context, AppRoutes.setup, (_) => false),
          ),
          title: _Logo(),
          actions: [
            TextButton(
              onPressed: () => setLanguage(ref,
                  ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh'),
              child: Text(t(ref, 'lang_toggle')),
            ),
          ],
        ),
        body: ResponsiveBuilder(builder: (context, width) {
          final isWide = width > 800;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: _ImageArea(session: session)),
                      const SizedBox(width: 16),
                      SizedBox(
                          width: 320,
                          child: _SortPanel(session: session)),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: _ImageArea(session: session)),
                      const SizedBox(height: 16),
                      SizedBox(
                          height: 280,
                          child: _SortPanel(session: session)),
                    ],
                  ),
          );
        }),
      ),
    );
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
  String? _currentPath;

  @override
  void didUpdateWidget(_ImageArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    final img = widget.session.currentImage;
    final newPath = img == null ? null : p.join(img.root, img.relativePath);
    if (newPath != _currentPath) {
      _currentPath = newPath;
      _loadError = false;
      _meta = null;
      _loadMeta(img);
    }
  }

  @override
  void initState() {
    super.initState();
    final img = widget.session.currentImage;
    _currentPath = img == null ? null : p.join(img.root, img.relativePath);
    _loadMeta(img);
  }

  void _loadMeta(ImageRef? img) async {
    if (img == null) return;
    final fs = ref.read(fileSystemRepositoryProvider);
    try {
      final meta = await fs.readMeta(img);
      if (mounted) setState(() => _meta = meta);
      // 预加载下一张
      final session = ref.read(sessionControllerProvider);
      if (session.hasNext) {
        final next = session.images[session.currentIndex + 1];
        if (mounted) {
          precacheImage(
            FileImage(File(p.join(next.root, next.relativePath))),
            context,
          );
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

    final absPath = p.join(img.root, img.relativePath);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 文件名 + 进度
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(img.name,
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
        // 大图
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
                : Image.file(
                    File(absPath),
                    fit: BoxFit.contain,
                    errorBuilder: (ctx, error, stack) {
                      // 标记失败，下次重建显示提示
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

class _Logo extends StatelessWidget {
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
