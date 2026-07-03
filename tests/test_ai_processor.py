"""AI Processor 模块单元测试。"""

import os
import pytest
from unittest.mock import patch, MagicMock

from spoken.ai.processor import AIProcessor, ProcessResult
from spoken.ai.prompts import get_system_prompt


class TestAIProcessorResolveApiKey:
    """API Key 解析逻辑测试。"""

    def test_env_variable_takes_priority(self):
        """环境变量应优先于配置文件中的 key。"""
        with patch.dict(os.environ, {"SPOKEN_AI_API_KEY": "env-key-123"}):
            proc = AIProcessor(api_key="config-key-456")
            assert proc._api_key == "env-key-123"
            assert proc.key_source == "environment"

    def test_config_key_used_when_no_env(self):
        """无环境变量时应使用配置文件中的 key（并发出警告）。"""
        with patch.dict(os.environ, {}, clear=True):
            # 移除可能存在的环境变量
            os.environ.pop("SPOKEN_AI_API_KEY", None)
            proc = AIProcessor(api_key="config-key-456")
            assert proc._api_key == "config-key-456"
            assert proc.key_source == "config"

    def test_no_key_available(self):
        """无任何 key 时应返回空字符串。"""
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("SPOKEN_AI_API_KEY", None)
            proc = AIProcessor(api_key="")
            assert proc._api_key == ""
            assert proc.key_source == "missing"

    def test_is_enabled_with_key(self):
        """有 key 时 is_enabled 应返回 True。"""
        with patch.dict(os.environ, {"SPOKEN_AI_API_KEY": "test-key"}):
            proc = AIProcessor()
            assert proc.is_enabled() is True

    def test_is_enabled_without_key(self):
        """无 key 时 is_enabled 应返回 False。"""
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("SPOKEN_AI_API_KEY", None)
            proc = AIProcessor(api_key="")
            assert proc.is_enabled() is False


class TestAIProcessorProcess:
    """处理逻辑测试。"""

    def test_mode_a_returns_original(self):
        """Mode A 应直接返回原文。"""
        with patch.dict(os.environ, {}, clear=True):
            os.environ.pop("SPOKEN_AI_API_KEY", None)
            proc = AIProcessor()
            result = proc.process("测试文字", mode="A")
            assert result.text == "测试文字"
            assert result.mode_used == "A"
            assert result.fallback is False

    def test_empty_text_returns_empty(self):
        """空文字应直接返回空。"""
        proc = AIProcessor()
        result = proc.process("  ", mode="A")
        assert result.text == ""

    def test_unknown_mode_fallback(self):
        """未知模式应降级为 Mode A。"""
        proc = AIProcessor()
        result = proc.process("测试", mode="X")
        assert result.fallback is True
        assert result.mode_used == "A"

    def test_mode_d_calls_ai(self):
        """Mode D 应调用 AI 并返回翻译结果。"""
        from spoken.ai.strategies import OpenAIStrategy
        proc = AIProcessor(api_key="demo-key")
        with patch.object(
            OpenAIStrategy, "process",
            return_value=ProcessResult(text="Hello world", mode_used="D", fallback=False),
        ) as mock_call:
            result = proc.process("你好，世界", mode="D")
        mock_call.assert_called_once()
        assert result.text == "Hello world"
        assert result.mode_used == "D"

    def test_mode_f_calls_ai(self):
        """Mode F 应调用 AI 并返回结构化纪要。"""
        from spoken.ai.strategies import OpenAIStrategy
        proc = AIProcessor(api_key="demo-key")
        structured = "主题：项目复盘\n事项：确认问题\n待办：补测试\n时间：明天下午"
        with patch.object(
            OpenAIStrategy, "process",
            return_value=ProcessResult(text=structured, mode_used="F", fallback=False),
        ) as mock_call:
            result = proc.process("我们明天下午做项目复盘，顺便把测试补一下", mode="F")
        mock_call.assert_called_once()
        assert result.text == structured
        assert result.mode_used == "F"

    def test_mode_c_normalizes_template_like_output(self):
        """Mode C 应清理说明性前缀，只保留最终 Prompt。"""
        from spoken.ai.client import AIClient
        proc = AIProcessor(api_key="demo-key")
        with patch.object(
            AIClient,
            "request",
            return_value={
                "text": "以下是优化后的 prompt：\n请写一个 Python 函数，接收列表输入并保持顺序去重。",
                "finish_reason": "stop",
            },
        ):
            result = proc.process("写个去重函数", mode="C")
        assert result.text == "请写一个 Python 函数，接收列表输入并保持顺序去重。"
        assert result.mode_used == "C"
        assert result.finish_reason == "stop"

    def test_truncated_response_falls_back_to_original_text(self):
        """模型因长度截断时应回退到原始文字，避免注入残缺内容。"""
        from spoken.ai.client import AIClient
        proc = AIProcessor(api_key="demo-key")
        original = "这是一个很长的原始文本，包含了很多内容"
        with patch.object(
            AIClient,
            "request",
            return_value={"text": "短", "finish_reason": "length"},
        ):
            result = proc.process(original, mode="B")
        assert result.text == original
        assert result.mode_used == "A"
        assert result.fallback is True
        assert result.truncated is True
        assert result.finish_reason == "length"

    def test_mode_c_strips_code_fence_output(self):
        """Mode C 应去掉模型偶发返回的代码围栏。"""
        from spoken.ai.strategies import OpenAIStrategy
        normalized = OpenAIStrategy._normalize_prompt_output("```text\nPrompt：\n请总结这段会议记录并提炼待办。\n```")
        assert normalized == "请总结这段会议记录并提炼待办。"


