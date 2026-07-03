"""EventBus 模块单元测试。"""

import threading
import time
from unittest.mock import MagicMock

import pytest

from spoken.core.events import Event, EventBus, get_default_bus, publish, subscribe


class TestEvent:
    """Event 数据类测试。"""

    def test_event_creation(self):
        """应能正确创建事件对象。"""
        event = Event(name="test", payload={"key": "value"}, trace_id="abc123")
        assert event.name == "test"
        assert event.payload == {"key": "value"}
        assert event.trace_id == "abc123"

    def test_event_defaults(self):
        """默认值应正确。"""
        event = Event(name="test")
        assert event.payload is None
        assert event.trace_id == ""

    def test_event_immutable(self):
        """事件对象应是不可变的（frozen dataclass）。"""
        event = Event(name="test")
        with pytest.raises(AttributeError):
            event.name = "changed"

    def test_event_repr(self):
        """repr 应包含关键信息。"""
        event = Event(name="test", payload="data")
        repr_str = repr(event)
        assert "test" in repr_str
        assert "data" in repr_str


class TestEventBus:
    """EventBus 核心功能测试。"""

    def test_subscribe_and_emit(self):
        """订阅后应能收到事件。"""
        bus = EventBus()
        received = []

        def handler(event: Event):
            received.append(event)

        bus.on("test_event", handler)
        bus.emit("test_event", payload="hello")

        assert len(received) == 1
        assert received[0].payload == "hello"

    def test_decorator_subscribe(self):
        """装饰器方式订阅应正常工作。"""
        bus = EventBus()
        received = []

        @bus.on("decorator_test")
        def handler(event: Event):
            received.append(event.payload)

        bus.emit("decorator_test", payload=42)
        assert received == [42]

    def test_multiple_subscribers(self):
        """多个订阅者应都收到事件。"""
        bus = EventBus()
        results = []

        bus.on("multi", lambda e: results.append("a"))
        bus.on("multi", lambda e: results.append("b"))
        bus.emit("multi")

        assert sorted(results) == ["a", "b"]

    def test_once_subscription(self):
        """一次性订阅应在处理一次后自动移除。"""
        bus = EventBus()
        received = []

        bus.once("once_test", lambda e: received.append(e.payload))
        bus.emit("once_test", payload=1)
        bus.emit("once_test", payload=2)

        assert len(received) == 1
        assert received[0] == 1

    def test_off_unsubscribe(self):
        """取消订阅后不应再收到事件。"""
        bus = EventBus()
        received = []

        def handler(event: Event):
            received.append(event)

        bus.on("off_test", handler)
        bus.emit("off_test")
        assert len(received) == 1

        bus.off("off_test", handler)
        bus.emit("off_test")
        assert len(received) == 1  # 没有增加

    def test_wildcard_subscription(self):
        """通配符订阅应收到所有事件。"""
        bus = EventBus()
        received = []

        bus.on("*", lambda e: received.append(e.name))
        bus.emit("event_a")
        bus.emit("event_b")

        assert len(received) == 2
        assert "event_a" in received
        assert "event_b" in received

    def test_handler_exception_isolated(self):
        """某个 handler 异常不应影响其他 handler。"""
        bus = EventBus()
        received = []

        def bad_handler(event: Event):
            raise ValueError("故意抛错")

        def good_handler(event: Event):
            received.append("ok")

        bus.on("error_test", bad_handler)
        bus.on("error_test", good_handler)
        bus.emit("error_test")  # 不应抛出异常

        assert received == ["ok"]

    def test_emit_after_close(self):
        """关闭后发布事件应被忽略。"""
        bus = EventBus()
        received = []

        bus.on("close_test", lambda e: received.append(1))
        bus.close()
        bus.emit("close_test")

        assert len(received) == 0

    def test_clear_specific(self):
        """清空特定事件应只影响该事件。"""
        bus = EventBus()
        received_a = []
        received_b = []

        bus.on("keep", lambda e: received_a.append(1))
        bus.on("clear", lambda e: received_b.append(1))

        bus.clear("clear")
        bus.emit("keep")
        bus.emit("clear")

        assert len(received_a) == 1
        assert len(received_b) == 0

    def test_clear_all(self):
        """清空所有事件后不应再收到任何事件。"""
        bus = EventBus()
        received = []

        bus.on("a", lambda e: received.append(1))
        bus.on("b", lambda e: received.append(1))

        bus.clear()
        bus.emit("a")
        bus.emit("b")

        assert len(received) == 0

    def test_subscriber_count(self):
        """订阅者计数应正确。"""
        bus = EventBus()
        assert bus.subscriber_count("test") == 0

        bus.on("test", lambda e: None)
        assert bus.subscriber_count("test") == 1

        bus.on("test", lambda e: None)
        assert bus.subscriber_count("test") == 2

    def test_thread_safety(self):
        """多线程并发订阅和发布应安全。"""
        bus = EventBus()
        received = []
        lock = threading.Lock()

        def handler(event: Event):
            with lock:
                received.append(event.payload)

        # 多个线程同时订阅和发布
        threads = []
        for i in range(10):
            t = threading.Thread(target=lambda idx=i: bus.on("thread_test", handler))
            threads.append(t)
            t.start()

        for t in threads:
            t.join()

        # 发布事件
        bus.emit("thread_test", payload="data")

        # 所有订阅者都应收到
        assert len(received) == 10

    def test_trace_id(self):
        """trace_id 应被正确传递。"""
        bus = EventBus()
        received = []

        bus.on("trace", lambda e: received.append(e.trace_id))
        bus.emit("trace", trace_id="flow-123")

        assert received == ["flow-123"]

    def test_emit_all(self):
        """emit_all 应能发布已构造的 Event 对象。"""
        bus = EventBus()
        received = []

        bus.on("direct", lambda e: received.append(e.payload))
        event = Event(name="direct", payload="direct_data")
        bus.emit_all(event)

        assert received == ["direct_data"]

    def test_weak_reference(self):
        """弱引用订阅不应阻止 handler 被 GC。"""
        bus = EventBus()

        # 创建局部函数，离开作用域后应被 GC
        def make_handler():
            received = []

            def handler(event: Event):
                received.append(event)

            bus.on("weak", handler, weak=True)
            return received

        received = make_handler()
        import gc

        gc.collect()  # 强制 GC

        # 弱引用订阅在 GC 后不应再收到事件
        bus.emit("weak")
        assert len(received) == 0


class TestDefaultBus:
    """默认全局总线测试。"""

    def test_singleton(self):
        """默认总线应为单例。"""
        bus1 = get_default_bus()
        bus2 = get_default_bus()
        assert bus1 is bus2

    def test_subscribe_publish_globals(self):
        """全局订阅和发布应正常工作。"""
        received = []

        @subscribe("global_test")
        def handler(event: Event):
            received.append(event.payload)

        publish("global_test", payload="global_data")

        assert received == ["global_data"]

    def test_global_bus_is_eventbus(self):
        """全局总线应为 EventBus 实例。"""
        bus = get_default_bus()
        assert isinstance(bus, EventBus)
