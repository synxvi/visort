// Home 控制器 —— Profile 管理 + 文件夹编辑 + 快捷键编辑
//
// 对应 Python 版:
//   - profile switch/create/delete（app.py:862-947）
//   - folders/action_keys 持久化（/api/folders autoSave，app.py:286+）
//   - 冲突检测（前端 getReservedKeys / updateActionKey / updateTemplateField）
//
// 本控制器直接操作 configProvider（AppConfig），并调 profilesService 持久化。
// 文件夹与快捷键的校验复用 profilesService.normalizeFolderTemplates。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/profiles_service.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';

class HomeController {
  HomeController(this._ref);
  final WidgetRef _ref;

  AppConfig get _config => _ref.read(configProvider);
  ProfilesService get _service => _ref.read(profilesServiceProvider);

  Future<void> _persist(AppConfig config) async {
    _ref.read(configProvider.notifier).state = config;
    await _service.save(config);
  }

  // ───────────────────────── Profile 管理 ─────────────────────────

  /// 切换 profile。失败返回错误 i18n key
  Future<String?> switchProfile(String name) async {
    if (!_config.profiles.containsKey(name)) return 'switch_profile_failed';
    await _persist(_service.switchProfile(_config, name));
    return null;
  }

  /// 新建 profile。失败返回错误 i18n key；初始目标子目录 label 按当前
  /// 语言取「通用 / General」，快捷键恒为默认 Z/X/C。
  Future<String?> createProfile(String name) async {
    final r = _service.createProfile(
      _config,
      name,
      defaultFolderLabel: t(_ref, 'default_label'),
    );
    if (r.error != null) return r.error;
    await _persist(r.config);
    return null;
  }

  /// 删除当前 profile。失败返回错误 i18n key
  Future<String?> deleteProfile(String name) async {
    final r = _service.deleteProfile(_config, name);
    if (r.error != null) return r.error;
    await _persist(r.config);
    return null;
  }

  // ───────────────────────── 文件夹编辑 ─────────────────────────

  /// 替换当前 profile 的文件夹模板（含校验）。
  /// 返回 null 表示成功，否则返回错误 i18n key。
  Future<String?> updateFolders(List<FolderTemplate> folders) async {
    try {
      // 校验（normalizeFolderTemplates 会重新构造，这里只做校验）
      _service.normalizeFolderTemplates(
          folders.map((e) => {'key': e.key, 'label': e.label}).toList());
    } on TemplateValidationException catch (e) {
      return e.i18nKey;
    }
    final profile = _config.activeProfileData.copyWith(folders: folders);
    final newProfiles = Map<String, Profile>.from(_config.profiles);
    newProfiles[_config.activeProfile] = profile;
    await _persist(_config.copyWith(profiles: newProfiles));
    return null;
  }

  // ───────────────────────── 快捷键编辑 ─────────────────────────

  /// 更新 action keys（undo/delete/skip）。
  /// 失败返回错误 i18n key（冲突检测）。
  Future<String?> updateActionKeys(ActionKeys actionKeys) async {
    // 冲突检测：三个 action key 不能互相重复、不能与文件夹 key 冲突
    final lower = [actionKeys.undo, actionKeys.delete, actionKeys.skip]
        .map((e) => e.toLowerCase())
        .toList();
    if (lower.toSet().length != lower.length) {
      // 找到重复项
      for (var i = 0; i < lower.length; i++) {
        for (var j = i + 1; j < lower.length; j++) {
          if (lower[i] == lower[j]) {
            final labels = ['undo_label', 'delete_label', 'skip_label'];
            return _ref.read(currentLanguageProvider) == 'zh'
                ? '「${actionKeys[labels[i]]}」与「${actionKeys[labels[j]]}」快捷键冲突'
                : 'Shortcut conflict between ${labels[i]} and ${labels[j]}';
          }
        }
      }
    }
    // 与文件夹 key 冲突
    for (final folder in _config.activeProfileData.folders) {
      if (lower.contains(folder.key.toLowerCase())) {
        return 'key_used_folder';
      }
    }

    final profile = _config.activeProfileData.copyWith(actionKeys: actionKeys);
    final newProfiles = Map<String, Profile>.from(_config.profiles);
    newProfiles[_config.activeProfile] = profile;
    await _persist(_config.copyWith(profiles: newProfiles));
    return null;
  }

  // ───────────────────────── 默认键分配 ─────────────────────────

  /// 新增文件夹时自动分配快捷键。
  /// 按 KEY_ORDER='ASDFQWER1234' 取未占用，回退剩余字母。
  /// 对应前端 KEY_ORDER（index.html:1258）
  static const keyOrder = 'ASDFQWER1234';

  String allocateKey(List<FolderTemplate> existing) {
    final used = existing.map((e) => e.key.toUpperCase()).toSet();
    // 保留键（action keys + space）也算占用，但此处仅知道 folder keys，
    // action key 冲突由 updateActionKeys 兜底；这里只避免 folder 间冲突
    for (final k in keyOrder.split('')) {
      if (!used.contains(k)) return k;
    }
    // 回退 A-Z 剩余
    for (var code = 65; code <= 90; code++) {
      final k = String.fromCharCode(code);
      if (!used.contains(k)) return k;
    }
    return '?';
  }
}

// 帮助函数：按 label 名取 action key 值
extension on ActionKeys {
  String operator [](String label) {
    switch (label) {
      case 'undo_label':
        return undo;
      case 'delete_label':
        return delete;
      case 'skip_label':
        return skip;
      default:
        return '';
    }
  }
}
