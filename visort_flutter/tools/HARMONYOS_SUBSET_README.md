# HarmonyOS Sans SC 字体子集化说明

## 背景

安卓冷启动慢的主因之一：原始 `HarmonyOS_Sans_SC` Regular + Bold 合计约 **15.7 MB**（覆盖 GB18030 全集，约 29000 字形）。Flutter 引擎启动时会将打包字体全量注册到 `FontCollection`，在中端安卓机上吃掉数百毫秒。

本工具链将其裁剪为 **GB2312 一级 + 二级常用字（6763 字）+ 应用 UI 文案 + 常用标点/ASCII**，单文件约 **1.7 MB**，合计约 **3.4 MB**（缩减 78%）。

## 字符集覆盖范围

| 来源 | 字符数 | 说明 |
|------|--------|------|
| GB2312 一级字（区位 16~55） | 3755 | 覆盖 99.8% 日常中文 |
| GB2312 二级字（区位 56~87） | 3008 | 次常用字，用户文件名/相册名会用到 |
| i18n UI 文案（strings_zh/en） | ~227 | 应用界面文案 100% 覆盖 |
| 常用标点 / 全角符号 / ASCII | ~300 | 中英文标点、数字、符号 |

**缺失字符如何兜底**：子集未包含的罕用字（如部分生僻人名用字、CJK 扩展 B+），由 `AppFonts.cjkFallback` 链中的系统 CJK 字体兜底渲染——安卓 `Noto Sans CJK` / Windows `微软雅黑`，不会出现豆腐块。

## 重新生成

### 前置依赖

```bash
pip install fonttools brotli zopfli
```

### 执行

```bash
cd sortr_flutter
python tools/subset_fonts.py
```

脚本会：
1. 首次运行时把 `assets/fonts/` 下的原始全集字体（>5MB）备份到 `.font-source/`（`assets` 之外，不入 git、不进 APK）。
2. 从 `.font-source/*.full.ttf` 读取并裁剪，输出覆盖 `assets/fonts/HarmonyOS_Sans_SC_Regular.ttf` / `_Bold.ttf`。
3. 打印前后体积与字形数对比。

可重复执行——始终以 `.font-source/*.full.ttf` 为输入源。

> ⚠️ 全集备份**必须**放在 `.font-source/` 而非 `assets/fonts/`。因为 `pubspec.yaml` 用 `assets/fonts/` 通配会打包该目录所有文件，若全集留在其中，16MB 会被打进 APK，完全抵消子集化收益。

## 原始字体获取

HarmonyOS Sans SC 完整字体（约 8MB/字重）下载：
- 官方：https://developer.harmonyos.com/cn/design/resource/ （搜索 "HarmonyOS Sans"）
- GitHub 镜像：https://github.com/harmonyos-fonts

下载后将 `HarmonyOS_Sans_SC_Regular.ttf` 与 `HarmonyOS_Sans_SC_Bold.ttf` 放入 `sortr_flutter/.font-source/`，**重命名为 `*.full.ttf`**（即 `HarmonyOS_Sans_SC_Regular.ttf.full.ttf`），再运行脚本。

## 字体策略决策记录

- **为何不全量打包**：16MB 全集严重拖慢安卓冷启动（首屏字体注册数百毫秒）。
- **为何不在安卓改用系统 Noto CJK**：曾考虑过。但为保持「Windows / 安卓中文字形视觉一致」而保留打包字体，仅做子集化。Windows 端因 flutter/flutter#103811 必须打包字体。
- **为何保留二级字**：用户文件名 / 相册名可能含次常用字，去掉会频繁回退系统字体导致同屏字形不一致。
