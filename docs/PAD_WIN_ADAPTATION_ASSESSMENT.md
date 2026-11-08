# Pad 布局 + Windows 相册适配 — 调研评估

> 性质：**调研评估文档（未立项）**。2026-11-08 基于三方并行盘点（MediaStore 依赖面 / UI 平台分叉 / xv_site_solo 同构参考）成文。
> 行号基于当日工作区（v1.5.0 发布后，commit 5608377 附近），后续漂移以代码为准。
>
> 两个评估方向：
> 1. **Pad 端**：安卓平板用宽屏（桌面风格）布局 + 已有安卓全部能力（MediaStore 全家桶），数据源零改动；
> 2. **PC 端**：Windows 桌面引入相册体验，相册 = 用户关联的文件夹；Sort 页沿用现有桌面实现（借鉴其布局与部分 API）。

---

## 0. 一句话结论

- **Pad 端：低-中成本（~2 周量级）**——纯 UI 活，数据层零改动；`xv_site_solo/mobile` 已把同构壳的宽屏分支做完，等于有参考答案。
- **PC 端：中-高成本（全量 4~6 周；砍 places/geocode 可压到 ~3 周）**——贵的不是"适配 API"，而是 favorites/trash/places 三个**无系统等价物、需重设计语义**的能力；主战场是用纯 Dart 重写 Kotlin `MediaStoreRepository`（2402 行）为"文件夹关联库"。
- 两端共享「宽屏断点 + 网格自适应 + 弹层宽屏化」的 UI 地基，**先 Pad 后 PC 可摊薄约一半 UI 工作**。

---

## 1. 现状基线

### 1.1 已就位、可直接复用的桌面基础

| 资产 | 位置 | 说明 |
|---|---|---|
| SQLite ffi 分叉 | `core/db/database_service.dart:51` | Windows/Linux → `databaseFactoryFfi` + `sqlite3_flutter_libs`；打开失败降级 `_db=null` 全 store noop（红线已测） |
| 5 个 sqflite store | `core/db/`（hdr_cache 77 行 / gallery_snapshot 148 / run_log 120 / search_index 156 / session_store 286） | 全部只 import sqflite、构造注入 `Future<Database?>`，**纯 Dart 零改动可复用** |
| Windows 解码分支 | `core/fs/image_loader.dart:33`（全图）/ `:893`（缩略图） | 非 Android → `FileImage` + `ResizeImage`；所有 evict 函数桌面为安全 no-op |
| 桌面 FS 仓储 | `core/fs/desktop_file_system.dart` | move/moveBatch 含冲突改名 `_1`/`_2`、跨盘 copy+delete 回退 |
| session id 双语义 | `core/db/database_service.dart:190` | `image_id` 桌面=相对路径 / Android=MediaStore `_ID`，注释早已预留 |
| 壁纸裁剪页 | `ui/ente_viewer/wallpaper_crop_page.dart`（600 行） | 纯 Flutter Canvas→PNG，原生侧仅差 `setWallpaper` 传输 |
| GalleryController 状态机 | `features/gallery/gallery_controller.dart`（1629 行） | 详见 §2.2，绝大部分纯 Dart |
| Windows runner | `windows/runner/*.cpp` | 原版模板零自定义——无任何 channel 注册（这也是 PC 端全部 MissingPluginException 的根源） |

### 1.2 平台耦合面（Android 专属，Windows 无实现）

耦合集中在 **4 条 channel + 1 个 Kotlin 仓库**，全部注册于 `MainActivity.kt:54-81`：

| Channel | Dart 客户端 | Kotlin 实现 | Windows 等价 |
|---|---|---|---|
| `visort/mediastore`（~38 方法，971 行客户端） | `core/fs/mediastore_channel.dart` | `mediastore/MediaStoreRepository.kt`（2402 行）+ `MediaStorePlugin.kt` | ❌ 无 → 本文主战场 |
| `visort/mediastore-events` | `core/fs/mediastore_events.dart` | ContentObserver 300ms 防抖 → 事件分类（Plugin.kt:1480-1577） | ❌ → `DirectoryWatcher` |
| `visort/wallpaper` | `core/fs/wallpaper_channel.dart`（53 行，1 方法） | `WallpaperManager.setStream` | 🔨 `SPI_SETDESKWALLPAPER`（锁屏无 API，UI 收敛单选项） |
| `visort/share` | `core/fs/share_channel.dart`（46 行） | ACTION_SEND/MULTIPLE（143 行） | 🔨 `share_plus` 或砍（调用点仅 `detail_page.dart:1706` 一处） |
| `visort/app` | 内联于 MainActivity:67-80 | `moveTaskToBack` / `reassertSystemUiFlags` | 不需要（window_manager 已有窗口管理） |

