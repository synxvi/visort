// 文件夹编辑器 —— 独立 StatefulWidget，解决光标丢失与卡顿
//
// 优化点（修复问题三）:
//   1. TextEditingController 按 key 缓存（build 时复用，不新建 → 光标不跳）
//   2. 本地维护 templates 副本，编辑只更新本地 state（不触发 Provider 重建）
//   3. 防抖：编辑后 500ms 才持久化到磁盘（避免每键一次 IO）
//   4. 排序/删除/新增时立即持久化（这些操作不频繁）
//
// 对应前端 #folder-editor（index.html）+ autoSaveFolderTemplates

import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/config/models.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';
import 'package:visort_flutter/features/home/home_controller.dart';
import 'package:visort_flutter/shared/widgets/text_formatters.dart';
import 'package:visort_flutter/shared/widgets/toast.dart';

class FolderEditor extends ConsumerStatefulWidget {
  const FolderEditor({
    super.key,
    required this.profile,
    required this.activeProfileName,
  });
  final Profile profile;
  final String activeProfileName;

  @override
  ConsumerState<FolderEditor> createState() => _FolderEditorState();
}

class _FolderEditorState extends ConsumerState<FolderEditor> {
  /// 本地编辑副本（与 Provider 解耦，避免每键重建）
  late List<FolderTemplate> _templates;
  /// controller 缓存：按 "行标识" 缓存，避免重建时丢光标
  final Map<String, TextEditingController> _keyControllers = {};
  final Map<String, TextEditingController> _labelControllers = {};
  /// 防抖计时器
  Timer? _debounce;

  /// 各行 key 上次有效值(冲突时回退,不留在非法状态;key 同 rowId 机制)。
  final Map<String, String> _lastKeys = {};

  @override
  void initState() {
    super.initState();
    _templates = List.of(widget.profile.folders);
  }

  /// 当外部 profile 变化（切换 profile / 删除）时同步本地副本
  /// 但不能简单覆盖，否则正在编辑的内容会丢失——仅在 templates 引用真正变化时同步
  @override
  void didUpdateWidget(FolderEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // profile 切换或 folders 数量变化时重新加载
    final newFolders = widget.profile.folders;
    if (oldWidget.activeProfileName != widget.activeProfileName ||
        newFolders.length != _templates.length ||
        !_listEqual(newFolders, _templates)) {
      _templates = List.of(newFolders);
      _pruneControllers();
    }
  }

