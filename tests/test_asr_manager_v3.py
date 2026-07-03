"""
ASR Manager V3 属性测试。

Property 7: ASR engine fallback
For any ASR engine failure scenario,
when the current engine fails to initialize or connect,
then the system should attempt to use the next available engine in the priority list.

Property 6: Long audio continuity
For any audio stream longer than 60 seconds,
when the ASR engine processes it,
then the engine should continue recognition until explicitly stopped.

Validates: Requirements 4.1, 4.4, 5.2
"""

import time
import unittest
from unittest.mock import MagicMock, patch


class MockASREngine:
    """模拟 ASR 引擎。"""

    def __init__(self, name="mock", load_fail=False, start_fail=False, max_duration=600):
        self.name = name
        self._loaded = False
        self._load_fail = load_fail
        self._start_fail = start_fail
        self.max_duration = max_duration
        self.start_called = False
        self.stop_called = False
        self.stop_result = ""

    def load(self):
        if self._load_fail:
            raise RuntimeError(f"{self.name} load failed")
        self._loaded = True

    def unload(self):
        self._loaded = False

    @property
    def is_loaded(self):
        return self._loaded

    def start(self):
        if self._start_fail:
            raise RuntimeError(f"{self.name} start failed")
        self.start_called = True

    def stop(self):
        self.stop_called = True
        return self.stop_result or f"result from {self.name}"


class TestASREngineFallback(unittest.TestCase):
    """Property 7: 测试 ASR 引擎降级逻辑。"""

    def test_fallback_on_load_failure(self):
        """主引擎加载失败时自动回退到备用引擎。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", load_fail=True)
        secondary = MockASREngine("secondary")

        mgr.register("primary", primary, primary=True)
        mgr.register("secondary", secondary, fallback_order=1)

        result = mgr.load()

        self.assertTrue(result)
        self.assertEqual(mgr.current_engine_name, "secondary")
        self.assertTrue(secondary.is_loaded)
        self.assertFalse(primary.is_loaded)

    def test_fallback_on_start_failure(self):
        """主引擎启动失败时自动回退。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", start_fail=True)
        secondary = MockASREngine("secondary")

        mgr.register("primary", primary, primary=True)
        mgr.register("secondary", secondary, fallback_order=1)

        # 先加载
        self.assertTrue(mgr.load())
        # 启动时失败，应回退
        result = mgr.start()

        self.assertTrue(result)
        self.assertEqual(mgr.current_engine_name, "secondary")
        self.assertTrue(secondary.start_called)

    def test_all_engines_fail(self):
        """所有引擎都失败时返回失败。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", load_fail=True)
        secondary = MockASREngine("secondary", load_fail=True)

        mgr.register("primary", primary, primary=True)
        mgr.register("secondary", secondary, fallback_order=1)

        result = mgr.load()

        self.assertFalse(result)
        self.assertEqual(mgr.current_engine_name, "")
        self.assertEqual(mgr.state, "error")

    def test_fallback_priority_order(self):
        """回退应按优先级顺序尝试。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", load_fail=True)
        second = MockASREngine("second", load_fail=True)
        third = MockASREngine("third")

        mgr.register("primary", primary, primary=True)
        mgr.register("second", second, fallback_order=2)
        mgr.register("third", third, fallback_order=1)

        result = mgr.load()

        self.assertTrue(result)
        # fallback_order 小的优先
        self.assertEqual(mgr.current_engine_name, "third")


class TestASRLongAudio(unittest.TestCase):
    """Property 6: 测试长语音支持。"""

    def test_long_audio_threshold_default(self):
        """默认长语音阈值应为 60 秒。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        self.assertEqual(mgr._long_audio_threshold, 60.0)

    def test_recording_duration_tracking(self):
        """录音时长应被正确跟踪。"""
        from spoken.asr.manager import ASRManager
        import time

        mgr = ASRManager()
        engine = MockASREngine("test")
        mgr.register("test", engine, primary=True)

        # 加载并启动
        self.assertTrue(mgr.load())
        self.assertTrue(mgr.start())

        # 检查录音时长
        time.sleep(0.1)
        duration = mgr.get_recording_duration()
        self.assertGreater(duration, 0.0)
        self.assertLess(duration, 1.0)

        # 停止后时长应重置
        mgr.stop()
        self.assertEqual(mgr.get_recording_duration(), 0.0)

    def test_is_long_audio_detection(self):
        """长语音检测应在超过阈值时触发。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        # 模拟正在录音，但时间很短
        mgr._is_running = True
        mgr._recording_start_time = time.time() - 5.0  # 5 秒前

        self.assertFalse(mgr.is_long_audio())

        # 模拟超过阈值
        mgr._recording_start_time = time.time() - 65.0  # 65 秒前
        self.assertTrue(mgr.is_long_audio())

    def test_configure_long_audio(self):
        """长语音配置应生效。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        mgr.configure_long_audio(threshold=30.0, max_duration=300.0)

        self.assertEqual(mgr._long_audio_threshold, 30.0)
        self.assertEqual(mgr._max_audio_duration, 300.0)

    def test_get_engine_for_duration_short(self):
        """短语音应使用主引擎。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", max_duration=600)
        mgr.register("primary", primary, primary=True)

        engine_name = mgr.get_engine_for_duration(30.0)
        self.assertEqual(engine_name, "primary")

    def test_get_engine_for_duration_long(self):
        """超长语音应回退到支持的引擎。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", max_duration=60)
        secondary = MockASREngine("secondary", max_duration=600)

        mgr.register("primary", primary, primary=True)
        mgr.register("secondary", secondary, fallback_order=1)

        # 120 秒超过 primary 的 60 秒限制
        engine_name = mgr.get_engine_for_duration(120.0)
        self.assertEqual(engine_name, "secondary")

    def test_get_engine_for_duration_no_support(self):
        """没有引擎支持时应返回 None。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        primary = MockASREngine("primary", max_duration=60)
        mgr.register("primary", primary, primary=True)

        engine_name = mgr.get_engine_for_duration(120.0)
        self.assertIsNone(engine_name)

    def test_stop_returns_text(self):
        """stop() 应返回识别文本。"""
        from spoken.asr.manager import ASRManager

        mgr = ASRManager()
        engine = MockASREngine("test")
        engine.stop_result = "hello world"
        mgr.register("test", engine, primary=True)

        self.assertTrue(mgr.load())
        self.assertTrue(mgr.start())

        result = mgr.stop()
        self.assertEqual(result, "hello world")


if __name__ == "__main__":
    import time
    unittest.main()
