"""Lifecycle 模块单元测试。"""

import pytest

from spoken.core.lifecycle import Lifecycle, LifecycleManager


class MockModule(Lifecycle):
    """模拟生命周期模块。"""

    def __init__(self, name: str, fail_start: bool = False):
        self.name = name
        self.fail_start = fail_start
        self.started = False
        self.stopped = False

    def start(self):
        if self.fail_start:
            raise RuntimeError(f"{self.name} start failed")
        self.started = True

    def stop(self):
        self.stopped = True


class TestLifecycleManager:
    """LifecycleManager 测试。"""

    def test_register_and_start(self):
        mgr = LifecycleManager()
        mod = MockModule("a")
        mgr.register("a", mod)

        assert mgr.start("a")
        assert mod.started
        assert mgr.is_started("a")

    def test_stop_order(self):
        """停止应按注册相反顺序。"""
        mgr = LifecycleManager()
        order = []

        class TrackingModule(Lifecycle):
            def __init__(self, name):
                self.name = name
            def start(self):
                order.append(("start", self.name))
            def stop(self):
                order.append(("stop", self.name))

        mgr.register("a", TrackingModule("a"))
        mgr.register("b", TrackingModule("b"))
        mgr.start_all()
        order.clear()
        mgr.stop_all()

        assert order == [("stop", "b"), ("stop", "a")]

    def test_start_failure_continues(self):
        """某个模块启动失败不应影响其他模块。"""
        mgr = LifecycleManager()
        a = MockModule("a")
        b = MockModule("b", fail_start=True)
        c = MockModule("c")

        mgr.register("a", a)
        mgr.register("b", b)
        mgr.register("c", c)

        results = mgr.start_all()
        assert results == {"a": True, "b": False, "c": True}
        assert a.started
        assert not b.started
        assert c.started

    def test_stop_all_only_started(self):
        """stop_all 只停止已启动的模块。"""
        mgr = LifecycleManager()
        a = MockModule("a")
        b = MockModule("b")

        mgr.register("a", a)
        mgr.register("b", b)
        mgr.start("a")

        mgr.stop_all()
        assert a.stopped
        assert not b.stopped

    def test_unregister_stops_first(self):
        """注销时应先停止模块。"""
        mgr = LifecycleManager()
        mod = MockModule("a")
        mgr.register("a", mod)
        mgr.start("a")

        mgr.unregister("a")
        assert mod.stopped
        assert "a" not in mgr.list_items()

    def test_list_items(self):
        mgr = LifecycleManager()
        mgr.register("b", MockModule("b"))
        mgr.register("a", MockModule("a"))
        assert mgr.list_items() == ["b", "a"]

    def test_repr(self):
        mgr = LifecycleManager()
        mgr.register("a", MockModule("a"))
        mgr.start("a")
        r = repr(mgr)
        assert "a" in r
