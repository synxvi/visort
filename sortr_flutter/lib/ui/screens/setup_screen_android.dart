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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/config/profiles_service.dart';
import 'package:sortr_flutter/core/fs/android_mediastore_file_system.dart';
import 'package:sortr_flutter/core/fs/image_loader.dart';
import 'package:sortr_flutter/core/fs/mediastore_channel.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/scan/scan_controller.dart';
import 'package:sortr_flutter/shared/widgets/non_modal_menu.dart';
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
  /// 右上角 ⋮ 按钮 key：Overlay 菜单定位（从按钮下方弹出，不遮挡按钮）
  final GlobalKey _menuBtnKey = GlobalKey();

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
  // 子目录列表的 AnimatedList key（驱动增删入场/退场动画）
  final _subDirsKey = GlobalKey<AnimatedListState>();

  bool _loading = false;
  bool _scanning = false;
  bool _permissionGranted = false;
  bool _manageMediaGranted = false;  // MANAGE_MEDIA 特殊权限（零弹窗媒体操作）
  String? _error;

  // 源/目标区折叠状态
  bool _sourceExpanded = true;
  bool _targetExpanded = true;

  /// 主界面滚动信号：非模态菜单监听它，滚动时自动收回。
  final _isScrolling = ValueNotifier<bool>(false);
  /// 当前非模态菜单控制器（收回用）
  NonModalMenuController? _menuCtl;

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
    _menuCtl?.close();
    _isScrolling.dispose();
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

  /// 右上角 3 点菜单：收藏 / 回收站快捷入口（相册浏览走首页列表直接点）。
  void _onMenuSelected(String value) {
    if (value == 'favorites') {
      Navigator.pushNamed(context, AppRoutes.album,
          arguments: const {'favoritesOnly': true});
    } else if (value == 'trash') {
      Navigator.pushNamed(context, AppRoutes.album,
          arguments: const {'trashedOnly': true});
    } else if (value == 'settings') {
      Navigator.pushNamed(context, AppRoutes.settings);
    }
  }

  /// 右上角 ⋮ 菜单：非模态浮层——从按钮右下角弹性展开，不阻塞主界面滚动。
  /// 主界面开始滚动时菜单自动收回（通过 _isScrolling 信号驱动）。
  void _showOverflowMenu() {
    // toggle：菜单已展开则收回（播放收回动画），否则新建展开。
    // 避免重复点击时关旧+开新导致展开动画重播（不符合操作预期）。
    if (_menuCtl != null && !_menuCtl!.isClosed) {
      _menuCtl!.close();
      return;
    }
    const menuWidth = 184.0;
    _menuCtl = showNonModalMenu(
      context: context,
      anchorKey: _menuBtnKey,
      menuWidth: menuWidth,
      isScrolling: _isScrolling,
      menuBuilder: (ctx) => Material(
        color: AppColors.surfaceElevated,
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildMenuItem(
              ctx,
              Icons.favorite,
              AppColors.text,
              t(ref, 'favorites_title'),
              onTap: () {
                _menuCtl?.close();
                _onMenuSelected('favorites');
              },
            ),
            _buildMenuItem(
              ctx,
              Icons.delete_outline,
              AppColors.text,
              t(ref, 'trash_title'),
              onTap: () {
                _menuCtl?.close();
                _onMenuSelected('trash');
              },
            ),
            _buildMenuItem(
              ctx,
              Icons.settings_outlined,
              AppColors.text,
              t(ref, 'settings_title'),
              onTap: () {
                _menuCtl?.close();
                _onMenuSelected('settings');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 菜单单项：图标 + 文本；点击后调用 [onTap]（由调用方负责关闭菜单 + 选中处理）。
  Widget _buildMenuItem(
    BuildContext ctx,
    IconData icon,
    Color iconColor,
    String label, {
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 12),
              Text(label,
                  style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: AppFonts.cjkFallback,
                      color: AppColors.text,
                      fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 检测相册内排序是否变化（从相册返回时封面需更新）
    _maybeRefreshCovers();
    // 首页（根路由）右滑/返回：等效 Home 键回桌面（task 保留后台，不 finish）。
    // 需要 MainActivity 的 sortr/app channel 配合 moveTaskToBack。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          const MethodChannel('sortr/app').invokeMethod('moveTaskToBack');
        }
      },
      child: Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        title: InkWell(
          onTap: () => setLanguage(
              ref, ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh'),
          borderRadius: BorderRadius.circular(8),
          child: const _Logo(),
        ),
        actions: [
          IconButton(
            key: _menuBtnKey,
            icon: const Icon(Icons.more_vert, color: AppColors.text),
            tooltip: t(ref, 'gallery_manage'),
            onPressed: _showOverflowMenu,
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
                style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
            icon: const Icon(Icons.swap_horiz, size: 18),
          ),
          ButtonSegment(
            value: ClassifyMode.toNewDir,
            label: Text(t(ref, 'mode_to_newdir'),
                style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
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
              style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted)));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification) {
          _isScrolling.value = true;
        } else if (n is ScrollEndNotification) {
          _isScrolling.value = false;
        }
        return false;
      },
      child: ListView(
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
        // 目标区随模式交叉切换：
        //   toAlbum = 流向分隔线 + 目标相册折叠区
        //   toNewDir = 间距 + 新建目录配置面板
        // 外层 AnimatedSize 平滑过渡两模式的高度差，内层 AnimatedSwitcher
        // 做交叉淡入淡出 + 轻微缩放（fade-through 语义，呼应模式切换）。
        AnimatedSize(
          duration: 300.ms,
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: 280.ms,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) {
              final scale = Tween<double>(begin: 0.97, end: 1.0).animate(
                CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
              );
              return FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: scale, child: child),
              );
            },
            // 自定义 layoutBuilder：新旧 child 顶部对齐。默认 alignment.center 在
            // 变高场景会让较短内容垂直居中悬浮，两模式高度差大时元素上下跳动。
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                ...previousChildren,
                ?currentChild,
              ],
            ),
            child: KeyedSubtree(
              key: ValueKey(_mode),
              child: _mode == ClassifyMode.toAlbum
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildFlowDivider(sourceExpanded: _sourceExpanded),
                        _buildCollapsibleSection(
                          title: t(ref, 'target_albums'),
                          totalCount: _buckets.length,
                          expanded: _targetExpanded,
                          onToggle: () => setState(
                              () => _targetExpanded = !_targetExpanded),
                          child: _buildBucketList(
                            selectedIds: _targetBucketIds,
                            onToggle: (id) => setState(() {
                              _targetBucketIds.contains(id)
                                  ? _targetBucketIds.remove(id)
                                  : _targetBucketIds.add(id);
                            }),
                          ),
                        ),
                      ],
                    )
                  : Padding(
                      // 展开态 top:20 对齐配置面板内区块分隔（父目录输入框→子目录
                      // 标题用 SizedBox(20)），让末位相册→「父目录」标题间距与面板内一致；
                      // 折叠态 top:0（源 header bottom:10 已提供标题间间距）。
                      padding: EdgeInsets.only(
                          top: _sourceExpanded ? 20.0 : 0.0),
                      child: _buildNewDirConfig(),
                    ),
            ),
          ),
        ),
        ],
      ),
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
    // 展开态：上 12（末位 tile 与分隔线的间距，网格 vertical padding 已为 0）下 8；
    // 折叠态：上下各 2（header↔header 等高，收紧一半贴近两侧）
    final padTop = sourceExpanded ? 12.0 : 2.0;
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
            // bottom:6（距下方内容/分隔线收紧）
            padding: const EdgeInsets.fromLTRB(16, 5, 8, 6),
            child: Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: AppFonts.cjkFallback,
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 13, height: 1.1)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accentWithOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$totalCount',
                      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
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
                const SizedBox(width: 4),
                // 展开/折叠指示箭头，随下方内容同步旋转（180°）。
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0.0,
                  duration: 200.ms,
                  curve: Curves.easeOutCubic,
                  child: const Icon(Icons.expand_more,
                      size: 20, color: AppColors.accent),
                ),
              ],
            ),
          ),
        ),
        // 动画展开/收起：AnimatedSize 平滑过渡高度（easeOutCubic 更现代，快进慢出）；
        // 展开瞬间内容用 flutter_animate 淡入，收起时直接收回。
        AnimatedSize(
          duration: 240.ms,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? child.animate().fadeIn(duration: 200.ms)
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
    final config = ref.watch(configProvider);
    final sorted = _sortedBuckets();
    final isGrid = config.homeLayout == HomeLayout.grid;
    final tiles = sorted
        .map((b) => _SetupBucketTile(
              key: ValueKey(b.id),
              bucket: b,
              selected: selectedIds.contains(b.id),
              onCheckToggle: () => onToggle(b.id),
              grid: isGrid,
            ))
        .toList();
    if (isGrid) {
      return GridView.count(
        crossAxisCount: config.homeGridColumns,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        childAspectRatio: 0.72,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        children: tiles,
      );
    }
    return Column(children: tiles);
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
        case SortBy.dateCreated:
          cmp = a.dateCreatedMs.compareTo(b.dateCreatedMs);
          break;
        case SortBy.dateModified:
          cmp = a.dateModifiedMs.compareTo(b.dateModifiedMs);
          break;
        case SortBy.dateTrashed:
          // 相册（bucket）无删除日期概念；回退创建时间。
          cmp = a.dateCreatedMs.compareTo(b.dateCreatedMs);
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
                    style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                        color: AppColors.accent2,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
                const SizedBox(height: 2),
                Text(t(ref, 'manage_media_hint'),
                    style: TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
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
                style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], fontSize: 11, fontWeight: FontWeight.w700)),
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
                onTap: _addSubDir,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Icon(Icons.add_circle_outline,
                      color: AppColors.accent, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 子目录行列表（AnimatedList：增删带入场/退场动画）
          AnimatedList(
            key: _subDirsKey,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            initialItemCount: _subDirs.length,
            itemBuilder: (ctx, idx, animation) =>
                _buildSubDirRow(idx, _subDirs[idx], animation),
          ),
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
                  color: AppColors.muted, fontFamily: 'Space Mono', height: 1.2, fontSize: 11),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  /// 新增子目录行（同步数据后通知 AnimatedList 插入，触发入场动画）。
  void _addSubDir() {
    final newIdx = _subDirs.length;
    setState(() => _subDirs.add(''));
    _subDirsKey.currentState?.insertItem(newIdx);
  }

  /// 删除子目录行（保存被删行数据渲染退场动画，再移除数据）。
  void _removeSubDir(int idx) {
    if (_subDirs.length <= 1) return;
    final removed = _subDirs[idx];
    _subDirsKey.currentState?.removeItem(
      idx,
      (ctx, animation) => _buildSubDirRow(idx, removed, animation),
    );
    setState(() => _subDirs.removeAt(idx));
  }

  /// 单个子目录行（AnimatedList 入场/退场共用）：SizeTransition + FadeTransition。
  Widget _buildSubDirRow(
      int idx, String value, Animation<double> animation) {
    return SizeTransition(
      sizeFactor: animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: animation,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
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
                      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                          color: AppColors.accent,
                          fontWeight: FontWeight.w800,
                          fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // 子目录名输入：删除图标内置 suffix
                Expanded(
                  child: _dirInputField(
                    controller: TextEditingController(text: value),
                    onChanged: (val) => _subDirs[idx] = val,
                    onDelete: _subDirs.length > 1
                        ? () => _removeSubDir(idx)
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 区块标题文字（统一样式）
  Widget _sectionTitle(String text) {
    return Text(text,
        style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
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
      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.text, fontSize: 14),
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
                  fontFamily: 'Space Mono', height: 1.2,
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
                      style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'],
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
                style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.text, fontSize: 14)),
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
                style: const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.danger, fontSize: 12)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _loadBuckets, child: Text(t(ref, 'retry'))),
          ],
        ),
      ),
    );
  }
}

