// 安卓 Home 屏幕（双模式分类）—— 统一 MediaStore 方案
//
// 两种分类模式（顶部 segmented control 切换）：
//   模式一 toAlbum（默认）：选源相册 + 选目标相册，move 改 RELATIVE_PATH 到目标相册
//   模式二 toNewDir：选源相册 + 输入父目录 + 编辑子目录，move 改 RELATIVE_PATH 到新建分类目录
//
// 数据流：
//   Home 构建 List<FolderDescriptor>（path=RELATIVE_PATH）→ scan prebuiltFolders → session folders
//   Sort 底部按钮 = folders（两种模式统一）
//   Run 按 RELATIVE_PATH 分组批量 moveBatch（createWriteRequest）

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/profiles_service.dart';
import 'package:visort_flutter/core/fs/android_mediastore_file_system.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/scan/scan_controller.dart';
import 'package:visort_flutter/shared/widgets/non_modal_menu.dart';
import 'package:visort_flutter/shared/widgets/sort_toggle.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'album_flight.dart';

class HomeScreenAndroid extends ConsumerStatefulWidget {
  const HomeScreenAndroid({super.key});

  @override
  ConsumerState<HomeScreenAndroid> createState() => _HomeScreenAndroidState();
}

class _HomeScreenAndroidState extends ConsumerState<HomeScreenAndroid>
    with WidgetsBindingObserver {
  static const _channel = MediaStoreChannel();
  static const _keyOrder = 'ABCDEFGHIJ'; // 目标相册/子目录的快捷键分配
  /// 右上角 ⋮ 按钮 key：Overlay 菜单定位（从按钮下方弹出，不遮挡按钮）
  final GlobalKey _menuBtnKey = GlobalKey();

  // 相册数据
  List<MsBucket> _buckets = const [];
  Set<String> _sourceBucketIds = {}; // 源相册
  Set<String> _targetBucketIds = {}; // 模式二目标相册
  // 记录上次查询封面时用的排序，用于检测变化后重查
  SortBy? _lastCoverSortBy;
  bool? _lastCoverSortAsc;

  // 模式
  ClassifyMode _mode = ClassifyMode.toNewDir;
  // 模式切换方向(抽屉滑动):正向 toAlbum→toNewDir(新从右进/旧向左出),反向反之。
  // 点击 SegmentedButton 与左右滑动手势共同维护,transitionBuilder 据此定向。
  bool _slideForward = true;

  // 模式一（toNewDir）配置
  final _parentCtrl = TextEditingController(text: '');
  final _parentFocus = FocusNode();
  List<String> _subDirs = ['', ''];
  // 子目录列表的 AnimatedList key（驱动增删入场/退场动画）
  final _subDirsKey = GlobalKey<AnimatedListState>();
  // toNewDir 编辑持久化防抖 timer（避免每个按键都写盘）
  Timer? _persistTimer;

  bool _loading = false;
  bool _scanning = false;
  bool _permissionGranted = false;
  bool _manageMediaGranted = false; // MANAGE_MEDIA 特殊权限（零弹窗媒体操作）
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
    _persistTimer?.cancel();
    _parentCtrl.dispose();
    _parentFocus.dispose();
    _menuCtl?.close();
    _isScrolling.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint(
      '[Home] lifecycle: $state, permissionGranted=$_permissionGranted',
    );
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
    debugPrint(
      '[Home] _recheckManageMedia: granted=$granted, current=$_manageMediaGranted',
    );
    if (mounted && granted != _manageMediaGranted) {
      setState(() => _manageMediaGranted = granted);
      if (granted) {
        toast(context, t(ref, 'manage_media_granted'));
      }
    }
  }

  Future<void> _loadBuckets() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
        // 默认进入「子目录」模式（toNewDir），不恢复上次模式
        _mode = ClassifyMode.toNewDir;
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
      setState(() {
        _loading = false;
        _error = e.toString();
      });
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
      result.add(
        FolderDescriptor(
          key: keyIdx < _keyOrder.length ? _keyOrder[keyIdx] : '?',
          label: bucket.name,
          path: relPath ?? 'Pictures/${bucket.name}',
        ),
      );
      keyIdx++;
    }
    return result;
  }

  /// 模式一新建分类 → FolderDescriptor（path = Pictures/父目录/子目录）
  List<FolderDescriptor> _buildNewDirFolders() {
    final parent = _parentCtrl.text.trim().isEmpty
        ? 'Visort'
        : _parentCtrl.text.trim();
    return _subDirs.asMap().entries.map((e) {
      final label = e.value.trim().isEmpty
          ? 'folder${e.key + 1}'
          : e.value.trim();
      return FolderDescriptor(
        key: e.key < _keyOrder.length ? _keyOrder[e.key] : '?',
        label: label,
        path: 'Pictures/$parent/$label',
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
        ? _subDirs
              .asMap()
              .entries
              .map(
                (e) => FolderTemplate(
                  key: e.key < _keyOrder.length ? _keyOrder[e.key] : '?',
                  label: e.value.trim(),
                ),
              )
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
        ? 'Visort'
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

    final err = await ref
        .read(scanControllerProvider.notifier)
        .scan(
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
  Future<void> _onMenuSelected(String value) async {
    if (value == 'favorites') {
      await Navigator.pushNamed(
        context,
        AlbumRoutes.album,
        arguments: const {'favoritesOnly': true},
      );
    } else if (value == 'trash') {
      await Navigator.pushNamed(
        context,
        AlbumRoutes.album,
        arguments: const {'trashedOnly': true},
      );
    } else if (value == 'settings') {
      Navigator.pushNamed(context, AppRoutes.settings);
      return;
    }
    // 收藏/回收站视图返回：可能发生了恢复/彻底删除，刷新首页封面/数量。
    _refreshCovers();
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
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.text,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    // 检测相册内排序是否变化（从相册返回时封面需更新）
    _maybeRefreshCovers();
    // 首页（根路由）返回:勾选态下先清空所有勾选(不退桌面);无勾选再回桌面。
    // 对标系统相册:点返回先取消选择,再按一次才退出。
    // 无勾选时走 moveTaskToBack(task 保留后台,不 finish),需 visort/app channel。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_sourceBucketIds.isNotEmpty || _targetBucketIds.isNotEmpty) {
          setState(() {
            _sourceBucketIds.clear();
            _targetBucketIds.clear();
          });
        } else {
          const MethodChannel('visort/app').invokeMethod('moveTaskToBack');
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.text,
          title: InkWell(
            onTap: () => setLanguage(
              ref,
              ref.read(currentLanguageProvider) == 'zh' ? 'en' : 'zh',
            ),
            borderRadius: BorderRadius.circular(8),
            child: const _Logo(),
          ),
          actions: [
            // 相册排序（源/目标 section 共用同一排序状态 albumSortBy/Asc）：
            // 从 section 标题整合到 AppBar，置于 ⋮ 左侧。section 内重复的 SortToggle 已移除。
            // Transform.translate 右移 SortToggle：内部 Padding(right:5) 让 icon 偏左，
            // 多 action 场景下视觉离 ⋮ 偏远，translate 抵消使其靠近 ⋮（gallery/album 里
            // SortToggle 是唯一 action，不受影响，故只在这里包）。
            // 右移量 14：排序图标↔⋮ 视觉间距从 ~14dp 缩到 ~10dp（约缩 1/4）。
            Transform.translate(
              offset: const Offset(14, 0),
              child: SortToggle(
                sortBy: config.albumSortBy,
                asc: config.albumSortAsc,
                onChanged: _setAlbumSort,
              ),
            ),
            IconButton(
              key: _menuBtnKey,
              icon: const Icon(Icons.more_vert, color: AppColors.text),
              tooltip: t(ref, 'gallery_manage'),
              onPressed: _showOverflowMenu,
            ),
          ],
        ),
        body: GestureDetector(
          // 点击空白（非输入框）：收起键盘并立即落盘 toNewDir 待保存编辑。
          onTap: _dismissAndFlush,
          // 左右滑动切换移动模式(对标系统相册页间滑动):右滑→相册间,左滑→子目录。
          onHorizontalDragEnd: _onModeSwipe,
          behavior: HitTestBehavior.opaque,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 模式切换 segmented control
                _buildModeSelector(),
                // 顶栏↔源相册分隔线：固定显示。模式选择器自身 bottom:10 已提供到分隔线
                // 的间距，与选择器 top:10（到顶栏）相等，故不再加额外 SizedBox。
                const Divider(color: AppColors.border, height: 1),
                // 主体（在分隔线下方滚动，不进入分隔线区域 → 不被遮挡）
                Expanded(child: _buildBody()),
                // 底部 Start
                _buildBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 切换模式:触发内容抽屉滑动(_slideForward 定向)。
  void _applyMode(ClassifyMode m) {
    if (m == _mode) return;
    setState(() {
      // 显示顺序为 toNewDir(左)→toAlbum(右)：切到右边的 toAlbum = 正向(新面板从右进)，
      // 切到左边的 toNewDir = 反向(从左进)。让抽屉动画方向与顶栏位置一致。
      // （原按枚举 index 判定，交换显示顺序后方向会反。）
      _slideForward = m == ClassifyMode.toAlbum;
      _mode = m;
    });
  }

  /// 左右滑动切换移动模式:右滑(正速度)→子目录(toNewDir);左滑→相册间(toAlbum)。
  /// 阈值 300px/s 避免误触。垂直滚动(ListView)不受影响——水平 drag 由本层独占。
  void _onModeSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v > 300 && _mode != ClassifyMode.toNewDir) {
      _applyMode(ClassifyMode.toNewDir);
    } else if (v < -300 && _mode != ClassifyMode.toAlbum) {
      _applyMode(ClassifyMode.toAlbum);
    }
  }

  Widget _buildModeSelector() {
    final isAlbum = _mode == ClassifyMode.toAlbum;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Container(
        // 轨道:未选段底色(surface),圆角;内 padding 让色块在其内滑动。
        padding: const EdgeInsets.all(4),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: LayoutBuilder(
          builder: (ctx, c) {
            final blockW = c.maxWidth / 2;
            return SizedBox(
              height: 40,
              child: Stack(
                children: [
                  // 高亮色块:圆角矩形,水平滑动到选中段。曲线/时长与下方内容
                  // 抽屉滑动一致(easeOutCubic ~280ms),保持视觉统一,无特效。
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    left: isAlbum ? blockW : 0,
                    top: 0,
                    bottom: 0,
                    width: blockW,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  // 两段按钮(在上层,捕获点击;色块在下层装饰)
                  Positioned.fill(
                    child: Row(
                      children: [
                        Expanded(
                          child: _modeSegment(
                            ClassifyMode.toNewDir,
                            Icons.create_new_folder_outlined,
                            t(ref, 'mode_to_newdir'),
                          ),
                        ),
                        Expanded(
                          child: _modeSegment(
                            ClassifyMode.toAlbum,
                            Icons.swap_horiz,
                            t(ref, 'mode_to_album'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 双面板卡片推动（PageView 式）：始终同时持有 toNewDir、toAlbum 两个面板，
  /// 用单一动画值 v（0=toNewDir、1=toAlbum）驱动两者水平位移——toNewDir 偏移 -v·w、
  /// toAlbum 偏移 (1-v)·w，两者边沿恒相接（紧贴），新面板从一侧推入、旧面板被推向
  /// 另一侧，不叠加不淡出。单一 v 保证缓动曲线下仍严格紧贴（AnimatedSwitcher 给新旧
  /// 各自独立的 anim，曲线下两者会同时落到中心附近而重叠，呈现叠加而非推动，故弃用）。
  Widget _buildModePanels() {
    final target = _mode == ClassifyMode.toAlbum ? 1.0 : 0.0;
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: target, end: target),
          duration: 280.ms,
          curve: Curves.easeOutCubic,
          builder: (ctx, v, _) => Stack(
            alignment: Alignment.topCenter,
            children: [
              // toNewDir 面板（左侧）：v=0 居中，v=1 推到左屏外
              Transform.translate(
                offset: Offset(-v * w, 0),
                child: SizedBox(
                  width: w,
                  child: Padding(
                    padding:
                        // 展开态 top:20 → 末行相册底到「父目录」标题 = 2(tile v2)+20 = 22；
                        // 折叠态 16 补偿 header 的 bottom:6，使 header→「父目录」标题同为 22（不再过近）
                        EdgeInsets.only(top: _sourceExpanded ? 20.0 : 16.0),
                    child: _buildNewDirConfig(),
                  ),
                ),
              ),
              // toAlbum 面板（右侧）：v=0 在右屏外，v=1 推到居中
              Transform.translate(
                offset: Offset((1 - v) * w, 0),
                child: SizedBox(
                  width: w,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildFlowDivider(sourceExpanded: _sourceExpanded),
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
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 单段按钮:点击切换模式;文字/图标颜色随选中态淡入淡出(选中=bg,未选=text),
  /// 与滑动色块同步,避免色块到位而字色仍滞留旧态。
  Widget _modeSegment(ClassifyMode m, IconData icon, String label) {
    final selected = _mode == m;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _applyMode(m),
        borderRadius: BorderRadius.circular(8),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: selected ? AppColors.bg : AppColors.text),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          builder: (ctx, color, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    if (!_permissionGranted) return _buildPermissionDenied();
    if (_error != null) return _buildError();
    if (_buckets.isEmpty) {
      return Center(
        child: Text(
          t(ref, 'no_albums'),
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
            color: AppColors.muted,
          ),
        ),
      );
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
        // 分隔线（固定在上）到源相册 header 内容 = 10：top:5 + 源相册 header top:5
        padding: const EdgeInsets.only(top: 5),
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
            child: _buildModePanels(),
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
            child: Icon(
              Icons.swap_horiz,
              size: 14,
              color: AppColors.accent.withValues(alpha: 0.7),
            ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            // top:5（距顶部分隔线/模式切换的间距，按需再收紧 1/3）；
            // bottom:6（距下方内容/分隔线收紧）
            padding: const EdgeInsets.fromLTRB(16, 5, 12, 6),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    color: AppColors.accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    height: 1.1,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accentWithOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$totalCount',
                    style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                // 展开/折叠指示箭头，随下方内容同步旋转（180°）。
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0.0,
                  duration: 200.ms,
                  curve: Curves.easeOutCubic,
                  child: const Icon(
                    Icons.expand_more,
                    size: 20,
                    color: AppColors.accent,
                  ),
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
        .map(
          (b) => _HomeBucketTile(
            key: ValueKey(b.id),
            bucket: b,
            selected: selectedIds.contains(b.id),
            onCheckToggle: () => onToggle(b.id),
            onInterceptWhileEditing: _dismissAndFlush,
            onAlbumReturned: _refreshCovers,
            grid: isGrid,
            selectionMode: selectedIds.isNotEmpty,
          ),
        )
        .toList();
    if (isGrid) {
      // 用 Wrap + 固定列宽替代 GridView.count：GridView 的 childAspectRatio 会把 cell
      // 高度锁死，内容（封面+SizedBox+文字）顶对齐后底部留白，且留白随列数变化
      //（3列 cell 大留白多、4列留白少），导致末行相册到后续元素间距忽大忽小。
      // Wrap 让每个 tile 高度=内容高度（无留白），末行底边天然对齐 → 各布局间距统一。
      return LayoutBuilder(
        builder: (ctx, c) {
          final cols = config.homeGridColumns;
          const spacing = 4.0;
          const hpad = 12.0;
          final cellW = (c.maxWidth - hpad * 2 - spacing * (cols - 1)) / cols;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: hpad),
            child: Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: tiles
                  .map((t) => SizedBox(width: cellW, child: t))
                  .toList(),
            ),
          );
        },
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
    final updated = config.copyWith(albumSortBy: sortBy, albumSortAsc: asc);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
    setState(() {});
  }

  /// 实时持久化 toNewDir 编辑（父目录 + 子目录）到 config：内存即时更新，
  /// 磁盘 save 防抖 400ms（避免每个按键都写 SharedPreferences）。
  /// 空父目录存 null、子目录存原始 label（含空串）→ 重启恢复后输入框为空、
  /// 显示灰色 hint（Visort / folder N），与未编辑状态一致。
  void _persistNewDir() {
    final config = ref.read(configProvider);
    final oldProfile = config.activeProfileData;
    final newFolders = _subDirs
        .asMap()
        .entries
        .map(
          (e) => FolderTemplate(
            key: e.key < _keyOrder.length ? _keyOrder[e.key] : '?',
            label: e.value.trim(),
          ),
        )
        .toList();
    final newProfile = oldProfile.copyWith(
      newDirParent: _parentCtrl.text.trim().isEmpty
          ? null
          : _parentCtrl.text.trim(),
      folders: newFolders,
    );
    final newProfiles = Map<String, Profile>.from(config.profiles)
      ..[config.activeProfile] = newProfile;
    ref.read(configProvider.notifier).state = config.copyWith(
      profiles: newProfiles,
    );
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      ref.read(profilesServiceProvider).save(ref.read(configProvider));
    });
  }

  /// 点击空白（非输入框）区域时收起键盘并立即落盘 toNewDir 编辑。
  ///
  /// 收键盘：FocusScope.unfocus 让当前 TextField 失焦 → 输入法收回。输入框为空
  /// 时失焦后由 hintText 自然显示灰色占位（Visort / folder*），无需回填——text 保持
  /// 空串，hint 即占位；实际使用由 _buildNewDirFolders / _startScan 的 isEmpty
  /// 兜底为 'Visort' / 'folder N'。
  /// 立即落盘：取消 _persistTimer 防抖直接 save，符合「点击即保存」语义，避免快速
  /// 切换输入框或返回页面时编辑落在 400ms 防抖窗口内被 dispose cancel 掉而丢失。
  void _dismissAndFlush() {
    if (_persistTimer?.isActive ?? false) {
      _persistTimer!.cancel();
      ref.read(profilesServiceProvider).save(ref.read(configProvider));
    }
    FocusScope.of(context).unfocus();
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
                Text(
                  t(ref, 'manage_media_title'),
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                    color: AppColors.accent2,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t(ref, 'manage_media_hint'),
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                    color: AppColors.text.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
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
            child: Text(
              t(ref, 'enable'),
              style: const TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
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
            hintText: 'Visort',
            onChanged: (_) {
              setState(() {});
              _persistNewDir();
            },
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
                  child: Icon(
                    Icons.add_circle_outline,
                    color: AppColors.accent,
                    size: 22,
                  ),
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
                color: AppColors.muted,
                fontFamily: 'Space Mono',
                height: 1.2,
                fontSize: 11,
              ),
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
    _persistNewDir();
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
    _persistNewDir();
  }

  /// 单个子目录行：委托给 _SubDirRow（StatefulWidget）。
  ///
  /// controller 必须由 _SubDirRow 的 State 持有并跨 rebuild 复用——之前在本
  /// build 内 `TextEditingController(text: value)` 每次 new，onChanged→setState
  /// 触发的 rebuild 会重建 controller，导致输入（尤其删除字符）后光标/焦点消失。
  Widget _buildSubDirRow(int idx, String value, Animation<double> animation) {
    return _SubDirRow(
      value: value,
      keyLabel: idx < _keyOrder.length ? _keyOrder[idx] : '?',
      animation: animation,
      // fieldBuilder 闭包捕获 idx，复用父级 _dirInputField 与编辑/删除逻辑不变
      fieldBuilder: (controller) => _dirInputField(
        controller: controller,
        hintText: 'folder ${idx + 1}',
        onChanged: (val) {
          setState(() => _subDirs[idx] = val);
          _persistNewDir();
        },
        onDelete: _subDirs.length > 1 ? () => _removeSubDir(idx) : null,
      ),
    );
  }

  /// 区块标题文字（统一样式）
  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Space Mono',
        fontFamilyFallback: ['Noto Sans Mono CJK SC'],
        color: AppColors.accent,
        fontWeight: FontWeight.w800,
        fontSize: 13,
      ),
    );
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
    String? hintText,
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
          hintText: hintText,
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
    String? hintText,
  }) {
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      style: const TextStyle(
        fontFamily: 'Space Mono',
        fontFamilyFallback: ['Noto Sans Mono CJK SC'],
        color: AppColors.text,
        fontSize: 14,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
        hintStyle: const TextStyle(
          color: AppColors.muted,
          fontFamily: 'Space Mono',
          fontFamilyFallback: ['Noto Sans Mono CJK SC'],
          fontSize: 14,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        filled: true,
        fillColor: AppColors.surface,
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
    if (onDelete == null) return field;
    // 删除按钮放在输入框外右侧,与顶部「加号」行(Padding(h:8)+Icon 22)同列对齐。
    return Row(
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onDelete,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Icon(
              Icons.remove_circle_outline,
              color: AppColors.danger,
              size: 22,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    final canStart =
        _sourceBucketIds.isNotEmpty &&
        ((_mode == ClassifyMode.toAlbum && _targetBucketIds.isNotEmpty) ||
            (_mode == ClassifyMode.toNewDir && _subDirs.isNotEmpty));
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
                  fontFamily: 'Space Mono',
                  height: 1.2,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: (canStart && !_scanning) ? _startScan : null,
              child: _scanning
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.bg,
                      ),
                    )
                  : Text(
                      t(ref, 'start'),
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
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
            const Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: AppColors.muted,
            ),
            const SizedBox(height: 16),
            Text(
              t(ref, 'permission_needed'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                color: AppColors.text,
                fontSize: 14,
              ),
            ),
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
            SelectableText(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                color: AppColors.danger,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _loadBuckets,
              child: Text(t(ref, 'retry')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个相册行（Home 用）：左封面 + 名称（点击进相册浏览）+ 右侧圆点勾选。
///
/// 交互分区：
///   - 封面缩略图 + 名称区域 → 进入相册内浏览（AlbumScreen）
///   - 右侧圆点 → 勾选/取消勾选（作为源/目标相册）
/// 选中反馈：圆点变实心 + 选中瞬间扩散波动环 + 整行 accent 淡背景高亮，
/// 让用户清晰知道哪一行是待操作项。
class _HomeBucketTile extends StatefulWidget {
  const _HomeBucketTile({
    super.key,
    required this.bucket,
    required this.selected,
    required this.onCheckToggle,
    this.onInterceptWhileEditing,
    this.onAlbumReturned,
    this.grid = false,
    this.selectionMode = false,
  });
  final MsBucket bucket;
  final bool selected;
  final VoidCallback onCheckToggle;

  /// 输入法展开时点击本 tile 的回调（收键盘 + 保存）；为 null 则不拦截。
  final VoidCallback? onInterceptWhileEditing;

  /// 从相册浏览返回后的回调（刷新封面/数量——删除/恢复会改变它们）。
  final VoidCallback? onAlbumReturned;
  final bool grid;

  /// 本组已进入选择模式（至少一个相册被勾选）：此时点击 tile 改为勾选/取消本相册，
  /// 不进入相册浏览——满足"勾选第一个后，点其余直接勾选"的批量选择体感。
  final bool selectionMode;

  @override
  State<_HomeBucketTile> createState() => _HomeBucketTileState();
}

class _HomeBucketTileState extends State<_HomeBucketTile>
    with SingleTickerProviderStateMixin {
  /// 封面缩略图 GlobalKey：点击进入相册时取其屏幕坐标做飞行层起点。
  final GlobalKey _coverKey = GlobalKey();

  // 选中波动环：selected 由 false→true 时播放一次（从圆点向外扩散并淡出）。
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );

  @override
  void didUpdateWidget(covariant _HomeBucketTile oldWidget) {
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
              onTap: _openAlbum,
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    _CoverThumb(
                      key: _coverKey,
                      coverId: widget.bucket.coverId,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.bucket.name,
                            style: TextStyle(
                              fontFamily: 'Space Mono',
                              height: 1.2,
                              fontFamilyFallback: AppFonts.cjkFallback,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: AppColors.text.withValues(alpha: 0.95),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.bucket.count}',
                            style: const TextStyle(
                              fontFamily: 'Space Mono',
                              height: 1.2,
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
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
            onTap: _onCheckToggle,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
                              color: AppColors.accent.withValues(
                                alpha: (1 - t) * 0.7,
                              ),
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
                        color: selected ? AppColors.accent : Colors.transparent,
                        border: Border.all(
                          color: selected ? AppColors.accent : AppColors.muted,
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
  /// 输入法展开（有 TextField 聚焦）时，点击相册入口只用于收起键盘并保存
  /// 编辑，不进入相册——避免编辑中的父/子目录改动落在防抖窗口内、随导航
  /// 丢失。返回 true 表示已拦截（调用方应 return）。第二次点击（键盘已收）
  /// 才执行原操作。
  bool _interceptIfEditing() {
    // 用 View 级 viewInsets（物理像素）而非 MediaQuery.viewInsetsOf：后者被
    // Scaffold 的 resizeToAvoidBottomInset 消费（removeViewInsets 传给 body），
    // 在 body 子树内恒为 0，无法据此判断键盘是否展开。
    if (View.of(context).viewInsets.bottom > 0) {
      widget.onInterceptWhileEditing?.call();
      return true;
    }
    return false;
  }

  /// 勾选入口：输入态先收键盘保存，不勾选。
  void _onCheckToggle() {
    if (_interceptIfEditing()) return;
    widget.onCheckToggle();
  }

  Future<void> _openAlbum({BuildContext? coverContext}) async {
    if (_interceptIfEditing()) return;
    // 选择模式（本组已有相册勾选）：点击改为勾选/取消本相册，不进入浏览
    if (widget.selectionMode) {
      widget.onCheckToggle();
      return;
    }
    // 封面缩略图的屏幕坐标：list 模式取 _coverKey 挂载的封面；grid 模式
    // 由调用方传封面区域的 context（GestureDetector/名称区）。网格动画
    // 从封面位置"长"出来（由小变大）。
    final ctx = coverContext ?? _coverKey.currentContext;
    final box = ctx?.findRenderObject();
    final rect = (box is RenderBox && box.attached)
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    final args = {
      'bucketId': widget.bucket.id,
      'bucketName': widget.bucket.name,
      'bucketCount': widget.bucket.count,
    };
    if (rect != null && widget.bucket.coverId != null) {
      await pushAlbumFlight(
        context,
        args: args,
        cellRect: rect,
        coverId: widget.bucket.coverId!,
        coverAlignment: albumCoverAlignment(rect, MediaQuery.sizeOf(context)),
      );
    } else {
      await Navigator.pushNamed(context, AlbumRoutes.album, arguments: args);
    }
    // 从相册返回：刷新封面/数量（相册内可能删除了图片/改了排序）
    widget.onAlbumReturned?.call();
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
                      key: _coverKey,
                      coverId: widget.bucket.coverId,
                      size: c.maxWidth,
                    ),
                  ),
                ),
                if (selected)
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.accent, width: 2.5),
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
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${widget.bucket.count}',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white,
                          fontFamily: 'Space Mono',
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: _onCheckToggle,
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
                fontFamily: 'Space Mono',
                height: 1.2,
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
                    color: AppColors.accent.withValues(alpha: (1 - t) * 0.7),
                    width: 2,
                  ),
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
                width: 2,
              ),
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
  const _CoverThumb({super.key, required this.coverId, required this.size});
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
        child: const Icon(
          Icons.photo_outlined,
          color: AppColors.muted,
          size: 20,
        ),
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
          child: const Icon(
            Icons.broken_image_outlined,
            color: AppColors.muted,
            size: 20,
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
        Text(
          'V',
          style: TextStyle(
            fontFamily: 'Syne',
            fontFamilyFallback: AppFonts.cjkFallback,
            fontWeight: FontWeight.w800,
            fontSize: 22,
            color: AppColors.accent,
          ),
        ),
        Text(
          'ISORT',
          style: TextStyle(
            fontFamily: 'Syne',
            fontFamilyFallback: AppFonts.cjkFallback,
            fontWeight: FontWeight.w800,
            fontSize: 22,
          ),
        ),
      ],
    );
  }
}

/// 单个子目录输入行（toNewDir 模式）。
///
/// 设计要点：[TextEditingController] 在 [_SubDirRowState] 内创建并跨 rebuild
/// 复用。AnimatedList 的 itemBuilder 每次 rebuild 都会调用 _buildSubDirRow，
/// 若在 build 内 `new TextEditingController` 会让 TextField 在每次输入
/// （onChanged→父 setState）后挂上一个全新 controller，光标位置与 IME 焦点
/// 随之丢失——表现为「删一个字后光标消失」。把 row 抽成 StatefulWidget，
/// 编辑期间列表项位置不变、State 复用，controller 稳定，光标得以保留。
///
/// 输入框本体（[TextField] + 装饰）由父级通过 [fieldBuilder] 提供，以复用
/// _dirInputField 与既有的 onChanged/onDelete 逻辑；本组件只负责持有
/// controller、同步外部 value 变化，以及入场/退场动画包裹与快捷键标签。
class _SubDirRow extends StatefulWidget {
  final String value;
  final String keyLabel;
  final Animation<double> animation;
  final Widget Function(TextEditingController controller) fieldBuilder;

  const _SubDirRow({
    required this.value,
    required this.keyLabel,
    required this.animation,
    required this.fieldBuilder,
  });

  @override
  State<_SubDirRow> createState() => _SubDirRowState();
}

class _SubDirRowState extends State<_SubDirRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(covariant _SubDirRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部 value 变化（配置加载、增删行导致的位置位移）时同步。
    // 用户正在编辑本行时 value == _controller.text（onChanged 已先写回 _subDirs），
    // 此处不触发，光标位置得以保留。
    if (_controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: widget.animation,
      // 展开方向为垂直（height）：顶部对齐，行从上往下生长
      // （等价旧 axisAlignment: -1.0；该属性自 Flutter 3.41 起被 alignment 取代）
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: widget.animation,
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
                      widget.keyLabel,
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // 子目录名输入：删除图标内置 suffix（由父级 fieldBuilder 提供）
                Expanded(child: widget.fieldBuilder(_controller)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
