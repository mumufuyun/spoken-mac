"""
spoken/injector/clipboard.py
剪贴板 Ctrl+V 文本注入实现。

适用场景：
- Electron 应用（VSCode, 飞书, Notion 等）
- SendInput 失败时的降级方案

注意事项：
- 注入前保存原剪贴板内容，注入后动态延迟恢复（基础 500ms + 每字符 2ms）
- 注入前需确保目标窗口已获得焦点
- 依赖 win32clipboard（pywin32 包含）
"""

from __future__ import annotations

import logging
import sys
import time
from typing import Optional

from .base import BaseInjector

logger = logging.getLogger(__name__)

# 注入后恢复剪贴板的延迟（毫秒）—— 基础值，实际会根据文本长度动态增加
CLIPBOARD_RESTORE_DELAY_MS = 500
# 焦点切换后的等待时间（毫秒）
FOCUS_DELAY_MS = 20


if sys.platform == "win32":
    import ctypes
    import ctypes.wintypes

    # Win32 按键常量
    VK_CONTROL = 0x11
    VK_V = 0x56
    KEYEVENTF_KEYUP = 0x0002

    def _keybd_event(vk: int, key_up: bool = False) -> None:
        """发送键盘事件（不依赖 pywin32）。"""
        flags = KEYEVENTF_KEYUP if key_up else 0
        ctypes.windll.user32.keybd_event(vk, 0, flags, 0)

    def _send_ctrl_v() -> None:
        """模拟按下并释放 Ctrl+V。"""
        _keybd_event(VK_CONTROL, key_up=False)
        _keybd_event(VK_V, key_up=False)
        time.sleep(0.012)
        _keybd_event(VK_V, key_up=True)
        _keybd_event(VK_CONTROL, key_up=True)

    def _clipboard_get_text() -> Optional[str]:
        """读取剪贴板文本内容。

        Returns:
            剪贴板文本，无文本或出错返回 None
        """
        try:
            import win32clipboard
            import win32con
            win32clipboard.OpenClipboard()
            try:
                if win32clipboard.IsClipboardFormatAvailable(win32con.CF_UNICODETEXT):
                    return win32clipboard.GetClipboardData(win32con.CF_UNICODETEXT)
            finally:
                win32clipboard.CloseClipboard()
        except Exception as e:
            logger.debug("读取剪贴板失败: %s", e)
        return None

    def _clipboard_set_text(text: str) -> bool:
        """设置剪贴板文本内容。

        Args:
            text: 要写入的文字

        Returns:
            True 表示成功
        """
        try:
            import win32clipboard
            import win32con
            win32clipboard.OpenClipboard()
            try:
                win32clipboard.EmptyClipboard()
                win32clipboard.SetClipboardData(win32con.CF_UNICODETEXT, text)
                return True
            finally:
                win32clipboard.CloseClipboard()
        except Exception as e:
            logger.error("设置剪贴板失败: %s", e)
            return False

    class ClipboardInjector(BaseInjector):
        """基于剪贴板 Ctrl+V 的文本注入器。

        特点：
        - 兼容 Electron 应用
        - 注入前保存用户剪贴板，注入后延迟恢复（防止污染）
        - 注入前确保目标窗口获得焦点
        """

        def __init__(
            self,
            focus_delay_ms: int = FOCUS_DELAY_MS,
            restore_delay_ms: int = CLIPBOARD_RESTORE_DELAY_MS,
        ) -> None:
            """初始化注入器。

            Args:
                focus_delay_ms: 焦点切换后的等待时间（毫秒）
                restore_delay_ms: 注入后恢复剪贴板的延迟（毫秒）
            """
            self._focus_delay_ms = focus_delay_ms
            self._restore_delay_ms = restore_delay_ms

        def inject(self, text: str, hwnd: Optional[int] = None) -> bool:
            """将文本通过剪贴板 Ctrl+V 注入到目标窗口。

            Args:
                text: 要注入的文字
                hwnd: 目标窗口句柄，提供则自动恢复焦点

            Returns:
                True 表示注入成功
            """
            if not text:
                return True

            # 1. 保存原剪贴板内容
            original_text = _clipboard_get_text()
            logger.debug("剪贴板原内容（前20字符）: %r", (original_text or "")[:20])

            # 2. 恢复目标窗口焦点
            if hwnd:
                from ..utils.window import restore_focus
                restore_focus(hwnd, self._focus_delay_ms)

            # 3. 写入待注入文本到剪贴板
            if not _clipboard_set_text(text):
                logger.error("无法设置剪贴板内容，注入失败")
                return False

            # 3.5 短暂等待确保系统剪贴板数据完全同步（长文本需要更久）
            time.sleep(0.05)

            # 4. 发送 Ctrl+V
            _send_ctrl_v()
            logger.debug("Ctrl+V 已发送，文本长度=%d", len(text))

            # 4.5 给目标应用（特别是 WebView2/Electron）开始处理 paste 的时间
            time.sleep(0.05)

            # 5. 延迟后恢复原剪贴板（在新线程中执行，不阻塞主流程）
            # 动态计算恢复延迟：基础 500ms + 每字符 2ms，最多 2000ms
            # 长文本时 WebView2/Chromium 的异步 paste 处理需要更长时间
            restore_ms = self._restore_delay_ms + min(len(text) * 2, 1500)
            if original_text is not None:
                import threading
                def _restore() -> None:
                    time.sleep(restore_ms / 1000.0)
                    try:
                        _clipboard_set_text(original_text)
                        logger.debug("剪贴板已恢复（延迟 %d ms）", restore_ms)
                    except Exception as e:
                        logger.error("剪贴板恢复失败: %s", e)

                t = threading.Thread(target=_restore, daemon=True, name="clipboard-restore")
                t.start()

            return True

else:
    # 非 Windows 平台的占位实现
    class ClipboardInjector(BaseInjector):  # type: ignore[no-redef]
        """非 Windows 平台的空实现（仅供开发测试）。"""

        def inject(self, text: str, hwnd=None) -> bool:  # type: ignore[override]
            logger.warning("ClipboardInjector 仅支持 Windows 平台")
            return False
