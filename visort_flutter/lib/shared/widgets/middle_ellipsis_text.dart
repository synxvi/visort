// 中段省略文件名 —— 长文件名在视觉中段靠后处截断，保留扩展名。
//
// 对比 TextOverflow.ellipsis（尾部 ...）：文件名常以 .ext 结尾，尾部省略会把
// 扩展名吃掉，且 ... 紧贴后续元素。中段省略模式：name...stub.png
//   - 测量自身可用宽度（LayoutBuilder）
//   - 若全文放得下 → 原样显示
//   - 放不下 → 在 basename 中段插 ...，末尾保留 .ext（如 long_fil...mg.png）
//
// 仅按字符长度启发式截断（足够文件名场景），不做像素级二分（避免性能开销）。

import 'package:flutter/material.dart';

class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(
    this.text, {
    super.key,
    required this.style,
    this.alignment = Alignment.centerLeft,
    this.padding = EdgeInsets.zero,
  });

  /// 待显示文本（通常是文件名，含扩展名）。
  final String text;

  /// 文本样式（与实际渲染一致，影响测量）。
  final TextStyle style;

  /// 文本在容器内的对齐（默认左中）。
  final Alignment alignment;

  /// 文本外层内边距（占用可用宽度，影响截断判定）。
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // padding 占掉的宽度先扣除。
        final horizPadding = padding.horizontal;
        final avail = constraints.maxWidth - horizPadding;
        final rendered = avail.isFinite && avail > 0
            ? _truncate(text, avail)
            : text;
        return Align(
          alignment: alignment,
          child: Padding(
            padding: padding,
            child: Text(rendered, style: style, maxLines: 1),
          ),
        );
      },
    );
  }

  /// 按可用宽度（px）决定是否截断，返回最终显示文本。
  ///
  /// 策略（优先级保证扩展名 + tail 始终可见）：
  /// 1. 全文放得下 → 原样。
  /// 2. 放不下 → 拆 basename / extension（取最后一个点，兼容多 . 文件名如
  ///    `IMG.2024.01.jpg` → base=`IMG.2024.01`、ext=`.jpg`）。
  /// 3. 优先保留 ext + 末尾 minTail 个字符（保证 ... 后面有内容），head 用剩余宽度。
  /// 4. 若 ext + tail 都放不下 → 尾部省略兜底。
  String _truncate(String src, double availWidth) {
    // 安全余量：单字符测量累加与整段 Text 渲染存在度量/字距误差，
    // 留约 1.5 字符宽度（fontSize 12 下约 10px）避免算得下实际溢出（如 .png 丢 g）。
    // (原 16px 偏保守,触发 … 过早,head 仅 1 字符就截断;收窄到 10 让 head 更长。)
    final safe = availWidth - 10;
    if (safe <= 0) return src; // 宽度极小，不截断交给 Text 自身处理
    if (_textWidth(src) <= safe) return src;

    // 拆 basename / extension：最后一个点为分隔，兼容多 . 文件名。
    final dot = src.lastIndexOf('.');
    final hasExt = dot > 0 && dot < src.length - 1;
    final ext = hasExt ? src.substring(dot) : '';
    final base = hasExt ? src.substring(0, dot) : src;
    if (base.isEmpty) return src; // 全是扩展名的怪异情况，原样返回

    const ellipsis = '…';
    const minTail = 2; // ... 后至少保留 2 字符(原 3 挤占 head 致 … 靠前)

    // ① 先预留 tail：从 base 末尾取 minTail 个字符（固定，不可侵占）。
    final tail = base.length >= minTail
        ? base.substring(base.length - minTail)
        : base;

    // ② 连 ext + ... + tail 都放不下 → 尾部省略兜底（极端窄宽度）。
    final fixed = '$ellipsis$tail$ext';
    if (_textWidth(fixed) >= safe) {
      var s = src;
      while (s.isNotEmpty && _textWidth(s + ellipsis) > safe) {
        s = s.substring(0, s.length - 1);
      }
      return s + ellipsis;
    }

    // ③ 从 base 开头逐步取 head，每次整体校验宽度（含 ext+tail），超了就停。
    //    整体校验避免单字符累加误差导致末尾字符被吃。
    final maxHeadLen = base.length - tail.length; // 不侵入 tail
    var head = '';
    for (var i = 1; i <= maxHeadLen; i++) {
      final candidate = base.substring(0, i);
      if (_textWidth('$candidate$fixed') > safe) break;
      head = candidate;
    }
    if (head.isEmpty) head = base.substring(0, 1); // 至少 1 字符
    return '$head$ellipsis$tail$ext';
  }

  /// 测量单行文本宽度（px）。
  double _textWidth(String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp.width;
  }
}
