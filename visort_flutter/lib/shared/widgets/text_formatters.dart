// 共享输入格式化器 —— 单字母快捷键输入框通用

import 'package:flutter/services.dart';

/// 输入即时大写化(保持光标位置)。
/// 配合 `FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]'))` 的字母
/// 白名单使用:非法字符在白名单层直接不进框,小写在此转为大写。
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text == newValue.text.toUpperCase()) return newValue;
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
