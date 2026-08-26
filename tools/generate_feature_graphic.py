#!/usr/bin/env python3
"""Generate the Google Play Store feature graphic.

Spec (Play Console "Main store listing" > Graphics):
  1024 x 500, JPEG or 24-bit PNG, no alpha/transparency.
Guidance: keep the focal point centered (edges can get cropped in some
placements), avoid pure white / dark gray backgrounds, no device frames,
no badges or store-rating iconography.

Reuses the same background palette and battery+bolt glyph as the app icon
(tools/generate_appicon.py) so the store listing matches the app itself
instead of drifting into separate artwork.

Run:  python3 tools/generate_feature_graphic.py
Deps: Pillow  (pip install Pillow)
"""

import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from generate_appicon import (
    BG_BOT, BG_MID, BG_TOP, GLOW, add_circuit, render_glyph,
    vertical_gradient, ImageChops_screen,
)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BRANDING = os.path.join(REPO, "docs", "branding")

W, H = 1024, 500
SS = 2  # supersample factor for crisp text/edges, downscaled at the end

FONT_BOLD = r"C:\Windows\Fonts\segoeuib.ttf"
FONT_REGULAR = r"C:\Windows\Fonts\segoeui.ttf"

TITLE = "BatteryHolder"
TAGLINE = "Monitor & flash ESP32 / ESP8266 battery boards"


def fit_font(path, text, max_width, start_size, min_size=10):
    """Largest truetype size (<= start_size) whose text fits max_width."""
    size = start_size
    tmp = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    while size > min_size:
        font = ImageFont.truetype(path, size)
        w = tmp.textbbox((0, 0), text, font=font)[2]
        if w <= max_width:
            return font
        size -= 2
    return ImageFont.truetype(path, min_size)


# ---- ESP dev boards ------------------------------------------------------
# Two of the boards the app actually talks to, drawn as small PCB
# illustrations so the listing shows the hardware, not just the wordmark.
PCB_TOP = (26, 92, 68)     # green solder mask, lit edge
PCB_BOT = (12, 54, 42)
PIN_HI = (255, 214, 128)   # gold header pads
PIN_LO = (176, 132, 52)
SHIELD_HI = (226, 234, 244)
SHIELD_LO = (140, 152, 170)
SILK = (232, 242, 255)


