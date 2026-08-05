# VISORT 安卓开发路线图

> 本文档记录安卓端 MVP 开发的全部决策共识。基于 Windows 端（W1–W7 已交付）的共享业务逻辑，
> 为安卓端 A0–A4 里程碑提供基准。每条决策均经过 grill-me 对齐流程确认。
>
> 最近对齐日期：2026-07-28

---

## 0. 现状基线

### 已存在（commit d9c67c0 交付）

| 资产 | 位置 | 说明 |
|---|---|---|
| 共享业务逻辑 | `lib/core/config/`、`lib/core/fs/file_system_repository.dart` | Profile 模型、`profiles_service`、`FileSystemRepository` 抽象 |
| 桌面 FS 实现 | `lib/core/fs/desktop_file_system.dart` | Windows 端在用（dart:io + file_picker） |
| 安卓 FS 骨架 | `lib/core/fs/android_saf_file_system.dart` | 全方法抛 `UnimplementedError`，文件头已写明技术路线 |
| 平台分发 | `lib/core/fs/fs_provider.dart` | `Platform.isAndroid` 已分叉 |
| 状态机 | `lib/features/session/session_controller.dart` | `decide(action)` / `undo()` / `run()` |
| i18n | `lib/core/i18n/` | 94 键 en/zh，纯 Dart 字典，平台无关 |
| 主题 | `lib/core/theme/` | app_colors / app_theme / noise_overlay，平台无关 |
| 控制器 | `lib/features/{scan,review,run,setup}/` | 与平台无关 |
| 单测 | `test/` | 44 测试全过，均针对桌面 FS 与纯 Dart 逻辑 |
| 安卓壳工程 | `android/` | 标准 Flutter 生成，`MainActivity.kt` 仅 5 行模板 |

### 当前缺口

1. **`AndroidSafFileSystem` 全部 `UnimplementedError`**——无任何实质实现
2. **`AndroidManifest.xml` 零权限声明**——但纯 SAF 模式下确实零权限需要
3. **`pubspec.yaml` 零安卓相关依赖**——`file_picker ^8.1.0` 在安卓上有持久化缺陷，不用于目录选择
4. **`MainActivity.kt` 无 MethodChannel 注册**
5. **`main.dart` 的 `window_manager` 初始化仅靠 try/catch 静默吞错**——安卓端是死代码路径
6. **`applicationId` 为 `com.visort.visort_flutter`**——不规范，待重命名

---

## 1. MVP 范围与定位

**目标**：在安卓真机上跑通核心整理闭环——
**选目录 → 逐张决策（全屏单图 + 底部目标按钮）→ 移动到目标子文件夹 → 查看结果**

**非目标**（明确排除）：
- ❌ Play Store 上架（不做合规审查、签名发布、隐私声明）
- ❌ Windows 全功能 1:1 复刻（不上自定义快捷键编辑、多 Profile 管理、Profile CRUD）
- ❌ 自动化集成测试（channel 调用靠类型保证，A4 真机手测验收）
- ❌ 缩略图网格预览（保持「一图一决策」的快达心智）

**验收标尺**：作者日常真机可用。

---

## 2. 18 条对齐共识

### 存储 / 文件系统

| # | 决策 | 理由 |
|---|---|---|
| 2 | **目录选择**：自建 MethodChannel 直调 `ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission` | `file_picker` 插件不暴露持久化 API（issue #1825），重启后丢权限；备选 `shared_storage` 已 discontinued |
| 3 | **扫描递归**：原生 `DocumentsContract.buildChildDocumentsUriUsingTree` 递归，`contentResolver.query` 按 MIME `image/*` 过滤 | 避免 `DocumentFile.listFiles()` 性能开销；与 move/delete 共享 contentResolver 上下文 |
| 8 | **目标目录关系**：混合模式。同 tree URI 内走 `renameDocument`（毫秒级）；跨独立授权 tree URI 走 `copy`+`delete`（慢，不保证原子） | 灵活性接受性能代价，Kotlin 侧需 `moveInTree` / `copyAcrossTrees` 两个方法分叉 |
| 9 | **图片加载**：自定义 `ContentUriImageProvider extends ImageProvider`，走 Flutter `imageCache`，解码时 `cacheWidth=screenWidth×2` 下采样 | 不落临时文件、零额外依赖、相机原图 40MB → 解码后 ~6–12MB |
| 10 | **配置存储**：`shared_preferences ^2.2.0`，存 tree URI 字符串 + 单 Profile | 生态最成熟、零额外原生代码、与 `profiles_service` 改造最小 |

