#!/usr/bin/env python3
"""Generate recall app icon — rec all: record everything.
v2: More dramatic, higher contrast, cooler look."""

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math

SIZE = 1024
CENTER = SIZE // 2

# Colors
CYAN = (0, 240, 255)
WHITE = (255, 255, 255)


def draw_arc(draw, cx, cy, radius, width, start_deg, end_deg, color):
    bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(bbox, start_deg, end_deg, fill=color, width=width)


def glow_circle(size, cx, cy, radius, color_rgba, blur):
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=color_rgba)
    return layer.filter(ImageFilter.GaussianBlur(blur))


def glow_ring(size, cx, cy, radius, width, color_rgba, blur):
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        outline=color_rgba, width=width
    )
    return layer.filter(ImageFilter.GaussianBlur(blur))


def main():
    comp = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 255))

    # === Deep background glow (subtle atmosphere) ===
    comp = Image.alpha_composite(comp, glow_circle(SIZE, CENTER, CENTER, 450, (0, 30, 40, 50), 250))
    comp = Image.alpha_composite(comp, glow_circle(SIZE, CENTER, CENTER, 280, (0, 50, 60, 40), 150))

    # === Outer ring glows (soft halos) ===
    for r, a, b in [(370, 12, 50), (300, 16, 35), (230, 20, 25), (160, 30, 18)]:
        comp = Image.alpha_composite(comp, glow_ring(SIZE, CENTER, CENTER, r, 20, (0, 240, 255, a), b))

    # === HUD ring segments ===
    ring_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring_layer)

    # Ring 1 (outermost) — thin, subtle, 4 segments
    r1 = 400
    for s, e in [(5, 85), (95, 175), (185, 265), (275, 355)]:
        draw_arc(rd, CENTER, CENTER, r1, 2, s, e, (0, 180, 200, 100))

    # Ring 2 — medium
    r2 = 350
    for s, e in [(15, 115), (135, 235), (255, 345)]:
        draw_arc(rd, CENTER, CENTER, r2, 3, s, e, (0, 200, 220, 140))

    # Ring 3 — brighter, wider segments
    r3 = 285
    for s, e in [(0, 100), (130, 240), (265, 355)]:
        draw_arc(rd, CENTER, CENTER, r3, 4, s, e, (0, 220, 240, 180))

    # Ring 4 — bright, thick
    r4 = 220
    for s, e in [(10, 150), (190, 340)]:
        draw_arc(rd, CENTER, CENTER, r4, 5, s, e, (0, 240, 255, 210))

    # Ring 5 (inner) — brightest
    r5 = 155
    for s, e in [(30, 170), (210, 350)]:
        draw_arc(rd, CENTER, CENTER, r5, 5, s, e, (0, 240, 255, 240))

    comp = Image.alpha_composite(comp, ring_layer)

    # === Tick marks on outermost ring (HUD precision detail) ===
    tick_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    td = ImageDraw.Draw(tick_layer)
    for deg in range(0, 360, 10):
        rad = math.radians(deg)
        is_major = deg % 30 == 0
        r_in = 392 if is_major else 395
        r_out = 410 if is_major else 406
        alpha = 100 if is_major else 40
        w = 2 if is_major else 1
        x1 = CENTER + r_in * math.cos(rad)
        y1 = CENTER + r_in * math.sin(rad)
        x2 = CENTER + r_out * math.cos(rad)
        y2 = CENTER + r_out * math.sin(rad)
        td.line([(x1, y1), (x2, y2)], fill=(0, 240, 255, alpha), width=w)
    comp = Image.alpha_composite(comp, tick_layer)

    # === Radial data lines (subtle, emanating from center) ===
    radial_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    rld = ImageDraw.Draw(radial_layer)
    for deg in [45, 135, 225, 315]:
        rad = math.radians(deg)
        x1 = CENTER + 110 * math.cos(rad)
        y1 = CENTER + 110 * math.sin(rad)
        x2 = CENTER + 145 * math.cos(rad)
        y2 = CENTER + 145 * math.sin(rad)
        rld.line([(x1, y1), (x2, y2)], fill=(0, 240, 255, 50), width=2)
    comp = Image.alpha_composite(comp, radial_layer)

    # === Center REC dot — the hero element ===

    # Large soft glow
    comp = Image.alpha_composite(comp, glow_circle(SIZE, CENTER, CENTER, 100, (0, 240, 255, 60), 60))
    # Medium glow
    comp = Image.alpha_composite(comp, glow_circle(SIZE, CENTER, CENTER, 70, (0, 240, 255, 120), 30))
    # Tight glow
    comp = Image.alpha_composite(comp, glow_circle(SIZE, CENTER, CENTER, 50, (0, 240, 255, 180), 15))

    draw = ImageDraw.Draw(comp)

    # Solid dot
    dot_r = 55
    draw.ellipse(
        [CENTER - dot_r, CENTER - dot_r, CENTER + dot_r, CENTER + dot_r],
        fill=(0, 240, 255, 255)
    )

    # Inner gradient ring (darker ring inside the dot for depth)
    inner_ring_r = 45
    draw.ellipse(
        [CENTER - inner_ring_r, CENTER - inner_ring_r,
         CENTER + inner_ring_r, CENTER + inner_ring_r],
        fill=(100, 250, 255, 240)
    )

    # Bright center
    bright_r = 30
    draw.ellipse(
        [CENTER - bright_r, CENTER - bright_r,
         CENTER + bright_r, CENTER + bright_r],
        fill=(200, 255, 255, 250)
    )

    # White hot core
    core_r = 14
    draw.ellipse(
        [CENTER - core_r, CENTER - core_r,
         CENTER + core_r, CENTER + core_r],
        fill=(255, 255, 255, 255)
    )

    # Recording indicator ring (tight circle around dot)
    rec_ring_r = 80
    draw.ellipse(
        [CENTER - rec_ring_r, CENTER - rec_ring_r,
         CENTER + rec_ring_r, CENTER + rec_ring_r],
        outline=(0, 240, 255, 160), width=3
    )

    # === "REC" label — clean, monospaced ===
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 42)
        font_small = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 28)
    except (OSError, IOError):
        font = ImageFont.load_default()
        font_small = font

    # "REC" below center dot
    rec_text = "REC"
    bbox = draw.textbbox((0, 0), rec_text, font=font)
    tw = bbox[2] - bbox[0]
    tx = CENTER - tw // 2 + 12  # offset for dot indicator
    ty = CENTER + 100

    # Text glow
    tg = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    tgd = ImageDraw.Draw(tg)
    tgd.text((tx, ty), rec_text, fill=(0, 240, 255, 100), font=font)
    tg = tg.filter(ImageFilter.GaussianBlur(10))
    comp = Image.alpha_composite(comp, tg)

    draw = ImageDraw.Draw(comp)
    draw.text((tx, ty), rec_text, fill=(0, 240, 255, 230), font=font)

    # Small dot indicator before REC
    di_r = 7
    di_x = tx - 18
    di_y = ty + 18
    draw.ellipse([di_x - di_r, di_y - di_r, di_x + di_r, di_y + di_r], fill=CYAN)

    # "ALL" below REC — subtle, spaced out
    all_text = "A  L  L"
    bbox2 = draw.textbbox((0, 0), all_text, font=font_small)
    tw2 = bbox2[2] - bbox2[0]
    tx2 = CENTER - tw2 // 2
    ty2 = ty + 50

    # ALL text glow
    ag = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    agd = ImageDraw.Draw(ag)
    agd.text((tx2, ty2), all_text, fill=(0, 200, 220, 60), font=font_small)
    ag = ag.filter(ImageFilter.GaussianBlur(6))
    comp = Image.alpha_composite(comp, ag)

    draw = ImageDraw.Draw(comp)
    draw.text((tx2, ty2), all_text, fill=(0, 200, 220, 120), font=font_small)

    # === Final output ===
    final = Image.new('RGB', (SIZE, SIZE), (0, 0, 0))
    final.paste(comp, mask=comp.split()[3])

    out = "recall/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    final.save(out, "PNG", quality=100)
    print(f"Saved: {out}")

    preview = "/tmp/recall_icon_v2.png"
    final.save(preview, "PNG")
    print(f"Preview: {preview}")


if __name__ == "__main__":
    main()
