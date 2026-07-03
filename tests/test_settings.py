"""Config Settings 模块单元测试。"""

import pytest
from spoken.config import settings as settings_module
from spoken.config.settings import _deep_merge, mask_sensitive, _validate_config


class TestDeepMerge:
    """深层合并函数测试。"""

    def test_simple_override(self):
        """顶层键应被覆盖。"""
        base = {"a": 1, "b": 2}
        override = {"b": 3}
        result = _deep_merge(base, override)
        assert result == {"a": 1, "b": 3}

    def test_nested_override(self):
        """嵌套字典应递归合并。"""
        base = {"section": {"a": 1, "b": 2}}
        override = {"section": {"b": 3, "c": 4}}
        result = _deep_merge(base, override)
        assert result == {"section": {"a": 1, "b": 3, "c": 4}}

    def test_original_not_modified(self):
        """合并不应修改原始字典。"""
        base = {"a": 1}
        override = {"a": 2}
        result = _deep_merge(base, override)
        assert base["a"] == 1  # 未被修改
        assert result["a"] == 2

    def test_new_key_added(self):
        """新键应被添加。"""
        base = {"a": 1}
        override = {"b": 2}
        result = _deep_merge(base, override)
        assert result == {"a": 1, "b": 2}

    def test_type_override(self):
        """不同类型值应直接覆盖（不递归）。"""
        base = {"a": {"nested": 1}}
        override = {"a": "string"}
        result = _deep_merge(base, override)
        assert result == {"a": "string"}


class TestMaskSensitive:
    """脱敏函数测试。"""

    def test_mask_api_key(self):
        """API Key 应被脱敏。"""
        config = {"ai": {"api_key": "sk-1234567890abcdef", "model": "gpt-4"}}
        result = mask_sensitive(config)
        assert result["ai"]["api_key"] != "sk-1234567890abcdef"
        assert "***" in result["ai"]["api_key"]
        assert result["ai"]["model"] == "gpt-4"  # 非敏感字段不变

    def test_mask_short_key(self):
        """短 key 应完全遮盖。"""
        config = {"ai": {"api_key": "short"}}
        result = mask_sensitive(config)
        assert result["ai"]["api_key"] == "***"

    def test_no_sensitive_data(self):
        """无敏感数据时应原样返回。"""
        config = {"asr": {"mode": "realtime"}}
        result = mask_sensitive(config)
        assert result == config

    def test_original_not_modified(self):
        """脱敏不应修改原始字典。"""
        config = {"ai": {"api_key": "sk-1234567890abcdef"}}
        result = mask_sensitive(config)
        assert config["ai"]["api_key"] == "sk-1234567890abcdef"


class TestConfigPathResolution:
    """配置路径解析测试。"""

    def test_prefers_appdata_config_when_present(self, tmp_path, monkeypatch):
        """存在 APPDATA 配置时应优先使用。"""
        appdata_dir = tmp_path / "appdata"
        default_path = appdata_dir / "Spoken" / "config.toml"
        default_path.parent.mkdir(parents=True)
        default_path.write_text("[ai]\nenabled = true\n", encoding="utf-8")

        project_root = tmp_path / "project"
        project_root.mkdir()
        project_path = project_root / "config.toml"
        project_path.write_text("[ai]\nenabled = false\n", encoding="utf-8")

        monkeypatch.setattr(settings_module.sys, "platform", "win32")
        monkeypatch.setenv("APPDATA", str(appdata_dir))
        monkeypatch.setattr(settings_module, "__file__", str(project_root / "config" / "settings.py"))

        assert settings_module._get_user_config_path() == default_path

    def test_falls_back_to_project_config_when_appdata_missing(self, tmp_path, monkeypatch):
        """APPDATA 配置不存在时应回退到项目根目录配置。"""
        appdata_dir = tmp_path / "appdata"
        project_root = tmp_path / "project"
        project_root.mkdir()
        project_path = project_root / "config.toml"
        project_path.write_text("[ai]\nenabled = true\n", encoding="utf-8")

        monkeypatch.setattr(settings_module.sys, "platform", "win32")
        monkeypatch.setenv("APPDATA", str(appdata_dir))
        monkeypatch.setattr(settings_module, "__file__", str(project_root / "config" / "settings.py"))

        assert settings_module._get_user_config_path() == project_path

    def test_returns_default_target_when_no_config_exists(self, tmp_path, monkeypatch):
        """都不存在时应返回标准用户配置目标路径。"""
        appdata_dir = tmp_path / "appdata"
        project_root = tmp_path / "project"
        project_root.mkdir()

        monkeypatch.setattr(settings_module.sys, "platform", "win32")
        monkeypatch.setenv("APPDATA", str(appdata_dir))
        monkeypatch.setattr(settings_module, "__file__", str(project_root / "config" / "settings.py"))

        expected = appdata_dir / "Spoken" / "config.toml"
        assert settings_module._get_user_config_path() == expected


class TestValidateConfig:
    """配置校验测试。"""

    def test_valid_config_no_warnings(self):
        """合法配置不应产生错误。"""
        config = {
            "mode": {"default": "A"},
            "asr": {"mode": "realtime"},
            "injection": {"method": "auto"},
        }
        # 不应抛出异常
        _validate_config(config)

    def test_invalid_mode_corrected(self):
        """无效 mode.default 应被修正。"""
        config = {"mode": {"default": "X"}}
        _validate_config(config)
        assert config["mode"]["default"] == "A"

    def test_extended_mode_kept(self):
        """新增模式 D-F 应被视为合法默认模式。"""
        for mode in ("D", "E", "F"):
            config = {"mode": {"default": mode}}
            _validate_config(config)
            assert config["mode"]["default"] == mode

    def test_invalid_asr_mode_corrected(self):
        """无效 asr.mode 应被修正。"""
        config = {"asr": {"mode": "invalid"}}
        _validate_config(config)
        assert config["asr"]["mode"] == "realtime"

    def test_invalid_injection_method_corrected(self):
        """无效 injection.method 应被修正。"""
        config = {"injection": {"method": "invalid"}}
        _validate_config(config)
        assert config["injection"]["method"] == "auto"

    def test_negative_hybrid_long_form_sec_corrected(self):
        """负数 long_form_sec 应回退到默认值。"""
        config = {"asr": {"hybrid": {"long_form_sec": -1}}}
        _validate_config(config)
        assert config["asr"]["hybrid"]["long_form_sec"] == 10
