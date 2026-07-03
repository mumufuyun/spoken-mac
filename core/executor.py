"""spoken/core/executor.py
Spoken v2 统一任务执行器 — 替代随处创建的 daemon 线程。

职责：
  - 封装 ThreadPoolExecutor，统一管理后台任务
  - 支持任务命名、取消、超时
  - 提供定时任务能力
  - 优雅关闭时等待未完成任务

使用示例::

    from spoken.core.executor import TaskExecutor

    executor = TaskExecutor(max_workers=8)

    # 提交普通任务
    future = executor.submit(my_func, arg1, arg2, name="asr-start")

    # 延迟任务
    executor.schedule(delay_sec=3.0, my_callback, name="auto-hide")

    # 定时任务（循环）
    executor.interval(period_sec=0.25, check_topmost, name="topmost-heartbeat")

    executor.shutdown(wait=True)
"""

from __future__ import annotations

import logging
import threading
import time
import uuid
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Any, Callable, Dict, List, Optional, Set

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 任务包装
# ══════════════════════════════════════════════════════════════════════

class TaskHandle:
    """任务句柄，用于取消和查询任务状态。"""

    def __init__(self, name: str, future: Future, cancel_event: threading.Event) -> None:
        self.name = name
        self._future = future
        self._cancel_event = cancel_event

    def cancel(self, wait: bool = False, timeout: Optional[float] = None) -> bool:
        """请求取消任务。

        Args:
            wait: 是否等待任务实际结束
            timeout: 等待超时（秒）

        Returns:
            True 表示取消请求已发出；False 表示任务已完成
        """
        if self._future.done():
            return False
        self._cancel_event.set()
        self._future.cancel()
        if wait:
            try:
                self._future.result(timeout=timeout)
            except Exception:
                pass
        return True

    @property
    def done(self) -> bool:
        return self._future.done()

    @property
    def cancelled(self) -> bool:
        return self._future.cancelled()

    def result(self, timeout: Optional[float] = None) -> Any:
        return self._future.result(timeout=timeout)

    def __repr__(self) -> str:
        status = "done" if self.done else "running"
        return f"TaskHandle({self.name!r}, {status})"


# ══════════════════════════════════════════════════════════════════════
# 任务执行器
# ══════════════════════════════════════════════════════════════════════

