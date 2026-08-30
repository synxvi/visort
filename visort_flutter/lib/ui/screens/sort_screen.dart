// Sort 屏幕（桌面）—— 图片逐张浏览 + 键盘决策（对应前端 #screen-sort）
//
// 还原 K2 UI:
//   - 左列：图片区（文件名 + 进度 + 大图 + 元信息 size/created/modified）
//   - 右列：文件夹按钮列表 + 根目录按钮 + 撤销/删除/跳过/Review
//
// 图片加载：Image.file（拼接绝对路径），失败显示 [预览不可用]
// 预加载：当前图加载完后 precacheImage 下一张
//
// 平台分叉（2026-08）：本文件为桌面布局（键盘 + 宽窄分栏），由 router.dart
// 在非安卓平台实例化；安卓沉浸式布局见 sort_screen_android.dart；双端共用的
// 会话守卫（空回退/完成跳 Review）见 sort_common.dart。
// 键盘处理不再按 Platform.isWindows 条件包裹——本文件只在桌面路由下实例化，
// WindowsKeyboardHandler 本身平台无关。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/fs_provider.dart';
import 'package:visort_flutter/core/fs/file_system_repository.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/image_ref.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/session/session_models.dart';
import 'package:visort_flutter/shared/widgets/kbd_badge.dart';
import 'package:visort_flutter/shared/widgets/responsive_builder.dart';
import 'package:visort_flutter/shared/widgets/visort_logo.dart';
import 'package:visort_flutter/ui/adaptive/windows_keyboard_handler.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/screens/sort_common.dart';

class SortScreen extends StatelessWidget {
  const SortScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SortSessionGate(
      builder: (context, session) => WindowsKeyboardHandler(
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.headerBg,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              // 回移动前的一级页（安卓 shell 保留当前页；桌面 HomeScreen
              // 保留输入状态）。重建 home 会丢状态、安卓落回默认相册页。
              onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
            ),
            title: const VisortLogo(),
            // 语言切换已移入「设置」（settings_section_general）。
          ),
          body: _buildDesktopLayout(session),
        ),
      ),
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

  /// 元信息竞态守卫：键盘连按快速翻图时旧图 readMeta 晚归会覆盖新图
  /// （photo_details_sheet 7ec73b7 同款 bug 的漏改点）。
  int _loadGeneration = 0;

  void _loadMeta(ImageRef? img) async {
    if (img == null) return;
    final fs = ref.read(fileSystemRepositoryProvider);
    final gen = ++_loadGeneration;
    try {
      final meta = await fs.readMeta(img);
      if (gen != _loadGeneration) return; // 已翻页，旧结果作废
      if (mounted) setState(() => _meta = meta);
      // 预加载下一张（跨平台）
      final session = ref.read(sessionControllerProvider);
      if (session.hasNext) {
        final next = session.images[session.currentIndex + 1];
        if (mounted) {
          precacheNextImage(context, next, targetWidth: sortTargetWidth(context));
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final img = session.currentImage;
    if (img == null) {
      // 完成态由 SortSessionGate 拦截自动跳 Review；此处不会渲染，留空兜底
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
                    image: buildImageProvider(img,
                        targetWidth: sortTargetWidth(context)),
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
          // 操作行：撤销/删除/跳过 + 审核（提前收尾：剩余全部跳过直进 Review）
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
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  label: t(ref, 'audit'),
                  accent: true,
                  onTap: () => controller.skipRemaining(),
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
    required this.onTap,
    this.kbd,
    this.danger = false,
    this.accent = false,
  });
  final String label;
  /// 快捷键提示行；null 则不渲染（「审核」无快捷键，单行强调按钮）
  final String? kbd;
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: fg)),
            if (kbd != null) ...[
              const SizedBox(height: 2),
              Text(kbd!,
                  style: const TextStyle(
                      fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 10, color: AppColors.muted)),
            ],
          ],
        ),
      ),
    );
  }
}
