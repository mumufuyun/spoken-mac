"""ASRManager 模块单元测试。"""

from unittest.mock import MagicMock

import pytest

from spoken.asr.manager import ASRManager, _EngineEntry
from spoken.core.events import EventBus


class MockASREngine:
    """模拟 ASR 引擎。"""

    def __init__(self, name: str = "mock", load_fail: bool = False, start_fail: bool = False):
        self.name = name
        self._loaded = False
        self._load_fail = load_fail
        self._start_fail = start_fail
        self.start_called = False
        self.stop_called = False

    def load(self):
        if self._load_fail:
            raise RuntimeError(f"{self.name} load failed")
        self._loaded = True

    def unload(self):
        self._loaded = False

    @property
    def is_loaded(self):
        return self._loaded

    def start(self):
        if self._start_fail:
            raise RuntimeError(f"{self.name} start failed")
        self.start_called = True

    def stop(self):
        self.stop_called = True


class TestEngineEntry:
    """_EngineEntry 测试。"""

    def test_creation(self):
        engine = MockASREngine()
        entry = _EngineEntry(name="test", engine=engine, is_primary=True)
        assert entry.name == "test"
        assert entry.is_primary
        assert entry.load_error is None


class TestASRManagerRegister:
    """注册功能测试。"""

    def test_register_single(self):
        mgr = ASRManager()
        engine = MockASREngine("e1")
        mgr.register("e1", engine)

        assert "e1" in mgr.list_engines()
        assert mgr.get_engine("e1") is engine

    def test_register_primary(self):
        mgr = ASRManager()
        mgr.register("main", MockASREngine(), primary=True)
        mgr.register("backup", MockASREngine(), primary=False)

        assert mgr.list_engines() == ["main", "backup"]

    def test_unregister(self):
        mgr = ASRManager()
        mgr.register("e1", MockASREngine())
        assert mgr.unregister("e1")
        assert "e1" not in mgr.list_engines()

    def test_unregister_unknown(self):
        mgr = ASRManager()
        assert not mgr.unregister("unknown")

    def test_register_overwrite(self):
        mgr = ASRManager()
        e1 = MockASREngine("old")
        e2 = MockASREngine("new")
        mgr.register("same", e1)
        mgr.register("same", e2)

        assert mgr.get_engine("same") is e2


class TestASRManagerLoad:
    """加载功能测试。"""

    def test_load_primary_success(self):
        mgr = ASRManager()
        engine = MockASREngine("main")
        mgr.register("main", engine, primary=True)

        assert mgr.load()
        assert mgr.is_ready
        assert mgr.current_engine_name == "main"
        assert engine.is_loaded

    def test_load_fallback_on_primary_fail(self):
        mgr = ASRManager()
        mgr.register("main", MockASREngine(load_fail=True), primary=True)
        mgr.register("backup", MockASREngine(), primary=False, fallback_order=0)

        assert mgr.load()
        assert mgr.current_engine_name == "backup"
        assert mgr.is_ready

    def test_load_all_fail(self):
        mgr = ASRManager()
        mgr.register("e1", MockASREngine(load_fail=True))
        mgr.register("e2", MockASREngine(load_fail=True))

        assert not mgr.load()
        assert not mgr.is_ready
        assert mgr.state == "error"

    def test_load_no_engines(self):
        mgr = ASRManager()
        assert not mgr.load()


