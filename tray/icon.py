"""
spoken/tray/icon.py
系统托盘图标模块 — Apple HIG 风格重设计

6 状态：
  ready         — 绿色 #30D158（Apple green）
  recording     — 红色 #FF453A（Apple red）
  recognizing   — 黄色 #FFD60A（Apple yellow）
  ai_processing — 紫色 #BF5AF2（Apple purple）
  injecting     — 蓝色 #0A84FF（Apple blue）
  error         — 橙色 #FF9F0A（Apple orange）

图标设计：
  - 圆形背景（非方形）
  - 中心绘制几何麦克风图形（胶囊体 + 支架弧线 + 底座）
  - 右下角小角标显示模式字母（A-F）

右键菜单：退出 / 模式切换（A-F）/ 查看日志
"""

from __future__ import annotations

import logging
import threading
from enum import Enum
from typing import Callable, Optional, Tuple

logger = logging.getLogger(__name__)

# ── Apple 系统色（RGB）────────────────────────────────────────────
STATE_COLORS: dict = {
    "ready":         (0x30, 0xD1, 0x58),   # #30D158 Apple Green
    "starting":      (0x0A, 0x84, 0xFF),   # #0A84FF Apple Blue
    "recording":     (0xFF, 0x45, 0x3A),   # #FF453A Apple Red
    "recognizing":   (0xFF, 0xD6, 0x0A),   # #FFD60A Apple Yellow
    "ai_processing": (0xBF, 0x5A, 0xF2),   # #BF5AF2 Apple Purple
    "injecting":     (0x0A, 0x84, 0xFF),   # #0A84FF Apple Blue
    "error":         (0xFF, 0x9F, 0x0A),   # #FF9F0A Apple Orange
}

# 工具提示模板
STATE_TOOLTIPS: dict = {
    "ready":         "Spoken — 就绪（{mode} 模式）",
    "starting":      "Spoken — 正在启动语音引擎...",
    "recording":     "Spoken — 录音中...",
    "recognizing":   "Spoken — 识别中...",
    "ai_processing": "Spoken — AI 处理中...",
    "injecting":     "Spoken — 正在注入文字...",
    "error":         "Spoken — 发生错误",
}

# AI 模式显示名称
MODE_NAMES = {
    "A": "直接注入",
    "B": "润色优化",
    "C": "转 Prompt",
    "D": "翻译英文",
    "E": "会议纪要",
    "F": "内容结构化",
}

# 图标尺寸
ICON_SIZE = 64


class TrayState(str, Enum):
    """托盘状态枚举。"""
    READY         = "ready"
    STARTING      = "starting"
    RECORDING     = "recording"
    RECOGNIZING   = "recognizing"
    AI_PROCESSING = "ai_processing"
    INJECTING     = "injecting"
    ERROR         = "error"


