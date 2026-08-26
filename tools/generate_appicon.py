#!/usr/bin/env python3
"""Generate the BatteryHolder app icon in all iOS sizes.

Design language: 3D + iOS "glass" + electronic.
  - deep electric-blue radial background with faint circuit traces
  - a glossy translucent (glass) battery with a green energy fill
  - a bright lightning bolt with an outer glow
  - specular highlights and a soft drop shadow for depth

The master is rendered supersampled once, then downscaled to every icon
size with Lanczos for crisp edges. All outputs are flattened to opaque RGB
(App Store icons may not contain an alpha channel).

Run:  python3 tools/generate_appicon.py
Deps: Pillow  (pip install Pillow)
"""

import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

MASTER = 2048  # supersampled master edge in px
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APPICONSET = os.path.join(
    REPO, "ios", "BatteryHolder", "Resources",
    "Assets.xcassets", "AppIcon.appiconset",
)
BRANDING = os.path.join(REPO, "docs", "branding")

# ---- palette -------------------------------------------------------------
BG_TOP = (14, 32, 82)      # electric indigo
BG_MID = (9, 20, 56)
BG_BOT = (3, 6, 16)        # near black
GLOW = (10, 132, 255)      # brand blue
TRACE = (78, 138, 226)
GLASS_LO = (36, 60, 120)
GLASS_HI = (208, 230, 255)
BORDER = (150, 190, 255)
ENERGY_TOP = (74, 232, 140)
ENERGY_BOT = (18, 150, 82)
BOLT_TOP = (255, 255, 255)
BOLT_BOT = (255, 202, 60)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def vertical_gradient(size, stops):
    """stops: list of (pos0..1, rgb). Returns an RGB image."""
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    # precompute one column then broadcast
    col = []
    for y in range(h):
        t = y / (h - 1)
        # find segment
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                lt = (t - p0) / (p1 - p0) if p1 > p0 else 0
                col.append(lerp(c0, c1, lt))
                break
        else:
            col.append(stops[-1][1])
    for y in range(h):
        c = col[y]
        for x in range(w):
            px[x, y] = c
    return img


def radial_glow(size, inner, outer, cx=0.5, cy=0.42, radius=0.75, res=512):
    """A radial gradient rendered small then upscaled (cheap + smooth)."""
    small = Image.new("RGB", (res, res))
    px = small.load()
    icx, icy = cx * res, cy * res
    maxr = radius * res
    for y in range(res):
        for x in range(res):
            d = math.hypot(x - icx, y - icy) / maxr
            d = min(1.0, d)
            px[x, y] = lerp(inner, outer, d)
    return small.resize(size, Image.LANCZOS)


