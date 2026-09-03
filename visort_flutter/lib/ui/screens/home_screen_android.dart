// 安卓「快速整理」屏（抽屉一级页④，原首页主屏）—— 统一 MediaStore 方案
//
// 抽屉重构后本屏不再是 `/` 路由（那是 AppShellAndroid），返回键分发/
// 收藏/回收站/设置入口均移交 Shell；本页只保留整理配置主流程。
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/folder_name_validator.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/core/config/profiles_service.dart';
import 'package:visort_flutter/core/fs/android_mediastore_file_system.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_animations.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/scan/scan_controller.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/shared/widgets/resume_button.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart'
    show showCenterDialog;
import 'package:visort_flutter/shared/widgets/app_bar_title.dart';
import 'package:visort_flutter/shared/widgets/view_options_toggle.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/router.dart';
import 'package:visort_flutter/ui/router_android.dart';
import 'package:visort_flutter/ui/screens/app_shell_android.dart'
    show DrawerMenuButton, ShellHandle;

class HomeScreenAndroid extends ConsumerStatefulWidget {
  const HomeScreenAndroid({super.key, this.shellHandle});

  /// 抽屉壳注入的句柄：☰ 呼出抽屉、返回键清勾选拦截、切回本页刷新封面。
  /// null = 非 shell 场景（当前不存在，预留）。
  final ShellHandle? shellHandle;

  @override
  ConsumerState<HomeScreenAndroid> createState() => _HomeScreenAndroidState();
}