/// 单个相册行（Setup 用）：左封面 + 名称（点击进相册浏览）+ 右侧圆点勾选。
///
/// 交互分区：
///   - 封面缩略图 + 名称区域 → 进入相册内浏览（AlbumScreen）
///   - 右侧圆点 → 勾选/取消勾选（作为源/目标相册）
/// 选中反馈：圆点变实心 + 选中瞬间扩散波动环 + 整行 accent 淡背景高亮，
/// 让用户清晰知道哪一行是待操作项。
class _SetupBucketTile extends StatefulWidget {
  const _SetupBucketTile({
    super.key,
    required this.bucket,
    required this.selected,
    required this.onCheckToggle,
    this.grid = false,
  });
  final MsBucket bucket;
  final bool selected;
  final VoidCallback onCheckToggle;
  final bool grid;

  @override
  State<_SetupBucketTile> createState() => _SetupBucketTileState();
}

class _SetupBucketTileState extends State<_SetupBucketTile>
    with SingleTickerProviderStateMixin {
  // 选中波动环：selected 由 false→true 时播放一次（从圆点向外扩散并淡出）。
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );

  @override
  void didUpdateWidget(covariant _SetupBucketTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) {
      _ripple.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.grid) return _buildGrid();
    final selected = widget.selected;
    return Padding(
      // vertical:2：tile 上下间距（收紧，相邻 tile 间距 4px）
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          // 封面缩略图 + 名称：点击进入相册浏览；选中时整行 accent 淡背景高亮
          Expanded(
            child: InkWell(
              onTap: () => Navigator.pushNamed(context, AppRoutes.album,
                  arguments: {
                    'bucketId': widget.bucket.id,
                    'bucketName': widget.bucket.name,
                    'bucketCount': widget.bucket.count,
                  }),
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    _CoverThumb(coverId: widget.bucket.coverId, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.bucket.name,
                            style: TextStyle(
                              fontFamily: 'Space Mono', height: 1.2,
                              fontFamilyFallback: AppFonts.cjkFallback,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: AppColors.text.withValues(alpha: 0.95),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text('${widget.bucket.count}',
                              style: const TextStyle(
                                  fontFamily: 'Space Mono', height: 1.2,
                                  fontSize: 10,
                                  color: AppColors.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 圆点勾选 + 选中波动环
          InkWell(
            onTap: widget.onCheckToggle,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 选中瞬间向外扩散的波动环（播放中才显示）
                    AnimatedBuilder(
                      animation: _ripple,
                      builder: (ctx, _) {
                        final t = _ripple.value;
                        if (t == 0.0 || t == 1.0) {
                          return const SizedBox.shrink();
                        }
                        return Container(
                          width: 20 + t * 44,
                          height: 20 + t * 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.accent
                                  .withValues(alpha: (1 - t) * 0.7),
                              width: 2,
                            ),
                          ),
                        );
                      },
                    ),
                    // 圆点本体：未选空心圆，选中实心圆 + 内部 bg 小点（略放大弹出）
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      width: selected ? 20 : 18,
                      height: selected ? 20 : 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected
                            ? AppColors.accent
                            : Colors.transparent,
                        border: Border.all(
                          color:
                              selected ? AppColors.accent : AppColors.muted,
                          width: 2,
                        ),
                      ),
                      child: selected
                          ? Center(
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.bg,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  // ── 网格态：竖向 tile（封面 + 名称 + 角标勾选），与列表态共用波动环。
  void _openAlbum() {
    Navigator.pushNamed(context, AppRoutes.album, arguments: {
      'bucketId': widget.bucket.id,
      'bucketName': widget.bucket.name,
      'bucketCount': widget.bucket.count,
    });
  }

  Widget _buildGrid() {
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: _openAlbum,
                  child: LayoutBuilder(
                    builder: (ctx, c) => _CoverThumb(
                        coverId: widget.bucket.coverId, size: c.maxWidth),
                  ),
                ),
                if (selected)
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.accent, width: 2.5),
                      ),
                    ),
                  ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  // IgnorePointer：点击数量 badge 穿透到下方封面，同样进入相册
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${widget.bucket.count}',
                          style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              fontFamily: 'Space Mono', height: 1.2)),
                    ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: widget.onCheckToggle,
                    behavior: HitTestBehavior.opaque,
                    child: _buildGridCheck(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _openAlbum,
            behavior: HitTestBehavior.opaque,
            child: Text(
              widget.bucket.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Space Mono', height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                color: AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 网格态勾选角标：未选半透明圆，选中 accent 实心 + 勾 + 波动环。
  Widget _buildGridCheck() {
    final selected = widget.selected;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _ripple,
            builder: (ctx, _) {
              final t = _ripple.value;
              if (t == 0.0 || t == 1.0) return const SizedBox.shrink();
              return Container(
                width: 18 + t * 40,
                height: 18 + t * 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.accent
                          .withValues(alpha: (1 - t) * 0.7),
                      width: 2),
                ),
              );
            },
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: selected ? 18 : 16,
            height: selected ? 18 : 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? AppColors.accent
                  : Colors.black.withValues(alpha: 0.4),
              border: Border.all(
                  color: selected ? AppColors.accent : Colors.white54,
                  width: 2),
            ),
            child: selected
                ? const Center(
                    child: Icon(Icons.check, size: 12, color: AppColors.bg),
                  )
                : null,
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
        image: buildThumbnailProvider(ref, size: 300),
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
