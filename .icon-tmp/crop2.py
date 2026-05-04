#!/usr/bin/env python3
from PIL import Image, ImageDraw

src = Image.open("/Users/vincent/Downloads/spoken-icon-v4.png").convert("RGBA")
w, h = src.size
print(f"Original: {w}x{h}")

# 找到图标内容的边界（排除所有边缘的边框像素）
threshold = 50
left, top, right, bottom = w, h, 0, 0

for y in range(h):
    for x in range(w):
        r, g, b, a = src.getpixel((x, y))
        # 排除所有边缘区域（上、下、左、右的黑色/深色边框）
        margin = 100
        if x < margin or x > w - margin or y < margin or y > h - margin:
            continue
        if r > threshold or g > threshold or b > threshold:
            if x < left: left = x
            if x > right: right = x
            if y < top: top = y
            if y > bottom: bottom = y

print(f"Content bounds: left={left}, top={top}, right={right}, bottom={bottom}")

# 裁剪出纯图标内容
icon = src.crop((left, top, right + 1, bottom + 1))
print(f"Cropped icon: {icon.size}")

# 缩放到 1024x1024（填满整个画布，无留白）
final = icon.resize((1024, 1024), Image.LANCZOS)
final.save("/Users/vincent/Projects/spoken/.icon-tmp/icon_1024x1024.png", "PNG")
print("Done - icon scaled to fill 1024x1024 with no border.")
