#!/usr/bin/env python3
"""
Spoken 应用图标生成脚本
输出: spoken.ico (16/32/48/64/128/256, 纯 BMP 32-bit，无 PNG 压缩)

支持两种模式：
1. 从 spoken_icon.png/jpg 提取图标（去掉黑色背景）
2. 如果没有源图片，生成默认麦克风图标
"""

from __future__ import annotations

import os
import struct


def _extract_icon_from_image(source_path: str, size: int = 256) -> "Image.Image":
    """从源图片中提取图标，去掉边缘黑色背景，返回 RGBA 图像。
    
    使用 BFS 洪泛填充从四个角出发，只移除与边缘相连的黑色区域，
    避免误杀图标内部的深色细节。
    """
    from PIL import Image
    
    try:
        # 打开源图片
        src = Image.open(source_path).convert("RGBA")
        
        # 裁切为正方形（以较小边为基准，居中裁切）
        w, h = src.size
        side = min(w, h)
        left = (w - side) // 2
        top = (h - side) // 2
        src = src.crop((left, top, left + side, top + side))
        
        # 调整大小
        src = src.resize((size, size), Image.Resampling.LANCZOS)
        
        # BFS 洪泛填充：从边缘开始，移除与边缘相连的黑色背景
        # 这样只会移除边缘的黑色区域，不会误杀图标内部的深色细节
        data = list(src.getdata())
        w, h = src.size
        
        # 判断是否为"背景黑色"的阈值
        BLACK_THRESHOLD = 15
        
        def is_black(idx):
            r, g, b, a = data[idx]
            return r < BLACK_THRESHOLD and g < BLACK_THRESHOLD and b < BLACK_THRESHOLD
        
        # 从四个角开始 BFS
        visited = set()
        queue = []
        
        # 四个角的像素
        corners = [0, w - 1, (h - 1) * w, h * w - 1]
        for corner in corners:
            if is_black(corner):
                queue.append(corner)
                visited.add(corner)
        
        # 4-连通 BFS
        while queue:
            idx = queue.pop(0)
            # 将此像素设为透明
            r, g, b, a = data[idx]
            data[idx] = (r, g, b, 0)
            
            # 检查四个邻居
            x = idx % w
            y = idx // w
            neighbors = []
            if x > 0: neighbors.append(idx - 1)
            if x < w - 1: neighbors.append(idx + 1)
            if y > 0: neighbors.append(idx - w)
            if y < h - 1: neighbors.append(idx + w)
            
            for n in neighbors:
                if n not in visited and is_black(n):
                    visited.add(n)
                    queue.append(n)
        
        src.putdata(data)
        return src
    except Exception as e:
        print(f"[WARN] 无法加载源图片 {source_path}: {e}")
        return None


def _make_app_icon_image(size: int = 256):
    """生成大众点评风格卡通麦克风图标（备用）。"""
    from PIL import Image, ImageDraw, ImageFilter

    DP_PRIMARY = (0xFF, 0x66, 0x33)
    DP_PRIMARY_LIGHT = (0xFF, 0x88, 0x44)
    WHITE = (255, 255, 255)

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx = size / 2
    cy = size / 2
    margin = max(2, int(size * 0.02))
    radius = (size / 2) - margin

    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=DP_PRIMARY,
    )
    inner_r = radius * 0.92
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    h_draw = ImageDraw.Draw(highlight)
    h_draw.ellipse(
        [cx - inner_r, cy - inner_r - radius * 0.08, cx + inner_r, cy + inner_r - radius * 0.08],
        fill=(*DP_PRIMARY_LIGHT, 80),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=max(3, int(size * 0.03))))
    img = Image.alpha_composite(img, highlight)
    draw = ImageDraw.Draw(img)

    mic_w = size * 0.30
    mic_h = size * 0.26
    mic_top = cy - size * 0.18
    mic_bottom = mic_top + mic_h

    body_left = cx - mic_w
    body_right = cx + mic_w
    body_radius = mic_w * 0.85
    draw.rounded_rectangle(
        [body_left, mic_top, body_right, mic_bottom],
        radius=body_radius,
        fill=WHITE,
    )

    grid_top = mic_top + mic_w * 0.3
    grid_bottom = mic_top + mic_h * 0.55
    grid_margin = mic_w * 0.25
    line_color = (0xF0, 0xF0, 0xF0)
    line_w = max(1, int(size * 0.012))
    if grid_bottom > grid_top:
        num_lines = max(3, int((grid_bottom - grid_top) / (size * 0.035)))
        for i in range(1, num_lines):
            gy = grid_top + (grid_bottom - grid_top) * i / num_lines
            draw.line(
                [(body_left + grid_margin, gy), (body_right - grid_margin, gy)],
                fill=line_color,
                width=line_w,
            )

    split_y = mic_bottom - mic_h * 0.15
    draw.line(
        [(body_left + grid_margin, split_y), (body_right - grid_margin, split_y)],
        fill=line_color,
        width=line_w,
    )

    arc_margin = mic_w * 0.18
    arc_top = mic_top + mic_h * 0.35
    arc_bottom = mic_bottom + size * 0.06
    arc_bbox = [
        body_left - arc_margin,
        arc_top,
        body_right + arc_margin,
        arc_bottom + (arc_bottom - arc_top),
    ]
    stroke = max(2, int(size * 0.025))
    draw.arc(arc_bbox, start=0, end=180, fill=WHITE, width=stroke)

    stem_top = arc_bottom + stroke // 2 - size * 0.01
    stem_bottom = stem_top + size * 0.06
    stem_w = max(2, int(size * 0.02))
    draw.rounded_rectangle(
        [cx - stem_w, stem_top, cx + stem_w, stem_bottom],
        radius=stem_w,
        fill=WHITE,
    )

    base_w = mic_w * 0.9
    base_h = size * 0.035
    base_top = stem_bottom - base_h * 0.3
    base_bottom = base_top + base_h
    draw.rounded_rectangle(
        [cx - base_w, base_top, cx + base_w, base_bottom],
        radius=base_h * 0.5,
        fill=WHITE,
    )

    highlight_w = max(1, int(size * 0.008))
    draw.arc(
        [body_left + mic_w * 0.6, mic_top + mic_h * 0.1,
         body_right - mic_w * 0.1, mic_bottom - mic_h * 0.1],
        start=280, end=80,
        fill=(255, 255, 255, 120),
        width=highlight_w,
    )

    return img


