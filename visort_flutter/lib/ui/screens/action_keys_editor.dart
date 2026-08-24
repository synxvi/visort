// Action Keys 编辑器 —— 独立组件，缓存 controller + 防抖持久化
//
// 对应前端 #action-keys-editor（undo/delete/skip 三个键）
// 同 FolderEditor 的优化思路：controller 缓存 + 500ms 防抖

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/home/home_controller.dart';
import 'package:visort_flutter/shared/widgets/text_formatters.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';

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

  /// 各字段上次有效值(冲突时回退,不留在非法状态)。
  final Map<String, String> _last = {};

  @override
  void initState() {
    super.initState();
    final ak = widget.actionKeys;
    _undoCtrl = TextEditingController(text: ak.undo);
    _deleteCtrl = TextEditingController(text: ak.delete);
    _skipCtrl = TextEditingController(text: ak.skip);
    _last['undo'] = ak.undo;
    _last['delete'] = ak.delete;
    _last['skip'] = ak.skip;
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
    final err = await HomeController(ref).updateActionKeys(ak);
    if (err != null && mounted) toast(context, t(ref, err));
  }

  /// 输入即时校验:与其他两个快捷键或当前 profile 的文件夹 key 重复时,
  /// 立即回退为之前的字符并 toast 提示(非法字符已在 formatter 层拦截)。
  void _onFieldChanged(
      String field, TextEditingController self, List<TextEditingController> others) {
    final v = self.text.trim().toUpperCase();
    final prev = _last[field] ?? '';
    if (v == prev) {
      _schedulePersist();
      return;
    }
    // 与其他快捷键冲突
    for (final o in others) {
      final ov = o.text.trim().toUpperCase();
      if (ov.isNotEmpty && ov == v) {
        self.text = prev;
        toast(context, t(ref, 'key_dup_action', [v]));
        return;
      }
    }
    // 与文件夹 key 冲突
    final folders = ref.read(configProvider).activeProfileData.folders;
    for (final f in folders) {
      if (f.key.toUpperCase() == v) {
        self.text = prev;
        toast(context, t(ref, 'key_used_folder', [v, f.label]));
        return;
      }
    }
    _last[field] = v;
    _schedulePersist();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _field(t(ref, 'undo_label'), 'undo', _undoCtrl,
                [_deleteCtrl, _skipCtrl]),
            const SizedBox(width: 12),
            _field(t(ref, 'delete_label'), 'delete', _deleteCtrl,
                [_undoCtrl, _skipCtrl]),
            const SizedBox(width: 12),
            _field(t(ref, 'skip_label'), 'skip', _skipCtrl,
                [_undoCtrl, _deleteCtrl]),
          ],
        ),
      ],
    );
  }

  Widget _field(String label, String field, TextEditingController ctrl,
      List<TextEditingController> others) {
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
            // 输入约束:非法字符(非字母)不进框;小写自动转大写。
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
              UpperCaseTextFormatter(),
            ],
            style: const TextStyle(
                fontFamily: 'Space Mono', height: 1.2,
                fontFamilyFallback: AppFonts.cjkFallback),
            decoration: const InputDecoration(
              counterText: '',
              contentPadding: EdgeInsets.symmetric(horizontal: 8),
            ),
            onChanged: (_) => _onFieldChanged(field, ctrl, others),
          ),
        ),
      ],
    );
  }
}
