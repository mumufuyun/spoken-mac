"""
spoken/injector/sendinput.py
Win32 SendInput KEYEVENTF_UNICODE 文本注入实现。

适用场景：大多数 Win32/WPF/Qt 原生应用
注意事项：
- Electron 应用不稳定，应由 dispatcher 降级到剪贴板方案
- IME 开启时会触发预选框，需由外部调用 ImeGuard 处理
- 超长文本按 batch_size 分批发送，防止 SendInput 缓冲区溢出
"""

from __future__ import annotations

import logging
import sys
import time
from typing import List

from .base import BaseInjector

logger = logging.getLogger(__name__)

# 默认参数
DEFAULT_CHAR_DELAY_MS = 0    # 字符间延迟（毫秒），0=无延迟
DEFAULT_BATCH_SIZE = 120     # 分批大小（字符数）
DEFAULT_BATCH_DELAY_MS = 0   # 批间延迟（毫秒），0=无延迟


if sys.platform == "win32":
    import ctypes
    import ctypes.wintypes

    # Win32 常量
    INPUT_KEYBOARD = 1
    KEYEVENTF_UNICODE = 0x0004
    KEYEVENTF_KEYUP = 0x0002

    class _KEYBDINPUT(ctypes.Structure):
        """Win32 KEYBDINPUT 结构体。"""
        _fields_ = [
            ("wVk",         ctypes.wintypes.WORD),
            ("wScan",       ctypes.wintypes.WORD),
            ("dwFlags",     ctypes.wintypes.DWORD),
            ("time",        ctypes.wintypes.DWORD),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class _INPUT_UNION(ctypes.Union):
        _fields_ = [("ki", _KEYBDINPUT)]

    class _INPUT(ctypes.Structure):
        """Win32 INPUT 结构体。"""
        _anonymous_ = ("_input",)
        _fields_ = [
            ("type",   ctypes.wintypes.DWORD),
            ("_input", _INPUT_UNION),
        ]

    def _make_key_event(char_code: int, key_up: bool = False) -> _INPUT:
        """创建单个 Unicode 按键事件。

        Args:
            char_code: Unicode 码点
            key_up: True 为抬起事件，False 为按下事件

        Returns:
            _INPUT 实例
        """
        flags = KEYEVENTF_UNICODE
        if key_up:
            flags |= KEYEVENTF_KEYUP
        return _INPUT(
            type=INPUT_KEYBOARD,
            ki=_KEYBDINPUT(
                wVk=0,
                wScan=char_code,
                dwFlags=flags,
                time=0,
                dwExtraInfo=None,
            ),
        )

    def _send_inputs(inputs: List[_INPUT]) -> int:
        """批量发送输入事件。

        Args:
            inputs: INPUT 列表

        Returns:
            成功发送的事件数
        """
        if not inputs:
            return 0
        arr = (_INPUT * len(inputs))(*inputs)
        sent = ctypes.windll.user32.SendInput(
            len(inputs),
            arr,
            ctypes.sizeof(_INPUT),
        )
        return sent

    class SendInputInjector(BaseInjector):
        """基于 Win32 SendInput KEYEVENTF_UNICODE 的文本注入器。

        特点：
        - 不依赖剪贴板，不污染用户数据
        - 支持所有 Unicode 字符（含中文、Emoji）
        - 字符间可配置延迟，防止应用漏字
        - 超长文本自动分批
        """

        def __init__(
            self,
            char_delay_ms: int = DEFAULT_CHAR_DELAY_MS,
            batch_size: int = DEFAULT_BATCH_SIZE,
            batch_delay_ms: int = DEFAULT_BATCH_DELAY_MS,
        ) -> None:
            """初始化注入器。

            Args:
                char_delay_ms: 每个字符的按下/抬起事件之间的延迟（毫秒）
                batch_size: 每批发送的字符数
                batch_delay_ms: 批间等待时间（毫秒）
            """
            self._char_delay_ms = char_delay_ms
            self._batch_size = batch_size
            self._batch_delay_ms = batch_delay_ms

        def inject(self, text: str) -> bool:
            """将文本通过 SendInput 注入到当前焦点窗口。

            Args:
                text: 要注入的文字

            Returns:
                True 表示全部字符注入成功
            """
            if not text:
                return True

            # 处理代理对（Emoji 等 BMP 外字符需要代理对）
            chars = self._expand_to_surrogates(text)
            batches = [chars[i:i + self._batch_size] for i in range(0, len(chars), self._batch_size)]

            total_sent = 0
            for batch_idx, batch in enumerate(batches):
                inputs: List[_INPUT] = []
                for char_code in batch:
                    inputs.append(_make_key_event(char_code, key_up=False))
                    inputs.append(_make_key_event(char_code, key_up=True))

                sent = _send_inputs(inputs)
                total_sent += sent // 2  # 每字符 2 个事件（down + up）

                if self._char_delay_ms > 0:
                    time.sleep(self._char_delay_ms / 1000.0 * len(batch))

                # 批间延迟
                if batch_idx < len(batches) - 1 and self._batch_delay_ms > 0:
                    time.sleep(self._batch_delay_ms / 1000.0)

            success = (total_sent >= len(chars))
            if not success:
                logger.warning(
                    "SendInput 注入不完整：期望 %d 字符，实际 %d 字符",
                    len(chars), total_sent,
                )
            else:
                logger.debug("SendInput 注入成功，共 %d 字符", len(chars))
            return success

        @staticmethod
        def _expand_to_surrogates(text: str) -> List[int]:
            """将字符串展开为 UTF-16LE 码单元列表（处理 BMP 外字符的代理对）。

            Args:
                text: 输入字符串

            Returns:
                UTF-16LE 码单元列表（每个 int 为 0x0000-0xFFFF）
            """
            result: List[int] = []
            encoded = text.encode("utf-16-le")
            for i in range(0, len(encoded), 2):
                code_unit = int.from_bytes(encoded[i:i+2], "little")
                result.append(code_unit)
            return result

else:
    # 非 Windows 平台的占位实现
    class SendInputInjector(BaseInjector):  # type: ignore[no-redef]
        """非 Windows 平台的空实现（仅供开发测试）。"""

        def inject(self, text: str) -> bool:
            logger.warning("SendInputInjector 仅支持 Windows 平台")
            return False
