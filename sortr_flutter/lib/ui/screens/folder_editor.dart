// 文件夹编辑器 —— 独立 StatefulWidget，解决光标丢失与卡顿
//
// 优化点（修复问题三）:
//   1. TextEditingController 按 key 缓存（build 时复用，不新建 → 光标不跳）
//   2. 本地维护 templates 副本，编辑只更新本地 state（不触发 Provider 重建）
//   3. 防抖：编辑后 500ms 才持久化到磁盘（避免每键一次 IO）
//   4. 排序/删除/新增时立即持久化（这些操作不频繁）
//
// 对应前端 #folder-editor（index.html）+ autoSaveFolderTemplates

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/setup/setup_controller.dart';
import 'package:sortr_flutter/shared/widgets/toast.dart';

class FolderEditor extends ConsumerStatefulWidget {
  const FolderEditor({
    super.key,
    required this.profile,
    required this.activeProfileName,
  });
  final Profile profile;
  final String activeProfileName;

  @override
  ConsumerState<FolderEditor> createState() => _FolderEditorState();
}

class _FolderEditorState extends ConsumerState<FolderEditor> {
  /// 本地编辑副本（与 Provider 解耦，避免每键重建）
  late List<FolderTemplate> _templates;
  /// controller 缓存：按 "行标识" 缓存，避免重建时丢光标
  final Map<String, TextEditingController> _keyControllers = {};
  final Map<String, TextEditingController> _labelControllers = {};
  /// 防抖计时器
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _templates = List.of(widget.profile.folders);
  }

  /// 当外部 profile 变化（切换 profile / 删除）时同步本地副本
  /// 但不能简单覆盖，否则正在编辑的内容会丢失——仅在 templates 引用真正变化时同步
  @override
  void didUpdateWidget(FolderEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // profile 切换或 folders 数量变化时重新加载
    final newFolders = widget.profile.folders;
    if (oldWidget.activeProfileName != widget.activeProfileName ||
        newFolders.length != _templates.length ||
        !_listEqual(newFolders, _templates)) {
      _templates = List.of(newFolders);
      _pruneControllers();
    }
  }

  bool _listEqual(List<FolderTemplate> a, List<FolderTemplate> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key || a[i].label != b[i].label) return false;
    }
    return true;
  }

  /// 清理不再需要的 controller（避免内存泄漏）
  void _pruneControllers() {
    final validIds = _templates
        .asMap()
        .entries
        .map((e) => _rowId(e.key, e.value))
        .toSet();
    _keyControllers.removeWhere((k, _) => !validIds.contains(k));
    _labelControllers.removeWhere((k, _) => !validIds.contains(k));
  }

  /// 行唯一标识：用 key+label+index 组合，编辑中保持稳定
  /// 注意：用 index 而非 key/label 作为标识，因为编辑时 key/label 在变
  String _rowId(int index, FolderTemplate f) => 'row_$index';

  TextEditingController _keyCtrl(int index, FolderTemplate f) {
    final id = _rowId(index, f);
    return _keyControllers.putIfAbsent(
        id, () => TextEditingController(text: f.key));
  }

  TextEditingController _labelCtrl(int index, FolderTemplate f) {
    final id = _rowId(index, f);
    return _labelControllers.putIfAbsent(
        id, () => TextEditingController(text: f.label));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    for (final c in _labelControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 防抖持久化：500ms 无输入后写盘
  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persistNow);
  }

  Future<void> _persistNow() async {
    // 从 controller 同步最新值到 _templates
    for (var i = 0; i < _templates.length; i++) {
      final f = _templates[i];
      final kCtrl = _keyControllers[_rowId(i, f)];
      final lCtrl = _labelControllers[_rowId(i, f)];
      _templates[i] = FolderTemplate(
        key: (kCtrl?.text ?? f.key).trim().toUpperCase(),
        label: (lCtrl?.text ?? f.label).trim(),
      );
    }
    final err = await SetupController(ref).updateFolders(_templates);
    if (err != null && mounted) {
      toast(context, t(ref, err));
    }
  }

  Future<void> _reorder(int oldIdx, int newIdx) async {
    if (newIdx > oldIdx) newIdx -= 1;
    setState(() {
      final item = _templates.removeAt(oldIdx);
      _templates.insert(newIdx, item);
      // controller 也跟随移动：清空重建（重排不频繁，可接受）
      _keyControllers.clear();
      _labelControllers.clear();
    });
    // 立即持久化（无防抖）
    await SetupController(ref).updateFolders(_templates);
  }

  Future<void> _removeAt(int idx) async {
    setState(() {
      _templates.removeAt(idx);
      _keyControllers.clear();
      _labelControllers.clear();
    });
    await SetupController(ref).updateFolders(_templates);
  }

  void _addFolder() {
    final setup = SetupController(ref);
    final key = setup.allocateKey(_templates);
    setState(() {
      _templates.add(FolderTemplate(
          key: key, label: t(ref, 'category', [_templates.length + 1])));
    });
    _schedulePersist();
  }

  @override
  Widget build(BuildContext context) {
    final title =
        '${widget.activeProfileName}${t(ref, 'target_subdirs_suffix')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: title),
        const SizedBox(height: 12),
        ReorderableListView.builder(
          buildDefaultDragHandles: false,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _templates.length,
          onReorder: _reorder,
          itemBuilder: (ctx, idx) {
            final f = _templates[idx];
            return Padding(
              key: ValueKey('row-$idx'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: TextField(
                      controller: _keyCtrl(idx, f),
                      textAlign: TextAlign.center,
                      maxLength: 1,
                      style: const TextStyle(
                          fontFamily: 'Space Mono', height: 1.2,
                          fontFamilyFallback: AppFonts.cjkFallback),
                      decoration: const InputDecoration(
                        counterText: '',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onChanged: (_) => _schedulePersist(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _labelCtrl(idx, f),
                      style: const TextStyle(
                          fontFamily: 'Space Mono', height: 1.2,
                          fontFamilyFallback: AppFonts.cjkFallback),
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onChanged: (_) => _schedulePersist(),
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: idx,
                    child: const Tooltip(
                      message: 'Drag to reorder',
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.drag_indicator,
                            size: 20, color: AppColors.muted),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t(ref, 'remove'),
                    icon: const Icon(Icons.close, size: 20),
                    color: AppColors.muted,
                    onPressed: () => _removeAt(idx),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addFolder,
            icon: const Icon(Icons.add),
            label: Text(t(ref, 'add_folder')),
          ),
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
            fontFamily: 'Space Mono', height: 1.2,
            fontFamilyFallback: AppFonts.cjkFallback,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
            letterSpacing: 0.5));
  }
}
