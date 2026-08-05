# visort_flutter

**VISORT** 的 Flutter 重写版——键盘驱动的图片 / 相册整理应用，同时是一个现代相册浏览器。

> 仓库根目录的 [`AGENTS.md`](../AGENTS.md) 是权威的架构与开发指南；本文件仅作快速上手。
> 完整架构决策见 [`docs/ANDROID_ROADMAP.md`](../docs/ANDROID_ROADMAP.md)。

## 平台

- **Windows 桌面**（功能完整）— 键盘驱动的逐张分类
- **Android**（活跃开发中）— 相册浏览 + 整理，已交付 MediaStore 核心架构，相册体验持续迭代

## 核心特性

- **非破坏式工作流**：所有移动 / 删除操作先暂存，确认 Run 后才执行
- **双数据通路**（Android）：分类（`FileSystemRepository` → `ImageRef`）与相册浏览（`GalleryController` → `MsImageInfo` 直连 MediaStore）独立设计，长期共存
- **相册浏览**：keyset 游标分页（免疫删除错位）、ContentObserver 实时刷新、全屏 PhotoViewer 分页联动
- **两种整理模式**（Android Setup）：toAlbum（移入已有相册）/ toNewDir（按自定义子目录分类）
- **国际化**：中 / 英双语，~161 个 i18n 键
- **无代码生成**：所有模型手写 `@immutable` + 手动 JSON 编解码

## 环境要求

- Flutter ≥ 3.44.0（Dart ≥ 3.12.0）
- Android：JDK 17，AGP 8.11.1，Kotlin 2.2.20，Gradle 8.14
- Windows：CMake ≥ 3.14，MSVC C++17（`/W4 /WX` 警告即错误）

## 常用命令

```bash
flutter pub get                  # 安装依赖（首次）
flutter run -d windows           # Windows 桌面运行
flutter run -d android           # Android 真机 / 模拟器
flutter analyze                  # 静态分析（flutter_lints，无自定义规则）
flutter test                     # 运行单元测试套件
flutter build apk --release      # 构建 Android APK
flutter build apk --split-per-abi
flutter build windows --release  # 构建 Windows exe
```

构建产物在 `build/`：APK 位于 `build/app/outputs/flutter-apk/`，Windows exe 位于 `build/windows/x64/runner/Release/`。

## 测试

`flutter test`，5 个文件 / 52 个用例，均为纯 Dart 单测，覆盖：配置模型与 JSON 往返、会话状态机（decide/undo）、Run 执行流与进度流、桌面文件系统（扫描 / 移动 / 冲突重命名 / 删除）、相册控制器（keyset 分页 / 删除 / 排序持久化）。

## 架构速览

- **状态管理**：Riverpod ^2.6.1；`main()` 手建 `ProviderContainer` + `UncontrolledProviderScope`
- **路由**：Flutter 内置命名路由（setup / sort / review / results / gallery / album / photoViewer）
- **平台分叉**：显式 `Platform.isAndroid` / `isWindows`（FS 提供者、路由、屏幕、布局、键盘处理）
- **Kotlin 原生**：`android/.../mediastore/`（MediaStore MethodChannel + EventChannel + ContentObserver）

详见根 `AGENTS.md` 与 `docs/ANDROID_ROADMAP.md`。

## 子集化字体

i18n 字符串变更后运行（HarmonyOS Sans SC 子集化，优化 Android 冷启动）：

```bash
pip install fonttools brotli zopfli
python tools/subset_fonts.py   # 幂等
```
