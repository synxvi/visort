// 双桶 ImageCache，逐行移植自 immich：mobile/lib/utils/cache/custom_image_cache.dart
//（2026-09-08，代码级对齐基线）+ visort 适配（大图桶判据/配额）。
//
// 动机（immich 原注释）：a single large image does not evict all small images
// ——一张 4096 帧 ~48MB 的 RGBA 与网格缩略图共用单缓存时互相驱逐：放大帧把
// 网格缩略图挤光（pop 后整屏重解码 = 「网格界面变慢」），网格浏览又把放大
// 帧挤掉（「回看不命中 → 重解码」）。分桶后互不干扰。
//
// [visort 适配]：大图桶判据用 ProgressiveImageKey 标记接口（progressive
// 升档 provider）；桶配额 maximumSize=3 + 128MB（immich 是 5 张不限字节——
// 其 original 桶 5×64MB 对相册整理工具过于豪放，visort 收紧防低内存机 OOM）。
// 小桶继承全局配置（initMaxDecodePixels 设的 800 条 / 96-256MB）。

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:visort_flutter/core/fs/image_loader.dart'
    show ProgressiveImageKey;

/// [ImageCache] that uses two caches for small and large images
/// so that a single large image does not evict all small images
final class VisortImageCache implements ImageCache {
  final ImageCache _small = ImageCache();

  /// viewer 渐进升档桶（2304/4096 帧驻留其中）：3 张 + 128MB 双上限。
  final ImageCache _large = ImageCache()
    ..maximumSize = 3
    ..maximumSizeBytes = 128 << 20;

  @override
  int get maximumSize => _small.maximumSize + _large.maximumSize;

  @override
  int get maximumSizeBytes => _small.maximumSizeBytes + _large.maximumSizeBytes;

  @override
  set maximumSize(int value) => _small.maximumSize = value;

  @override
  set maximumSizeBytes(int value) => _small.maximumSizeBytes = value;

  @override
  void clear() {
    _small.clear();
    _large.clear();
  }

  @override
  void clearLiveImages() {
    _small.clearLiveImages();
    _large.clearLiveImages();
  }

  /// Gets the cache for the given key
  ImageCache _cacheForKey(Object key) {
    return switch (key) {
      ProgressiveImageKey() => _large,
      _ => _small,
    };
  }

  @override
  bool containsKey(Object key) {
    // 渐进升档 provider 与网格缩略图 provider 分属大/小桶（大桶条目
    // 不占小桶配额，互不驱逐）。
    return _cacheForKey(key).containsKey(key);
  }

  @override
  int get currentSize => _small.currentSize + _large.currentSize;

  @override
  int get currentSizeBytes => _small.currentSizeBytes + _large.currentSizeBytes;

  @override
  bool evict(Object key, {bool includeLive = true}) =>
      _cacheForKey(key).evict(key, includeLive: includeLive);

  @override
  int get liveImageCount => _small.liveImageCount + _large.liveImageCount;

  @override
  int get pendingImageCount => _small.pendingImageCount + _large.pendingImageCount;

  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) =>
      _cacheForKey(key).putIfAbsent(key, loader, onError: onError);

  @override
  ImageCacheStatus statusForKey(Object key) => _cacheForKey(key).statusForKey(key);
}

/// 自定义 binding：接入双桶缓存（immich 的 widgets_binding.dart 同款手法）。
/// main 里以 `VisortWidgetsBinding.ensureInitialized()` 替代
/// `WidgetsFlutterBinding.ensureInitialized()`。
final class VisortWidgetsBinding extends WidgetsFlutterBinding {
  @override
  ImageCache createImageCache() => VisortImageCache();
}
