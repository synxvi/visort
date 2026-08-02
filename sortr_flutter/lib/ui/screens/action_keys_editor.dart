// Action Keys 编辑器 —— 独立组件，缓存 controller + 防抖持久化
//
// 对应前端 #action-keys-editor（undo/delete/skip 三个键）
// 同 FolderEditor 的优化思路：controller 缓存 + 500ms 防抖

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sortr_flutter/core/config/models.dart';
import 'package:sortr_flutter/core/i18n/i18n.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';
import 'package:sortr_flutter/features/setup/setup_controller.dart';
import 'package:sortr_flutter/shared/widgets/toast.dart';

class ActionKeysEditor extends ConsumerStatefulWidget {
  const ActionKeysEditor({super.key, required this.actionKeys});
  final ActionKeys actionKeys;

  @override
  ConsumerState<ActionKeysEditor> createState() => _ActionKeysEditorState();
}

class _ActionKeysEditorState extends ConsumerState<ActionKeysEditor> {
  late TextEditingController _undoCtrl;
  late TextEditingController _deleteCtrl;
  late TextEditingController _skipCtrl;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final ak = widget.actionKeys;
    _undoCtrl = TextEditingController(text: ak.undo);
    _deleteCtrl = TextEditingController(text: ak.delete);
    _skipCtrl = TextEditingController(text: ak.skip);
  }

  @override
  void didUpdateWidget(ActionKeysEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ak = widget.actionKeys;
    // 仅在外部值与当前 controller 不一致时同步（避免编辑中被覆盖）
    if (ak.undo != _undoCtrl.text) _undoCtrl.text = ak.undo;
    if (ak.delete != _deleteCtrl.text) _deleteCtrl.text = ak.delete;
    if (ak.skip != _skipCtrl.text) _skipCtrl.text = ak.skip;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _undoCtrl.dispose();
    _deleteCtrl.dispose();
    _skipCtrl.dispose();
    super.dispose();
  }

  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persistNow);
  }

  Future<void> _persistNow() async {
    final ak = ActionKeys(
      undo: _undoCtrl.text.trim().toUpperCase(),
      delete: _deleteCtrl.text.trim().toUpperCase(),
      skip: _skipCtrl.text.trim().toUpperCase(),
    );
    final err = await SetupController(ref).updateActionKeys(ak);
    if (err != null && mounted) toast(context, t(ref, err));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _field(t(ref, 'undo_label'), _undoCtrl),
            const SizedBox(width: 12),
            _field(t(ref, 'delete_label'), _deleteCtrl),
            const SizedBox(width: 12),
            _field(t(ref, 'skip_label'), _skipCtrl),
          ],
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontFamily: 'Space Mono', height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback,
                fontSize: 11,
                color: AppColors.muted)),
        const SizedBox(height: 4),
        SizedBox(
          width: 64,
          child: TextField(
            controller: ctrl,
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
      ],
    );
  }
}
