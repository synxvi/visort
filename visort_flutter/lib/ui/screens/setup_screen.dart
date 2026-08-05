// Setup 屏幕 —— 配置整理方案（对应前端 #screen-setup）
//
// 还原 K1 UI 元素：
//   - 源目录 + Browse + 扫描模式（Recursive/Flat）
//   - 目标父目录 + Browse + Import Subfolders
//   - Profile 切换/新建/删除
//   - Action Keys 编辑器（undo/delete/skip，冲突检测）
//   - 文件夹编辑器（ReorderableListView，key + label + 拖拽 + Remove）
//   - Start 按钮 → 触发扫描 → 跳 Sort
//   - 右侧目标文件夹预览

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/fs_provider.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/scan/scan_controller.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/setup/setup_controller.dart';
import 'package:visort_flutter/shared/widgets/profile_dropdown.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/screens/action_keys_editor.dart';
import 'package:visort_flutter/ui/screens/folder_editor.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late TextEditingController _sourceCtrl;
  late TextEditingController _destCtrl;
  bool _recursive = true;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configProvider);
    _sourceCtrl = TextEditingController(text: config.lastSourceDir);
    _destCtrl = TextEditingController(
        text: config.lastDestParent.isNotEmpty
            ? config.lastDestParent
            : _defaultDestParent());
  }

  String _defaultDestParent() {
    // 对应 Python DEFAULT_DEST_PARENT = ~/Pictures
    return '';
  }

  @override
  void dispose() {
    _sourceCtrl.dispose();
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _browseSource() async {
    final fs = ref.read(fileSystemRepositoryProvider);
    final paths = await fs.pickDirectories();
    if (paths.isNotEmpty && mounted) {
      setState(() => _sourceCtrl.text = paths.first);
    }
  }

  Future<void> _browseDest() async {
    final fs = ref.read(fileSystemRepositoryProvider);
    final paths = await fs.pickDirectories();
    if (paths.isNotEmpty && mounted) {
      final path = paths.first;
      setState(() => _destCtrl.text = path);
      // 实时重算 folders 预览
      ref
          .read(sessionControllerProvider.notifier)
          .recomputeFolders(destinationParent: path);
    }
  }

  Future<void> _importSubdirs() async {
    final parent = _destCtrl.text.trim();
    if (parent.isEmpty) {
      toast(context, t(ref, 'enter_dest_parent'));
      return;
    }
    final fs = ref.read(fileSystemRepositoryProvider);
    try {
      final subdirs = await fs.listSubdirs(parent);
      if (subdirs.isEmpty) {
        toast(context, t(ref, 'no_subdirs'));
        return;
      }
      final config = ref.read(configProvider);
      final profile = config.activeProfileData;
      var templates = List<FolderTemplate>.from(profile.folders);

      // 替换模式：仅 1 个且 label 为 General/通用/default_label
      final isDefaultOnly = templates.length == 1 &&
          ['general', '通用'].contains(templates.single.label.toLowerCase());
      if (isDefaultOnly) templates.clear();

      final existingLabels = templates.map((e) => e.label).toSet();
      final setup = SetupController(ref);
      var imported = 0;
      for (final name in subdirs) {
        if (existingLabels.contains(name)) continue;
        final key = setup.allocateKey(templates);
        templates.add(FolderTemplate(key: key, label: name));
        existingLabels.add(name);
        imported++;
      }
      if (imported == 0) {
        toast(context, t(ref, 'no_new_subdirs'));
        return;
      }
      await setup.updateFolders(templates);
      if (mounted) toast(context, t(ref, 'imported_count', [imported]));
    } catch (_) {
      if (mounted) toast(context, t(ref, 'import_failed'));
    }
  }

  Future<void> _startScan() async {
    final source = _sourceCtrl.text.trim();
    final dest = _destCtrl.text.trim();
    if (source.isEmpty) {
      toast(context, t(ref, 'enter_source'));
      return;
    }
    if (dest.isEmpty) {
      toast(context, t(ref, 'enter_dest'));
      return;
    }
    setState(() => _scanning = true);

    // 持久化 last dirs
    final config = ref.read(configProvider);
    final updated = config.copyWith(lastSourceDir: source, lastDestParent: dest);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);

    final err = await ref.read(scanControllerProvider.notifier).scan(
          source: [source],
          sourceRoot: source,
          destinationParent: dest,
          recursive: _recursive,
          config: ref.read(configProvider),
        );
    if (!mounted) return;
    setState(() => _scanning = false);
    if (err != null) {
      toast(context, t(ref, err));
      return;
    }
    Navigator.pushNamed(context, AppRoutes.sort);
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final profile = config.activeProfileData;
    return Scaffold(
      appBar: AppBar(
        title: _buildLogo(),
        actions: [
          TextButton(
            onPressed: () => setLanguage(
                ref, ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh'),
            child: Text(ref.read(currentLanguageProvider) == 'zh' ? '中文' : 'EN'),
          ),
        ],
      ),
      body: Stack(
        children: [
          ResponsiveBuilder(builder: (context, width) {
            final isWide = width > 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildLeftColumn(profile)),
                        const SizedBox(width: 40),
                        Expanded(child: _buildRightColumn(profile)),
                      ],
                    )
                  : Column(
                      children: [
                        _buildLeftColumn(profile),
                        const SizedBox(height: 32),
                        _buildRightColumn(profile),
                      ],
                    ),
            );
          }),
          if (_scanning)
            LoadingOverlayBuilder(message: t(ref, 'scanning')),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('SORT',
            style: TextStyle(
                fontFamily: AppFonts.syne,
                fontWeight: FontWeight.w800,
                fontSize: 22)),
        Text('R',
            style: TextStyle(
                fontFamily: AppFonts.syne,
                fontWeight: FontWeight.w800,
                fontSize: 22,
                color: AppColors.accent)),
      ],
    );
  }

  // ───────────── 左列：目录 + Profile + 编辑器 ─────────────

  Widget _buildLeftColumn(Profile profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDirRow(),
        const SizedBox(height: 16),
        _buildStartButton(),
        const SizedBox(height: 32),
        _buildProfileSection(profile),
        const SizedBox(height: 24),
        FolderEditor(
          profile: profile,
          activeProfileName: ref.read(configProvider).activeProfile,
        ),
        const SizedBox(height: 24),
        ActionKeysEditor(actionKeys: profile.actionKeys),
      ],
    );
  }

  Widget _buildDirRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: t(ref, 'source_dir')),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sourceCtrl,
                style: const TextStyle(fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 13),
                decoration: InputDecoration(
                  hintText: t(ref, 'dir_ph'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: t(ref, 'browse_src'),
              onPressed: _browseSource,
              icon: const Icon(Icons.folder_open),
            ),
            IconButton(
              tooltip: t(ref, 'toggle_scan'),
              onPressed: () => setState(() => _recursive = !_recursive),
              icon: Icon(_recursive ? Icons.account_tree : Icons.list),
              color: _recursive ? AppColors.accent : AppColors.muted,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(_recursive ? t(ref, 'recursive') : t(ref, 'flat'),
            style: const TextStyle(
                fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 11, color: AppColors.muted)),
        const SizedBox(height: 20),
        _FieldLabel(text: t(ref, 'dest_parent')),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _destCtrl,
                onChanged: (v) => ref
                    .read(sessionControllerProvider.notifier)
                    .recomputeFolders(destinationParent: v),
                style: const TextStyle(fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 13),
                decoration: InputDecoration(hintText: t(ref, 'dest_ph')),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: t(ref, 'browse_dst'),
              onPressed: _browseDest,
              icon: const Icon(Icons.folder_open),
            ),
            IconButton(
              tooltip: t(ref, 'import_subdirs'),
              onPressed: _importSubdirs,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStartButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _scanning ? null : _startScan,
        child: Text(t(ref, 'start')),
      ),
    );
  }

  // ───────────── Profile 区 ─────────────

  Widget _buildProfileSection(Profile profile) {
    final config = ref.watch(configProvider);
    final names = config.profiles.keys.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: t(ref, 'profile_group')),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ProfileDropdown(
                value: config.activeProfile,
                items: names,
                onSelected: (v) async {
                  final err = await SetupController(ref).switchProfile(v);
                  if (err != null && mounted) toast(context, t(ref, err));
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: t(ref, 'new_profile_tt'),
              icon: const Icon(Icons.add),
              onPressed: () => _createProfileDialog(),
            ),
            IconButton(
              tooltip: t(ref, 'del_profile_tt'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteProfileDialog(config.activeProfile),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _createProfileDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(t(ref, 'enter_profile_name'),
              style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], fontSize: 14)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    final err = await SetupController(ref).createProfile(name);
    if (!mounted) return;
    if (err == null) {
      toast(context, t(ref, 'profile_created', [name]));
    } else {
      toast(context, t(ref, err, [name]));
    }
  }

  Future<void> _deleteProfileDialog(String name) async {
    final config = ref.read(configProvider);
    if (config.profiles.length <= 1) {
      toast(context, t(ref, 'keep_one_profile'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(t(ref, 'confirm_delete', [name]),
            style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = await SetupController(ref).deleteProfile(name);
    if (!mounted) return;
    if (err == null) {
      toast(context, t(ref, 'profile_deleted'));
    } else {
      toast(context, t(ref, err));
    }
  }

  // ───────────── 右列：文件夹预览 ─────────────

  Widget _buildRightColumn(Profile profile) {
    final dest = _destCtrl.text;
    final descriptors =
        ref.read(profilesServiceProvider).computeDestinationFolders(dest.isEmpty ? ref.read(configProvider).lastDestParent : dest, profile.folders);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: t(ref, 'dest_preview')),
        const SizedBox(height: 12),
        if (descriptors.isEmpty)
          Text(t(ref, 'enter_dest_parent'),
              style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted, fontSize: 12))
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: descriptors
                .map((d) => _FolderChip(
                      keyLabel: d.key,
                      label: d.label,
                      path: d.path,
                    ))
                .toList(),
          ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
            letterSpacing: 0.5));
  }
}

class _FolderChip extends StatelessWidget {
  const _FolderChip({required this.keyLabel, required this.label, required this.path});
  final String keyLabel;
  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(keyLabel,
                    style: const TextStyle(
                        fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.bg)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback, fontSize: 10, color: AppColors.muted)),
        ],
      ),
    );
  }
}

// ───────────── 响应式辅助 ─────────────

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

// 复用 LoadingOverlay 的便捷包装（带 dismiss 能力留给后续）
class LoadingOverlayBuilder extends StatelessWidget {
  const LoadingOverlayBuilder({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: AppColors.overlayBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
              const SizedBox(height: 16),
              Text(message,
                  style: const TextStyle(
                      fontFamily: 'Space Mono', height: 1.2, fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 13,
                      color: AppColors.text)),
            ],
          ),
        ),
      ),
    );
  }
}
