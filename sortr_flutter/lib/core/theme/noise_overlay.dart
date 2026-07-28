// 噪点纹理叠加层 —— 还原 index.html body::before 的 feTurbulence 噪点效果
//
// 源: index.html:108-116
//   feTurbulence fractalNoise baseFrequency=0.9 numOctaves=4
//   噪点 opacity=0.04，叠加层 opacity=0.35
//   position:fixed; inset:0; pointer-events:none
//
// 关键设计：噪点 PNG 用【白色像素 + 随机 alpha】(RGBA)，
// 而不是灰度图。原因：
//   - 灰度图均值 127 会被 DecorationImage 当作不透明层整体铺满 → 提亮背景成中灰
//   - 白+alpha 图：黑色/透明处不贡献，只在 alpha>0 处叠加白色颗粒
//   - 配合 Opacity(0.04*0.35≈0.014) 控制，效果 = 极淡颗粒质感

import 'package:flutter/material.dart';

class WithNoise extends StatelessWidget {
  const WithNoise({
    super.key,
    required this.child,
    this.opacity = 0.014, // 0.35(叠加层) * 0.04(噪点强度)
  });

  final Widget child;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: const _NoiseLayer(),
            ),
          ),
        ),
      ],
    );
  }
}

class _NoiseLayer extends StatelessWidget {
  const _NoiseLayer();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/images/noise.png'),
          repeat: ImageRepeat.repeat,
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}
