# sortr.spec
# PyInstaller build specification for SORTR.
#
# 仅输出单文件模式：
#   onefile — 单个独立 exe（dist/sortr-windows.exe）
#
# Usage:
#   pyinstaller sortr.spec --noconfirm
#
# Cross-platform notes:
#   Windows : outputs  dist/sortr-windows.exe
#   macOS   : outputs  dist/SORTR.app
#   Linux   : outputs  dist/sortr-linux

import sys
from PyInstaller.building.api import PYZ, EXE
from PyInstaller.building.build_main import Analysis
from PyInstaller.building.osx import BUNDLE

# ── Determine output name per platform ───────────────────────────────────────
if sys.platform == "win32":
    exe_name = "sortr-windows"
elif sys.platform == "darwin":
    exe_name = "SORTR"
else:
    exe_name = "sortr-linux"

# ── Analysis ─────────────────────────────────────────────────────────────────
a = Analysis(
    ["app.py"],
    pathex=[],
    binaries=[],
    datas=[("index.html", "."), ("assets/fonts", "assets/fonts")],
    hiddenimports=[
        "flask",
        "flask.templating",
        "jinja2",
        "jinja2.ext",
        "werkzeug",
        "werkzeug.routing",
        "werkzeug.serving",
        "werkzeug.exceptions",
        "werkzeug.middleware.shared_data",
        "click",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # 排除大型但不需要的第三方包
        "matplotlib", "numpy", "PIL", "scipy",
        # 不需要的标准库模块
        "unittest", "pydoc", "doctest",
        "multiprocessing", "asyncio", "xmlrpc",
        "setuptools", "pip", "distutils",
    ],
    noarchive=False,
)

pyz = PYZ(a.pure)

# ── 单文件 EXE（onefile）────────────────────────────────────────────────────
# onefile 模式：所有依赖打包进单个 exe，启动时自动解压到临时目录。
# console=False：纯窗口运行，不弹出命令行窗口。
exe_onefile = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name=exe_name,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    onefile=True,
    version_file=None,
    # icon="assets/icon.ico",  # Windows 图标（可选）
)

# ── macOS .app bundle ────────────────────────────────────────────────────────
app = BUNDLE(
    exe_onefile,
    name="SORTR.app",
    icon=None,
    bundle_identifier="com.sortr.app",
    info_plist={
        "CFBundleName": "SORTR",
        "CFBundleDisplayName": "SORTR",
        "CFBundleVersion": "1.2.0",
        "CFBundleShortVersionString": "1.2.0",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
    },
)
