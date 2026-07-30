#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HarmonyOS Sans SC 字体子集化 —— 安卓冷启动优化

背景：原始 HarmonyOS_Sans_SC Regular+Bold 合计约 15.7MB，覆盖 GB18030 全集。
Flutter 引擎在启动时会把它全量注册到 FontCollection，是安卓冷启动最大单项开销。
本脚本将其裁剪为「应用 UI 文案 + 常用汉字 + 标点 + ASCII」子集，单文件可压到约 0.5MB。

字符集来源：
  1. lib/core/i18n/strings_zh.dart 与 strings_en.dart 中所有字符串字面量（UI 文案 100% 覆盖）
  2. GB2312 一级+二级常用字（6763 字）
  3. 常用 CJK 标点 / 全角符号 / ASCII 可见字符
  4. 数字 / 基本拉丁补充

裁剪后缺失的生僻字（如用户文件名罕用字）由 fontFamilyFallback 链里的
系统 CJK 字体兜底（安卓 Noto / Windows 微软雅黑），不影响渲染。

用法：
    pip install fonttools brotli zopfli
    cd sortr_flutter
    python tools/subset_fonts.py

可重复执行：每次会用原始 .full.ttf 作为输入（首次运行会自动备份）。
"""

import codecs
import re
import shutil
import sys
from pathlib import Path

try:
    from fontTools import subset
except ImportError:
    sys.exit(
        "未找到 fontTools。请先安装：\n    pip install fonttools brotli zopfli"
    )

# ─────────────────────── 路径 ───────────────────────
ROOT = Path(__file__).resolve().parent.parent
FONTS_DIR = ROOT / "assets" / "fonts"
I18N_DIR = ROOT / "lib" / "core" / "i18n"
# 原始全集字体存放处（assets 之外，避免被 pubspec 打进 APK）。
# 注意：pubspec.yaml 的 assets 通配 assets/fonts/ 会打包该目录所有文件，
# 故全集备份绝不能留在 assets/fonts/ 下，否则子集化收益被抵消。
SOURCE_DIR = ROOT / ".font-source"

TARGETS = [
    "HarmonyOS_Sans_SC_Regular.ttf",
    "HarmonyOS_Sans_SC_Bold.ttf",
]


# ─────────────────────── 字符集构建 ───────────────────────
def extract_ui_chars() -> str:
    """从 i18n strings_*.dart 中提取所有单引号字符串字面量的内容。"""
    chars = set()
    # 匹配 'xxx' 字符串（转义后的 \\ 和 \' 已处理）
    str_re = re.compile(r"'((?:\\.|[^'\\])*)'")
    for f in ("strings_zh.dart", "strings_en.dart"):
        text = (I18N_DIR / f).read_text(encoding="utf-8")
        for m in str_re.finditer(text):
            raw = m.group(1)
            # 还原常见转义
            raw = raw.replace(r"\'", "'").replace(r"\\", "\\").replace(r"\n", "\n")
            chars.update(raw)
    return "".join(chars)


def gb2312_chars() -> str:
    """GB2312 一级（3755，区位 16~55）+ 二级（3008，区位 56~87）常用汉字。

    通过 GB2312 编码反查精确枚举，而非取整个 Unicode CJK 段（那样等于没裁剪）。
    一级字覆盖 99.8% 日常中文，二级字覆盖次常用字（用户文件名/相册名会用到）。
    """
    chars = []
    # 一级 + 二级汉字区：区位码第 1 字节 16..87
    for row in range(16, 88):
        for col in range(1, 95):
            try:
                ch = codecs.decode(bytes([row + 0xA0, col + 0xA0]), "gb2312")
                chars.append(ch)
            except (UnicodeDecodeError, ValueError):
                continue
    return "".join(chars)


def punctuation_chars() -> str:
    """常用标点 / 全角符号 / ASCII 可见字符 / 基本拉丁补充。"""
    parts = [
        # ASCII 可见 + 空格
        "".join(chr(c) for c in range(0x20, 0x7F)),
        # 基本拉丁补充（带圈数字、版权符号等）
        "".join(chr(c) for c in range(0xA0, 0x180)),
        # CJK 标点（全角空格、。，、；：？！「」『』（）【】《》……—·）
        "\u3000\u3001\u3002\uff0c\uff0c\u3001\uff1b\uff1a\uff1f\uff01"
        "\u300c\u300d\u300e\u300f\uff08\uff09\u3010\u3011\u300a\u300b"
        "\u2026\u2014\u2014\u00b7\uff5e\uff0f\uff5c",
        # 常用全角数字 / 字母（部分 UI 用到）
        "".join(chr(c) for c in range(0xFF01, 0xFFEF)),  # 半角全角形式
        # 引号变体
        "\u201c\u201d\u2018\u2019\u2022\u25cf",
    ]
    return "".join(parts)


def build_charset() -> set:
    chars = set()
    chars.update(extract_ui_chars())
    chars.update(gb2312_chars())
    chars.update(punctuation_chars())
    return chars


# ─────────────────────── 子集化 ───────────────────────
def subset_one(filename: str, charset: set) -> tuple:
    """对一个字体做子集化。返回 (原大小, 新大小, 原字形数, 新字形数)。"""
    src_full = FONTS_DIR / filename
    backup = SOURCE_DIR / (filename + ".full.ttf")

    # 首次运行：把 assets/fonts 里的原始全集字体备份到 .font-source/
    # （assets 之外，避免被 pubspec 打进 APK）。
    if not backup.exists():
        SOURCE_DIR.mkdir(parents=True, exist_ok=True)
        # 仅当 assets/fonts 下仍是全集（体积 > 5MB）时才备份，
        # 避免把已子集化的版本误当全集备份。
        if src_full.exists() and src_full.stat().st_size > 5 * 1024 * 1024:
            shutil.copy2(src_full, backup)
            print(f"  [备份] {filename} -> .font-source/{backup.name}（原始全集）")
        else:
            sys.exit(
                f"找不到 {filename} 的原始全集。请将完整 HarmonyOS 字体放入\n"
                f"  {SOURCE_DIR}/{filename}.full.ttf\n后重试。"
            )

    # 始终从全集备份读取，保证可重复执行
    input_file = backup

    orig_size = input_file.stat().st_size
    orig_glyphs = _count_glyphs(input_file)

    # 输出到临时文件，成功后替换原文件
    out_tmp = FONTS_DIR / (filename + ".subset.tmp")

    args = [
        f"--output-file={out_tmp}",
        "--glyph-names",
        "--no-hinting",          # 去除 hinting，安卓/Flutter 不需要，省体积
        "--desubroutinize",      # 展开子程序，进一步压缩
        "--drop-tables+=DSIG,MVFK,METF,ByTL",  # 去 HarmonyOS 签名/元数据表
        "--layout-features=*",   # 保留 GSUB/GPOS（粗体替换、合字等）
        "--unicodes=" + ",".join(f"{ord(c):04X}" for c in charset),
        "--notdef-outline",      # 保留 .notdef
        str(input_file),
    ]

    subset.main(args)

    new_size = out_tmp.stat().st_size
    new_glyphs = _count_glyphs(out_tmp)

    # 替换原文件
    shutil.move(str(out_tmp), str(src_full))

    return orig_size, new_size, orig_glyphs, new_glyphs


def _count_glyphs(path: Path) -> int:
    """统计字体字形数（不依赖完整加载，用 ttx 头快速读 glyf/CFF）。"""
    from fontTools.ttLib import TTFont

    try:
        font = TTFont(path, lazy=True, ignoreDecompileErrors=True)
        n = (
            len(font.getGlyphOrder())
            if "glyf" in font or "CFF " in font or "CFF2" in font
            else 0
        )
        font.close()
        return n
    except Exception:
        return -1


# ─────────────────────── 入口 ───────────────────────
def fmt_size(n: int) -> str:
    return f"{n / 1024:.0f} KB" if n < 1024 * 1024 else f"{n / 1024 / 1024:.2f} MB"


def main() -> int:
    if not FONTS_DIR.exists():
        sys.exit(f"字体目录不存在：{FONTS_DIR}")

    print("=== HarmonyOS Sans SC 字体子集化 ===")
    print("构建字符集 …")
    charset = build_charset()
    print(f"  目标字符集大小：{len(charset)} 个唯一字符\n")

    total_orig = 0
    total_new = 0
    for fn in TARGETS:
        src = FONTS_DIR / fn
        if not src.exists():
            print(f"[跳过] {fn} 不存在")
            continue
        print(f"[子集化] {fn}")
        o, n, og, ng = subset_one(fn, charset)
        total_orig += o
        total_new += n
        ratio = (1 - n / o) * 100 if o else 0
        print(
            f"  {fmt_size(o)} -> {fmt_size(n)}  "
            f"(字形 {og} -> {ng}, 缩减 {ratio:.1f}%)\n"
        )

    if total_orig:
        total_ratio = (1 - total_new / total_orig) * 100
        print("=== 汇总 ===")
        print(f"  合计：{fmt_size(total_orig)} -> {fmt_size(total_new)}")
        print(f"  总缩减：{total_ratio:.1f}%")
        print("\n提示：原始全集存放在 .font-source/（已加入 .gitignore，且在 assets 之外不会被打包）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