def _bmp32_data(img) -> bytes:
    """将 PIL RGBA 图像转为 ICO 用的 32-bit BMP 数据（不含 14-byte 文件头）。"""
    rgba = img.convert("RGBA")
    w, h = rgba.size
    pixels = rgba.tobytes()  # RGBA, top-to-bottom

    # ICO 中 BMP 高度是实际 2 倍（XOR mask + AND mask）
    # 32-bit 下 AND mask 全 0，因为 alpha 已处理透明
    dib_height = h * 2

    # BITMAPINFOHEADER (40 bytes)
    dib = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        w,           # biWidth
        dib_height,  # biHeight (2x for XOR+AND)
        1,           # biPlanes
        32,          # biBitCount
        0,           # biCompression (BI_RGB)
        0,           # biSizeImage
        2835,        # biXPelsPerMeter
        2835,        # biYPelsPerMeter
        0,           # biClrUsed
        0,           # biClrImportant
    )

    # 像素数据：BGRA，bottom-to-top
    row_size = w * 4
    bgra = bytearray()
    for y in range(h - 1, -1, -1):
        row = pixels[y * row_size : (y + 1) * row_size]
        for x in range(w):
            r, g, b, a = row[x * 4 : x * 4 + 4]
            bgra.extend([b, g, r, a])

    # AND mask (1-bit per pixel, 32-bit aligned per row)
    # 32-bit BMP 不需要 AND mask，但 ICO 格式要求存在（全 0 表示不透明）
    and_row_size = ((w + 31) // 32) * 4
    and_mask = bytes(and_row_size * h)

    return dib + bytes(bgra) + and_mask


def generate_ico(output_path: str = "spoken.ico") -> None:
    from PIL import Image

    sizes = [16, 32, 48, 64, 128, 256]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_full = os.path.join(script_dir, output_path)

    # 尝试从源图片加载图标
    base = None
    source_candidates = [
        os.path.join(script_dir, "spoken_icon.png"),
        os.path.join(script_dir, "spoken_icon.jpg"),
        os.path.join(os.path.expanduser("~"), "Desktop", "IMG_1778314419173_fc014460-4b7e-11f1-bf42-870fc655d35d.jpg"),
    ]
    
    for source_path in source_candidates:
        if os.path.exists(source_path):
            print(f"[INFO] 从源图片加载图标: {source_path}")
            try:
                base = _extract_icon_from_image(source_path, 256)
                if base is not None:
                    print(f"[OK] 图标已从 {source_path} 提取")
                    break
            except Exception as e:
                print(f"[WARN] 图标提取失败: {e}，将使用默认图标")
                base = None
    
    # 如果没有源图片或提取失败，生成默认图标
    if base is None:
        print("[INFO] 源图片不存在或提取失败，使用默认麦克风图标")
        base = _make_app_icon_image(256)

    images = []
    for size in sizes:
        if size == 256:
            images.append(base)
        else:
            images.append(base.resize((size, size), Image.Resampling.LANCZOS))

    # 构建 ICO 文件（纯 BMP 32-bit，无 PNG）
    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)  # ICONDIR

    # 计算数据偏移
    entry_size = 16
    data_offset = 6 + entry_size * count

    entries = b""
    data = b""

    for img in images:
        w, h = img.size
        bmp = _bmp32_data(img)
        total_size = len(bmp)

        # ICONDIRENTRY
        w_byte = w if w < 256 else 0
        h_byte = h if h < 256 else 0
        entry = struct.pack(
            "<BBBBHHII",
            w_byte, h_byte, 0, 0,  # width, height, colors, reserved
            1, 32,                  # planes, bitcount
            total_size,             # size of image data
            data_offset,            # offset in file
        )
        entries += entry
        data += bmp
        data_offset += total_size

    with open(output_full, "wb") as f:
        f.write(header + entries + data)

    print(f"[OK] 图标已生成: {output_full}")
    print(f"     尺寸: {', '.join(f'{s}x{s}' for s in sizes)} (BMP 32-bit)")


if __name__ == "__main__":
    generate_ico()
