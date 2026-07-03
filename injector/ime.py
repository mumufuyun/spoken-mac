"""
spoken/injector/ime.py
IME（输入法）状态管理模块。

注入前临时关闭 IME，防止 Unicode SendInput 触发输入法预选框。
注入完成后恢复原始 IME 状态。
"""

from __future__ import annotations

import logging
import sys
from contextlib import contextmanager
from typing import Optional

logger = logging.getLogger(__name__)


if sys.platform == "win32":
    import ctypes
    import ctypes.wintypes

    # imm32.dll 函数签名定义
    _imm32 = ctypes.windll.imm32

    def _get_ime_context(hwnd: int) -> Optional[int]:
        """获取窗口的 IME 上下文句柄。

        Args:
            hwnd: 窗口句柄

        Returns:
            IME 上下文句柄，失败返回 None
        """
        himc = _imm32.ImmGetContext(hwnd)
        return himc if himc else None

    def _release_ime_context(hwnd: int, himc: int) -> None:
        """释放 IME 上下文句柄。"""
        _imm32.ImmReleaseContext(hwnd, himc)

    def get_ime_open_status(hwnd: int) -> bool:
        """获取窗口当前 IME 开关状态。

        Args:
            hwnd: 窗口句柄

        Returns:
            True 表示 IME 已开启，False 表示已关闭
        """
        himc = _get_ime_context(hwnd)
        if himc is None:
            return False
        try:
            status = bool(_imm32.ImmGetOpenStatus(himc))
            return status
        finally:
            _release_ime_context(hwnd, himc)

    def set_ime_open_status(hwnd: int, open_status: bool) -> bool:
        """设置窗口 IME 开关状态。

        Args:
            hwnd: 窗口句柄
            open_status: True 开启 IME，False 关闭 IME

        Returns:
            True 表示操作成功
        """
        himc = _get_ime_context(hwnd)
        if himc is None:
            logger.debug("hwnd=%d 没有 IME 上下文（可能不是输入框）", hwnd)
            return False
        try:
            result = bool(_imm32.ImmSetOpenStatus(himc, int(open_status)))
            if not result:
                logger.debug("ImmSetOpenStatus 返回 False，hwnd=%d", hwnd)
            return result
        finally:
            _release_ime_context(hwnd, himc)

    class ImeGuard:
        """IME 状态保护器，注入前关闭 IME，注入后恢复。

        使用示例::

            guard = ImeGuard(hwnd)
            guard.disable()    # 关闭 IME
            # ... 注入文字 ...
            guard.restore()    # 恢复原始状态

        或使用 with 语句::

            with ImeGuard.disabled(hwnd):
                # ... 注入文字 ...
        """

        def __init__(self, hwnd: int) -> None:
            self._hwnd = hwnd
            self._was_open: Optional[bool] = None

        def disable(self) -> None:
            """关闭 IME 并记录原始状态。"""
            try:
                self._was_open = get_ime_open_status(self._hwnd)
                if self._was_open:
                    set_ime_open_status(self._hwnd, False)
                    logger.debug("IME 已临时关闭，hwnd=%d", self._hwnd)
            except Exception as e:
                logger.error("关闭 IME 失败，hwnd=%d: %s", self._hwnd, e)
                self._was_open = None  # 标记为未知，恢复时跳过

        def restore(self) -> None:
            """恢复 IME 到原始状态。"""
            if self._was_open is None:
                return  # disable() 未成功调用，跳过
            try:
                if self._was_open:
                    set_ime_open_status(self._hwnd, True)
                    logger.debug("IME 已恢复，hwnd=%d", self._hwnd)
            except Exception as e:
                logger.error("恢复 IME 失败，hwnd=%d: %s", self._hwnd, e)
            finally:
                self._was_open = None

        @classmethod
        @contextmanager
        def disabled(cls, hwnd: int):
            """上下文管理器：在 with 块内禁用 IME，退出后自动恢复。

            Args:
                hwnd: 窗口句柄
            """
            guard = cls(hwnd)
            guard.disable()
            try:
                yield guard
            finally:
                guard.restore()

else:
    # 非 Windows 平台的占位实现
    def get_ime_open_status(hwnd: int) -> bool:  # type: ignore[misc]
        return False

    def set_ime_open_status(hwnd: int, open_status: bool) -> bool:  # type: ignore[misc]
        return False

    class ImeGuard:  # type: ignore[no-redef]
        """非 Windows 平台的空实现。"""

        def __init__(self, hwnd: int) -> None:
            pass

        def disable(self) -> None:
            pass

        def restore(self) -> None:
            pass

        @classmethod
        @contextmanager
        def disabled(cls, hwnd: int):
            yield cls(hwnd)
