// 恢复会话横条(P2)—— Home 顶部「继续上次整理」入口
//
// 杀进程/崩溃后有未完成会话时显示(轻量探测 hasPersistedSession),
// 点击恢复并进 sort。非弹窗横条(路线图定的默认方案):不打断浏览,
// 忽略即无视,新扫描自动覆盖旧会话。
//
// 左右滑动清除中断记录(Dismissible):拖动跟手、背景删除示意渐显、
// 松手未过阈值回弹、过阈值滑出后高度收起——全套动画系统自带。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

class ResumeSessionBanner extends StatelessWidget {
  const ResumeSessionBanner({
    super.key,
    required this.onResume,
    required this.onDismiss,
  });

  final VoidCallback onResume;

  /// 滑动清除后的回调(丢弃持久化会话 + 收起横条)。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Dismissible(
        key: const ValueKey('resume_banner'),
        direction: DismissDirection.horizontal,
        onDismissed: (_) => onDismiss(),
        // 背景与 child 同圆角同缩进(在 Padding 内),红色删除示意随拖动渐显。
        background: _dismissBg(Alignment.centerLeft),
        secondaryBackground: _dismissBg(Alignment.centerRight),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onResume,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.history, size: 18, color: AppColors.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr('resume_session'),
                      style: const TextStyle(
                        fontFamily: 'Space Mono',
                        fontFamilyFallback: AppFonts.cjkFallback,
                        height: 1.2,
                        color: AppColors.text,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 18, color: AppColors.muted),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 滑动背景:danger 底 + 垃圾桶 + 文案,图标靠拖动起始侧。
  Widget _dismissBg(Alignment alignment) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline, size: 18, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            tr('resume_dismiss'),
            style: const TextStyle(
              fontFamily: 'Space Mono',
              fontFamilyFallback: AppFonts.cjkFallback,
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
