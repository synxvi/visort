# 发布前修复计划（GitHub Release 渠道：Windows + Android）

> 依据 2026-08-25 六路并行审查报告制定。渠道前提：不走 Play 商店，GitHub Release 直装。
> 由此：Play 合规类项移出范围；per-ABI versionCode 降为规范性建议；
> **签名仍是硬前提**——CI runner 的 debug keystore 每次不同，签名不固定则用户无法覆盖升级。
>
> 执行约定：每批次修完跑 `flutter analyze` + `flutter test`，通过后独立 commit。

## 批次 A —— 崩溃 + 数据误操作（发版硬门槛）

- [x] A1 minSdk 显式钉 26（`build.gradle.kts`；修复 Android 7.x 进相册即崩——Bundle query 是 API 26+）
- [x] A2 API 29 删除路径（`MediaStoreRepository.kt`：`createTrashRequest` 是 API 30 方法，Q 上 NoSuchMethodError 崩溃；连同 Q 上 sort 删除静默全失败一并修）
- [x] A3 安卓快捷键池 `?` 溢出（目标 >10 个时 key 全为 `?`，decide/Run 串位移错文件）：Home 拦截上限 + run_controller folderMap 重复 key fail-fast
- [x] A4 桌面 folder label 路径穿越（`normalizeFolderTemplates` 接入现成 `folderNameInvalidKey`，`..`/保留字符拦截）+ i18n key
- [x] A5 防重复点击：Review Run 按钮双击 = 双执行（`opaque:false` 转场窗口）；两端 Home `_startScan` 入口即置位防并发

## 批次 B —— 发布基建

- [ ] B1 签名机制落地：`key.properties` 读取 + 缺失回落 debug（保本地工作流）；生成生产 keystore（不入库）+ `.gitignore`
- [ ] B2 per-ABI versionCode 偏移（AGP 9 `androidComponents.onVariants`）
- [ ] B3 版本号定调 `1.3.0+2`（延续历史 v1.2.x 线）
- [ ] B4 CI：加 `flutter test`/`analyze` 门禁 job；pin `flutter-version: 3.47.1`；产物名带版本号
- [ ] B5 Windows `BINARY_NAME` → `visort`（不再泄漏工程名 visort_flutter.exe）
- [ ] B6 根 `.gitignore` 旧前缀 `sortr_flutter/` → `visort_flutter/`；32.6MB 字体全集 `git rm --cached`（本地保留）
- [ ] B7 重跑 `tools/subset_fonts.py`（子集落后 i18n 10 天）
- [ ] B8 调试残留清理：`main.dart` FPS 统计 + `[FONT]` 诊断、`detail_page.dart` 三处 `[dbg]` 热路径日志

## 批次 C —— 性能口碑

- [x] C1 Sort 屏解码带 `targetWidth`（桌面 `_ImageArea` / 安卓 `_FullscreenImage` / `precacheNextImage`）——键盘连按每键 48MB → ~7MB
- [x] C2 viewer 大图缓存清理接线（`evictViewerImageCache` 目前零调用）+ ImageCache 上限显式配置
- [x] C3 ContentObserver 防抖合并（批量操作后不再全量重查风暴）+ 快照落盘节流
- [x] C4 viewer `allowImplicitScrolling: true`（相邻页预取，连翻不糊）
- [x] C5 批量操作 `List.contains` → `Set` 四处 + `_currentSelectedIds` 交集化

## 批次 D —— 卡死/挂起路径

- [x] D1 桌面 `scanImages` 异常防护 + 两端 `_startScan` try/finally 复位 `_scanning`
- [x] D2 扫描/相册错误不再透传 `e.toString()` 原文 → i18n key 映射
- [x] D3 权限：声明 `READ_MEDIA_VISUAL_USER_SELECTED` + Android 14 部分授权识别 + 永久拒绝「去设置」出口
- [x] D4 壁纸页 `_applying` finally 复位（非 WallpaperException 不再卡死按钮）
- [x] D5 Kotlin `cleanupBinding` 六个 pending 补全 + error 回调；Dart 弹窗类 channel 加超时

## 批次 E —— 正确性收尾

- [x] E1 `MsImageInfo`/`MsBucket` copyWith 补全，删除 3+ 处手写拷贝（修收藏后 HDR 徽标被清 bug）
- [x] E2 文件夹 key 与 actionKeys 双向冲突检测（delete 键不再被静默劫持）+ i18n
- [x] E3 i18n：`photo_count` 中文补齐、快捷键冲突文案 key 化、EN/ZH key 对齐护栏测试
- [x] E4 Run 生命周期：Results 屏 PopScope（执行中禁退出）+ RunController 防重入
- [x] E5 配置损坏备份（`visort_config_bak`）不再静默清零
- [x] E6 全局错误兜底（`FlutterError.onError` + `PlatformDispatcher.onError`）

## 批次 F —— 原生层加固

- [x] F1 批量删除/移动/重命名 IO 移出主线程（ioExecutor）——上千张不再 ANR
- [x] F2 系统弹窗 URI 分片（300-500/批）——大批量不再 TransactionTooLarge
- [x] F3 `hdrCache` HashMap → ConcurrentHashMap
- [x] F4 `trimThumbnailCache` walkTopDown（缓存不再无界增长）
- [x] F5 `moveBatch` 部分成功协议（返回成功 id 集，Results 不再误报全失败）
- [x] F6 `ACCESS_MEDIA_LOCATION` 运行时请求（详情 GPS 不再恒空）

## 批次 G —— 清理

- [x] G1 死代码：不可达 `gallery_screen.dart` 整屏、零引用 `loading_overlay.dart`/`navigatorKeyProvider`/`hasPersistedSession`
- [x] G2 `allowBackup=false` + manifest 权限注释纠偏
- [x] G3 杂项：壁纸 `setStream` 第三参 false、删零引用 `collection` 依赖、`onReorder`→`onReorderItem`、analyze warning 清零
- [x] G4 AGENTS.md 更新（ente_viewer/core/db/photo_view fork/测试规模已漂移一个版本）

## 批次 H —— 终验

- [x] H1 `flutter analyze`（warning 清零目标）+ `flutter test` 全过
- [x] H2 `flutter build apk --release --split-per-abi` 出包验证 + versionCode 三包互异核对
- [x] H3 Windows 构建交 CI 验证（本机 Linux 无法交叉编译）

## 明确不做（本轮范围外）

- god class 拆分（home_screen_android 2382 行 / detail_page 2059 行）、会话恢复四件套两端去重、`'Space Mono'` 153 处字面量收敛 → 发版后第一轮重构
- Windows 代码签名（OV 证书 + signtool）→ SmartScreen 警告可接受，正式分发再买
- Play 商店合规、国内备案 → 渠道不需要
- gallery_controller `._pageSize = 100000` 全量加载、无 mocktail/_bloc_test 等均为 AGENTS.md 记载的刻意设计，不动
