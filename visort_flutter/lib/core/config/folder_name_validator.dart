// 目录名（将作为 RELATIVE_PATH / 文件系统路径组件）合法性 + 重复校验。
//
// 纯函数、无 Flutter 依赖，便于单测（test/folder_name_validator_test.dart）。
// 校验规则：
//   - 非法字符：路径分隔符（/ \）+ Windows 保留字符（: * ? " < > |）+ null
//   - `.` / `..`：路径穿越
//   - Windows 保留设备名（CON/COM1…）与结尾点/空格：作为目录组件在
//     Windows 上创建必失败（审查 F12，目标平台之一）
//   - 重复：与其他行「有效名」相同（空行兜底 folder N，与 Home 的
//     _buildNewDirFolders 一致）

/// 目录名非法字符集合的正则。
final RegExp folderNameIllegalRe = RegExp(r'[/\\:*?"<>|\x00]');

/// Windows 保留设备名（不分大小写；CON.txt 带扩展名形式同样非法）。
const _windowsReservedNames = {
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// 单个目录名是否合法。返回错误文案 key（null=合法）。
/// 空名视为合法（空行走 folder N 兜底，不算错）。
String? folderNameInvalidKey(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  if (folderNameIllegalRe.hasMatch(trimmed) ||
      trimmed == '.' ||
      trimmed == '..') {
    return 'folder_name_invalid_char';
  }
  final base = trimmed.split('.').first.toUpperCase();
  if (_windowsReservedNames.contains(base) ||
      trimmed.endsWith('.') ||
      trimmed.endsWith(' ')) {
    return 'folder_name_invalid_char';
  }
  return null;
}

/// 第 [i] 行的有效名（空行按 folder N 兜底，N 从 1 起）。
String folderEffectiveName(int i, List<String> names) {
  final t = names[i].trim();
  return t.isEmpty ? 'folder${i + 1}' : t;
}

/// 第 [idx] 行是否与其他行重名。返回错误文案 key（null=不重复）。
/// 空行不报错（兜底名与行号绑定，天然唯一）。
String? folderNameDupKey(int idx, List<String> names) {
  if (names[idx].trim().isEmpty) return null;
  final target = folderEffectiveName(idx, names);
  for (var i = 0; i < names.length; i++) {
    if (i != idx && folderEffectiveName(i, names) == target) {
      return 'folder_name_dup';
    }
  }
  return null;
}
