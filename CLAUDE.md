# CLAUDE.md

> **本仓库的 AI 协作指南已统一到 [`AGENTS.md`](./AGENTS.md)。** 请以 `AGENTS.md` 为准——它是最新的架构、约定与命令参考。本文件保留仅为兼容 Claude Code 的默认读取入口，不再单独维护内容。

## 项目一句话

**SORTR** —— 键盘驱动的桌面 + 移动图片 / 相册整理工具。活动代码库是 Flutter 应用（`visort_flutter/`，目标 Windows 桌面 + Android）；根目录的 `app.py` / `index.html` 是仍随版本发布的历史 Python / Flask 实现。

**核心不变量**：所有移动 / 删除操作先暂存于内存，仅在用户确认 "Run" 后执行。

## 指引

- 架构、数据流、状态管理、文件系统抽象、代码约定、测试 → [`AGENTS.md`](./AGENTS.md)
- 安卓开发决策与里程碑（A0–A4、SAF→MediaStore 转向、v2 相册定型）→ [`docs/ANDROID_ROADMAP.md`](./docs/ANDROID_ROADMAP.md)
