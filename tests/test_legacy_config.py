"""
遗留配置自动修复测试。

测试 _fix_legacy_config 方法：
1. 检测并修复旧版 win+space 快捷键
2. 无遗留配置时不做修改
3. settings 为空时安全返回

Validates: Requirements - Legacy config auto-fix
"""

import unittest
from unittest.mock import MagicMock, patch, call


class TestFixLegacyConfig(unittest.TestCase):
    """测试 SpokenApp._fix_legacy_config 方法。"""

    def _make_app(self, settings=None):
        """创建一个模拟的 SpokenApp 实例，只暴露 _fix_legacy_config 需要的接口。"""
        from spoken.__main__ import SpokenApp
        app = object.__new__(SpokenApp)
        app._settings = settings
        return app

    def test_fix_win_space_to_alt_r(self):
        """检测到 win+space 时应自动修复为 alt+r。"""
        settings = MagicMock()
        settings.get.return_value = "win+space"
        app = self._make_app(settings)

        app._fix_legacy_config()

        settings.set_and_save_async.assert_called_once_with(
            "hotkey", "toggle_record", "alt+r"
        )

    def test_no_fix_when_alt_r(self):
        """当前已是 alt+r 时不应修改。"""
        settings = MagicMock()
        settings.get.return_value = "alt+r"
        app = self._make_app(settings)

        app._fix_legacy_config()

        settings.set_and_save_async.assert_not_called()

    def test_no_fix_when_custom_hotkey(self):
        """使用其他自定义快捷键时不应修改。"""
        settings = MagicMock()
        settings.get.return_value = "ctrl+alt+r"
        app = self._make_app(settings)

        app._fix_legacy_config()

        settings.set_and_save_async.assert_not_called()

    def test_no_fix_when_no_settings(self):
        """settings 为 None 时应安全返回。"""
        app = self._make_app(None)

        # 不应抛出异常
        app._fix_legacy_config()

    def test_default_value_is_alt_r(self):
        """get 方法的 default 参数应为 alt+r。"""
        settings = MagicMock()
        settings.get.return_value = "alt+r"  # 返回默认值
        app = self._make_app(settings)

        app._fix_legacy_config()

        # 验证 get 被正确调用
        settings.get.assert_called_once_with(
            "hotkey", "toggle_record", default="alt+r"
        )


if __name__ == "__main__":
    unittest.main()
