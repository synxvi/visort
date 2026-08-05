---
goal: VISORT 相册功能增强（P0 元数据展示 / P1 回收站·收藏·ContentObserver 增量化）
version: '1.0'
date_created: 2026-07-31
owner: synxvi
status: 'Planned'
tags: [feature, android, gallery, mediastore, kotlin]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

基于 [`docs/GALLERY_RESEARCH.md`](GALLERY_RESEARCH.md) 调研结论，对安卓相册功能进行 **P0–P1** 增强。所有改动遵循现有「自建轻量 MediaStore channel + 双数据通路」设计，采用**摘抄式移植**（photo_manager Apache-2.0 / aves BSD-3），不引入 photo_manager 整包或 Glide。

**范围**：
- **P0** — EXIF/元数据展示（详情抽屉增强）
- **P1a** — 回收站（移入 / 恢复 / 回收站视图）
- **P1b** — 收藏（收藏 / 取消收藏 / 收藏视图）
- **P1c** — ContentObserver 增量化（`"changed"` 字符串 → 结构化事件，精准刷新）

**不在本计划范围**：缩略图预热(P2)、相册封面策略(P2)、滑动多选(P3)、视频(P4)、SQLite 索引(P4)。

---

## 1. Requirements & Constraints

- **REQ-001**：所有写操作（trash/restore/favorite）沿用现有 `MediaStore.createXxxRequest` + `ActivityResultListener` + `startIntentSenderForResult` 异步弹窗模式，保持「一次系统弹窗」体验。
- **REQ-002**：保留 keyset 游标分页；新增 `IS_TRASHED/IS_FAVORITE` 投影列不得破坏分页游标稳定性。
- **REQ-003**：API 兼容性守卫：`createTrashRequest`/`createFavoriteRequest`/`IS_TRASHED`/`IS_FAVORITE` 均为 API 29+/30+ 特性，低版本须优雅降级（返回空结果或 unsupported 错误），不得崩溃。
- **CON-001**：`MsImageInfo` 模型扩展（加 `isTrashed/isFavorite`）须向后兼容——现有 JSON/Map 反序列化不得 break（参考 v2 排序字段迁移的向后兼容经验）。
- **CON-002**：i18n 新增键须同时加到 `strings_en.dart` 与 `strings_zh.dart`（项目约定）。
- **CON-003**：复用 photo_manager / aves 代码须保留版权头声明并在 `NOTICE` 登记（见 §4 Dependencies）。
- **GUD-001**：Kotlin 查询全部走现有 `ioExecutor`（4 线程）+ `mainHandler` 主线程回调；`result` 必须主线程调用。
- **GUD-002**：错误用 `MsError` 类型化错误码（与 Dart `MsErrorCode` 对齐），UI 可按 code 分支。
- **PAT-001**：移植范例——photo_manager `PhotoManagerDeleteManager.moveToTrashInApi30` / `PhotoManagerFavoriteManager.favoriteAsset` / `PhotoManagerNotifyChannel.onChange` 分类启发式。
- **PAT-002**：UI 落点——`photo_details_sheet.dart` 复用现有 `_row(label,value)` 两列模式；收藏/回收站入口复用现有 `GalleryController` + Riverpod 模式。

---

## 2. Implementation Steps

### Implementation Phase 1 — P0 元数据展示（EXIF）

