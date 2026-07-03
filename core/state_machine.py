"""spoken/core/state_machine.py
Spoken v2 状态机 — 统一管理应用运行时状态。

设计原则：
  - 所有状态转换必须经过状态机校验
  - 禁止任何模块直接修改状态
  - 状态转换时自动触发事件到事件总线
  - 支持进入/退出/转换回调

状态定义::

    Idle → Starting → Recording → Recognizing → AIProcessing → Injecting → Completed
     ↑                                                                    ↓
     └────────────────────────────────────────────────────────────────── Error

使用示例::

    from spoken.core.state_machine import StateMachine, State

    sm = StateMachine()
    sm.on_enter(State.RECORDING, lambda: print("开始录音"))
    sm.transition_to(State.RECORDING)  # 合法转换
    sm.transition_to(State.IDLE)       # 非法转换，抛出异常
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Callable, Dict, List, Optional, Set

from .events import Event, EventBus

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 状态定义
# ══════════════════════════════════════════════════════════════════════

class State(str, Enum):
    """应用处理状态枚举。"""

    IDLE = "idle"
    STARTING = "starting"
    RECORDING = "recording"
    RECOGNIZING = "recognizing"
    AI_PROCESSING = "ai_processing"
    INJECTING = "injecting"
    COMPLETED = "completed"
    ERROR = "error"


# ══════════════════════════════════════════════════════════════════════
# 转换规则
# ══════════════════════════════════════════════════════════════════════

# 合法状态转换图: from_state -> {allowed_to_states}
_TRANSITIONS: Dict[State, Set[State]] = {
    State.IDLE: {State.STARTING},
    State.STARTING: {State.RECORDING, State.ERROR, State.IDLE},
    State.RECORDING: {State.RECOGNIZING, State.ERROR, State.IDLE},
    State.RECOGNIZING: {State.AI_PROCESSING, State.INJECTING, State.COMPLETED, State.ERROR, State.IDLE},
    State.AI_PROCESSING: {State.INJECTING, State.COMPLETED, State.ERROR, State.IDLE},
    State.INJECTING: {State.COMPLETED, State.ERROR, State.IDLE},
    State.COMPLETED: {State.IDLE, State.STARTING},
    State.ERROR: {State.IDLE, State.STARTING},
}


@dataclass(frozen=True, slots=True)
class Transition:
    """状态转换记录。"""

    from_state: State
    to_state: State
    timestamp: float
    trigger: str = ""  # 转换触发原因/来源


# ══════════════════════════════════════════════════════════════════════
# 状态机
# ══════════════════════════════════════════════════════════════════════

class StateMachine:
    """线程安全的状态机。

    Attributes:
        state: 当前状态（只读，通过 transition_to 修改）
        history: 最近的状态转换历史
    """

    def __init__(self, event_bus: Optional[EventBus] = None) -> None:
        self._state = State.IDLE
        self._event_bus = event_bus
        self._history: List[Transition] = []
        self._lock = threading.RLock()

        # 回调注册表
        self._on_enter: Dict[State, List[Callable]] = {}
        self._on_exit: Dict[State, List[Callable]] = {}
        self._on_transition: Dict[tuple, List[Callable]] = {}

    # ── 状态查询 ──────────────────────────────────────────────────

    @property
    def state(self) -> State:
        """当前状态（只读）。"""
        with self._lock:
            return self._state

    @property
    def history(self) -> List[Transition]:
        """状态转换历史副本。"""
        with self._lock:
            return list(self._history)

    def is_idle(self) -> bool:
        return self.state == State.IDLE

    def is_processing(self) -> bool:
        """是否处于处理中状态（从 Recording 到 Injecting 之间）。"""
        return self.state in {
            State.STARTING,
            State.RECORDING,
            State.RECOGNIZING,
            State.AI_PROCESSING,
            State.INJECTING,
        }

    def can_transition_to(self, target: State) -> bool:
        """检查是否允许转换到目标状态。"""
        with self._lock:
            allowed = _TRANSITIONS.get(self._state, set())
            return target in allowed

    # ── 状态转换 ──────────────────────────────────────────────────

    def transition_to(
        self,
        target: State,
        *,
        trigger: str = "",
        force: bool = False,
    ) -> Transition:
        """执行状态转换。

        Args:
            target: 目标状态
            trigger: 转换触发原因（用于日志和追踪）
            force: 是否跳过合法性检查（仅用于紧急重置）

        Returns:
            Transition 转换记录

        Raises:
            ValueError: 转换不合法且 force=False
        """
        with self._lock:
            current = self._state

            if not force and target not in _TRANSITIONS.get(current, set()):
                raise ValueError(
                    f"非法状态转换: {current.value} -> {target.value}"
                )

            # 执行退出回调
            self._run_callbacks(self._on_exit.get(current, []), current, target)

            # 执行转换
            self._state = target
            trans = Transition(
                from_state=current,
                to_state=target,
                timestamp=time.time(),
                trigger=trigger,
            )
            self._history.append(trans)
            # 保留最近 50 条历史
            if len(self._history) > 50:
                self._history = self._history[-50:]

            logger.info(
                "状态转换: %s -> %s (trigger=%s)",
                current.value,
                target.value,
                trigger,
            )

            # 执行进入回调
            self._run_callbacks(self._on_enter.get(target, []), current, target)

            # 执行特定转换回调
            key = (current, target)
            self._run_callbacks(self._on_transition.get(key, []), current, target)

        # 发布事件（在锁外执行，避免回调死锁）
        if self._event_bus is not None:
            self._event_bus.emit(
                "state_changed",
                {
                    "from": current.value,
                    "to": target.value,
                    "trigger": trigger,
                },
            )

        return trans

    def reset(self, trigger: str = "reset") -> Transition:
        """强制重置到 Idle 状态。"""
        return self.transition_to(State.IDLE, trigger=trigger, force=True)

    # ── 回调注册 ──────────────────────────────────────────────────

    def on_enter(self, state: State, callback: Callable[[State, State], None]) -> None:
        """注册进入某状态的回调。

        Args:
            state: 目标状态
            callback: 接收 (from_state, to_state) 参数
        """
        self._on_enter.setdefault(state, []).append(callback)

    def on_exit(self, state: State, callback: Callable[[State, State], None]) -> None:
        """注册退出某状态的回调。

        Args:
            state: 源状态
            callback: 接收 (from_state, to_state) 参数
        """
        self._on_exit.setdefault(state, []).append(callback)

    def on_transition(
        self,
        from_state: State,
        to_state: State,
        callback: Callable[[State, State], None],
    ) -> None:
        """注册特定转换的回调。"""
        key = (from_state, to_state)
        self._on_transition.setdefault(key, []).append(callback)

    # ── 内部方法 ──────────────────────────────────────────────────

    def _run_callbacks(
        self,
        callbacks: List[Callable[[State, State], None]],
        from_state: State,
        to_state: State,
    ) -> None:
        for cb in callbacks:
            try:
                cb(from_state, to_state)
            except Exception as e:
                logger.error("状态回调异常: %s", e, exc_info=True)

    def __repr__(self) -> str:
        return f"StateMachine(state={self.state.value})"


import time
