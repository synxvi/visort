// 恢复会话横条(P2)—— Home 顶部「继续上次整理」入口
//
// 杀进程/崩溃后有未完成会话时显示(轻量探测 hasPersistedSession),
// 点击恢复并进 sort。非弹窗横条(路线图定的默认方案):不打断浏览,
// 忽略即无视,新扫描自动覆盖旧会话。

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/core/theme/app_colors.dart';

class ResumeSessionBanner extends StatelessWidget {
  const ResumeSessionBanner({super.key, required this.onResume});

  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
                      height: 1.2,
                      fontFamilyFallback: AppFonts.cjkFallback,
                      fontSize: 13,
                      color: AppColors.text,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
