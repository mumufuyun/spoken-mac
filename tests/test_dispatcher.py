"""
注入器调度逻辑测试。

测试 injector/dispatcher.py 中 TextDispatcher 的策略选择：
1. 强制模式（clipboard / sendinput）
2. auto 模式下 Electron / UWP / UAC 检测
3. 目标窗口策略（smart / locked_on_start / current）
4. from_config 工厂方法

Validates: Requirements - Injection strategy selection
"""

import unittest
from unittest.mock import MagicMock, patch, PropertyMock

from spoken.injector.dispatcher import TextDispatcher
from spoken.utils.window import WindowInfo


def _make_window(
    hwnd=100, pid=1234, exe_name="notepad.exe",
    exe_path="C:\\Windows\\notepad.exe", title="记事本",
    is_electron=False, is_uwp=False, is_elevated=False,
):
    """创建测试用 WindowInfo 实例。"""
    return WindowInfo(
        hwnd=hwnd, pid=pid, exe_name=exe_name,
        exe_path=exe_path, title=title,
        is_electron=is_electron, is_uwp=is_uwp, is_elevated=is_elevated,
    )


class TestTextDispatcherStrategySelection(unittest.TestCase):
    """测试注入策略选择逻辑。"""

    def test_forced_clipboard_method(self):
        """method=clipboard 时应强制使用剪贴板。"""
        dispatcher = TextDispatcher(method="clipboard")
        name = dispatcher._select_injector_name()
        self.assertEqual(name, "clipboard")

    def test_forced_sendinput_method(self):
        """method=sendinput 时应强制使用 SendInput。"""
        dispatcher = TextDispatcher(method="sendinput")
        name = dispatcher._select_injector_name()
        self.assertEqual(name, "sendinput")

    def test_auto_method_with_no_window(self):
        """auto 模式无窗口信息时应默认 SendInput。"""
        dispatcher = TextDispatcher(method="auto")
        with patch.object(dispatcher, "_resolve_target_window", return_value=None):
            name = dispatcher._select_injector_name()
            self.assertEqual(name, "sendinput")

    def test_auto_method_with_electron_app(self):
        """auto 模式下 Electron 应用应走剪贴板。"""
        dispatcher = TextDispatcher(method="auto")
        window = _make_window(exe_name="code.exe", is_electron=True)
        with patch.object(dispatcher, "_resolve_target_window", return_value=window):
            name = dispatcher._select_injector_name()
            self.assertEqual(name, "clipboard")

    def test_auto_method_with_uwp_app(self):
        """auto 模式下 UWP 应用应走剪贴板。"""
        dispatcher = TextDispatcher(method="auto")
        window = _make_window(
            exe_name="ApplicationFrameHost.exe",
            title="设置", is_uwp=True,
        )
        with patch.object(dispatcher, "_resolve_target_window", return_value=window):
            name = dispatcher._select_injector_name()
            self.assertEqual(name, "clipboard")

    def test_auto_method_with_normal_app(self):
        """auto 模式下普通应用应走 SendInput。"""
        dispatcher = TextDispatcher(method="auto")
        window = _make_window(exe_name="notepad.exe", title="记事本")
        with patch.object(dispatcher, "_resolve_target_window", return_value=window):
            name = dispatcher._select_injector_name()
            self.assertEqual(name, "sendinput")

    def test_auto_method_with_clipboard_force_app(self):
        """auto 模式下配置的强制剪贴板应用应走剪贴板。"""
        dispatcher = TextDispatcher(
            method="auto",
            clipboard_force_apps=["notepad.exe", "weixin.exe"],
        )
        window = _make_window(exe_name="notepad.exe", title="记事本")
        with patch.object(dispatcher, "_resolve_target_window", return_value=window):
            name = dispatcher._select_injector_name()
            self.assertEqual(name, "clipboard")

    def test_auto_method_with_elevated_app_unprivileged(self):
        """auto 模式下提权窗口且当前进程未提权时应返回 None。"""
        dispatcher = TextDispatcher(method="auto")
        window = _make_window(
            exe_name="taskmgr.exe", title="任务管理器", is_elevated=True,
        )
        with patch.object(dispatcher, "_resolve_target_window", return_value=window):
            with patch("ctypes.windll") as mock_windll:
                mock_windll.shell32.IsUserAnAdmin.return_value = 0  # 未提权
                name = dispatcher._select_injector_name()
                self.assertIsNone(name)


