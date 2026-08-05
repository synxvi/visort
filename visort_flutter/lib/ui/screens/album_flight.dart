// 相册网格由小变大 route —— 进入 AlbumScreen(缩略图网格)
//
// 对标系统相册：点击相册一瞬间画面就是缩略图网格（小尺寸），整个网格
// 由小变大放大到全屏（grow + fade）。不是封面单图拉伸——飞行层封面
// 方案被用户否决（封面图拉伸变形 + 动画结束瞬切网格，感知更卡）。
//
// 实现：
//   - PageRouteBuilder.transitionsBuilder（route 过渡动画，ColorOS 不降帧）
//   - child（AlbumScreen 网格）整体 Transform.scale(0.6→1) + Opacity(0.4→1)，
//     缩放锚点 = 点击的封面位置（网格从封面处"长"出来）
//   - opaque: false → pop 返回时网格缩小回封面位置，底下页面全程可见
//     （COUI 式，无"黑→页面瞬现"）
//
// 注意：动画期间 AlbumScreen 照常渲染（query 在动画窗口内完成，网格 + 缩略图
// 渐进可见）——动画主体是网格本身，而不是等待动画结束才显示内容。

import 'package:flutter/material.dart';

import '../../core/theme/app_animations.dart';
import 'album_screen.dart';
import '../router.dart';

/// 网格由小变大进入相册。
///
/// [args]：与 AppRoutes.album 的 pushNamed arguments 相同
/// （bucketId/bucketName/bucketCount/favoritesOnly/trashedOnly）。
/// [coverAlignment]：缩放锚点（点击的封面位置，网格从此处放大到全屏）。
Future<void> pushAlbumGrow(
  BuildContext context, {
  required Map<String, dynamic> args,
  Alignment coverAlignment = Alignment.center,
}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    // pop 返回动画期间底下页面（Home/Gallery）参与合成并可见
    opaque: false,
    pageBuilder: (_, _, _) => AlbumScreen(
      bucketId: args['bucketId']?.toString() ?? '',
      bucketName: args['bucketName']?.toString(),
      bucketCount: (args['bucketCount'] as num?)?.toInt(),
      favoritesOnly: args['favoritesOnly'] == true,
      trashedOnly: args['trashedOnly'] == true,
    ),
    transitionsBuilder: (ctx, anim, _, child) {
      final isReverse = anim.status == AnimationStatus.reverse;
      // COUIMoveEase 强 ease-out：网格"冲"到全屏（一加手感）
      final t = AppCurves.couiMoveEase.transform(anim.value);
      // 网格由小变大 + 淡入：起点即见（小尺寸半透明），点击瞬间是缩略图
      final scale = 0.6 + 0.4 * t;
      final fade = 0.4 + 0.6 * t;
      return Stack(
        fit: StackFit.expand,
        children: [
          // push 垫黑（网格缩小期留白纯黑，与全屏网格背景衔接一致）；
          // pop 不垫 → 露出底下页面（COUI 式返回）
          if (!isReverse) const ColoredBox(color: Colors.black),
          Opacity(
            opacity: fade,
            child: Transform.scale(
              scale: scale,
              alignment: coverAlignment,
              child: child,
            ),
          ),
        ],
      );
    },
    settings: const RouteSettings(name: AppRoutes.album),
  ));
}

/// 封面屏幕 Rect → 缩放锚点 Alignment（封面中心相对屏幕，范围 -1..1）。
/// 网格将从封面位置"长"出来。
Alignment albumCoverAlignment(Rect coverRect, Size screenSize) {
  return Alignment(
    (coverRect.center.dx / screenSize.width) * 2 - 1,
    (coverRect.center.dy / screenSize.height) * 2 - 1,
  );
}