- **GOAL-001**：在 `photo_details_sheet` 显示 EXIF/GPS/相机参数，Kotlin 侧用 `metadata-extractor` + `exifinterface` 提取。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-101 | **Gradle 加依赖**：`android/app/build.gradle.kts` 的 `dependencies {}` 块加 `implementation("androidx.exifinterface:exifinterface:1.3.7")` 与 `implementation("com.drew:metadata-extractor:2.19.0")`。**不加** `mp4parser`（LGPL-3.0，法务风险）。 |  |  |
| TASK-102 | **Kotlin `MsError` 扩展**：`MediaStoreModels.kt` 的 `sealed class MsError` 加 `data class MetadataFailed(override val message: String) : MsError("METADATA_FAILED", message)`。 |  |  |
| TASK-103 | **Kotlin 提取方法**：`MediaStoreRepository.kt` 新增 `fun getMetadata(id: String): Map<String, Map<String,String>>`。实现：用 `ContentUris.withAppendedId(EXTERNAL_CONTENT_URI, id.toLong())` 取 URI，`contentResolver.openInputStream(uri)?.use { ... }`；先用 `androidx.exifinterface.media.ExifInterface(inputStream)` 取 EXIF（TAG_MAKE/MODEL/F_NUMBER/EXPOSURE_TIME/ISO/FOCAL_LENGTH/DATE_TIME_ORIGINAL/GPS_LATLONG/ORIENTATION），再用 `com.drew.imaging.ImageMetadataReader.readMetadata()` 兜底（目录→tag 遍历）。返回 `{ "EXIF": {make,model,...}, "GPS": {lat,lng}, "File": {...} }`。API<Q 或流打开失败返回 `emptyMap()`（不抛错）。移植自 aves `MetadataFetchHandler` + photo_manager `IDBUtils.getExif`。 |  |  |
| TASK-104 | **Kotlin channel 路由**：`MediaStorePlugin.kt` `onMethodCall` 的 `when` 块（约行 217-232）加 `"getMetadata" -> handleGetMetadata(call, result)`；新增 `private fun handleGetMetadata(call, result)`：`val id = call.argument<String>("id") ?: 回 InvalidArg`，`ioExecutor.execute { val m = repo.getMetadata(id); mainHandler.post { result.success(m) } }`。 |  |  |
| TASK-105 | **Dart channel 方法**：`mediastore_channel.dart` `MediaStoreChannel` 类加 `Future<Map<String, Map<String,String>>> getMetadata(String id) async`，`invokeMethod<Map>('getMetadata', {'id': id})`，`PlatformException` 转 `MsException`。 |  |  |
| TASK-106 | **Dart UI 增强**：`photo_details_sheet.dart` `_PhotoDetailsSheetState` 加 `Future<Map<String,Map<String,String>>>? _exifFuture`，`initState` 调 `getMetadata(info.id)`。`build` 在现有 `readMeta`（width/height）行之后用 `FutureBuilder` 渲染 EXIF 分组（遍历 Map，每组一个标题 + 若干 `_row`）。空 Map 不渲染该区。 |  |  |
| TASK-107 | **i18n**：`strings_en.dart` / `strings_zh.dart` 加键：`meta_section_exif` / `meta_section_gps` / `meta_make` / `meta_model` / `meta_aperture` / `meta_exposure` / `meta_iso` / `meta_focal` / `meta_date_taken` / `meta_coords` / `meta_orientation`。 |  |  |
| TASK-108 | **许可证登记**：新建 `android/app/NOTICE`（或追加），登记 `metadata-extractor 2.19.0 (Apache-2.0, Drew Noakes)` 与 `AndroidX ExifInterface 1.3.7 (Apache-2.0, The Android Open Source Project)`。 |  |  |

### Implementation Phase 2 — P1a 回收站

