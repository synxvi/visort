// 配置模型单元测试 —— 验证 W1 核心数据结构
// 验证：默认值、JSON 往返、normalize 校验规则、profile 增删

import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/config/profiles_service.dart';

void main() {
  group('AppConfig 默认值', () {
    test('默认配置正确', () {
      final c = AppConfig.defaults();
      expect(c.activeProfile, 'Default');
      expect(c.profiles, contains('Default'));
      expect(c.language, 'system'); // 默认跟随系统语言（曾为 'en'，i18n 改造后更新）
      expect(c.lastSourceDir, '');
      expect(c.lastDestParent, '');
      final p = c.activeProfileData;
      // defaults 单 Profile 空 folders（首启动用户自建；曾含单个
      // key='A'/label='General' 模板，语义演变后测试同步更新）。
      expect(p.folders, isEmpty);
      expect(p.actionKeys.undo, 'Z');
      expect(p.actionKeys.delete, 'X');
      expect(p.actionKeys.skip, 'C');
    });
  });

  group('JSON 往返', () {
    test('toJson / fromJson 可逆', () {
      final original = AppConfig(
        activeProfile: 'Work',
        profiles: {
          'Work': Profile(
            folders: [
              FolderTemplate(key: 'A', label: 'Photos'),
              FolderTemplate(key: 'S', label: 'Screens'),
            ],
            actionKeys: ActionKeys(undo: 'Z', delete: 'X', skip: 'C'),
          ),
        },
        language: 'zh',
        lastSourceDir: 'D:/src',
        lastDestParent: 'D:/dest',
      );
      final json = original.toJson();
      final restored = AppConfig.fromJson(json);
      expect(restored.activeProfile, 'Work');
      expect(restored.language, 'zh');
      expect(restored.lastSourceDir, 'D:/src');
      expect(restored.profiles['Work']!.folders.length, 2);
      expect(restored.profiles['Work']!.folders[0].label, 'Photos');
    });

    test('裸列表（旧格式）兼容为 Default profile', () {
      final restored = AppConfig.fromJson({
        'active_profile': 'Default',
        'profiles': [
          {'key': 'a', 'label': 'x'}
        ],
      });
      // key 统一大写
      expect(restored.profiles['Default']!.folders.single.key, 'A');
      expect(restored.profiles['Default']!.folders.single.label, 'x');
    });
  });

  group('normalizeFolderTemplates 校验', () {
    final service = ProfilesService();

    test('空列表 → need_folder', () {
      try {
        service.normalizeFolderTemplates([]);
        fail('应抛异常');
      } on TemplateValidationException catch (e) {
        expect(e.i18nKey, 'need_folder');
      }
    });

    test('key 非 1 字符 → row_key_len', () {
      try {
        service.normalizeFolderTemplates([
          {'key': 'AB', 'label': 'x'}
        ]);
        fail('应抛异常');
      } on TemplateValidationException catch (e) {
        expect(e.i18nKey, 'row_key_len');
        expect(e.args.first, 1);
      }
    });

    test('key 重复 → row_dup', () {
      try {
        service.normalizeFolderTemplates([
          {'key': 'a', 'label': 'x'},
          {'key': 'A', 'label': 'y'},
        ]);
        fail('应抛异常');
      } on TemplateValidationException catch (e) {
        expect(e.i18nKey, 'row_dup');
        expect(e.args[0], 2);
      }
    });

    test('label 空 → row_empty', () {
      try {
        service.normalizeFolderTemplates([
          {'key': 'a', 'label': '   '}
        ]);
        fail('应抛异常');
      } on TemplateValidationException catch (e) {
        expect(e.i18nKey, 'row_empty');
      }
    });

    test('合法输入 → key 大写化、label trim', () {
      final result = service.normalizeFolderTemplates([
        {'key': 'a', 'label': '  Photos  '},
        {'key': 's', 'label': 'Screens'},
      ]);
      expect(result[0].key, 'A');
      expect(result[0].label, 'Photos');
      expect(result[1].key, 'S');
    });
  });

  group('computeDestinationFolders', () {
    final service = ProfilesService();

    test('Windows 反斜杠分隔', () {
      final dirs = service.computeDestinationFolders(
        r'D:\Photos',
        [FolderTemplate(key: 'A', label: 'General')],
      );
      expect(dirs.single.path, r'D:\Photos\General');
    });

    test('正斜杠分隔', () {
      final dirs = service.computeDestinationFolders(
        'D:/Photos/',
        [FolderTemplate(key: 'A', label: 'General')],
      );
      expect(dirs.single.path, 'D:/Photos/General');
    });
  });

  group('Profile 增删', () {
    final service = ProfilesService();

    test('新建 profile', () {
      var config = AppConfig.defaults();
      final r = service.createProfile(config, 'Work');
      config = r.config;
      expect(r.error, isNull);
      expect(config.profiles, contains('Work'));
      expect(config.activeProfile, 'Work');
      // 新建用默认 action_keys（Z/X/C）
      expect(config.profiles['Work']!.actionKeys.delete, 'X');
      // 全新初始状态：不复制当前 profile——目标子目录仅一条默认模板
      final folders = config.profiles['Work']!.folders;
      expect(folders.length, 1);
      expect(folders.single.key, 'A');
      expect(folders.single.label, 'General');
    });

    test('禁止删除最后一个 profile', () {
      var config = AppConfig.defaults();
      final r = service.deleteProfile(config, 'Default');
      expect(r.error, 'keep_one_profile');
      expect(config.profiles.length, 1);
    });

    test('删除 active 后自动切换', () {
      var config = AppConfig.defaults();
      config = service.createProfile(config, 'Work').config;
      final r = service.deleteProfile(config, 'Work');
      config = r.config;
      expect(config.activeProfile, 'Default');
    });
  });
}
