"""Errors 模块单元测试。"""

import pytest

from spoken.core.errors import ErrorCode, SpokenError


class TestErrorCode:
    """错误码测试。"""

    def test_all_codes_have_format(self):
        """所有错误码应符合 E### 格式。"""
        for code in ErrorCode:
            assert code.code.startswith("E")
            assert len(code.code) == 4
            assert code.message

    def test_code_categories(self):
        """错误码应按类别分组。"""
        assert ErrorCode.UNKNOWN.code == "E100"
        assert ErrorCode.ASR_LOAD_FAILED.code == "E200"
        assert ErrorCode.AI_NO_API_KEY.code == "E300"
        assert ErrorCode.INJECT_FAILED.code == "E400"
        assert ErrorCode.NETWORK_ERROR.code == "E500"


class TestSpokenError:
    """SpokenError 测试。"""

    def test_basic_creation(self):
        err = SpokenError(ErrorCode.ASR_LOAD_FAILED, "Windows 引擎初始化失败")
        assert err.code == ErrorCode.ASR_LOAD_FAILED
        assert "Windows 引擎初始化失败" in str(err)

    def test_with_suggestion(self):
        err = SpokenError(
            ErrorCode.AI_NO_API_KEY,
            detail="未找到 API Key",
            suggestion="请设置环境变量 SPOKEN_AI_API_KEY",
        )
        text = str(err)
        assert "E300" in text
        assert "建议:" in text

    def test_to_dict(self):
        err = SpokenError(ErrorCode.NETWORK_ERROR, "连接超时")
        d = err.to_dict()
        assert d["code"] == "E500"
        assert d["message"] == "网络连接错误"
        assert d["detail"] == "连接超时"

    def test_is_exception(self):
        """SpokenError 应可被抛出和捕获。"""
        with pytest.raises(SpokenError) as exc_info:
            raise SpokenError(ErrorCode.CONFIG_INVALID, "格式错误")
        assert exc_info.value.code == ErrorCode.CONFIG_INVALID
