#!/usr/bin/env python3
"""Generate Android + Windows app icons from assets/icon/visort.png.

Android:
  - legacy mipmap ic_launcher.png (48dp base, full-bleed logo) for API < 26
  - adaptive icon: mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_foreground.png
    (108dp; logo scaled into the 66% safe zone on a pure-black canvas so circular
    masks only crop black border, keeping the green "V" intact)
Windows:
  - windows/runner/resources/app_icon.ico (multi-size, full-bleed)

Idempotent — re-run after replacing assets/icon/visort.png. Requires Pillow.
"""
from PIL import Image
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # visort_flutter/
SRC = ROOT / "assets" / "icon" / "visort.png"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
WINDOWS_RES = ROOT / "windows" / "runner" / "resources"

DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
SAFE_ZONE = 0.66  # adaptive foreground content ratio (66% of 108dp keyline)


def main():
    if not SRC.exists():
        raise SystemExit(f"source icon not found: {SRC}")
    logo = Image.open(SRC).convert("RGBA")
    print(f"source: {SRC.name} {logo.size} {logo.mode}")

    # 1. legacy ic_launcher (48dp) — full-bleed logo, square, no crop
    for d, scale in DENSITIES.items():
        sz = round(48 * scale)
        out = ANDROID_RES / f"mipmap-{d}" / "ic_launcher.png"
        logo.resize((sz, sz), Image.LANCZOS).save(out)
        print(f"  legacy  {d:8} {sz:>3}x{sz:<3} -> {out.relative_to(ROOT)}")

    # 2. adaptive foreground (108dp) — logo into 66% safe zone on black canvas
    for d, scale in DENSITIES.items():
        canvas = round(108 * scale)
        content = round(canvas * SAFE_ZONE)
        fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 255))
        small = logo.resize((content, content), Image.LANCZOS)
        fg.paste(small, ((canvas - content) // 2, (canvas - content) // 2))
        out = ANDROID_RES / f"mipmap-{d}" / "ic_launcher_foreground.png"
        fg.save(out)
        print(f"  fg      {d:8} {canvas:>3}x{canvas:<3} -> {out.relative_to(ROOT)}")

    # 3. adaptive icon descriptor (anydpi-v26)
    v26 = ANDROID_RES / "mipmap-anydpi-v26"
    v26.mkdir(parents=True, exist_ok=True)
    (v26 / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
        encoding="utf-8",
    )
    print(f"  adaptive xml      -> {(v26 / 'ic_launcher.xml').relative_to(ROOT)}")

    # 4. Windows ICO (multi-size, full-bleed; square, no crop)
    ico_sizes = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)]
    WINDOWS_RES.mkdir(parents=True, exist_ok=True)
    ico_path = WINDOWS_RES / "app_icon.ico"
    logo.save(ico_path, format="ICO", sizes=ico_sizes)
    print(f"  windows ico       -> {ico_path.relative_to(ROOT)}")
    print("done.")


if __name__ == "__main__":
    main()
