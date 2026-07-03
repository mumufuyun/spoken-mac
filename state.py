"""
spoken/state.py
应用状态控制器 — 管理 Spoken 的运行时状态。

职责：
  - 维护当前工作模式（A/B/C/D/E/F）
  - 维护当前处理状态（ready/recording/recognizing/ai_processing/injecting/error）
  - 通知 UI 层（托盘、浮窗）状态变更
  - 模式切换与持久化

将状态管理从 SpokenApp 中解耦，使其可独立测试。
"""

from __future__ import annotations

import logging
import threading
from enum import Enum
from typing import List, Optional, Protocol

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 状态定义
# ══════════════════════════════════════════════════════════════════════

class AppState(str, Enum):
    """应用处理状态。"""
    READY         = "ready"
    STARTING      = "starting"
    RECORDING     = "recording"
    RECOGNIZING   = "recognizing"
    AI_PROCESSING = "ai_processing"
    INJECTING     = "injecting"
    ERROR         = "error"


class WorkMode(str, Enum):
    """工作模式。"""
    DIRECT          = "A"  # 直接注入
    POLISH          = "B"  # 润色优化
    TO_PROMPT       = "C"  # 转 Prompt
    TRANSLATE       = "D"  # 翻译为英文
    MEETING_MINUTES = "E"  # 会议纪要
    STRUCTURED      = "F"  # 内容结构化整理


# 模式循环顺序
_MODE_CYCLE = {
    WorkMode.DIRECT: WorkMode.POLISH,
    WorkMode.POLISH: WorkMode.TO_PROMPT,
    WorkMode.TO_PROMPT: WorkMode.TRANSLATE,
    WorkMode.TRANSLATE: WorkMode.MEETING_MINUTES,
    WorkMode.MEETING_MINUTES: WorkMode.STRUCTURED,
    WorkMode.STRUCTURED: WorkMode.DIRECT,
}

MODE_NAMES = {
    "A": "直接注入",
    "B": "润色优化",
    "C": "转 Prompt",
    "D": "翻译英文",
    "E": "会议纪要",
    "F": "内容结构化",
}


# ══════════════════════════════════════════════════════════════════════
# 观察者协议
# ══════════════════════════════════════════════════════════════════════

class StateObserver(Protocol):
    """状态观察者协议（UI 层实现）。"""

    def on_state_change(self, state: str) -> None:
        """处理状态变更通知。"""
        ...

    def on_mode_change(self, mode: str) -> None:
        """工作模式变更通知。"""
        ...


# ══════════════════════════════════════════════════════════════════════
# 状态控制器
# ══════════════════════════════════════════════════════════════════════

class StateController:
    """应用状态控制器，集中管理运行时状态和模式。

    线程安全：所有状态变更都通过锁保护。

    使用示例::

        ctrl = StateController(initial_mode="A")
        ctrl.add_observer(tray_icon)
        ctrl.add_observer(overlay_window)

        ctrl.set_state(AppState.RECORDING)
        ctrl.cycle_mode()
    """

    def __init__(
        self,
        initial_mode: str = "A",
        settings=None,  # Settings 实例（可选，用于持久化）
    ) -> None:
        self._state = AppState.READY
        self._mode = WorkMode(initial_mode) if initial_mode in ("A", "B", "C", "D", "E", "F") else WorkMode.DIRECT
        self._settings = settings
        self._observers: List[StateObserver] = []
        self._lock = threading.Lock()

    # ── 状态管理 ──────────────────────────────────────────────────

    @property
    def state(self) -> AppState:
        """当前处理状态。"""
        return self._state

    @property
    def mode(self) -> WorkMode:
        """当前工作模式。"""
        return self._mode

    @property
    def mode_str(self) -> str:
        """当前工作模式字符串（A-F）。"""
        return self._mode.value

    def set_state(self, state: AppState | str) -> None:
        """更新处理状态，通知所有观察者。

        Args:
            state: AppState 枚举或字符串（如 "recording"）
        """
        if isinstance(state, str):
            try:
                state = AppState(state)
            except ValueError:
                logger.error("无效的应用状态: %s", state)
                return

        with self._lock:
            old = self._state
            self._state = state

        if old != state:
            logger.debug("状态变更: %s → %s", old.value, state.value)
            self._notify_state(state.value)

    def set_mode(self, mode: str) -> None:
        """设置工作模式。

        Args:
            mode: "A" / "B" / "C" / "D" / "E" / "F"
        """
        if mode not in ("A", "B", "C", "D", "E", "F"):
            logger.warning("无效的工作模式: %s", mode)
            return

        with self._lock:
            old = self._mode
            self._mode = WorkMode(mode)

        if old != self._mode:
            logger.info("模式变更: %s → %s (%s)", old.value, mode, MODE_NAMES.get(mode, ""))
            self._persist_mode(mode)
            self._notify_mode(mode)

    def cycle_mode(self) -> str:
        """循环切换工作模式 A → B → C → D → E → F → A。

        Returns:
            切换后的模式字符串
        """
        new_mode = _MODE_CYCLE[self._mode]
        self.set_mode(new_mode.value)
        return new_mode.value

    # ── 观察者管理 ────────────────────────────────────────────────

    def add_observer(self, observer: StateObserver) -> None:
        """注册状态观察者。"""
        self._observers.append(observer)

    def remove_observer(self, observer: StateObserver) -> None:
        """移除状态观察者。"""
        self._observers.remove(observer)

    def _notify_state(self, state: str) -> None:
        """通知所有观察者状态变更。"""
        for obs in self._observers:
            try:
                obs.on_state_change(state)
            except Exception as e:
                logger.debug("观察者状态通知失败: %s", e)

    def _notify_mode(self, mode: str) -> None:
        """通知所有观察者模式变更。"""
        for obs in self._observers:
            try:
                obs.on_mode_change(mode)
            except Exception as e:
                logger.debug("观察者模式通知失败: %s", e)

    # ── 持久化 ────────────────────────────────────────────────────

    def _persist_mode(self, mode: str) -> None:
        """将当前模式持久化到配置文件。"""
        if self._settings:
            try:
                save_async = getattr(self._settings, "set_and_save_async", None)
                if callable(save_async):
                    save_async("mode", "default", value=mode)
                else:
                    self._settings.set_and_save("mode", "default", value=mode)
            except Exception as e:
                logger.warning("保存模式配置失败（下次重启将重置）: %s", e)

    # ── StateListener 兼容接口 ────────────────────────────────────

    def on_state_change(self, state: str) -> None:
        """Pipeline 回调接口（实现 StateListener 协议）。"""
        self.set_state(state)

    def __repr__(self) -> str:
        return f"StateController(state={self._state.value}, mode={self._mode.value})"
