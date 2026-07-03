"""
热键管理器测试。

测试 hotkey/manager.py 中的：
1. HotkeyManager - 热键注册/注销/生命周期
2. PushToTalkHotkey - PTT 模式状态机
3. ToggleRecordHotkey - Toggle 模式状态机

Validates: Requirements - Hotkey management
"""

import threading
import unittest
from unittest.mock import MagicMock, patch

from spoken.hotkey.manager import HotkeyManager, PushToTalkHotkey, ToggleRecordHotkey


class TestHotkeyManager(unittest.TestCase):
    """HotkeyManager 单元测试。"""

    def test_register_adds_hotkey(self):
        """注册热键应添加到内部字典。"""
        manager = HotkeyManager()
        callback = MagicMock()
        manager.register("ctrl+alt+r", callback)
        self.assertIn("ctrl+alt+r", manager._hotkeys)
        self.assertEqual(manager._hotkeys["ctrl+alt+r"], callback)

    def test_register_overwrites_existing(self):
        """重复注册同一热键应替换回调。"""
        manager = HotkeyManager()
        cb1 = MagicMock()
        cb2 = MagicMock()
        manager.register("ctrl+r", cb1)
        manager.register("ctrl+r", cb2)
        self.assertEqual(manager._hotkeys["ctrl+r"], cb2)

    def test_unregister_removes_hotkey(self):
        """注销热键应从内部字典移除。"""
        manager = HotkeyManager()
        manager.register("ctrl+r", MagicMock())
        manager.unregister("ctrl+r")
        self.assertNotIn("ctrl+r", manager._hotkeys)

    def test_unregister_unknown_ignored(self):
        """注销未注册的热键应安全忽略。"""
        manager = HotkeyManager()
        # 不应抛出异常
        manager.unregister("ctrl+unknown")

    def test_is_running_initially_false(self):
        """初始状态应为未运行。"""
        manager = HotkeyManager()
        self.assertFalse(manager.is_running)

    def test_repr(self):
        """repr 应包含状态信息。"""
        manager = HotkeyManager()
        manager.register("ctrl+r", MagicMock())
        r = repr(manager)
        self.assertIn("已停止", r)
        self.assertIn("1", r)

    def test_register_raw_hook(self):
        """register_raw_hook 应添加 hook 函数。"""
        manager = HotkeyManager()
        hook_fn = MagicMock()
        manager.register_raw_hook(hook_fn)
        self.assertIn(hook_fn, manager._raw_hooks)


class TestPushToTalkHotkey(unittest.TestCase):
    """PushToTalkHotkey 单元测试。"""

    def test_combo_parsing(self):
        """热键组合应正确解析为主键和修饰键。"""
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        self.assertEqual(ptt._main_key, "r")
        self.assertEqual(ptt._modifiers, ["alt"])

    def test_combo_parsing_multi_modifier(self):
        """多修饰键组合应正确解析。"""
        ptt = PushToTalkHotkey(
            combo="ctrl+alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        self.assertEqual(ptt._main_key, "r")
        self.assertEqual(ptt._modifiers, ["ctrl", "alt"])

    def test_initial_not_recording(self):
        """初始状态应为未录音。"""
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        self.assertFalse(ptt.is_recording)

    def test_reset(self):
        """reset 应强制重置录音状态。"""
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        ptt._recording = True
        ptt.reset()
        self.assertFalse(ptt.is_recording)

    def test_key_down_starts_recording(self):
        """主键按下应触发 on_start。"""
        start_cb = MagicMock()
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=start_cb,
            on_stop=MagicMock(),
        )

        event = MagicMock()
        event.event_type = "down"
        event.name = "r"

        with patch.object(ptt, "_modifiers_held", return_value=True):
            ptt.handle_event(event)

        self.assertTrue(ptt.is_recording)

    def test_key_down_ignores_when_recording(self):
        """录音中再次按下应被忽略（防抖）。"""
        start_cb = MagicMock()
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=start_cb,
            on_stop=MagicMock(),
        )
        ptt._recording = True

        event = MagicMock()
        event.event_type = "down"
        event.name = "r"

        with patch.object(ptt, "_modifiers_held", return_value=True):
            with patch.object(ptt, "_start_release_watcher"):
                ptt.handle_event(event)

        # on_start 不应再被调用
        start_cb.assert_not_called()

    def test_key_up_stops_recording(self):
        """主键松开应触发 on_stop。"""
        stop_cb = MagicMock()
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=stop_cb,
        )
        ptt._recording = True

        event = MagicMock()
        event.event_type = "up"
        event.name = "r"

        ptt.handle_event(event)
        self.assertFalse(ptt.is_recording)

    def test_modifier_release_stops_recording(self):
        """修饰键松开应停止录音。"""
        stop_cb = MagicMock()
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=stop_cb,
        )
        ptt._recording = True

        event = MagicMock()
        event.event_type = "up"
        event.name = "alt"

        ptt.handle_event(event)
        self.assertFalse(ptt.is_recording)

    def test_is_main_key(self):
        """_is_main_key 应正确识别主键。"""
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        event = MagicMock()
        event.name = "r"
        self.assertTrue(ptt._is_main_key(event))

        event.name = "alt"
        self.assertFalse(ptt._is_main_key(event))

    def test_is_required_modifier_key(self):
        """_is_required_modifier_key 应正确识别修饰键。"""
        ptt = PushToTalkHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        event = MagicMock()
        event.name = "alt"
        self.assertTrue(ptt._is_required_modifier_key(event))

        event.name = "r"
        self.assertFalse(ptt._is_required_modifier_key(event))


class TestToggleRecordHotkey(unittest.TestCase):
    """ToggleRecordHotkey 单元测试。"""

    def test_initial_not_recording(self):
        """初始状态应为未录音。"""
        toggle = ToggleRecordHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        self.assertFalse(toggle.is_recording)

    def test_first_toggle_starts(self):
        """第一次触发应开始录音。"""
        start_cb = MagicMock()
        toggle = ToggleRecordHotkey(
            combo="alt+r",
            on_start=start_cb,
            on_stop=MagicMock(),
        )
        toggle.handle()
        self.assertTrue(toggle.is_recording)

    def test_second_toggle_stops(self):
        """第二次触发应停止录音。"""
        stop_cb = MagicMock()
        toggle = ToggleRecordHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=stop_cb,
        )
        toggle.handle()  # 开始
        toggle.handle()  # 停止
        self.assertFalse(toggle.is_recording)

    def test_reset(self):
        """reset 应强制重置状态。"""
        toggle = ToggleRecordHotkey(
            combo="alt+r",
            on_start=MagicMock(),
            on_stop=MagicMock(),
        )
        toggle._recording = True
        toggle.reset()
        self.assertFalse(toggle.is_recording)

    def test_cycle_multiple_times(self):
        """多次触发应正确交替。"""
        start_cb = MagicMock()
        stop_cb = MagicMock()
        toggle = ToggleRecordHotkey(
            combo="alt+r",
            on_start=start_cb,
            on_stop=stop_cb,
        )

        for _ in range(5):
            toggle.handle()  # 开始
            self.assertTrue(toggle.is_recording)
            toggle.handle()  # 停止
            self.assertFalse(toggle.is_recording)


if __name__ == "__main__":
    unittest.main()