class TaskExecutor:
    """统一后台任务执行器。

    线程安全，可在任意线程中提交任务。
    """

    def __init__(self, max_workers: int = 8, thread_name_prefix: str = "spoken-") -> None:
        self._pool = ThreadPoolExecutor(
            max_workers=max_workers,
            thread_name_prefix=thread_name_prefix,
        )
        self._handles: Dict[str, TaskHandle] = {}
        self._lock = threading.Lock()
        self._shutdown = False
        self._timers: Set[threading.Timer] = set()

    # ── 提交任务 ──────────────────────────────────────────────────

    def submit(
        self,
        fn: Callable,
        *args: Any,
        name: str = "",
        **kwargs: Any,
    ) -> TaskHandle:
        """提交一个后台任务。

        Args:
            fn: 要执行的函数
            *args, **kwargs: 函数参数
            name: 任务名称（用于日志和追踪）

        Returns:
            TaskHandle 任务句柄
        """
        if self._shutdown:
            raise RuntimeError("TaskExecutor 已关闭")

        task_name = name or f"task-{uuid.uuid4().hex[:8]}"
        cancel_event = threading.Event()

        def _wrapper() -> Any:
            if cancel_event.is_set():
                logger.debug("任务 %s 在启动前被取消", task_name)
                return None
            try:
                logger.debug("任务开始: %s", task_name)
                result = fn(*args, **kwargs)
                logger.debug("任务完成: %s", task_name)
                return result
            except Exception as e:
                logger.error("任务异常 [%s]: %s", task_name, e, exc_info=True)
                raise

        future = self._pool.submit(_wrapper)
        handle = TaskHandle(task_name, future, cancel_event)

        with self._lock:
            self._handles[task_name] = handle

        # 任务完成后自动清理
        future.add_done_callback(lambda f: self._cleanup(task_name))
        return handle

    def schedule(
        self,
        delay_sec: float,
        fn: Callable,
        *args: Any,
        name: str = "",
        **kwargs: Any,
    ) -> TaskHandle:
        """延迟执行一次任务。

        Args:
            delay_sec: 延迟秒数
            fn: 要执行的函数
            name: 任务名称
        """
        task_name = name or f"scheduled-{uuid.uuid4().hex[:8]}"
        cancel_event = threading.Event()
        future: Future = Future()

        def _run() -> None:
            if cancel_event.is_set():
                future.cancel()
                return
            try:
                result = fn(*args, **kwargs)
                future.set_result(result)
            except Exception as e:
                future.set_exception(e)

        def _delayed() -> None:
            if not cancel_event.is_set():
                self.submit(_run, name=task_name)

        timer = threading.Timer(delay_sec, _delayed)
        timer.name = f"timer-{task_name}"
        timer.daemon = True

        handle = TaskHandle(task_name, future, cancel_event)
        with self._lock:
            self._handles[task_name] = handle
            self._timers.add(timer)

        def _on_done(_f: Future) -> None:
            self._cleanup(task_name)
            with self._lock:
                self._timers.discard(timer)

        future.add_done_callback(_on_done)
        timer.start()
        return handle

    def interval(
        self,
        period_sec: float,
        fn: Callable,
        *args: Any,
        name: str = "",
        max_runs: Optional[int] = None,
        **kwargs: Any,
    ) -> TaskHandle:
        """定时循环执行任务。

        Args:
            period_sec: 执行周期（秒）
            fn: 每次执行的函数
            max_runs: 最大执行次数，None 表示无限
            name: 任务名称
        """
        task_name = name or f"interval-{uuid.uuid4().hex[:8]}"
        cancel_event = threading.Event()
        future: Future = Future()
        run_count = 0

        def _loop() -> None:
            nonlocal run_count
            while not cancel_event.is_set():
                if max_runs is not None and run_count >= max_runs:
                    break
                time.sleep(period_sec)
                if cancel_event.is_set():
                    break
                try:
                    fn(*args, **kwargs)
                    run_count += 1
                except Exception as e:
                    logger.error("定时任务异常 [%s]: %s", task_name, e, exc_info=True)
            future.set_result(run_count)

        inner_handle = self.submit(_loop, name=task_name)
        handle = TaskHandle(task_name, future, cancel_event)

        with self._lock:
            self._handles[task_name] = handle

        def _on_done(_f: Future) -> None:
            self._cleanup(task_name)

        future.add_done_callback(_on_done)
        return handle

    # ── 查询与管理 ────────────────────────────────────────────────

    def get_handle(self, name: str) -> Optional[TaskHandle]:
        """按名称获取任务句柄。"""
        with self._lock:
            return self._handles.get(name)

    def cancel(self, name: str, wait: bool = False, timeout: Optional[float] = None) -> bool:
        """取消指定名称的任务。"""
        handle = self.get_handle(name)
        if handle is None:
            return False
        return handle.cancel(wait=wait, timeout=timeout)

    def cancel_all(self, pattern: str = "") -> int:
        """取消所有匹配名称的任务。

        Args:
            pattern: 名称包含该字符串则匹配，空字符串匹配所有

        Returns:
            取消的任务数量
        """
        count = 0
        with self._lock:
            names = list(self._handles.keys())
        for name in names:
            if not pattern or pattern in name:
                if self.cancel(name):
                    count += 1
        return count

    def active_count(self) -> int:
        """返回当前活跃任务数。"""
        with self._lock:
            return sum(1 for h in self._handles.values() if not h.done)

    # ── 关闭 ──────────────────────────────────────────────────────

    def shutdown(self, wait: bool = True, timeout: Optional[float] = None) -> None:
        """优雅关闭执行器。

        Args:
            wait: 是否等待未完成任务
            timeout: 等待超时（秒）
        """
        self._shutdown = True

        # 取消所有定时器
        with self._lock:
            timers = list(self._timers)
        for timer in timers:
            timer.cancel()

        # 取消所有进行中的任务
        self.cancel_all()

        self._pool.shutdown(wait=wait)
        logger.info("TaskExecutor 已关闭")

    # ── 内部方法 ──────────────────────────────────────────────────

    def _cleanup(self, name: str) -> None:
        with self._lock:
            self._handles.pop(name, None)

    def __repr__(self) -> str:
        active = self.active_count()
        total = len(self._handles)
        return f"TaskExecutor(active={active}, total={total})"
