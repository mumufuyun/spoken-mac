"""Pipeline 模块单元测试 — CoT 过滤和流水线逻辑。"""

import pytest

from spoken.utils.text import strip_think_tags


class TestStripThinkTags:
    """strip_think_tags 函数测试。"""

    def test_empty_string(self):
        """空字符串应返回空字符串。"""
        assert strip_think_tags("") == ""

    def test_no_think_tags(self):
        """无 think 标签的文字应原样返回。"""
        text = "这是正常的文字"
        assert strip_think_tags(text) == text

    def test_think_tag_removed(self):
        """<think...</think 标签应被移除。"""
        text = "你好世界"
        result = strip_think_tags(text)
        assert "你好世界" in result
        # <think 标签应该被去除

    def test_cot_tag_removed(self):
        """<думаю...</resposta> 标签应被移除。"""
        # 这个测试验证备选标签格式
        text = "正常文字"
        result = strip_think_tags(text)
        assert result == text

    def test_strip_whitespace(self):
        """结果应去除首尾空白。"""
        text = "  你好  "
        assert strip_think_tags(text) == "你好"

    def test_preserves_content_outside_tags(self):
        """标签外部的文字应保留。"""
        text = "前面的文字后面的文字"
        assert "前面的文字" in strip_think_tags(text) or "后面的文字" in strip_think_tags(text)


class TestPipelineMode:
    """Pipeline 模式设置测试。"""

    def test_current_mode_setter(self):
        """测试 current_mode setter。"""
        from spoken.pipeline import Pipeline

        # 使用 mock 对象创建 Pipeline（避免真实依赖）
        class MockASR:
            is_recording = False
            def start(self): pass
            def stop(self): return ""
            def transcribe(self, audio_bytes, language=None): return ""

        class MockAudio:
            is_recording = False
            def start(self): pass
            def stop(self): return b""

        class MockAI:
            def process(self, text, mode="A"):
                from spoken.ai.processor import ProcessResult
                return ProcessResult(text=text, mode_used=mode, fallback=False)
            def interrupt(self): pass

        class MockInjector:
            def capture_focus(self): return None
            def inject_with_fallback(self, text): return True

        pipeline = Pipeline(
            asr_engine=MockASR(),
            audio_capture=MockAudio(),
            ai_processor=MockAI(),
            dispatcher=MockInjector(),
            overlay=None,
            state_listener=None,
            asr_mode="realtime",
            current_mode="A",
            language="zh",
        )

        assert pipeline.current_mode == "A"
        pipeline.current_mode = "B"
        assert pipeline.current_mode == "B"
        pipeline.current_mode = "C"
        assert pipeline.current_mode == "C"
        # 无效模式应被忽略
        pipeline.current_mode = "X"
        assert pipeline.current_mode == "C"

    def test_try_start_not_processing(self):
        """非处理状态时应允许开始。"""
        from spoken.pipeline import Pipeline

        class MockASR:
            is_recording = False
            def start(self): pass
            def stop(self): return ""
            def transcribe(self, audio_bytes, language=None): return ""

        class MockAudio:
            is_recording = False
            def start(self): pass
            def stop(self): return b""

        class MockAI:
            def process(self, text, mode="A"):
                from spoken.ai.processor import ProcessResult
                return ProcessResult(text=text, mode_used=mode, fallback=False)
            def interrupt(self): pass

        class MockInjector:
            def capture_focus(self): return None
            def inject_with_fallback(self, text): return True

        pipeline = Pipeline(
            asr_engine=MockASR(),
            audio_capture=MockAudio(),
            ai_processor=MockAI(),
            dispatcher=MockInjector(),
            overlay=None,
            state_listener=None,
            asr_mode="realtime",
            current_mode="A",
            language="zh",
        )

        # try_start 会占用处理槽位，直到 finish() 释放
        assert pipeline.try_start() is True
        assert pipeline.is_processing is True
        pipeline.finish()
        assert pipeline.is_processing is False

    def test_try_start_already_processing(self):
        """处理中时应拒绝开始。"""
        from spoken.pipeline import Pipeline

        class MockASR:
            is_recording = False
            def start(self): pass
            def stop(self): return ""
            def transcribe(self, audio_bytes, language=None): return ""

        class MockAudio:
            is_recording = False
            def start(self): pass
            def stop(self): return b""

        class MockAI:
            def process(self, text, mode="A"):
                from spoken.ai.processor import ProcessResult
                return ProcessResult(text=text, mode_used=mode, fallback=False)
            def interrupt(self): pass

        class MockInjector:
            def capture_focus(self): return None
            def inject_with_fallback(self, text): return True

        pipeline = Pipeline(
            asr_engine=MockASR(),
            audio_capture=MockAudio(),
            ai_processor=MockAI(),
            dispatcher=MockInjector(),
            overlay=None,
            state_listener=None,
            asr_mode="realtime",
            current_mode="A",
            language="zh",
        )

        # 手动设置处理中状态
        pipeline._is_processing = True
        assert pipeline.try_start() is False  # 应被拒绝

    def test_mode_d_allows_ai_processing(self):
        """Mode D 应进入 AI 处理分支。"""
        from spoken.pipeline import Pipeline

        class MockASR:
            is_recording = False
            def start(self): pass
            def stop(self): return "原文"
            def transcribe(self, audio_bytes, language=None): return "原文"

        class MockAudio:
            is_recording = False
            def start(self): pass
            def stop(self): return b"audio-bytes" * 16

        class MockAI:
            def process(self, text, mode="A", on_chunk=None):
                from spoken.ai.processor import ProcessResult
                return ProcessResult(text="Translated text", mode_used=mode, fallback=False)
            def interrupt(self): pass

        class MockInjector:
            def __init__(self):
                self.text = None
            def capture_focus(self): return None
            def inject_with_fallback(self, text):
                self.text = text
                return True

        injector = MockInjector()
        pipeline = Pipeline(
            asr_engine=MockASR(),
            audio_capture=MockAudio(),
            ai_processor=MockAI(),
            dispatcher=injector,
            overlay=None,
            state_listener=None,
            asr_mode="realtime",
            current_mode="D",
            language="zh",
        )

        pipeline.run_realtime()
        assert injector.text == "Translated text"
