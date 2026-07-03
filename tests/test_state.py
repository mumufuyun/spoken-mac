"""StateController 模块单元测试。"""

from unittest.mock import MagicMock

import pytest

from spoken.state import StateController, AppState, WorkMode, MODE_NAMES


class TestStateController:
    """StateController 状态管理测试。"""

    def test_initial_state(self):
        """初始状态应为 READY，模式为指定值。"""
        ctrl = StateController(initial_mode="B")
        assert ctrl.state == AppState.READY
        assert ctrl.mode == WorkMode.POLISH
        assert ctrl.mode_str == "B"

    def test_initial_mode_default(self):
        """默认模式应为 A。"""
        ctrl = StateController()
        assert ctrl.mode == WorkMode.DIRECT
        assert ctrl.mode_str == "A"

    def test_set_state(self):
        """测试状态变更。"""
        ctrl = StateController()
        ctrl.set_state(AppState.RECORDING)
        assert ctrl.state == AppState.RECORDING

    def test_set_state_by_string(self):
        """测试通过字符串设置状态。"""
        ctrl = StateController()
        ctrl.set_state("recognizing")
        assert ctrl.state == AppState.RECOGNIZING

    def test_set_state_invalid(self):
        """无效状态应被忽略。"""
        ctrl = StateController()
        ctrl.set_state("invalid_state")
        assert ctrl.state == AppState.READY  # 不变

    def test_set_mode(self):
        """测试模式设置。"""
        ctrl = StateController()
        ctrl.set_mode("B")
        assert ctrl.mode_str == "B"
        ctrl.set_mode("C")
        assert ctrl.mode_str == "C"

    def test_set_mode_invalid(self):
        """无效模式应被忽略。"""
        ctrl = StateController()
        ctrl.set_mode("X")
        assert ctrl.mode_str == "A"  # 不变

    def test_cycle_mode(self):
        """测试模式循环切换 A→B→C→D→E→F→A。"""
        ctrl = StateController(initial_mode="A")
        assert ctrl.cycle_mode() == "B"
        assert ctrl.cycle_mode() == "C"
        assert ctrl.cycle_mode() == "D"
        assert ctrl.cycle_mode() == "E"
        assert ctrl.cycle_mode() == "F"
        assert ctrl.cycle_mode() == "A"

    def test_set_mode_prefers_async_persist(self):
        """模式变更应优先使用异步保存，避免阻塞热键线程。"""
        settings = MagicMock()
        ctrl = StateController(initial_mode="A", settings=settings)

        ctrl.set_mode("B")

        settings.set_and_save_async.assert_called_once_with("mode", "default", value="B")
        settings.set_and_save.assert_not_called()

    def test_observer_notification(self):
        """测试观察者状态通知。"""
        received_states = []
        received_modes = []

        class MockObserver:
            def on_state_change(self, state: str):
                received_states.append(state)
            def on_mode_change(self, mode: str):
                received_modes.append(mode)

        ctrl = StateController()
        ctrl.add_observer(MockObserver())

        ctrl.set_state("recording")
        assert "recording" in received_states

        ctrl.set_mode("B")
        assert "B" in received_modes

    def test_remove_observer(self):
        """测试移除观察者。"""
        received = []

        class MockObserver:
            def on_state_change(self, state: str):
                received.append(state)
            def on_mode_change(self, mode: str):
                pass

        obs = MockObserver()
        ctrl = StateController()
        ctrl.add_observer(obs)
        ctrl.set_state("recording")
        assert len(received) == 1

        ctrl.remove_observer(obs)
        ctrl.set_state("ready")
        assert len(received) == 1  # 不应增加


class TestAppState:
    """AppState 枚举测试。"""

    def test_all_states_exist(self):
        """所有预期状态应存在。"""
        assert AppState.READY.value == "ready"
        assert AppState.STARTING.value == "starting"
        assert AppState.RECORDING.value == "recording"
        assert AppState.RECOGNIZING.value == "recognizing"
        assert AppState.AI_PROCESSING.value == "ai_processing"
        assert AppState.ERROR.value == "error"


class TestWorkMode:
    """WorkMode 枚举测试。"""

    def test_all_modes_exist(self):
        """所有预期模式应存在。"""
        assert WorkMode.DIRECT.value == "A"
        assert WorkMode.POLISH.value == "B"
        assert WorkMode.TO_PROMPT.value == "C"
        assert WorkMode.TRANSLATE.value == "D"
        assert WorkMode.MEETING_MINUTES.value == "E"
        assert WorkMode.STRUCTURED.value == "F"

    def test_mode_names(self):
        """模式名称映射应完整。"""
        assert "A" in MODE_NAMES
        assert "B" in MODE_NAMES
        assert "C" in MODE_NAMES
        assert "D" in MODE_NAMES
        assert "E" in MODE_NAMES
        assert "F" in MODE_NAMES
