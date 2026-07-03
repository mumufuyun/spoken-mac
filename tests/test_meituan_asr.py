"""
美团 ASR 适配器属性测试。

Property 8: API credential protection
For any log output or error message,
when the system logs ASR-related information,
then no API keys, secrets, or authentication tokens should appear in the output.

Property 9: API response parsing
For any valid Meituan ASR API response format,
when the system parses the response,
then the recognized text should be correctly extracted and passed to the pipeline.

Validates: Requirements 5.4, 5.5
"""

import unittest
from unittest.mock import MagicMock, patch


class TestMeituanASRAuthentication(unittest.TestCase):
    """Property 8: 测试 API 凭证保护。"""

    def test_credentials_not_logged(self):
        """凭证不应出现在日志中。"""
        from spoken.asr.meituan_asr import MeituanASREngine
        import logging

        # 创建一个内存日志处理器来捕获日志
        log_capture = []
        handler = logging.Handler()
        handler.emit = lambda record: log_capture.append(record.getMessage())

        logger = logging.getLogger("spoken.asr.meituan_asr")
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)

        try:
            engine = MeituanASREngine(
                app_key="secret_key_12345",
                app_secret="super_secret_67890",
            )

            # 触发认证
            auth = engine._authenticate()

            # 检查所有日志消息
            for msg in log_capture:
                self.assertNotIn("secret_key_12345", msg)
                self.assertNotIn("super_secret_67890", msg)

            # 认证结果不应是空的
            self.assertTrue(auth)
        finally:
            logger.removeHandler(handler)

    def test_load_requires_credentials(self):
        """缺少凭证时应报错。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine()
        with self.assertRaises(RuntimeError) as ctx:
            engine.load()
        self.assertIn("app_key", str(ctx.exception).lower())

    def test_load_validates_endpoint(self):
        """无效端点格式时应报错。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="http://invalid.com",
        )
        with self.assertRaises(RuntimeError) as ctx:
            engine.load()
        self.assertIn("endpoint", str(ctx.exception).lower())

    def test_endpoint_validation(self):
        """端点格式错误时应报错。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="http://invalid.com",  # 不是 wss://
        )
        with self.assertRaises(RuntimeError):
            engine.load()


class TestMeituanASRResponseParsing(unittest.TestCase):
    """Property 9: 测试 API 响应解析。"""

    def setUp(self):
        from spoken.asr.meituan_asr import MeituanASREngine

        self.engine = MeituanASREngine(
            app_key="test_key",
            app_secret="test_secret",
            endpoint="wss://test.sankuai.com",
        )

    def test_parse_partial_result(self):
        """中间结果应被正确解析。"""
        msg = '{"type": "partial", "text": "你好世界"}'
        self.engine._handle_message(msg)

        self.assertEqual(self.engine._partial_results, ["你好世界"])

    def test_parse_final_result(self):
        """最终结果应被正确解析。"""
        msg = '{"type": "final", "text": "你好世界，这是测试"}'
        self.engine._handle_message(msg)

        self.assertEqual(self.engine._final_result, "你好世界，这是测试")

    def test_parse_segment_result(self):
        """分段结果应被缓存。"""
        msg = '{"type": "segment", "text": "第一段内容"}'
        self.engine._handle_message(msg)

        self.assertEqual(self.engine._recognized_segments, ["第一段内容"])

    def test_parse_error_message(self):
        """错误消息应被正确处理而不崩溃。"""
        msg = '{"type": "error", "message": "服务暂时不可用"}'
        # 不应抛出异常
        self.engine._handle_message(msg)

    def test_parse_invalid_json(self):
        """无效 JSON 应被正确处理而不崩溃。"""
        msg = "not valid json"
        self.engine._handle_message(msg)
        # 不应抛出异常，结果应保持为空

    def test_parse_empty_message(self):
        """空消息应被正确处理。"""
        self.engine._handle_message('')
        self.engine._handle_message('{}')

    def test_multiple_partial_results(self):
        """多个中间结果应被累积。"""
        self.engine._handle_message('{"type": "partial", "text": "你好"}')
        self.engine._handle_message('{"type": "partial", "text": "世界"}')

        self.assertEqual(len(self.engine._partial_results), 2)
        self.assertEqual(self.engine._partial_results, ["你好", "世界"])

    def test_final_result_overwrites(self):
        """最终结果应被正确设置。"""
        self.engine._handle_message('{"type": "partial", "text": "临时"}')
        self.engine._handle_message('{"type": "final", "text": "最终结果"}')

        self.assertEqual(self.engine._final_result, "最终结果")


class TestMeituanASRLongAudio(unittest.TestCase):
    """测试长语音支持。"""

    def test_max_duration_configurable(self):
        """最大时长应可配置。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="wss://test.com",
            max_duration=300,
        )
        self.assertEqual(engine.max_duration, 300)

    def test_default_max_duration(self):
        """默认最大时长应为 600 秒。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="wss://test.com",
        )
        self.assertEqual(engine.max_duration, 600)


class TestMeituanASRState(unittest.TestCase):
    """测试状态管理。"""

    def test_initial_state(self):
        """初始状态应正确。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="wss://test.com",
        )
        self.assertFalse(engine.is_recording)
        self.assertFalse(engine.is_loaded)

    def test_load_sets_loaded_state(self):
        """加载后状态应更新。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="wss://test.com",
        )
        engine.load()
        self.assertTrue(engine.is_loaded)

    def test_unload_clears_state(self):
        """卸载后状态应重置。"""
        from spoken.asr.meituan_asr import MeituanASREngine

        engine = MeituanASREngine(
            app_key="key",
            app_secret="secret",
            endpoint="wss://test.com",
        )
        engine.load()
        engine.unload()
        self.assertFalse(engine.is_loaded)


if __name__ == "__main__":
    unittest.main()
