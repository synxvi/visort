# SORTR dev 分支变更总结（相对于 main）

> **生成日期**：2026-04-06
> **对比分支**：`main` → `dev`（当前工作区未提交修改）
> **版本变化**：1.0.0 → 1.1.0

---

## 一、变更概览

| 文件 | main 行数 | dev 行数 | 变化 |
|------|----------|---------|------|
| `app.py` | 546 | 1030 | +484（新功能 + 结构优化） |
| `index.html` | 1085 | 1834 | +749（UI 重构 + 中文化） |
| `sortr.spec` | 105 | 125 | 优化打包配置 |
| `requirements.txt` | 3 | 2 | 移除 pywebview |
| `readme.md` | — | — | 替换为中文版 |

**新增目录/文件**（未跟踪）：
- `assets/fonts/` — 本地字体文件（替代 Google Fonts CDN）
- `config/` — 运行时配置目录模板
- `docs/` — 项目文档
- `CLAUDE.md` / `CODEBUDDY.md` — AI 协作配置

---

## 二、app.py 后端变更

### 2.1 移除 pywebview，改用系统浏览器

**背景**：pywebview 在 Windows DPI 缩放下窗口位置/大小记忆存在根本性缺陷，多次尝试修复均失败。

**改动**：
- 删除 `import webview` 及所有 pywebview 相关代码
- 删除窗口状态管理（`window_size.json`、DPI 检测、`SetProcessDPIAware`）
- 打包模式下统一使用 `webbrowser.open()` 打开系统默认浏览器
- 浏览器自身完美管理窗口大小/位置，无需额外代码

### 2.2 多配置组（Profiles）系统

**新增**：支持多组快捷键/文件夹配置，适用于不同整理场景。

| 新增函数/变量 | 说明 |
|--------------|------|
| `get_config_dir()` | 配置目录从 `~/.sortr/` 改为 `exe同级/config/`，便携性更好 |
| `PROFILES_FILE` | `config/profiles.json`，存储所有配置组 |
| `ACTIVE_PROFILE` | 当前激活的配置组名（默认 `"默认"`） |
| `profiles_data` | 内存中的配置组数据 |
| `_ensure_profile_dict()` | 兼容旧格式（列表）→ 新格式（字典） |
| `_load_profiles()` | 加载配置，含旧版 `~/.sortr/folders.json` 自动迁移 |
| `_save_profiles()` | 持久化配置到磁盘 |
| `DEFAULT_ACTION_KEYS` | 默认功能键：undo=z, delete=x, skip=c |

**新增 API**：

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/profiles` | GET | 获取所有配置组列表、当前配置、上次使用的目录 |
| `/api/profiles` | POST | 切换/创建/删除配置组（action: switch/create/delete） |

### 2.3 自定义功能键绑定

**新增**：用户可自定义 undo / delete / skip 的快捷键。

| 相关函数 | 说明 |
|---------|------|
| `load_action_keys()` | 加载当前配置组的功能键 |
| `save_action_keys()` | 保存功能键到配置 |
| `_get_profile_action_keys()` | 获取指定配置组的功能键 |

### 2.4 新增 API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/browse` | GET | 调用 tkinter 原生目录选择器 |
| `/api/scan-subdirs` | POST | 列出指定目录下的子文件夹 |
| `/api/run-stream` | POST | SSE 流式执行，实时返回进度 |
| `/fonts/<filename>` | GET | 本地字体文件服务（替代 CDN） |

### 2.5 记忆上次使用的目录

| 函数 | 说明 |
|------|------|
| `save_last_dirs()` | 扫描时保存源目录和目标父目录到 `profiles.json` |
| `load_last_dirs()` | 启动时读取上次使用的目录，自动填入 |

### 2.6 根目录移动（`__root__`）

decide 端点新增 `__root__` 目标键，允许将图片直接移动到目标父目录（不进入子文件夹）。

### 2.7 打包优化（sortr.spec）

| 改动 | 说明 |
|------|------|
| `onefile=True` → `onefile=False` | 改为目录分发，启动速度提升 3-5 秒 |
| 新增 `COLLECT` | onedir 模式必需 |
| 新增 `assets/fonts` 数据文件 | 本地字体 |
| 新增 `tkinter` hiddenimports | 原生目录选择器 |
| 移除 `webview` hiddenimports | 不再使用 pywebview |
| `excludes` 移除 `tkinter` | 改为需要 tkinter |

### 2.8 代码清理

| 清理项 | 说明 |
|--------|------|
| 删除 `FOLDER_TEMPLATES_FILE` 变量 | 已被 profiles 系统替代，声明未使用 |
| 删除 `_last_dirs` 全局变量 | `load_last_dirs()` 直接调用即可 |
| 删除残留注释 `# Window size save (from JS)` | 窗口管理已移除 |
| 修复 `scan()` docstring 缩进 | `folder_templates` 参数描述格式对齐 |

---

## 三、index.html 前端变更

### 3.1 中文化

- 页面语言 `en` → `zh-CN`
- 标题、按钮、提示文本全面中文化
- 版本号 `1.0.0` → `1.1.0`

### 3.2 本地字体

- 移除 Google Fonts CDN `<link>` 标签
- 新增 6 个 `@font-face` 声明（Space Mono、Syne 各字重）
- 通过 `/fonts/` 路由加载本地字体，消除网络延迟

### 3.3 UI 重构

| 改动 | 说明 |
|------|------|
| 配置组切换器 | 新增 profile-switcher 组件，支持新建/删除/切换 |
| 功能键编辑器 | 新增 action-keys-editor，可自定义快捷键 |
| 目录浏览按钮 | 新增"浏览"按钮调用 `/api/browse` 原生选择器 |
| 导入子文件夹 | 新增按钮将目标父目录下的子目录批量导入为文件夹类型 |
| 根目录移动按钮 | 新增 `__root__` 按钮，将图片移到目标父目录 |
| 图片详情面板 | 图片下方显示文件名、尺寸、分辨率、时间等元数据 |
| 加载遮罩 | 新增 loading-overlay，扫描/执行时全屏显示进度 |
| 快捷键提示 | 重新设计为横排列表布局 |
| 消息提示框 | 最大宽度 320px → 360px |
| body 闪烁消除 | 初始 `opacity: 0`，字体加载完成后添加 `.ready` 类显示 |

### 3.4 流式执行（SSE）

Review 确认后使用 `/api/run-stream` 替代 `/api/run`，实时显示文件操作进度。

---

## 四、依赖变化

| 包 | main | dev | 说明 |
|----|------|-----|------|
| Flask | >=3.0.0 | >=3.0.0 | 不变 |
| pywebview | >=5.0 | **移除** | 窗口管理改用浏览器 |
| pyinstaller | >=6.0.0 | >=6.0.0 | 不变 |

---

## 五、配置目录变化

| 项目 | main | dev |
|------|------|-----|
| 配置位置 | `~/.sortr/` | `exe同级/config/` |
| 配置文件 | `folders.json`（单组） | `profiles.json`（多组） |
| 旧版迁移 | 无 | 自动检测 `~/.sortr/folders.json` 并导入 |