def add_circuit(img, seed=7, count=22):
    """Draw faint circuit traces on a transparent overlay, blurred slightly."""
    W, H = img.size
    C = min(W, H)
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    rnd = random.Random(seed)
    lw = max(2, C // 340)
    for _ in range(count):
        x = rnd.randint(0, W)
        y = rnd.randint(0, H)
        pts = [(x, y)]
        for _ in range(rnd.randint(2, 4)):
            if rnd.random() < 0.5:
                x = min(W, max(0, x + rnd.choice([-1, 1]) * rnd.randint(C // 12, C // 4)))
            else:
                y = min(H, max(0, y + rnd.choice([-1, 1]) * rnd.randint(C // 12, C // 4)))
            pts.append((x, y))
        d.line(pts, fill=(*TRACE, 60), width=lw, joint="curve")
        for p in pts:
            r = lw * 1.8
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=(*TRACE, 90))
    ov = ov.filter(ImageFilter.GaussianBlur(C // 900))
    img.paste(ov, (0, 0), ov)
    return img


def rrect_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def render_glyph(C):
    """The glass battery + bolt mark alone, on a transparent C x C canvas."""
    base = Image.new("RGBA", (C, C), (0, 0, 0, 0))

    cx = C / 2
    body_w, body_h = 0.40 * C, 0.54 * C
    bx0, by0 = cx - body_w / 2, 0.25 * C
    bx1, by1 = cx + body_w / 2, by0 + body_h
    rad = 0.075 * C

    # --- drop shadow for depth ---
    shadow = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ds = ImageDraw.Draw(shadow)
    off = int(0.02 * C)
    ds.rounded_rectangle([bx0, by0 + off, bx1, by1 + off], radius=rad,
                         fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(C // 55))
    base.alpha_composite(shadow)

    # --- battery terminal (nub on top) ---
    tw, th = 0.16 * C, 0.05 * C
    term = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    dt = ImageDraw.Draw(term)
    dt.rounded_rectangle([cx - tw / 2, by0 - th, cx + tw / 2, by0 + rad],
                         radius=th / 2, fill=(*lerp(GLASS_HI, GLASS_LO, 0.4), 255))
    base.alpha_composite(term)

    # --- glass body: translucent gradient inside a rounded rect ---
    body_grad = vertical_gradient(
        (int(body_w), int(body_h)),
        [(0.0, GLASS_HI), (0.5, GLASS_LO), (1.0, (18, 30, 66))],
    ).convert("RGBA")
    # translucency
    alpha = Image.new("L", body_grad.size, 150)
    body_grad.putalpha(alpha)
    bmask = Image.new("L", body_grad.size, 0)
    ImageDraw.Draw(bmask).rounded_rectangle(
        [0, 0, body_grad.size[0] - 1, body_grad.size[1] - 1], radius=rad, fill=255)
    base.paste(body_grad, (int(bx0), int(by0)), Image.composite(
        body_grad.split()[3], Image.new("L", body_grad.size, 0), bmask))

    # --- energy fill (charge) inside the body ---
    inset = 0.028 * C
    fx0, fx1 = bx0 + inset, bx1 - inset
    ftop = by0 + body_h * 0.36
    fbot = by1 - inset
    fw, fh = int(fx1 - fx0), int(fbot - ftop)
    if fw > 0 and fh > 0:
        efill = vertical_gradient((fw, fh), [(0.0, ENERGY_TOP), (1.0, ENERGY_BOT)]).convert("RGBA")
        emask = Image.new("L", (fw, fh), 0)
        ImageDraw.Draw(emask).rounded_rectangle(
            [0, 0, fw - 1, fh - 1], radius=rad * 0.7, fill=235)
        base.paste(efill, (int(fx0), int(ftop)), emask)
        # meniscus highlight line at the top of the fill
        gl = Image.new("RGBA", (C, C), (0, 0, 0, 0))
        ImageDraw.Draw(gl).line([(fx0 + rad * 0.4, ftop + 3), (fx1 - rad * 0.4, ftop + 3)],
                                fill=(230, 255, 240, 200), width=max(2, C // 260))
        gl = gl.filter(ImageFilter.GaussianBlur(C // 1400))
        base.alpha_composite(gl)

    # --- rim light / border ---
    rim = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([bx0, by0, bx1, by1], radius=rad,
                                          outline=(*BORDER, 210), width=max(3, C // 300))
    base.alpha_composite(rim)

    # --- top specular glass sheen (hugs the top curve) ---
    clip = rrect_mask((C, C), [bx0, by0, bx1, by1], rad)
    spec = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(spec).ellipse(
        [bx0 - body_w * 0.15, by0 - body_h * 0.20,
         bx1 + body_w * 0.15, by0 + body_h * 0.24],
        fill=(255, 255, 255, 165))
    spec = spec.filter(ImageFilter.GaussianBlur(C // 70))
    spec.putalpha(Image.composite(spec.split()[3], Image.new("L", (C, C), 0), clip))
    base.alpha_composite(spec)

    # --- diagonal glass reflection streak ---
    streak = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(streak).polygon(
        [(bx0 + body_w * 0.10, by0), (bx0 + body_w * 0.36, by0),
         (bx0 + body_w * 0.12, by1), (bx0 - body_w * 0.04, by1)],
        fill=(255, 255, 255, 42))
    streak = streak.filter(ImageFilter.GaussianBlur(C // 240))
    streak.putalpha(Image.composite(streak.split()[3], Image.new("L", (C, C), 0), clip))
    base.alpha_composite(streak)

    # --- lightning bolt with glow (kept inside the body) ---
    bolt = bolt_polygon(cx, 0.50 * C, 0.145 * C, 0.265 * C)
    # glow
    glowlayer = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(glowlayer).polygon(bolt, fill=(255, 220, 120, 255))
    glowlayer = glowlayer.filter(ImageFilter.GaussianBlur(C // 60))
    base.alpha_composite(glowlayer)
    # bolt gradient fill via masked paste
    bmin_y = min(p[1] for p in bolt)
    bmax_y = max(p[1] for p in bolt)
    bg2 = vertical_gradient((C, C), [(0.0, BOLT_TOP), (1.0, BOLT_BOT)]).convert("RGBA")
    bmask2 = Image.new("L", (C, C), 0)
    ImageDraw.Draw(bmask2).polygon(bolt, fill=255)
    base.paste(bg2, (0, 0), bmask2)
    # bolt inner highlight edge
    edge = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    ImageDraw.Draw(edge).polygon(bolt, outline=(255, 255, 255, 220), width=max(2, C // 340))
    base.alpha_composite(edge)

    return base


def render_master():
    C = MASTER
    # --- background: vertical gradient + radial brand glow (screened in) ---
    bg = vertical_gradient((C, C), [(0.0, BG_TOP), (0.55, BG_MID), (1.0, BG_BOT)])
    glow = radial_glow((C, C), GLOW, (0, 0, 0), cx=0.5, cy=0.40, radius=0.85)
    bg = ImageChops_screen(bg, glow)
    bg = add_circuit(bg)

    base = bg.convert("RGBA")
    base.alpha_composite(render_glyph(C))

    # flatten to opaque RGB
    return base.convert("RGB")


def bolt_polygon(cx, cy, hw, hh):
    """A classic lightning bolt centered at (cx, cy), half-width hw, half-height hh."""
    # normalized points (x in [-1,1], y in [-1,1]) tuned to look balanced
    pts = [
        (0.15, -1.00),
        (-0.55, 0.12),
        (-0.08, 0.12),
        (-0.30, 1.00),
        (0.58, -0.18),
        (0.06, -0.18),
        (0.52, -1.00),
    ]
    return [(cx + x * hw * 1.6, cy + y * hh) for (x, y) in pts]


def ImageChops_screen(a, b):
    from PIL import ImageChops
    return ImageChops.screen(a, b)


# iOS AppIcon size table: (idiom, pointsize, scale, pixel)
ENTRIES = [
    ("iphone", "20x20", "2x", 40),
    ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58),
    ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80),
    ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120),
    ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20),
    ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29),
    ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40),
    ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76),
    ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def main():
    os.makedirs(APPICONSET, exist_ok=True)
    os.makedirs(BRANDING, exist_ok=True)

    print("Rendering master (%dpx)..." % MASTER)
    master = render_master()
    master1024 = master.resize((1024, 1024), Image.LANCZOS)

    # generate unique pixel sizes
    sizes = sorted({px for *_, px in ENTRIES})
    files = {}
    for px in sizes:
        name = "AppIcon-%d.png" % px
        img = master1024 if px == 1024 else master1024.resize((px, px), Image.LANCZOS)
        img.save(os.path.join(APPICONSET, name), "PNG")
        files[px] = name
        print("  wrote", name)

    images = [{
        "idiom": idiom,
        "size": size,
        "scale": scale,
        "filename": files[px],
    } for (idiom, size, scale, px) in ENTRIES]

    with open(os.path.join(APPICONSET, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    print("  wrote Contents.json")

    # branding preview (for docs / sharing)
    master1024.save(os.path.join(BRANDING, "app-icon-1024.png"), "PNG")
    print("  wrote docs/branding/app-icon-1024.png")

    # Google Play Store hi-res listing icon: 512x512, 32-bit PNG, <=1 MB.
    # Play's uploader requires an alpha channel (opaque here — no transparency
    # in the actual artwork, just the RGBA format Play expects).
    master512 = master1024.resize((512, 512), Image.LANCZOS).convert("RGBA")
    play_icon_path = os.path.join(BRANDING, "app-icon-512.png")
    master512.save(play_icon_path, "PNG", optimize=True)
    size_kb = os.path.getsize(play_icon_path) / 1024
    print("  wrote docs/branding/app-icon-512.png (%.0f KB)" % size_kb)


if __name__ == "__main__":
    main()
