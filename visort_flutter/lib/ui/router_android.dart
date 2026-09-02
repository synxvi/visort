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
import 'screens/search_screen.dart';

/// 安卓相册浏览链的路由名。
///
/// 与共享 [AppRoutes] 分离：home/sort/review/results/settings 是全平台通用流程，
/// gallery/album/photoViewer 仅安卓可达，故常量归此处。
class AlbumRoutes {
  AlbumRoutes._();

  /// 单个相册（bucket 内图片瀑布流）。
  static const album = '/album';

  /// 搜索页（人物/位置/文件类型分类，[ente 对齐] 相册页右上角搜索按钮）。
  static const search = '/search';

  /// 大图浏览器（album 内 push 的全屏看图页）。
  /// 仅作为 [RouteSettings.name] 使用（供 [RouteNameObserver] 识别），
  /// 不在 onGenerateRoute 里注册 case——它由 album_screen 直接 push PageRouteBuilder。
  static const photoViewer = '/photo-viewer';
}

/// 噪点 overlay 不套用的路由（相册浏览相关）。
///
/// 这些页面有大面积滚动列表/全屏看图，每帧全屏 alpha 合成会拖慢渲染；
/// 且「看照片」时颗粒质感无意义，故绕过。见 currentRouteName 说明。
/// `/`（AppRoutes.home，字面量避免与 router.dart 循环引用）也在名单：
/// 抽屉壳的默认屏是相册封面网格（大滚动列表），且壳内 5 个一级页共用
/// 同一路由名，噪点层无法按页区分——整壳豁免，快速整理/设置随之失去
/// 噪点质感（卡片流影响甚微，换取相册滚动满帧）。
const albumNoiseDisabledRoutes = {
  '/',
  AlbumRoutes.album,
  AlbumRoutes.photoViewer,
};

/// 相册路由深度守卫（2026-09 双指双桶黑屏的终态修复）。
///
/// 首页 tile 导航的 tap 层互斥（static 锁 / canPop）真机实证均不可靠
/// （同毫秒双通过，机制未明）——改用【不依赖任何时序】的结构性保证：
/// 相册页 initState 时向此计数器注册，发现自己不是栈中唯一的相册页
/// 即静默 pop 自己。initState 顺序严格等于入栈顺序（路由栈是严格的），
/// 第二页注册时 depth 必然 ≥2 → 必然自退。首页 tile 导航语义由此收敛为
/// 「第一次命中相册后，阻止再开另一相册」。
abstract final class AlbumRouteGuard {
  static int _depth = 0;

  /// 页面 initState 调用。返回是否为栈中唯一的相册页。
  static bool registerAndCheckFirst() {
    _depth++;
    return _depth == 1;
  }

  /// 页面 dispose 调用。
  static void unregister() {
    _depth = (_depth - 1).clamp(0, 1 << 30);
  }
}

/// 生成安卓相册浏览链的路由。
///
/// 由共享 [onGenerateRoute] 的 default 分支委托调用；桌面端因永不 push 这些路由名，
/// 不会进入本函数。转场统一 ente 式 200ms 淡入（enteFadeRoute）。
Route<dynamic>? onGenerateAlbumRoute(RouteSettings settings) {
  switch (settings.name) {
    case AlbumRoutes.search:
      return enteFadeRoute(
        builder: (_) => const SearchScreen(),
        settings: settings,
      );
    case AlbumRoutes.album:
      // 参数通过 settings.arguments（Map）传入 bucketId / bucketName / bucketCount。
      final args = settings.arguments;
      if (args is Map) {
        return enteFadeRoute(
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
