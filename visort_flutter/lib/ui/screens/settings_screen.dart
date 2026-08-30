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
import 'package:visort_flutter/shared/widgets/confirm_sheet.dart';
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
              // 抽屉动画档位（仅安卓 Shell 有抽屉；桌面端不显示）。
              // 快速 = 250/200ms（Material 官方黄金值，默认）；舒适 =
              // 320/240ms（emphasized 方向，节奏沉稳）。开/关非对称。
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
            ],
          ),
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
  }) async {
    final updated = ref.read(configProvider).copyWith(
          drawerAnimSpeed: drawerAnimSpeed,
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
