# SORTR — 键盘驱动的图片整理工具

[![Python](https://img.shields.io/badge/Python-3.9%2B-blue)](https://www.python.org/)
[![Flask](https://img.shields.io/badge/Flask-3.x-green)](https://flask.palletsprojects.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

轻量级桌面图片整理工具。扫描目录中的图片，逐张浏览并一键分类到不同文件夹。所有操作在确认前不会触碰任何文件。

---

## 功能

- **键盘优先** — 按单个键移动/删除/跳过图片，无需鼠标
- **拖动排序** — 拖拽调整目标子目录的顺序
- **自定义快捷键** — 文件夹按键、撤销/删除/跳过均可自由配置
- **多配置组** — 保存多套分类方案，一键切换
- **中英文切换** — 界面语言一键切换，自动保存
- **递归/同层级扫描** — 可切换扫描模式
- **目录记忆** — 自动记住上次使用的源目录和目标目录
- **导入子目录** — 将目标父目录下的子文件夹一键导入为分类目标
- **审核预览** — 执行前查看完整的移动/删除/跳过统计
- **冲突处理** — 目标文件同名时自动加数字后缀，不覆盖
- **单文件打包** — 双击即用，无命令行窗口

---

## 快速开始

### 下载

从 [Releases](https://github.com/synxvi/sortr/releases) 下载最新版 `sortr-windows.exe`，双击运行即可。

### 运行源码

```bash
git clone https://github.com/synxvi/sortr.git
cd sortr

python -m venv .venv
.venv\Scripts\activate     # Windows
source .venv/bin/activate  # macOS / Linux

pip install -r requirements.txt
python app.py
```

启动后浏览器自动打开 `http://127.0.0.1:5050`。

### 构建

```bash
pip install -r requirements.txt
pyinstaller sortr.spec --noconfirm --clean
```

产物输出到 `dist/sortr-windows.exe`。

---

## 使用流程

**1. 配置**

设置源目录、目标父目录，自定义分类子文件夹的快捷键和名称。支持「导入子文件夹」批量添加。

**2. 分类**

逐张浏览图片，键盘操作：

| 操作 | 按键 |
|---|---|
| 移动到子目录 | 对应快捷键（如 `A` `S` `D`） |
| 移动到根目录 | `空格` |
| 删除 | 可配置，默认 `X` |
| 跳过 | 可配置，默认 `C` |
| 撤销 | 可配置，默认 `Z` |

**3. 审核** — 查看所有暂存操作的统计和明细，可返回继续调整。

**4. 执行** — 确认无误后点击「执行」，一次性应用到文件系统。

---

## 配置文件

首次运行后自动生成在程序同级的 `config/profiles.json`，保存语言偏好、快捷键绑定和配置组。

---

## 支持的图片格式

JPG · JPEG · PNG · GIF · BMP · WEBP · TIFF · SVG · ICO · HEIC · HEIF · AVIF · CR2 · NEF · ARW · DNG

---

## 技术栈

- **后端** — Flask (Python 3.9+)
- **前端** — 原生 JS 单页应用，无构建步骤
- **打包** — PyInstaller 单文件可执行程序（onefile）

---

## 许可证

[MIT License](LICENSE)