def _draw_mode_badge(img: "PIL.Image.Image", mode_label: str, size: int = ICON_SIZE) -> None:
    """在图标右下角绘制 AI 模式角标（A/B/C/D/E/F）。
    
    Args:
        img: PIL RGBA Image 对象（会被原地修改）
        mode_label: 模式字母，如 "A"
        size: 图标尺寸
    """
    try:
        from PIL import ImageDraw, ImageFont
    except ImportError:
        return
    
    if not mode_label or mode_label.upper() not in "ABCDEF":
        return
    
    draw = ImageDraw.Draw(img)
    
    # 右下角角标参数
    badge_size = max(16, int(size * 0.25))
    badge_margin = max(2, int(size * 0.08))
    badge_radius = badge_size // 2
    
    badge_x = size - badge_size - badge_margin
    badge_y = size - badge_size - badge_margin
    
    # 绘制半透明白色圆形背景
    draw.ellipse(
        [badge_x, badge_y, badge_x + badge_size, badge_y + badge_size],
        fill=(255, 255, 255, 200),
    )
    
    # 绘制模式字母（黑色文字）
    text = mode_label.upper()
    
    # 尝试使用系统字体，如果失败则跳过文字
    try:
        # 尝试多个可能的字体路径
        font_paths = [
            "C:\\Windows\\Fonts\\arial.ttf",
            "C:\\Windows\\Fonts\\ARIAL.TTF",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",  # Linux
        ]
        
        font = None
        font_size = max(10, int(badge_size * 0.6))
        
        for font_path in font_paths:
            try:
                font = ImageFont.truetype(font_path, font_size)
                break
            except Exception:
                continue
        
        if font:
            # 计算文字居中位置
            bbox = draw.textbbox((0, 0), text, font=font)
            text_width = bbox[2] - bbox[0]
            text_height = bbox[3] - bbox[1]
            
            text_x = badge_x + (badge_size - text_width) // 2
            text_y = badge_y + (badge_size - text_height) // 2
            
            draw.text((text_x, text_y), text, fill=(0, 0, 0, 255), font=font)
        else:
            # 没有字体，至少绘制简单的点
            center_x = badge_x + badge_size // 2
            center_y = badge_y + badge_size // 2
            draw.ellipse(
                [center_x - 2, center_y - 2, center_x + 2, center_y + 2],
                fill=(0, 0, 0, 255),
            )
    except Exception as e:
        logger.debug(f"无法绘制模式角标文字: {e}")


def _load_icon_from_source(size: int = ICON_SIZE) -> Optional["PIL.Image.Image"]:
    """尝试从源图片加载 Spoken 图标。
    
    使用 BFS 洪泛填充从边缘移除黑色背景，保留图标内部的深色细节。
    
    Args:
        size: 期望的图标尺寸
        
    Returns:
        RGBA Image 对象，或 None 如果加载失败
    """
    from PIL import Image
    import os
    
    # 候选源图片路径
    candidates = [
        os.path.join(os.path.dirname(__file__), "..", "spoken_icon.png"),
        os.path.join(os.path.dirname(__file__), "..", "spoken_icon.jpg"),
        os.path.expanduser("~") + r"\Desktop\IMG_1778314419173_fc014460-4b7e-11f1-bf42-870fc655d35d.jpg",
    ]
    
    for source_path in candidates:
        if not os.path.exists(source_path):
            continue
        try:
            src = Image.open(source_path).convert("RGBA")
            # 裁切为正方形（以较小边为基准）
            w, h = src.size
            side = min(w, h)
            left = (w - side) // 2
            top = (h - side) // 2
            src = src.crop((left, top, left + side, top + side))
            
            # 调整大小
            src = src.resize((size, size), Image.Resampling.LANCZOS)
            
            # BFS 洪泛填充：从边缘移除黑色背景，保留内部深色细节
            data = list(src.getdata())
            w, h = src.size
            
            BLACK_THRESHOLD = 15
            
            def is_black(idx):
                r, g, b, a = data[idx]
                return r < BLACK_THRESHOLD and g < BLACK_THRESHOLD and b < BLACK_THRESHOLD
            
            visited = set()
            queue = []
            
            corners = [0, w - 1, (h - 1) * w, h * w - 1]
            for corner in corners:
                if is_black(corner):
                    queue.append(corner)
                    visited.add(corner)
            
            while queue:
                idx = queue.pop(0)
                r, g, b, a = data[idx]
                data[idx] = (r, g, b, 0)
                
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
            logger.debug(f"无法加载源图片 {source_path}: {e}")
            continue
    
    return None


