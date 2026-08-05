// Profiles 服务 —— 配置持久化 + Profile 管理 + 文件夹路径计算
//
// 职责：
//   - load()/save()：AppConfig ↔ JSON ↔ shared_preferences（JSON 由 AppConfig
//     自身的 toJson/fromJson 完成，本服务只负责读写 prefs）
//   - switchProfile/createProfile/deleteProfile：Profile 管理（返回新 config + 错误）
//   - computeDestinationFolders：模板 + 父目录 → 完整路径描述符
//   - normalizeFolderTemplates：模板校验 + 规范化（key 大写化、label trim）
//
// 设计：
//   - 纯 Dart，无 Riverpod 依赖（由 i18n.dart 的 profilesServiceProvider 注入）
//   - 校验规则与返回契约由 test/widget_test.dart 锁定。

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// shared_preferences 中存储 AppConfig JSON 的 key。
const _kPrefKey = 'visort_config';

/// 文件夹描述符：模板 + 完整路径（供 Session 决策时拿到 destPath）。
@immutable
class FolderDescriptor {
  const FolderDescriptor({
    required this.key,
    required this.label,
    required this.path,
  });

  final String key;
  final String label;

  /// 目标完整路径。
  /// - Windows/POSIX：`父目录/分隔符/label`
  /// - 安卓 toNewDir：父目录（tree URI）下的 label 子树
  final String path;

  @override
  String toString() => 'FolderDescriptor($key → $label @ $path)';
}

/// 模板校验异常。
///
/// [i18nKey] 指向本地化错误文案；[args] 为占位符参数（如行号、长度）。
class TemplateValidationException implements Exception {
  const TemplateValidationException(this.i18nKey, [this.args = const []]);
  final String i18nKey;
  final List<Object> args;

  @override
  String toString() => 'TemplateValidationException($i18nKey, $args)';
}

/// createProfile / deleteProfile 的返回：新配置 + 可空错误 i18n key。
typedef ProfileOpResult = ({AppConfig config, String? error});

/// 默认快捷键（新建 Profile / 缺失回退用）。
const _defaultActionKeys = ActionKeys(undo: 'Z', delete: 'X', skip: 'C');

/// Profile 管理与持久化服务。
class ProfilesService {
  /// 读取持久化配置；失败或不存在则返回默认配置。
  Future<AppConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefKey);
      if (raw == null || raw.isEmpty) return AppConfig.defaults();
      return AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // 损坏的 JSON 等异常 → 回退默认，避免启动崩溃
      return AppConfig.defaults();
    }
  }

  /// 持久化配置。
  Future<void> save(AppConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefKey, jsonEncode(config.toJson()));
    } catch (_) {
      // 写入失败静默忽略（外部存储权限等问题不阻塞 UI）
    }
  }

  // ───────────────────────── Profile 管理 ─────────────────────────

  /// 切换激活 Profile。Profile 不存在时原样返回。
  AppConfig switchProfile(AppConfig config, String name) {
    if (!config.profiles.containsKey(name)) return config;
    return config.copyWith(activeProfile: name);
  }

  /// 新建 Profile。重名返回错误；新建 Profile 使用默认快捷键。
  ProfileOpResult createProfile(AppConfig config, String name) {
    if (name.isEmpty) {
      return (config: config, error: 'profile_name_empty');
    }
    if (config.profiles.containsKey(name)) {
      return (config: config, error: 'profile_name_exists');
    }
    // 新建 Profile 复用当前激活 Profile 的文件夹结构，但用默认快捷键。
    final base = config.activeProfileData;
    final updated = config.copyWith(
      profiles: {
        ...config.profiles,
        name: Profile(
          folders: base.folders,
          actionKeys: _defaultActionKeys,
          classifyMode: base.classifyMode,
        ),
      },
      activeProfile: name,
    );
    return (config: updated, error: null);
  }

  /// 删除 Profile。最后一个 Profile 不允许删除（错误 keep_one_profile）。
  ProfileOpResult deleteProfile(AppConfig config, String name) {
    if (config.profiles.length <= 1) {
      return (config: config, error: 'keep_one_profile');
    }
    final remaining = Map<String, Profile>.from(config.profiles)..remove(name);
    final newActive = config.activeProfile == name
        ? remaining.keys.first
        : config.activeProfile;
    return (
      config: config.copyWith(profiles: remaining, activeProfile: newActive),
      error: null,
    );
  }

  // ───────────────────────── 文件夹路径计算 ─────────────────────────

  /// 由父目录 + 模板列表计算完整文件夹描述符。
  ///
  /// 路径分隔符取自父目录自身（保留其斜杠风格：`D:\Photos` → `\`，
  /// `D:/Photos/` → `/`），父目录以斜杠结尾时不再追加。
  /// 父目录为空或模板为空时返回空列表。
  List<FolderDescriptor> computeDestinationFolders(
    String destinationParent,
    List<FolderTemplate> templates,
  ) {
    if (destinationParent.isEmpty || templates.isEmpty) return const [];
    final sep = _detectSeparator(destinationParent);
    final base = destinationParent.endsWith('\\') ||
            destinationParent.endsWith('/')
        ? destinationParent.substring(0, destinationParent.length - 1)
        : destinationParent;
    return templates
        .map((t) => FolderDescriptor(
              key: t.key,
              label: t.label,
              path: '$base$sep${t.label}',
            ))
        .toList(growable: false);
  }

  /// 从路径推断分隔符：含反斜杠用 `\`，否则用 `/`。
  String _detectSeparator(String path) =>
      path.contains('\\') ? r'\' : '/';

  // ───────────────────────── 模板校验 / 规范化 ─────────────────────────

  /// 校验并规范化文件夹模板列表，返回规范化后的 [FolderTemplate] 列表
  /// （key 大写化、label trim）。校验失败抛 [TemplateValidationException]：
  ///   - 空列表           → `need_folder`
  ///   - key 非单字符     → `row_key_len`（args=[期望长度 1]）
  ///   - key 重复         → `row_dup`（args=[冲突行号，从 1 起]）
  ///   - label 空白       → `row_empty`
  List<FolderTemplate> normalizeFolderTemplates(
      List<Map<String, String>> templates) {
    if (templates.isEmpty) {
      throw const TemplateValidationException('need_folder');
    }
    final seenKeys = <String>{};
    final normalized = <FolderTemplate>[];
    for (var i = 0; i < templates.length; i++) {
      final t = templates[i];
      final key = (t['key'] ?? '').trim().toUpperCase();
      final label = (t['label'] ?? '').trim();

      if (key.length != 1) {
        throw TemplateValidationException('row_key_len', [1]);
      }
      if (label.isEmpty) {
        throw const TemplateValidationException('row_empty');
      }
      if (!seenKeys.add(key)) {
        throw TemplateValidationException('row_dup', [i + 1]);
      }
      normalized.add(FolderTemplate(key: key, label: label));
    }
    return normalized;
  }
}