### 交互模型

| # | 决策 | 理由 |
|---|---|---|
| 4 | **逐张决策**：全屏单图 + 底部横滑目标按钮列 | 与 Windows 端「一图一键」心智同构（键盘→按钮），`session.decide(action)` 接口零改造复用 |
| 5 | **底部按钮**：横滑按钮列 = Profile folders（从 `profile.folders` 读取） | 数据结构两端 100% 共享，零额外配置 |
| 7 | **Profile 来源**：单 Profile 设计，首次配置后持久化，提供修改入口 | 比「预制多 Profile」更简洁，把 `profiles_service` 复杂度降到「单配置读写」 |
| 6 | **Setup 范围**：最小化——选 Profile + 授权目录 + 开始整理 | 砍掉所有 Profile 编辑能力、action_keys_editor 整体不入安卓流程 |

### 平台配置

| # | 决策 | 理由 |
|---|---|---|
| 11 | **SDK**：minSdk=26 / targetSdk=36 / compileSdk=36 | SAF 在 API 26+ 行为一致、持久化权限可靠、覆盖 ~95% 设备、零上架迁移成本 |
| 12 | **Kotlin 组织**：三层分包 `com.visort.visort_flutter.saf`：`SafPlugin`（MethodChannel 入口）/ `SafRepository`（ContentResolver+DocumentsContract）/ `SafModels`（data class） | 职责清晰、可测、与 Dart 侧 controller/repository 风格对称 |
| 13 | **入口分叉**：`main.dart` 用 `Platform.isXxx` 显式分叉，`window_manager` 归 `isWindows`，安卓分支新增 `setupAndroid()` | 语义明确、依赖按需加载、为 A1 预留据点 |
| 14 | **Manifest**：零权限声明（无 `READ_EXTERNAL_STORAGE` / `MANAGE_EXTERNAL_STORAGE` / `POST_NOTIFICATIONS`）+ `applicationId` 改为 `com.visort.app` | 纯 SAF 零权限摩擦；appId 规范化为将来上架准备 |

### 工程 / 流程

| # | 决策 | 理由 |
|---|---|---|
| 1 | **范围定位**：MVP 核心闭环跑通，不上架 | 所有选型的「够用」标尺 |
| 15 | **测试策略**：仅保现有 44 单测，安卓靠手测 | MVP 范围控制；channel 调用靠类型保证；集成测试留到后续 |
| 16 | **测试设备**：模拟器开发 + 真机验收 | SAF 在模拟器与真机行为一致（都走 framework），迭代效率最高 |
| 17 | **里程碑**：A0–A4 五阶段（见下） | 与骨架注释已有命名对齐 |
| 18 | **文档治本**：解除 `.gitignore` 对 `docs/` 的忽略，本文档入库 | 避免下次裸奔（d9c67c0 提交信息声称创建了本文档，但实际被 gitignore 吞掉） |

---

## 3. 里程碑 A0–A4

### A0 — SAF PoC（概念验证）

**状态**：✅✅ 全部完成并验证（2026-07-28）

**目标**：验证 SAF 通路可行，跑通最小闭环。

