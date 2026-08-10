// PhotoViewer 分页联动回归测试
//
// 背景: PhotoViewer 经 PageRouteBuilder.pageBuilder 创建,pageBuilder 只在 push
// 时执行一次 → widget.photos 是打开瞬间的快照。loadMore 后 gallery state.photos
// 增长但 widget.photos 不刷新,didUpdateWidget 的合并(photos.length 比较)永不触发
// → _photos 卡在第一页(_pageSize=60) → 翻到第 60 张后再也无法右滑(大相册 100%
// 复现,小相册不触发)。
//
// 修复: build 里 ref.listen 直接监听 galleryControllerProvider,把 loadMore 追加
// 的条目合并进 _photos。本测试验证该合并: gallery state.photos 增长后 PageView
// itemCount 同步增长(修复前卡在第一页长度)。

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';
import 'package:visort_flutter/features/gallery/gallery_controller.dart';
import 'package:visort_flutter/ui/screens/photo_viewer.dart';

MsImageInfo _photo(String id) => MsImageInfo(
      id: id,
      name: '$id.jpg',
      size: 1024,
      mime: 'image/jpeg',
      bucketId: 'b1',
      dateAddedMs: 0,
      dateModifiedMs: 0,
      width: 100,
      height: 100,
    );

/// 可外部控制 state 的 stub controller(跳过 channel/config 初始化)。
class _StubGalleryController extends GalleryController {
  @override
  GalleryState build() => const GalleryState();

  void setPhotos(List<MsImageInfo> photos) {
    state = state.copyWith(photos: photos, nextCursor: 'more');
  }

  void appendPhotos(List<MsImageInfo> photos) {
    state = state.copyWith(photos: [...state.photos, ...photos]);
  }
}

int _pageViewItemCount(WidgetTester tester) {
  final w = tester.widget<ExtendedImageGesturePageView>(
      find.byType(ExtendedImageGesturePageView));
  return (w.childrenDelegate as SliverChildBuilderDelegate).childCount ?? 0;
}

void main() {
  testWidgets('gallery state.photos 增长 → viewer PageView itemCount 同步增长',
      (tester) async {
    final stub = _StubGalleryController();
    final container = ProviderContainer(overrides: [
      galleryControllerProvider.overrideWith(() => stub),
    ]);
    addTearDown(container.dispose);
    container.read(galleryControllerProvider); // 触发 build,_element 注入

    // 初始第一页(模拟 _pageSize 张已加载)
    final firstPage = [_photo('1'), _photo('2')];
    stub.setPhotos(firstPage);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // widget.photos = 打开瞬间的快照(等同 PageRouteBuilder.pageBuilder
          // 闭包捕获的值——push 后不再刷新)。
          home: PhotoViewer(photos: firstPage, initialIndex: 0),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(_pageViewItemCount(tester), 2,
        reason: '初始 PageView itemCount 应等于第一页长度');

    // loadMore 后 gallery state.photos 增长(第二页追加)。
    stub.appendPhotos([_photo('3'), _photo('4')]);
    await tester.pump();
    await tester.pump();

    expect(_pageViewItemCount(tester), 4,
        reason: 'loadMore 后 gallery photos 增长应经 ref.listen 合并到 viewer。'
            '修复前 widget.photos 快照不刷新 → didUpdateWidget 合并不触发 → '
            'itemCount 卡在第一页长度(2),大相册翻到第 60 张后无法继续右滑。');
  });

  // 删除后 gallery state.photos 缩短时不应误触发合并(删除由 viewer 本地处理)。
  testWidgets('gallery state.photos 缩短(删除)不触发合并、不干扰本地删除',
      (tester) async {
    final stub = _StubGalleryController();
    final container = ProviderContainer(overrides: [
      galleryControllerProvider.overrideWith(() => stub),
    ]);
    addTearDown(container.dispose);
    container.read(galleryControllerProvider); // 触发 build,_element 注入

    final firstPage = [_photo('1'), _photo('2')];
    stub.setPhotos(firstPage);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: PhotoViewer(photos: firstPage, initialIndex: 0),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_pageViewItemCount(tester), 2);

    // 删除一张(photos 缩短):ref.listener 应因 length <= _photos.length 直接返回。
    stub.setPhotos([_photo('1')]);
    await tester.pump();
    await tester.pump();

    // viewer 自身的 _photos 未变(删除走 _removeCurrentAndAdvance 本地路径,
    // 此处只验证 listener 不误删),itemCount 仍为 2。
    expect(_pageViewItemCount(tester), 2,
        reason: 'gallery photos 缩短(删除场景)不应经 listener 改动 viewer _photos');
  });
}
