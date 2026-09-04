// 设置屏 —— 分组卡片式（iOS / Material Settings 风格）
//
// 信息架构：section header（分组标题）+ 卡片（组内项以缩进分隔线关联）。
// 布局/列数设置已整体迁出（[ente 对齐]）：各页面右上角 ViewOptionsToggle
// 选项面板就地调节，设置页只留语言/抽屉动画与缓存。
// 选择器：弹簧菜单 showSpringPopupFromAnchor，宽度自适应、右缘对齐箭头、从 ▾ 弹出；
//         弹窗底色 surfaceElevated（比卡片 surface 提亮，层级区分）。
// 改动即时写回 configProvider 并持久化（shared_preferences）。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/fs/image_loader.dart'
    show computeViewerTargetWidth;
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/search/search_index_service.dart';
import 'package:visort_flutter/shared/widgets/app_bar_title.dart';
import 'package:visort_flutter/shared/widgets/confirm_sheet.dart';
import 'package:visort_flutter/shared/widgets/glyph_icons.dart';
import 'package:visort_flutter/shared/widgets/spring_popup.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';
import 'package:visort_flutter/ui/screens/app_shell_android.dart'
    show DrawerMenuButton, ShellHandle;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.shellHandle});

  /// 抽屉壳句柄：非 null = 嵌入安卓 Shell 的一级页（顶栏 ☰ 呼出抽屉，
  /// 无返回箭头）；null = push 的普通页面（桌面入口，自动返回箭头）。
  final ShellHandle? shellHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.text,
        leading: shellHandle != null
            ? DrawerMenuButton(
                handle: shellHandle,
                tooltip: t(ref, 'settings_title'),
              )
            : null,
        // titleSpacing 0 + 共用标题组件：与其他一级页同款几何（标题盒从
        // leading 槽右缘起、CJK 重心 −1.4dp 上移贴中线，见
        // app_bar_title.dart）；字重保持本页历史 w400。
        titleSpacing: 0,
        title: AppBarTitleText(
          t(ref, 'settings_title'),
          fontWeight: FontWeight.w400,
        ),
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
              // 默认首页（仅安卓 Shell）：启动进入的一级页 + 其它一级页
              // 返回键的应用内终点。选中后下次启动生效。
              if (Platform.isAndroid)
                _PickerRow<DefaultHomePage>(
                  label: t(ref, 'settings_default_home'),
                  value: config.defaultHomePage,
                  valueLabel: switch (config.defaultHomePage) {
                    DefaultHomePage.gallery => t(ref, 'gallery_title'),
                    DefaultHomePage.sort => t(ref, 'quick_sort_title'),
                    DefaultHomePage.favorites => t(ref, 'favorites_title'),
                  },
                  options: [
                    (DefaultHomePage.gallery, t(ref, 'gallery_title')),
                    (DefaultHomePage.sort, t(ref, 'quick_sort_title')),
                    (DefaultHomePage.favorites, t(ref, 'favorites_title')),
                  ],
                  onSelected: (v) => _update(ref, defaultHomePage: v),
                ),
              // 抽屉动画档位（仅安卓 Shell 有抽屉；桌面端不显示）。
              // 快速 = 250/200ms（Material 官方黄金值）；舒适 =
              // 320/240ms（emphasized 方向，节奏沉稳，默认——2026-09
              // 用户定稿）。开/关非对称。
              if (Platform.isAndroid)
                _PickerRow<DrawerAnimSpeed>(
                  label: t(ref, 'settings_drawer_speed'),
                  value: config.drawerAnimSpeed,
                  valueLabel: config.drawerAnimSpeed == DrawerAnimSpeed.fast
                      ? t(ref, 'drawer_speed_fast')
                      : t(ref, 'drawer_speed_comfortable'),
                  options: [
                    (DrawerAnimSpeed.fast, t(ref, 'drawer_speed_fast')),
                    (
                      DrawerAnimSpeed.comfortable,
                      t(ref, 'drawer_speed_comfortable')
                    ),
                  ],
                  onSelected: (v) => _update(ref, drawerAnimSpeed: v),
                ),
              // 图片删除提醒（仅安卓：大图删除是安卓相册路径）：关闭后
              // 大图界面删除不再弹应用内确认 sheet，直接移入回收站（仍
              // 可恢复；回收站内「彻底删除」恒确认，不受此开关影响）。
              // 描述文案收纳进 ⓘ 弹窗（2026-09 用户定稿，行内不再常驻）。
              if (Platform.isAndroid)
                _SwitchRow(
                  label: t(ref, 'settings_delete_confirm'),
                  info: t(ref, 'settings_delete_confirm_note'),
                  value: config.deleteConfirmEnabled,
                  onChanged: (v) =>
                      _update(ref, deleteConfirmEnabled: v),
                ),
            ],
          ),
          // ── 机器学习（[ente 对齐] ENTE ML 设置页精简：开关+进度+注释）──
          // 位于缓存组上方（2026-09 用户定稿排布）。
          _SectionHeader(t(ref, 'settings_section_ml')),
          const _MlSection(),
          // ── 缓存 ──
          _SectionHeader(t(ref, 'settings_section_cache')),
          const _CacheSection(),
        ],
      ),
    );
  }

  /// 写回 configProvider + 持久化（与 _setAlbumSort 同模式）。
  Future<void> _update(
    WidgetRef ref, {
    DrawerAnimSpeed? drawerAnimSpeed,
    DefaultHomePage? defaultHomePage,
    bool? deleteConfirmEnabled,
  }) async {
    final updated = ref.read(configProvider).copyWith(
          drawerAnimSpeed: drawerAnimSpeed,
          defaultHomePage: defaultHomePage,
          deleteConfirmEnabled: deleteConfirmEnabled,
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
              // 两端对称缩进（此前仅 indent 无 endIndent：线右端顶到
              // 卡片边缘，观感异常——真机反馈）。
              const Divider(
                height: 1,
                thickness: 0.5,
                indent: 16,
                endIndent: 16,
                color: AppColors.border,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 开关行：标题 + Switch + 可选副文案（说明关闭后的行为）。整行可点切换，
/// 结构与 ML 区 _switchGroup 一致（InkWell + Row + Switch + note）。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.info,
  });

  final String label;

  /// 说明弹窗内容（已翻译文本）：传了则 label 后显示 ⓘ 按钮，描述
  /// 不再常驻副行（2026-09 用户定稿：描述收纳进弹窗）。
  final String? info;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final i = info;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          // 同一行元素（文字/ⓘ/开关）垂直居中对齐
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(label,
                style: const TextStyle(
                  color: AppColors.text,
                  fontFamily: 'Space Mono', height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 14,
                )),
            if (i != null) ...[
              const SizedBox(width: 6),
              _InfoHintButton(title: label, body: i),
            ],
            const Spacer(),
            Switch(
              value: value,
              activeColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// 行内 ⓘ 说明按钮（设置行 label 文字后）：点击从按钮正下方弹簧展开
/// 小说明面板（与设置页选择器菜单 / 选项面板同一下拉家族）。
/// 图形与顶栏说明按钮同一个 InfoGlyphIcon（含 accent 顶点，stroke 1.7
/// 降档同款）；点击区 32×32——不用 IconButton（48 盒会撑破行内布局，
/// 此处非 bar 按钮）。嵌在外层整行 InkWell 内：内层手势在竞技场胜出，
/// 点 ⓘ 不会误触开关。
class _InfoHintButton extends StatelessWidget {
  const _InfoHintButton({required this.title, required this.body});

  final String title;
  final String body;

  /// 点击 → 按钮正下方弹簧展开说明面板（锚点约定与 ViewOptionsToggle
  /// 选项面板一致：弹簧起点 = 按钮中心 × 面板顶边，面板右缘离按钮
  /// 右缘 8，越屏左移钳制，240 定宽）。
  void _open(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    // 小弹窗 200 定宽（240 占屏 2/3，观感横跨半屏——真机反馈）。
    const menuWidth = 200.0;
    const edgeMargin = 20.0;
    final buttonCx = pos.dx + box.size.width / 2;
    showSpringPopupFromAnchor<void>(
      context: context,
      barrierLabel: 'note_info',
      // 弹簧起点 = 按钮中心 × 面板顶边：面板自按钮正下方长出来。
      anchorGlobalDx: buttonCx,
      anchorGlobalDy: pos.dy + box.size.height + 4,
      // 面板水平中心对准按钮中心（按钮垂直于面板中心位置）。理想
      // 位置直接算中心；仅在两侧间隙 < 20dp 的贴边风险时 clamp 钳制
      //——按钮靠左 → 离左间隙小、离右间隙大，两边都不贴屏（直觉
      // 定位，2026-09 用户定稿）。
      menuLeft: (buttonCx - menuWidth / 2).clamp(
        edgeMargin,
        (screen.width - menuWidth - edgeMargin)
            .clamp(edgeMargin, double.infinity),
      ),
      menuTop: pos.dy + box.size.height + 4,
      menuWidth: menuWidth,
      menuBuilder: (_) => _NoteInfoPanel(title: title, body: body),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: InkWell(
        onTap: () => _open(context),
        // dy +1.2 光学补偿：CJK 字形视觉重心低于几何中心 ~1.4dp
        //（AppBarTitleText 同实证），ⓘ 几何居中会显高于文字视觉
        // 中线——下移贴齐（行内元素垂直居中对齐的视觉完成态）。
        child: Center(
          child: Transform.translate(
            offset: const Offset(0, 1.2),
            child: const InfoGlyphIcon(strokeWidth: 1.7),
          ),
        ),
      ),
    );
  }
}

/// 说明面板：标题 + 一段描述，从 ⓘ 按钮正下方弹簧展开（设置选择器
/// 菜单同族卡片：surfaceElevated / 12 圆角 / elevation 3）。
class _NoteInfoPanel extends StatelessWidget {
  const _NoteInfoPanel({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    const bodyStyle = TextStyle(
      fontFamily: 'Space Mono',
      height: 1.6,
      fontFamilyFallback: AppFonts.cjkFallback,
      fontSize: 12,
      color: AppColors.muted,
    );
    return Material(
      color: AppColors.surfaceElevated,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        // 四周留白收敛（20 → 14，2026-09 真机反馈偏空）
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: bodyStyle.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(body, style: bodyStyle),
          ],
        ),
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

// ───────────────── 缓存组：空闲预缓存开关 + 配额档位 + 占用/清除 ─────────────────

/// 配额档位（MB）：Slider 离散档，默认 1GB。
const List<int> _kQuotaSteps = [256, 512, 1024, 2048];

String _fmtBytes(int bytes, WidgetRef ref) {
  final mb = bytes / (1024 * 1024);
  if (mb < 1) return '${(bytes / 1024).round()} KB';
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

String _fmtQuota(int mb) => mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB';

class _CacheSection extends ConsumerStatefulWidget {
  const _CacheSection();

  @override
  ConsumerState<_CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends ConsumerState<_CacheSection> {
  final MediaStoreChannel _channel = const MediaStoreChannel();
  ({int cached, int total, int full, int thumb})? _usage;

  /// WorkManager 任务态：running / enqueued（排队等充电）/ idle。
  String _workState = 'idle';
  bool _clearing = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refreshUsage();
    // 进度轮询：Worker 充电窗口跑批 / 前台 idle 会话都在持续写盘，
    // 快照数字会"卡住不动"（曾致「增长慢」误判）。3s 间隔两个轻查询
    // （目录计数 + count），设置页存活期才轮询，离开即停。
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshUsage(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshUsage() async {
    // tw 与 viewer 同源（fullCacheStats 只数 {tw} 目录的文件数）。
    // platformDispatcher 而非 View.of(context)：initState 首调时 widget
    // 树尚未挂载完，View.of 依赖 ancestor 查找会抛异常。
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final results = await Future.wait([
      _channel.fullCacheStats(
        targetWidth: computeViewerTargetWidth(view.physicalSize.width),
      ),
      _channel.precacheWorkState(),
    ]);
    if (!mounted) return;
    setState(() {
      _usage = results[0] as ({int cached, int total, int full, int thumb});
      _workState = results[1] as String;
    });
  }

  /// 关开关：弹窗提醒全量缓存将自动清除 → 确认后关开关 + 清 full 缓存。
  Future<void> _onSwitchToOff() async {
    final fullMb = _usage == null
        ? ''
        : '（${_fmtBytes(_usage!.full, ref)}）';
    final confirmed = await showConfirmSheet(
      context,
      title: t(ref, 'settings_precache_off_title'),
      desc: t(ref, 'settings_precache_off_desc') + fullMb,
      cancelText: t(ref, 'cancel'),
      confirmText: t(ref, 'confirm'),
    ).confirmed;
    if (confirmed != true || !mounted) return;
    await _updateConfig(precacheEnabled: false);
    await _channel.clearImageCaches(clearThumb: false);
    await _refreshUsage();
  }

  /// 手动清除：full + thumb 全清（释放最大存储）。
  Future<void> _onClearAll() async {
    if (_clearing) return;
    final total = _usage == null ? 0 : _usage!.full + _usage!.thumb;
    final confirmed = await showConfirmSheet(
      context,
      title: t(ref, 'settings_clear_cache_title'),
      desc: t(ref, 'settings_clear_cache_desc') +
          '（${_fmtBytes(total, ref)}）',
      cancelText: t(ref, 'cancel'),
      confirmText: t(ref, 'confirm'),
    ).confirmed;
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    // 先取消预缓存任务再清：Worker 正在跑时边删边写，清完又被写回，
    // 违背「立即释放」预期。开关仍开，下次冷启动重新排队（增量成本低）。
    await _channel.cancelPrecacheWork();
    final freed = await _channel.clearImageCaches(clearThumb: true);
    if (!mounted) return;
    setState(() => _clearing = false);
    await _refreshUsage();
    toast(context, t(ref, 'settings_cache_cleared') +
        ' ${_fmtBytes(freed.full + freed.thumb, ref)}');
  }

  /// 进度行副文案：任务状态 + full 磁盘占用组合。running/enqueued 状态
  /// 解释「数字为什么不动」（在跑 / 排队中），idle 只报占用。
  /// 占用只报 full（配额管的口径）：thumb 是独立 128MB 上限不受滑块
  /// 控制，混进合计会呈现「占用 364MB > 256MB 配额」的困惑（真机实证）。
  String _statusLine(WidgetRef ref) {
    final u = _usage;
    if (u == null) return '…';
    final usageStr = _fmtBytes(u.full, ref);
    switch (_workState) {
      case 'running':
        return '${t(ref, 'settings_precache_running')} · $usageStr';
      case 'enqueued':
        return '${t(ref, 'settings_precache_waiting')} · $usageStr';
      default:
        return '${t(ref, 'settings_disk_usage')} $usageStr';
    }
  }

  Future<void> _updateConfig({bool? precacheEnabled, int? precacheQuotaMb}) async {
    final updated = ref.read(configProvider).copyWith(
          precacheEnabled: precacheEnabled,
          precacheQuotaMb: precacheQuotaMb,
        );
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final stepIdx = _kQuotaSteps.indexOf(config.precacheQuotaMb);
    final safeIdx = stepIdx < 0 ? 2 : stepIdx; // 未知值回退默认 1GB 档
    final usage = _usage;
    return _SettingsCard(
      children: [
        // 开关行：InkWell+Row+Switch（wallpaper_crop_page 同款模式）。
        InkWell(
          onTap: () {
            if (config.precacheEnabled) {
              _onSwitchToOff();
            } else {
              _updateConfig(precacheEnabled: true);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Text(t(ref, 'settings_precache'),
                    style: const TextStyle(
                      color: AppColors.text,
                      fontFamily: 'Space Mono',
                      height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 14,
                    )),
                const Spacer(),
                Switch(
                  value: config.precacheEnabled,
                  activeColor: AppColors.accent,
                  onChanged: (v) => v
                      ? _updateConfig(precacheEnabled: true)
                      : _onSwitchToOff(),
                ),
              ],
            ),
          ),
        ),
        // 配额档位：4 档离散 Slider（256MB/512MB/1GB/2GB）。
        if (config.precacheEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Text(t(ref, 'settings_precache_quota'),
                    style: const TextStyle(
                      color: AppColors.text,
                      fontFamily: 'Space Mono',
                      height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 14,
                    )),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: AppColors.accent,
                      inactiveTrackColor: AppColors.border,
                      thumbColor: AppColors.accent,
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14),
                      showValueIndicator: ShowValueIndicator.never,
                    ),
                    child: Slider(
                      value: safeIdx.toDouble(),
                      max: (_kQuotaSteps.length - 1).toDouble(),
                      divisions: _kQuotaSteps.length - 1,
                      onChanged: (v) => _updateConfig(
                          precacheQuotaMb: _kQuotaSteps[v.round()]),
                    ),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(_fmtQuota(_kQuotaSteps[safeIdx]),
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontFamily: 'Space Mono',
                          fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                          color: AppColors.muted,
                          fontSize: 13)),
                ),
              ],
            ),
          ),
        // 进度显示行：已缓存张数 + 任务状态 + 磁盘占用（3s 轮询，见
        // initState；点按立即刷）。删除图片会同步删缓存文件，张数与占用
        // 随轮询即时反映。
        InkWell(
          onTap: _refreshUsage,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(t(ref, 'settings_cache_progress'),
                        style: const TextStyle(
                          color: AppColors.text,
                          fontFamily: 'Space Mono',
                          height: 1.2,
                          fontFamilyFallback: AppFonts.cjkFallback,
                          fontSize: 14,
                        )),
                    const Spacer(),
                    Text(
                      usage == null
                          ? '…'
                          : '${usage.cached} / ${usage.total} ${t(ref, 'photos_unit')}',
                      style: const TextStyle(
                          fontFamily: 'Space Mono',
                          fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                          color: AppColors.muted,
                          fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _statusLine(ref),
                  style: const TextStyle(
                      fontFamily: 'Space Mono',
                      fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                      color: AppColors.muted,
                      fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        // 手动清除行（full + thumb 全清）。
        InkWell(
          onTap: _onClearAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Text(t(ref, 'settings_clear_cache'),
                    style: const TextStyle(
                      color: AppColors.text,
                      fontFamily: 'Space Mono',
                      height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 14,
                    )),
                const Spacer(),
                if (_clearing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.chevron_right,
                      color: AppColors.muted, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────── 智能识别组：搜索索引开关 + 进度 + 分能力开关 + 注释 ───────────────

/// 智能识别区（搜索索引；[aves 对齐] Aves 搜索维度数据底座）。
///
/// 索引总开关驱动后台全库 EXIF 扫描（拍摄时间/GPS/相机一次 pass，
/// 产物 SQLite search_index 表——与上方「缓存」区的图片解码缓存完全
/// 分离，用户要求）；地名解析随索引恒开（2026-09 地点识别分开关并入
/// 总开关），「索引数据」行与地点识别开关已移除（与进度重复/权限随
/// 总开关）。
/// 人物识别已移除（2026-08：本地人脸识别方案未采用）。
class _MlSection extends ConsumerStatefulWidget {
  const _MlSection();

  @override
  ConsumerState<_MlSection> createState() => _MlSectionState();
}

class _MlSectionState extends ConsumerState<_MlSection> {
  @override
  void initState() {
    super.initState();
    // 恢复持久化索引（进度 + SQLite 表），搜索页日期/地点/相机分类同源读取。
    ref.read(searchIndexServiceProvider.notifier).load();
  }

  Future<void> _update({bool? mlIndexEnabled}) async {
    final updated = ref.read(configProvider).copyWith(
          mlIndexEnabled: mlIndexEnabled,
        );
    ref.read(configProvider.notifier).state = updated;
    await ref.read(profilesServiceProvider).save(updated);
  }

  /// 索引总开关：开→启动后台扫描；关→确认后清索引数据（[ente 对齐]
  /// ENTE 关 ML 清库语义）。
  Future<void> _onIndexToggle(bool enable) async {
    final notifier = ref.read(searchIndexServiceProvider.notifier);
    if (enable) {
      await _update(mlIndexEnabled: true);
      // 后台分批跑，不 await（设置页停留期间进度实时更新）。
      unawaited(notifier.start());
    } else {
      final confirmed = await showConfirmSheet(
        context,
        title: t(ref, 'settings_ml_off_title'),
        desc: t(ref, 'settings_ml_off_desc'),
        cancelText: t(ref, 'cancel'),
        confirmText: t(ref, 'confirm'),
      ).confirmed;
      if (confirmed != true || !mounted) return;
      notifier.cancel(); // 先停批循环，避免清完又被写回（同预缓存清库竞态）
      await _update(mlIndexEnabled: false);
      await notifier.clear();
    }
  }

  /// 进度主行右侧：已索引 / 总张数（对齐缓存区「cached / total 张」格式，
  /// 2026-09 用户定稿替换百分比）。分母 = 当前库规模（scanAllImages 全量
  /// 扫描，含 GIF 不含回收站；首轮跑批定基，此后每次增量对账
  /// （syncNewPhotos）对齐到最新库规模）；分子 = 已落库行数，跑批中随
  /// 落库实时涨（不再跑完才跳）。total 未知（刚开启未起跑）返回 null
  /// 显示「…」。
  String? _progressText(SearchIndexState ml) {
    if (ml.total <= 0) return null;
    return '${_thousands(ml.metaCount)} / ${_thousands(ml.total)} '
        '${t(ref, 'photos_unit')}';
  }

  /// 千分位（仅此一处用，不引 intl）。
  String _thousands(int n) {
    final s = '$n';
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      buf.write(s[i]);
      final rem = s.length - i - 1;
      if (rem > 0 && rem % 3 == 0) buf.write(',');
    }
    return buf.toString();
  }

  /// 进度状态副行：索引中/地名解析中/已完成；其余（刚开启未起跑/中断）
  /// 无文案返回 null 不渲染——避免与主行占位符叠出双「—」。
  String? _statusLine(SearchIndexState ml) {
    if (ml.running) return t(ref, 'settings_ml_running');
    if (ml.done) return t(ref, 'settings_ml_done');
    return null;
  }

  static const _labelStyle = TextStyle(
    color: AppColors.text,
    fontFamily: 'Space Mono',
    height: 1.2,
    fontFamilyFallback: AppFonts.cjkFallback,
    fontSize: 14,
  );

  static const _noteStyle = TextStyle(
    fontFamily: 'Space Mono',
    height: 1.3,
    fontFamilyFallback: AppFonts.cjkFallback,
    color: AppColors.muted,
    fontSize: 11,
  );

  /// 开关逻辑组 = 一个 child（_SettingsCard 在 children 间自动插分隔线，
  /// 注释必须并入组内——拍平成独立 child 会让线穿过开关与其注释之间，
  /// 视觉混乱）。结构与 _CacheSection 的行组一致。
  /// 描述文案（noteKey）2026-09 收纳进 ⓘ 弹窗，不再常驻副行。
  Widget _switchGroup({
    required String labelKey,
    required String noteKey,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          // 同一行元素（文字/ⓘ/开关）垂直居中对齐
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(t(ref, labelKey), style: _labelStyle),
            const SizedBox(width: 6),
            _InfoHintButton(
              title: t(ref, labelKey),
              body: t(ref, noteKey),
            ),
            const Spacer(),
            Switch(
              value: value,
              activeColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final ml = ref.watch(searchIndexServiceProvider);
    final progressText = _progressText(ml);
    final status = _statusLine(ml);
    return _SettingsCard(
      children: [
        // 索引总开关 + 注释（一组）。
        _switchGroup(
          labelKey: 'settings_ml_index',
          noteKey: 'settings_ml_index_note',
          value: config.mlIndexEnabled,
          onChanged: (v) => _onIndexToggle(v),
        ),
        // 进度组：主行百分比数字，副行状态；仅开启时显示（缓存区配额行
        // 同款模式）。关闭时显示 = 主行副行各一个「—」占位，视觉噪音。
        // 「索引数据」「地点识别」开关已移除（用户定稿：前者与进度重复，
        // 后者并入总开关——开索引即地点识别）。
        if (config.mlIndexEnabled)
          InkWell(
            onTap: () => ref.read(searchIndexServiceProvider.notifier).load(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(t(ref, 'settings_ml_progress'), style: _labelStyle),
                      const Spacer(),
                      Text(
                        // null = 刚开启 total/张数均未就绪，'…' 单占位
                        progressText ?? '…',
                        style: const TextStyle(
                            fontFamily: 'Space Mono',
                            fontFamilyFallback: ['Noto Sans Mono CJK SC'],
                            color: AppColors.muted,
                            fontSize: 13),
                      ),
                    ],
                  ),
                  if (status != null) ...[
                    const SizedBox(height: 2),
                    Text(status, style: _noteStyle),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
