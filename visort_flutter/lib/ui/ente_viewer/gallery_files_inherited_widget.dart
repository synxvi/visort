// [ente 移植] 网格文件共享状态 —— 原文件：ente .../state/gallery_files_inherited_widget.dart

import 'package:flutter/material.dart';
import 'package:visort_flutter/core/fs/mediastore_channel.dart';

// ignore: must_be_immutable
class GalleryFilesState extends InheritedWidget {
  GalleryFilesState({super.key, required super.child});

  // Keep the same file objects used by galleryGroups so mutations stay in sync.
  List<MsImageInfo>? _galleryFiles;

  set setGalleryFiles(List<MsImageInfo> galleryFiles) {
    _galleryFiles = galleryFiles;
  }

  void removeFile(MsImageInfo file) {
    _galleryFiles!.remove(file);
  }

  List<MsImageInfo>? get galleryFilesOrNull => _galleryFiles;

  List<MsImageInfo> get galleryFiles {
    assert(
      _galleryFiles != null,
      "Gallery files not set yet. Should be set in the gallery widget",
    );
    return _galleryFiles!;
  }

  static GalleryFilesState? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<GalleryFilesState>();
  }

  static GalleryFilesState of(BuildContext context) {
    final result = maybeOf(context);
    assert(result != null, 'No GalleryFiles found in context.');
    return result!;
  }

  @override
  bool updateShouldNotify(GalleryFilesState oldWidget) => false;
}