class TestASRManagerStartStop:
    """启动/停止测试。"""

    def test_start_stop(self):
        mgr = ASRManager()
        engine = MockASREngine("main")
        mgr.register("main", engine)
        mgr.load()

        assert mgr.start()
        assert mgr.is_running
        assert engine.start_called

        mgr.stop()
        assert not mgr.is_running
        assert engine.stop_called

    def test_start_without_load(self):
        mgr = ASRManager()
        assert not mgr.start()

    def test_start_fallback(self):
        """启动失败时自动回退。"""
        bus = EventBus()
        mgr = ASRManager(event_bus=bus)
        mgr.register("main", MockASREngine(start_fail=True), primary=True)
        backup = MockASREngine("backup")
        mgr.register("backup", backup, fallback_order=0)

        mgr.load()  # 主引擎加载成功
        assert mgr.current_engine_name == "main"

        # 启动主引擎会失败，触发回退
        assert mgr.start()
        assert mgr.current_engine_name == "backup"
        assert backup.start_called

    def test_stop_no_engine(self):
        """没有引擎时停止不应抛错。"""
        mgr = ASRManager()
        mgr.stop()  # 不应抛出异常


class TestASRManagerEvents:
    """事件发布测试。"""

    def test_engine_ready_event(self):
        bus = EventBus()
        received = []
        bus.on("asr_engine_ready", lambda e: received.append(e.payload))

        mgr = ASRManager(event_bus=bus)
        mgr.register("e1", MockASREngine())
        mgr.load()

        assert len(received) == 1
        assert received[0]["engine"] == "e1"

    def test_engine_failed_event(self):
        bus = EventBus()
        received = []
        bus.on("asr_engine_failed", lambda e: received.append(e.payload))

        mgr = ASRManager(event_bus=bus)
        mgr.register("e1", MockASREngine(load_fail=True))
        mgr.load()

        assert len(received) == 1
        assert received[0]["engine"] == "e1"

    def test_asr_started_event(self):
        bus = EventBus()
        received = []
        bus.on("asr_started", lambda e: received.append(e.payload))

        mgr = ASRManager(event_bus=bus)
        mgr.register("e1", MockASREngine())
        mgr.load()
        mgr.start()

        assert len(received) == 1
        assert received[0]["engine"] == "e1"

    def test_asr_stopped_event(self):
        bus = EventBus()
        received = []
        bus.on("asr_stopped", lambda e: received.append(e.payload))

        mgr = ASRManager(event_bus=bus)
        mgr.register("e1", MockASREngine())
        mgr.load()
        mgr.start()
        mgr.stop()

        assert len(received) == 1

    def test_engine_changed_on_fallback(self):
        bus = EventBus()
        received = []
        bus.on("asr_engine_changed", lambda e: received.append(e.payload))

        mgr = ASRManager(event_bus=bus)
        mgr.register("main", MockASREngine(start_fail=True), primary=True)
        mgr.register("backup", MockASREngine(), fallback_order=0)

        mgr.load()
        mgr.start()  # 主引擎启动失败，回退

        assert len(received) == 1
        assert received[0]["from"] == "main"
        assert received[0]["to"] == "backup"


class TestASRManagerUnload:
    """卸载测试。"""

    def test_unload_current(self):
        mgr = ASRManager()
        engine = MockASREngine("main")
        mgr.register("main", engine)
        mgr.load()

        mgr.unload()
        assert not mgr.is_ready
        assert mgr.state == "idle"
        assert not engine.is_loaded

    def test_unload_during_running(self):
        mgr = ASRManager()
        engine = MockASREngine("main")
        mgr.register("main", engine)
        mgr.load()
        mgr.start()

        mgr.unload()
        assert not mgr.is_running


class TestASRManagerRepr:
    """repr 测试。"""

    def test_repr(self):
        mgr = ASRManager()
        mgr.register("e1", MockASREngine())
        mgr.register("e2", MockASREngine())

        r = repr(mgr)
        assert "e1" in r
        assert "e2" in r
        assert "idle" in r


class TestASRManagerFallbackOrder:
    """回退优先级测试。"""

    def test_fallback_order_respected(self):
        mgr = ASRManager()
        mgr.register("first", MockASREngine(load_fail=True), fallback_order=0)
        mgr.register("second", MockASREngine(load_fail=True), fallback_order=1)
        mgr.register("third", MockASREngine(), fallback_order=2)

        mgr.load()
        assert mgr.current_engine_name == "third"
