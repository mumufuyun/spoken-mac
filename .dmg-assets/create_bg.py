#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFont

width, height = 660, 400
img = Image.new('RGBA', (width, height), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# 尝试使用系统支持中文的字体
fonts_to_try = [
    ('PingFang SC', 32),
    ('PingFangSC-Regular', 32),
    ('STHeitiSC-Light', 32),
    ('Hiragino Sans GB', 32),
    ('Heiti SC', 32),
    ('Arial Unicode MS', 32),
]

font = None
for name, size in fonts_to_try:
    try:
        font = ImageFont.truetype(f'/System/Library/Fonts/{name}.ttf', size)
        print(f"Using font: {name}.ttf")
        break
    except:
        pass
    try:
        font = ImageFont.truetype(f'/System/Library/Fonts/{name}.ttc', size)
        print(f"Using font: {name}.ttc")
        break
    except:
        pass
    try:
        font = ImageFont.truetype(f'/System/Library/Fonts/PingFang.ttc', size)
        print(f"Using font: PingFang.ttc")
        break
    except:
        pass

if font is None:
    font = ImageFont.load_default()
    print("Using default font")

# 绘制 slogan
text = "语言是最好的输入"
bbox = draw.textbbox((0, 0), text, font=font)
text_width = bbox[2] - bbox[0]
text_height = bbox[3] - bbox[1]
x = (width - text_width) / 2
y = (height - text_height) / 2

draw.text((x, y), text, fill=(30, 30, 30, 255), font=font)

img.save('/Users/vincent/Projects/spoken/.dmg-assets/background.png', 'PNG')
print('Background created successfully')
