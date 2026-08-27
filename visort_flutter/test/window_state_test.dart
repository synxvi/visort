// WindowBounds JSON 编解码测试
//
// WindowStateService 依赖 path_provider + window_manager（平台绑定，需
// mock 才能在单测跑）——纯逻辑 WindowBounds 的 toJson/fromJson 往返是
// 可测的持久化契约：损坏/缺失字段的解析行为也在此固定。

import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/window/window_state.dart';

void main() {
  group('WindowBounds JSON 往返', () {
    test('普通窗口往返一致', () {
      final bounds = WindowBounds(
        width: 1280.0,
        height: 800.0,
        offsetX: 100.0,
        offsetY: 50.0,
        isMaximized: false,
      );
      final restored = WindowBounds.fromJson(bounds.toJson());
      expect(restored.width, 1280.0);
      expect(restored.height, 800.0);
      expect(restored.offsetX, 100.0);
      expect(restored.offsetY, 50.0);
      expect(restored.isMaximized, false);
    });

    test('最大化状态往返一致', () {
      final bounds = WindowBounds(
        width: 1920.0,
        height: 1080.0,
        offsetX: 0.0,
        offsetY: 0.0,
        isMaximized: true,
      );
      final restored = WindowBounds.fromJson(bounds.toJson());
      expect(restored.isMaximized, true);
    });

    test('旧 JSON 缺 is_maximized 字段 → 默认 false（兼容旧版）', () {
      final restored = WindowBounds.fromJson({
        'width': 800.0,
        'height': 600.0,
        'offset_x': 10.0,
        'offset_y': 20.0,
      });
      expect(restored.isMaximized, false);
      expect(restored.width, 800.0);
      expect(restored.height, 600.0);
    });

    test('数值字段以 num 存储（int 也兼容）', () {
      final restored = WindowBounds.fromJson({
        'width': 800,
        'height': 600,
        'offset_x': 10,
        'offset_y': 20,
        'is_maximized': true,
      });
      expect(restored.width, 800.0);
      expect(restored.height, 600.0);
      expect(restored.isMaximized, true);
    });
  });
}
