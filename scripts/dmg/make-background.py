"""Draws the DMG window background (640x400 pt, @1x and @2x): Songtide's dark purple with a warm
glow, an arrow from the app (left) to Applications (right), and a one-line hint. Finder always
draws icon labels in black over a background picture, so each label gets a light pill to sit on.
Everything stays in the top three quarters, clear of the path and status bars some people keep on."""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 640, 400
ICON_Y = 150                       # icon centres (must match dmg-settings.py)
LEFT_X, RIGHT_X = 170, 470
LABEL_Y = 233                      # centre of Finder's label under a 128pt icon (window minus title bar)
LABELS = {LEFT_X: 92, RIGHT_X: 118}  # pill widths for "Songtide" and "Applications"

def draw(scale, out):
    s = scale
    w, h = W * s, H * s
    img = Image.new("RGB", (w, h))
    px = img.load()
    top, bottom = (24, 16, 40), (11, 8, 18)          # deep purple to near black
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    # Warm glow behind the arrow, like the icon's ripple.
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse([w * 0.28, h * 0.20, w * 0.72, h * 0.55], fill=110)
    glow = glow.filter(ImageFilter.GaussianBlur(70 * s))
    img = Image.composite(Image.new("RGB", (w, h), (242, 132, 60)), img, glow.point(lambda v: v * 0.5))
    d = ImageDraw.Draw(img)
    # Arrow between the icons.
    y = ICON_Y * s
    x0, x1 = (LEFT_X + 78) * s, (RIGHT_X - 78) * s
    d.rounded_rectangle([x0, y - 3 * s, x1 - 14 * s, y + 3 * s], radius=3 * s, fill=(242, 140, 72))
    d.polygon([(x1, y), (x1 - 22 * s, y - 15 * s), (x1 - 22 * s, y + 15 * s)], fill=(242, 140, 72))
    # Light pills under the labels.
    for cx, pw in LABELS.items():
        d.rounded_rectangle([(cx - pw / 2) * s, (LABEL_Y - 11) * s, (cx + pw / 2) * s, (LABEL_Y + 11) * s],
                            radius=11 * s, fill=(236, 230, 245))
    # Hint text.
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 15 * s)
    text = "Drag Songtide into Applications to install"
    tw = d.textlength(text, font=font)
    d.text(((w - tw) / 2, 268 * s), text, font=font, fill=(200, 192, 214))
    img.save(out)

draw(1, sys.argv[1])
draw(2, sys.argv[2])