**范围**：
- Kotlin 侧新增 `saf` 包三层骨架
- `SafPlugin` 注册 MethodChannel `visort/saf`，实现 3 个方法：
  - `pickDirectory()` → 启动 `ACTION_OPEN_DOCUMENT_TREE`，调 `takePersistableUriPermission`，返回 tree URI 字符串
  - `scanImages(treeUri)` → `DocumentsContract.buildChildDocumentsUriUsingTree` 递归 + `contentResolver.query` 按 `image/*` 过滤，返回 `List<Map>` （name/docId/size/mime）
  - `persistedUriPermissions` → 列出当前持久化授权，验证重启后保留
- Dart 侧写一个临时 demo 页（不入正式 UI），调 channel 显示扫描结果列表

**验收标准**：
- ✅ 模拟器选目录后能列出该目录下的图片名（纯文本列表即可）
- ✅ 杀进程重启后，`persistedUriPermissions` 仍包含上次授权的 tree URI
- ✅ `flutter analyze` 零错误，44 单测仍全过

**关键风险**：
- SAF 在某些 OEM 定制系统（MIUI/ColorOS）上行为有差异——A4 真机验收时重点关注

### A1 — SAF 完整实现

**状态**：✅✅ 全部完成并验证（2026-07-28）

**目标**：填充 `AndroidSafFileSystem` 全部方法，提供完整 FS 能力。

**范围**：
- Kotlin `SafRepository` 实现全部方法：
  - `scanImages` 完整版（含 size/mtime/recursive 参数）
  - `listSubdirs(parentDocId)`
  - `move(srcDocId, destDirDocId)` —— **分叉**：判断 src 与 dest 是否同 tree URI
    - 同 tree → `DocumentsContract.renameDocument`
    - 跨 tree → `copyDocument` + `deleteDocument`（Kotlin 侧两方法：`moveInTree` / `copyAcrossTrees`）
  - `delete(docId)` → `DocumentsContract.deleteDocument`
  - `exists(docId)` → contentResolver query 探测
  - `readBytes(docId, maxBytes)` → `ContentResolver.openInputStream`
- Dart `AndroidSafFileSystem` 全方法对接 channel，移除所有 `UnimplementedError`
- Dart 新增 `ContentUriImageProvider extends ImageProvider<ContentUriImage>`：
  - `load` 方法调 `readBytes` channel，配合 `PaintingBinding.instance.imageCache`
  - 解码通过 `DecoderCallback` 传 `cacheWidth: screenWidth × 2` 下采样
- 替换 `sort_screen` 里所有 `Image.file()` 调用为 `Image(image: ContentUriImageProvider(ref))`

**验收标准**：
- ✅ Dart 侧 `AndroidSafFileSystem` 无 `UnimplementedError` 残留
- ✅ `flutter analyze` 零错误
- ✅ 现有 44 单测仍全过（无回归）
- ✅ 同 tree URI 内 move 操作 < 50ms（模拟器测）

**关键风险**：
- 跨 tree URI 的 `copyDocument` 在部分 provider 上不可靠——A1 阶段仅保证同 tree，跨 tree 标记为「最佳努力」

### A2 — 交互闭环

**状态**：✅✅ 全部完成并验证（2026-07-28）

**目标**：改造 UI 为安卓触屏交互，跑通完整整理闭环。

**范围**：
- `ui/screens/setup_screen.dart` 改造为安卓版：
  - 移除 Profile 切换 UI、action_keys_editor 入口、folder_editor 入口
  - 保留：单 Profile 显示 + 源目录授权按钮（调 SAF pickDirectory）+ 目标子目录配置 + 「开始整理」按钮
  - 目标子目录配置：列表显示 folder 名（可改名/增删），每个目标可选「父目录下子目录」或「独立授权目录」
- `ui/screens/sort_screen.dart` 改造为安卓版：
  - 移除 `RawKeyboardListener` / `windows_keyboard_handler`
  - 全屏 `Image(image: ContentUriImageProvider(currentRef))`
  - 底部 `SingleChildScrollView(horizontal)` + `Row` 横滑按钮列，每个按钮 → `session.decide(folderId)`
  - 可选手势：左滑=上一张、右滑=跳过（A2 可选，A4 必选）
