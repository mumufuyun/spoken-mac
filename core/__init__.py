"""Spoken v2 核心基础设施模块。"""

from .events import EventBus, Event, subscribe, publish
from .executor import TaskExecutor
from .state_machine import StateMachine, State, Transition
from .lifecycle import Lifecycle, LifecycleManager
from .errors import SpokenError, ErrorCode

__all__ = [
    "EventBus",
    "Event",
    "subscribe",
    "publish",
    "TaskExecutor",
    "StateMachine",
    "State",
    "Transition",
    "Lifecycle",
    "LifecycleManager",
    "SpokenError",
    "ErrorCode",
]