  bool _listEqual(List<FolderTemplate> a, List<FolderTemplate> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key || a[i].label != b[i].label) return false;
    }
    return true;
  }

  /// 清理不再需要的 controller（避免内存泄漏）
  void _pruneControllers() {
    final validIds = _templates
        .asMap()
        .entries
        .map((e) => _rowId(e.key, e.value))
        .toSet();
    _keyControllers.removeWhere((k, _) => !validIds.contains(k));
    _labelControllers.removeWhere((k, _) => !validIds.contains(k));
    _lastKeys.removeWhere((k, _) => !validIds.contains(k));
  }

  /// 行唯一标识：用 key+label+index 组合，编辑中保持稳定
  /// 注意：用 index 而非 key/label 作为标识，因为编辑时 key/label 在变
  String _rowId(int index, FolderTemplate f) => 'row_$index';

  TextEditingController _keyCtrl(int index, FolderTemplate f) {
    final id = _rowId(index, f);
    return _keyControllers.putIfAbsent(
        id, () => TextEditingController(text: f.key));
  }

  TextEditingController _labelCtrl(int index, FolderTemplate f) {
    final id = _rowId(index, f);
    return _labelControllers.putIfAbsent(
        id, () => TextEditingController(text: f.label));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    for (final c in _labelControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 防抖持久化：500ms 无输入后写盘
  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persistNow);
  }

  Future<void> _persistNow() async {
    // 从 controller 同步最新值到 _templates
    for (var i = 0; i < _templates.length; i++) {
      final f = _templates[i];
      final kCtrl = _keyControllers[_rowId(i, f)];
      final lCtrl = _labelControllers[_rowId(i, f)];
      _templates[i] = FolderTemplate(
        key: (kCtrl?.text ?? f.key).trim().toUpperCase(),
        label: (lCtrl?.text ?? f.label).trim(),
      );
    }
    final err = await HomeController(ref).updateFolders(_templates);
    if (err != null && mounted) {
      toast(context, t(ref, err));
    }
  }

  Future<void> _reorder(int oldIdx, int newIdx) async {
    // onReorderItem（v3.41+ 替代废弃的 onReorder）已自动补偿被移除项的
    // newIndex——旧 onReorder 需要的手动 `newIdx -= 1` 不再需要。
    setState(() {
      final item = _templates.removeAt(oldIdx);
      _templates.insert(newIdx, item);
      // controller 也跟随移动：清空重建（重排不频繁，可接受）
      _keyControllers.clear();
      _labelControllers.clear();
      _lastKeys.clear();
    });
    // 立即持久化（无防抖）
    await HomeController(ref).updateFolders(_templates);
  }

  Future<void> _removeAt(int idx) async {
    // 至少保留一个：目标文件夹预览与 Run 语义都依赖非空 folders，
    // 删空会让右侧预览消失（也过不了 start 校验）。
    if (_templates.length <= 1) {
      toast(context, t(ref, 'keep_one_folder'));
      return;
    }
    setState(() {
      _templates.removeAt(idx);
      _keyControllers.clear();
      _labelControllers.clear();
      _lastKeys.clear();
    });
    await HomeController(ref).updateFolders(_templates);
  }

  /// key 列输入即时校验：与其他行 key 或操作快捷键（撤销/删除/跳过）
  /// 重复时立即回退为之前的字符并 toast(非法字符已在 formatter 层拦截,
  /// 小写已自动转大写)。
  void _onKeyChanged(int idx, FolderTemplate f) {
    final ctrl = _keyCtrl(idx, f);
    final v = ctrl.text.trim().toUpperCase();
    final rowId = _rowId(idx, f);
    final prev = _lastKeys[rowId] ?? f.key;
    if (v == prev) {
      _schedulePersist();
      return;
    }
    // 与其他行 key 重复(label 取 controller 实时文本,编辑中也能对上)
    for (var i = 0; i < _templates.length; i++) {
      if (i == idx) continue;
      final otherKey = (_keyControllers[_rowId(i, _templates[i])]?.text ??
              _templates[i].key)
          .trim()
          .toUpperCase();
      if (otherKey.isNotEmpty && otherKey == v) {
        final otherLabel = _labelControllers[_rowId(i, _templates[i])]?.text ??
            _templates[i].label;
        ctrl.text = prev;
        toast(context, t(ref, 'key_used_folder', [v, otherLabel]));
        return;
      }
    }
    // 与操作快捷键冲突
    final ak = ref.read(configProvider).activeProfileData.actionKeys;
    for (final k in [ak.undo, ak.delete, ak.skip]) {
      if (k.trim().isNotEmpty && k.trim().toUpperCase() == v) {
        ctrl.text = prev;
        toast(context, t(ref, 'key_used_action', [v]));
        return;
      }
    }
    _lastKeys[rowId] = v;
    _schedulePersist();
  }

  void _addFolder() {
    final home = HomeController(ref);
    final key = home.allocateKey(_templates);
    setState(() {
      _templates.add(FolderTemplate(
          key: key, label: t(ref, 'category', [_templates.length + 1])));
    });
    _schedulePersist();
  }

  @override
  Widget build(BuildContext context) {
    final title =
        '${widget.activeProfileName}${t(ref, 'target_subdirs_suffix')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: title),
        const SizedBox(height: 12),
        ReorderableListView.builder(
          buildDefaultDragHandles: false,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _templates.length,
          onReorderItem: _reorder,
          itemBuilder: (ctx, idx) {
            final f = _templates[idx];
            return Padding(
              key: ValueKey('row-$idx'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: TextField(
                      controller: _keyCtrl(idx, f),
                      textAlign: TextAlign.center,
                      maxLength: 1,
                      // 输入约束:非法字符(非字母)不进框;小写自动转大写。
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
                        UpperCaseTextFormatter(),
                      ],
                      style: const TextStyle(
                          fontFamily: 'Space Mono', height: 1.2,
                          fontFamilyFallback: AppFonts.cjkFallback),
                      decoration: const InputDecoration(
                        counterText: '',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onChanged: (_) => _onKeyChanged(idx, f),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _labelCtrl(idx, f),
                      style: const TextStyle(
                          fontFamily: 'Space Mono', height: 1.2,
                          fontFamilyFallback: AppFonts.cjkFallback),
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onChanged: (_) => _schedulePersist(),
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: idx,
                    child: const Tooltip(
                      message: 'Drag to reorder',
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.drag_indicator,
                            size: 20, color: AppColors.muted),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t(ref, 'remove'),
                    icon: const Icon(Icons.close, size: 20),
                    color: AppColors.muted,
                    onPressed: () => _removeAt(idx),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        // 新增入口：虚线空占位卡片——直观表达「点击后在上方追加一行」，
        // 替代原 TextButton（用户要求）。hover 时边框/文字点亮提示可点。
        _AddFolderPlaceholder(onTap: _addFolder),
      ],
    );
  }
}

/// 「新增文件夹」虚线占位卡片：空态区域即新增按钮。
class _AddFolderPlaceholder extends ConsumerWidget {
  const _AddFolderPlaceholder({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _AddFolderBody(
      label: t(ref, 'add_folder'),
      onTap: onTap,
    );
  }
}

class _AddFolderBody extends StatefulWidget {
  const _AddFolderBody({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_AddFolderBody> createState() => _AddFolderBodyState();
}

class _AddFolderBodyState extends State<_AddFolderBody> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? AppColors.accent : AppColors.muted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: ShapeDecoration(
            shape: _DashedRoundedBorder(
              radius: 6,
              color: color.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(
                  color: color,
                  fontFamily: 'Space Mono', height: 1.2,
                  fontFamilyFallback: AppFonts.cjkFallback,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 虚线圆角边框（CustomPainter 自绘：四边等距虚线段）。
class _DashedRoundedBorder extends OutlinedBorder {
  const _DashedRoundedBorder({
    required this.color,
    this.radius = 6,
    this.gap = 4,
    this.dash = 5,
  });

  final Color color;
  final double radius;
  final double gap;
  final double dash;

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(1);

  @override
  ShapeBorder scale(double t) => _DashedRoundedBorder(
        color: Color.lerp(color, color, t)!,
        radius: radius * t,
        gap: gap,
        dash: dash,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is _DashedRoundedBorder
      ? _DashedRoundedBorder(
          color: Color.lerp(a.color, color, t)!,
          radius: lerpDouble(a.radius, radius, t)!,
        )
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is _DashedRoundedBorder
      ? _DashedRoundedBorder(
          color: Color.lerp(color, b.color, t)!,
          radius: lerpDouble(radius, b.radius, t)!,
        )
      : super.lerpTo(b, t);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRRect(RRect.fromRectAndRadius(
        rect.deflate(1), Radius.circular(radius)));
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()..addRRect(RRect.fromRectAndRadius(
        rect, Radius.circular(radius)));
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // 沿圆角矩形周长走虚线
    final path = Path()..addRRect(RRect.fromRectAndRadius(
        rect.deflate(0.5), Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      bool draw = true;
      while (dist < metric.length) {
        final len = draw ? dash : gap;
        if (draw) {
          canvas.drawPath(metric.extractPath(dist, dist + len), paint);
        }
        dist += len;
        draw = !draw;
      }
    }
  }

  @override
  _DashedRoundedBorder copyWith({
    BorderSide? side,
    Color? color,
    double? radius,
  }) =>
      _DashedRoundedBorder(
        color: color ?? this.color,
        radius: radius ?? this.radius,
      );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontFamily: 'Space Mono', height: 1.2,
            fontFamilyFallback: AppFonts.cjkFallback,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
            letterSpacing: 0.5));
  }
}
