// 窗口状态持久化 —— 记住上次窗口大小与位置
//
// 持久化内容：宽/高/左/上/是否最大化。存到 application support 目录的
// window_state.json。启动时恢复，窗口 resize/move 后异步保存。
//
// 注意：最大化时不覆盖普通尺寸，仅在还原为普通窗口时才记录。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class WindowBounds {
  const WindowBounds({
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
    this.isMaximized = false,
  });

  final double width;
  final double height;
  final double offsetX;
  final double offsetY;
  final bool isMaximized;

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'offset_x': offsetX,
        'offset_y': offsetY,
        'is_maximized': isMaximized,
      };

  factory WindowBounds.fromJson(Map<String, dynamic> json) => WindowBounds(
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        offsetX: (json['offset_x'] as num).toDouble(),
        offsetY: (json['offset_y'] as num).toDouble(),
        isMaximized: (json['is_maximized'] as bool?) ?? false,
      );

  @override
  String toString() =>
      'WindowBounds(${width}x$height @ $offsetX,$offsetY max=$isMaximized)';
}

class WindowStateService {
  static const _fileName = 'window_state.json';

  Future<File> get _file async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// 加载已保存的窗口状态。不存在或解析失败返回 null。
  Future<WindowBounds?> load() async {
    try {
      final file = await _file;
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return WindowBounds.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// 校验已保存窗口与任一显示器的可见区域相交（≥100×100 阈值）。
  ///
  /// 换主屏/拔副屏后，保存的 offset 可能落在已不存在的屏幕区域——
  /// 越界但合法的坐标 setBounds 不报错，表现为「应用启动了却看不见
  /// 窗口」，且每次启动都会被屏外坐标覆写保存（审查 P1）。返回 false
  /// 时调用方只恢复尺寸并居中。
  Future<bool> isBoundsOnScreen(WindowBounds b) async {
    final win = Rect.fromLTWH(b.offsetX, b.offsetY, b.width, b.height);
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final vp = d.visiblePosition;
        final vs = d.visibleSize ?? d.size;
        final visible = Rect.fromLTWH(
          vp?.dx ?? 0,
          vp?.dy ?? 0,
          vs.width,
          vs.height,
        );
        final inter = visible.intersect(win);
        // 至少露出 100×100，肉眼能找到并拖回；完全在屏外才算越界。
        if (inter.width >= 100 && inter.height >= 100) return true;
      }
      return false;
    } catch (_) {
      // 探测失败（API 异常/平台差异）不误伤：按可见处理，行为同旧版。
      return true;
    }
  }

  /// 从当前窗口读取状态并保存。
  Future<void> saveCurrent() async {
    try {
      final isMaximized = await windowManager.isMaximized();
      final size = await windowManager.getSize();
      final offset = await windowManager.getPosition();
      final bounds = WindowBounds(
        width: size.width,
        height: size.height,
        offsetX: offset.dx,
        offsetY: offset.dy,
        isMaximized: isMaximized,
      );
      await _write(bounds);
    } catch (_) {
      // 静默失败：保存失败不应影响使用
    }
  }

  Future<void> _write(WindowBounds bounds) async {
    final file = await _file;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(bounds.toJson()));
  }
}
