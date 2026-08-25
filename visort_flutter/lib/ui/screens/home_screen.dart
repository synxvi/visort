// Home 屏幕 —— 配置整理方案（对应前端 #screen-setup）
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
import 'package:visort_flutter/features/home/home_controller.dart';
import 'package:visort_flutter/shared/widgets/visort_logo.dart';
import 'package:visort_flutter/shared/widgets/profile_dropdown.dart';
import 'package:visort_flutter/shared/widgets/resume_button.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/screens/action_keys_editor.dart';
import 'package:visort_flutter/ui/screens/folder_editor.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late TextEditingController _sourceCtrl;
  late TextEditingController _destCtrl;
  bool _recursive = true;
  bool _scanning = false;

  /// Start 防并发闸门：persistedSummary/恢复弹窗的 async gap 期间 _scanning
  /// 仍为 false、按钮可再点，双击会并发进入两次扫描（双 push sort）。
  /// _scanning 置位后的窗口由其自身兜底（按钮禁用）。
  bool _scanInFlight = false;

  /// 是否有可恢复的整理会话(P2,顶部横条)。
  bool _resumeAvailable = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configProvider);
    _sourceCtrl = TextEditingController(text: config.lastSourceDir);
    _destCtrl = TextEditingController(
        text: config.lastDestParent.isNotEmpty
            ? config.lastDestParent
            : _defaultDestParent());
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkResumableSession());
    // P2:从 sort/review 返回 Home(pop 不重建本页)时重探横条。
    currentRouteName.addListener(_onRouteChanged);
  }

  /// 路由回到 Home 时重探横条(全局 RouteNameObserver 驱动)。
  void _onRouteChanged() {
    if (currentRouteName.value == AppRoutes.home) {
      _checkResumableSession();
    }
  }

  /// 探测持久化会话。显示条件 = **库里有已决策的会话**(同安卓 Home:
  /// 整理过就显示;清除只有「重新开始」覆写与滑动横条两条路)。
  Future<void> _checkResumableSession() async {
    final s = await ref
        .read(sessionControllerProvider.notifier)
        .persistedSummary();
    if (!mounted) return;
    setState(() => _resumeAvailable = s != null && s.decided > 0);
  }

  /// 横条滑除:丢弃持久化会话。
  void _onDismissResumeBanner() {
    ref.read(sessionControllerProvider.notifier).discardPersistedSession();
    setState(() => _resumeAvailable = false);
  }

  /// 恢复上次会话并落屏;pop 回来后重探横条显隐。
  Future<void> _resumeLastSession() async {
    final ok = await ref
        .read(sessionControllerProvider.notifier)
        .restoreLastSession();
    if (!mounted || !ok) return;
    setState(() => _resumeAvailable = false);
    // 完成态会话(在 Review 屏被杀)直达 Review;进 sort 会因「无当前图」
    // 黑屏(其自动跳 Review 只挂在决策完成回调上,恢复路径不经过)。
    final target =
        ref.read(sessionControllerProvider).isComplete ? '/review' : '/sort';
    await Navigator.of(context).pushNamed(target);
    await _checkResumableSession();
  }

  String _defaultDestParent() {
    // 对应 Python DEFAULT_DEST_PARENT = ~/Pictures
    return '';
  }

  /// Start 前恢复询问弹窗(安卓 Home 同款)。
  /// true=继续上次;false=重新开始;null=关掉弹窗(取消本次 Start)。
  Future<bool?> _askResumePersisted(
      ({int total, int decided, int currentIndex}) s) {
    return showCenterDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          t(ref, 'resume_found_title'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: AppFonts.cjkFallback,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
        content: Text(
          '${t(ref, 'resume_found_body_a')}${s.total}'
          '${t(ref, 'resume_found_body_b')}${s.decided}'
          '${t(ref, 'resume_found_body_c')}',
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: AppFonts.cjkFallback,
            fontSize: 13,
            color: AppColors.muted,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t(ref, 'resume_restart')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t(ref, 'resume_continue')),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    currentRouteName.removeListener(_onRouteChanged);
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
        if (mounted) toast(context, t(ref, 'no_subdirs'));
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
      final home = HomeController(ref);
      var imported = 0;
      for (final name in subdirs) {
        if (existingLabels.contains(name)) continue;
        final key = home.allocateKey(templates);
        templates.add(FolderTemplate(key: key, label: name));
        existingLabels.add(name);
        imported++;
      }
      if (imported == 0) {
        if (mounted) toast(context, t(ref, 'no_new_subdirs'));
        return;
      }
      await home.updateFolders(templates);
      if (mounted) toast(context, t(ref, 'imported_count', [imported]));
    } catch (_) {
      if (mounted) toast(context, t(ref, 'import_failed'));
    }
  }

  /// Start 入口：防并发闸门（见 _scanInFlight），实际流程在 _startScanInner。
  Future<void> _startScan() async {
    if (_scanInFlight) return;
    _scanInFlight = true;
    try {
      await _startScanInner();
    } finally {
      _scanInFlight = false;
    }
  }

  Future<void> _startScanInner() async {
    // P2:有未完成会话先问恢复(与安卓 Home 同款,避免 Start 重扫覆写丢决策)。
    final summary = await ref
        .read(sessionControllerProvider.notifier)
        .persistedSummary();
    if (summary != null && summary.decided > 0) {
      final resume = await _askResumePersisted(summary);
      if (!mounted || resume == null) return;
      if (resume) {
        final ok = await ref
            .read(sessionControllerProvider.notifier)
            .restoreLastSession();
        if (!mounted || !ok) return;
        setState(() => _resumeAvailable = false);
        // 完成态直达 Review(同 _resumeLastSession,黑屏规避)。
        final target = ref.read(sessionControllerProvider).isComplete
            ? AppRoutes.review
            : AppRoutes.sort;
        await Navigator.of(context).pushNamed(target);
        await _checkResumableSession();
        return;
      }
    }
    if (!mounted) return; // 恢复探测/弹窗是 async gap,原流程用 context 前先守卫
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
        // 语言下拉入口（桌面专属）：默认语言由 main() 首启按系统语言落定
        // （中文→zh，其余→en 兜底），此处提供手动切换，与设置页共用 setLanguage。
        title: const VisortLogo(),
        actions: [
          // 右缘 16 与 title(logo)距左 16 对称；下压对齐：小字号按钮在
          // AppBar 居中区里略偏上，垫 3px 让其文字底边与 22px logo 底边
          // 处于同一水平线。
          Padding(
            padding: const EdgeInsets.only(right: 16, bottom: 3),
            child: _buildLangToggle(),
          ),
        ],
      ),
      body: Stack(
        children: [
          ResponsiveBuilder(builder: (context, width) {
            final isWide = width > 900;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              // P2 会话恢复横条置顶(通栏,宽窄布局都在内容上方)。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isWide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _buildLeftColumn(profile)),
                        const SizedBox(width: 40),
                        Expanded(child: _buildRightColumn(profile)),
                      ],
                    )
                  else
                    Column(
                      children: [
                        _buildLeftColumn(profile),
                        const SizedBox(height: 32),
                        _buildRightColumn(profile),
                      ],
                    ),
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

  // ───────────── AppBar 右上角语言下拉 ─────────────
  // 样式对齐设置页 _PickerRow 的值态：muted 小字 + ▾；菜单复用
  // showSpringPopupFromAnchor（弹簧菜单，当前项 ✓）。

  Widget _buildLangToggle() {
    final lang = ref.watch(currentLanguageProvider);
    // Builder 取按钮自身 context：菜单锚点必须相对按钮定位（用 state 的
    // context 会拿到整个 Scaffold 的 RenderBox，坐标算到屏幕外、菜单
    // 弹在不可见位置——首版「点不开」的根因）。
    return Builder(builder: (btnCtx) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _openLangMenu(btnCtx),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(lang == 'zh' ? '中文' : 'EN',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontFamily: 'Space Mono', height: 1.2,
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 12,
                  )),
              const Icon(Icons.keyboard_arrow_down,
                  color: AppColors.muted, size: 16),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _openLangMenu(BuildContext anchorContext) async {
    final box = anchorContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final lang = ref.read(currentLanguageProvider);
    const options = [('zh', '中文'), ('en', 'English')];
    // 菜单宽度按内容测量（与设置页同算法）：padding×2 + 勾选位 + 间距 + 最宽文字。
    const style = TextStyle(
      fontFamily: 'Space Mono', height: 1.2,
      fontFamilyFallback: AppFonts.cjkFallback,
      fontSize: 14,
    );
    final scaler = MediaQuery.textScalerOf(context);
    double maxText = 0;
    for (final o in options) {
      final tp = TextPainter(
        text: TextSpan(text: o.$2, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > maxText) maxText = tp.width;
    }
    final menuWidth = 14 * 2 + 16 + 8 + maxText + 2;
    final menuTop = pos.dy + box.size.height + 4;
    final menuLeft = pos.dx + box.size.width - 6 - menuWidth; // 右缘对齐按钮文字右缘
    final selected = await showSpringPopupFromAnchor<String>(
      context: context,
      barrierLabel: 'lang',
      // 支点 = ▾ 中心（按钮右缘 - padding6 - ▾半宽8），菜单顶边。
      anchorGlobalDx: pos.dx + box.size.width - 14,
      anchorGlobalDy: menuTop,
      menuLeft: menuLeft,
      menuTop: menuTop,
      menuWidth: menuWidth,
      menuBuilder: (ctx) => Material(
        color: AppColors.surfaceElevated,
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // stretch：行拉满菜单宽——否则窄选项（如「中文」比 English 窄）
          // 的 hover 背景只盖自身内容宽，不满行。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final o in options)
              InkWell(
                onTap: () => Navigator.of(ctx).pop(o.$1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        child: o.$1 == lang
                            ? const Icon(Icons.check,
                                size: 16, color: AppColors.accent)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(o.$2,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontFamily: 'Space Mono', height: 1.2,
                            fontFamilyFallback: AppFonts.cjkFallback,
                            fontSize: 14,
                          )),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (selected != null) setLanguage(ref, selected);
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
    return Row(
      children: [
        // P2「继续」按钮:有可恢复记录时出现在开始左侧(桌面仅水平拖清除);
        // 无入场动画,出现即到位。
        if (_resumeAvailable) ...[
          ResumeButton(
            onResume: _resumeLastSession,
            onDismiss: _onDismissResumeBanner,
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: FilledButton(
            onPressed: _scanning ? null : _startScan,
            child: Text(t(ref, 'start')),
          ),
        ),
      ],
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
                  final err = await HomeController(ref).switchProfile(v);
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
            // 回车 = OK(与确认按钮同值提交)
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            decoration: const InputDecoration(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(t(ref, 'cancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(t(ref, 'ok')),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    final err = await HomeController(ref).createProfile(name);
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
              child: Text(t(ref, 'cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t(ref, 'delete_btn')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = await HomeController(ref).deleteProfile(name);
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
