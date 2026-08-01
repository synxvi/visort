// i18n 核心 —— 翻译函数 + 当前语言 Provider
//
// 对应前端 t(key, args) 与 applyLang()（index.html:1199-1203, 1001）：
//   - 支持 {0} {1} 占位符替换
//   - 回退顺序: currentLang → en → key 本身
//
// 当前语言由 configProvider.language 驱动（'en' | 'zh'）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/models.dart';
import '../config/profiles_service.dart';
import 'strings_en.dart';
import 'strings_zh.dart';

/// 支持的语言
const supportedLocales = ['en', 'zh'];

/// 翻译函数（纯函数，不依赖 Provider，便于在非 Widget 上下文使用）
String tr(String key, [List<Object> args = const []]) {
  return _translate(_currentLangOverride, key, args);
}

// 全局语言覆盖（仅供 tr() 这种无 context 调用使用；正常 UI 走 t()）
String _currentLangOverride = 'en';

/// 翻译（带 Riverpod 上下文版本，会跟随当前语言）
String t(WidgetRef ref, String key, [List<Object> args = const []]) {
  final lang = ref.watch(currentLanguageProvider);
  _currentLangOverride = lang; // 同步给 tr()
  return _translate(lang, key, args);
}

String _translate(String lang, String key, List<Object> args) {
  final dict = lang == 'zh' ? stringsZh : stringsEn;
  var value = dict[key] ?? stringsEn[key] ?? key;
  // 替换 {0} {1} ... 占位符
  for (var i = 0; i < args.length; i++) {
    value = value.replaceAll('{$i}', args[i].toString());
  }
  return value;
}

// ───────────────────────── Provider 接线 ─────────────────────────

/// 当前语言 Provider，由 config 派生
final currentLanguageProvider = Provider<String>((ref) {
  final config = ref.watch(configProvider);
  return config.language;
});

/// 切换语言。对应 Python POST /api/lang（app.py:421-431）
Future<void> setLanguage(WidgetRef ref, String lang) async {
  if (!supportedLocales.contains(lang)) return;
  final service = ref.read(profilesServiceProvider);
  final config = ref.read(configProvider);
  final updated = config.copyWith(language: lang);
  ref.read(configProvider.notifier).state = updated;
  await service.save(updated);
}

/// 全局配置状态 Provider（应用启动时由 main 注入加载后的配置）
final configProvider = StateProvider<AppConfig>((ref) => AppConfig.defaults());

/// ProfilesService 单例 Provider
final profilesServiceProvider = Provider<ProfilesService>((ref) {
  return ProfilesService();
});