### 1.3 UI 层平台分叉现状

| 事实 | 引用 |
|---|---|
| Shell 是「自绘左抽屉 + 惰性 IndexedStack」，**不是** BottomNavigationBar；抽屉宽 66% clamp 250-340 | `ui/screens/app_shell_android.dart:219`（826 行） |
| 相册链网格列数全部是**持久化固定值**（默认 4，步进 3-5），无宽度断点 | `gallery_screen.dart:443`、`album_screen.dart:246`、`models.dart:262`、`ViewOptionsToggle` :588 |
| `ResponsiveBuilder`（17 行）只有桌面两处在用（home >900 / sort >800），相册链零断点 | `home_screen.dart:333`、`sort_screen.dart:63` |
| `ente_viewer` 29 文件 11.4k 行，**无任何宽屏适配**；filmstrip 常量按手机竖屏调校 | `filmstrip.dart:18/71` |
| 桌面版（home 842 行 / sort 487 行）**无相册入口**；`WindowsKeyboardHandler`（129 行）平台无关但仅桌面 sort 在用，安卓无键盘处理 | `router.dart:108` 注释明示相册链仅安卓注册 |
| 安卓专属代码合计 **~24.5k 行**（shell+*_android ~3.9k / 相册链 screens ~4.3k / gallery_controller 1.6k / ente_viewer 11.4k / 安卓弹层 ~1.6k / core/fs 安卓侧 ~1.6k） | 盘点统计 |

### 1.4 Windows 上直接 push `/album` 的连环失败（为什么不能"先跑起来看看"）

1. 路由层不崩（`router_android.dart:82` 正常生成 `AlbumScreen`），随后 `galleryControllerProvider` → `MediaStoreChannel` → **MissingPluginException**；
2. 缩略图：`imageRefFromMediaStoreId` 的 `content://media/...` authority 在 Windows 分支拼成非法路径 → **全部图片加载失败**（`image_loader.dart:910-913`）；
3. viewer 的 share/wallpaper/`visort/app` 同样无 handler；
4. `fs_provider` 在 Windows 返回 `DesktopFileSystem`——目录树语义，无 bucket/trash/favorite 概念。

---

## 2. MediaStore 依赖面盘点（PC 端成本核心）

### 2.1 Channel 方法 → Windows 等价性总表

| 能力组 | 方法（`mediastore_channel.dart`） | Android API | Windows 等价性 |
|---|---|---|---|
| 权限 | hasPermission / requestPermission / openAppSettings / requestAccessMediaLocation / hasManageMedia / requestManageMedia | READ_MEDIA_IMAGES / MANAGE_MEDIA 链 | **整链消失**（文件夹自选无需权限；MANAGE_MEDIA/位置权限语义不存在） |
| 枚举分页 | listBuckets :344 / scanImages :366（keyset 游标 `"sortValue\|id"`） | ContentResolver.query + QUERY_ARG_SQL_SELECTION | 🔨 **需新实现，语义清晰**：bucket=文件夹、dart:io 遍历 + SQLite 元数据表；keyset 分页逻辑（Dart 侧）可原样保留 |
| 元数据 | readMeta :451 / getMetadata :524 / existsStatus :817 | ContentResolver query / ExifInterface + metadata-extractor 兜底 | 🔨 `os.stat` 已有；EXIF → Dart exif 包 |
| 搜索索引源 | indexSearchMeta :473（DateTimeOriginal/GPS/Make/Model 单 pass）/ geocodePlaces :502（Geocoder + 0.02° 网格缓存） | androidx ExifInterface / android.location.Geocoder | 🔨 EXIF→Dart 包；**geocode 无等价需重设计**（HTTP 反地理编码或砍） |
| HDR | detectHdrs :436 / isHdrJpeg（读 64KB 文件头找 XMP `hdrgm:Version`） | 纯字节解析 | ✅ 语义清晰，直接改写为 Dart |
| 读取 | readBytes :589 / readThumbnail :606 / readSampledImage :630 / readSampledJpeg :655 | openInputStream / loadThumbnail+EXIF 快路径+磁盘缓存 / BitmapFactory inSampleSize+转正 | ✅ **现有分支已覆盖**：FileImage+ResizeImage（`image_loader.dart`）；磁盘缩略图缓存可选重做；EXIF 转正注意桌面解码是否有等价（增强项） |
| 变更操作 | requestFavorite :540 / requestTrash :557 / requestRestore :573 / requestDelete :840 / requestMove :896 / requestRename :916 / requestCopy :947 / nameExists :932 | `createXxxRequest` 系统弹窗 + ContentResolver.update | ⚠️ **弹窗语义全部消失**：move/rename/copy 反而更简单（dart:io 直做，desktop_file_system 已有）；**favorite/trash/restore/delete 需重设计**（见 §2.3） |
| 缓存/预取 | precacheFullImage :691 / fullCacheStats :796 / setFullCacheQuota :721 / schedulePrecacheWork :764（WorkManager）/ imageCacheBytes :747 等 | app 私有目录 LRU 磁盘缓存 + PrecacheWorker | 🔨 缓存本体 dart:io 可复刻；WorkManager → 应用内 idle 调度（`idle_precache.dart` 本就是 Dart 实现） |
| 杂项 | totalRamMb :675 | ActivityManager.MemoryInfo | 不需要（Dart 侧 null 已安全降级，桌面用固定阈值） |

