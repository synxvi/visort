<div align="center">

# SORTR

**键盘驱动的图片 / 相册整理工具** — 桌面 + 安卓

逐张浏览，一键分类，确认前不碰任何文件。

[**English**](readme.md)

[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-blue)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.12%2B-0175C2)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## 为什么用 SORTR？

拍了成百上千张照片堆在一个文件夹里不想整理？SORTR 让你像反应一样快速分类——眼睛看图，一键一决策，几分钟就能把几百张图片归位。

**核心设计原则：所有操作先暂存，确认后才执行。** 不会误删、不会误移。

## 平台

| 平台 | 状态 | 特性 |
|---|---|---|
| **Windows 桌面** | 稳定 · 功能完整 | 键盘驱动分类，窗口状态持久化 |
| **Android** | 活跃开发中 | MediaStore 相册浏览 + 整理；相册体验为当前开发重心 |

代码库是 [`visort_flutter/`](visort_flutter/) 下的 **Flutter 应用**，移植自早期的 Python / Flask 实现（已移除）。

## 功能

- **键盘优先** — Windows 上单键移动 / 删除 / 跳过；安卓上点按目标
- **暂存执行** — 所有移动 / 删除先排队入内存，点 Run 前不动文件系统
- **相册浏览器**（安卓）— keyset 分页的 MediaStore 图库、ContentObserver 实时刷新、全屏查看器
- **两种整理模式**（安卓）— 移入已有相册，或按自定义子目录分类
- **执行前审核** — 执行前查看完整的暂存操作统计
- **中英文界面** — 一键切换，自动保存
- **冲突处理** — 同名文件自动加数字后缀，不覆盖
- **无代码生成** — 全程手写不可变模型

## 快速开始（Flutter）

需要 [Flutter ≥ 3.44](https://flutter.dev)（Dart ≥ 3.12）。

```bash
git clone https://github.com/synxvi/visort.git
cd visort/visort_flutter
flutter pub get
flutter run -d windows        # Windows 桌面
flutter run -d android        # 安卓真机 / 模拟器
```

构建：

```bash
flutter build windows --release   # → build/windows/x64/runner/Release/
flutter build apk --release       # → build/app/outputs/flutter-apk/
```

> 安卓 release 构建目前用 debug 签名（尚未配置生产 keystore）。

## 使用流程

```
配置 → 分类 → 审核 → 执行
```

1. **配置** — 选源（安卓选相册，Windows 选目录），设置目标文件夹
2. **分类** — 逐张决策：移到文件夹、移到根目录、删除或跳过
3. **审核** — 查看暂存操作的统计
4. **执行** — 确认后一次性应用

## 支持格式

18 种：JPG · PNG · GIF · BMP · WEBP · TIFF · TIF · SVG · ICO · HEIC · HEIF · RAW · CR2 · NEF · ARW · DNG · AVIF

## 技术栈

| 层 | 技术 |
|---|---|
| 界面 / 逻辑 | Flutter（Dart ≥ 3.12），Riverpod ^2.6.1 |
| 安卓原生 | Kotlin + MediaStore（MethodChannel + EventChannel + ContentObserver） |
| Windows 原生 | CMake 运行器（C++17） |
| 测试 | `flutter_test`，52 个单测用例 |
| 状态 | 内存暂存，无数据库 |

## 文档

- [`AGENTS.md`](AGENTS.md) — 权威的架构与开发指南
- [`docs/ANDROID_ROADMAP.md`](docs/ANDROID_ROADMAP.md) — 安卓端口决策（A0–A4、SAF→MediaStore、v2 相册定型）
- [`visort_flutter/README.md`](visort_flutter/README.md) — Flutter 应用快速上手

## 许可证

[MIT License](LICENSE)