class _HomeScreenAndroidState extends ConsumerState<HomeScreenAndroid>
    with WidgetsBindingObserver {
  /// 飞行目标 tag（父级全局）：点击相册瞬间置位，所有 tile 的 HeroMode
  /// 据此屏蔽非目标 tile（含屏外预构建）；push 返回后清除。
  String? _flightTag;
  static const _channel = MediaStoreChannel();
  static const _keyOrder = 'ABCDEFGHIJ'; // 目标相册/子目录的快捷键分配

  // 相册数据
  List<MsBucket> _buckets = const [];
  Set<String> _sourceBucketIds = {}; // 源相册
  Set<String> _targetBucketIds = {}; // 模式二目标相册
  // 记录上次查询封面时用的排序，用于检测变化后重查
  SortBy? _lastCoverSortBy;
  bool? _lastCoverSortAsc;

  // 模式
  ClassifyMode _mode = ClassifyMode.toNewDir;

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

  /// Start 防并发闸门：恢复探测/弹窗/构建目标相册的 async gap 期间
  /// _scanning 仍为 false、按钮可再点，双击会并发进入两次扫描（双 push
  /// sort）。_scanning 置位后的窗口由其自身兜底（按钮禁用）。
  bool _scanInFlight = false;
  bool _permissionGranted = false;
  bool _manageMediaGranted = false; // MANAGE_MEDIA 特殊权限（零弹窗媒体操作）
  String? _error;

  // 源/目标区折叠状态
  bool _sourceExpanded = true;
  bool _targetExpanded = true;

  /// 是否有可恢复的整理会话(Home 顶部横条)。
  bool _resumeAvailable = false;

  /// 本轮是否发起过整理(Start/恢复)。整理流程结束(session reset)返回时
  /// 据此清勾选并复位;未发起过(如仅切相册页浏览返回)不动勾选草稿。
  bool _sortStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _parentFocus.addListener(() {
      if (mounted) setState(() {});
    });
    // 预热/首启只探测权限不弹窗（requestIfDenied=false）：弹窗入口收敛
    // 到「授予权限」按钮（用户显式点击）。
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _initAndLoad(requestIfDenied: false));
    // P2 会话恢复探测:杀进程后有未完成整理会话则显示横条。
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkResumableSession());
    // P2:从 sort/review 等返回 Home(手势 pop 不重建本页)时重探横条——
    // 决策已直写落盘,pop 回来当帧就该长出「继续上次整理」。
    currentRouteName.addListener(_onRouteChanged);
    // 返回键拦截（Shell 分发）：勾选态先清空勾选，已消费不落退后台。
    // （原 PopScope 逻辑上移到 Shell——同路由多 PopScope 会全部同时回调。）
    widget.shellHandle?.onBack = () {
      if (_sourceBucketIds.isEmpty && _targetBucketIds.isEmpty) return false;
      setState(() {
        _sourceBucketIds.clear();
        _targetBucketIds.clear();
      });
      return true;
    };
    // 抽屉从其他一级页切回本页：静默刷新封面 + 重探会话横条
    //（原「⋮ 进入收藏/回收站 await push 返回后刷新」的等价钩子）。
    widget.shellHandle?.onActivated = () {
      _refreshCovers();
      _checkResumableSession();
    };
  }

  /// 路由回到 Home 时(全局 RouteNameObserver 驱动):重探横条 + 刷新
  /// 封面/数量 + 整理流程结束后清勾选。
  void _onRouteChanged() {
    if (currentRouteName.value != AppRoutes.home) return;
    // 整理流程结束(session 已 reset → 空态)返回:清空源/目标勾选,页面
    // 不再停留勾选态——否则移动过的相册仍高亮勾着(真机实测)。
    // 中途退出(session 仍在,「继续」可恢复)保留勾选草稿,便于续整理。
    final s = ref.read(sessionControllerProvider);
    if (s.isEmpty && _sortStarted) {
      _sortStarted = false;
      if (_sourceBucketIds.isNotEmpty || _targetBucketIds.isNotEmpty) {
        setState(() {
          _sourceBucketIds.clear();
          _targetBucketIds.clear();
        });
      }
    }
    // 全量重查 buckets:源相册封面/数量随移动变化(移走第一张后封面
    // 可能变更、count 减一;目标相册 count 增一)。
    _refreshCovers();
    _checkResumableSession();
  }

  @override
  void dispose() {
    currentRouteName.removeListener(_onRouteChanged);
    WidgetsBinding.instance.removeObserver(this);
    _persistTimer?.cancel();
    _parentCtrl.dispose();
    _parentFocus.dispose();
    widget.shellHandle?.onBack = null;
    widget.shellHandle?.onActivated = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint(
      '[Home] lifecycle: $state, permissionGranted=$_permissionGranted',
    );
    // app 从后台恢复前台（用户从系统设置授权后返回）→ 重探读取权限 +
    // 重新检测 MANAGE_MEDIA
    if (state == AppLifecycleState.resumed) {
      // 延迟 500ms 检测，确保系统权限状态已刷新
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (!mounted) return;
        // 未授权态从设置回来：授权了就补走加载（整页 denied 提示的闭环）
        if (!_permissionGranted && await _channel.hasPermission()) {
          setState(() => _permissionGranted = true);
          await _loadBuckets();
          if (!mounted) return;
        }
        unawaited(_recheckManageMedia());
      });
    }
  }

  /// 初始化并加载。[requestIfDenied]=false 时只探测不弹系统权限窗——
  /// IndexedStack 预热构建也会走 initState，预热时弹窗会让用户在相册页
  /// 莫名其妙看到权限对话框（[用户定稿] 引导收敛到各页显式 UI：相册页
  /// 顶部提示条 / 本页整页提示的「授予权限」按钮）。
  Future<void> _initAndLoad({bool requestIfDenied = true}) async {
    setState(() => _loading = true);
    final granted = await _channel.hasPermission();
    if (!granted) {
      if (!requestIfDenied) {
        if (!mounted) return;
        setState(() {
          _permissionGranted = false;
          _loading = false;
        });
        return;
      }
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
          label: bucket.name.isEmpty ? t(ref, 'root_dir') : bucket.name,
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

  /// 子目录名校验：非法字符 / `.` `..` / 与其他行有效名重复 → 错误 key。
  /// 规则集中在 folder_name_validator.dart（纯函数，有单测）。
  ///
  /// 越界守卫：AnimatedList 退场动画期间，退场行以删除时的旧 idx 回调
  /// （此时 _subDirs 已收缩），不守卫会 RangeError → 退场行构建失败 →
  /// 该帧渲染异常（真机「删末位行灰屏闪烁」的根因；删中间行旧 idx 恰在
  /// 合法域内不炸，故只有删末位必现）。退场行正在消失，无需校验。
  String? _subDirRowErrorKey(int idx) {
    if (idx < 0 || idx >= _subDirs.length) return null;
    return folderNameInvalidKey(_subDirs[idx]) ??
        folderNameDupKey(idx, _subDirs);
  }

  /// 父目录名校验（非法字符 / 路径穿越；空值走 Visort 兜底，不算错）。
  String? _parentDirErrorKey() {
    return folderNameInvalidKey(_parentCtrl.text);
  }

  /// toNewDir 模式下父/子目录名是否全部合法（任一非法字符/重名命中即 false）。
  /// 用于禁用「开始」按钮——红框提示 + 按钮禁用，双重防误触。
  bool get _newDirNamesValid {
    if (_parentDirErrorKey() != null) return false;
    for (var i = 0; i < _subDirs.length; i++) {
      if (_subDirRowErrorKey(i) != null) return false;
    }
    return true;
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
    // 收键盘+清焦点链（同 _dismissAndFlush）：开始按钮在底栏，输入框聚焦时
    // 点击不会触发 body 的 onTap，若不先收焦点，push 到 sort/review 返回时
    // 路由作用域会把焦点还给输入框、键盘自动弹出。
    _dismissAndFlush();
    // P2:有未完成会话先问恢复。Start 的默认语义是重扫覆写——不问就直接
    // 覆写会让"中断后点开始续整理"的主诉路径丢决策(每次都从第一张来)。
    final summary = await ref
        .read(sessionControllerProvider.notifier)
        .persistedSummary();
    if (summary != null && summary.decided > 0) {
      final resume = await _askResumePersisted(summary);
      if (!mounted || resume == null) return; // 关掉弹窗 = 取消本次 Start
      if (resume) {
        final ok = await ref
            .read(sessionControllerProvider.notifier)
            .restoreLastSession();
        if (!mounted || !ok) return;
        setState(() => _resumeAvailable = false);
        // 完成态会话(在 Review 屏被杀)直达 Review;进 sort 会因「无当前图」
        // 黑屏(其自动跳 Review 只挂在决策完成回调上,恢复路径不经过)。
        final target =
            ref.read(sessionControllerProvider).isComplete ? '/review' : '/sort';
        _sortStarted = true;
        await Navigator.of(context).pushNamed(target);
        await _checkResumableSession();
        return;
      }
      // false → 用户明确选择重新开始,继续走重扫覆写。
    }
    if (!mounted) return; // 恢复探测/弹窗是 async gap,原流程用 context 前先守卫
    if (_sourceBucketIds.isEmpty) {
      toast(context, t(ref, 'no_album_selected'));
      return;
    }
    // 按模式校验目标
    // 可空：toNewDir 在校验后同步赋值；toAlbum 的异步构建挪进下方 try
    //（channel 异常并入 _scanning 复位保护），scan 的 prebuiltFolders 参数可空。
    List<FolderDescriptor>? folders;
    if (_mode == ClassifyMode.toAlbum) {
      if (_targetBucketIds.isEmpty) {
        toast(context, t(ref, 'no_target_album'));
        return;
      }
      // 快捷键池硬上限：超过 _keyOrder 后 key 溢出为 '?'（decide 按 key 匹配
      // 会串位、Run 的 folderMap 会静默覆盖），在源头拦截。
      if (_targetBucketIds.length > _keyOrder.length) {
        toast(context, t(ref, 'too_many_targets', [_keyOrder.length]));
        return;
      }
    } else {
      // 合法性 + 重复校验：非法字符 / `.` `..` 穿越 / 重名直接拦截，提示中止。
      // （输入框已实时标红，这里是兜底强制——用户可能忽略红框直接点开始。）
      final parentErr = _parentDirErrorKey();
      if (parentErr != null) {
        toast(context, t(ref, parentErr));
        return;
      }
      for (var i = 0; i < _subDirs.length; i++) {
        final err = _subDirRowErrorKey(i);
        if (err != null) {
          toast(context, t(ref, err));
          return;
        }
      }
      folders = _buildNewDirFolders();
      if (folders.isEmpty) {
        toast(context, t(ref, 'no_subdir'));
        return;
      }
      // 同 toAlbum：子目录行数超过快捷键池即拦截（_addSubDir 已前置拦截，
      // 此处兜底——旧持久化配置可能带回超限行数）。
      if (folders.length > _keyOrder.length) {
        toast(context, t(ref, 'too_many_targets', [_keyOrder.length]));
        return;
      }
    }

    setState(() => _scanning = true);
    // try/finally：任何异常路径都复位 _scanning——含 _buildTargetAlbumFolders
    // 的 channel 异常（getBucketRelativePath 可抛 PlatformException），此前
    // 它会让 Start 永久禁用、页面卡 loading，release 下表现为「卡死」。
    try {
      if (_mode == ClassifyMode.toAlbum) {
        folders = await _buildTargetAlbumFolders();
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
      if (err != null) {
        toast(context, t(ref, err));
        return;
      }
      _sortStarted = true;
      Navigator.pushNamed(context, AppRoutes.sort);
    } catch (e) {
      debugPrint('[startScan] $e');
      if (mounted) toast(context, t(ref, 'scan_failed'));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 顶栏「ⓘ」说明按钮：弹出屏幕居中的说明弹窗，介绍本页用途与两种
  /// 整理模式的区别。弹层与恢复询问等居中弹窗同款（showCenterDialog：
  /// scrim + 弹簧缩放 + 点外/返回收回）；内容纯文字，无交互条目。
  Future<void> _showTipsDialog() async {
    await showCenterDialog<void>(
      context: context,
      builder: (_) => const _QuickSortTipsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    // 检测相册内排序是否变化（从相册返回时封面需更新）
    _maybeRefreshCovers();
    // 返回键不在本页处理：勾选清空/退后台由 Shell 的三段分发经
    // ShellHandle.onBack 完成（见 initState）。
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        // ☰ 呼出抽屉（原首页为根路由无 leading；logo 已移除，只留抽屉头部）
        leading: DrawerMenuButton(
          handle: widget.shellHandle,
          tooltip: t(ref, 'quick_sort_title'),
        ),
        titleSpacing: 0,
        // 标题视觉对齐共用组件（CJK 重心偏下 −1.4dp 上移贴中线，
        // 见 app_bar_title.dart）。
        title: AppBarTitleText(t(ref, 'quick_sort_title')),
        actions: [
          // 说明按钮（选项按钮左侧）：点击弹出屏幕居中的说明弹窗，介绍
          // 本页用途与两种整理模式的区别。自绘 ⓘ 图标形制参照首页搜索
          // 按钮（24 视口 stroke 1.8 圆头，图形外缘 ~10.8 与搜索/筛选
          // 包络同量级）；x 12.75 → 与选项按钮图形间隙 22dp（搜索按钮
          // 同款调校）。圆形图形几何正中，无需 y 补偿。
          Transform.translate(
            offset: const Offset(12.75, 0),
            child: IconButton(
              icon: const _HelpGlyphIcon(),
              tooltip: t(ref, 'quick_sort_tips'),
              onPressed: _showTipsDialog,
            ),
          ),
          // 视图选项（[ente 对齐]）：布局切换 + 网格列数 + 排序收口到一个
          // 选项按钮；相册排序为源/目标 section 共用状态 albumSortBy/Asc。
          // 品牌 logo 已随抽屉定稿移除（只留抽屉头部一处）。
          ViewOptionsToggle(
            layout: config.homeLayout,
            onLayoutChanged: _setHomeLayout,
            gridColumns: config.homeGridColumns,
            onGridColumnsChanged: _setHomeGridColumns,
            sortBy: config.albumSortBy,
            asc: config.albumSortAsc,
            onSortChanged: _setAlbumSort,
          ),
        ],
      ),
      body: GestureDetector(
        // 点击空白（非输入框）：收起键盘并立即落盘 toNewDir 待保存编辑。
        onTap: _dismissAndFlush,
        // 模式页间滑动 + 抽屉呼出（见 _onModeSwipe 注释）。
        onHorizontalDragEnd: _onModeSwipe,
        behavior: HitTestBehavior.opaque,
        // edge-to-edge 沉浸：body SafeArea(bottom:false)，卡片流延伸到
        // 底栏上缘；底栏保持贴边（Column 尾），Container 背景自延伸到
        // 物理底边、内部 SafeArea(top:false) 避让手势条（底栏自己的延伸，
        // 非额外黑条）。底栏不做悬浮卡片（用户明确要求保持贴边）。
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 模式切换 segmented control
              _buildModeSelector(),
              // 顶栏↔源相册分隔线：固定显示。模式选择器自身 bottom:10 已提供到分隔线
              // 的间距，与选择器 top:10（到顶栏）相等，故不再加额外 SizedBox。
              const Divider(color: AppColors.border, height: 1),
              // 主体（在分隔线下方滚动，不进入分隔线区域 → 不被遮挡）
              // [ente 对齐] 相册排序切换内容交叉淡入 150ms（easeInQuart/easeOutExpo）。
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppDurations.enteContentSwitch,
                  switchInCurve: Curves.easeInQuart,
                  switchOutCurve: Curves.easeOutExpo,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    fit: StackFit.expand,
                    children: [
                      for (final previous in previousChildren)
                        Positioned.fill(child: previous),
                      if (currentChild != null)
                        Positioned.fill(child: currentChild),
                    ],
                  ),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: KeyedSubtree(
                    key: ValueKey(
                        (config.albumSortBy, config.albumSortAsc, config.homeLayout)),
                    child: _buildBody(),
                  ),
                ),
              ),
              // 底部 Start（贴边，非悬浮）
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────────────── P2 会话恢复 ─────────────────────────

  /// Start 前恢复询问弹窗。
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

  /// 探测持久化会话。显示条件 = **库里有已决策的会话**——只要整理过,
  /// 无论内存是否还有活动会话(新开始返回/恢复后返回)都显示,方便
  /// 一键续上;0 决策(刚扫描没动/刚"重新开始"覆写)无中断价值,不显示。
  /// 清除只有两条路:用户点「重新开始」(新扫描覆写,决策归零)或滑动横条。
  Future<void> _checkResumableSession() async {
    final s = await ref
        .read(sessionControllerProvider.notifier)
        .persistedSummary();
    if (!mounted) return;
    setState(() => _resumeAvailable = s != null && s.decided > 0);
  }

  /// 横条滑除:丢弃持久化会话(Dismissible 已播完滑出+收起动画)。
  void _onDismissResumeBanner() {
    ref.read(sessionControllerProvider.notifier).discardPersistedSession();
    setState(() => _resumeAvailable = false);
  }

  /// 恢复上次会话并落屏;pop 回来后重探横条显隐。
  /// 完成态会话直达 Review(在 Review 屏被杀的场景),黑屏规避见上。
  Future<void> _resumeLastSession() async {
    final ok = await ref
        .read(sessionControllerProvider.notifier)
        .restoreLastSession();
    if (!mounted || !ok) return;
    setState(() => _resumeAvailable = false);
    final target =
        ref.read(sessionControllerProvider).isComplete ? '/review' : '/sort';
    await Navigator.of(context).pushNamed(target);
    await _checkResumableSession();
  }

  /// 切换模式:触发内容抽屉滑动。
  void _applyMode(ClassifyMode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
    });
  }

  /// 水平滑动分派（用户定稿的线性退让链 [抽屉 ← 子目录 ← 相册间]）：
  /// 右滑(正速度) 相册间→子目录（原行为）；子目录→呼出抽屉（新——
  /// 原本子目录态右滑是无操作，正好接到抽屉上）。
  /// 左滑→相册间（原行为）；相册间态左滑无操作（不变）。
  /// 阈值 300px/s 避免误触。垂直滚动(ListView)不受影响——水平 drag 由本层独占。
  void _onModeSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v > 300) {
      if (_mode != ClassifyMode.toNewDir) {
        _applyMode(ClassifyMode.toNewDir);
      } else {
        widget.shellHandle?.openDrawer();
      }
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
                            if (_targetBucketIds.contains(id)) {
                              // 取消勾选 = 移除目标相册：有未完成决策的会话
                              // 在引用目标快照，同子目录移除一样拦截。
                              if (_resumeAvailable) {
                                toast(context, t(ref, 'pending_session_guard'));
                                return;
                              }
                              _targetBucketIds.remove(id);
                            } else {
                              _targetBucketIds.add(id);
                            }
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
    return ListView(
        // 动画对齐 ente：iOS 式回弹滚动物理。
        physics: const BouncingScrollPhysics(),
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
            flightTag: _flightTag,
            onFlightStart: (tag) => setState(() => _flightTag = tag),
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
        case SortBy.dateFavorited:
          // 相册（bucket）无收藏日期概念（该维度仅收藏视图提供）；回退创建时间。
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

  /// 切换源相册区布局（列表↔网格）并持久化（选项面板回调）。
  Future<void> _setHomeLayout(HomeLayout layout) async {
    final updated = ref.read(configProvider).copyWith(homeLayout: layout);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
  }

  /// 步进源相册区网格列数并持久化（选项面板回调）。
  Future<void> _setHomeGridColumns(int cols) async {
    final updated = ref.read(configProvider).copyWith(homeGridColumns: cols);
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
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
  /// 收键盘：对「当前聚焦节点」unfocus → 输入法收回。必须用
  /// FocusManager.instance.primaryFocus?.unfocus() 而非 FocusScope.of(context)
  /// .unfocus()——后者只清父级（Navigator）作用域的焦点链，Home 路由作用域
  /// 的 _focusedChildren 仍记着 TextField；从相册返回时路由作用域恢复焦点会
  /// 重新聚焦该输入框、键盘自动弹出（2026-08 实测：创建子目录后进相册返回，
  /// 输入法自动展开聚焦到子目录输入框）。对聚焦节点本身 unfocus 会清空其
  /// 所在路由作用域的焦点链，返回时不再回焦。
  /// 输入框为空时失焦后由 hintText 自然显示灰色占位（Visort / folder*），无需
  /// 回填——text 保持空串，hint 即占位；实际使用由 _buildNewDirFolders /
  /// _startScan 的 isEmpty 兜底为 'Visort' / 'folder N'。
  /// 立即落盘：取消 _persistTimer 防抖直接 save，符合「点击即保存」语义，避免快速
  /// 切换输入框或返回页面时编辑落在 400ms 防抖窗口内被 dispose cancel 掉而丢失。
  void _dismissAndFlush() {
    if (_persistTimer?.isActive ?? false) {
      _persistTimer!.cancel();
      ref.read(profilesServiceProvider).save(ref.read(configProvider));
    }
    FocusManager.instance.primaryFocus?.unfocus();
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
            errorText: _parentDirErrorKey() == null
                ? null
                : t(ref, _parentDirErrorKey()!),
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
          // 预览路径：贴子目录末项，间距与子目录行间一致（8px）。
          // 原 12px 在深色背景上观感为一条过大的黑边；且 AnimatedList
          // 移除行时预览块随高度收缩上移（shrinkWrap 跟随），间距一致
          // 后「覆盖/下移」的错位观感消除。
          const SizedBox(height: 8),
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
    // 快捷键池上限：超出后 key 会溢出为 '?'，decide/Run 均按 key 匹配将串位。
    // 在新增入口拦截（_startScan 处另有兜底）。
    if (_subDirs.length >= _keyOrder.length) {
      toast(context, t(ref, 'too_many_targets', [_keyOrder.length]));
      return;
    }
    final newIdx = _subDirs.length;
    setState(() => _subDirs.add(''));
    _subDirsKey.currentState?.insertItem(newIdx);
    _persistNewDir();
  }

  /// 删除子目录行（保存被删行数据渲染退场动画，再移除数据）。
  void _removeSubDir(int idx) {
    // 有未完成决策的会话在引用子目录列表快照：移除行会让「恢复会话看到
    // 的目标」与首页配置脱节（Run 本身走快照不出错，但用户极易误解为
    // 配置生效）。先处理会话（恢复并 Run / 丢弃）再改目标。
    if (_resumeAvailable) {
      toast(context, t(ref, 'pending_session_guard'));
      return;
    }
    if (_subDirs.length <= 1) return;
    final removed = _subDirs[idx];
    _subDirsKey.currentState?.removeItem(
      idx,
      // 退场动画期间行仍在树上且可命中：禁掉指针，防误触二次删除。
      (ctx, animation) => IgnorePointer(
        child: _buildSubDirRow(idx, removed, animation),
      ),
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
      // 实时校验：非法字符/重名 → 红框 + 红字（_subDirRowErrorKey）。
      fieldBuilder: (controller, focusNode) {
        final errKey = _subDirRowErrorKey(idx);
        return _dirInputField(
          controller: controller,
          focusNode: focusNode,
          hintText: 'folder ${idx + 1}',
          errorText: errKey == null ? null : t(ref, errKey),
          onChanged: (val) {
            setState(() => _subDirs[idx] = val);
            _persistNewDir();
          },
          // 删除持焦行前先把焦点转给父目录输入框：删末位行时下方已无
          // 输入框可自然接焦，系统会直接收起 IME → 窗口 resize →
          // SurfaceView resize 闪灰（「删末位灰屏闪烁」根因；删中间行
          // 焦点自然落到下一行输入框故无此现象）。先转移 → 键盘保持
          // 展开，退场动画与 IME 不打架。
          onDelete: _subDirs.length > 1
              ? () {
                  if (focusNode.hasFocus) _parentFocus.requestFocus();
                  _removeSubDir(idx);
                }
              : null,
        );
      },
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
    String? errorText,
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
          errorText: errorText,
        ),
      ],
    );
  }

  /// 目录输入框（父目录与子目录共用）。
  ///
  /// 纯 Flutter 原生 TextField + 单层 OutlineInputBorder（无外层 Container，
  /// 无嵌套双框）。父目录和子目录用完全相同的组件 + InputDecoration，
  /// 渲染必然一致。Pictures/ 提示在标题显示。
  /// [errorText] 非空时红框 + 红字（非法字符 / 重名校验，见 _subDirRowErrorKey）。
  Widget _dirInputField({
    required TextEditingController controller,
    FocusNode? focusNode,
    ValueChanged<String>? onChanged,
    VoidCallback? onDelete,
    String? hintText,
    String? errorText,
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
        errorText: errorText,
        errorStyle: const TextStyle(
          color: AppColors.danger,
          fontSize: 11,
          fontFamily: 'Space Mono',
          fontFamilyFallback: ['Noto Sans Mono CJK SC'],
        ),
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
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
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
            (_mode == ClassifyMode.toNewDir &&
                _subDirs.isNotEmpty &&
                // 名称非法/重复时禁用开始（红框已提示原因）。
                _newDirNamesValid));
    // 贴边底栏（Column 尾，非悬浮）：Container 背景延伸到物理底边，
    // 内部 SafeArea(top:false) 让内容避让手势条。
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
            // P2「继续」按钮:有可恢复记录(已决策会话)时出现在开始左侧;
            // 任意方向拖动推远松手即清除记录(飞出+淡出,见 ResumeButton)。
            // 无入场/收位动画——出现即到位(用户定稿),消失由按钮自身
            // 飞出动画承接后瞬时收位。
            if (_resumeAvailable) ...[
              ResumeButton(
                onResume: _resumeLastSession,
                onDismiss: _onDismissResumeBanner,
                freeDrag: true,
              ),
              const SizedBox(width: 12),
            ],
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
            const SizedBox(height: 8),
            // 永久拒绝（「不再询问」）后 requestPermissions 不再弹窗、按钮
            // 原地空转——设置页是唯一出口。
            TextButton(
              onPressed: () => _channel.openAppSettings(),
              child: Text(
                t(ref, 'open_settings'),
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 13,
                ),
              ),
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
    this.flightTag,
    this.onFlightStart,
  });
  final MsBucket bucket;
  final bool selected;
  final VoidCallback onCheckToggle;

  /// 输入法展开时点击本 tile 的回调（收键盘 + 保存）；为 null 则不拦截。
  final VoidCallback? onInterceptWhileEditing;

  /// 从相册浏览返回后的回调（刷新封面/数量——删除/恢复会改变它们）。
  final VoidCallback? onAlbumReturned;
  /// 父级飞行目标 tag（点击相册瞬间非 null，用于 HeroMode 屏蔽本 tile）。
  final String? flightTag;
  /// 点击时通知父级置位飞行目标（父级 setState 后本 tile rebuild）。
  final ValueChanged<String>? onFlightStart;
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
  /// 封面 Hero tag：动态取「网格排序后第一张」的 id（ente 封面↔第一张配对）。
  String? _heroTag;

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
                      heroTag: _heroTag,
                      heroEnabled:
                          widget.flightTag == null || widget.flightTag == _heroTag,
                      size: 44,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.bucket.name.isEmpty
                                ? tr('root_dir')
                                : widget.bucket.name,
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
    // 先无条件收键盘+清焦点链（onInterceptWhileEditing = _dismissAndFlush）：
    // 系统返回键收起键盘时 TextField 仍持焦点（viewInsets 已归 0），只凭
    // viewInsets>0 判断会漏——焦点链不清，进相册返回时输入框回焦、键盘自动
    // 弹出（2026-08 实测）。无论键盘状态都先清，再按键盘是否展开决定拦截。
    widget.onInterceptWhileEditing?.call();
    // 用 View 级 viewInsets（物理像素）而非 MediaQuery.viewInsetsOf：后者被
    // Scaffold 的 resizeToAvoidBottomInset 消费（removeViewInsets 传给 body），
    // 在 body 子树内恒为 0，无法据此判断键盘是否展开。
    if (View.of(context).viewInsets.bottom > 0) {
      return true;
    }
    return false;
  }

  /// 勾选入口：输入态先收键盘保存，不勾选。
  void _onCheckToggle() {
    if (_interceptIfEditing()) return;
    widget.onCheckToggle();
  }
  /// 导航防重入【static 全局共享】：enterBucket→读 state→push 是一长串
  /// async——双指同时点【两个不同 tile】时并发执行，两边都会从【同一个
  /// 共享 state】读 photos[0] 设 Hero tag 互踩。static 字段跨全部 tile
  /// 实例互斥：只认第一次点击。（相册页 tile 的同款根治见 gallery_screen
  /// _open——2026-09 双指黑屏系列，此处为整理流程源相册入口的同型防线。）
  static bool _navInFlight = false;

  Future<void> _openAlbum() async {
    // [GAL] 入口打点（排查"返回后点击无反应"，2026-09），同 gallery_screen。
    debugPrint('[GAL] sort-open tap bucket=${widget.bucket.id} '
        'locked=$_navInFlight');
    if (_navInFlight) return;
    if (_interceptIfEditing()) return;
    // 选择模式（本组已有相册勾选）：点击改为勾选/取消本相册，不进入浏览
    if (widget.selectionMode) {
      widget.onCheckToggle();
      return;
    }
    _navInFlight = true;
    try {
      // [ente 对齐] 相册打开 = 200ms fade + 封面 Hero 飞行（封面↔网格第一张图）。
      // 先 await enterBucket：push 时网格第一张 cell 必须已存在（Hero 终点），
      // 否则 flight 不启动（异步查询错过动画窗口）。快照命中秒回。
      // _HomeBucketTileState 非 Consumer，用 containerOf 读 controller。
      final container = ProviderScope.containerOf(context);
      final notifier = container.read(galleryControllerProvider.notifier);
      await notifier.enterBucket(widget.bucket.id);
      if (!mounted) return;
      final s = container.read(galleryControllerProvider);
      // 终局裁决（await 之后、push 之前——state 与路由栈此刻都是真实
      // 落定的，判定不依赖 tap 时序）：
      // ① state 归属：await 窗口内 state 可能已被其他入口切走——非本桶
      //   放弃导航，且不拿他桶首张做 Hero（跨桶 tag 与真实终点对不上）；
      // ② 路由栈：push 是 UI 线程同步原子操作，两个并发流只可能有一个
      //   在 push 前观测到 canPop==false——锁被绕过的任何残余场景在此
      //   必然只放行一个。
      // 输家不 push = 不打断赢家的 Hero flight（双路由 push+pop 打断
      // 飞行 = 黑 tile 残影/吞点击，2026-09 真机实证）。
      if (s.bucketId != widget.bucket.id) {
        debugPrint('[GAL] nav-abort(own) bucket=${widget.bucket.id} '
            'state=${s.bucketId}');
        return;
      }
      if (Navigator.of(context).canPop()) {
        debugPrint('[GAL] nav-abort(canPop) bucket=${widget.bucket.id}');
        return;
      }
      final photos = s.photos;
      if (photos.isNotEmpty) {
        final tag = 'photo_${photos[0].id}';
        setState(() => _heroTag = tag);
        widget.onFlightStart?.call(tag);
      }
      final args = {
        'bucketId': widget.bucket.id,
        'bucketName': widget.bucket.name,
        'bucketCount': widget.bucket.count,
      };
      await Navigator.pushNamed(context, AlbumRoutes.album, arguments: args);
      if (mounted) widget.onFlightStart?.call(''); // 清除
      // 从相册返回：刷新封面/数量（相册内可能删除了图片/改了排序）
      widget.onAlbumReturned?.call();
    } finally {
      _navInFlight = false;
    }
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
                      heroTag: _heroTag,
                      heroEnabled:
                          widget.flightTag == null || widget.flightTag == _heroTag,
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
              widget.bucket.name.isEmpty
                  ? tr('root_dir')
                  : widget.bucket.name,
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
  const _CoverThumb({
    super.key,
    required this.coverId,
    required this.size,
    this.heroTag,
    this.heroEnabled = true,
  });
  final String? coverId;
  final double size;
  /// 封面 Hero tag（网格第一张 id，enterBucket 后动态更新）；null 时用 coverId。
  final String? heroTag;
  /// 是否参与 Hero 配对：点击相册瞬间仅目标 tile 启用，屏蔽屏外预构建 tile。
  final bool heroEnabled;

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
    // [ente 对齐] 封面包 Hero：与相册网格第一张 cell 配对（封面↔第一张图飞行）。
    // heroTag 优先（网格第一张 id）；null 回退 coverId。
    return HeroMode(
      enabled: heroEnabled,
      child: Hero(
      tag: heroTag ?? 'photo_$coverId',
      flightShuttleBuilder:
          (flightContext, animation, type, fromHeroContext, toHeroContext) =>
              (toHeroContext.widget as Hero).child,
      transitionOnUserGestures: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image(
          image: buildThumbnailProvider(ref, size: 300, squareCrop: true),
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
        ),
      ),
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
/// controller 与 FocusNode、同步外部 value 变化，以及入场/退场动画包裹
/// 与快捷键标签。FocusNode 同样由行 State 持有（与 controller 同理，跨
/// rebuild 复用），并在 fieldBuilder 中交给父级——删除持焦行时可据此判断
/// 与转移焦点（见 _buildSubDirRow 的 onDelete）。
class _SubDirRow extends StatefulWidget {
  final String value;
  final String keyLabel;
  final Animation<double> animation;
  final Widget Function(
      TextEditingController controller, FocusNode focusNode) fieldBuilder;

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
  final _focusNode = FocusNode();

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
    _focusNode.dispose();
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
                Expanded(child: widget.fieldBuilder(_controller, _focusNode)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 快速整理页「ⓘ」说明弹窗内容：本页用途 + 两种整理模式区别。
/// 纯文字展示（无交互行），屏幕居中（屏宽−48，两侧各 24 边距）、
/// 卡片样式对齐选项面板（surfaceElevated / 圆角 12 / elevation 3）。
class _QuickSortTipsDialog extends ConsumerWidget {
  const _QuickSortTipsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const bodyStyle = TextStyle(
      fontFamily: 'Space Mono',
      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
      fontSize: 12,
      height: 1.6,
      color: AppColors.text,
    );
    const labelStyle = TextStyle(
      fontFamily: 'Space Mono',
      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: AppColors.text,
    );
    // 模式段：图标 + 模式名（与顶部 segmented control 同图标），说明
    // 文字 muted 弱一档，与面板行的图标 16 + 间距 8 形制一致。
    Widget modeRow(IconData icon, String label, String desc) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: labelStyle),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      style: bodyStyle.copyWith(color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    return Material(
      color: AppColors.surfaceElevated,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      // 定宽：屏宽 −48（两侧各 24 边距），大屏不再放宽（12sp 正文行宽
      // 过长难读）。
      child: SizedBox(
        width: MediaQuery.sizeOf(context).width - 48,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t(ref, 'quick_sort_tips_intro'), style: bodyStyle),
              modeRow(
                Icons.create_new_folder_outlined,
                t(ref, 'mode_to_newdir'),
                t(ref, 'quick_sort_tips_newdir'),
              ),
              modeRow(
                Icons.swap_horiz,
                t(ref, 'mode_to_album'),
                t(ref, 'quick_sort_tips_album'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自绘「ⓘ」图标（快速整理页说明按钮用）：圆圈 + 倒感叹号，顶点用
/// 主题 accent 黄绿提亮（用户定稿 2026-09）。
///
/// 形制对齐首页搜索按钮 _SearchGlyphPainter：24 基准视口、圆头笔帽；
/// 圆圈外缘（含线宽）直径 ~10.8，与搜索图形（10.5）/筛选图形（11.2）
/// 包络同量级，视觉分量一致。
class _HelpGlyphIcon extends StatelessWidget {
  const _HelpGlyphIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(28),
      painter: _HelpGlyphPainter(),
    );
  }
}

class _HelpGlyphPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..color = AppColors.text
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    // 外圈：中心 (12,12) 半径 4.5，外缘直径 4.5×2+1.8 = 10.8。
    canvas.drawCircle(const Offset(12, 12), 4.5, stroke);
    // 倒感叹号：顶点 = accent 实心小圆（唯一彩色点缀）；短竖线下引，
    // 点/线间留 ~0.6 空隙（i 的字面结构）。
    canvas.drawCircle(
      const Offset(12, 9.8),
      1.0,
      Paint()..color = AppColors.accent,
    );
    canvas.drawLine(
      const Offset(12, 12.2),
      const Offset(12, 13.8),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HelpGlyphPainter oldDelegate) => false;
}
