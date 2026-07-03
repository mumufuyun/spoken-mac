"""
spoken/injector/dispatcher.py
注入策略分发器。

策略选择逻辑：
1. config method="clipboard" → 强制剪贴板
2. config method="sendinput" → 强制 SendInput
3. config method="auto"（默认）：
   - Electron 应用 → 剪贴板（配置列表 + 内置 ELECTRON_APPS）
   - UWP 应用 → 剪贴板
   - 目标进程已提权（UAC）且当前进程未提权 → 跳过注入，提示用户
   - 其他 → SendInput，失败自动降级剪贴板

整个注入流程：
  恢复焦点 → 关闭 IME → 注入 → 恢复 IME
"""

from __future__ import annotations

import logging
import sys
from contextlib import contextmanager
from typing import Any, Optional

from .base import BaseInjector
from .clipboard import ClipboardInjector
from .registry import InjectorRegistry
from .sendinput import SendInputInjector
from ..utils.window import WindowInfo, get_foreground_window_info, restore_focus

logger = logging.getLogger(__name__)


class TextDispatcher:
    """文本注入策略分发器，根据目标应用类型选择最优注入方案。

    使用示例::

        dispatcher = TextDispatcher(config=settings.get_section("injection"))
        # 录音开始时记录焦点
        dispatcher.capture_focus()
        # 注入文字
        dispatcher.inject("识别出的文字")
    """

    def __init__(
        self,
        method: str = "auto",
        focus_delay_ms: int = 20,
        char_delay_ms: int = 0,
        batch_size: int = 120,
        batch_delay_ms: int = 0,
        clipboard_force_apps: Optional[list] = None,
        target_window: str = "smart",
        event_bus: Optional[Any] = None,
    ) -> None:
        """初始化分发器。

        Args:
            method: 注入方案（auto / sendinput / clipboard）
            focus_delay_ms: 焦点恢复等待时间（毫秒）
            char_delay_ms: SendInput 字符间延迟（毫秒）
            batch_size: SendInput 分批大小
            batch_delay_ms: SendInput 批间延迟（毫秒）
            clipboard_force_apps: 额外强制走剪贴板的进程名列表（小写）
            target_window: 注入目标窗口策略（locked_on_start / current / smart）
            event_bus: 事件总线实例（可选）
        """
        self._method = method
        self._focus_delay_ms = focus_delay_ms
        self._target_window = target_window if target_window in ("locked_on_start", "current", "smart") else "smart"
        self._clipboard_force_apps = frozenset(
            app.lower() for app in (clipboard_force_apps or [])
        )

        # 注入器注册表（v2 插件化）
        self._registry = InjectorRegistry(event_bus=event_bus)
        self._sendinput = SendInputInjector(
            char_delay_ms=char_delay_ms,
            batch_size=batch_size,
            batch_delay_ms=batch_delay_ms,
        )
        self._clipboard = ClipboardInjector(
            focus_delay_ms=focus_delay_ms,
        )
        self._registry.register("sendinput", self._sendinput)
        self._registry.register("clipboard", self._clipboard)

        # 注册自动选择器
        self._registry.register_selector("dispatcher", self._select_injector_name)

        # 录音开始时保存的焦点窗口信息
        self._captured_window: Optional[WindowInfo] = None

    @property
    def captured_window(self) -> Optional[WindowInfo]:
        """返回最后捕获的焦点窗口信息（只读）。"""
        return self._captured_window

    @classmethod
    def from_config(cls, config: dict) -> "TextDispatcher":
        """从配置字典创建实例。

        Args:
            config: Settings.get_section("injection") 返回的字典

        Returns:
            TextDispatcher 实例
        """
        return cls(
            method=str(config.get("method", "auto")),
            focus_delay_ms=int(config.get("focus_delay_ms", 20)),
            char_delay_ms=int(config.get("char_delay_ms", 0)),
            batch_size=int(config.get("batch_size", 120)),
            batch_delay_ms=int(config.get("batch_delay_ms", 0)),
            clipboard_force_apps=config.get("clipboard_force_apps", []),
            target_window=str(config.get("target_window", "smart")),
        )

    def capture_focus(self) -> Optional[WindowInfo]:
        """记录当前前台窗口信息（应在录音开始时调用）。

        Returns:
            捕获的 WindowInfo，失败返回 None
        """
        self._captured_window = get_foreground_window_info()
        if self._captured_window:
            logger.debug(
                "焦点已记录: %s (pid=%d)",
                self._captured_window.exe_name,
                self._captured_window.pid,
            )
        else:
            logger.warning("capture_focus: 无法获取前台窗口信息")
        return self._captured_window

    def _resolve_target_window(self) -> Optional[WindowInfo]:
        """根据策略选择最终注入目标窗口。"""
        captured = self._captured_window
        if self._target_window == "locked_on_start":
            return captured

        current = get_foreground_window_info()
        if self._target_window == "current":
            return current or captured

        if current is None:
            return captured
        if captured is None:
            return current
        if current.hwnd == captured.hwnd:
            return current
        if current.pid == captured.pid:
            logger.debug("目标窗口策略 smart：同一进程，跟随当前焦点窗口")
            return current
        if current.exe_name and current.exe_name == captured.exe_name:
            logger.debug("目标窗口策略 smart：同一应用，跟随当前焦点窗口")
            return current
        return captured

    def inject(self, text: str) -> bool:
        """根据策略将文本注入到之前捕获的焦点窗口。

        Args:
            text: 要注入的文字

        Returns:
            True 表示注入成功
        """
        if not text:
            return True

        if sys.platform != "win32":
            logger.warning("文本注入仅支持 Windows 平台，当前平台: %s", sys.platform)
            return False

        window = self._resolve_target_window()
        if window is not None:
            self._captured_window = window

        # ── 1. 恢复焦点 ──────────────────────────────────────────
        if window:
            ok = restore_focus(window.hwnd, self._focus_delay_ms)
            if not ok:
                logger.warning("焦点恢复失败（窗口可能已关闭），尝试直接注入")

        # ── 2. 选择注入策略 ────────────────────────────────────────
        injector = self._select_injector(window)
        if injector is None:
            # UAC 提权窗口，无法注入
            logger.error(
                "目标窗口 %s 需要管理员权限才能注入，请以管理员身份运行 Spoken",
                window.exe_name if window else "未知",
            )
            return False

        # ── 3. 处理 IME ────────────────────────────────────────────
        # 仅在 SendInput 方案下需要处理 IME（剪贴板方案不受 IME 影响）
        if isinstance(injector, SendInputInjector) and window:
            from .ime import ImeGuard
            with ImeGuard.disabled(window.hwnd):
                return injector.inject_safe(text)
        else:
            # 剪贴板方案：传入 hwnd 做焦点恢复（inject 内部会二次确认）
            if isinstance(injector, ClipboardInjector) and window:
                return injector.inject(text, hwnd=window.hwnd)
            return injector.inject_safe(text)

    def _select_injector_name(self) -> Optional[str]:
        """根据当前窗口信息选择注入器名称（供注册表选择器使用）。

        Returns:
            注入器名称，None 表示无法注入
        """
        window = self._resolve_target_window()

        # 强制模式
        if self._method == "clipboard":
            return "clipboard"
        if self._method == "sendinput":
            return "sendinput"

        # auto 模式
        if window is None:
            return "sendinput"

        # UAC 提权检测
        if window.is_elevated:
            import ctypes as _ctypes
            try:
                current_elevated = bool(_ctypes.windll.shell32.IsUserAnAdmin())
            except Exception:
                current_elevated = False
            if not current_elevated:
                logger.error(
                    "目标进程 %s 已提权，Spoken 未以管理员运行，无法注入",
                    window.exe_name,
                )
                return None

        # Electron / 强制剪贴板
        if window.is_electron or window.exe_name in self._clipboard_force_apps:
            return "clipboard"

        # UWP
        if window.is_uwp:
            return "clipboard"

        return "sendinput"

    def _select_injector(self, window: Optional[WindowInfo]) -> Optional[BaseInjector]:
        """根据窗口信息选择注入器（向后兼容）。

        Args:
            window: 目标窗口信息，None 表示未知

        Returns:
            选中的注入器，None 表示无法注入（如 UAC 提权窗口）
        """
        name = self._select_injector_name()
        if name is None:
            return None
        return self._registry.get(name)

    def inject_with_fallback(self, text: str) -> bool:
        """注入文本，SendInput 失败时自动降级到剪贴板方案。

        增加重试机制：剪贴板注入失败时最多重试 2 次，
        每次间隔 50ms（等待焦点恢复）。

        Args:
            text: 要注入的文字

        Returns:
            True 表示注入成功
        """
        if not text:
            return True

        window = self._resolve_target_window()
        if window is not None:
            self._captured_window = window

        # 先尝试正常注入流程
        if self._method in ("clipboard",) or (
            window and (window.is_electron or window.is_uwp or window.exe_name in self._clipboard_force_apps)
        ):
            return self._inject_with_retry(text, max_retries=2)

        # SendInput → 失败 → 降级剪贴板
        if window:
            restore_focus(window.hwnd, self._focus_delay_ms)

        from .ime import ImeGuard
        hwnd = window.hwnd if window else 0
        with ImeGuard.disabled(hwnd) if hwnd else _null_context():
            success = self._sendinput.inject_safe(text)

        if not success:
            logger.warning("SendInput 失败，自动降级到剪贴板方案")
            if window:
                restore_focus(window.hwnd, self._focus_delay_ms)
            success = self._inject_with_retry(text, max_retries=2)

        return success

    def _inject_with_retry(self, text: str, max_retries: int = 2) -> bool:
        """带重试的剪贴板注入。

        Args:
            text: 要注入的文字
            max_retries: 最大重试次数

        Returns:
            True 表示注入成功
        """
        import time as _time
        window = self._captured_window

        for attempt in range(max_retries + 1):
            hwnd = window.hwnd if window else None
            if self._clipboard.inject(text, hwnd=hwnd):
                return True
            if attempt < max_retries:
                logger.debug("剪贴板注入第 %d 次失败，等待后重试", attempt + 1)
                _time.sleep(self._focus_delay_ms / 1000.0)
                if window:
                    restore_focus(window.hwnd, self._focus_delay_ms)

        logger.error("剪贴板注入 %d 次尝试均失败", max_retries + 1)
        return False


@contextmanager
def _null_context():
    """简单的空上下文管理器，用于 hwnd=0 时占位。"""
    yield
