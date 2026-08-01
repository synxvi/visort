# SORTR 相册功能增强调研报告

> 调研日期：2026-07-31
> 目的：为安卓相册功能增强寻找技术栈相近的开源项目，评估可复用代码与可借鉴设计。
> 本项目基线：Flutter + Riverpod ^2.6.1 + 自建 Kotlin MediaStore channel（MethodChannel `sortr/mediastore` + EventChannel `sortr/mediastore-events`，ContentObserver 300ms 防抖），keyset 游标分页，MsImageInfo 内存模型。

---

## 0. 候选筛选

针对 SORTR 技术栈（Flutter + Android Kotlin + MediaStore + 自建 channel）筛选 3 个最接近的开源项目：

| 仓库 | ⭐ | 许可证 | 定位 | 与 SORTR 契合 | 核心价值 |
|---|---|---|---|---|---|
| [`fluttercandies/flutter_photo_manager`](https://github.com/fluttercandies/flutter_photo_manager) | 769 | Apache-2.0 | 相册管理**底层插件**（封装 MediaStore） | **高**（技术栈同构） | Kotlin MediaStore 现成实现，回收站/收藏/EXIF 可直接移植 |
| [`fluttercandies/flutter_wechat_assets_picker`](https://github.com/fluttercandies/flutter_wechat_assets_picker) | 1651 | Apache-2.0 | 微信风格相册 **UI/picker** | 中（UI/交互层） | 相册 UI 模式、滑动多选、全屏预览手势 |
| [`deckerst/aves`](https://github.com/deckerst/aves) | 5012 | BSD-3 | 专业级相册 **app**（功能标杆） | 中-高（架构/功能） | 增量同步机制、元数据提取、SQLite 索引设计 |

排除项：`Sivatech24/flutter-image-gallery-app`（教程级，网络图非 MediaStore）。

---

## 1. photo_manager —— 复用核心（Kotlin 可直接移植）

技术栈与 SORTR 几乎同构（Flutter + Kotlin MethodChannel + MediaStore + 后台线程查询）。它是 SORTR 自建 channel 的「成熟工业版」。

### 1.1 相册功能实现要点

- **缩略图与缓存**：`thumb/ThumbnailUtil.kt` 全委托 Glide，`.signature(ObjectKey(modifiedDate))` 按修改时间缓存失效，`requestCacheThumb(Priority.LOW)` 异步预热。`ScopedCache.kt` 是原文件缓存（非缩略图）。
- **分页**：`IDBUtils.getSortOrder` 返回 `"<orderBy> LIMIT $size OFFSET $start"`——**OFFSET 分页**，`AndroidQDBUtils.cursorWithRange` 在游标侧切片。
- **ContentObserver**：`PhotoManagerNotifyChannel.kt` 对 image/video/audio 三 URI 各注册一个 observer，**无防抖**；`onChange` 用 `DATE_ADDED<30s` 判 insert/update，查不到行判 delete；经独立 MethodChannel `…/notify` 推 `{type,id,galleryId}`。`safeQuery` 降级 Volume-not-found。
- **删除/回收站/移动/收藏**（均经 ActivityResult consent）：
  - `PhotoManagerDeleteManager`：`deleteInApi30`(createDeleteRequest)、`deleteJustInApi29`(RecoverableSecurityException 队列)、`moveToTrashInApi30`/`restoreFromTrashInApi30`(createTrashRequest)。
  - `PhotoManagerWriteManager.moveToPathWithPermission`：createWriteRequest 取权限→`update RELATIVE_PATH`。
  - `PhotoManagerFavoriteManager.favoriteAsset`：createFavoriteRequest（API30+）。
- **权限**：`PermissionDelegate33`(READ_MEDIA_IMAGES/VIDEO/AUDIO) + `PermissionDelegate34`(READ_MEDIA_VISUAL_USER_SELECTED 部分访问)。
- **元数据**：`IDBUtils.getExif`(完整 ExifInterface)、`getLatLong`(图 ExifInterface.latLong，视频 MediaMetadataRetriever ISO6709)。投影列含 `IS_FAVORITE/IS_TRASHED/DURATION/WIDTH/HEIGHT/ORIENTATION`。

### 1.2 可直接移植（Kotlin 片段 → `MediaStoreRepository.kt`/`MediaStorePlugin.kt`）

1. **回收站**：`moveToTrashInApi30`/`restoreFromTrashInApi30` + `logQuery(includeTrashed=true)`(`QUERY_ARG_MATCH_TRASHED=MATCH_INCLUDE`) + 投影 `IS_TRASHED`。
2. **收藏**：`favoriteAsset`(`createFavoriteRequest`) + 投影 `IS_FAVORITE`。
3. **EXIF/GPS**：`getExif`/`getLatLong`。
4. **移动升级**：`moveToPathWithPermission`(createWriteRequest→update)——把 SORTR 移动升级为系统级 consent。
5. **健壮性**：`ActivityResultListener` + requestCode + RecoverableSecurityException 队列；`isVolumeNotFound` + 空 MatrixCursor 降级。

### 1.3 仅借鉴模式（不引入依赖）

- Glide 缩略图的 `.signature(modifiedDate)` 失效键 + `Priority.LOW` 批量预热——但**不建议引入 Glide**（SORTR 已用系统 `loadThumbnail`）。
- ContentObserver 的 insert/update/delete 分类启发式。
- `requestCacheAssetsThumbnail` 的预热-取消生命周期。

### 1.4 ⚠️ 关键结论

保持 SORTR 的 **keyset 游标分页**。photo_manager 的 `OFFSET` 在并发插入/删除时会重复/跳页，SORTR 方案更优，勿回退。

---

## 2. wechat_assets_picker —— UI/交互参考

基于 photo_manager + extended_image + provider 的微信风格 picker，核心由 builder-delegate 模式驱动。

### 2.1 相册浏览 UI 模式（→ `gallery_screen`/`album_screen`）

- **bucket 切换**：`pathEntitySelector` 经典微信交互——AppBar 标题药丸 + `AnimatedAlign` 滑下列表。
- **网格滚动**：`assetsGridBuilder` 用 `SliverGrid` + `findChildIndexCallback`(稳定 key) + `Selector` 限重建 + `RepaintBoundary` 包缩略图；`assetGridItemBuilder` 滚动到底（index==length-gridCount*3）触发 loadMore。
- **滑动多选**：`AssetGridDragSelectionCoordinator`（309 行）：`_calculateIndexFromPosition` 全局坐标→row*gridCount+col 网格索引 + `EdgeDraggingAutoScroller` 边缘自动滚动。被外层 `GestureDetector(onHorizontalDrag*/onLongPress*/onPan*)` 调用。
- **bucket 封面/计数**：`PathWrapper<Path>`(`thumbnailData` + `assetCount`)，异步填充。
- **bucket 排序**：`CommonSortPathDelegate`（最近/相机/截图置顶 + lastModified 倒序）。

### 2.2 全屏预览（→ `PhotoViewer`）

`AssetPickerViewerBuilderDelegate` + `image_page_builder`：`ExtendedImageGesturePageView` 水平翻页 + 双击 1↔3 Tween 缩放动画 + `GestureConfig(minScale:1,maxScale:3)`。**无下滑关闭**——SORTR 的 `InteractiveViewer` 已覆盖缩放/双击，下滑关闭需自行补。

### 2.3 provider→Riverpod 对应

`ChangeNotifier`→`Notifier`，`Selector`→`select()`，「selectedDescriptions 重建键」技巧→Riverpod `select()`。状态核心 `AssetPickerProvider` 对应 SORTR `GalleryController`。

---

## 3. aves —— 功能标杆 + 架构启发

Flutter + Kotlin 双端专业级安卓相册与元数据 explorer（5,012⭐）。作者声明不接 PR，但 BSD-3 允许参考与代码移植。依赖**自有 SQLite 索引层**（SORTR 当前无）。

### 3.1 MediaStore channel 架构（对比 SORTR 的最大价值点）

`android/.../channel/` 按「语义 × 方向」三类拆分：

- **`calls/` = MethodChannel（请求-响应）**，按领域分文件：`MediaStoreHandler`、`MetadataFetchHandler`、`MediaEditHandler`、`GeocodingHandler` 等约 18 个，每个持 `ioScope=Dispatchers.IO`，统一 `Coresult.safe`。
- **`streams/darttoplatform/`**：`MediaStoreStreamHandler`(增量拉取)、`ImageOpStreamHandler`(批量操作逐条回报)、`ImageByteStreamHandler`。
- **`streams/platformtodart/`**：`AnalysisStreamHandler`、`MediaCommandStreamHandler`(ContentObserver/Intent 推送)。

流通道用 `app.loup.streams_channel.StreamsChannel` 插件（非原生 EventChannel）。

### 3.2 最值得吸收的两点

1. **增量同步机制**（性能主线）：
   - `getEntries(knownEntries={contentId→dateModifiedMillis})`：native 端跳过「已知且未变」的条目，只流式回新增/变更项。
   - API30+ 用 `MediaStore.getGeneration()` + `getChangedUris(sinceGeneration)` 做 generation 增量。
   - `checkObsoleteContentIds`/`checkObsoletePaths` 精确判定删除项。
   - 比 SORTR 当前 ContentObserver 触发的**全量重查**省大量 CPU/IO。
2. **元数据提取库选型**：`MetadataFetchHandler`(1557 行) 用 `metadata-extractor` + `ExifInterface` + Adobe `XMPCore` + `mp4parser`，`getAllMetadata` 返回 `Map<目录,Map<tag,desc>>`——直接契合 SORTR `photo_details_sheet`。

### 3.3 自有 SQLite 索引层（为搜索/统计铺路）

`db_sqflite_schema.dart` 10 张表：`entry`/`metadata`/`address`(反向地理编码)/`dateTaken`/`favourites`/`covers`(相册封面策略)/`dynamicAlbums`(搜索存为虚拟相册)/`vaults`/`trash`/`videoPlayback`(视频续播)。

### 3.4 其它功能全景

- 双 Flutter 引擎 + WorkManager 后台扫描（`AnalysisWorker` 新建独立后台引擎 + SQLite 通信，App 关闭仍可扫描）——复杂度高，建议 SORTR 暂缓。
- 富 Entry 模型 `AvesEntry`：`bestDate` 三级回退(catalog→dateTaken→dateModified)、`isRotated`/`displaySize`/`displayAspectRatio`、`stackedEntries`(连拍/raw+jpg 堆叠)。
- 搜索 `collection_search_delegate.dart` + `GlobalSearchHandler`；统计 `stats_page.dart`；筛选 `model/filters/*`；视频 `MediaSessionHandler`+`videoPlayback`。

### 3.5 可复用/可借鉴

- **可直接移植**：metadata-extractor + ExifInterface 原生 EXIF 方案（加 Gradle 依赖即可）；DB schema 设计蓝本；`ImageOpStreamHandler` 批量操作流式回报模式。
- **借鉴设计**：generation 增量同步；channel 按领域拆 calls/streams；AvesEntry 富模型 + bestDate 三级回退；servicePolicy 优先级限流。
- **仅产品参考**：地图视图、屏保/widget/壁纸、MediaSession、global search provider 接入。

---

## 4. 综合：增强路线图

| 优先级 | 增强项 | 借鉴源 | 复用方式 | 落点 | 工作量 |
|---|---|---|---|---|---|
| **P0** | EXIF/元数据展示 | aves `MetadataFetchHandler` + photo_manager `getExif` | 加 `metadata-extractor`+`exifinterface` 依赖，移植 Kotlin 方法 | `photo_details_sheet.dart` / `MediaStoreRepository.kt` | 中 |
| **P1** | 回收站 + 收藏 | photo_manager `DeleteManager`/`FavoriteManager` | **直接移植 Kotlin**（createTrashRequest/createFavoriteRequest） | `MediaStorePlugin.kt` + `MsImageInfo` 加 isTrashed/isFavorite | 中 |
| **P1** | ContentObserver 增量化 | photo_manager 分类启发式 + aves generation 增量 | EventChannel 载荷从「全量刷新」升级为 `{type,ids[],galleryId}` | `MediaStoreRepository.kt` / `gallery_controller.dart` | 中 |
| **P2** | 缩略图预热 | photo_manager `requestCache`（Priority.LOW 批量预热） | 沿用现有 `loadThumbnail` 通道做视口预热（不引入 Glide） | `gallery_controller.dart` | 小-中 |
| **P2** | 相册封面策略 | aves `covers` 表 + wechat `PathWrapper` | bucket 记录稳定封面 entryId/主色 | `gallery_controller.dart` / `MediaStoreModels.kt` | 小 |
| **P3** | 滑动多选 + 批量操作 | wechat `AssetGridDragSelectionCoordinator` + aves `ImageOpStreamHandler` | 借鉴坐标→index 映射 + 流式逐条回报 | `album_screen.dart` 新增多选模式 | 中-大 |
| **P3** | bucket 切换下拉 UI | wechat `pathEntitySelector` | 借鉴交互模式（Riverpod 重写） | `album_screen.dart` | 小 |
| **P4** | 视频支持 | aves `DURATION` + `videoPlayback` | `MsImageInfo` 加 `durationMillis` + 续播 | 全链路 | 大 |
| **P4** | 自有 SQLite 索引 | aves `db_sqflite_schema.dart` | 引入 sqflite，为搜索/统计铺路 | 新 `model/db/` | 大 |

---

## 5. 复用合规

- **Apache-2.0**（photo_manager / wechat_assets_picker）：移植代码须在文件头保留 `Copyright 2018 The FlutterCandies author`，并在仓库 `NOTICE`/`LICENSE-THIRD-PARTY` 登记。
- **BSD-3**（aves）：须保留版权与许可证声明，建议 README/致谢页注明「受 Aves 启发」。
- ⚠️ **aves 间接依赖 `mp4parser` 是 LGPL-3.0**——静态打包进 APK 有动态链接/替换义务，支持视频元数据前需法务确认；可改用其他 MP4 解析库规避。
- 建议一律**摘抄式借鉴**而非整文件拷贝，降低耦合与许可证负担。

---

## 6. 重要提醒

1. **保持 keyset 分页**——photo_manager 的 OFFSET 在并发写入时错位，SORTR 现有方案更优，勿回退。
2. **本项目的缩略图通道已存在**：`gallery_screen.dart`/`album_screen.dart` 经 `_AndroidThumbnailProvider`→`readThumbnail`→系统 `loadThumbnail`(API29+)。P2 缩略图增强方向是**预热 + 磁盘缓存**，不是「加缩略图通道」，也不要引入 Glide（系统 loadThumbnail 原生路径更快）。
3. **不要整包依赖 photo_manager**——会破坏 SORTR「自建轻量 channel + 双数据通路（分类/相册分离）」设计，且拖入 Glide 重依赖。摘抄式移植即可。

---

## 附录：调研依据

- photo_manager：`PhotoManagerNotifyChannel.kt`/`ThumbnailUtil.kt`/`IDBUtils.kt`/`AndroidQDBUtils.kt`/`PhotoManagerDeleteManager.kt`/`PhotoManagerWriteManager.kt`/`PhotoManagerFavoriteManager.kt`/`PermissionDelegate33-34.kt` + Dart `thumbnail.dart`/`entity.dart`/`notify_manager.dart`。
- wechat_assets_picker：`asset_picker_provider.dart`/`asset_picker_builder_delegate.dart`/`asset_picker_viewer_builder_delegate.dart`/`image_page_builder.dart`/`asset_entity_grid_item_builder.dart`/`asset_grid_drag_selection_coordinator.dart`/`sort_path_delegate.dart`/`path_wrapper.dart`。
- aves：`calls/MediaStoreHandler.kt`/`MetadataFetchHandler.kt`/`MediaEditHandler.kt`；`streams/BaseStreamHandler.kt`/`MediaStoreStreamHandler.kt`/`ImageOpStreamHandler.kt`；`AnalysisWorker.kt`/`analysis_service.dart`/`media_store_service.dart`/`metadata_fetch_service.dart`/`db_sqflite_schema.dart`/`entry/entry.dart`。