- **GOAL-002**：支持把图片移入系统回收站、恢复、以及查看回收站。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-201 | **Kotlin 模型扩展**：`MediaStoreModels.kt` `MsImageInfo` 加 `val isTrashed: Boolean = false`（默认 false 保兼容）+ `toMap()` 加 `"isTrashed" to isTrashed`。`MsError` 加 `object TrashUnsupported : MsError("TRASH_UNSUPPORTED", "回收站需要 Android 10+")` 与 `object RestoreCancelled : MsError("RESTORE_CANCELLED", "用户取消恢复")`。 |  |  |
| TASK-202 | **Kotlin 投影 + 查询**：`MediaStoreRepository.kt` `scanImages` 的 `projection`（约行 142-150）加 `MediaStore.Images.Media.IS_TRASHED`（API R+；用反射或 `if (BuildSdk >= R)` 守卫避免低版本常量不存在）；循环解析处（约行 216-228）取 `isTrashed = idxTrashed>=0 && cursor.getInt(idxTrashed)==1`，传入 `MsImageInfo(...,isTrashed)`。`selection` 默认排除回收站：R+ 用 `Bundle` 查询参数 `QUERY_ARG_MATCH_TRASHED = MATCH_EXCLUDE`（注意 ContentResolver.query 的 Bundle 重载），<R 不加条件。移植自 photo_manager `IDBUtils.logQuery(includeTrashed)`。 |  |  |
| TASK-203 | **Kotlin trash/restore 方法**：`MediaStoreRepository.kt` 新增 `fun requestTrash(ids): IntentSender?` 与 `fun requestRestore(ids): IntentSender?`。实现：`uris = ids.map { ContentUris.withAppendedId(EXTERNAL_CONTENT_URI, it.toLong()) }`；R+ 用 `MediaStore.createTrashRequest(contentResolver, uris, true/false).intentSender`；Q 用同名 API；<Q 返回 null（无回收站概念，按现状直接删）。移植自 photo_manager `PhotoManagerDeleteManager.moveToTrashInApi30/restoreFromTrashInApi30`。 |  |  |
| TASK-204 | **Kotlin plugin 路由 + 回调**：`MediaStorePlugin.kt` 加常量 `REQUEST_TRASH=0x5452` / `REQUEST_RESTORE=0x5253`；加 `pendingTrashResult: Result?` / `pendingRestoreResult: Result?` 字段；`onMethodCall` 加 `"requestTrash" -> handleRequestTrash(call,result)` / `"requestRestore" -> handleRequestRestore(call,result)`（仿 `handleRequestDelete`：取 IntentSender→`pendingXxxResult=result`→`startIntentSenderForResult(intentSender, REQUEST_TRASH/RESTORE, null,0,0,0)`）；`onActivityResult` 的 `when` 加 `REQUEST_TRASH`/`REQUEST_RESTORE` 分支（OK→`pending.success(count)`，否则→`error(RestoreCancelled)`）。 |  |  |
| TASK-205 | **Dart channel**：`mediastore_channel.dart` `MsImageInfo` 加 `isTrashed` 字段 + `fromMap` 解析；`MediaStoreChannel` 加 `Future<int> requestTrash(List<String> ids)` / `Future<int> requestRestore(List<String> ids)`（仿 `requestDelete`，捕获 `MsDeleteCancelledException` 类型的取消）。 |  |  |
| TASK-206 | **回收站查询**：`MediaStoreRepository.kt` 新增 `fun scanTrashed(bucketIds, afterCursor, limit, sortBy, asc): ScanPage`——复用 `scanImages` 逻辑但 `QUERY_ARG_MATCH_TRASHED=MATCH_INCLUDE` 且 selection 加 `IS_TRASHED=1`。Dart channel 加 `scanTrashed(...)`；plugin 路由加 `"scanTrashed"`。 |  |  |
| TASK-207 | **UI — 回收站入口与视图**：`gallery_screen.dart` 顶部加「回收站」入口（仅在 API≥Q 显示）。新建 `trash_screen.dart`（复用 `album_screen` 的网格 + `MediaStoreChannel.scanTrashed`）：每张图长按/菜单 →「恢复」。`router.dart` 加 `/trash` 路由。`GalleryController` 加 `loadTrashed()`。 |  |  |
| TASK-208 | **UI — album 内移入回收站**：`album_screen.dart` 删除流程旁加「移到回收站」选项（API≥Q）；复用现有删除按钮的 confirm 流。`GalleryController.deletePhoto` 同构新增 `trashPhoto(id)`：调 `requestTrash` + 本地移除 + `evictImageCache`。 |  |  |
| TASK-209 | **i18n**：加键 `trash_title` / `trash_empty` / `action_trash` / `action_restore` / `confirm_trash` / `trash_unsupported`（en/zh 双份）。 |  |  |

### Implementation Phase 3 — P1b 收藏