- `ui/screens/review_screen.dart` / `results_screen.dart`：评估改造量，预计仅需移除键盘提示
- `ui/router.dart`：移除 Windows 专属路由守卫（若有）
- 复用 `session_controller` / `scan_controller` / `run_controller`，零改造

**验收标准**：
- ✅ 模拟器能完成：Setup 选目录 → Sort 逐张点按钮决策 → Review → Results 完整闭环
- ✅ session 状态机 `decide/undo/run` 行为与 Windows 端一致
- ✅ 无 `RawKeyboardListener` 残留调用

### A3 — 配置持久化

**状态**：✅✅ 全部完成并验证（2026-07-28）

**目标**：重启 app 后配置与授权完整保留。

**范围**：
- `pubspec.yaml` 新增 `shared_preferences: ^2.2.0`
- `profiles_service` 改造或新增 `android_config_service.dart`：
  - 读写单 Profile（folder 列表 + 名称）到 shared_preferences
  - 读写 tree URI 字符串映射（folder name → tree URI）到 shared_preferences
- `main.dart` 改造：
  - 用 `if (Platform.isWindows)` 显式包裹 `window_manager` 与 `window_state` 模块
  - 新增 `setupAndroid()`：初始化 shared_preferences、预加载持久化的 tree URI
- 启动时检查 `persistedUriPermissions`，若用户在系统设置里撤销了授权，引导重新授权
- `fs_provider.dart` 改为 async Provider（因 shared_preferences 读取需 async）

**验收标准**：
- ✅ 杀进程重启后，Setup 屏显示上次配置的 Profile 与目录
- ✅ 重启后直接进入 Sort 屏，扫描结果与上次一致（tree URI 仍有效）
- ✅ 手动在系统设置撤销 SAF 授权后，app 能检测并引导重新授权
- ✅ `window_manager` 不再被安卓端 import（用 `dart:io show Platform` 判断）

### A4 — 真机验收

**状态**：✅ MediaStore 重写真机验证通过（2026-07-29，OnePlus PJZ110 / Android 16）

**目标**：真机日常可用。

**范围**：
- 真机（作者日常机型）走完整闭环
- 性能调优：
  - 大图（>20MB）加载是否 OOM
  - 横滑按钮列是否卡顿
  - scanImages 大目录（>1000 张）耗时
- 必选手势：左滑上一张、右滑跳过、下拉撤销
- OEM 兼容性：若作者机型为 MIUI/ColorOS 等，重点测 SAF 行为
- 补 `visort_flutter/README.md` 安卓构建说明
- 更新根 `README.md` 技术栈章节（当前仍写 Flask，需补 Flutter）
- 修复 `applicationId` 为 `com.visort.app`（Kotlin package 路径可选保留 `com.visort.visort_flutter`，Gradle 允许不一致）

**验收标准**：
- ✅ 作者真机连续整理 100+ 张图片无崩溃、无 OOM、无明显卡顿
- ✅ README 含安卓构建/运行说明
- ✅ `flutter analyze` 零错误，44 单测全过

---

## 4. 关键踩坑预警（基于 Windows 端经验 + 安卓特性）

| 坑 | 来源 | 规避 |
|---|---|---|
| `MaterialLocalizations` zh 未注册致 TextField 崩溃 | Windows W2 | 安卓端同样需要 `flutter_localizations` delegate，已引入 |
| 中文字体打包 | Windows W2 | HarmonyOS_Sans_SC 已替换 NotoSansSC（工作区未提交），需确认 pubspec 字体声明一致 |
| Profile 切换需 `copyWith` 强制不可变 | Windows W3 | 单 Profile 设计下风险降低，但 `AppConfig` 仍需保持 final 字段 |
| 编辑器卡顿 | Windows W4 | 安卓 MVP 砍掉编辑器，风险消除 |
| 噪点 overlay 用 RGBA PNG | Windows W5 | 直接复用，平台无关 |
| **SAF 跨 tree move 不可靠** | 安卓特有 | A1 仅保证同 tree，跨 tree 标记「最佳努力」+ 用户反馈失败 |
| **相机原图 OOM** | 安卓特有 | `cacheWidth=screenWidth×2` 下采样，限制 imageCache 上限 |
| **OEM SAF 行为差异**（MIUI 等） | 安卓特有 | A4 真机验收重点 |
| **SAF 持久化授权额度**（512/128） | 安卓特有 | 单 Profile 通常 1–3 个 tree URI，远低于限额 |

