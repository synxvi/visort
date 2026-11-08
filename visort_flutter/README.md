# visort_flutter

**VISORT** 的 Flutter 应用——键盘 / 手势驱动的图片整理 + 相册，仓库唯一代码库（Android + Windows）。

> 仓库根目录的 [`AGENTS.md`](../AGENTS.md) 是权威的架构与开发指南；本文件仅作快速上手。
> 完整架构决策见 [`docs/ANDROID_ROADMAP.md`](../docs/ANDROID_ROADMAP.md)。
> 面向用户的介绍与截图见根目录 [`README_zh.md`](../README_zh.md) / [`readme.md`](../readme.md)。

## 平台

- **Android**（活跃开发）— 相册浏览 + 整理流水线，MediaStore 核心架构已交付，相册生态（收藏 / 回收站 / 搜索 / 壁纸 / 查看器）持续迭代
- **Windows 桌面**（稳定，冻结）— 键盘驱动的逐张分类

## 核心特性

- **非破坏式工作流**：所有移动 / 删除操作先暂存，确认 Run 后才执行；删除走系统回收站
- **双数据通路**（Android）：分类（`FileSystemRepository` → `ImageRef`）与相册浏览（`GalleryController` → `MsImageInfo` 直连 MediaStore）独立设计，长期共存
- **相册浏览**：keyset 游标分页（免疫删除错位）、ContentObserver 实时刷新、全屏 PhotoViewer（缩放 / filmstrip / 壁纸裁剪）
- **相册生态**：收藏跨相册聚合、系统回收站、本地搜索索引、空闲预缓存
- **两种整理模式**（Android Setup）：相册间（toAlbum）/ 子目录规则（toNewDir，键 A / B 分流）
- **国际化**：中 / 英双语，335 个 i18n 键（`i18n_keys_test` 保证 EN/ZH 对齐）
- **无代码生成**：所有模型手写 `@immutable` + 手动 JSON 编解码

## 环境要求

- Flutter ≥ 3.47.1（Dart ≥ 3.10.4）
- Android：JDK 17，AGP 9.0.1，Kotlin 2.3.20，Gradle 9.1.0，minSdk 30
- Windows：CMake ≥ 3.14，MSVC C++17（`/W4 /WX` 警告即错误）

## 常用命令

```bash
flutter pub get                  # 安装依赖（首次）
flutter run -d windows           # Windows 桌面运行
flutter run -d android           # Android 真机 / 模拟器
flutter analyze                  # 静态分析（flutter_lints，无自定义规则）
flutter test                     # 运行单元测试套件
flutter build apk --release --split-per-abi \
  --obfuscate --split-debug-info=build/symbols   # Android release（剥离 Dart 符号）
flutter build windows --release  # 构建 Windows exe
```

构建产物在 `build/`：APK 位于 `build/app/outputs/flutter-apk/`，Windows exe 位于 `build/windows/x64/runner/Release/`。

## 测试

`flutter test`，22 个文件 / 208 个用例，均为纯 Dart 单测，覆盖：配置模型与 JSON 往返、会话状态机（decide/undo/restore）、Run 执行流与进度流、桌面文件系统（扫描 / 移动 / 冲突重命名 / 删除）、相册控制器（keyset 分页 / 批量操作 / ContentObserver 防抖）、SQLite 存储层（会话 / 快照 / 搜索索引 / 运行日志）、i18n 键位对齐。详见根 `AGENTS.md` 的覆盖表。

## 架构速览

- **状态管理**：Riverpod ^2.6.1；`main()` 手建 `ProviderContainer` + `UncontrolledProviderScope`
- **路由**：Flutter 内置命名路由；Android 五页 Shell（相册 / 整理 / 收藏 / 回收站 / 设置）
- **平台分叉**：UI 层文件级分叉（`*_android` + `*_common`），逻辑层仅限固定 seam（`fs_provider`、`image_loader`、`database_service` 等）
- **Kotlin 原生**：`android/.../mediastore/`（MediaStore MethodChannel + EventChannel + ContentObserver）与 `wallpaper/`

详见根 `AGENTS.md` 与 `docs/ANDROID_ROADMAP.md`。

## 子集化字体

i18n 字符串变更后运行（CJK 字体子集化，优化 Android 冷启动与包体）：

```bash
pip install fonttools brotli zopfli
python tools/subset_fonts.py   # 幂等，需将原始全集字体置于 .font-source/
```