- **GOAL-003**：支持收藏/取消收藏，及查看收藏相册。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-301 | **Kotlin 模型 + 投影**：`MediaStoreModels.kt` `MsImageInfo` 加 `val isFavorite: Boolean = false` + toMap。`MsError` 加 `object FavoriteUnsupported : MsError("FAVORITE_UNSUPPORTED","收藏需要 Android 10+")` 与 `object FavoriteCancelled : MsError("FAVORITE_CANCELLED","用户取消")`。`MediaStoreRepository.kt` `scanImages` projection 加 `IS_FAVORITE`（R+ 守卫），解析处取 `isFavorite`。移植自 photo_manager 投影 `IS_FAVORITE`。 |  |  |
| TASK-302 | **Kotlin 收藏方法**：`MediaStoreRepository.kt` 新增 `fun requestFavorite(ids: List<String>, favorite: Boolean): IntentSender?`：R+ `MediaStore.createFavoriteRequest(contentResolver, uris, favorite).intentSender`；<R 返回 null。移植自 photo_manager `PhotoManagerFavoriteManager.favoriteAsset`。 |  |  |
| TASK-303 | **Kotlin plugin**：`MediaStorePlugin.kt` 加 `REQUEST_FAVORITE=0x4641` + `pendingFavoriteResult` + `pendingFavoriteIds/favoriteFlag`；`onMethodCall` 加 `"requestFavorite" -> handleRequestFavorite(call,result)`；`onActivityResult` 加 `REQUEST_FAVORITE` 分支（OK→对每图 `update IS_FAVORITE` 或直接 success；取消→`FavoriteCancelled`）。 |  |  |
| TASK-304 | **Dart channel + controller**：`mediastore_channel.dart` `MsImageInfo` 加 `isFavorite`；`MediaStoreChannel` 加 `Future<int> requestFavorite(List<String> ids, bool favorite)`。`gallery_controller.dart` 加 `toggleFavorite(MsImageInfo)`：调 channel + 本地翻转 `isFavorite`（乐观更新，失败回滚）。 |  |  |
| TASK-305 | **UI — 收藏交互**：`photo_details_sheet.dart` 或 `photo_viewer.dart` 顶部加心形按钮（`widget.info.isFavorite` 决定填充/描边），点击 `toggleFavorite`。`gallery_screen.dart` 加「收藏」虚拟入口 → 复用 album 网格 + selection `IS_FAVORITE=1` 查询（新增 `scanFavorites` 通道方法或 scanImages 加 filter 参数）。 |  |  |
| TASK-306 | **i18n**：加键 `favorites_title` / `favorites_empty` / `action_favorite` / `action_unfavorite` / `favorite_unsupported`（en/zh）。 |  |  |

### Implementation Phase 4 — P1c ContentObserver 增量化

- **GOAL-004**：把 EventChannel 的裸 `"changed"` 字符串升级为结构化事件，`GalleryController` 精准增量更新而非全量 reload。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-401 | **Kotlin observer 取 uri**：`MediaStorePlugin.kt` 行 104-107 的 `ContentObserver` 改 `override fun onChange(selfChange: Boolean, uri: Uri?)`（API 16+ 有此重载），把 `uri` 传入 `streamHandler.notifyChanged(uri)`。 |  |  |
| TASK-402 | **Kotlin 事件分类**：`MediaChangeStreamHandler.notifyChanged(uri: Uri?)`：保留 300ms 防抖逻辑；防抖触发时：① `uri==null` → 推 `{"type":"refresh"}`（全量刷新，兼容旧语义）；② `uri.lastPathSegment` 是数字 id → 查该行，**查不到→delete**；**查到且 `now - DATE_ADDED < 30s`→insert**；**否则→update**。构造 `{"type":"insert"/"update"/"delete", "id":id, "bucketId":bucketId}` 经 `sink.success(map)`。移植自 photo_manager `PhotoManagerNotifyChannel.onChange` 启发式（含 `safeQuery`/`isVolumeNotFound` 降级）。 |  |  |
| TASK-403 | **Dart 事件模型**：`mediastore_events.dart` 新增 `enum MsChangeType { refresh, insert, update, delete }` + `class MsChangeEvent { final MsChangeType type; final String? id; final String? bucketId; }`；`mediaStoreChanges()` 返回 `Stream<MsChangeEvent>`（`receiveBroadcastStream().map` 解析 Map→`MsChangeEvent`，解析失败降级为 `MsChangeEvent(MsChangeType.refresh)`）。保留向后兼容：旧的 `"changed"` 字符串也映射为 `refresh`。 |  |  |
| TASK-404 | **Controller 增量处理**：`gallery_controller.dart` 的 observer 订阅回调按 `event.type` 分支：`refresh`→现有全量 reload（fallback）；`insert/update`→若 `event.bucketId` 在当前列表则重载该 bucket 计数/封面（或按 id 局部更新）；`delete`→从当前 images 列表移除该 id + 所在 bucket count--（复用 `deletePhoto` 的本地移除逻辑）。**保留全量 reload 作为兜底**（type 未知或 bucket 不在缓存）。 |  |  |
| TASK-405 | **测试**：`test/gallery_controller_test.dart` 加用例：注入 `_FakeMediaStoreChannel` + 假 `mediaStoreChangeStreamProvider` override 推 `MsChangeEvent`，断言 delete 事件触发本地移除、insert 触发 reload、refresh 触发全量。 |  |  |

