// 系统相册式底部上弹确认小窗（删除/批量操作共用）。
//
// 实现要点：
//   - 挂 root Overlay 最顶（栏之上）：scrim 盖住一切——「其它所有变暗」，
//     顶栏/底栏自身渲染与不透明度完全不动；scrim 吸收全部点击 = 模态，
//     只有面板内按钮可点（root Overlay 的栏在 dialog barrier 之上，
//     showGeneralDialog 挡不住，故必须走 OverlayEntry 方案）。
//   - 隐式动画（TweenAnimationBuilder + ValueNotifier target 切换）驱动
//     上弹/下滑，无需 TickerProvider；关闭时 target→0，220ms 后移除 entry。
//   - 文案由调用方经 i18n 解析后传入（本组件无 ref）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/theme/app_colors.dart'
    show AppColors, AppFonts;

/// 一次确认小窗会话：[confirmed] 完成于用户选择（scrim/取消 = false）；
/// [close] 供外部主动关闭（如系统返回拦截），等效取消。
class ConfirmSheetSession {
  ConfirmSheetSession({required this.confirmed, required this.close});
  final Future<bool> confirmed;
  final void Function() close;
}

/// 弹出底部确认小窗（点 scrim/取消 = false）。
ConfirmSheetSession showConfirmSheet(
  BuildContext context, {
  required String title,
  String? desc,
  String? cancelText,
  String? confirmText,
  Color? confirmColor,
}) {
  final target = ValueNotifier<double>(1);
  final completer = Completer<bool>();
  late final OverlayEntry entry;
  void close(bool confirmed) {
    if (completer.isCompleted) return;
    completer.complete(confirmed);
    target.value = 0;
    Future.delayed(const Duration(milliseconds: 220), () {
      entry.remove();
      target.dispose();
    });
  }

  entry = OverlayEntry(
    builder: (_) => ValueListenableBuilder<double>(
      valueListenable: target,
      builder: (_, end, __) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: end),
        duration: Duration(milliseconds: end == 1 ? 250 : 200),
        curve: end == 1 ? Curves.decelerate : Curves.easeOut,
        builder: (_, t, ___) => _ConfirmSheetPanel(
          t: t,
          title: title,
          desc: desc,
          cancelText: cancelText ?? '取消',
          confirmText: confirmText ?? '确认',
          confirmColor: confirmColor ?? AppColors.danger,
          onConfirm: () => close(true),
          onCancel: () => close(false),
        ),
      ),
    ),
  );
  Overlay.of(context).insert(entry);
  return ConfirmSheetSession(
    confirmed: completer.future,
    close: () => close(false),
  );
}

class _ConfirmSheetPanel extends StatelessWidget {
  const _ConfirmSheetPanel({
    required this.t,
    required this.title,
    required this.cancelText,
    required this.confirmText,
    required this.confirmColor,
    required this.onConfirm,
    required this.onCancel,
    this.desc,
  });

  /// 动画进度（0 关闭态 → 1 打开态）。
  final double t;
  final String title;
  final String? desc;
  final String cancelText;
  final String confirmText;
  final Color confirmColor;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // scrim：盖住一切（含栏）+ 吸收点击（模态），点按 = 取消
        Positioned.fill(
          child: GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.5 * t),
            ),
          ),
        ),
        // 底部小窗（系统相册式）：左右 24 边距、悬空于手势条上方、四角
        // 圆角。随 t 从屏底滑入。
        Positioned(
          left: 24,
          right: 24,
          bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
          child: FractionalTranslation(
            translation: Offset(0, 1 - t),
            child: Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        height: 1.3,
                        fontFamilyFallback: AppFonts.cjkFallback,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.text,
                      ),
                    ),
                    if (desc != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        desc!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Space Mono',
                          height: 1.4,
                          fontFamilyFallback: AppFonts.cjkFallback,
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: onCancel,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 46),
                            ),
                            child: Text(
                              cancelText,
                              style: const TextStyle(
                                fontFamily: 'Space Mono',
                                fontFamilyFallback: AppFonts.cjkFallback,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: confirmColor,
                              foregroundColor: AppColors.bg,
                              minimumSize: const Size(0, 46),
                            ),
                            onPressed: onConfirm,
                            child: Text(confirmText),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
