// 安卓专属路由 —— 相册浏览链（gallery / album / photoViewer）
//
// 从共享 router.dart 拆出，实现平台解耦（方案 B 阶段二）：
//   - 相册浏览是安卓独有功能，桌面端不注册这些路由、不 import 这些屏。
//   - 噪点 overlay 豁免名单也在此处：仅安卓相册链需要绕过全屏噪点合成。
//
// 桌面端（Windows/macOS/linux）完全不引用本文件；新增平台无需关心。

import 'package:flutter/material.dart';

import 'route_transitions.dart';
import 'screens/album_screen.dart';
import 'screens/gallery_screen.dart';

/// 安卓相册浏览链的路由名。
///
/// 与共享 [AppRoutes] 分离：home/sort/review/results/settings 是全平台通用流程，
/// gallery/album/photoViewer 仅安卓可达，故常量归此处。
class AlbumRoutes {
  AlbumRoutes._();

  /// 相册列表（bucket 网格）。
  static const gallery = '/gallery';

  /// 单个相册（bucket 内图片瀑布流）。
  static const album = '/album';

  /// 大图浏览器（album 内 push 的全屏看图页）。
  /// 仅作为 [RouteSettings.name] 使用（供 [RouteNameObserver] 识别），
  /// 不在 onGenerateRoute 里注册 case——它由 album_screen 直接 push PageRouteBuilder。
  static const photoViewer = '/photo-viewer';
}

/// 噪点 overlay 不套用的路由（相册浏览相关）。
///
/// 这些页面有大面积滚动列表/全屏看图，每帧全屏 alpha 合成会拖慢渲染；
/// 且「看照片」时颗粒质感无意义，故绕过。见 currentRouteName 说明。
const albumNoiseDisabledRoutes = {
  AlbumRoutes.gallery,
  AlbumRoutes.album,
  AlbumRoutes.photoViewer,
};

/// 生成安卓相册浏览链的路由。
///
/// 由共享 [onGenerateRoute] 的 default 分支委托调用；桌面端因永不 push 这些路由名，
/// 不会进入本函数。
Route<dynamic>? onGenerateAlbumRoute(RouteSettings settings) {
  switch (settings.name) {
    case AlbumRoutes.gallery:
      // 相册浏览链（与 album 的 grow 动画配套）：被推页无位移——
      // slide 的被推页视差会让相册返回时列表页整体滑动。
      return couiFadeRoute(
        builder: (_) => const GalleryScreen(),
        settings: settings,
      );
    case AlbumRoutes.album:
      // 参数通过 settings.arguments（Map）传入 bucketId / bucketName / bucketCount。
      // 用快速浮现（fade + 轻缩放）：比 slide 更轻盈，适合内容浏览切换。
      final args = settings.arguments;
      if (args is Map) {
        return couiFadeRoute(
          builder: (_) => AlbumScreen(
            bucketId: args['bucketId']?.toString() ?? '',
            bucketName: args['bucketName']?.toString(),
            bucketCount: (args['bucketCount'] as num?)?.toInt(),
            favoritesOnly: args['favoritesOnly'] == true,
            trashedOnly: args['trashedOnly'] == true,
          ),
          settings: settings,
        );
      }
      return null;
    default:
      return null;
  }
}