---

## 3. Alternatives

- **ALT-001**：直接依赖 `photo_manager` 整包 —— 否决。会破坏「自建轻量 channel + 双数据通路（分类/相册分离）」设计，拖入 Glide 重依赖，且与 `ImageRef`/`MsImageInfo` 双模型冲突。采用摘抄式移植。
- **ALT-002**：视频元数据用 `mp4parser`（aves 方案）—— 否决（P0 范围）。mp4parser 是 LGPL-3.0，静态打包进 APK 有动态链接/替换义务，法务风险。P0 仅做图片 EXIF；视频元数据留待 P4，届时用 `MediaMetadataRetriever`（系统 API，零依赖）规避。
- **ALT-003**：回收站自建本地 SQLite 表跟踪 —— 否决。Android 10+ 已有系统回收站（`createTrashRequest` + `IS_TRASHED`），无需自建；自建反而与系统相册状态不一致。
- **ALT-004**：ContentObserver 增量化用 aves 的 generation API（`MediaStore.getGeneration`）—— 暂缓。generation API 复杂度高且需维护 known-set，P1c 先做简单的 uri→insert/update/delete 分类启发式（photo_manager 方案），generation 增量留待后续性能优化。

---

## 4. Dependencies

- **DEP-001**：`androidx.exifinterface:exifinterface:1.3.7`（Apache-2.0）— P0 EXIF 读取。Gradle `implementation`。
- **DEP-002**：`com.drew:metadata-extractor:2.19.0`（Apache-2.0）— P0 兜底元数据（IPTC/XMP 等）。
- **DEP-003**：无新增 Dart 依赖——所有改动复用现有 Riverpod / MethodChannel / EventChannel。
- **DEP-004**（合规）：新建 `android/app/NOTICE` 登记 DEP-001/002；移植 photo_manager / aves 的 Kotlin 片段须在文件头加 `// Ported from fluttercandies/flutter_photo_manager (Apache-2.0, Copyright 2018 The FlutterCandies author)` 或 `// Inspired by deckers/aves (BSD-3-Clause, Copyright (c) Thibault Deckers)` 注释。

---

## 5. Files

**Kotlin（`android/app/src/main/kotlin/com/visort/visort_flutter/mediastore/`）**：
- `MediaStoreModels.kt` — `MsImageInfo` 加 `isTrashed/isFavorite`；`MsError` 加 5 个错误类型。
- `MediaStoreRepository.kt` — `scanImages` 投影 + selection（trashed 排除）；新增 `getMetadata`/`requestTrash`/`requestRestore`/`requestFavorite`/`scanTrashed`。
- `MediaStorePlugin.kt` — `onMethodCall` 加 5 个 case；`onActivityResult` 加 3 个 requestCode 分支；`ContentObserver.onChange` 取 uri；`MediaChangeStreamHandler.notifyChanged` 分类。

**Dart（`visort_flutter/lib/`）**：
- `core/fs/mediastore_channel.dart` — `MsImageInfo` 加字段；`MediaStoreChannel` 加 `getMetadata`/`requestTrash`/`requestRestore`/`requestFavorite`/`scanTrashed`。
- `core/fs/mediastore_events.dart` — `MsChangeType`/`MsChangeEvent`；`mediaStoreChanges()` 返回 `Stream<MsChangeEvent>`。
- `features/gallery/gallery_controller.dart` — `toggleFavorite`/`trashPhoto`/`loadTrashed`；observer 增量分支。
- `ui/screens/photo_details_sheet.dart` — EXIF 分组渲染 + 收藏按钮。
- `ui/screens/gallery_screen.dart` — 回收站/收藏入口。
- `ui/screens/trash_screen.dart`（新）— 回收站视图。
- `ui/router.dart` — `/trash` 路由。
- `core/i18n/strings_en.dart` / `strings_zh.dart` — 新增 ~25 个键。

