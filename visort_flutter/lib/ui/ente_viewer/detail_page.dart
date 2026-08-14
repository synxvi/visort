// [ente 移植] 大图浏览页 —— 基于 ente detail_page.dart（PageView + 全屏 + 手势）
//
// 保留（与 ente 完全一致）：
//   - PageView.builder + FastScrollPhysics(speedFactor:4) 翻页惯性
//   - HeroMode(enabled: index == selectedIndex)：只有当前页启 Hero
//   - 缩放中禁用翻页（shouldDisableScroll → NeverScrollableScrollPhysics）
//   - 全屏切换：顶/底栏 AnimatedOpacity 200ms 淡出（enableFullScreenNotifier）
//   - 删除补位 animateToPage 200ms easeInOut
//   - 底部渐隐 scrim（透明→黑 0.6→0.72）
//   - 上滑详情（onSwipeUp → 底部信息面板）
//
// 适配 visort：
//   - EnteFile → MsImageInfo；操作走 galleryController（MediaStore）
//   - 删除 OCR/QR/社交/全景/编辑/guest/共享/云端（不含视频播放）
//   - 栏位精简（顶栏：返回+序号+收藏+删除；底栏：详情+删除/恢复）
//   - i18n 先中文硬编码（后续接 visort t()）

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';

import 'detail_page_state.dart';
import 'fast_scroll_physics.dart';
import 'zoomable_image.dart';

/// 底部 scrim 高度（ente _galleryBottomBarHeight 同值）。
const double _kBottomBarHeight = 68.0;

class DetailPage extends ConsumerStatefulWidget {
  final List<MsImageInfo> files;
  final int initialIndex;
  /// 翻页回调：网格滚动到当前行（Hero pop 时 cell 在视口才找得到飞行目标）。
  final ValueChanged<int>? onIndexChanged;

  const DetailPage({
    super.key,
    required this.files,
    required this.initialIndex,
    this.onIndexChanged,
  });

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  late final PageController _pageController;
  late final ValueNotifier<int> _selectedIndexNotifier;
  late List<MsImageInfo> _files;
  bool _shouldDisableScroll = false;
  bool _swipeLocked = false;

