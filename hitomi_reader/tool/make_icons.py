"""根据用户提供的图标生成 Android（传统 + 自适应）与 Windows 图标。

用法（在 hitomi_reader 目录下，需要 Pillow 和 numpy）：
    python tool/make_icons.py tool/icon_source.webp . build/icon_preview

源图为带透明背景的粉色圆角方块，中间是深色圆形插画。会生成：
- Android 传统图标 mipmap-*/ic_launcher.png 与自适应图标（粉色背景 + 圆形插画前景）；
- Windows 图标 windows/runner/resources/app_icon.ico；
- 应用内使用的 assets/icon.png；
- 预览图（模拟圆形、圆角方形启动器和小尺寸）。
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

source, project, preview_dir = sys.argv[1:4]
image = Image.open(source).convert('RGBA')
pixels = np.asarray(image).astype(int)
alpha = pixels[..., 3]

# 粉色圆角方块的范围
ys, xs = np.where(alpha > 128)
left, right, top, bottom = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
# 粉色背景色：取方块内、圆外的若干点的中位数
samples = [pixels[y, x, :3] for (x, y) in [(200, 640), (640, 180), (1090, 640), (640, 1070), (230, 1000)]]
background = tuple(int(v) for v in np.median(np.array(samples), axis=0))
print('shape', left, right, top, bottom, 'background', background)

# 深色圆：中心与半径
dark = (pixels[..., :3].max(axis=2) < 130) & (alpha > 128)
ys, xs = np.where(dark)
cx, cy = (xs.min() + xs.max() + 1) / 2, (ys.min() + ys.max() + 1) / 2
radius = max(xs.max() + 1 - xs.min(), ys.max() + 1 - ys.min()) / 2
print('circle', cx, cy, radius)

# ---- 方形底图（传统图标、Windows 图标）：圆角方块居中放进正方形 ----
shape = image.crop((left, top, right, bottom))
side = max(shape.size)
square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
square.paste(shape, ((side - shape.width) // 2, (side - shape.height) // 2))

# ---- 自适应图标前景：圆形插画，外圈透明，按原图比例（圆占可见区域约 75%）----
pad = radius + 6
circle = image.crop((int(cx - pad), int(cy - pad), int(cx + pad), int(cy + pad)))
scale = 4  # 超采样画圆形遮罩，边缘平滑
size = circle.width
mask = Image.new('L', (size * scale, size * scale), 0)
r = (radius + 1.5) * scale
c = size * scale / 2
ImageDraw.Draw(mask).ellipse((c - r, c - r, c + r, c + r), fill=255)
mask = mask.resize((size, size), Image.LANCZOS)
circle.putalpha(Image.fromarray(np.minimum(np.asarray(mask), np.asarray(circle.getchannel('A')))))

def foreground(px):
    """108dp 画布，可见区域为中间 72dp，圆的直径取 72 × 0.75 = 54dp。"""
    canvas = Image.new('RGBA', (px, px), (0, 0, 0, 0))
    diameter = round(px * 54 / 108 * size / (2 * radius))
    art = circle.resize((diameter, diameter), Image.LANCZOS)
    canvas.paste(art, ((px - diameter) // 2, (px - diameter) // 2), art)
    return canvas

res = os.path.join(project, 'android', 'app', 'src', 'main', 'res')
densities = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for name, factor in densities.items():
    folder = os.path.join(res, f'mipmap-{name}')
    os.makedirs(folder, exist_ok=True)
    square.resize((round(48 * factor),) * 2, Image.LANCZOS).save(os.path.join(folder, 'ic_launcher.png'))
    foreground(round(108 * factor)).save(os.path.join(folder, 'ic_launcher_foreground.png'))

anydpi = os.path.join(res, 'mipmap-anydpi-v26')
os.makedirs(anydpi, exist_ok=True)
with open(os.path.join(anydpi, 'ic_launcher.xml'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<!-- Android 8.0 起的自适应图标：粉色背景 + 圆形插画，启动器裁成任何形状都与原图一致 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
''')
values = os.path.join(res, 'values')
with open(os.path.join(values, 'colors.xml'), 'w', encoding='utf-8', newline='\n') as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#%02X%02X%02X</color>
</resources>
''' % background)

# ---- Windows 图标 ----
ico = os.path.join(project, 'windows', 'runner', 'resources', 'app_icon.ico')
square.save(ico, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])

# ---- 应用内使用的图标（关于页面）----
assets = os.path.join(project, 'assets')
os.makedirs(assets, exist_ok=True)
square.resize((512, 512), Image.LANCZOS).save(os.path.join(assets, 'icon.png'))

# ---- 预览：模拟启动器的圆形、圆角方形遮罩，以及小尺寸效果 ----
os.makedirs(preview_dir, exist_ok=True)
fg = foreground(432)
layer = Image.new('RGBA', (432, 432), background + (255,))
layer.alpha_composite(fg)
visible = layer.crop((72, 72, 360, 360))  # 中间 72dp
sheet = Image.new('RGBA', (288 * 3 + 64 + 256 + 32 * 4, 300), (255, 255, 255, 255))
for i, kind in enumerate(['circle', 'squircle', 'legacy']):
    if kind == 'legacy':
        tile = square.resize((288, 288), Image.LANCZOS)
    else:
        m = Image.new('L', (288, 288), 0)
        draw = ImageDraw.Draw(m)
        if kind == 'circle':
            draw.ellipse((0, 0, 287, 287), fill=255)
        else:
            draw.rounded_rectangle((0, 0, 287, 287), radius=80, fill=255)
        tile = visible.copy()
        tile.putalpha(m)
    sheet.alpha_composite(tile, (16 + i * 304, 6))
x = 16 + 3 * 304
for s in (64, 32, 16):
    small = square.resize((s, s), Image.LANCZOS)
    sheet.alpha_composite(small, (x, 6))
    x += s + 16
sheet.save(os.path.join(preview_dir, 'icon_preview.png'))
print('done')
