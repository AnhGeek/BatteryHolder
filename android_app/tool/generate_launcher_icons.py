#!/usr/bin/env python3
"""Generate the Android launcher icons from the same artwork as iOS.

The master render lives in `tools/generate_appicon.py` — this script imports it
so both platforms stay pixel-identical instead of drifting apart.

Outputs, under android_app/android/app/src/main/res/:
  mipmap-*/ic_launcher.png             legacy square icon (API 25 and below)
  mipmap-*/ic_launcher_foreground.png  adaptive foreground, art in the safe zone
  mipmap-anydpi-v26/ic_launcher.xml    adaptive icon declaration
  values/ic_launcher_background.xml    adaptive background color

Adaptive icons are a 108dp canvas whose outer 18dp on each side can be cropped
by the launcher's mask, so the art is scaled into the inner 72dp safe zone.

Run:  python android_app/tool/generate_launcher_icons.py
Deps: Pillow  (pip install Pillow)
"""

import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ANDROID_APP = os.path.dirname(HERE)
REPO = os.path.dirname(ANDROID_APP)
RES = os.path.join(ANDROID_APP, "android", "app", "src", "main", "res")

sys.path.insert(0, os.path.join(REPO, "tools"))
from generate_appicon import render_master  # noqa: E402

# Matches the iOS LaunchBackground colorset and the splash gradient's mid stop.
BACKGROUND_HEX = "#FF091438"

# density -> (legacy icon px, adaptive layer px)
DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

# The 72dp safe zone as a fraction of the 108dp adaptive canvas.
SAFE_ZONE = 72 / 108


def write(path, image):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, "PNG")
    print("  wrote", os.path.relpath(path, REPO))


def main():
    print("Rendering master...")
    master = render_master().convert("RGBA").resize((1024, 1024), Image.LANCZOS)

    for density, (legacy_px, adaptive_px) in DENSITIES.items():
        folder = os.path.join(RES, "mipmap-" + density)

        write(os.path.join(folder, "ic_launcher.png"),
              master.resize((legacy_px, legacy_px), Image.LANCZOS))

        # Adaptive foreground: art centered in the safe zone, transparent around
        # it so the launcher's mask only ever crops empty padding.
        art_px = int(round(adaptive_px * SAFE_ZONE))
        layer = Image.new("RGBA", (adaptive_px, adaptive_px), (0, 0, 0, 0))
        offset = (adaptive_px - art_px) // 2
        layer.paste(master.resize((art_px, art_px), Image.LANCZOS), (offset, offset))
        write(os.path.join(folder, "ic_launcher_foreground.png"), layer)

    anydpi = os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml")
    os.makedirs(os.path.dirname(anydpi), exist_ok=True)
    with open(anydpi, "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background" />\n'
            '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
            '</adaptive-icon>\n'
        )
    print("  wrote", os.path.relpath(anydpi, REPO))

    colors = os.path.join(RES, "values", "ic_launcher_background.xml")
    with open(colors, "w", encoding="utf-8") as f:
        f.write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources>\n'
            '    <!-- Mirrors the iOS LaunchBackground colorset. -->\n'
            '    <color name="ic_launcher_background">%s</color>\n'
            '</resources>\n' % BACKGROUND_HEX
        )
    print("  wrote", os.path.relpath(colors, REPO))


if __name__ == "__main__":
    main()
