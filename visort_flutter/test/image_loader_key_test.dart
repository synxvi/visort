// 解码管线 key 同源测试（矩阵 A 本机可测部分）。
//
// computeViewerTargetWidth 是 precache/_BigImage/evict 三处共用的宽度
// 公式——任何一处自算（或参数口径不同）都会造成 ImageCache key 不匹配：
// 预热进缓存的条目 evict 清不掉 / 大图请求 key 对不上预热条目重解码。
// 此处锁定公式行为（max(960, 屏宽物理像素×0.8)）；evict 全档清理依赖
// Android channel（Platform 守卫），归模拟器/真机验证轮。
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/image_loader.dart';

void main() {
  group('computeViewerTargetWidth（precache/BigImage/evict 三处同源）', () {
    test('窄屏垫底 960（12MP 图下采样 ~1MP，压进飞行窗）', () {
      expect(computeViewerTargetWidth(720), 960); // 720×0.8=576 < 960
      expect(computeViewerTargetWidth(1080), 960); // 864 < 960
      expect(computeViewerTargetWidth(1200), 960); // 正好 960
    });

    test('宽屏用 0.8×：PJZ110 物理宽 1440 → 1152', () {
      expect(computeViewerTargetWidth(1440), 1152);
      expect(computeViewerTargetWidth(2000), 1600);
    });

    test('非整数屏宽取整（key 稳定性：同一屏宽恒同一 tw）', () {
      expect(computeViewerTargetWidth(1399), 1119); // 1399×0.8=1119.2 → 1119
      expect(computeViewerTargetWidth(1399), computeViewerTargetWidth(1399));
    });
  });

  group('imageRefFromMediaStoreId（封面/网格临时包装）', () {
    test('id 进 relativePath、root 为 MediaStore authority', () {
      final ref = imageRefFromMediaStoreId('42', extension: '.png');
      expect(ref.relativePath, '42');
      expect(ref.extension, '.png');
      // kImagesAuthority：MediaStore images 表 authority（root 即缓存 key
      // 的一部分——与 viewer/网格构造路径同源）。
      expect(ref.root, 'content://media/external/images/media');
    });
  });
}