def _make_icon_image(
    color: Tuple[int, int, int],
    size: int = ICON_SIZE,
    mode_label: str = "",
) -> "PIL.Image.Image":
    """生成卡通麦克风圆形托盘图标（大众点评风格）或从源图片加载。

    设计规格：
      - 优先从源图片加载 Spoken 图标，并添加彩色圆形背景
      - 如果无源图片，则动态生成：圆形背景 + 白色卡通麦克风 + 网格拾音孔 + U 形支架 + 底座
      - 右下角渲染模式字母角标（小号，白色，半透明圆形底）

    Args:
        color: RGB 颜色元组（状态颜色）
        size: 图标正方形尺寸（像素）
        mode_label: 右下角角标字母（如 "A"），空字符串则不显示

    Returns:
        PIL RGBA Image 对象
    """
    try:
        from PIL import Image, ImageDraw, ImageFilter, ImageFont
    except ImportError as e:
        raise ImportError("Pillow 未安装，请运行: pip install Pillow") from e
    
    # 尝试从源图片加载图标
    icon_img = _load_icon_from_source(size)
    if icon_img is not None:
        # 源图片成功加载 — 直接使用，不加背景圆框
        # 后续可通过透明度或微妙的状态指示来表达状态，但不需要彩色背景圆框
        img = icon_img.copy()
        
        # 添加模式角标（如果需要）
        if mode_label:
            _draw_mode_badge(img, mode_label, size)
        
        return img
    
    # 如果源图片加载失败，回退到动态生成麦克风图标
    logger.debug("使用动态生成的麦克风图标")

    WHITE = (255, 255, 255)
    GRID_COLOR = (0xF0, 0xF0, 0xF0)

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx = size / 2
    cy = size / 2
    margin = max(1, int(size * 0.015))
    radius = (size / 2) - margin

    # ── 1. 圆形背景 ───────────────────────────────────────────────
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(*color, 255),
    )
    # 顶部高光（渐变模拟）
    inner_r = radius * 0.92
    light_color = (
        min(255, color[0] + 20),
        min(255, color[1] + 20),
        min(255, color[2] + 20),
    )
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    h_draw = ImageDraw.Draw(highlight)
    h_draw.ellipse(
        [cx - inner_r, cy - inner_r - radius * 0.08,
         cx + inner_r, cy + inner_r - radius * 0.08],
        fill=(*light_color, 70),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=max(2, int(size * 0.025))))
    img = Image.alpha_composite(img, highlight)
    draw = ImageDraw.Draw(img)

    # ── 2. 卡通麦克风 ─────────────────────────────────────────────
    mic_w = size * 0.30      # 半宽
    mic_h = size * 0.26      # 头高度
    mic_top = cy - size * 0.18
    mic_bottom = mic_top + mic_h

    body_left = cx - mic_w
    body_right = cx + mic_w
    body_radius = mic_w * 0.85

    # 主体
    draw.rounded_rectangle(
        [body_left, mic_top, body_right, mic_bottom],
        radius=body_radius,
        fill=WHITE,
    )

    # 拾音网格横线
    grid_top = mic_top + mic_w * 0.3
    grid_bottom = mic_top + mic_h * 0.55
    grid_margin = mic_w * 0.25
    line_w = max(1, int(size * 0.012))
    if grid_bottom > grid_top:
        num_lines = max(3, int((grid_bottom - grid_top) / (size * 0.035)))
        for i in range(1, num_lines):
            gy = grid_top + (grid_bottom - grid_top) * i / num_lines
            draw.line(
                [(body_left + grid_margin, gy), (body_right - grid_margin, gy)],
                fill=GRID_COLOR,
                width=line_w,
            )

    # 分割线
    split_y = mic_bottom - mic_h * 0.15
    draw.line(
        [(body_left + grid_margin, split_y), (body_right - grid_margin, split_y)],
        fill=GRID_COLOR,
        width=line_w,
    )

    # U 形支架
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

    # 支架竖杆
    stem_top = arc_bottom + stroke // 2 - size * 0.01
    stem_bottom = stem_top + size * 0.06
    stem_w = max(2, int(size * 0.02))
    draw.rounded_rectangle(
        [cx - stem_w, stem_top, cx + stem_w, stem_bottom],
        radius=stem_w,
        fill=WHITE,
    )

    # 底座
    base_w = mic_w * 0.9
    base_h = size * 0.035
    base_top = stem_bottom - base_h * 0.3
    base_bottom = base_top + base_h
    draw.rounded_rectangle(
        [cx - base_w, base_top, cx + base_w, base_bottom],
        radius=base_h * 0.5,
        fill=WHITE,
    )

    # ── 3. 右下角模式角标 ─────────────────────────────────────────
    if mode_label:
        badge_size = int(size * 0.32)
        badge_x = size - badge_size - 1
        badge_y = size - badge_size - 1

        draw.ellipse(
            [badge_x, badge_y, badge_x + badge_size, badge_y + badge_size],
            fill=(255, 255, 255, 200),
        )

        badge_font_size = int(badge_size * 0.62)
        badge_font = None
        for font_name in ("arialbd.ttf", "Arial Bold.ttf", "arial.ttf", "DejaVuSans-Bold.ttf"):
            try:
                badge_font = ImageFont.truetype(font_name, badge_font_size)
                break
            except Exception:
                continue
        if badge_font is None:
            badge_font = ImageFont.load_default()

        badge_cx = badge_x + badge_size // 2
        badge_cy = badge_y + badge_size // 2

        bbox = draw.textbbox((0, 0), mode_label, font=badge_font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        tx = badge_cx - tw // 2 - bbox[0]
        ty = badge_cy - th // 2 - bbox[1]

        text_color = (
            max(0, color[0] - 40),
            max(0, color[1] - 40),
            max(0, color[2] - 40),
            255,
        )
        draw.text((tx, ty), mode_label, fill=text_color, font=badge_font)

    return img


class TrayIcon:
    """Apple HIG 风格系统托盘图标控制器。

    使用示例::

        tray = TrayIcon(
            on_mode_change=lambda m: print(f"切换到 {m}"),
            on_quit=lambda: sys.exit(0),
            on_view_log=lambda: os.startfile("spoken.log"),
        )
        tray.start()
        tray.set_state(TrayState.RECORDING)
        tray.set_mode("B")
    """

    def __init__(
        self,
        on_mode_change: Optional[Callable[[str], None]] = None,
        on_quit: Optional[Callable[[], None]] = None,
        on_view_log: Optional[Callable[[], None]] = None,
        on_pause_resume: Optional[Callable[[bool], None]] = None,
        on_engine_change: Optional[Callable[[str], None]] = None,
        initial_mode: str = "A",
        initial_engine: str = "xunfei",
        show_mode_indicator: bool = True,
        done_flash_ms: int = 1500,
    ) -> None:
        """初始化托盘控制器。

        Args:
            on_mode_change: 模式切换回调，参数为新模式 "A"/"B"/"C"
            on_quit: 退出回调
            on_view_log: 查看日志回调
            on_pause_resume: 暂停/恢复回调，参数 True=暂停, False=恢复
            on_engine_change: 引擎切换回调，参数为引擎名 "meituan"/"xunfei"/"windows"
            initial_mode: 初始 AI 模式
            initial_engine: 初始 ASR 引擎
            show_mode_indicator: 是否在图标右下角显示模式角标
            done_flash_ms: 注入完成后绿色状态保持时长（毫秒，预留）
        """
        self._on_mode_change = on_mode_change
        self._on_quit = on_quit
        self._on_view_log = on_view_log
        self._on_pause_resume = on_pause_resume
        self._on_engine_change = on_engine_change
        self._current_mode = initial_mode
        self._current_engine = initial_engine
        self._show_mode = show_mode_indicator
        self._done_flash_ms = done_flash_ms

        self._state = TrayState.READY
        self._paused = False
        self._icon = None       # pystray.Icon 实例
        self._pystray = None
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()

    # ── 公开接口 ──────────────────────────────────────────────────

    def start(self) -> None:
        """在后台线程启动托盘图标。

        Raises:
            ImportError: pystray 或 Pillow 未安装
        """
        try:
            import pystray
            self._pystray = pystray
        except ImportError as e:
            raise ImportError("pystray 未安装，请运行: pip install pystray") from e

        self._icon = self._pystray.Icon(
            name="Spoken",
            icon=self._build_icon_image(),
            title=self._build_tooltip(),
            menu=self._build_menu(),
        )

        self._thread = threading.Thread(
            target=self._run,
            daemon=True,
            name="TrayThread",
        )
        self._thread.start()
        logger.info("托盘图标已启动（Apple HIG 圆形图标）")

    def stop(self) -> None:
        """停止并移除托盘图标。"""
        if self._icon:
            try:
                self._icon.stop()
            except Exception as e:
                logger.error("停止托盘图标失败: %s", e)
        logger.info("托盘图标已停止")

    def set_state(self, state: "TrayState | str") -> None:
        """更新托盘状态（颜色 + 提示）。

        Args:
            state: TrayState 枚举值或字符串（如 "recording"）
        """
        if isinstance(state, str):
            try:
                state = TrayState(state)
            except ValueError:
                logger.error("无效的托盘状态: %s", state)
                return

        with self._lock:
            self._state = state

        self._update_icon()
        logger.debug("托盘状态 → %s", state.value)

    def set_mode(self, mode: str) -> None:
        """更新当前 AI 模式，刷新右下角角标。

        Args:
            mode: "A" / "B" / "C" / "D" / "E" / "F"
        """
        if mode not in ("A", "B", "C", "D", "E", "F"):
            logger.warning("无效的模式: %s", mode)
            return
        with self._lock:
            self._current_mode = mode
        self._update_icon()
        logger.info("AI 模式切换为: %s（%s）", mode, MODE_NAMES.get(mode, ""))

    def set_engine(self, engine: str) -> None:
        """更新当前 ASR 引擎，刷新菜单状态。

        Args:
            engine: "meituan" / "xunfei" / "windows"
        """
        if engine not in ("meituan", "xunfei", "windows"):
            logger.warning("无效的引擎: %s", engine)
            return
        with self._lock:
            self._current_engine = engine
        self._update_menu()
        logger.info("ASR 引擎切换为: %s", engine)

    def flash_done(self) -> None:
        """注入完成：短暂切换到就绪（绿色）状态，给用户视觉反馈。"""
        self.set_state(TrayState.READY)

    def notify_error(self, message: str) -> None:
        """显示错误状态（橙色图标）。

        Args:
            message: 错误信息（记录到日志）
        """
        logger.error("托盘错误通知: %s", message)
        self.set_state(TrayState.ERROR)

    def notify(self, title: str, message: str) -> None:
        """显示托盘气泡通知。

        Args:
            title: 通知标题
            message: 通知内容
        """
        if self._icon and hasattr(self._icon, "notify"):
            try:
                self._icon.notify(message, title)
                logger.info("托盘通知: [%s] %s", title, message)
            except Exception as e:
                logger.warning("托盘通知失败: %s", e)
        else:
            logger.info("托盘通知(无图标): [%s] %s", title, message)

    # ── 内部方法 ──────────────────────────────────────────────────

    def _run(self) -> None:
        """托盘事件循环（在独立线程中运行）。"""
        try:
            self._icon.run()
        except Exception as e:
            logger.error("托盘图标运行异常: %s", e)

    def _build_icon_image(self) -> "PIL.Image.Image":
        """根据当前状态和模式生成图标图像。"""
        with self._lock:
            state_val = self._state.value
            mode = self._current_mode
            show = self._show_mode
        color = STATE_COLORS.get(state_val, (128, 128, 128))
        label = mode if show else ""
        return _make_icon_image(color, size=ICON_SIZE, mode_label=label)

    def _build_tooltip(self) -> str:
        """生成托盘工具提示文字。"""
        with self._lock:
            state_val = self._state.value
            mode = self._current_mode
        template = STATE_TOOLTIPS.get(state_val, "Spoken")
        return template.format(mode=mode)

    def _build_menu(self) -> "pystray.Menu":
        """构建右键菜单（模式切换 + 设置 + 日志 + 退出）。"""
        items = []

        # 模式选择（radio 互斥）
        for mode_key, mode_name in MODE_NAMES.items():
            items.append(
                self._pystray.MenuItem(
                    f"模式 {mode_key}：{mode_name}",
                    self._make_mode_handler(mode_key),
                    checked=lambda item, m=mode_key: self._current_mode == m,
                    radio=True,
                )
            )

        items.append(self._pystray.Menu.SEPARATOR)

        # 设置子菜单
        setting_items = []

        # 引擎选择
        engine_names = {
            "meituan": "美团 ASR",
            "xunfei": "讯飞实时",
            "windows": "Windows 原生",
        }
        for engine_key, engine_name in engine_names.items():
            setting_items.append(
                self._pystray.MenuItem(
                    engine_name,
                    self._make_engine_handler(engine_key),
                    checked=lambda item, e=engine_key: self._current_engine == e,
                    radio=True,
                )
            )

        items.append(
            self._pystray.MenuItem(
                "引擎选择",
                self._pystray.Menu(*setting_items),
            )
        )

        items.append(self._pystray.Menu.SEPARATOR)

        # 暂停/恢复
        items.append(
            self._pystray.MenuItem(
                lambda text: "恢复 Spoken" if self._paused else "暂停 Spoken",
                self._handle_pause_resume,
            )
        )

        items.append(self._pystray.Menu.SEPARATOR)

        # 查看日志
        if self._on_view_log:
            items.append(
                self._pystray.MenuItem(
                    "查看日志",
                    lambda icon=None, item=None: self._on_view_log(),
                )
            )

        items.append(self._pystray.Menu.SEPARATOR)

        # 退出
        items.append(
            self._pystray.MenuItem(
                "退出 Spoken",
                lambda icon=None, item=None: self._handle_quit(),
            )
        )

        return self._pystray.Menu(*items)

    def _make_mode_handler(self, mode: str) -> Callable:
        """为每个模式菜单项生成独立的回调函数。"""
        def handler(icon=None, item=None) -> None:
            self.set_mode(mode)
            if self._on_mode_change:
                try:
                    self._on_mode_change(mode)
                except Exception as e:
                    logger.error("模式切换回调异常: %s", e)
        return handler

    def _make_engine_handler(self, engine: str) -> Callable:
        """为每个引擎菜单项生成独立的回调函数。"""
        def handler(icon=None, item=None) -> None:
            self.set_engine(engine)
            if self._on_engine_change:
                try:
                    self._on_engine_change(engine)
                except Exception as e:
                    logger.error("引擎切换回调异常: %s", e)
        return handler

    def _handle_pause_resume(self, icon=None, item=None) -> None:
        """处理暂停/恢复菜单点击。"""
        self._paused = not self._paused
        if self._paused:
            logger.info("Spoken 已暂停（热键将不响应）")
        else:
            logger.info("Spoken 已恢复")
        if self._on_pause_resume:
            try:
                self._on_pause_resume(self._paused)
            except Exception as e:
                logger.error("暂停/恢复回调异常: %s", e)

    def _handle_quit(self) -> None:
        """处理退出菜单点击。"""
        logger.info("用户请求退出 Spoken")
        self.stop()
        if self._on_quit:
            try:
                self._on_quit()
            except Exception as e:
                logger.error("退出回调异常: %s", e)

    def _update_icon(self) -> None:
        """刷新托盘图标图像和工具提示。"""
        if self._icon is None:
            return
        try:
            self._icon.icon = self._build_icon_image()
            self._icon.title = self._build_tooltip()
        except Exception as e:
            logger.error("更新托盘图标失败: %s", e)

    def _update_menu(self) -> None:
        """刷新托盘右键菜单。"""
        if self._icon is None:
            return
        try:
            self._icon.menu = self._build_menu()
        except Exception as e:
            logger.error("更新托盘菜单失败: %s", e)