`MsImageInfo`（13 字段：id/name/size/mime/bucketId/dateAddedMs/dateModifiedMs/isFavorite/isTrashed/dateTrashedMs/width/height/isHdr）在 Windows 侧的映射：**id=相对路径**、bucketId=文件夹路径、isFavorite/isTrashed 改由本地元数据表支撑。

### 2.2 GalleryController：绝大部分白拿

1629 行中纯 Dart 可复用：`_loadToken` 竞态守卫 :272、桶快照 LRU+落盘 :594、HDR 三级流水（SQLite→分批 detect→回填）:516、桶 count/封面本地 delta :938/:1406、**乐观收藏+回滚** :857/:1219、收藏时间 SP 记录 :1267、**observer 防抖 400ms/自变异静默窗 600ms/pending 事件** :1442、撤回二分插回 :831、`_cancelKeyOrRaw` :1012。

平台相关仅两类：① channel 调用点本身（约 20 处，集中在 `mediaStoreChannelProvider` 注入）；② `MsImageInfo.id`=_ID 约定（换相对路径即可，见 §1.1 双语义预留）。

> **前置改造（便宜且必要）**：把 `MediaStoreChannel` 抽成接口。测试 `_FakeMediaStoreChannel extends MediaStoreChannel`（`gallery_controller_test.dart`）已证明注入 seam 现成——抽接口后 Windows 侧实现 `DesktopLibraryChannel` 即可，`GalleryController` 一行不改。

### 2.3 三个"无等价需重设计"点

| 能力 | Android 现状 | Windows 方案建议 |
|---|---|---|
| **收藏** | MediaStore `IS_FAVORITE` 列 + `createFavoriteRequest` 弹窗；收藏时刻存 SP（`visort_fav_times`）撑 dateFavorited 排序 | **本地 sqflite 表**（同 hdr_cache 模式）：`favorite(id, favAtMs)`；排序/乐观更新/SP 时间线逻辑全部白拿 |
| **回收站** | `IS_TRASHED` + `DATE_EXPIRES` 30 天 + `createTrashRequest` 弹窗；Run 流程的删除也走 trash（`android_mediastore_file_system.dart:174`） | 推荐 **`.trash` 隐藏目录**（免 FFI、纯 Dart 可测、恢复=move 回原位）；备选 Win32 `IFileOperation` 真系统回收站（工作量同级、语义更贴系统，需 FFI/插件）。牵涉面：`desktop_file_system.dart:163`（现 os.remove 真删）+ 仓储接口补 restore + `GalleryController` trash 视图状态机（可复用）+ `search_data_store.dart:150` 对账口径排除 trash 目录 |
| **places/反地理编码** | GPS（EXIF）→ `Geocoder` → country/adminArea/locality 三元组，搜索 7 维度之一 | 首版**砍**（搜索少一个维度不伤结构）；二期若要，接 HTTP 反地理编码服务（联网+服务商选型） |

明确不还债清单：锁屏壁纸（无 API）、WorkManager 后台预取（应用内 idle 替代）、MANAGE_MEDIA/ACCESS_MEDIA_LOCATION 权限链（消失）、`visort/app` 通道（不需要）。

