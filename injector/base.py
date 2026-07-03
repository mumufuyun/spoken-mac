"""
spoken/injector/base.py
文本注入器抽象基类。
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod

logger = logging.getLogger(__name__)


class BaseInjector(ABC):
    """文本注入器抽象基类。

    具体实现：
    - SendInputInjector：Win32 SendInput KEYEVENTF_UNICODE
    - ClipboardInjector：剪贴板 Ctrl+V 方案
    """

    @abstractmethod
    def inject(self, text: str) -> bool:
        """将文本注入到当前焦点窗口。

        Args:
            text: 要注入的文字

        Returns:
            True 表示注入成功，False 表示失败
        """
        ...

    def inject_safe(self, text: str) -> bool:
        """带异常捕获的安全注入（不会抛出异常）。

        Args:
            text: 要注入的文字

        Returns:
            True 表示成功，False 表示失败
        """
        try:
            return self.inject(text)
        except Exception as e:
            logger.error("%s 注入失败: %s", type(self).__name__, e)
            return False

    def __repr__(self) -> str:
        return f"{type(self).__name__}()"
