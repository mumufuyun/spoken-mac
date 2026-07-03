"""
spoken/injector/registry.py
注入器插件注册表 — 支持动态注册和选择注入策略。

使用示例::

    from spoken.injector.registry import InjectorRegistry
    from spoken.injector.sendinput import SendInputInjector
    from spoken.injector.clipboard import ClipboardInjector

    registry = InjectorRegistry()
    registry.register("sendinput", SendInputInjector())
    registry.register("clipboard", ClipboardInjector())

    # 选择并注入
    injector = registry.select("clipboard")
    injector.inject("Hello World")
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Dict, List, Optional

from .base import BaseInjector

logger = logging.getLogger(__name__)


class InjectorRegistry:
    """注入器插件注册表。

    职责：
      - 注册/注销注入器插件
      - 根据策略名称或条件选择最佳注入器
      - 支持优先级排序
    """

    def __init__(self, event_bus: Optional[Any] = None) -> None:
        self._injectors: Dict[str, BaseInjector] = {}
        self._selectors: Dict[str, Callable[[], Optional[str]]] = {}
        self._event_bus = event_bus

    # ── 注册 ──────────────────────────────────────────────────────

    def register(self, name: str, injector: BaseInjector) -> None:
        """注册注入器。

        Args:
            name: 注入器标识名
            injector: 注入器实例
        """
        self._injectors[name] = injector
        logger.debug("注册注入器: %s", name)

    def unregister(self, name: str) -> bool:
        """注销注入器。"""
        if name in self._injectors:
            del self._injectors[name]
            logger.debug("注销注入器: %s", name)
            return True
        return False

    def register_selector(self, name: str, selector: Callable[[], Optional[str]]) -> None:
        """注册选择器函数。

        选择器返回注入器名称，或 None 表示不匹配。
        """
        self._selectors[name] = selector

    # ── 查询 ──────────────────────────────────────────────────────

    def get(self, name: str) -> Optional[BaseInjector]:
        """按名称获取注入器。"""
        return self._injectors.get(name)

    def list_injectors(self) -> List[str]:
        """列出所有已注册的注入器名称。"""
        return list(self._injectors.keys())

    def has(self, name: str) -> bool:
        """是否存在指定注入器。"""
        return name in self._injectors

    # ── 选择 ──────────────────────────────────────────────────────

    def select(self, name: str) -> Optional[BaseInjector]:
        """按名称选择注入器。"""
        injector = self._injectors.get(name)
        if injector is None:
            logger.warning("未找到注入器: %s", name)
        return injector

    def auto_select(self) -> Optional[BaseInjector]:
        """通过选择器自动选择注入器。

        按注册顺序调用选择器，第一个返回非 None 的被使用。
        """
        for sel_name, selector in self._selectors.items():
            try:
                chosen = selector()
                if chosen and chosen in self._injectors:
                    logger.debug("选择器 '%s' 选中注入器: %s", sel_name, chosen)
                    return self._injectors[chosen]
            except Exception as e:
                logger.warning("选择器 '%s' 出错: %s", sel_name, e)
        return None

    # ── 注入 ──────────────────────────────────────────────────────

    def inject(self, text: str, name: str = "auto") -> bool:
        """使用指定注入器注入文本。

        Args:
            text: 要注入的文字
            name: 注入器名称，"auto" 则使用 auto_select

        Returns:
            True 表示注入成功
        """
        if name == "auto":
            injector = self.auto_select()
        else:
            injector = self.select(name)

        if injector is None:
            logger.error("没有可用的注入器")
            return False

        result = injector.inject_safe(text)
        self._emit("text_injected", {"success": result, "injector": name})
        return result

    # ── 内部 ──────────────────────────────────────────────────────

    def _emit(self, event_name: str, payload: Dict[str, Any]) -> None:
        if self._event_bus is not None:
            try:
                self._event_bus.emit(event_name, payload)
            except Exception as e:
                logger.warning("发布事件 '%s' 失败: %s", event_name, e)

    def __repr__(self) -> str:
        return f"InjectorRegistry({self.list_injectors()})"