---

## 3. Pad 端改动清单（方向 1）

| # | 改动点 | 内容 | 量级 |
|---|---|---|---|
| A1 | Shell 双形态 | `app_shell_android.dart` 宽屏 fork：常驻侧栏（NavigationRail 形态）+ 画布。**可复用**：页面注册表 `_pageWidget`/`_items`（数据驱动）、`ShellHandle` 契约、惰性 IndexedStack+预热、默认首页配置；**要 fork**：Transform 推拉 Stack（:363-482）、`DrawerSwipeWrapper`、`_SidebarMorphPainter`、66% 宽度数学 | 3~5 天 |
| A2 | 网格列数自适应 | 列数改宽度映射（手机 3-5 → Pad 6-10）；`ViewOptionsToggle.gridColumnsMax` 放开；`models.dart` 持久化 int 需加「auto」语义或宽度档位 | 1~2 天 |
| A3 | 弹层宽屏观感 | `confirm_sheet`（硬编码左右 24 边距+手势条 inset）、`photo_details_sheet`（DraggableScrollableSheet）、`spring_popup` 在宽屏的位置复核 | 2~3 天 |
| A4 | viewer | Pad 是**触摸设备**——长按/双击/上滑详情/PageView 天然可用；真正要动的只有 filmstrip 竖屏常量与 viewer 网格列数 | 2~3 天 |
| A5 | 路由 fork 细化 | `router.dart:82` 的 `Platform.isAndroid` 需细化「手机 vs 平板」（最短边阈值或 device 类别），否则 Pad 永远拿手机 Shell | 0.5 天 |
| A6 | 断点收口 | 现有 >900/>800 两处桌面断点 + 新 Pad 断点统一为 token（见 §5 xvsolo 模式） | 0.5 天 |

数据源、channel、store、解码管线**全部零改动**（MediaStore 照用）。

---

## 4. PC 端实施拆解（方向 2）

### 4.1 架构：MediaStore 替身 = 「文件夹关联库」

```
GalleryController（不动，注入接口化 channel）
        │
DesktopLibraryChannel（新，纯 Dart）
        ├─ dart:io 目录遍历（关联文件夹 → bucket=子文件夹 or 每个关联根=相册，待定）
        ├─ SQLite 元数据表（id=相对路径, mtime, size, w/h, isFavorite, isTrashed, dateTrashed…）
        ├─ EXIF 提取（Dart 包：dateTaken/GPS/相机 → 喂 search_index，替代 indexSearchMeta+geocode）
        ├─ DirectoryWatcher（替代 ContentObserver；事件分类启发式可从 Plugin.kt 移植）
        ├─ 缩略图（现成 ResizeImage(FileImage) 分支；磁盘缓存可选）
        └─ trash = .trash 目录 / favorite = 本地表
```

不需要写任何 C++（Windows runner 保持模板）；全部在 Dart 层完成。

### 4.2 分期建议

- **一期（~2 周）：浏览闭环**。channel 抽接口 → `DesktopLibraryChannel` 扫描/分页/readBytes/exists + 关联文件夹管理 UI（file_picker 已有）→ 相册网格/查看器跑通（配合 Pad 期做好的宽屏断点）。
- **二期（~1 周）：操作与增值**。favorite 本地表 + 乐观链路、`.trash` 回收站语义 + 恢复、HDR 检测（Dart 字节解析）、壁纸（`SPI_SETDESKWALLPAPER`，裁剪页零改动）。
- **三期（可选）：搜索全景**。EXIF→search_index 构建/增量同步（服务状态机白拿，数据源换 Dart EXIF）；places 明确不做。
- UI 桌面化（鼠标 hover/右键/拖框选）**后置迭代**——先以"大屏触摸式"跑（宽屏断点下观感成立），触摸范式交互在桌面鼠标上多数可用（点击代替轻触、双击可用；长按多选需要键盘 Ctrl/Shift 补位，可与 `WindowsKeyboardHandler` 融合）。

### 4.3 与 Sort 页的合并

现有桌面 `home_screen`/`sort_screen`/`review`/`results` 原样保留（冻结不动）；相册体验作为新增入口进入 Windows 端导航（形态待定：双栏 home 加相册区，或直接采用安卓 Shell 的宽屏形态——**建议后者**，与 Pad 共用 A1 的 Shell 双形态成果）。

---

