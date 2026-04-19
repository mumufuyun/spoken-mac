#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFont

width, height = 600, 400
img = Image.new('RGB', (width, height), color='#F5F5F7')
draw = ImageDraw.Draw(img)

try:
    font_large = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 28)
    font_medium = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 16)
    font_small = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 12)
except:
    font_large = ImageFont.load_default()
    font_medium = ImageFont.load_default()
    font_small = ImageFont.load_default()

# 标题
title = '安装 Spoken'
bbox = draw.textbbox((0, 0), title, font=font_large)
text_width = bbox[2] - bbox[0]
draw.text(((width - text_width) / 2, 40), title, fill='#1D1D1F', font=font_large)

# 说明
subtitle = '将 Spoken.app 拖入 Applications 完成安装'
bbox = draw.textbbox((0, 0), subtitle, font=font_medium)
text_width = bbox[2] - bbox[0]
draw.text(((width - text_width) / 2, 80), subtitle, fill='#6E6E73', font=font_medium)

# 左侧 App 图标
app_x, app_y, icon_size = 150, 180, 80
draw.rounded_rectangle([app_x, app_y, app_x + icon_size, app_y + icon_size], radius=16, fill='#FFFFFF', outline='#D2D2D7', width=2)

mic_cx = app_x + icon_size // 2
mic_cy = app_y + icon_size // 2
draw.ellipse([mic_cx - 12, mic_cy - 20, mic_cx + 12, mic_cy + 8], fill='#007AFF')
draw.rectangle([mic_cx - 16, mic_cy + 8, mic_cx + 16, mic_cy + 20], fill='#007AFF')

# 右侧 Applications 文件夹
folder_x, folder_y = 350, 180
draw.rounded_rectangle([folder_x, folder_y, folder_x + icon_size, folder_y + icon_size], radius=16, fill='#FFFFFF', outline='#D2D2D7', width=2)

folder_cx = folder_x + icon_size // 2
folder_cy = folder_y + icon_size // 2
draw.rounded_rectangle([folder_cx - 20, folder_cy - 12, folder_cx + 20, folder_cy + 16], radius=4, fill='#5AC8FA')
draw.rectangle([folder_cx - 20, folder_cy - 16, folder_cx + 8, folder_cy - 12], fill='#5AC8FA')

# 箭头
arrow_y = 210
draw.line([(245, arrow_y), (335, arrow_y)], fill='#86868B', width=3)
draw.line([(320, arrow_y - 10), (335, arrow_y)], fill='#86868B', width=3)
draw.line([(320, arrow_y + 10), (335, arrow_y)], fill='#86868B', width=3)

# 底部
footer = '安装完成后，从 Applications 启动 Spoken'
bbox = draw.textbbox((0, 0), footer, font=font_small)
text_width = bbox[2] - bbox[0]
draw.text(((width - text_width) / 2, height - 60), footer, fill='#86868B', font=font_small)

img.save('/Users/vincent/Projects/spoken/.dmg-assets/background.png')
print('Background image created')
