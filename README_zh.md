<div align="center">

# SORTR

**键盘驱动的桌面图片整理工具**

逐张浏览，一键分类，确认前不碰任何文件。

[**English**](README.md)

[![Python 3.9+](https://img.shields.io/badge/Python-3.9%2B-blue)](https://www.python.org/)
[![Flask](https://img.shields.io/badge/Flask-3.x-green)](https://flask.palletsprojects.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## 为什么用 SORTR？

拍了成百上千张照片，堆在一个文件夹里不想整理？SORTR 让你像打字一样快速分类 — 左手按快捷键，眼睛看图，几分钟就能把几百张图片归档到对应文件夹。

**核心设计原则：所有操作先暂存，确认后才执行。** 不会误删、不会误移。

## 功能

- **键盘优先** — 单键移动/删除/跳过，无需鼠标
- **自定义快捷键** — 文件夹按键、撤销、删除、跳过均可自由配置
- **多配置组** — 保存多套分类方案，一键切换
- **拖拽排序** — 拖拽调整目标子目录顺序
- **审核预览** — 执行前查看完整的操作统计
- **中英文界面** — 一键切换，自动保存
- **导入子目录** — 目标父目录下的子文件夹一键导入
- **冲突处理** — 同名文件自动加数字后缀，不覆盖
- **目录记忆** — 自动记住上次使用的目录
- **单文件打包** — 双击即用，无需安装

## 快速开始

### 下载

从 [Releases](https://github.com/synxvi/sortr/releases) 下载最新版，双击运行。

### 运行源码

```bash
git clone https://github.com/synxvi/sortr.git
cd sortr
pip install -r requirements.txt
python app.py
```

## 使用流程

```
配置 → 分类 → 审核 → 执行
```

1. **配置** — 设置源目录和目标目录，自定义分类文件夹和快捷键
2. **分类** — 逐张浏览，键盘操作：

   | 操作 | 按键 |
   |---|---|
   | 移动到子目录 | `A` `S` `D` ... |
   | 移动到根目录 | `空格` |
   | 删除 | `X`（可配置） |
   | 跳过 | `C`（可配置） |
   | 撤销 | `Z`（可配置） |

3. **审核** — 查看暂存操作的统计和明细
4. **执行** — 确认后一次性应用到文件系统

## 支持格式

JPG · PNG · GIF · BMP · WEBP · TIFF · SVG · ICO · HEIC · HEIF · AVIF · CR2 · NEF · ARW · DNG

## 技术栈

| 层 | 技术 |
|---|---|
| 后端 | Flask (Python 3.9+) |
| 前端 | 原生 JS SPA |
| 打包 | PyInstaller |
| 窗口 | pywebview |

## 许可证

[MIT License](LICENSE)
