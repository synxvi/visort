// 逐行移植自 immich：mobile/lib/presentation/widgets/images/
// cache_aware_listener_tracker.mixin.dart（2026-09-08，代码级对齐基线）。
// 原始语义见英文注释；doc 三坑描述保留原文结构，中文批注标 visort 场景。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';

/// Tracks listeners on an [ImageStreamCompleter] to safely cancel in-flight
/// network requests without interfering with [ImageCache] internals.
///
/// ### Problem
/// Cancelling fetches when the listener count drops to 1 (cache only) or 0
/// is unsafe due to three framework behaviours:
///
/// 1. **Memory-pressure eviction** — `ImageCache.clear()` removes the cache
///    listener while UI widgets still need the image. A count-based check
///    would cancel the active fetch, leaving the UI with no image.
/// 2. **Synchronous detach during `putIfAbsent`** — When an `initialImage`
///    is provided, the cache attaches, receives the frame, and detaches
///    synchronously *before* the UI widget can attach. Count reaches 0 and
///    would trigger a false cancel.
/// 3. **Listener misidentification** — After the cache detaches (via 1 or 2),
///    the next UI listener could be mistaken for the cache listener, causing
///    incorrect cancellations when that widget is disposed.
///
/// ### Solution: First-Listener Heuristic
/// The cache is always the first listener attached (via `putIfAbsent`). This
/// mixin records that identity once and uses it for all subsequent decisions:
///
/// * **Identity locking** — The first listener is assumed to be the cache.
///   Once identified, `_hasIdentifiedCacheListener` prevents reassignment.
/// * **Targeted cancellation** — Cancel only when the identified cache
///   listener is the sole remaining listener and no image has been delivered.
/// * **Sync-removal bypass** — When `hadInitialImage` is set, the first
///   synchronous removal of the cache listener is ignored so the fetch
///   survives until the UI attaches.
///
/// [visort] 场景：viewer 渐进升档 completer（_ProgressiveViewerImageCompleter）
/// 构造时以 1152 帧作 initialImage 同步 setImage（此时尚无任何 listener），
/// cache 的 pending listener 随后同步 attach→收帧→detach——没有
/// `_hasIgnoredFirstSyncRemoval` 兜底时这次同步 detach 会把计数打到 0，
/// 触发假死亡（真机「反复双击死活不清楚」的根因之一，2026-09-08）。
mixin CacheAwareListenerTrackerMixin on ImageStreamCompleter {
  void Function()? _onLastListenerRemoved;
  int _listenerCount = 0;
  bool _hadInitialImage = false;
  bool _hasIgnoredFirstSyncRemoval = false;
  ImageStreamListener? _cacheListener;
  bool _hasIdentifiedCacheListener = false;

  /// Initializes the tracking state. Must be called in the subclass constructor.
  void setupListenerTracking({
    required bool hadInitialImage,
    void Function()? onLastListenerRemoved,
  }) {
    _hadInitialImage = hadInitialImage;
    _onLastListenerRemoved = onLastListenerRemoved;
  }

  @override
  void addListener(ImageStreamListener listener) {
    if (!_hasIdentifiedCacheListener) {
      _hasIdentifiedCacheListener = true;
      _cacheListener = listener;
    }

    _listenerCount++;
    debugPrint('[TRK] add count=$_listenerCount first=${_cacheListener == listener}');
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    _listenerCount--;

    final bool isCacheListener = listener == _cacheListener;
    if (isCacheListener) {
      _cacheListener = null;
    }

    if (_hadInitialImage && !_hasIgnoredFirstSyncRemoval && isCacheListener) {
      _hasIgnoredFirstSyncRemoval = true;
      debugPrint('[TRK] rm bypass-sync count=$_listenerCount');
      return;
    }

    debugPrint(
      '[TRK] rm count=$_listenerCount isCache=$isCacheListener '
      'had=$_hadInitialImage ignored=$_hasIgnoredFirstSyncRemoval',
    );

    final bool onlyCacheListenerLeft =
        _listenerCount == 1 && _cacheListener != null;

    final bool completelyAbandoned = _listenerCount == 0;

    if (onlyCacheListenerLeft || completelyAbandoned) {
      final onLastListenerRemoved = _onLastListenerRemoved;
      if (onLastListenerRemoved != null) {
        _onLastListenerRemoved = null;
        debugPrint(
          '[TRK] fire onLastListenerRemoved only=$onlyCacheListenerLeft '
          'abandoned=$completelyAbandoned',
        );
        onLastListenerRemoved();
      }
    }
  }
}