**构建/合规**：
- `android/app/build.gradle.kts` — 2 个依赖。
- `android/app/NOTICE`（新）— 第三方许可证登记。

---

## 6. Testing

- **TEST-001**：`flutter analyze` 零 error（每个 phase 后跑）。
- **TEST-002**：`flutter test` 全过（现有 52 用例无回归）。
- **TEST-003**（P1c）：`gallery_controller_test.dart` 新增 ≥3 用例（insert/update/delete 事件分支 + refresh 兜底）。
- **TEST-004**（手测，真机 OnePlus PJZ110 / Android 16）：
  - P0：打开一张带 EXIF 的照片详情，确认显示相机型号/光圈/GPS；无 EXIF 的图不崩。
  - P1a：相册内移入回收站→系统弹窗确认→图消失；回收站视图可见→恢复→原图回。
  - P1b：详情页收藏→收藏视图可见；取消→消失。
  - P1c：他 app 拍新照→本 app 相册自动出现新图（insert）；删图→自动消失（delete）。
- **TEST-005**：低版本守卫——模拟器 API 28 验证 trash/favorite/metadata 返回 unsupported 而非崩溃（若无 API28 设备，至少代码审查 `Build.VERSION` 守卫完备）。

---

## 7. Risks & Assumptions

- **RISK-001**：`metadata-extractor` 对 HEIC/RAW（.cr2/.nef/.arw/.dng）支持不全——可能返回部分 EXIF。缓解：先 ExifInterface 兜底，解析失败返回已有字段，不报错。
- **RISK-002**：`scanImages` 投影加 `IS_TRASHED/IS_FAVORITE` 在 API<Q 设备上常量不存在导致 `NoClassDefFoundError`。缓解：用 `Build.VERSION.SDK_INT >= R` 守卫或反射取列名字符串（`"is_trashed"`/`"is_favorite"`），低版本投影不加该列、解析时 `getColumnIndex` 返回 -1 当 false。
- **RISK-003**：部分 OEM ROM（MIUI/ColorOS）的 `IS_FAVORITE`/回收站行为有差异。缓解：手测覆盖目标机型；失败时降级为 unsupported（参考现有 `GalleryController.deletePhoto` 重检 `exists()` 的防御性 ROM workaround 惯例）。
- **RISK-004**：ContentObserver 分类启发式（DATE_ADDED<30s 判 insert）在时钟漂移或批量导入时可能误判。缓解：误判仅影响刷新粒度（update vs insert），最终一致性由用户滚动触发的全量查询保证；保留 `refresh` 全量兜底。
- **ASSUMPTION-001**：目标真机 Android 16（API 36），P0/P1 全部特性可用；最低支持 API 26（项目 minSdk），低版本优雅降级。
- **ASSUMPTION-002**：`MANAGE_MEDIA` 特殊权限路径（现有删除/移动已有）同样适用于 trash/favorite 的零弹窗优化——可作为 P1 后续优化，本计划先用标准 createXxxRequest 弹窗路径。

---

## 8. Related Specifications / Further Reading

- 调研报告：[`docs/GALLERY_RESEARCH.md`](GALLERY_RESEARCH.md)
- 架构决策：[`docs/ANDROID_ROADMAP.md`](ANDROID_ROADMAP.md) §7（v2 相册定型）
- 开发指南：[`AGENTS.md`](../AGENTS.md)
- 移植来源（仅参考）：
  - photo_manager `PhotoManagerDeleteManager.kt` / `PhotoManagerFavoriteManager.kt` / `PhotoManagerNotifyChannel.kt` / `IDBUtils.kt`（Apache-2.0）
  - aves `MetadataFetchHandler.kt` / `MediaStoreStreamHandler.kt`（BSD-3-Clause）
