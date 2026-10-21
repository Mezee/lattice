"""Builds the app icon, menu bar icons and SVG logo from the two source images in assets/src.

Run from the repo root:  uv run --with pillow --with numpy python tools/make_icons.py
Needs `potrace` (brew install potrace) for the SVG and `iconutil` (macOS) for the .icns.
"""
import subprocess, shutil, tempfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC, OUT = ROOT / "assets" / "src", ROOT / "assets"

logo = Image.open(SRC / "logo-mask.png").convert("RGBA")          # black cube, light bubble, transparent bg
orig = Image.open(SRC / "icon-original.png").convert("RGB")       # gradient cube on black squircle
W = logo.width                                                     # 708
alpha = np.array(logo.getchannel("A")).astype(float) / 255
lum = np.array(logo.convert("L")).astype(float) / 255
cube_minus_bubble = np.clip(alpha * (1 - lum), 0, 1)               # 1 on the cube body, 0 on bubble and background


def upscaled_mask(arr, factor):
    """Smooth, sub-pixel-accurate mask: Lanczos upscale of an antialiased mask, then re-threshold."""
    im = Image.fromarray((arr * 255).astype(np.uint8)).resize((arr.shape[1] * factor, arr.shape[0] * factor), Image.LANCZOS)
    a = np.array(im).astype(float) / 255
    return np.clip((a - 0.5) * 6 + 0.5, 0, 1)                      # steep ramp = antialiased threshold at 50%


# ---------- SVG logo (traced) ----------
with tempfile.TemporaryDirectory() as t:
    big = upscaled_mask(cube_minus_bubble, 4)
    bmp = Path(t) / "mask.bmp"
    Image.fromarray(((1 - big) * 255).astype(np.uint8)).convert("1").save(bmp)
    subprocess.run(["potrace", "-s", "--turdsize", "20", "-o", str(OUT / "logo.svg"), str(bmp)], check=True)

# ---------- menu bar template icons ----------
BBOX_CENTER, SIDE = 353.5, 470
box = (BBOX_CENTER - SIDE / 2, BBOX_CENTER - SIDE / 2, BBOX_CENTER + SIDE / 2, BBOX_CENTER + SIDE / 2)


def bars(spec):
    """Draw bars (x, centre y, height, width) in source coordinates into a mask the size of the logo."""
    s = 4
    im = Image.new("L", (W * s, W * s), 0)
    d = ImageDraw.Draw(im)
    for x, cy, h, w in spec:
        d.rounded_rectangle([(x - w / 2) * s, (cy - h / 2) * s, (x + w / 2) * s, (cy + h / 2) * s], radius=w / 2 * s, fill=255)
    return np.array(im).astype(float) / 255


states = {
    "idle": [],
    "reading": [(222, 379, 60, 30), (262, 401, 100, 30), (302, 423, 70, 30)],
    "paused": [(235, 387, 100, 32), (290, 417, 100, 32)],
}
base4 = upscaled_mask(cube_minus_bubble, 4)
for name, spec in states.items():
    m = np.clip(base4 + (bars(spec) if spec else 0), 0, 1)
    im = Image.fromarray((m * 255).astype(np.uint8)).crop(tuple(int(v * 4) for v in box)).resize((54, 54), Image.LANCZOS)
    rgba = Image.new("RGBA", (54, 54), (0, 0, 0, 0)); rgba.putalpha(im)
    rgba.save(OUT / f"menubar-{name}.png")

# ---------- app icon ----------
S = 1024; BODY = 824; PAD = (S - BODY) // 2; SS = 3
src = np.array(orig).astype(float)
valid = Image.fromarray((cube_minus_bubble * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(11))
v = np.array(valid).astype(float)[..., None] / 255
num = np.array(Image.fromarray((src * v).astype(np.uint8)).filter(ImageFilter.GaussianBlur(30))).astype(float)
den = np.array(valid.filter(ImageFilter.GaussianBlur(30))).astype(float)[..., None] / 255
filled = np.where(v > 0.5, src, num / np.maximum(den, 1e-3))      # gradient continued under the bubble and past the edges
filled = np.array(Image.fromarray(filled.clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2)))

scale = BODY / W
cube_img = Image.fromarray(filled).resize((round(W * scale), round(W * scale)), Image.LANCZOS)
mask_hi = upscaled_mask(cube_minus_bubble, 4)
mask_img = Image.fromarray((mask_hi * 255).astype(np.uint8)).resize(cube_img.size, Image.LANCZOS)

# squircle (superellipse) body, supersampled for clean edges
n = 5.0
g = (np.arange(S * SS) + 0.5) / (S * SS) * S - S / 2
X, Y = np.meshgrid(g, g)
sq = (np.abs(X / (BODY / 2)) ** n + np.abs(Y / (BODY / 2)) ** n <= 1).astype(np.uint8) * 255
squircle = Image.fromarray(sq).resize((S, S), Image.LANCZOS)

top, bottom = np.array(orig.getpixel((354, 30))), np.array(orig.getpixel((354, 680)))
rows = np.linspace(top, bottom, S)[:, None, :].repeat(S, axis=1).astype(np.uint8)
body = Image.fromarray(rows).convert("RGBA")
body.putalpha(squircle)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh_a = squircle.filter(ImageFilter.GaussianBlur(18)).point(lambda p: int(p * 0.40))
shadow.putalpha(sh_a)
canvas.alpha_composite(shadow, (0, 12))
canvas.alpha_composite(body)
layer = cube_img.convert("RGBA"); layer.putalpha(mask_img)
canvas.alpha_composite(layer, (PAD, PAD))
canvas.save(OUT / "icon-1024.png")

with tempfile.TemporaryDirectory() as t:
    iconset = Path(t) / "Lattice.iconset"; iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        canvas.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        canvas.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "Lattice.icns")], check=True)
print("done")
