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
    // 与 actionKeys 冲突：键盘优先级是 文件夹 key → Space → delete → skip
    // → undo，文件夹 key 撞 delete/skip 会让操作键静默失效（用户以为在
    // 删图、实际移进了文件夹）。updateActionKeys 已查正向，此处补反向。
    final ak = _config.activeProfileData.actionKeys;
    final actionKeys = {ak.undo, ak.delete, ak.skip}
        .map((k) => k.toLowerCase())
        .toSet();
    for (final f in folders) {
      if (actionKeys.contains(f.key.toLowerCase())) {
        return 'folder_key_used_action';
      }
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
      // 三个操作键互相冲突。返回 i18n key（此前手工双语拼接会向英文用户
      // 输出内部 label 名 "undo_label"，且绕过 i18n 体系）。
      return 'key_conflict_action';
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

  String allocateKey(List<FolderTemplate> existing) =>
      allocateFolderKey(existing);
}

/// 顶层纯函数：新增文件夹时自动分配快捷键。实例方法委托此函数——
/// 纯逻辑便于单测（HomeController 依赖 WidgetRef，构造需 widget 上下文）。
/// 按 [HomeController.keyOrder]='ASDFQWER1234' 取未占用，回退 A-Z 剩余。
String allocateFolderKey(List<FolderTemplate> existing) {
  final used = existing.map((e) => e.key.toUpperCase()).toSet();
  // 保留键（action keys + space）也算占用，但此处仅知道 folder keys，
  // action key 冲突由 updateActionKeys 兜底；这里只避免 folder 间冲突
  for (final k in HomeController.keyOrder.split('')) {
    if (!used.contains(k)) return k;
  }
  // 回退 A-Z 剩余
  for (var code = 65; code <= 90; code++) {
    final k = String.fromCharCode(code);
    if (!used.contains(k)) return k;
  }
  return '?';
}