class TestTextDispatcherTargetWindow(unittest.TestCase):
    """测试目标窗口策略。"""

    def test_locked_on_start_uses_captured(self):
        """locked_on_start 策略应始终使用录音时捕获的窗口。"""
        dispatcher = TextDispatcher(target_window="locked_on_start")
        captured = _make_window(hwnd=100, exe_name="notepad.exe", title="记事本")
        dispatcher._captured_window = captured

        with patch("spoken.injector.dispatcher.get_foreground_window_info") as mock_fg:
            mock_fg.return_value = _make_window(
                hwnd=200, exe_name="code.exe", title="VS Code", is_electron=True,
            )
            result = dispatcher._resolve_target_window()
            self.assertEqual(result.hwnd, 100)

    def test_current_uses_foreground(self):
        """current 策略应使用当前前台窗口。"""
        dispatcher = TextDispatcher(target_window="current")
        captured = _make_window(hwnd=100, exe_name="notepad.exe", title="记事本")
        dispatcher._captured_window = captured

        current = _make_window(
            hwnd=200, exe_name="code.exe", title="VS Code", is_electron=True,
        )
        with patch("spoken.injector.dispatcher.get_foreground_window_info", return_value=current):
            result = dispatcher._resolve_target_window()
            self.assertEqual(result.hwnd, 200)

    def test_smart_same_process_follows_current(self):
        """smart 策略下同进程应跟随当前焦点。"""
        dispatcher = TextDispatcher(target_window="smart")
        captured = _make_window(
            hwnd=100, pid=1234, exe_name="code.exe", title="VS Code 1",
            is_electron=True,
        )
        dispatcher._captured_window = captured

        current = _make_window(
            hwnd=200, pid=1234, exe_name="code.exe", title="VS Code 2",
            is_electron=True,
        )
        with patch("spoken.injector.dispatcher.get_foreground_window_info", return_value=current):
            result = dispatcher._resolve_target_window()
            self.assertEqual(result.hwnd, 200)

    def test_invalid_target_window_defaults_to_smart(self):
        """无效的 target_window 应默认为 smart。"""
        dispatcher = TextDispatcher(target_window="invalid")
        self.assertEqual(dispatcher._target_window, "smart")


class TestTextDispatcherFromConfig(unittest.TestCase):
    """测试 from_config 工厂方法。"""

    def test_from_config_defaults(self):
        """空配置应使用默认值。"""
        dispatcher = TextDispatcher.from_config({})
        self.assertEqual(dispatcher._method, "auto")
        self.assertEqual(dispatcher._focus_delay_ms, 20)

    def test_from_config_custom(self):
        """自定义配置应正确传入。"""
        config = {
            "method": "clipboard",
            "focus_delay_ms": 50,
            "char_delay_ms": 10,
            "batch_size": 200,
            "batch_delay_ms": 5,
            "clipboard_force_apps": ["code.exe"],
            "target_window": "locked_on_start",
        }
        dispatcher = TextDispatcher.from_config(config)
        self.assertEqual(dispatcher._method, "clipboard")
        self.assertEqual(dispatcher._focus_delay_ms, 50)
        self.assertEqual(dispatcher._target_window, "locked_on_start")
        self.assertIn("code.exe", dispatcher._clipboard_force_apps)


class TestTextDispatcherInjectEmpty(unittest.TestCase):
    """测试空文本注入。"""

    def test_inject_empty_string(self):
        """空字符串应直接返回 True。"""
        dispatcher = TextDispatcher()
        self.assertTrue(dispatcher.inject(""))

    def test_inject_with_fallback_empty_string(self):
        """inject_with_fallback 空字符串应直接返回 True。"""
        dispatcher = TextDispatcher()
        self.assertTrue(dispatcher.inject_with_fallback(""))


if __name__ == "__main__":
    unittest.main()
