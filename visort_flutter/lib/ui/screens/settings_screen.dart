// 设置屏 —— 分组卡片式（iOS / Material Settings 风格）
//
// 信息架构：section header（分组标题）+ 卡片（组内项以缩进分隔线关联）。
// 设计原则：网格列数属「首页」组的第二项（与布局同卡、分隔线关联），
//           而非缩进子项——避免「缩进错位」的视觉歧义，层级靠卡片聚合表达。
// 相册网格列数独属「相册」组。
// 选择器：弹簧菜单 showSpringPopupFromAnchor，宽度自适应、右缘对齐箭头、从 ▾ 弹出；
//         弹窗底色 surfaceElevated（比卡片 surface 提亮，层级区分）。
// 改动即时写回 configProvider 并持久化（shared_preferences）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final isGrid = config.homeLayout == HomeLayout.grid;
    final suffix = t(ref, 'cols_unit');
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        title: Text(t(ref, 'settings_title'),
            style: const TextStyle(
              fontFamily: 'Space Mono', height: 1.2,
              fontFamilyFallback: AppFonts.cjkFallback,
              fontSize: 16,
            )),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          // ── 通用 ──
          _SectionHeader(t(ref, 'settings_section_general')),
          _SettingsCard(
            children: [
              // 语言两态：中文 / English。无「跟随系统」——首启时 main()
              // 已按系统语言决断一次并落定（zh 或 en，见 main.dart），此后
              // 只靠用户手动切换。原首页 logo / sort 屏的中英切换按钮已移除，
              // 统一收口到此处。
              _PickerRow<String>(
                label: t(ref, 'lang_setting'),
                value: config.language == 'zh' ? 'zh' : 'en',
                valueLabel: config.language == 'zh' ? '中文' : 'English',
                options: const [
                  ('zh', '中文'),
                  ('en', 'English'),
                ],
                onSelected: (v) => setLanguage(ref, v),
              ),
            ],
          ),
          // ── 首页 ──
          _SectionHeader(t(ref, 'settings_section_home')),
          _SettingsCard(
            children: [
              _PickerRow<HomeLayout>(
                label: t(ref, 'settings_home_layout'),
                value: config.homeLayout,
                valueLabel:
                    isGrid ? t(ref, 'layout_grid') : t(ref, 'layout_list'),
                options: [
                  (HomeLayout.list, t(ref, 'layout_list')),
                  (HomeLayout.grid, t(ref, 'layout_grid')),
                ],
                onSelected: (v) => _update(ref, homeLayout: v),
              ),
              if (isGrid)
                _PickerRow<int>(
                  label: t(ref, 'settings_home_grid_cols'),
                  value: config.homeGridColumns,
                  valueLabel: '${config.homeGridColumns} $suffix',
                  options: [(3, '3 $suffix'), (4, '4 $suffix')],
                  onSelected: (v) => _update(ref, homeGridColumns: v),
                ),
            ],
          ),
          // ── 相册 ──
          _SectionHeader(t(ref, 'settings_section_album')),
          _SettingsCard(
            children: [
              _PickerRow<int>(
                label: t(ref, 'settings_album_grid_cols'),
                value: config.photoGridColumns,
                valueLabel: '${config.photoGridColumns} $suffix',
                options: [
                  (2, '2 $suffix'),
                  (3, '3 $suffix'),
                  (4, '4 $suffix'),
                  (5, '5 $suffix'),
                ],
                onSelected: (v) => _update(ref, photoGridColumns: v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 写回 configProvider + 持久化（与 _setAlbumSort 同模式）。
  Future<void> _update(
    WidgetRef ref, {
    HomeLayout? homeLayout,
    int? homeGridColumns,
    int? photoGridColumns,
  }) async {
    final updated = ref.read(configProvider).copyWith(
          homeLayout: homeLayout,
          homeGridColumns: homeGridColumns,
          photoGridColumns: photoGridColumns,
        );
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
  }
}

/// 分组标题：小号 muted 全大写感文字，左对齐，上宽下窄内边距。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.muted,
          fontFamily: 'Space Mono', height: 1.2,
          fontFamilyFallback: AppFonts.cjkFallback,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// 分组卡片：surface 底 + 圆角，组内项间以缩进分隔线关联（左对齐文字）。
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 0.5,
                indent: 16,
                color: AppColors.border,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 设置行：标题 + 当前值 + ▾。点击弹弹簧菜单（showSpringPopupFromAnchor）。
/// 菜单宽度自适应内容、右缘对齐箭头（卡片右−16），从 ▾ 正下方弹簧展开。
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.options,
    required this.onSelected,
  });
  final String label;
  final String valueLabel;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _openMenu(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text(label,
                style: const TextStyle(
                  color: AppColors.text,
                  fontFamily: 'Space Mono', height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 14,
                )),
            const Spacer(),
            Text(valueLabel,
                style:
                    const TextStyle(fontFamily: 'Space Mono', fontFamilyFallback: ['Noto Sans Mono CJK SC'], color: AppColors.muted, fontSize: 13)),
            const Icon(Icons.keyboard_arrow_down,
                color: AppColors.muted, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    // 菜单右缘 = 卡片右 − 16（对齐 ▾ 箭头）
    final rightEdge = pos.dx + box.size.width - 16;
    // 菜单宽度按内容测量，供 showSpringPopupFromAnchor 精确定位弹簧支点。
    final menuWidth = _measureMenuWidth(context);
    // 用 showSpringPopupFromAnchor：弹簧缩放作用在菜单本体（非全屏 Stack），
    // 以「▾ 正下方 × 菜单顶边」为支点 —— 与首页 ⋮ 弹窗同款"从触发处长出"。
    final selected = await showSpringPopupFromAnchor<T>(
      context: context,
      barrierLabel: 'picker',
      // 支点 x = ▾ 中心（行右缘 - padding16 - ▾半宽10）；y = 菜单顶边（= menuTop）。
      anchorGlobalDx: pos.dx + box.size.width - 26,
      anchorGlobalDy: pos.dy + box.size.height + 4,
      menuLeft: rightEdge - menuWidth, // 右缘对齐 rightEdge
      menuTop: pos.dy + box.size.height + 4,
      menuWidth: menuWidth,
      // 自定义菜单（Material + Column.min）：宽度纯按内容，无 PopupMenu 默认最小宽；
      // Padding 左右对称（14）→ ✓ 离左 = 文字离右。
      menuBuilder: (ctx) => Material(
        color: AppColors.surfaceElevated,
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // stretch：行拉满菜单宽——窄选项的 hover 背景不满行（同语言菜单）。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final o in options)
              InkWell(
                onTap: () => Navigator.of(ctx).pop(o.$1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        child: o.$1 == value
                            ? const Icon(Icons.check,
                                size: 16, color: AppColors.accent)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(o.$2,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontFamily: 'Space Mono', height: 1.2,
                            fontFamilyFallback: AppFonts.cjkFallback,
                            fontSize: 14,
                          )),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (selected != null) onSelected(selected);
  }

  /// 测量选项菜单的内容宽度，供 showSpringPopupFromAnchor 定位弹簧支点。
  /// 单行 = 左右内边距(14×2) + 勾选位(16) + 间距(8) + 文字宽度；取最宽行。
  double _measureMenuWidth(BuildContext context) {
    const style = TextStyle(
      fontFamily: 'Space Mono',
      height: 1.2,
      fontFamilyFallback: AppFonts.cjkFallback,
      fontSize: 14,
    );
    final scaler = MediaQuery.textScalerOf(context);
    double maxText = 0;
    for (final o in options) {
      final tp = TextPainter(
        text: TextSpan(text: o.$2, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > maxText) maxText = tp.width;
    }
    return 14 * 2 + 16 + 8 + maxText + 2;
  }
}
