// 安卓 Setup 屏幕（双模式分类）—— 统一 MediaStore 方案
//
// 两种分类模式（顶部 segmented control 切换）：
//   模式一 toAlbum（默认）：选源相册 + 选目标相册，move 改 RELATIVE_PATH 到目标相册
//   模式二 toNewDir：选源相册 + 输入父目录 + 编辑子目录，move 改 RELATIVE_PATH 到新建分类目录
//
// 数据流：
//   Setup 构建 List<FolderDescriptor>（path=RELATIVE_PATH）→ scan prebuiltFolders → session folders
//   Sort 底部按钮 = folders（两种模式统一）
//   Run 按 RELATIVE_PATH 分组批量 moveBatch（createWriteRequest）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/android_mediastore_file_system.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/scan/scan_controller.dart';
import 'package:sortr_flutter/shared/widgets/sort_toggle.dart';
import 'package:sortr_flutter/shared/widgets/toast.dart';
import 'package:sortr_flutter/ui/router.dart';

class SetupScreenAndroid extends ConsumerStatefulWidget {
  const SetupScreenAndroid({super.key});

  @override
  ConsumerState<SetupScreenAndroid> createState() => _SetupScreenAndroidState();
}

class _SetupScreenAndroidState extends ConsumerState<SetupScreenAndroid>
    with WidgetsBindingObserver {
  static const _channel = MediaStoreChannel();
  static const _keyOrder = 'ABCDEFGHIJ'; // 目标相册/子目录的快捷键分配

  // 相册数据
  List<MsBucket> _buckets = const [];
  Set<String> _sourceBucketIds = {};   // 源相册
  Set<String> _targetBucketIds = {};   // 模式二目标相册
  // 记录上次查询封面时用的排序，用于检测变化后重查
  SortBy? _lastCoverSortBy;
  bool? _lastCoverSortAsc;

  // 模式
  ClassifyMode _mode = ClassifyMode.toAlbum;

  // 模式一（toNewDir）配置
  final _parentCtrl = TextEditingController(text: '整理结果');
  final _parentFocus = FocusNode();
  List<String> _subDirs = ['保留', '待删'];

  bool _loading = false;
  bool _scanning = false;
  bool _permissionGranted = false;
  bool _manageMediaGranted = false;  // MANAGE_MEDIA 特殊权限（零弹窗媒体操作）
  String? _error;

  // 源/目标区折叠状态
  bool _sourceExpanded = true;
  bool _targetExpanded = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _parentFocus.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAndLoad());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _parentCtrl.dispose();
    _parentFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[Setup] lifecycle: $state, permissionGranted=$_permissionGranted');
    // app 从后台恢复前台（用户从系统设置授权后返回）→ 重新检测 MANAGE_MEDIA
    if (state == AppLifecycleState.resumed) {
      // 延迟 500ms 检测，确保系统权限状态已刷新
      Future.delayed(const Duration(milliseconds: 500), _recheckManageMedia);
    }
  }

  Future<void> _initAndLoad() async {
    setState(() => _loading = true);
    final granted = await _channel.hasPermission();
    if (!granted) {
      final ok = await _channel.requestPermission();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _permissionGranted = false;
          _loading = false;
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() => _permissionGranted = true);
    // 检测 MANAGE_MEDIA（零弹窗媒体操作，Android 12+）
    final manageMedia = await _channel.hasManageMedia();
    if (mounted) setState(() => _manageMediaGranted = manageMedia);
    await _loadBuckets();
  }

  Future<void> _requestManageMedia() async {
    await _channel.requestManageMedia();
    // 跳转后由 didChangeAppLifecycleState(resumed) 重新检测
  }

  /// 从系统设置返回后重新检测 MANAGE_MEDIA
  Future<void> _recheckManageMedia() async {
    final granted = await _channel.hasManageMedia();
    debugPrint('[Setup] _recheckManageMedia: granted=$granted, current=$_manageMediaGranted');
    if (mounted && granted != _manageMediaGranted) {
      setState(() => _manageMediaGranted = granted);
      if (granted) {
        toast(context, t(ref, 'manage_media_granted'));
      }
    }
  }

  Future<void> _loadBuckets() async {
    setState(() { _loading = true; _error = null; });
    try {
      final config = ref.read(configProvider);
      // 封面跟随「相册内排序」（photoSortBy），保证封面 = 进相册看到的第一张
      final buckets = await _channel.listBuckets(
        sortBy: config.photoSortBy,
        asc: config.photoSortAsc,
      );
      if (!mounted) return;

      // 从持久化 config 恢复模式/父目录/子目录（不恢复勾选状态）
      final profile = config.activeProfileData;

      setState(() {
        _buckets = buckets;
        // 记录本次查询封面用的排序，用于返回时检测变化
        _lastCoverSortBy = config.photoSortBy;
        _lastCoverSortAsc = config.photoSortAsc;
        // 每次进入应用不勾选任何目录（清空持久化的选择）
        _sourceBucketIds = <String>{};
        _targetBucketIds = <String>{};
        // 默认始终进入「相册间」模式（不恢复上次的模式，避免启动落在子目录模式）
        _mode = ClassifyMode.toAlbum;
        if (profile.newDirParent != null && profile.newDirParent!.isNotEmpty) {
          _parentCtrl.text = profile.newDirParent!;
        }
        // 从 folders 恢复子目录列表（仅当有持久化数据时）
        if (profile.folders.isNotEmpty) {
          _subDirs = profile.folders.map((f) => f.label).toList();
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  /// 检测相册内排序（photoSortBy）是否与上次查询封面时不同。
  /// 不同则静默重查（不触发 loading 闪烁），保证返回首页时封面已更新。
  void _maybeRefreshCovers() {
    final config = ref.read(configProvider);
    if (_lastCoverSortBy != config.photoSortBy ||
        _lastCoverSortAsc != config.photoSortAsc) {
      _lastCoverSortBy = config.photoSortBy;
      _lastCoverSortAsc = config.photoSortAsc;
      _refreshCovers();
    }
  }

  /// 静默刷新相册封面（保留勾选状态，仅更新 buckets 的 coverId）
  Future<void> _refreshCovers() async {
    try {
      final config = ref.read(configProvider);
      final buckets = await _channel.listBuckets(
        sortBy: config.photoSortBy,
        asc: config.photoSortAsc,
      );
      if (!mounted) return;
      setState(() {
        _buckets = buckets;
        // 保留勾选状态（_sourceBucketIds/_targetBucketIds 不清空）
      });
    } catch (_) {
      // 静默失败
    }
  }

  /// 模式二目标相册 → FolderDescriptor（path = RELATIVE_PATH）
  Future<List<FolderDescriptor>> _buildTargetAlbumFolders() async {
    final result = <FolderDescriptor>[];
    var keyIdx = 0;
    for (final bucket in _buckets) {
      if (!_targetBucketIds.contains(bucket.id)) continue;
      final relPath = await _channel.getBucketRelativePath(bucket.id);
      result.add(FolderDescriptor(
        key: keyIdx < _keyOrder.length ? _keyOrder[keyIdx] : '?',
        label: bucket.name,
        path: relPath ?? 'Pictures/${bucket.name}',
      ));
      keyIdx++;
    }
    return result;
  }

  /// 模式一新建分类 → FolderDescriptor（path = Pictures/父目录/子目录）
  List<FolderDescriptor> _buildNewDirFolders() {
    final parent = _parentCtrl.text.trim().isEmpty
        ? '整理结果'
        : _parentCtrl.text.trim();
    return _subDirs.where((s) => s.trim().isNotEmpty).toList().asMap().entries.map((e) {
      return FolderDescriptor(
        key: e.key < _keyOrder.length ? _keyOrder[e.key] : '?',
        label: e.value,
        path: 'Pictures/$parent/${e.value}',
      );
    }).toList();
  }

  Future<void> _startScan() async {
    if (_sourceBucketIds.isEmpty) {
      toast(context, t(ref, 'no_album_selected'));
      return;
    }
    // 按模式校验目标
    List<FolderDescriptor> folders;
    if (_mode == ClassifyMode.toAlbum) {
      if (_targetBucketIds.isEmpty) {
        toast(context, t(ref, 'no_target_album'));
        return;
      }
      setState(() => _scanning = true);
      folders = await _buildTargetAlbumFolders();
    } else {
      folders = _buildNewDirFolders();
      if (folders.isEmpty) {
        toast(context, t(ref, 'no_subdir'));
        return;
      }
      setState(() => _scanning = true);
    }

    final sourceIds = _sourceBucketIds.toList();

    // 持久化配置到 Profile
    final config = ref.read(configProvider);
    final oldProfile = config.activeProfileData;
    // 模式一的子目录列表存入 folders（label = 子目录名）
    final newFolders = _mode == ClassifyMode.toNewDir
        ? _subDirs.where((s) => s.trim().isNotEmpty).toList()
            .asMap()
            .entries
            .map((e) => FolderTemplate(
                  key: e.key < _keyOrder.length ? _keyOrder[e.key] : '?',
                  label: e.value.trim(),
                ))
            .toList()
        : oldProfile.folders;
    final newProfile = oldProfile.copyWith(
      classifyMode: _mode,
      targetAlbumIds: _targetBucketIds.toList(),
      newDirParent: _parentCtrl.text.trim(),
      folders: newFolders,
    );
    final newProfiles = Map<String, Profile>.from(config.profiles)
      ..[config.activeProfile] = newProfile;
    // destinationParent 的语义：根目录决策（kRootDestKey）会把图片直接移到这里。
    // - toNewDir：根目录 = 目标父目录本身 → RELATIVE_PATH 应为 'Pictures/<父目录>'，
    //   这样点「根目录」时图片会落到父目录（与子目录 'Pictures/<父>/<子>' 同级语义一致）。
    //   不能用 kImagesAuthority（那是 MediaStore 集合 authority，非法 RELATIVE_PATH，
    //   会导致 Kotlin contentResolver.update 返回 0 行 → 移动失败）。
    // - toAlbum：根目录按钮已隐藏（无父目录根概念），destinationParent 不会被消费，
    //   保留 kImagesAuthority 仅作占位。
    final newDirParent = _parentCtrl.text.trim().isEmpty
        ? '整理结果'
        : _parentCtrl.text.trim();
    final destParent = _mode == ClassifyMode.toNewDir
        ? 'Pictures/$newDirParent'
        : kImagesAuthority;
    final updated = config.copyWith(
      lastSourceDir: sourceIds.join(','),
      lastDestParent: destParent,
      profiles: newProfiles,
    );
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);

    final err = await ref.read(scanControllerProvider.notifier).scan(
          source: sourceIds,
          sourceRoot: kImagesAuthority,
          destinationParent: destParent,
          recursive: true,
          config: ref.read(configProvider),
          prebuiltFolders: folders,
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
    // 检测相册内排序是否变化（从相册返回时封面需更新）
    _maybeRefreshCovers();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        title: const _Logo(),
        actions: [
          TextButton(
            onPressed: () => setLanguage(
                ref, ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh'),
            child: Text(
                ref.read(currentLanguageProvider) == 'zh' ? '中文' : 'EN'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 模式切换 segmented control
            _buildModeSelector(),
            const Divider(color: AppColors.border, height: 1),
            // 主体
            Expanded(child: _buildBody()),
            // 底部 Start
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SegmentedButton<ClassifyMode>(
        // 激活态不显示默认 ✅，保留各模式自身 icon
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.text,
          selectedBackgroundColor: AppColors.accent,
          selectedForegroundColor: AppColors.bg,
        ),
        segments: [
          ButtonSegment(
            value: ClassifyMode.toAlbum,
            label: Text(t(ref, 'mode_to_album'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            icon: const Icon(Icons.swap_horiz, size: 18),
          ),
          ButtonSegment(
            value: ClassifyMode.toNewDir,
            label: Text(t(ref, 'mode_to_newdir'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
          ),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() => _mode = s.first),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (!_permissionGranted) return _buildPermissionDenied();
    if (_error != null) return _buildError();
    if (_buckets.isEmpty) {
      return Center(
          child: Text(t(ref, 'no_albums'),
              style: const TextStyle(color: AppColors.muted)));
    }
    return ListView(
      padding: const EdgeInsets.only(top: 2),
      children: [
        // MANAGE_MEDIA 引导（未授权时显示）
        if (!_manageMediaGranted) _buildManageMediaBanner(),
        // 源相册区（可折叠）
        _buildCollapsibleSection(
          title: t(ref, 'source_albums'),
          totalCount: _buckets.length,
          expanded: _sourceExpanded,
          onToggle: () => setState(() => _sourceExpanded = !_sourceExpanded),
          child: _buildBucketList(
            selectedIds: _sourceBucketIds,
            onToggle: (id) => setState(() {
              _sourceBucketIds.contains(id)
                  ? _sourceBucketIds.remove(id)
                  : _sourceBucketIds.add(id);
            }),
          ),
        ),
        // 区块间分隔：toAlbum 模式用流向分隔线（源→目标），
        // toNewDir 模式保持纯间距（目标区是配置面板，与相册列表视觉关系不同）
        // 注：源 header 底部 padding 已改对称(10)，此处 SizedBox 同步收紧 6 以维持原节奏
        if (_mode == ClassifyMode.toAlbum)
          _buildFlowDivider(sourceExpanded: _sourceExpanded)
        else
          SizedBox(height: _sourceExpanded ? 10 : 0),
        if (_mode == ClassifyMode.toAlbum)
          _buildCollapsibleSection(
            title: t(ref, 'target_albums'),
            totalCount: _buckets.length,
            expanded: _targetExpanded,
            onToggle: () =>
                setState(() => _targetExpanded = !_targetExpanded),
            child: _buildBucketList(
              selectedIds: _targetBucketIds,
              onToggle: (id) => setState(() {
                _targetBucketIds.contains(id)
                    ? _targetBucketIds.remove(id)
                    : _targetBucketIds.add(id);
              }),
            ),
          )
        else
          _buildNewDirConfig(),
      ],
    );
  }

  /// 源/目标相册间的流向分隔线：两端渐隐细线 + 中央 swap_horiz 图标锚点，
  /// 呼应 toAlbum「相册间」模式的移动语义（源 → 目标）。
  ///
  /// padding 随源区状态变化，保证分隔线始终落在两侧视觉重心的中点：
  /// - 折叠态：上方衔接源 header（272px，与目标 header 等高）→ 上下等距，分隔线天然居中
  /// - 展开态：上方衔接末位相册 tile（176px，比目标 header 矮）→ 上方多留补偿间距，
  ///   否则分隔线会紧贴 tile，而到目标标题的视觉距离偏大
  Widget _buildFlowDivider({required bool sourceExpanded}) {
    // 展开态：上 29（补偿末位 tile 偏矮，tile.vertical=4 已收紧）下 8；
    // 折叠态：上下各 2（header↔header 等高，收紧一半贴近两侧）
    final padTop = sourceExpanded ? 29.0 : 2.0;
    final padBottom = sourceExpanded ? 8.0 : 2.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, padTop, 16, padBottom),
      child: Row(
        children: [
          // 左渐隐线（边缘透明 → 中部 border 色）
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.border.withValues(alpha: 0),
                    AppColors.border,
                  ],
                ),
              ),
            ),
          ),
          // 中央图标锚点
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.accentWithOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.swap_horiz,
                size: 14, color: AppColors.accent.withValues(alpha: 0.7)),
          ),
          // 右渐隐线（中部 border 色 → 边缘透明）
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.border,
                    AppColors.border.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 可折叠区域：header（标题 + 总数 + 排序按钮）+ 动画展开的子内容。
  /// 用 AnimatedSize 实现展开/收起的平滑过渡，相邻区块自动顶上。
  Widget _buildCollapsibleSection({
    required String title,
    required int totalCount,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    final config = ref.read(configProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            // top:5（距顶部分隔线/模式切换的间距，按需再收紧 1/3）；
            // bottom:10（距下方内容/分隔线的呼吸间距）
            padding: const EdgeInsets.fromLTRB(16, 5, 8, 10),
            child: Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accentWithOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$totalCount',
                      style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                SortToggle(
                  sortBy: config.albumSortBy,
                  asc: config.albumSortAsc,
                  onChanged: _setAlbumSort,
                ),
              ],
            ),
          ),
        ),
        // 动画展开/收起：AnimatedSize 让高度平滑过渡
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: expanded
              ? child
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }

  /// 排序后的 bucket 列表渲染
  Widget _buildBucketList({
    required Set<String> selectedIds,
    required void Function(String id) onToggle,
  }) {
    final sorted = _sortedBuckets();
    return Column(
      children: sorted
          .map((b) => _SetupBucketTile(
                bucket: b,
                selected: selectedIds.contains(b.id),
                onCheckToggle: () => onToggle(b.id),
              ))
          .toList(),
    );
  }

  /// 按用户排序偏好返回 bucket 列表
  List<MsBucket> _sortedBuckets() {
    final config = ref.read(configProvider);
    final list = List<MsBucket>.of(_buckets);
    list.sort((a, b) {
      int cmp;
      switch (config.albumSortBy) {
        case SortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortBy.dateTaken:
        case SortBy.dateAdded:
          // bucket 无独立日期字段，按数量降序作为次要键保证稳定
          cmp = a.count.compareTo(b.count);
          break;
      }
      return config.albumSortAsc ? cmp : -cmp;
    });
    return list;
  }

  /// 切换相册列表排序并持久化。
  /// 注意：相册列表顺序由 Dart 内存排（_sortedBuckets），不影响封面。
  /// 封面跟随「相册内排序」(photoSortBy)，在 _loadBuckets 时决定。
  Future<void> _setAlbumSort(SortBy sortBy, bool asc) async {
    final config = ref.read(configProvider);
    final updated =
        config.copyWith(albumSortBy: sortBy, albumSortAsc: asc);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
    setState(() {});
  }

  /// MANAGE_MEDIA 权限引导横幅（未授权时显示）
  Widget _buildManageMediaBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accent2.withValues(alpha: 0.1),
        border: Border.all(color: AppColors.accent2.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: AppColors.accent2, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t(ref, 'manage_media_title'),
                    style: const TextStyle(
                        color: AppColors.accent2,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
                const SizedBox(height: 2),
                Text(t(ref, 'manage_media_hint'),
                    style: TextStyle(
                        color: AppColors.text.withValues(alpha: 0.7),
                        fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent2,
              foregroundColor: AppColors.bg,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(0, 0),
            ),
            onPressed: _requestManageMedia,
            child: Text(t(ref, 'enable'),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// 模式一（toNewDir）配置：父目录 + 子目录编辑
  Widget _buildNewDirConfig() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 父目录：标题 + 输入框（统一组件，与子目录行用相同的标题→输入框间距）
          _titledDirInput(
            title: '${t(ref, 'parent_dir')}  ·  Pictures/',
            controller: _parentCtrl,
            focusNode: _parentFocus,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          // 子目录标题行 + 加号
          Row(
            children: [
              _sectionTitle(t(ref, 'sub_dirs')),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _subDirs.add('')),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Icon(Icons.add_circle_outline,
                      color: AppColors.accent, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 子目录行列表
          ..._subDirs.asMap().entries.map((e) {
            final idx = e.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              // IntrinsicHeight：让字母块高度跟随输入框，消除右侧缺块
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 快捷键标签：正方形，高度跟随输入框
                    AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppColors.accentWithOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          idx < _keyOrder.length ? _keyOrder[idx] : '?',
                          style: const TextStyle(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w800,
                              fontSize: 13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 子目录名输入：删除图标内置 suffix，输入框撑满到右边界
                    Expanded(
                      child: _dirInputField(
                        controller: TextEditingController(text: e.value),
                        onChanged: (val) => _subDirs[idx] = val,
                        onDelete: _subDirs.length > 1
                            ? () => setState(() => _subDirs.removeAt(idx))
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          // 预览路径
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              _buildNewDirFolders().map((f) => f.path).join('\n'),
              style: const TextStyle(
                  color: AppColors.muted, fontFamily: 'SpaceMono', fontSize: 11),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// 区块标题文字（统一样式）
  Widget _sectionTitle(String text) {
    return Text(text,
        style: const TextStyle(
            color: AppColors.accent,
            fontWeight: FontWeight.w800,
            fontSize: 13));
  }

  /// 带标题的目录输入框（父目录用）。
  ///
  /// 关键：标题文字和输入框之间的间距用固定 SizedBox 控制，
  /// 不受 TextField/安卓 EditText 渲染高度差异影响。
  /// 与子目录行（_sectionTitle + SizedBox(8) + _dirInputField）使用相同间距。
  Widget _titledDirInput({
    required String title,
    required TextEditingController controller,
    FocusNode? focusNode,
    ValueChanged<String>? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle(title),
        const SizedBox(height: 8),
        _dirInputField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 目录输入框（父目录与子目录共用）。
  ///
  /// 纯 Flutter 原生 TextField + 单层 OutlineInputBorder（无外层 Container，
  /// 无嵌套双框）。父目录和子目录用完全相同的组件 + InputDecoration，
  /// 渲染必然一致。Pictures/ 提示在标题显示。
  Widget _dirInputField({
    required TextEditingController controller,
    FocusNode? focusNode,
    ValueChanged<String>? onChanged,
    VoidCallback? onDelete,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: const TextStyle(color: AppColors.text, fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        filled: true,
        fillColor: AppColors.surface,
        // 子目录行的删除图标放在输入框内部右侧（suffix），
        // 这样输入框本身撑满整行宽度，右边界与父目录输入框对齐。
        suffixIcon: onDelete == null
            ? null
            : IconButton(
                icon: const Icon(Icons.remove_circle_outline,
                    color: AppColors.danger, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onDelete,
                tooltip: '删除',
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
      onChanged: onChanged,
    );
  }

  Widget _buildBottomBar() {
    final canStart = _sourceBucketIds.isNotEmpty &&
        ((_mode == ClassifyMode.toAlbum && _targetBucketIds.isNotEmpty) ||
            (_mode == ClassifyMode.toNewDir &&
                _subDirs.any((s) => s.trim().isNotEmpty)));
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.all(16),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                _statusText(),
                style: TextStyle(
                  fontFamily: 'SpaceMono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 12,
                  color: canStart ? AppColors.accent : AppColors.muted,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.bg,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: (canStart && !_scanning) ? _startScan : null,
              child: _scanning
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.bg),
                    )
                  : Text(t(ref, 'start'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText() {
    if (_mode == ClassifyMode.toAlbum) {
      return '${t(ref, 'source_count', [_sourceBucketIds.length])} · '
          '${t(ref, 'target_count', [_targetBucketIds.length])}';
    }
    final validSubs = _subDirs.where((s) => s.trim().isNotEmpty).length;
    return '${t(ref, 'source_count', [_sourceBucketIds.length])} · '
        '${t(ref, 'subdir_count', [validSubs])}';
  }

  Widget _buildPermissionDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 48, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(t(ref, 'permission_needed'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.text, fontSize: 14)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _initAndLoad,
              child: Text(t(ref, 'grant_permission')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.danger),
            const SizedBox(height: 12),
            SelectableText(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _loadBuckets, child: Text(t(ref, 'retry'))),
          ],
        ),
      ),
    );
  }
}

/// 单个相册行（Setup 用）：左封面 + 名称（点击进相册浏览）+ 右侧勾选框
///
/// 交互分区：
///   - 封面缩略图 + 名称区域 → 进入相册内浏览（AlbumScreen）
///   - 右侧 Checkbox → 勾选/取消勾选（作为源/目标相册）
class _SetupBucketTile extends StatelessWidget {
  const _SetupBucketTile({
    required this.bucket,
    required this.selected,
    required this.onCheckToggle,
  });
  final MsBucket bucket;
  final bool selected;
  final VoidCallback onCheckToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // vertical:4：tile 上下间距（含首尾 tile 与标题/分隔线的衔接），进一步收紧
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // 封面缩略图 + 名称：点击进入相册浏览
          Expanded(
            child: InkWell(
              onTap: () => Navigator.pushNamed(context, AppRoutes.album,
                  arguments: {
                    'bucketId': bucket.id,
                    'bucketName': bucket.name,
                  }),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  _CoverThumb(coverId: bucket.coverId, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bucket.name,
                          style: TextStyle(
                            fontFamily: 'SpaceMono',
                            fontFamilyFallback: AppFonts.cjkFallback,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppColors.text.withValues(alpha: 0.95),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text('${bucket.count}',
                            style: const TextStyle(
                                fontFamily: 'SpaceMono',
                                fontSize: 10,
                                color: AppColors.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 右侧勾选框（方形圆角 checkbox 样式 + 扩大热区）
          InkWell(
            onTap: onCheckToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: selected ? AppColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? AppColors.accent : AppColors.muted,
                    width: 2,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check,
                        color: AppColors.bg, size: 18)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面缩略图（正方形，圆角）。无封面时显示占位图标。
class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.coverId, required this.size});
  final String? coverId;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (coverId == null || coverId!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(Icons.photo_outlined,
            color: AppColors.muted, size: 20),
      );
    }
    final ref = imageRefFromMediaStoreId(coverId!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image(
        image: buildThumbnailProvider(ref, size: 160),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (ctx, error, stack) => Container(
          width: size,
          height: size,
          color: AppColors.surface,
          child: const Icon(Icons.broken_image_outlined,
              color: AppColors.muted, size: 20),
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
                fontFamily: 'Syne',
                fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w800,
                fontSize: 22)),
        Text('R',
            style: TextStyle(
                fontFamily: 'Syne',
                fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w800,
                fontSize: 22,
                color: AppColors.accent)),
      ],
    );
  }
}
