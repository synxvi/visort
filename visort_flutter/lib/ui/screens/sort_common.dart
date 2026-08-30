// Sort 屏共享件 —— 双平台行为完全一致的会话门卫与解码宽度工具。
//
// 平台布局分叉（2026-08）：桌面键盘布局见 sort_screen.dart；安卓沉浸式布局见
// sort_screen_android.dart；实例化分叉点在 router.dart 的 /sort 路由。
// 本文件不放任何 Platform.is 分支——两端若在此分叉，说明该逻辑应下放到布局文件。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/session/session_models.dart';
import 'package:visort_flutter/ui/router.dart';

/// Sort 屏解码目标宽度（物理像素）：与 viewer 同源（computeViewerTargetWidth）。
/// 预览区只有屏幕大小——全分辨率解码（12MP ≈ 48MB ARGB）在键盘连按时
/// 当前图 + precache 下一张双份解码会瞬间塞满 ImageCache；下采样后 ~7MB/张。
int sortTargetWidth(BuildContext context) => computeViewerTargetWidth(
      MediaQuery.sizeOf(context).width *
          MediaQuery.devicePixelRatioOf(context),
    );

/// 会话门卫：空 session 回 Home、完成态自动跳 Review，放行后交给平台布局。
///
/// 这段守卫是双平台同源的硬不变式（含杀进程恢复场景的补跳），只此一份、
/// 两端布局文件不得各自复制，防止行为漂移。
class SortSessionGate extends ConsumerWidget {
  const SortSessionGate({super.key, required this.builder});

  /// 通过守卫后的平台布局构造器（此时 session 非空且未完成）。
  final Widget Function(BuildContext context, SessionState session) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);

    // 完成时自动跳 Review：ref.listen 仅在 session"变完成"时触发一次，
    // 从 Review pop 回不会重复触发（配合 continue_sort 回退 index 避免完成态空白）。
    // 删除了原先最后一张图之后的"审核变更"中间页——它会多算一页，
    // 导致进度显示成 (length+1)/length（如 5/4）。
    ref.listen<SessionState>(sessionControllerProvider, (prev, next) {
      if (next.isComplete && (prev == null || !prev.isComplete)) {
        Navigator.pushNamed(context, AppRoutes.review);
      }
    });

    // 空 session（未扫描直接进入）→ 回 Home
    if (session.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // mounted 守卫：Results Continue 先 reset()（session 变空触发本分支）
        // 再 popUntil，本回调执行时 sort 路由已被 pop、context 已失效——
        // 无守卫会用死 context 重建 home，壳层重挂默认相册页，从快速整理页
        // 发起的整理被甩回"首页"（真机实测）。完成态分支同款守卫。
        if (!context.mounted) return;
        Navigator.pushNamedAndRemoveUntil(context, AppRoutes.home, (_) => false);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    // 完成态：不再渲染"审核变更"中间页，留一帧空白作跳转过渡。
    // 恢复场景(P2)补跳:会话在 Review 屏被杀后恢复进来即完成态,
    // ref.listen 听不到"变完成"(无状态变化)——首帧主动 push Review,
    // 否则永远停在空白屏(真机实测黑屏,返回才回 Home)。
    // isCurrent 去重:正常完成路径 listen 已先 push Review(本路由非栈顶),
    // 此时不再重复压栈。
    if (session.isComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final isTop = ModalRoute.of(context)?.isCurrent ?? false;
        if (isTop) Navigator.pushNamed(context, AppRoutes.review);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    return builder(context, session);
  }
}
