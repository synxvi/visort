// 自定义 Profile 下拉选择器
//
// 为什么不用 PopupMenuButton？
//   M3 的 PopupMenuRoute 在 Windows 桌面端展开动画的起始帧会用主题默认
//   Material 绘制圆角矩形，暗色背景下圆角外缘会出现灰白闪烁。
//   这里用 OverlayEntry + CompositedTransformFollower 自绘弹层，过渡完全可控。
//
// 特性：
//   - 点击触发器 → 在其下方定位弹层（跟随滚动/位移）
//   - AnimatedOpacity 淡入（120ms），无圆角残影
//   - 点击外部 / 选中项后关闭
//   - 无 InkWell 波纹（主题全局已禁用，此处用 GestureDetector）

import 'package:flutter/material.dart';
import 'package:sortr_flutter/core/theme/app_colors.dart';

class ProfileDropdown extends StatefulWidget {
  const ProfileDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onSelected,
  });

  /// 当前选中值
  final String value;
  final List<String> items;
  final ValueChanged<String> onSelected;

  @override
  State<ProfileDropdown> createState() => _ProfileDropdownState();
}

class _ProfileDropdownState extends State<ProfileDropdown> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  void _toggle() {
    if (_isOpen) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    final overlay = Overlay.of(context);
    final box = context.findRenderObject() as RenderBox;
    final width = box.size.width;

    _overlayEntry = OverlayEntry(
      builder: (ctx) => _DropdownOverlay(
        link: _link,
        width: width,
        items: widget.items,
        value: widget.value,
        onSelected: (v) {
          _close();
          widget.onSelected(v);
        },
        onDismiss: _close,
      ),
    );
    overlay.insert(_overlayEntry!);
    setState(() => _isOpen = true);
  }

  void _close() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _isOpen = false);
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: GestureDetector(
        onTap: _toggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(
              color: _isOpen ? AppColors.accent : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.value,
                  style: const TextStyle(
                    fontFamily: 'SpaceMono',
                    fontFamilyFallback: AppFonts.cjkFallback,
                    fontSize: 13,
                    color: AppColors.text,
                  ),
                ),
              ),
              Icon(
                _isOpen ? Icons.unfold_less : Icons.unfold_more,
                size: 18,
                color: AppColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹层本体：定位 + 淡入 + 列表 + 点击外部关闭
class _DropdownOverlay extends StatefulWidget {
  const _DropdownOverlay({
    required this.link,
    required this.width,
    required this.items,
    required this.value,
    required this.onSelected,
    required this.onDismiss,
  });

  final LayerLink link;
  final double width;
  final List<String> items;
  final String value;
  final ValueChanged<String> onSelected;
  final VoidCallback onDismiss;

  @override
  State<_DropdownOverlay> createState() => _DropdownOverlayState();
}

class _DropdownOverlayState extends State<_DropdownOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 全屏屏障：点击关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        // 定位在触发器下方
        CompositedTransformFollower(
          link: widget.link,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 4),
          child: FadeTransition(
            opacity: _fade,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: widget.width,
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.items
                      .map((n) => _Item(
                            label: n,
                            isSelected: n == widget.value,
                            onTap: () => widget.onSelected(n),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Item extends StatefulWidget {
  const _Item({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          color: _hover
              ? AppColors.rootDirBgHover
              : Colors.transparent,
          child: Text(
            widget.label,
            style: TextStyle(
              fontFamily: 'SpaceMono',
              fontFamilyFallback: AppFonts.cjkFallback,
              fontSize: 13,
              color: widget.isSelected ? AppColors.accent : AppColors.text,
              fontWeight:
                  widget.isSelected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
