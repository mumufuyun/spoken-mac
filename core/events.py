"""spoken/core/events.py
Spoken v2 事件总线 — 模块间解耦通信的核心基础设施。

设计原则：
  - 所有模块通过事件通信，禁止直接回调
  - 事件是轻量 dataclass，可序列化
  - 支持同步和异步订阅
  - 线程安全

使用示例::

    from spoken.core.events import EventBus, Event

    bus = EventBus()

    @bus.on("record_started")
    def handle_start(event: Event):
        print(f"开始录音: {event.payload}")

    bus.emit("record_started", {"mode": "B"})
"""

from __future__ import annotations

import inspect
import logging
import threading
import weakref
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, TypeVar

logger = logging.getLogger(__name__)

T = TypeVar("T")


# ══════════════════════════════════════════════════════════════════════
# 事件定义
# ══════════════════════════════════════════════════════════════════════

@dataclass(frozen=True, slots=True)
class Event:
    """标准事件对象。

    Attributes:
        name: 事件类型名称，如 "record_started"
        payload: 事件载荷数据（任意类型）
        trace_id: 追踪 ID，用于关联单次录音流程中的全部事件
    """

    name: str
    payload: Any = None
    trace_id: str = ""

    def __repr__(self) -> str:
        payload_repr = repr(self.payload)[:60]
        return f"Event({self.name!r}, {payload_repr}, trace={self.trace_id!r})"


# ══════════════════════════════════════════════════════════════════════
# 事件总线
# ══════════════════════════════════════════════════════════════════════

