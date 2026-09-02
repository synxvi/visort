// Windows 键盘交互 —— 对齐前端 handleKey（index.html:2220-2233）
//
// 优先级：文件夹 key → Space(根目录) → delete → skip → undo
// 大小写不敏感；TextField 聚焦时禁用（由 FocusScope 自动处理）
//
// 用 Shortcuts + Actions，仅 Sort 屏激活

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visort_flutter/core/i18n/i18n.dart';
import 'package:visort_flutter/features/session/session_controller.dart';
import 'package:visort_flutter/features/session/session_models.dart';

/// 包装 Sort 屏幕，注入键盘快捷键。
/// 文件夹 key 是动态的（用户配置），所以用 onKey 回调逐键判断。
class WindowsKeyboardHandler extends ConsumerStatefulWidget {
  const WindowsKeyboardHandler({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<WindowsKeyboardHandler> createState() =>
      _WindowsKeyboardHandlerState();
}

class _WindowsKeyboardHandlerState
    extends ConsumerState<WindowsKeyboardHandler> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 自动请求焦点以接收键盘事件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // 焦点守卫（审查 F12）：输入框聚焦时放行给 TextField——文件头「由
    // FocusScope 自动处理」不成立（本 onKeyEvent 挂在 Focus 上层，子节点
    // 未消费的键会到达这里，ESC 会同时清输入并 popUntil 清场；sort 屏
    // 未来加输入框即踩雷）。
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }

    // 0. ESC → 中断整理返回移动前一级页(与 AppBar 返回箭头同语义,pop
    //    保留 shell/HomeScreen 状态;会话已持久化,Home 顶部「继续」可恢复)
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.popUntil(context, (r) => r.isFirst);
      return KeyEventResult.handled;
    }

    final session = ref.read(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);
    final config = ref.read(configProvider);
    final actionKeys = config.activeProfileData.actionKeys;

    // 从 logicalKey 取字符。小键盘数字归一（审查 F12）：'Numpad 1' 等标签
    // 匹配不到文件夹 key '1'；空标签键直接忽略（用户误配空 key 时不会被
    // 无标签键意外命中）。
    var keyLabel = event.logicalKey.keyLabel;
    final numpad = RegExp(r'^Numpad (\d)$').firstMatch(keyLabel);
    if (numpad != null) keyLabel = numpad.group(1)!;
    if (keyLabel.isEmpty) return KeyEventResult.ignored;
    final key = keyLabel.toLowerCase();

    // 1. 文件夹 key 优先
    final folder = controller.folderByKey(key);
    if (folder != null) {
      controller.decide(DecisionAction.move, destKey: folder.key);
      _maybeFinish(session, controller);
      return KeyEventResult.handled;
    }

    // 2. Space → 根目录
    if (event.logicalKey == LogicalKeyboardKey.space) {
      controller.decide(DecisionAction.move, destKey: kRootDestKey);
      _maybeFinish(session, controller);
      return KeyEventResult.handled;
    }

    // 3. delete
    if (key == actionKeys.delete.toLowerCase()) {
      controller.decide(DecisionAction.delete);
      _maybeFinish(session, controller);
      return KeyEventResult.handled;
    }

    // 4. skip
    if (key == actionKeys.skip.toLowerCase()) {
      controller.decide(DecisionAction.skip);
      _maybeFinish(session, controller);
      return KeyEventResult.handled;
    }

    // 5. undo
    if (key == actionKeys.undo.toLowerCase()) {
      controller.undo();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// 决策后若已到末尾，不自动跳转（让用户主动点 Review）
  void _maybeFinish(SessionState session, SessionController controller) {
    // 这里不自动跳转，UI 通过 watch session 变化决定是否提示
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      autofocus: true,
      child: widget.child,
    );
  }
}
