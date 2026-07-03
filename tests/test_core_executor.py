"""TaskExecutor 模块单元测试。"""

import time
from concurrent.futures import CancelledError

import pytest

from spoken.core.executor import TaskExecutor, TaskHandle


class TestTaskHandle:
    """TaskHandle 测试。"""

    def test_handle_repr(self):
        """repr 应显示名称和状态。"""
        executor = TaskExecutor()
        handle = executor.submit(lambda: "result", name="test_repr")
        time.sleep(0.01)  # 等待完成

        repr_str = repr(handle)
        assert "test_repr" in repr_str
        executor.shutdown()


class TestTaskExecutorSubmit:
    """任务提交测试。"""

    def test_submit_basic(self):
        """基本任务提交应正常工作。"""
        executor = TaskExecutor()
        handle = executor.submit(lambda: "hello", name="basic")

        result = handle.result(timeout=2)
        assert result == "hello"
        executor.shutdown()

    def test_submit_with_args(self):
        """带参数的任务应正常工作。"""
        executor = TaskExecutor()
        handle = executor.submit(lambda x, y: x + y, 3, 4, name="add")

        assert handle.result(timeout=2) == 7
        executor.shutdown()

    def test_submit_with_kwargs(self):
        """带关键字参数的任务应正常工作。"""
        executor = TaskExecutor()
        handle = executor.submit(lambda x=0, y=0: x * y, x=5, y=6, name="multiply")

        assert handle.result(timeout=2) == 30
        executor.shutdown()

    def test_submit_exception(self):
        """任务异常应被捕获并传播。"""
        executor = TaskExecutor()

        def bad_task():
            raise ValueError("task error")

        handle = executor.submit(bad_task, name="error")

        with pytest.raises(ValueError, match="task error"):
            handle.result(timeout=2)
        executor.shutdown()

    def test_auto_cleanup(self):
        """任务完成后应自动清理。"""
        executor = TaskExecutor()
        handle = executor.submit(lambda: None, name="cleanup")

        time.sleep(0.05)  # 等待完成
        assert handle.done
        assert executor.get_handle("cleanup") is None  # 已清理
        executor.shutdown()

    def test_multiple_tasks(self):
        """多个任务应并行执行。"""
        executor = TaskExecutor(max_workers=4)
        handles = []

        for i in range(5):
            handle = executor.submit(lambda idx=i: idx, name=f"task_{i}")
            handles.append(handle)

        results = [h.result(timeout=2) for h in handles]
        assert sorted(results) == [0, 1, 2, 3, 4]
        executor.shutdown()


class TestTaskExecutorSchedule:
    """延迟任务测试。"""

    def test_schedule_delay(self):
        """延迟任务应在指定时间后执行。"""
        executor = TaskExecutor()
        start = time.time()

        handle = executor.schedule(0.1, lambda: "delayed", name="delay")
        result = handle.result(timeout=2)
        elapsed = time.time() - start

        assert result == "delayed"
        assert elapsed >= 0.08  # 允许一定误差
        executor.shutdown()

    def test_schedule_cancel(self):
        """延迟任务应能被取消。"""
        executor = TaskExecutor()
        handle = executor.schedule(10.0, lambda: "never", name="cancel_me")

        assert handle.cancel()
        time.sleep(0.05)
        assert handle.cancelled or handle.done
        executor.shutdown()


class TestTaskExecutorInterval:
    """定时循环任务测试。"""

    def test_interval_basic(self):
        """定时任务应循环执行。"""
        executor = TaskExecutor()
        counter = []

        def tick():
            counter.append(1)

        handle = executor.interval(0.05, tick, name="tick", max_runs=3)
        result = handle.result(timeout=2)

        assert result >= 3
        assert len(counter) >= 3
        executor.shutdown()

    def test_interval_cancel(self):
        """定时任务应能被取消。"""
        executor = TaskExecutor()
        counter = []

        handle = executor.interval(0.05, lambda: counter.append(1), name="interval_cancel")
        time.sleep(0.15)  # 执行几次

        handle.cancel(wait=True, timeout=1)
        count_before = len(counter)
        time.sleep(0.1)  # 再等等

        assert len(counter) == count_before  # 不应再增加
        executor.shutdown()


class TestTaskExecutorCancel:
    """任务取消测试。"""

    def test_cancel_by_name(self):
        """应能通过名称取消任务。"""
        executor = TaskExecutor()

        def long_task():
            time.sleep(10)
            return "done"

        executor.submit(long_task, name="long")
        time.sleep(0.01)

        assert executor.cancel("long")
        executor.shutdown()

    def test_cancel_all(self):
        """应能批量取消任务。"""
        executor = TaskExecutor()

        for i in range(3):
            executor.submit(lambda: time.sleep(10), name=f"batch_{i}")

        time.sleep(0.01)
        count = executor.cancel_all(pattern="batch_")
        assert count == 3
        executor.shutdown()

    def test_cancel_all_empty_pattern(self):
        """空 pattern 应取消所有任务。"""
        executor = TaskExecutor()

        executor.submit(lambda: time.sleep(10), name="a")
        executor.submit(lambda: time.sleep(10), name="b")

        time.sleep(0.01)
        count = executor.cancel_all()
        assert count == 2
        executor.shutdown()


class TestTaskExecutorShutdown:
    """关闭测试。"""

    def test_shutdown_wait(self):
        """关闭时应等待未完成任务。"""
        executor = TaskExecutor()
        results = []

        def task():
            time.sleep(0.05)
            results.append("done")
            return "ok"

        executor.submit(task, name="wait_task")
        executor.shutdown(wait=True)

        assert results == ["done"]

    def test_shutdown_no_wait(self):
        """不等待关闭应不阻塞。"""
        executor = TaskExecutor()

        executor.submit(lambda: time.sleep(10), name="no_wait")
        executor.shutdown(wait=False)

        # 不应抛出异常
        assert True

    def test_submit_after_shutdown(self):
        """关闭后提交任务应抛出异常。"""
        executor = TaskExecutor()
        executor.shutdown(wait=False)

        with pytest.raises(RuntimeError, match="已关闭"):
            executor.submit(lambda: None)

    def test_active_count(self):
        """活跃任务计数应正确。"""
        executor = TaskExecutor()

        assert executor.active_count() == 0

        handle = executor.submit(lambda: time.sleep(0.1), name="active")
        time.sleep(0.01)
        assert executor.active_count() == 1

        handle.result(timeout=2)
        assert executor.active_count() == 0
        executor.shutdown()


class TestTaskExecutorConcurrency:
    """并发测试。"""

    def test_concurrent_submissions(self):
        """多线程提交应安全。"""
        import threading

        executor = TaskExecutor()
        results = []
        lock = threading.Lock()

        def worker(idx: int):
            def task():
                with lock:
                    results.append(idx)
                return idx

            executor.submit(task, name=f"worker_{idx}")

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        time.sleep(0.2)  # 等待任务完成
        assert len(results) == 10
        executor.shutdown()