## 5. xv_site_solo 可借鉴模式（同构参考答案）

`~/Dev/Code/xv_site_solo/mobile`（Flutter，pubspec 明写"外观套用 Visort"，shell 从 visort 1:1 移植后演化）已在 手机+平板+Windows+Web 四端真机跑通。可直接搬：

| 模式 | 位置 | 说明 |
|---|---|---|
| **单壳运行时宽窄分叉** | `ui/screens/app_shell.dart`（2281 行）:1520 | 一个 build 内 `width >= kShellWideBreakpoint` 分叉：窄屏=双抽屉壳（visort 同款）/ 宽屏=常驻 RailShell+面包屑+画布 IndexedStack，共用切页逻辑。**对比 visort 的文件级 fork 惯例，这里值得为 shell 破例**（两形态共享状态太多） |
| 唯一断点 token | `core/theme/morrow_tokens.dart:229` | `kShellWideBreakpoint=720` + RailWidth 248/64、gutter/gap/touchTarget 常量族 |
| 画布页位系统 | `core/modules/shell_pages.dart` | 42 个 int 页位 + 惰性位掩码；**宽屏红线：二级页渲染进画布不 push 全屏**（Pad/PC 相册下钻相册→照片链时同样面临） |
| 无参画布页传参 | `knowledge/write_session.dart` 模式 | 会话 StateProvider + 递增 nonce 作 ValueKey 强制重建 |
| 平台闸门探针 | `core/platform/platform_probe.dart` | 条件导出收口一切平台判断（禁散布 dart:io/kIsWeb）；`isTouchPlatform` 解决"hover 才显现的控件在触摸端不可达"——Pad 实测教训 |
| Windows 桌面框 | `shared/widgets/xv_desktop_frame.dart` + `main.dart:31` | frameless 自绘标题栏、三键按宽度分治、灯箱全屏隐藏三键；visort 已有 window_manager 基础 |
| UI 缩放管线 | `app.dart` `_XvZoom`:169-271 | 按有效宽度判断点（浏览器 zoom 心智），可选 |
| 平板安全区 | `app_shell.dart:1579-1700` | 壳层单点 removePadding+注入，内部禁二次 SafeArea |
| 网格列数 helper | `data/article_feed.dart:485` | `maxColumnWidth` 夹紧 2..6；配合每页视图偏好（`taxonomy_view_prefs.dart`：手动钉列/自适应双模式）——A2 直接套 |
| 灯箱/图片 | `xv_image_lightbox.dart` / `xv_image.dart` | InteractiveViewer+双击 2x、DPR 感知下采样（参考，viewer 本体 visort 用自己的 ente_viewer） |

xvsolo **没有**、需 visort 自建：本地 FS 相册浏览（其图片全来自 REST+MinIO URL）、图片多选批操作 UI、交错网格。状态管理同源（手写 provider 无代码生成，riverpod 3 的 legacy import 兼容 StateNotifier），无迁移障碍。

---

## 6. 成本汇总与路线

| 方向 | 量级 | 主要构成 |
|---|---|---|
| Pad（A1-A6） | **~2 周** | Shell 双形态 3-5d + 网格 1-2d + 弹层 2-3d + viewer 2-3d + 路由/断点 1d |
| PC 一期（浏览闭环） | ~2 周 | channel 接口化 + DesktopLibraryChannel 扫描/分页 + 关联文件夹 UI |
| PC 二期（操作增值） | ~1 周 | favorite/trash/HDR/壁纸 |
| PC 三期（搜索，可选） | ~1 周 | EXIF→search_index；places 不做 |
| **PC 全量合计** | **4~6 周**（砍 places 后 ~3 周） | |

**建议顺序**：Pad 先行（A1/A2 产出的 Shell 双形态+断点地基，PC 一期直接复用）→ PC 一期 → 二期 → 视需求决定三期。

**待拍板决策点**（开工前需定）：
1. Windows「相册」的粒度：每个关联文件夹=一个相册，还是关联根下子文件夹各为一册（影响 listBuckets 语义与 UI 层级）；
2. trash 方案：`.trash` 目录（推荐） vs Win32 IFileOperation；
3. Windows 端导航形态：沿用宽屏 Shell 双形态（推荐，与 Pad 共用） vs 现有桌面 home 里加入口；
4. Pad 断点阈值与"平板判定"标准（xvsolo 用 720 最短边，visort 现有桌面 800/900 两处需统一）。
