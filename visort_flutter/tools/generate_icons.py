#!/usr/bin/env python3
"""Generate Android + Windows app icons from assets/icon/visort.png.

Android:
  - legacy mipmap ic_launcher.png (48dp base, full-bleed logo) for API < 26
  - adaptive icon: mipmap-anydpi-v26/ic_launcher.xml + two layers (108dp each):
      background  — radial charcoal gradient + app-noise grain, full-bleed texture
      foreground  — logo knocked out to transparency (black -> alpha), scaled into
                    the 66% safe zone; "VST" is vertically centered in the source
Windows:
  - windows/runner/resources/app_icon.ico (multi-size, full-bleed)

Idempotent — re-run after replacing assets/icon/visort.png. Requires Pillow.
"""
import numpy as np
from PIL import Image
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # visort_flutter/
SRC = ROOT / "assets" / "icon" / "visort.png"
NOISE = ROOT / "assets" / "images" / "noise.png"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
WINDOWS_RES = ROOT / "windows" / "runner" / "resources"

DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
SAFE_ZONE = 0.66  # adaptive foreground content ratio (66% of 108dp keyline)


def make_bg(size, strength=0.05):
    """Icon background texture: radial charcoal gradient (#1B1B1B -> #0A0A0A)
    overlaid with the app's own noise.png grain (same WithNoise aesthetic)."""
    yy, xx = np.mgrid[0:size, 0:size].astype(float)
    c = (size - 1) / 2
    r = np.clip(np.sqrt((xx - c) ** 2 + (yy - c) ** 2) / (size * 0.72), 0, 1)
    base = 27 * (1 - r) + 10 * r
    grain = np.array(Image.open(NOISE).convert("RGBA"))[:, :, 3].astype(float) / 255 * strength
    rep = -(-size // grain.shape[0])
    tiled = np.tile(grain, (rep, rep))[:size, :size]
    rgb = (base + (255 - base) * tiled).clip(0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([rgb] * 3 + [np.full((size, size), 255, np.uint8)]))


def knockout(img):
    """Black background -> transparent (luminance-derived alpha), so the logo
    layer composites cleanly over the textured background without a seam."""
    a = np.array(img.convert("RGBA")).astype(int)
    lum = a[:, :, :3].max(axis=2)
    a[:, :, 3] = np.clip((lum - 15) * 2.2, 0, 255).astype(np.uint8)
    return Image.fromarray(a.astype(np.uint8))


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

    # 2. adaptive background (108dp) — full-bleed charcoal texture
    for d, scale in DENSITIES.items():
        canvas = round(108 * scale)
        out = ANDROID_RES / f"mipmap-{d}" / "ic_launcher_background.png"
        make_bg(canvas).save(out)
        print(f"  bg      {d:8} {canvas:>3}x{canvas:<3} -> {out.relative_to(ROOT)}")

    # 3. adaptive foreground (108dp) — transparent logo into 66% safe zone
    clear = knockout(logo)
    for d, scale in DENSITIES.items():
        canvas = round(108 * scale)
        content = round(canvas * SAFE_ZONE)
        fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        small = clear.resize((content, content), Image.LANCZOS)
        fg.alpha_composite(small, ((canvas - content) // 2, (canvas - content) // 2))
        out = ANDROID_RES / f"mipmap-{d}" / "ic_launcher_foreground.png"
        fg.save(out)
        print(f"  fg      {d:8} {canvas:>3}x{canvas:<3} -> {out.relative_to(ROOT)}")

    # 4. adaptive icon descriptor (anydpi-v26)
    v26 = ANDROID_RES / "mipmap-anydpi-v26"
    v26.mkdir(parents=True, exist_ok=True)
    (v26 / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
        encoding="utf-8",
    )
    print(f"  adaptive xml      -> {(v26 / 'ic_launcher.xml').relative_to(ROOT)}")

    # 5. Windows ICO (multi-size, full-bleed; square, no crop)
    ico_sizes = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)]
    WINDOWS_RES.mkdir(parents=True, exist_ok=True)
    ico_path = WINDOWS_RES / "app_icon.ico"
    logo.save(ico_path, format="ICO", sizes=ico_sizes)
    print(f"  windows ico       -> {ico_path.relative_to(ROOT)}")
    print("done.")


if __name__ == "__main__":
    main()
