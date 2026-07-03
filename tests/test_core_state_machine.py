"""StateMachine 模块单元测试。"""

import pytest

from spoken.core.events import EventBus
from spoken.core.state_machine import State, StateMachine, Transition, _TRANSITIONS


class TestStateEnum:
    """State 枚举测试。"""

    def test_all_states(self):
        """所有预期状态应存在。"""
        assert State.IDLE.value == "idle"
        assert State.STARTING.value == "starting"
        assert State.RECORDING.value == "recording"
        assert State.RECOGNIZING.value == "recognizing"
        assert State.AI_PROCESSING.value == "ai_processing"
        assert State.INJECTING.value == "injecting"
        assert State.COMPLETED.value == "completed"
        assert State.ERROR.value == "error"

    def test_state_is_str(self):
        """State 应为 str 子类，便于序列化。"""
        assert isinstance(State.IDLE, str)
        assert State.IDLE == "idle"


class TestStateMachineInit:
    """状态机初始化测试。"""

    def test_default_state(self):
        """默认状态应为 IDLE。"""
        sm = StateMachine()
        assert sm.state == State.IDLE

    def test_with_event_bus(self):
        """应能接受事件总线。"""
        bus = EventBus()
        sm = StateMachine(event_bus=bus)
        assert sm._event_bus is bus


class TestStateTransitions:
    """状态转换测试。"""

    def test_valid_transition(self):
        """合法转换应成功。"""
        sm = StateMachine()
        trans = sm.transition_to(State.STARTING)

        assert sm.state == State.STARTING
        assert trans.from_state == State.IDLE
        assert trans.to_state == State.STARTING

    def test_full_pipeline_flow(self):
        """完整流程应能正常转换。"""
        sm = StateMachine()

        # 模拟一次完整的录音-识别-AI-注入流程
        sm.transition_to(State.STARTING)
        sm.transition_to(State.RECORDING)
        sm.transition_to(State.RECOGNIZING)
        sm.transition_to(State.AI_PROCESSING)
        sm.transition_to(State.INJECTING)
        sm.transition_to(State.COMPLETED)
        sm.transition_to(State.IDLE)

        assert sm.state == State.IDLE

    def test_recognize_to_injecting(self):
        """识别状态可直接转到注入（模式A）。"""
        sm = StateMachine()
        sm.transition_to(State.STARTING)
        sm.transition_to(State.RECORDING)
        sm.transition_to(State.RECOGNIZING)
        sm.transition_to(State.INJECTING)  # 跳过 AI
        sm.transition_to(State.COMPLETED)

        assert sm.state == State.COMPLETED

    def test_recognize_to_completed(self):
        """识别状态可直接完成（无注入）。"""
        sm = StateMachine()
        sm.transition_to(State.STARTING)
        sm.transition_to(State.RECORDING)
        sm.transition_to(State.RECOGNIZING)
        sm.transition_to(State.COMPLETED)

        assert sm.state == State.COMPLETED

    def test_invalid_transition(self):
        """非法转换应抛出异常。"""
        sm = StateMachine()

        with pytest.raises(ValueError, match="非法状态转换"):
            sm.transition_to(State.COMPLETED)

    def test_idle_to_recording_invalid(self):
        """IDLE 不能直接到 RECORDING。"""
        sm = StateMachine()

        with pytest.raises(ValueError):
            sm.transition_to(State.RECORDING)

    def test_force_transition(self):
        """force=True 应跳过检查。"""
        sm = StateMachine()
        sm.transition_to(State.INJECTING, force=True)

        assert sm.state == State.INJECTING


class TestStateMachineReset:
    """重置测试。"""

    def test_reset(self):
        """reset 应强制回到 IDLE。"""
        sm = StateMachine()
        sm.transition_to(State.STARTING)
        sm.transition_to(State.RECORDING)

        trans = sm.reset()

        assert sm.state == State.IDLE
        assert trans.from_state == State.RECORDING
        assert trans.to_state == State.IDLE


class TestStateQueries:
    """状态查询测试。"""

    def test_is_idle(self):
        """is_idle 应正确判断。"""
        sm = StateMachine()
        assert sm.is_idle()

        sm.transition_to(State.STARTING)
        assert not sm.is_idle()

    def test_is_processing(self):
        """is_processing 应正确判断处理中状态。"""
        sm = StateMachine()
        assert not sm.is_processing()

        sm.transition_to(State.STARTING)
        assert sm.is_processing()

        sm.transition_to(State.RECORDING)
        assert sm.is_processing()

        sm.transition_to(State.RECOGNIZING)
        assert sm.is_processing()

        sm.transition_to(State.COMPLETED)
        assert not sm.is_processing()

    def test_can_transition_to(self):
        """can_transition_to 应正确预判。"""
        sm = StateMachine()

        assert sm.can_transition_to(State.STARTING)
        assert not sm.can_transition_to(State.RECORDING)

        sm.transition_to(State.STARTING)
        assert sm.can_transition_to(State.RECORDING)
        assert sm.can_transition_to(State.ERROR)


