"""
spoken/core/lifecycle.py
资源生命周期管理接口 — 统一管理模块的启动、停止和清理。

设计原则：
  - 所有需要初始化和清理的模块实现 Lifecycle 接口
  - 通过 LifecycleManager 统一协调启动/停止顺序
  - 支持依赖关系：A 依赖 B 则 B 先启动、后停止

使用示例::

    from spoken.core.lifecycle import Lifecycle, LifecycleManager

    class MyModule(Lifecycle):
        def start(self):
            print("启动")
        def stop(self):
            print("停止")

    mgr = LifecycleManager()
    mgr.register("my", MyModule())
    mgr.start_all()   # 按注册顺序启动
    mgr.stop_all()    # 按相反顺序停止
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)


class Lifecycle(ABC):
    """资源生命周期接口。

    实现此接口的类可被 LifecycleManager 统一管理。
    """

    @abstractmethod
    def start(self) -> None:
        """启动资源。可能抛出异常表示启动失败。"""
        ...

    @abstractmethod
    def stop(self) -> None:
        """停止资源。不应抛出异常（捕获并记录）。"""
        ...

    def is_ready(self) -> bool:
        """资源是否已就绪。默认实现返回 True。"""
        return True


class LifecycleManager:
    """生命周期管理器。

    按注册顺序启动，按相反顺序停止（依赖关系）。
    """

    def __init__(self) -> None:
        self._items: Dict[str, Lifecycle] = {}
        self._order: List[str] = []
        self._started: set[str] = set()

    def register(self, name: str, item: Lifecycle) -> None:
        """注册生命周期对象。

        Args:
            name: 对象名称
            item: 实现 Lifecycle 接口的对象
        """
        if name in self._items:
            logger.warning("生命周期对象 '%s' 已存在，将被覆盖", name)
        self._items[name] = item
        if name not in self._order:
            self._order.append(name)
        logger.debug("注册生命周期对象: %s", name)

    def unregister(self, name: str) -> bool:
        """注销对象。"""
        if name not in self._items:
            return False
        # 如果已启动，先停止
        if name in self._started:
            self._stop_one(name)
        del self._items[name]
        self._order.remove(name)
        return True

    def start_all(self) -> Dict[str, bool]:
        """启动所有已注册的对象。

        Returns:
            name -> success 的字典
        """
        results = {}
        for name in self._order:
            success = self._start_one(name)
            results[name] = success
        return results

    def stop_all(self) -> None:
        """停止所有已启动的对象（按相反顺序）。"""
        for name in reversed(self._order):
            if name in self._started:
                self._stop_one(name)

    def start(self, name: str) -> bool:
        """启动指定对象。"""
        return self._start_one(name)

    def stop(self, name: str) -> None:
        """停止指定对象。"""
        self._stop_one(name)

    def is_started(self, name: str) -> bool:
        """对象是否已启动。"""
        return name in self._started

    def list_items(self) -> List[str]:
        """列出所有已注册的对象名称。"""
        return list(self._order)

    # ── 内部方法 ──────────────────────────────────────────────────

    def _start_one(self, name: str) -> bool:
        item = self._items.get(name)
        if item is None:
            logger.error("生命周期对象 '%s' 未注册", name)
            return False
        if name in self._started:
            return True
        try:
            item.start()
            self._started.add(name)
            logger.info("已启动: %s", name)
            return True
        except Exception as e:
            logger.error("启动 '%s' 失败: %s", name, e, exc_info=True)
            return False

    def _stop_one(self, name: str) -> None:
        item = self._items.get(name)
        if item is None:
            return
        try:
            item.stop()
            logger.info("已停止: %s", name)
        except Exception as e:
            logger.error("停止 '%s' 时出错: %s", name, e, exc_info=True)
        finally:
            self._started.discard(name)

    def __repr__(self) -> str:
        started = ", ".join(name for name in self._order if name in self._started)
        return f"LifecycleManager(total={len(self._order)}, started=[{started}])"