class TestProcessResult:
    """ProcessResult 测试。"""

    def test_success_property(self):
        """正常结果 success 应为 True。"""
        result = ProcessResult(text="你好", mode_used="B", fallback=False)
        assert result.success is True

    def test_fallback_success_property(self):
        """降级结果 success 应为 False。"""
        result = ProcessResult(text="你好", mode_used="A", fallback=True)
        assert result.success is False

    def test_repr(self):
        """repr 应包含状态信息。"""
        result = ProcessResult(text="你好", mode_used="B", fallback=False)
        assert "OK" in repr(result)

        result_timeout = ProcessResult(text="你好", mode_used="A", fallback=True, timed_out=True)
        assert "TIMEOUT" in repr(result_timeout)

        result_truncated = ProcessResult(text="你好", mode_used="A", fallback=True, truncated=True)
        assert "TRUNCATED" in repr(result_truncated)


class TestPrompts:
    """Prompt 模板测试。"""

    def test_get_system_prompt_b(self):
        """Mode B prompt 应包含润色相关关键词。"""
        prompt = get_system_prompt("B")
        assert "润色" in prompt or "修正" in prompt

    def test_get_system_prompt_c(self):
        """Mode C prompt 应明确要求输出可直接使用的完整 Prompt。"""
        prompt = get_system_prompt("C")
        assert "完整 Prompt" in prompt or "完整指令" in prompt
        assert "不是模板" in prompt or "占位符" in prompt

    def test_get_system_prompt_d(self):
        """Mode D prompt 应包含翻译相关关键词。"""
        prompt = get_system_prompt("D")
        assert "翻译" in prompt or "英文" in prompt

    def test_get_system_prompt_e(self):
        """Mode E prompt 应包含会议纪要相关关键词。"""
        prompt = get_system_prompt("E")
        assert "会议" in prompt or "纪要" in prompt

    def test_get_system_prompt_f(self):
        """Mode F prompt 应包含结构化整理相关关键词。"""
        prompt = get_system_prompt("F")
        assert "整理" in prompt or "结构" in prompt

    def test_custom_prompt_overrides_default(self):
        """自定义 prompt 应覆盖默认值。"""
        custom = "这是自定义prompt"
        result = get_system_prompt("B", custom_prompt=custom)
        assert result == custom

    def test_empty_custom_uses_default(self):
        """空自定义 prompt 应使用默认值。"""
        result = get_system_prompt("B", custom_prompt="")
        assert "润色" in result or "修正" in result

    def test_invalid_mode_raises(self):
        """无效模式应抛出 ValueError。"""
        with pytest.raises(ValueError):
            get_system_prompt("A")

        with pytest.raises(ValueError):
            get_system_prompt("X")