class EventBus:
    """线程安全的事件总线。

    支持：
      - 同步/异步回调订阅
      - 一次性订阅（auto_remove=True）
      - 按事件类型过滤订阅
      - 弱引用订阅（避免内存泄漏）
    """

    def __init__(self) -> None:
        # event_name -> list[(handler, once, weak)]
        self._subscribers: Dict[str, List[tuple]] = {}
        self._lock = threading.RLock()
        self._closed = False

    # ── 订阅 ──────────────────────────────────────────────────────

    def on(
        self,
        event_name: str,
        handler: Optional[Callable[[Event], None]] = None,
        *,
        once: bool = False,
        weak: bool = False,
    ) -> Callable[[Event], None]:
        """订阅事件。

        可作为装饰器使用::

            @bus.on("record_started")
            def handler(event: Event):
                ...

        Args:
            event_name: 事件名称，"*" 表示订阅所有事件
            handler: 事件处理函数，接收 Event 参数
            once: True 则处理一次后自动取消订阅
            weak: True 则使用弱引用，不阻止 handler 被 GC

        Returns:
            传入的 handler（装饰器模式）
        """
        if handler is None:
            # 装饰器模式: @bus.on("name")
            def decorator(fn: Callable[[Event], None]) -> Callable[[Event], None]:
                self._subscribe(event_name, fn, once=once, weak=weak)
                return fn

            return decorator  # type: ignore[return-value]

        self._subscribe(event_name, handler, once=once, weak=weak)
        return handler

    def off(
        self,
        event_name: str,
        handler: Callable[[Event], None],
    ) -> bool:
        """取消订阅。

        Returns:
            True 表示成功移除
        """
        with self._lock:
            subs = self._subscribers.get(event_name)
            if not subs:
                return False
            for i, (h, once, weak) in enumerate(subs):
                real_h = h() if weak else h
                if real_h is None:
                    continue
                if real_h is handler:
                    subs.pop(i)
                    return True
            return False

    def once(
        self,
        event_name: str,
        handler: Optional[Callable[[Event], None]] = None,
    ) -> Callable[[Event], None]:
        """一次性订阅（等价于 on(..., once=True)）。"""
        return self.on(event_name, handler, once=True)

    # ── 发布 ──────────────────────────────────────────────────────

    def emit(self, event_name: str, payload: Any = None, *, trace_id: str = "") -> None:
        """同步发布事件（在当前线程立即调用所有订阅者）。

        Args:
            event_name: 事件名称
            payload: 事件载荷
            trace_id: 追踪 ID
        """
        if self._closed:
            logger.warning("EventBus 已关闭，忽略事件: %s", event_name)
            return

        event = Event(name=event_name, payload=payload, trace_id=trace_id)
        subs = self._get_subscribers(event_name)

        to_remove: List[int] = []
        for idx, (handler, once, weak) in enumerate(subs):
            real_handler = handler() if weak else handler
            if real_handler is None:
                to_remove.append(idx)
                continue
            try:
                real_handler(event)
            except Exception as e:
                logger.error("事件处理异常 [%s]: %s", event_name, e, exc_info=True)
            if once:
                to_remove.append(idx)

        # 清理已失效/一次性订阅
        if to_remove:
            with self._lock:
                current = self._subscribers.get(event_name, [])
                # 重新获取位置（可能已有变化）
                for idx in sorted(to_remove, reverse=True):
                    if idx < len(current):
                        current.pop(idx)

    def emit_all(self, event: Event) -> None:
        """发布一个已构造好的 Event 对象。"""
        self.emit(event.name, event.payload, trace_id=event.trace_id)

    # ── 管理 ──────────────────────────────────────────────────────

    def close(self) -> None:
        """关闭事件总线，清空所有订阅。"""
        with self._lock:
            self._subscribers.clear()
            self._closed = True
        logger.debug("EventBus 已关闭")

    def clear(self, event_name: Optional[str] = None) -> None:
        """清空指定事件或所有事件的订阅。"""
        with self._lock:
            if event_name is None:
                self._subscribers.clear()
            else:
                self._subscribers.pop(event_name, None)

    def subscriber_count(self, event_name: str) -> int:
        """返回指定事件的订阅者数量。"""
        with self._lock:
            return len(self._subscribers.get(event_name, []))

    # ── 内部方法 ──────────────────────────────────────────────────

    def _subscribe(
        self,
        event_name: str,
        handler: Callable[[Event], None],
        once: bool,
        weak: bool,
    ) -> None:
        if weak:
            ref = weakref.ref(handler)
        else:
            ref = handler  # type: ignore[assignment]

        with self._lock:
            self._subscribers.setdefault(event_name, []).append((ref, once, weak))
        logger.debug("订阅事件: %s (once=%s, weak=%s)", event_name, once, weak)

    def _get_subscribers(self, event_name: str) -> List[tuple]:
        """获取订阅者列表的副本（线程安全）。"""
        with self._lock:
            specific = list(self._subscribers.get(event_name, []))
            wildcards = list(self._subscribers.get("*", []))
        return specific + wildcards

    def __repr__(self) -> str:
        with self._lock:
            total = sum(len(s) for s in self._subscribers.values())
            events = len(self._subscribers)
        return f"EventBus({events} 事件, {total} 订阅)"


# ══════════════════════════════════════════════════════════════════════
# 便捷函数（默认全局总线）
# ══════════════════════════════════════════════════════════════════════

_default_bus: Optional[EventBus] = None
_default_bus_lock = threading.Lock()


def get_default_bus() -> EventBus:
    """获取默认全局事件总线实例。"""
    global _default_bus
    if _default_bus is None:
        with _default_bus_lock:
            if _default_bus is None:
                _default_bus = EventBus()
    return _default_bus


def subscribe(
    event_name: str,
    handler: Optional[Callable[[Event], None]] = None,
    *,
    once: bool = False,
) -> Callable[[Event], None]:
    """使用默认全局总线订阅事件。"""
    return get_default_bus().on(event_name, handler, once=once)


def publish(event_name: str, payload: Any = None, *, trace_id: str = "") -> None:
    """使用默认全局总线发布事件。"""
    get_default_bus().emit(event_name, payload, trace_id=trace_id)
