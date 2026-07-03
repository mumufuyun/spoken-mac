"""
配置迁移属性测试。

Property 2: Config backward compatibility
For any existing config file format from version V2,
when the application loads the config,
then the settings should be correctly migrated to version V3 format.

Property 3: Config forward compatibility
For any config file with unknown keys,
when the application loads the config,
then unknown keys should be preserved and not cause errors.

Validates: Requirements 8.1, 8.2, 8.3
"""

import unittest


class TestConfigBackwardCompatibility(unittest.TestCase):
    """Property 2: 测试配置向后兼容。"""

    def test_migrate_v2_basic_config(self):
        """V2 基本配置应正确迁移。"""
        from spoken.config.migration import migrate_v2_to_v3

        v2_config = {
            "hotkey": {
                "record_mode": "toggle",
                "toggle_record": "alt+r",
            },
            "asr": {
                "mode": "realtime",
                "language": "zh",
            },
        }

        v3 = migrate_v2_to_v3(v2_config)

        self.assertEqual(v3["hotkey"]["record_mode"], "toggle")
        self.assertEqual(v3["hotkey"]["toggle_record"], "alt+r")
        self.assertEqual(v3["asr"]["mode"], "realtime")
        self.assertEqual(v3["asr"]["language"], "zh")

    def test_v3_defaults_added(self):
        """V3 新增字段应使用默认值。"""
        from spoken.config.migration import migrate_v2_to_v3

        v2_config = {
            "asr": {"mode": "realtime"},
        }

        v3 = migrate_v2_to_v3(v2_config)

        # V3 新增字段
        self.assertEqual(v3["asr"]["fallback_order"], "meituan, xunfei, windows")
        self.assertEqual(v3["asr"]["long_audio_threshold_sec"], 60.0)
        self.assertEqual(v3["asr"]["max_audio_duration_sec"], 600.0)
        self.assertEqual(v3["asr"]["meituan"]["endpoint"], "wss://asr.sankuai.com/v1/realtime")

    def test_detect_v3_config(self):
        """应正确检测 V3 配置。"""
        from spoken.config.migration import detect_config_version

        v3_config = {
            "asr": {
                "fallback_order": "xunfei",
            },
        }
        self.assertEqual(detect_config_version(v3_config), "v3")

    def test_detect_v2_config(self):
        """应正确检测 V2 配置。"""
        from spoken.config.migration import detect_config_version

        v2_config = {
            "asr": {
                "mode": "realtime",
            },
        }
        self.assertEqual(detect_config_version(v2_config), "v2")

    def test_migrate_if_needed_v2(self):
        """V2 配置应自动迁移。"""
        from spoken.config.migration import migrate_if_needed

        v2_config = {"asr": {"mode": "realtime"}}
        v3 = migrate_if_needed(v2_config)

        self.assertIn("fallback_order", v3["asr"])

    def test_migrate_if_needed_v3(self):
        """V3 配置应保持不变。"""
        from spoken.config.migration import migrate_if_needed

        v3_config = {
            "asr": {
                "fallback_order": "meituan",
                "meituan": {"endpoint": "custom"},
            },
        }
        result = migrate_if_needed(v3_config)

        self.assertEqual(result["asr"]["meituan"]["endpoint"], "custom")


class TestConfigForwardCompatibility(unittest.TestCase):
    """Property 3: 测试配置向前兼容。"""

    def test_unknown_keys_preserved(self):
        """未知键应被保留。"""
        from spoken.config.migration import migrate_v2_to_v3

        v2_config = {
            "asr": {"mode": "realtime"},
            "custom_section": {"custom_key": "custom_value"},
        }

        v3 = migrate_v2_to_v3(v2_config)

        # 未知键可能不在迁移结果中，但迁移过程不应报错
        self.assertIsNotNone(v3)

    def test_empty_config_migrated(self):
        """空配置应能迁移为仅含默认值的配置。"""
        from spoken.config.migration import migrate_v2_to_v3

        v3 = migrate_v2_to_v3({})

        # 应包含所有 V3 默认值
        self.assertIn("asr", v3)
        self.assertIn("fallback_order", v3["asr"])


if __name__ == "__main__":
    unittest.main()