  final ValueNotifier<bool> enableFullScreenNotifier = ValueNotifier(false);
  final ValueNotifier<bool> isZoomedNotifier = ValueNotifier(false);
  final ValueNotifier<ZoomTransform> zoomTransformNotifier =
      ValueNotifier(ZoomTransform.identity);
  final ValueNotifier<bool> isInSharedCollectionNotifier =
      ValueNotifier(false);
  final ValueNotifier<String?> showingThumbnailFallbackNotifier =
      ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _files = List.of(widget.files);
    _selectedIndexNotifier = ValueNotifier(widget.initialIndex);
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _selectedIndexNotifier.dispose();
    enableFullScreenNotifier.dispose();
    isZoomedNotifier.dispose();
    zoomTransformNotifier.dispose();
    isInSharedCollectionNotifier.dispose();
    showingThumbnailFallbackNotifier.dispose();
    super.dispose();
  }

  MsImageInfo? get _selectedFile => _fileAt(_selectedIndexNotifier.value);

  MsImageInfo? _fileAt(int index) {
    if (index < 0 || index >= _files.length) return null;
    return _files[index];
  }

  @override
  Widget build(BuildContext context) {
    if (_files.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.maybePop(context);
      });
      return const Scaffold(backgroundColor: Colors.black);
    }
    return InheritedDetailPageState(
      enableFullScreenNotifier: enableFullScreenNotifier,
      isInSharedCollectionNotifier: isInSharedCollectionNotifier,
      showingThumbnailFallbackNotifier: showingThumbnailFallbackNotifier,
      isZoomedNotifier: isZoomedNotifier,
      zoomTransformNotifier: zoomTransformNotifier,
      child: PopScope(
        canPop: true,
        child: Scaffold(
          extendBodyBehindAppBar: true,
          resizeToAvoidBottomInset: false,
          backgroundColor: Colors.black,
          body: Center(
            child: Stack(
              children: [
                _buildPageView(),
                // 顶栏
                _buildTopBar(),
                // 底栏 + scrim
                _buildBottomOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageView() {
    return PageView.builder(
      clipBehavior: Clip.none,
      itemBuilder: (context, index) {
        final file = _files[index];
        _preloadFiles(index);
        final fileContent = ZoomableImage(
          file,
          tagPrefix: 'photo',
          shouldDisableScroll: (value) {
            if (_shouldDisableScroll != value) {
              setState(() => _shouldDisableScroll = value);
            }
          },
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          onSwipeUp: () => _showDetails(file),
          onFullLoaded: (_) {},
        );
        final page = GestureDetector(
          onTap: () {
            InheritedDetailPageState.of(context).toggleFullScreenByUser();
          },
          child: fileContent,
        );
        return ValueListenableBuilder(
          valueListenable: _selectedIndexNotifier,
          builder: (context, selectedIndex, _) =>
              HeroMode(enabled: index == selectedIndex, child: page),
        );
      },
      onPageChanged: (index) {
        if (_selectedIndexNotifier.value == index) {
          // 文件数可能已变但索引未变（ente 同款）。
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          _selectedIndexNotifier.notifyListeners();
        } else {
          _selectedIndexNotifier.value = index;
        }
        widget.onIndexChanged?.call(index);
      },
      physics: _shouldDisableScroll || _swipeLocked
          ? const NeverScrollableScrollPhysics()
          : const FastScrollPhysics(speedFactor: 4.0),
      controller: _pageController,
      itemCount: _files.length,
    );
  }

  void _preloadFiles(int index) {
    // 图片由 ImageCache + allowImplicitScrolling 预渲染处理，无需显式预加载
    //（ente 有服务端预取；visort 本地 MediaStore 读取快，跳过）。
  }

  Widget _buildTopBar() {
    return ValueListenableBuilder<int>(
      valueListenable: _selectedIndexNotifier,
      builder: (context, selectedIndex, _) {
        final file = _fileAt(selectedIndex);
        if (file == null) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: enableFullScreenNotifier,
          builder: (context, isFullScreen, _) {
            return IgnorePointer(
              ignoring: isFullScreen,
              child: AnimatedOpacity(
                opacity: isFullScreen ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      Expanded(
                        child: Text(
                          '${selectedIndex + 1} / ${_files.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontFamily: 'Space Mono',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: isZoomedNotifier,
                        builder: (context, zoomed, _) {
                          return IconButton(
                            icon: Icon(
                              file.isFavorite
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: file.isFavorite
                                  ? const Color(0xFFE53935)
                                  : Colors.white,
                            ),
                            onPressed: zoomed ? null : () => _toggleFavorite(file),
                          );
                        },
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        color: const Color(0xFF252525),
                        onSelected: (v) {
                          switch (v) {
                            case 'delete':
                              _confirmDelete(file);
                              break;
                            case 'restore':
                              _confirmRestore(file);
                              break;
                            case 'delete_forever':
                              _confirmDeleteForever(file);
                              break;
                          }
                        },
                        itemBuilder: (ctx) => [
                          if (!file.isTrashed)
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('移到回收站',
                                  style: TextStyle(color: Colors.white)),
                            )
                          else ...[
                            const PopupMenuItem(
                              value: 'restore',
                              child: Text('恢复',
                                  style: TextStyle(color: Colors.white)),
                            ),
                            const PopupMenuItem(
                              value: 'delete_forever',
                              child: Text('彻底删除',
                                  style: TextStyle(color: Color(0xFFE53935))),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomOverlay() {
    final safePadding = MediaQuery.paddingOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: enableFullScreenNotifier,
      builder: (context, isFullScreen, _) {
        return IgnorePointer(
          ignoring: isFullScreen,
          child: AnimatedOpacity(
            opacity: isFullScreen ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.bottomCenter,
                  child: IgnorePointer(
                    child: SizedBox(
                      width: double.infinity,
                      height: safePadding.bottom + _kBottomBarHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.6),
                              Colors.black.withValues(alpha: 0.72),
                            ],
                            stops: const [0, 0.8, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: safePadding.bottom,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.info_outline,
                            color: Colors.white),
                        tooltip: '详情',
                        onPressed: () => _showDetails(_selectedFile),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ──────────── 操作（visort galleryController / MediaStore） ────────────

  Future<void> _toggleFavorite(MsImageInfo file) async {
    await ref
        .read(galleryControllerProvider.notifier)
        .setFavorites([file.id], !file.isFavorite);
    if (mounted) {
      setState(() {
        final i = _files.indexWhere((f) => f.id == file.id);
        if (i >= 0) {
          _files[i] = MsImageInfo(
            id: file.id,
            name: file.name,
            size: file.size,
            mime: file.mime,
            bucketId: file.bucketId,
            dateAddedMs: file.dateAddedMs,
            dateModifiedMs: file.dateModifiedMs,
            isFavorite: !file.isFavorite,
            isTrashed: file.isTrashed,
            dateTrashedMs: file.dateTrashedMs,
            width: file.width,
            height: file.height,
          );
        }
      });
    }
  }

  Future<void> _confirmDelete(MsImageInfo file) async {
    final ok = await _confirm('移到回收站？', '可从回收站恢复');
    if (ok != true || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .trashPhoto(file.id);
    if (err != null) {
      if (mounted) _toast('删除失败');
      return;
    }
    _onFileRemoved();
  }

  Future<void> _confirmRestore(MsImageInfo file) async {
    final ok = await _confirm('恢复这张照片？', '');
    if (ok != true || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .restorePhoto(file.id);
    if (err != null) {
      if (mounted) _toast('恢复失败');
      return;
    }
    _onFileRemoved();
  }

  Future<void> _confirmDeleteForever(MsImageInfo file) async {
    final ok = await _confirm('彻底删除？', '不可恢复');
    if (ok != true || !mounted) return;
    final err = await ref
        .read(galleryControllerProvider.notifier)
        .deletePhoto(file.id);
    if (err != null) {
      if (mounted) _toast('删除失败');
      return;
    }
    _onFileRemoved();
  }

  Future<bool?> _confirm(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252525),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: content.isEmpty
            ? null
            : Text(content, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认',
                style: TextStyle(color: Color(0xFF4FC3F7))),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF333333),
        ),
      );
  }

  /// 删除/恢复当前项后补位（ente 同款：animateToPage 200ms easeInOut）。
  void _onFileRemoved() {
    if (!mounted) return;
    final totalFiles = _files.length;
    if (totalFiles <= 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _files.removeAt(_selectedIndexNotifier.value);
      _selectedIndexNotifier.value = min(
        _selectedIndexNotifier.value,
        totalFiles - 2,
      );
    });
    final currentPageIndex = _pageController.page!.round();
    final int targetPageIndex = _files.length > currentPageIndex
        ? currentPageIndex
        : currentPageIndex - 1;
    if (_files.isNotEmpty) {
      unawaited(
        _pageController.animateToPage(
          targetPageIndex,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        ),
      );
    }
  }

  /// 上滑 → 详情信息面板（简化版：基本信息弹层；后续可接 visort 详情面板）。
  void _showDetails(MsImageInfo? file) {
    if (file == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${file.width} × ${file.height} px  ·  '
                '${(file.size / 1024 / 1024).toStringAsFixed(2)} MB',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