class TestStateCallbacks:
    """回调测试。"""

    def test_on_enter(self):
        """进入回调应在状态进入时触发。"""
        sm = StateMachine()
        entered = []

        sm.on_enter(State.STARTING, lambda f, t: entered.append("enter_starting"))
        sm.transition_to(State.STARTING)

        assert entered == ["enter_starting"]

    def test_on_exit(self):
        """退出回调应在状态退出时触发。"""
        sm = StateMachine()
        exited = []

        sm.on_exit(State.IDLE, lambda f, t: exited.append("exit_idle"))
        sm.transition_to(State.STARTING)

        assert exited == ["exit_idle"]

    def test_on_transition(self):
        """特定转换回调应在匹配时触发。"""
        sm = StateMachine()
        transitions = []

        sm.on_transition(State.IDLE, State.STARTING, lambda f, t: transitions.append("idle->starting"))
        sm.transition_to(State.STARTING)

        assert transitions == ["idle->starting"]

    def test_multiple_callbacks(self):
        """多个回调应依次触发。"""
        sm = StateMachine()
        log = []

        sm.on_enter(State.STARTING, lambda f, t: log.append("cb1"))
        sm.on_enter(State.STARTING, lambda f, t: log.append("cb2"))
        sm.transition_to(State.STARTING)

        assert log == ["cb1", "cb2"]

    def test_callback_parameters(self):
        """回调应接收 from_state 和 to_state。"""
        sm = StateMachine()
        received = []

        def callback(from_state, to_state):
            received.append((from_state, to_state))

        sm.on_enter(State.STARTING, callback)
        sm.transition_to(State.STARTING)

        assert received == [(State.IDLE, State.STARTING)]

    def test_callback_exception_isolated(self):
        """回调异常不应影响其他回调和状态转换。"""
        sm = StateMachine()
        good_called = []

        def bad_callback(f, t):
            raise ValueError("callback error")

        def good_callback(f, t):
            good_called.append(1)

        sm.on_enter(State.STARTING, bad_callback)
        sm.on_enter(State.STARTING, good_callback)
        sm.transition_to(State.STARTING)

        assert sm.state == State.STARTING  # 状态仍应转换成功
        assert good_called == [1]  # 好的回调仍应执行


class TestStateHistory:
    """历史记录测试。"""

    def test_history_recorded(self):
        """转换历史应被记录。"""
        sm = StateMachine()
        sm.transition_to(State.STARTING, trigger="hotkey")
        sm.transition_to(State.RECORDING)

        history = sm.history
        assert len(history) == 2
        assert history[0].from_state == State.IDLE
        assert history[0].to_state == State.STARTING
        assert history[0].trigger == "hotkey"

    def test_history_limit(self):
        """历史记录应有上限（50条）。"""
        sm = StateMachine()

        # 制造大量转换
        for _ in range(60):
            sm.transition_to(State.STARTING, force=True)
            sm.transition_to(State.IDLE, force=True)

        assert len(sm.history) <= 50


class TestStateMachineEvents:
    """事件发布测试。"""

    def test_state_changed_event(self):
        """状态转换应发布 state_changed 事件。"""
        bus = EventBus()
        received = []

        bus.on("state_changed", lambda e: received.append(e.payload))

        sm = StateMachine(event_bus=bus)
        sm.transition_to(State.STARTING, trigger="test")

        assert len(received) == 1
        assert received[0]["from"] == "idle"
        assert received[0]["to"] == "starting"
        assert received[0]["trigger"] == "test"


class TestTransitionDataclass:
    """Transition 数据类测试。"""

    def test_transition_creation(self):
        """应能创建转换记录。"""
        import time

        trans = Transition(
            from_state=State.IDLE,
            to_state=State.STARTING,
            timestamp=time.time(),
            trigger="test",
        )

        assert trans.from_state == State.IDLE
        assert trans.to_state == State.STARTING
        assert trans.trigger == "test"


class TestTransitionGraph:
    """转换规则图测试。"""

    def test_all_states_have_transitions(self):
        """所有状态都应有转换规则。"""
        for state in State:
            assert state in _TRANSITIONS, f"{state} 缺少转换规则"

    def test_idle_can_only_start(self):
        """IDLE 只能转换到 STARTING。"""
        assert _TRANSITIONS[State.IDLE] == {State.STARTING}

    def test_completed_can_return_to_idle(self):
        """COMPLETED 应能回到 IDLE。"""
        assert State.IDLE in _TRANSITIONS[State.COMPLETED]

    def test_error_can_recover(self):
        """ERROR 应能恢复。"""
        assert State.IDLE in _TRANSITIONS[State.ERROR]
        assert State.STARTING in _TRANSITIONS[State.ERROR]

    def test_no_dead_end(self):
        """没有死胡同状态（至少有一个出口）。"""
        for state, targets in _TRANSITIONS.items():
            assert len(targets) > 0, f"{state} 是死胡同状态"