---

## 5. 依赖变更清单（A1–A3 期间）

### pubspec.yaml 新增

```yaml
dependencies:
  shared_preferences: ^2.2.0  # A3 引入
  # 注：不引入 file_picker 的安卓 SAF 扩展（issue #1825 未解决）
  # 注：不引入 photo_manager / MediaStore（与「选任意目录」语义不一致）
  # 注：不引入 saf / shared_storage（已 discontinued / 两年未更新）
```

### AndroidManifest.xml 变更

```xml
<!-- 零权限声明，纯 SAF 不需要任何 runtime permission -->
<!-- applicationId 改为 com.visort.app（在 build.gradle.kts 中改） -->
```

### build.gradle.kts 变更

```kotlin
defaultConfig {
    applicationId = "com.visort.app"  // 原 com.visort.visort_flutter
    minSdk = 26                       // 原 flutter.minSdkVersion
    targetSdk = 36                    // 原 flutter.targetSdkVersion
    // compileSdk 跟随 flutter.compileSdkVersion（建议显式锁 36）
}
```

---

## 5.5 架构转向：SAF → MediaStore（2026-07-28，真机实测后修订）

### 转向背景

A4 真机实测（OnePlus PJZ110 / ColorOS / Android 16）暴露了 SAF 方案的根本缺陷：

| 真机相册分布 | 物理路径 | SAF 能否覆盖 |
|---|---|---|
| 飞牛相册 | `TRIM/Download/飞牛相册` | ❌ 需单独授权 TRIM |
| X | `Download/X` | ❌ 需单独授权 Download |
| Camera | `DCIM/Camera` | ✅ 授权 DCIM |
| 桌搭 | `DCIM/MyAlbums/桌搭` | ✅ 同在 DCIM |
| HeyBox | `Pictures/HeyBox` + `DCIM/HeyBox` | ❌ 同名跨目录，SAF 当成 2 个 |

系统相册 App 显示 12-15 个相册，但分散在 4 个不同分区（DCIM/Pictures/Download/TRIM）。SAF 要求用户逐一授权父目录，且无法处理同名相册合并。

**决策：改用 MediaStore.Images.Media（系统相册标准 API）**，与所有主流相册 App 一致。

### 共识修订

| 原共识（SAF） | 新共识（MediaStore） |
|---|---|
| #2 目录选择：自建 SAF channel | MediaStore `bucket_display_name` 分组列出相册 |
| #3 扫描递归：DocumentsContract | MediaStore `contentResolver.query` by bucket |
| #8 目标目录：混合 tree URI | MediaStore `RELATIVE_PATH` 写入 |
| #9 图片加载：ContentUriImageProvider | 复用（MediaStore 也返回 content:// URI） |
| #14 零权限：纯 SAF | **`READ_MEDIA_IMAGES`（Android 13+）+ `createDeleteRequest`（API 30+）** |
| #5 横滑按钮：Profile folders | ✅ 不变 |
| #4 全屏单图 + 底部按钮 | ✅ 不变 |

### MediaStore 关键 API

- **列相册**：`contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, [bucket_display_name], groupBy=bucket_display_name)` → 相册名+数量
- **列图片**：`contentResolver.query(..., selection=bucket_display_name=?)` → 指定相册的图片
- **加载**：content URI 直接给 `Image(image:)`，无需自定义 ImageProvider（但保留 ContentUriImageProvider 做下采样）
- **删除/回收**：`MediaStore.createTrashRequest()` / `createDeleteRequest()`（Android 10+，系统弹窗确认）
- **移动（改相册）**：`contentValues.put(RELATIVE_PATH, "Pictures/新相册名")` + `contentResolver.update(uri, values)`；或 `createWriteRequest`

