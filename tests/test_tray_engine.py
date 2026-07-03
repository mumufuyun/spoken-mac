"""
托盘引擎切换功能测试。

Validates: 托盘设置入口支持切换语音识别引擎
"""

import unittest
from unittest.mock import MagicMock, patch


class MockPystray:
    """模拟 pystray 模块。"""

    class Menu:
        def __init__(self, *items):
            self.items = items

        SEPARATOR = "SEPARATOR"

    class MenuItem:
        def __init__(self, text, action, checked=None, radio=False):
            self.text = text
            self.action = action
            self.checked = checked
            self.radio = radio


class TestTrayEngineSwitch(unittest.TestCase):
    """测试托盘引擎切换功能。"""

    def test_tray_icon_accepts_engine_callback(self):
        """TrayIcon 应接受 on_engine_change 回调。"""
        from spoken.tray.icon import TrayIcon

        callback = MagicMock()
        tray = TrayIcon(on_engine_change=callback, initial_engine="xunfei")

        self.assertEqual(tray._current_engine, "xunfei")
        self.assertEqual(tray._on_engine_change, callback)

    def test_set_engine_updates_state(self):
        """set_engine 应更新当前引擎状态。"""
        from spoken.tray.icon import TrayIcon

        tray = TrayIcon(initial_engine="xunfei")
        tray._pystray = MockPystray()
        tray._icon = MagicMock()

        tray.set_engine("meituan")
        self.assertEqual(tray._current_engine, "meituan")

        tray.set_engine("windows")
        self.assertEqual(tray._current_engine, "windows")

    def test_set_engine_invalid_ignored(self):
        """无效引擎名应被忽略。"""
        from spoken.tray.icon import TrayIcon

        tray = TrayIcon(initial_engine="xunfei")
        tray._pystray = MockPystray()
        tray._icon = MagicMock()

        tray.set_engine("invalid")
        self.assertEqual(tray._current_engine, "xunfei")  # 不变

    def test_engine_change_callback_fired(self):
        """引擎菜单点击应触发回调。"""
        from spoken.tray.icon import TrayIcon

        callback = MagicMock()
        tray = TrayIcon(on_engine_change=callback, initial_engine="xunfei")
        tray._pystray = MockPystray()
        tray._icon = MagicMock()

        # 模拟点击 meituan 引擎
        handler = tray._make_engine_handler("meituan")
        handler()

        callback.assert_called_once_with("meituan")
        self.assertEqual(tray._current_engine, "meituan")

    def test_menu_contains_engine_options(self):
        """菜单中应包含引擎选择项。"""
        from spoken.tray.icon import TrayIcon

        tray = TrayIcon(initial_engine="xunfei")
        tray._pystray = MockPystray()

        menu = tray._build_menu()

        # 查找引擎选择子菜单
        engine_menu = None
        for item in menu.items:
            if isinstance(item, MockPystray.MenuItem) and item.text == "引擎选择":
                engine_menu = item.action
                break

        self.assertIsNotNone(engine_menu, "菜单中应包含'引擎选择'子菜单")

        # 检查子菜单中的引擎选项
        engine_texts = []
        for item in engine_menu.items:
            if isinstance(item, MockPystray.MenuItem):
                engine_texts.append(item.text)

        self.assertIn("美团 ASR", engine_texts)
        self.assertIn("讯飞实时", engine_texts)
        self.assertIn("Windows 原生", engine_texts)

    def test_engine_radio_checked(self):
        """当前引擎应为 checked 状态。"""
        from spoken.tray.icon import TrayIcon

        tray = TrayIcon(initial_engine="xunfei")
        tray._pystray = MockPystray()

        menu = tray._build_menu()

        # 找到引擎选择子菜单
        engine_menu = None
        for item in menu.items:
            if isinstance(item, MockPystray.MenuItem) and item.text == "引擎选择":
                engine_menu = item.action
                break

        self.assertIsNotNone(engine_menu)

        # 检查讯飞实时为 checked
        for item in engine_menu.items:
            if item.text == "讯飞实时":
                self.assertTrue(item.checked(None))
            elif item.text == "美团 ASR":
                self.assertFalse(item.checked(None))

    def test_engine_switch_updates_checked(self):
        """切换引擎后 checked 状态应更新。"""
        from spoken.tray.icon import TrayIcon

        tray = TrayIcon(initial_engine="xunfei")
        tray._pystray = MockPystray()
        tray._icon = MagicMock()

        tray.set_engine("meituan")

        menu = tray._build_menu()
        engine_menu = None
        for item in menu.items:
            if isinstance(item, MockPystray.MenuItem) and item.text == "引擎选择":
                engine_menu = item.action
                break

        for item in engine_menu.items:
            if item.text == "美团 ASR":
                self.assertTrue(item.checked(None))
            elif item.text == "讯飞实时":
                self.assertFalse(item.checked(None))


if __name__ == "__main__":
    unittest.main()
