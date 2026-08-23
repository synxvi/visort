// 重命名对话框 —— aves rename_entry_dialog 对标
//
// 交互（与 aves 一致）：
//   - TextField 默认值 = 文件名去扩展名；扩展名以灰字固定显示在输入框右侧
//     （只改主名，扩展名不可编辑）
//   - 实时校验：非空 + 同目录无同名（channel nameExists 查询，防抖 300ms）
//   - 校验失败 Apply 置灰；提交 trimLeft + 去换行，拼回扩展名返回完整文件名
//
// 返回值：新完整文件名（含扩展名）；取消/关闭返回 null。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart' show t;
import 'package:visort_flutter/core/theme/app_colors.dart'
    show AppColors, AppFonts;

import 'spring_popup.dart' show showCenterDialog;

/// 弹出重命名对话框。返回新完整文件名（含扩展名），取消返回 null。
Future<String?> showRenameDialog(
  BuildContext context,
  WidgetRef ref, {
  required MsImageInfo photo,
}) {
  return showCenterDialog<String>(
    context: context,
    builder: (ctx) => _RenameDialog(photo: photo),
  );
}

/// 从 DISPLAY_NAME 拆扩展名（含点，小写）。无扩展名返回空串。
String _extOf(String name) {
  final i = name.lastIndexOf('.');
  return (i > 0 && i < name.length - 1) ? name.substring(i) : '';
}

class _RenameDialog extends ConsumerStatefulWidget {
  const _RenameDialog({required this.photo});
  final MsImageInfo photo;

  @override
  ConsumerState<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends ConsumerState<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: _baseName,
  );
  final ValueNotifier<bool> _isValid = ValueNotifier(false);

  /// 同名查询防抖（每次输入重置 300ms 后查询）。
  Timer? _debounce;

  String get _ext => _extOf(widget.photo.name);
  String get _baseName =>
      widget.photo.name.substring(0, widget.photo.name.length - _ext.length);

  String get _newName =>
      _controller.text.trimLeft().replaceAll('\n', '');

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // 空对话框预校验一次（初始默认值就是合法主名，通常直接通过）。
    _validate();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _isValid.dispose();
    super.dispose();
  }

  void _onChanged() {
    // 非空本地立即校验；同名远程查询防抖 300ms（每键一次查询太重）。
    final name = _newName;
    if (name.isEmpty) {
      _debounce?.cancel();
      _isValid.value = false;
      return;
    }
    // 未改名直接置灰（提交无意义）。
    if (name == _baseName) {
      _debounce?.cancel();
      _isValid.value = false;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _validate);
  }

  Future<void> _validate() async {
    final name = _newName;
    if (name.isEmpty || name == _baseName) {
      _isValid.value = false;
      return;
    }
    // 同目录同名预检（排除自身）。查询失败放行（提交时 Kotlin 再拦一道）。
    final exists = await const MediaStoreChannel()
        .nameExists(widget.photo.id, '$name$_ext');
    if (!mounted) return;
    _isValid.value = !exists;
  }

  void _submit() {
    if (!_isValid.value) return;
    Navigator.of(context).pop('$_newName$_ext');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        t(ref, 'rename'),
        style: const TextStyle(
          fontFamily: 'Space Mono',
          fontFamilyFallback: AppFonts.cjkFallback,
          color: AppColors.text,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 1,
              cursorColor: AppColors.accent,
              style: const TextStyle(
                fontFamily: 'Space Mono',
                fontFamilyFallback: AppFonts.cjkFallback,
                color: AppColors.text,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                labelText: t(ref, 'rename_dialog_label'),
                labelStyle: const TextStyle(
                  fontFamily: 'Space Mono',
                  fontFamilyFallback: AppFonts.cjkFallback,
                  color: AppColors.muted,
                  fontSize: 12,
                ),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          // 扩展名灰字（aves 同款：只改主名）
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 12),
            child: Text(
              _ext,
              style: const TextStyle(
                fontFamily: 'Space Mono',
                color: AppColors.muted,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            t(ref, 'cancel'),
            style: const TextStyle(
              color: AppColors.muted,
              fontFamily: 'Space Mono',
              fontFamilyFallback: AppFonts.cjkFallback,
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _isValid,
          builder: (context, valid, _) => TextButton(
            onPressed: valid ? _submit : null,
            child: Text(
              t(ref, 'confirm'),
              style: TextStyle(
                color: valid ? AppColors.accent : AppColors.muted,
                fontFamily: 'Space Mono',
                fontFamilyFallback: AppFonts.cjkFallback,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