### 影响

- **A0/A1 的 SAF 代码保留为备选**（不删除，标记 deprecated）——SAF 对"非媒体文件"场景仍有价值
- **新增 `MediaStoreFileSystem implements FileSystemRepository`**
- **Setup 屏改为相册多选列表**（取代 SAF picker）
- **fs_provider 安卓分支改指 MediaStoreFileSystem**
- **AndroidManifest 加 `READ_MEDIA_IMAGES` + 运行时权限请求**

---

## 6. 文档维护约定

- 本文档随每次里程碑完成更新「现状基线」与「里程碑」章节
- 每条共识变更必须记录理由（不删除原条目，标记 `~~旧~~` 并追加新条目）
- A4 完成后，本文档归档为 `docs/ANDROID_ROADMAP_v1.md`，开启 v2（上架版）路线图

---

## 7. v2 架构定型：相册为重点（2026-07-31）

> 安卓版重新定位为 **「相册快速整理 + 现代相册浏览」**——不只是一个分类工具，本身就要是一个流畅美观的相册应用。
> 相册功能成为开发重心，本章节把支撑它的架构决策钉死，作为后续相册迭代的基准。

### 7.1 产品定位修订

| 维度 | v1（A0–A4） | v2（本章起） |
|---|---|---|
| 定位 | 图片分类工具 | **相册应用**（含浏览/整理） |
| 相册浏览 | 仅 setup 内联勾选列表 | 独立的 gallery/album 两级浏览 + 全屏 viewer |
| 实时性 | 快照式（进页面才查） | ContentObserver 实时刷新 |
| 分页 | offset（有错位 bug） | keyset 游标法 |
| 可测试 | 相册逻辑无单测 | GalleryController 8 个单测覆盖 |

### 7.2 双数据通路（正式定调，不再试图统一）

相册与分类是**两条并列的数据通路**，对应不同的领域模型，长期共存：

```
分类流程:  UI → session/run controllers → FileSystemRepository(契约)
             → AndroidMediaStoreFileSystem → MediaStoreChannel → Kotlin
             数据模型: ImageRef(root/relativePath/extension/displayName)
             relativePath = MediaStore _ID（决策字典 key）

相册流程:  UI → GalleryController(Notifier) → MediaStoreChannel 直连 → Kotlin
             数据模型: MsImageInfo(id/name/size/mime/dateAddedMs/dateModifiedMs)
             渲染时由 UI 把 id 包成 ImageRef(imageRefFromMediaStoreId)
```

**不要把相册塞进 `FileSystemRepository`**——该契约的语义是「目录 + 相对路径」，与相册（bucket + _ID）本质不同，硬塞会扭曲契约。相册需要富模型（日期/尺寸/MIME），`ImageRef` 太薄。

### 7.3 v2 共识（19–25）

