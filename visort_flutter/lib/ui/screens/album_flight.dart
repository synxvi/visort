// 相册进入 route —— 网格缩放方案:
//   - push: page grow(AlbumScreen 网格从小变大 + 淡入,首帧即网格)。
//   - pop: 网格由大缩小,飞行层用「静态网格快照」(pop 开始 RepaintBoundary.toImage)。
//     直接缩小实时 AlbumScreen 会因 GridView viewport 变小 → offset clamp + cell
//     重排,网格滚动一屏以上时飞行层杂乱;快照是静态图,缩小不重排、稳定。
//     末段封面缩略图淡入接管(与相册 cell 同 provider 同位置,无缝)。

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/fs/image_loader.dart';
import '../../core/theme/app_animations.dart';
import 'album_screen.dart';
import '../router_android.dart';

/// 封面屏幕 Rect → 缩放锚点 Alignment(封面中心相对屏幕,范围 -1..1)。
/// push 时网格从此处"长"出来,pop 时网格缩回此处。
Alignment albumCoverAlignment(Rect coverRect, Size screenSize) {
  return Alignment(
    (coverRect.center.dx / screenSize.width) * 2 - 1,
    (coverRect.center.dy / screenSize.height) * 2 - 1,
  );
}

/// 进入相册网格。
///
/// [args]:与 AlbumRoutes.album 的 pushNamed arguments 相同
///        (bucketId/bucketName/bucketCount/favoritesOnly/trashedOnly)。
/// [cellRect]:封面缩略图显示区域的全局坐标(pop 飞行层缩回此处)。
/// [coverId]:封面图 _ID(MsBucket.coverId),pop 末段封面接管 + 预加载。
/// [coverAlignment]:缩放锚点(封面位置),push 网格从处长出 / pop 网格缩回。
Future<void> pushAlbumFlight(
  BuildContext context, {
  required Map<String, dynamic> args,
  required Rect cellRect,
  required String coverId,
  required Alignment coverAlignment,
}) {
  // 静态网格快照:pop 开始 toImage 截图当前网格(用户看到的滚动状态),
  // 截图完成后飞行层用快照(RawImage cover),避免缩小中 GridView 重排杂乱。
  final gridKey = GlobalKey();
  ui.Image? snapshot;
  var capturing = false;
  // pop 开始预加载封面(与相册 cell 同 thumbSize),动画期间就绪无跳变。
  var _precached = false;

  return Navigator.of(context).push(PageRouteBuilder<void>(
    // [ente 对齐] 页面转场时长 200ms（ente routeToPage 同款；原 400/280 偏长）。
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    // pop 返回时底下相册列表参与合成并可见(COUI 式返回)。
    opaque: false,
    pageBuilder: (_, _, _) => RepaintBoundary(
      key: gridKey,
      child: AlbumScreen(
        bucketId: args['bucketId']?.toString() ?? '',
        bucketName: args['bucketName']?.toString(),
        bucketCount: (args['bucketCount'] as num?)?.toInt(),
        favoritesOnly: args['favoritesOnly'] == true,
        trashedOnly: args['trashedOnly'] == true,
      ),
    ),
    transitionsBuilder: (ctx, anim, _, child) {
      final size = MediaQuery.sizeOf(ctx);
      final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);
      final isReverse = anim.status == AnimationStatus.reverse;

      // pop 开始:截图当前网格(静态飞行层)。截图完成前短暂用实时网格。
      if (isReverse && !capturing) {
        capturing = true;
        final rb = gridKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
        if (rb != null && rb.attached) {
          rb.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(ctx))
              .then((img) => snapshot = img);
        }
      }

      if (!isReverse) {
        // push: page grow(网格从小变大 + 淡入,锚 coverAlignment)。
        final t = AppCurves.couiMoveEase.transform(anim.value);
        final scale = 0.6 + 0.4 * t;
        final fade = 0.4 + 0.6 * t;
        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
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
      }

      // pop。
      final dpr = MediaQuery.devicePixelRatioOf(ctx);
      final thumbSize = (cellRect.width * dpr).round().clamp(96, 512);
      if (!_precached) {
        _precached = true;
        precacheImage(
          buildThumbnailProvider(
              imageRefFromMediaStoreId(coverId), size: thumbSize),
          ctx,
        );
      }
      final t = AppCurves.couiMoveEase.transform(anim.value); // pop 1→0
      // Positioned layout 缩放(photo viewer 大图→网格同款,不触发 Transform culling)。
      // rect 从全屏(anim=1)线性缩到 cellRect 四顶点(anim=0)。
      final rect = Rect.lerp(fullRect, cellRect, 1.0 - t)!;
      // 飞行层上下沿与缩略图网格对齐(t 接近 0)时,封面缩略图在 cellRect 淡入
      // 接管——与相册 cell 同 provider 同图同位置,route 移除后无缝衔接。
      final coverFade = ((0.25 - t) / 0.25).clamp(0.0, 1.0);
      return Stack(
        fit: StackFit.expand,
        children: [
          // 飞行层:截图完成后用静态快照(不随缩小重排);完成前短暂用实时网格。
          if (snapshot != null)
            Positioned.fromRect(
              rect: rect,
              child: RawImage(image: snapshot!, fit: BoxFit.cover),
            )
          else
            // 截图完成前:实时网格保持全屏(不随 rect 缩小)。直接用 rect 缩小会让
            // SliverGrid 的 cell 随 viewport 等比缩小 → 行高变 → 可见行数跳变 →
            // 内容重排跳动(沉浸抖;日期 SliverList cell 高固定不抖)。全屏保持到
            // 截图就绪,再切 RawImage 缩小(静态快照不重排)。
            Positioned.fromRect(rect: fullRect, child: child),
          // 封面缩略图:缩到 cellRect 对齐时淡入(同 provider 同位置,无缝接管)。
          if (coverFade > 0)
            Positioned.fromRect(
              rect: cellRect,
              child: Opacity(
                opacity: coverFade,
                child: Image(
                  image: buildThumbnailProvider(
                      imageRefFromMediaStoreId(coverId), size: thumbSize),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: Color(0xFF2A2A2A)),
                ),
              ),
            ),
        ],
      );
    },
    settings: const RouteSettings(name: AlbumRoutes.album),
  ));
}