def _rrect(draw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def render_board(width, label, aspect, ss=3):
    """One ESP dev board, seen flat-on. Returns RGBA sized to fit the board.

    width  -- final board width in px
    label  -- silkscreen text on the RF shield ("ESP32" / "ESP8266")
    aspect -- height / width of the PCB
    """
    w = width * ss
    h = int(round(w * aspect))
    pad = int(w * 0.10)  # room for the drop shadow
    img = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x0, y0 = pad, pad
    x1, y1 = pad + w, pad + h
    r = int(w * 0.05)

    # PCB body, with a vertical gradient so it reads as lit from above
    body = vertical_gradient((w, h), [(0.0, PCB_TOP), (1.0, PCB_BOT)]).convert("RGBA")
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255)
    img.paste(body, (x0, y0), mask)
    d.rounded_rectangle((x0, y0, x1 - 1, y1 - 1), radius=r,
                        outline=(150, 214, 186, 130), width=max(1, ss))

    # gold pin headers down both long edges
    pitch = w / 13.0
    ph = int(h * 0.055)
    pw = int(pitch * 0.52)
    for i in range(12):
        px = x0 + int(pitch * (i + 0.74))
        for py in (y0 + int(h * 0.035), y1 - int(h * 0.035) - ph):
            _rrect(d, (px, py, px + pw, py + ph), max(1, ss),
                   fill=PIN_HI, outline=PIN_LO, width=max(1, ss // 2))

    # RF shield can with the chip name etched on it
    sx0 = x0 + int(w * 0.20)
    sx1 = x1 - int(w * 0.20)
    sy0 = y0 + int(h * 0.20)
    sy1 = y0 + int(h * 0.62)
    shield = vertical_gradient((sx1 - sx0, sy1 - sy0),
                               [(0.0, SHIELD_HI), (1.0, SHIELD_LO)]).convert("RGBA")
    smask = Image.new("L", shield.size, 0)
    ImageDraw.Draw(smask).rounded_rectangle(
        (0, 0, shield.size[0] - 1, shield.size[1] - 1), radius=int(w * 0.02), fill=255)
    img.paste(shield, (sx0, sy0), smask)
    d.rounded_rectangle((sx0, sy0, sx1, sy1), radius=int(w * 0.02),
                        outline=(96, 108, 126, 200), width=max(1, ss))
    # the PCB antenna trace above the can
    ax0, ax1 = x0 + int(w * 0.30), x1 - int(w * 0.30)
    ay = y0 + int(h * 0.135)
    step = (ax1 - ax0) / 6.0
    zig = []
    for i in range(7):
        zig.append((ax0 + step * i, ay - (int(h * 0.045) if i % 2 else 0)))
    d.line(zig, fill=(226, 236, 250, 210), width=max(2, int(ss * 1.6)), joint="curve")

    lab = fit_font(FONT_BOLD, label, (sx1 - sx0) * 0.74, int((sy1 - sy0) * 0.42))
    lb = d.textbbox((0, 0), label, font=lab)
    d.text((((sx0 + sx1) - (lb[2] - lb[0])) // 2, ((sy0 + sy1) - (lb[3] - lb[1])) // 2 - lb[1]),
           label, font=lab, fill=(58, 70, 88, 255))

    # micro-USB shell and a lit status LED along the bottom edge
    ux0 = x0 + int(w * 0.40)
    ux1 = x1 - int(w * 0.40)
    uy1 = y1 - int(h * 0.10)
    uy0 = uy1 - int(h * 0.14)
    _rrect(d, (ux0, uy0, ux1, uy1), int(w * 0.012),
           fill=(196, 206, 220, 255), outline=(120, 132, 150, 255), width=max(1, ss))
    lr = int(w * 0.018)
    lx = x0 + int(w * 0.14)
    ly = y1 - int(h * 0.17)
    d.ellipse((lx - lr, ly - lr, lx + lr, ly + lr), fill=(120, 255, 176, 255))

    # soft drop shadow under the board
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x0, y0 + int(h * 0.06), x1, y1 + int(h * 0.06)), radius=r, fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(w * 0.035)))
    out = Image.alpha_composite(shadow, img)

    return out.resize((out.size[0] // ss, out.size[1] // ss), Image.LANCZOS)


def render():
    w, h = W * SS, H * SS
    margin = int(w * 0.055)

    # --- background: same vertical gradient + brand glow as the icon ---
    bg = vertical_gradient((w, h), [(0.0, BG_TOP), (0.55, BG_MID), (1.0, BG_BOT)])
    glow = radial_glow_rect((w, h), GLOW, (0, 0, 0), cx=0.22, cy=0.5, radius=0.9)
    bg = ImageChops_screen(bg, glow)
    bg = add_circuit(bg, seed=11, count=16)
    base = bg.convert("RGBA")

    # --- glyph: the glass battery + bolt, left side, vertically centered ---
    glyph_px = int(h * 0.82)
    glyph = render_glyph(glyph_px)
    gx = margin
    gy = (h - glyph_px) // 2
    base.alpha_composite(glyph, (gx, gy))

    # --- wordmark + tagline, right of the glyph ---
    text_x = gx + glyph_px + int(w * 0.05)
    max_text_w = w - margin - text_x
    draw = ImageDraw.Draw(base)

    title_font = fit_font(FONT_BOLD, TITLE, max_text_w, int(h * 0.20))
    tagline_font = fit_font(FONT_REGULAR, TAGLINE, max_text_w, int(h * 0.075))

    title_h = draw.textbbox((0, 0), TITLE, font=title_font)[3]
    tagline_h = draw.textbbox((0, 0), TAGLINE, font=tagline_font)[3]

    # the two supported boards, tilted, sitting under the tagline
    board_w = int(max_text_w * 0.34)
    boards = [
        render_board(board_w, "ESP32", 0.62).rotate(7, Image.BICUBIC, expand=True),
        render_board(int(board_w * 0.84), "ESP8266", 0.72).rotate(-6, Image.BICUBIC, expand=True),
    ]
    board_gap = int(w * 0.022)
    row_w = sum(b.size[0] for b in boards) + board_gap * (len(boards) - 1)
    row_h = max(b.size[1] for b in boards)

    gap = int(h * 0.05)
    board_gap_top = int(h * 0.07)
    block_h = title_h + gap + tagline_h + board_gap_top + row_h
    title_y = (h - block_h) // 2
    tagline_y = title_y + title_h + gap
    row_top = tagline_y + tagline_h + board_gap_top

    draw.text((text_x, title_y), TITLE, font=title_font, fill=(255, 255, 255, 255))
    draw.text((text_x, tagline_y), TAGLINE, font=tagline_font, fill=(196, 214, 255, 235))

    bx = text_x + (max_text_w - row_w) // 2
    for b in boards:
        base.alpha_composite(b, (bx, row_top + (row_h - b.size[1]) // 2))
        bx += b.size[0] + board_gap

    out = base.convert("RGB").resize((W, H), Image.LANCZOS)
    return out


def radial_glow_rect(size, inner, outer, cx, cy, radius, res=512):
    """Same idea as generate_appicon.radial_glow but for a non-square target."""
    from math import hypot
    small = Image.new("RGB", (res, res))
    px = small.load()
    icx, icy = cx * res, cy * res
    maxr = radius * res
    for y in range(res):
        for x in range(res):
            d = min(1.0, hypot(x - icx, y - icy) / maxr)
            px[x, y] = tuple(int(round(inner[i] + (outer[i] - inner[i]) * d)) for i in range(3))
    return small.resize(size, Image.LANCZOS)


def main():
    os.makedirs(BRANDING, exist_ok=True)
    print("Rendering feature graphic (%dx%d @ %dx supersample)..." % (W, H, SS))
    img = render()
    path = os.path.join(BRANDING, "feature-graphic-1024x500.png")
    img.save(path, "PNG", optimize=True)
    print("  wrote docs/branding/feature-graphic-1024x500.png (mode=%s, %.0f KB)"
          % (img.mode, os.path.getsize(path) / 1024))


if __name__ == "__main__":
    main()