| # | 决策 | 理由 |
|---|---|---|
| 19 | **分页**：keyset 游标法（`afterCursor` = 上一页末条的 sortValue+\|+id），取代 offset | offset 在删除/新增后会错位（重复或跳过）；keyset 天然免疫，是相册 App 标准做法 |
| 20 | **ContentObserver 实时刷新**：Kotlin 注册 `MediaStore.Images.Media.EXTERNAL_CONTENT_URI` observer，经 EventChannel（`visort/mediastore-events`）推 Dart，300ms 防抖，静默刷新 | 系统相册都是实时的；其他 app 拍新照/删图时本 app 自动更新列表 |
| 21 | **MediaStoreChannel 可注入**：`mediaStoreChannelProvider`（Provider），GalleryController 经 ref.read 取得；测试 override 注入 fake | 解除相册逻辑的测试盲区（v1 相册零单测） |
| 22 | **查询全后台线程**：Kotlin 侧 listBuckets/scanImages/readMeta/exists/getBucketRelativePath 全部走 `ioExecutor`（4 线程池）+ mainHandler 回传 | listBuckets 是全表扫描+内存聚合，上万张时主线程卡 100ms+ 掉帧 |
| 23 | **ImageRef.displayName**：新增可选字段，安卓从 DISPLAY_NAME 带入；UI 统一用 `label` getter（优先 displayName 回退 name） | 安卓下 `name` 取 relativePath 末段 = _ID 数字，不可读；sort 屏顶部/详情需真实文件名 |
| 24 | **类型化错误**：`MsException` + `MsErrorCode` 枚举（与 Kotlin `MsError.code` 对齐），取代通用 Exception 字符串 | UI 可据 code 分支（权限引导 vs 重试） |
| 25 | **PhotoViewer 分页联动**：viewer 接收 `onLoadMore`/`hasMore`，滚动接近末尾（剩 <5 张）触发，新数据经 didUpdateWidget 合并 | v1 viewer 只能看已加载页（每页 60），大相册滑不到底 |

### 7.4 文件结构（v2 现状）

```
visort_flutter/
├─ lib/
│  ├─ core/fs/
│  │  ├─ file_system_repository.dart   # 契约（分类通路）
│  │  ├─ android_mediastore_file_system.dart  # 分类通路实现
│  │  ├─ mediastore_channel.dart       # channel 客户端（双通路共用，可注入）
│  │  ├─ mediastore_events.dart        # [新] ContentObserver EventChannel
│  │  ├─ image_loader.dart             # ImageProvider + 缩略图 provider
│  │  └─ image_ref.dart                # [改] +displayName/label
│  └─ features/gallery/
│     └─ gallery_controller.dart       # [改] channel 注入 + keyset + observer 订阅
│  └─ ui/screens/
│     ├─ gallery_screen.dart           # 相册列表
│     ├─ album_screen.dart             # [改] 相册网格（拆分后仅网格 + 入口）
│     ├─ photo_viewer.dart             # [新] 全屏 viewer（分页联动）
│     ├─ photo_details_sheet.dart      # [新] 详情抽屉
│     └─ album_common.dart             # [新] 共享辅助（extOf/formatSize/...）
└─ android/.../mediastore/
   ├─ MediaStorePlugin.kt              # [改] EventChannel + 全后台线程
   └─ MediaStoreRepository.kt          # [改] keyset 分页 + 修 buildWriteRequest bug
```

### 7.5 v2 已交付清单（2026-07-31）

- ✅ keyset 分页（Dart + Kotlin），修复 offset 删除错位 bug
- ✅ ContentObserver + EventChannel 实时刷新（300ms 防抖，静默）
- ✅ Kotlin 全查询移后台线程
- ✅ MediaStoreChannel 可注入 + `gallery_controller_test.dart`（8 cases）
- ✅ ImageRef.displayName（修安卓显示 _ID 数字）
- ✅ MsException 类型化错误码
- ✅ PhotoViewer 分页联动（大相册一路滑到底）
- ✅ album_screen.dart 拆分（825→3 文件，单一职责）
- ✅ 清理 SAF 死代码（content_uri_image_provider / android_saf / saf_channel / saf_demo + Kotlin saf 包）
- ✅ 修 Kotlin `buildWriteRequest` 复制粘贴 bug
- ✅ `flutter analyze` 0 error、`flutter test` 52 通过、Android debug APK 构建通过

### 7.6 §5.5 SAF 备选条款的修订

§5.5 原记「A0/A1 的 SAF 代码保留为备选（不删除）」——**v2 撤销此条款**。SAF 全套代码（Dart `android_saf_file_system` / `saf_channel` / `content_uri_image_provider` / `saf_demo_screen` + Kotlin `saf/` 包）已删除。理由：MediaStore 已是安卓相册/图片的唯一通路，SAF 代码长期零引用、零维护，保留徒增认知负担与死代码；如未来确需非媒体文件场景，重新引入比维护一套僵尸代码成本更低。

