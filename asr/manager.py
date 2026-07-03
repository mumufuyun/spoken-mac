"""
spoken/asr/manager.py
ASR 引擎管理器 — 统一管理多引擎的注册、选择、回退和生命周期。

设计原则：
  - 对外隐藏引擎差异，提供统一接口
  - 自动回退：主引擎失败时自动切换到备用引擎
  - 通过 EventBus 发布状态事件，解耦 UI 和日志
  - 线程安全：可在任意线程中调用

使用示例::

    from spoken.asr.manager import ASRManager
    from spoken.core.events import EventBus

    bus = EventBus()
    mgr = ASRManager(event_bus=bus)

    # 注册引擎（按优先级排序）
    mgr.register("windows", WindowsSpeechEngine(...), primary=True)
    mgr.register("xunfei", XunfeiRealtimeEngine(...))

    # 启动（自动选择可用引擎）
    mgr.start()

    # 停止
    mgr.stop()
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from .engine import ASREngine

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 引擎注册项
# ══════════════════════════════════════════════════════════════════════

@dataclass
class _EngineEntry:
    """内部引擎注册项。"""

    name: str
    engine: ASREngine
    is_primary: bool = False
    fallback_order: int = 0
    load_error: Optional[str] = None


# ══════════════════════════════════════════════════════════════════════
# ASR 管理器
# ══════════════════════════════════════════════════════════════════════

class ASRManager:
    """ASR 引擎管理器。

    职责：
      - 注册多个 ASR 引擎
      - 按优先级加载，自动回退
      - 统一控制 start/stop
      - 通过 event_bus 发布识别结果和状态
    """

    def __init__(
        self,
        event_bus: Optional[Any] = None,
        on_partial_text: Optional[Callable[[str], None]] = None,
        on_final_text: Optional[Callable[[str], None]] = None,
    ) -> None:
        self._event_bus = event_bus
        self._on_partial_text = on_partial_text
        self._on_final_text = on_final_text

        self._engines: Dict[str, _EngineEntry] = {}
        self._current: Optional[_EngineEntry] = None
        self._lock = threading.RLock()

        # 状态
        self._is_running = False
        self._state = "idle"  # idle, loading, ready, listening, error

        # V3: 长语音支持
        self._long_audio_threshold: float = 60.0  # 长语音阈值（秒）
        self._max_audio_duration: float = 3600.0  # 最大支持时长（60 分钟）
        self._recording_start_time: float = 0.0  # 录音开始时间

    # ── 注册 ──────────────────────────────────────────────────────

    def register(
        self,
        name: str,
        engine: ASREngine,
        *,
        primary: bool = False,
        fallback_order: int = 0,
    ) -> None:
        """注册一个 ASR 引擎。

        Args:
            name: 引擎标识名，如 "windows", "xunfei"
            engine: ASREngine 实例
            primary: 是否为主引擎（优先尝试）
            fallback_order: 回退优先级（数字越小越优先）
        """
        with self._lock:
            if name in self._engines:
                logger.warning("引擎 '%s' 已存在，将被覆盖", name)

            self._engines[name] = _EngineEntry(
                name=name,
                engine=engine,
                is_primary=primary,
                fallback_order=fallback_order,
            )
        logger.info("注册 ASR 引擎: %s (primary=%s)", name, primary)

    def unregister(self, name: str) -> bool:
        """注销引擎。"""
        with self._lock:
            entry = self._engines.pop(name, None)
            if entry is None:
                return False
            if self._current and self._current.name == name:
                self._current = None
        logger.info("注销 ASR 引擎: %s", name)
        return True

    # ── 加载与选择 ────────────────────────────────────────────────

    def load(self) -> bool:
        """加载主引擎，失败时自动按回退顺序尝试。

        Returns:
            True 表示至少一个引擎加载成功
        """
        with self._lock:
            candidates = self._ordered_candidates()

        for entry in candidates:
            logger.info("尝试加载 ASR 引擎: %s", entry.name)
            try:
                entry.engine.load()
                with self._lock:
                    self._current = entry
                    self._state = "ready"
                logger.info("[OK] ASR 引擎就绪: %s", entry.name)
                self._emit("asr_engine_ready", {"engine": entry.name})
                return True
            except Exception as e:
                entry.load_error = str(e)
                logger.warning("引擎 '%s' 加载失败: %s", entry.name, e)
                self._emit("asr_engine_failed", {"engine": entry.name, "error": str(e)})

        logger.error("所有 ASR 引擎均加载失败")
        with self._lock:
            self._state = "error"
        self._emit("asr_engine_error", {"error": "所有引擎加载失败"})
        return False

    def unload(self) -> None:
        """卸载当前引擎。"""
        with self._lock:
            entry = self._current
            self._current = None
            self._is_running = False
            self._state = "idle"

        if entry:
            try:
                entry.engine.unload()
                logger.info("ASR 引擎已卸载: %s", entry.name)
            except Exception as e:
                logger.warning("卸载引擎 '%s' 时出错: %s", entry.name, e)

    # ── 启动与停止 ────────────────────────────────────────────────

    def start(self) -> bool:
        """启动识别（调用当前引擎的 start）。

        Returns:
            True 表示成功启动
        """
        with self._lock:
            entry = self._current
            if entry is None:
                logger.error("没有可用的 ASR 引擎")
                return False

        logger.info("启动 ASR 识别: %s", entry.name)
        try:
            # 部分引擎使用 start() 方法
            start_fn = getattr(entry.engine, "start", None)
            if callable(start_fn):
                start_fn()

            with self._lock:
                self._is_running = True
                self._state = "listening"

            with self._lock:
                self._recording_start_time = time.time()

            self._emit("asr_started", {"engine": entry.name})
            return True
        except Exception as e:
            logger.error("启动 ASR 失败: %s", e)
            self._emit("asr_start_failed", {"engine": entry.name, "error": str(e)})

            # 尝试回退
            if self._try_fallback():
                return self.start()
            return False

    def stop(self) -> str:
        """停止识别并返回结果。

        Returns:
            识别出的文本
        """
        result_text = ""
        with self._lock:
            entry = self._current
            self._is_running = False
            self._state = "ready"
            duration = time.time() - self._recording_start_time if self._recording_start_time > 0 else 0

        if entry:
            try:
                stop_fn = getattr(entry.engine, "stop", None)
                if callable(stop_fn):
                    result_text = stop_fn() or ""
                logger.info("ASR 识别已停止: %s (时长: %.1fs)", entry.name, duration)
            except Exception as e:
                logger.warning("停止引擎 '%s' 时出错: %s", entry.name, e)

        self._emit("asr_stopped", {"duration": duration})
        self._recording_start_time = 0.0
        return result_text

    # ── 状态查询 ──────────────────────────────────────────────────

    @property
    def is_ready(self) -> bool:
        """是否有已加载的引擎。"""
        with self._lock:
            return self._current is not None and self._current.engine.is_loaded

    @property
    def is_running(self) -> bool:
        """是否正在识别中。"""
        with self._lock:
            return self._is_running

    @property
    def current_engine_name(self) -> str:
        """当前引擎名称。"""
        with self._lock:
            return self._current.name if self._current else ""

    @property
    def state(self) -> str:
        """当前状态。"""
        with self._lock:
            return self._state

    def get_recording_duration(self) -> float:
        """获取当前录音时长（秒）。"""
        with self._lock:
            if not self._is_running or self._recording_start_time <= 0:
                return 0.0
            return time.time() - self._recording_start_time

    def is_long_audio(self) -> bool:
        """当前是否处于长语音录制状态。"""
        duration = self.get_recording_duration()
        return duration > self._long_audio_threshold

    def get_engine_for_duration(self, estimated_duration: float) -> Optional[str]:
        """根据预估时长选择合适的引擎名称。

        Args:
            estimated_duration: 预估音频时长（秒）

        Returns:
            引擎名称，如果无可用引擎返回 None
        """
        with self._lock:
            candidates = self._ordered_candidates()

        for entry in candidates:
            # 检查引擎是否支持该时长
            max_duration = getattr(entry.engine, "max_duration", self._max_audio_duration)
            if estimated_duration <= max_duration:
                return entry.name
        return None

    def configure_long_audio(self, threshold: float = 60.0, max_duration: float = 3600.0) -> None:
        """配置长语音参数。

        Args:
            threshold: 长语音阈值（秒）
            max_duration: 最大支持时长（秒）
        """
        with self._lock:
            self._long_audio_threshold = threshold
            self._max_audio_duration = max_duration
        logger.info("长语音配置更新: 阈值=%.0fs, 最大时长=%.0fs", threshold, max_duration)

    def get_engine(self, name: str) -> Optional[ASREngine]:
        """按名称获取引擎实例。"""
        with self._lock:
            entry = self._engines.get(name)
            return entry.engine if entry else None

    def list_engines(self) -> List[str]:
        """列出所有已注册的引擎名称。"""
        with self._lock:
            return list(self._engines.keys())

    # ── 回退 ──────────────────────────────────────────────────────

    def _try_fallback(self) -> bool:
        """尝试回退到下一个可用引擎。

        Returns:
            True 表示回退成功
        """
        with self._lock:
            current_name = self._current.name if self._current else None
            candidates = self._ordered_candidates()

            # 找到当前引擎之后的候选
            fallback_candidates = []
            found_current = False
            for c in candidates:
                if found_current and c.name != current_name:
                    fallback_candidates.append(c)
                if c.name == current_name:
                    found_current = True

        for entry in fallback_candidates:
            logger.warning("尝试回退到引擎: %s", entry.name)
            try:
                # 卸载旧引擎
                if current_name:
                    old = self._engines.get(current_name)
                    if old:
                        try:
                            old.engine.unload()
                        except Exception:
                            pass

                entry.engine.load()
                with self._lock:
                    self._current = entry
                    self._state = "ready"
                logger.info("[OK] 回退成功，当前引擎: %s", entry.name)
                self._emit("asr_engine_changed", {
                    "from": current_name,
                    "to": entry.name,
                })
                return True
            except Exception as e:
                logger.warning("回退到 '%s' 失败: %s", entry.name, e)
                self._emit("asr_engine_failed", {"engine": entry.name, "error": str(e)})

        logger.error("所有回退引擎均不可用")
        with self._lock:
            self._state = "error"
        return False

    # ── 内部方法 ──────────────────────────────────────────────────

    def _ordered_candidates(self) -> List[_EngineEntry]:
        """返回按优先级排序的候选引擎列表。"""
        entries = list(self._engines.values())
        # 先按 primary 排序，再按 fallback_order 排序
        entries.sort(key=lambda e: (not e.is_primary, e.fallback_order))
        return entries

    def _emit(self, event_name: str, payload: Dict[str, Any]) -> None:
        """发布事件到事件总线。"""
        if self._event_bus is not None:
            try:
                self._event_bus.emit(event_name, payload)
            except Exception as e:
                logger.warning("发布事件 '%s' 失败: %s", event_name, e)

    # ── 健康检查与统计（V3 新增）────────────────────────────────

    def health_check(self) -> dict:
        """执行健康检查，返回引擎状态报告。

        Returns:
            {
                "state": str,            # 当前状态
                "current_engine": str,   # 当前引擎名
                "is_running": bool,      # 是否在识别中
                "recording_duration": float,  # 当前录音时长（秒）
                "engines": {             # 各引擎状态
                    "name": {
                        "loaded": bool,
                        "is_primary": bool,
                        "load_error": str or None,
                    }
                }
            }
        """
        with self._lock:
            engines_info = {}
            for name, entry in self._engines.items():
                engines_info[name] = {
                    "loaded": getattr(entry.engine, "is_loaded", False),
                    "is_primary": entry.is_primary,
                    "load_error": entry.load_error,
                }

            return {
                "state": self._state,
                "current_engine": self._current.name if self._current else "",
                "is_running": self._is_running,
                "recording_duration": self.get_recording_duration(),
                "long_audio_threshold": self._long_audio_threshold,
                "is_long_audio": self.is_long_audio(),
                "engines": engines_info,
            }

    def reset_to_primary(self) -> bool:
        """尝试重置回主引擎（如主引擎恢复可用）。

        Returns:
            True 表示成功切换到主引擎
        """
        with self._lock:
            candidates = self._ordered_candidates()
            if not candidates:
                return False
            primary = candidates[0]
            if self._current and self._current.name == primary.name:
                return True  # 已经是主引擎

        logger.info("尝试重置到主引擎: %s", primary.name)
        try:
            primary.engine.load()
            with self._lock:
                self._current = primary
                self._state = "ready"
            logger.info("[OK] 已重置到主引擎: %s", primary.name)
            self._emit("asr_engine_reset", {"engine": primary.name})
            return True
        except Exception as e:
            logger.warning("重置到主引擎失败: %s", e)
            return False

    def __repr__(self) -> str:
        with self._lock:
            engines = list(self._engines.keys())
            current = self._current.name if self._current else "None"
            return f"ASRManager(engines={engines}, current={current}, state={self._state})"
