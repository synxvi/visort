# SORTR — 键盘驱动的图片整理工具

[![Python](https://img.shields.io/badge/Python-3.9%2B-blue)](https://www.python.org/)
[![Flask](https://img.shields.io/badge/Flask-3.x-green)](https://flask.palletsprojects.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/平台-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)](#构建)

轻量级桌面图片整理工具。扫描目录中的图片，逐张浏览并一键分类到不同文件夹。所有操作在确认前不会触碰任何文件。

> Fork 自 [SinghChinmay/sortr-image-organizer-desktop](https://github.com/SinghChinmay/sortr-image-organizer-desktop)，增加了多配置组、自定义快捷键、目录记忆等功能。

---

## 功能

- **递归/同层级扫描** — 可切换扫描模式，递归遍历或仅扫描当前层级
- **中英文切换** — 界面语言一键切换，自动保存偏好
- **键盘优先** — 按单个字母键移动图片，无需鼠标操作
- **多配置组** — 保存多套分类方案（如"工作"、"生活"），一键切换
- **自定义快捷键** — 撤销/删除/跳过的按键可自由配置
- **目录记忆** — 自动记住上次使用的源目录和目标目录
- **导入子目录** — 将目标父目录下的子文件夹一键导入为分类目标
- **非破坏性** — 所有操作先暂存，确认后才执行，支持撤销
- **审核预览** — 执行前可查看完整的移动/删除/跳过统计
- **冲突处理** — 目标文件同名时自动加数字后缀，不覆盖
- **单文件打包** — PyInstaller onefile 模式，双击即用，无命令行窗口

---

## 快速开始

### 下载

从 [Releases](https://github.com/synxvi/sortr/releases) 下载对应平台的可执行文件，双击运行即可。

### 运行源码

```bash
git clone https://github.com/synxvi/sortr.git
cd sortr

python -m venv .venv
# Windows
.venv\Scripts\activate
# macOS / Linux
source .venv/bin/activate

pip install -r requirements.txt
python app.py
```

启动后浏览器自动打开 `http://127.0.0.1:5050`。

### 构建

```bash
pip install -r requirements.txt
pyinstaller sortr.spec --noconfirm --clean
```

产物输出到 `dist/` 目录，为当前平台的单文件可执行程序。

---

## 使用说明

### 第一步：配置

1. **源目录** — 输入或浏览选择包含待整理图片的文件夹
2. **目标父目录** — 分类后的子目录将创建在此目录下
3. **配置组** — 选择/新建一套分类方案，可创建多套（如按项目分类）
4. **目标子目录** — 设置分类目标（快捷键 + 文件夹名），也可点击「导入子文件夹」自动导入
5. 点击 **Start** 开始扫描

### 第二步：分类

逐张显示图片，使用键盘操作：

| 操作 | 按键 |
|---|---|
| 移动到子目录 | 对应快捷键（如 `a` `s` `d`） |
| 移动到根目录 | `空格` |
| 删除 | 可配置，默认 `X` |
| 跳过 | 可配置，默认 `C` |
| 撤销 | 可配置，默认 `Z` |

也可直接点击右侧按钮操作。

### 第三步：审核

浏览完所有图片后进入审核界面：
- 统计移动/删除/跳过/未处理的数量
- 逐条查看每张图片的操作和目标位置
- 可返回继续分类

### 第四步：执行

确认无误后点击「执行」，所有操作一次性应用到文件系统。执行完成后显示结果统计。

---

## 配置文件

配置保存在程序同级的 `config/profiles.json`：

```json
{
  "active_profile": "默认",
  "language": "en",
  "profiles": {
    "默认": {
      "folders": [{"key": "a", "label": "通用"}],
      "action_keys": {"undo": "z", "delete": "x", "skip": "c"}
    }
  }
}
```

---

## 支持的图片格式

JPG · JPEG · PNG · GIF · BMP · WEBP · TIFF · SVG · ICO · HEIC · HEIF · AVIF · RAW · CR2 · NEF · ARW · DNG

> RAW 格式可正常移动/删除，但浏览器预览可能无法显示。

---

## 技术栈

- **后端** — Flask (Python 3.9+)
- **前端** — 原生 JS 单页应用，无构建步骤
- **打包** — PyInstaller 单文件可执行程序（onefile 模式，无控制台窗口）

---

## 许可证

[MIT License](LICENSE)
