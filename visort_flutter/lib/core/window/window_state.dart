// 窗口状态持久化 —— 记住上次窗口大小与位置
//
// 持久化内容：宽/高/左/上/是否最大化。存到 application support 目录的
// window_state.json。启动时恢复，窗口 resize/move 后异步保存。
//
// 注意：最大化时不覆盖普通尺寸，仅在还原为普通窗口时才记录。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
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
