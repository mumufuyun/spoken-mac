from __future__ import annotations

import asyncio
import datetime as dt
import logging
import re
import sys
import threading
import time
from typing import Callable, Optional

from .engine import ASREngine

logger = logging.getLogger(__name__)


def _normalize_language_tag(language: str) -> Optional[str]:
    value = (language or "").strip()
    if not value or value.lower() == "auto":
        return None

    mapping = {
        # zh 不指定语言标签，使用 Windows 默认识别器以支持中英混合识别
        # Windows 11 默认识别器天然支持中文+英文混合输入
        "zh": None,
        "en": "en-US",
    }
    result = mapping.get(value.lower(), value)
    # 如果映射结果为 None，说明该语言推荐使用默认识别器
    return result


def _should_compact_join(language_tag: Optional[str], raw_language: str = "") -> bool:
    if not language_tag:
        # 当 language_tag 为 None 时（zh 或 auto），检查 raw_language
        if raw_language and raw_language.lower() in ("zh", "auto", ""):
            return True
        return False
    tag = language_tag.lower()
    return tag.startswith(("zh", "ja", "ko"))


def _clean_fragment(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip())


class WindowsSpeechEngine(ASREngine):
    """Realtime ASR powered by Windows.Media.SpeechRecognition.

    性能优化策略（v2 — 常驻 worker + 预编译）：
    - load() 阶段：预检 + 启动常驻 worker 线程
    - 常驻 worker 线程：在 STA Apartment 中预创建 recognizer + compile
    - start() 时：直接 await session.start_async()，跳过创建/编译延迟
    - stop() 时：只 stop session，保留 recognizer 和 worker 线程
    - 首次启动延迟从 2-4s 降至 ~100ms

    线程安全：
    - recognizer 在 worker 线程中创建和使用，满足 WinRT STA 亲和性
    - 通过 Event 同步 start/stop 指令
    - worker 线程常驻，避免反复创建销毁的开销
    """

    def __init__(
        self,
        language: str = "zh",
        initial_silence_timeout_sec: float = 5.0,
        end_silence_timeout_sec: float = 0.8,
        auto_stop_silence_sec: float = 60.0,
        on_partial_text: Optional[Callable[[str], None]] = None,
        on_final_text: Optional[Callable[[str], None]] = None,
    ) -> None:
        super().__init__()
        self._raw_language = language
        self._language_tag = _normalize_language_tag(language)
        self._joiner = "" if _should_compact_join(self._language_tag, raw_language=self._raw_language) else " "
        self.max_duration = 600  # Windows 无硬上限，按长语音默认值
        self._initial_silence_timeout_sec = max(0.1, float(initial_silence_timeout_sec))
        self._end_silence_timeout_sec = max(0.1, float(end_silence_timeout_sec))
        self._auto_stop_silence_sec = max(5.0, float(auto_stop_silence_sec))
        self._on_partial_text = on_partial_text
        self._on_final_text = on_final_text

        self._worker_thread: Optional[threading.Thread] = None
        self._worker_loop: Optional[asyncio.AbstractEventLoop] = None

        # 常驻 worker 控制
        self._worker_alive = threading.Event()     # worker 线程已启动并就绪
        self._cmd_start = threading.Event()         # 通知 worker 开始识别
        self._cmd_stop = threading.Event()          # 通知 worker 停止识别
        self._start_event = threading.Event()       # 识别已开始（对外通知）
        self._result_event = threading.Event()      # 结果已就绪
        self._session_completed = threading.Event()
        self._is_listening = threading.Event()
        self._shutdown_worker = threading.Event()   # 通知 worker 线程退出

        self._state_lock = threading.Lock()
        self._segments: list[str] = []
        self._partial_text = ""
        self._final_text = ""
        self._start_error: Optional[str] = None

        self._recognizer = None
        self._session = None
        self._token_completed = None
        self._token_result_generated = None
        self._token_hypothesis = None
        self._token_quality = None
        self._token_state_changed = None

        # 预编译的 recognizer 缓存（在 worker 线程中创建，可安全复用）
        self._prebuilt_recognizer = None
        self._recognizer_ready = threading.Event()

    @classmethod
    def from_config(
        cls,
        config: dict,
        on_partial_text: Optional[Callable[[str], None]] = None,
        on_final_text: Optional[Callable[[str], None]] = None,
    ) -> "WindowsSpeechEngine":
        windows_cfg = config.get("windows", {})
        language = str(windows_cfg.get("language_tag", "") or config.get("language", "zh"))
        return cls(
            language=language,
            initial_silence_timeout_sec=float(
                windows_cfg.get("initial_silence_timeout_sec", 5.0) or 5.0
            ),
            end_silence_timeout_sec=float(
                windows_cfg.get("end_silence_timeout_sec", 0.8) or 0.8
            ),
            auto_stop_silence_sec=float(
                windows_cfg.get("auto_stop_silence_sec", 60.0) or 60.0
            ),
            on_partial_text=on_partial_text,
            on_final_text=on_final_text,
        )

    def load(self) -> None:
        if self._loaded:
            return
        if sys.platform != "win32":
            raise RuntimeError("Windows 原生语音识别仅支持在 Windows 上运行")

        try:
            import winsdk.windows.globalization  # noqa: F401
            import winsdk.windows.media.speechrecognition  # noqa: F401
        except ImportError as exc:
            raise RuntimeError(
                "缺少 winsdk 依赖，请先执行: python -m pip install winsdk"
            ) from exc

        try:
            self._preflight_recognizer()
        except OSError as exc:
            win_error = getattr(exc, "winerror", None) or getattr(exc, "args", [None])[0]
            if win_error == -2147199735 or "0x80045509" in str(exc):
                raise RuntimeError(
                    "Windows 在线语音识别策略未同意（错误 0x80045509）。\n"
                    "请按以下步骤操作：\n"
                    "  1. 打开 Windows 设置 → 隐私和安全性 → 语音\n"
                    "  2. 开启「在线语音识别」开关\n"
                    "  3. 重启 Spoken\n"
                    "或者将 config.toml 中 [asr] realtime_provider 改为 \"xunfei\" 使用讯飞引擎。"
                ) from exc
            raise RuntimeError(f"Windows 语音识别预检失败: {exc}") from exc
        except Exception as exc:
            logger.warning("Windows 语音识别预检失败（将继续尝试）: %s", exc)

        self._loaded = True
        logger.info("WindowsSpeechEngine 加载完成（预检通过）")

        # 启动常驻 worker 线程：预创建 recognizer + compile，后续 start() 秒起
        self._start_persistent_worker()

    def _create_recognizer(self):
        import winsdk.windows.globalization as globalization
        from winsdk.windows.media.speechrecognition import (
            SpeechRecognitionScenario,
            SpeechRecognitionTopicConstraint,
            SpeechRecognizer,
        )

        recognizer = (
            SpeechRecognizer(globalization.Language(self._language_tag))
            if self._language_tag
            else SpeechRecognizer()
        )

        if recognizer.constraints is not None:
            recognizer.constraints.append(
                SpeechRecognitionTopicConstraint(
                    SpeechRecognitionScenario.DICTATION,
                    "dictation",
                )
            )

        return recognizer

    def _preflight_recognizer(self) -> None:
        """仅做预检，不缓存 recognizer 对象。"""
        from winsdk.windows.media.speechrecognition import SpeechRecognitionResultStatus

        recognizer = self._create_recognizer()
        loop = asyncio.new_event_loop()
        try:
            compile_result = loop.run_until_complete(recognizer.compile_constraints_async())
        finally:
            loop.close()

        compile_status = getattr(compile_result, "status", SpeechRecognitionResultStatus.UNKNOWN)
        try:
            recognizer.close()
        except Exception:
            pass

        if compile_status != SpeechRecognitionResultStatus.SUCCESS:
            status_name = getattr(compile_status, "name", str(compile_status))
            raise RuntimeError(f"Windows 语音识别约束编译失败: {status_name}")

        logger.info("Windows 识别器预检完成")

    def unload(self) -> None:
        if self._is_listening.is_set():
            try:
                self.stop()
            except Exception as exc:
                logger.warning("停止 Windows 原生语音识别失败: %s", exc)

        # 通知常驻 worker 退出
        self._shutdown_worker.set()
        self._cmd_stop.set()
        if self._worker_thread and self._worker_thread.is_alive():
            self._worker_thread.join(timeout=3.0)

        self._loaded = False
        logger.info("WindowsSpeechEngine 已释放")

    # ══════════════════════════════════════════════════════════════════
    # start / stop — 核心接口
    # ══════════════════════════════════════════════════════════════════

    def start(self) -> None:
        self.ensure_loaded()

        with self._state_lock:
            self._segments.clear()
            self._partial_text = ""
            self._final_text = ""

        self._start_event.clear()
        self._result_event.clear()
        self._session_completed.clear()
        self._is_listening.clear()
        self._start_error = None
        self._cmd_stop.clear()
        self._cmd_start.clear()

        # 确保 worker 线程存活
        if not self._worker_alive.is_set():
            self._start_persistent_worker()

        # 等待 recognizer 预编译完成（最多等 5s，超时则直接失败，由上层降级到讯飞）
        if not self._recognizer_ready.wait(timeout=5.0):
            # 预编译超时 → 不再降级到 legacy（legacy 几乎必败），让上层切换引擎
            logger.warning("recognizer 预编译超时，建议切换到讯飞引擎")
            raise RuntimeError(
                "Windows 语音识别预编译超时。"
                "请将 config.toml 中 [asr] realtime_provider 改为 \"xunfei\" 使用讯飞引擎。"
            )

        # 确认预编译 recognizer 仍然有效
        if not self._prebuilt_recognizer:
            logger.warning("_recognizer_ready 已 set 但 _prebuilt_recognizer 为 None")
            self._recognizer_ready.clear()
            raise RuntimeError("Windows 语音识别预编译状态异常，请重试或切换到讯飞引擎")

        # 通知 worker 开始识别
        logger.debug(
            "start() 发送指令: worker_alive=%s, recognizer_ready=%s, "
            "cmd_start=%s, cmd_stop=%s, is_listening=%s",
            self._worker_alive.is_set(),
            self._recognizer_ready.is_set(),
            self._cmd_start.is_set(),
            self._cmd_stop.is_set(),
            self._is_listening.is_set(),
        )
        self._cmd_start.set()

        if not self._start_event.wait(timeout=5.0):
            self._cmd_stop.set()
            raise RuntimeError(
                "Windows 语音识别启动超时。"
                "请将 config.toml 中 [asr] realtime_provider 改为 \"xunfei\" 使用讯飞引擎。"
            )

        if self._start_error:
            raise RuntimeError(self._start_error)

    def stop(self) -> str:
        with self._state_lock:
            existing = (self._final_text or self._partial_text).strip()

        # 短暂等待 start() 完成（处理快速按下松开的场景）
        if not self._is_listening.is_set() and self._cmd_start.is_set():
            self._start_event.wait(timeout=3.0)

        if not self._is_listening.is_set() and not self._cmd_start.is_set():
            if existing:
                logger.info("stop() 时未在监听，返回已有结果: %s", existing[:40])
                return existing
            return existing or ""

        # 通知 worker 停止识别（幂等：已经 set 过则不再重复 set）
        if not self._cmd_stop.is_set():
            self._cmd_stop.set()
            logger.debug("stop() 已发送停止信号")
        else:
            logger.debug("stop() 停止信号已存在，直接等待结果")

        # 等待结果就绪
        got_result = self._result_event.wait(timeout=5.0)
        if not got_result:
            logger.warning("stop() 等待结果超时（5s），强制清理监听状态")
            # 超时兜底：强制清除监听状态，避免下次 start() 时状态异常
            self._is_listening.clear()
            # 确保其他等待者也能被唤醒
            self._result_event.set()

        with self._state_lock:
            result = (self._final_text or self._partial_text).strip()

        return result

    @property
    def is_recording(self) -> bool:
        return self._is_listening.is_set()

    def get_recorded_audio(self) -> bytes:
        return b""

    def get_recorded_duration_sec(self) -> float:
        return 0.0

    def transcribe(self, audio_bytes: bytes, language: Optional[str] = None) -> str:
        raise RuntimeError(
            "Windows 原生语音识别当前仅支持实时麦克风听写，不支持离线音频转录"
        )

    # ══════════════════════════════════════════════════════════════════
    # 常驻 worker 线程（v2 核心）
    # ══════════════════════════════════════════════════════════════════

    def _start_persistent_worker(self) -> None:
        """启动常驻 worker 线程，预编译 recognizer，为后续 start() 加速。"""
        if self._worker_thread and self._worker_thread.is_alive() and self._worker_alive.is_set():
            return

        self._shutdown_worker.clear()
        self._worker_alive.clear()
        self._recognizer_ready.clear()
        self._cmd_start.clear()
        self._cmd_stop.clear()

        self._worker_thread = threading.Thread(
            target=self._persistent_worker_main,
            name="windows-speech-worker",
            daemon=True,
        )
        self._worker_thread.start()
        logger.info("常驻 worker 线程已启动，等待 recognizer 预编译...")

    def _persistent_worker_main(self) -> None:
        """常驻 worker 主循环：预编译 recognizer，等待 start/stop 指令。"""
        pythoncom_mod = None
        loop: Optional[asyncio.AbstractEventLoop] = None

        try:
            try:
                import pythoncom as _pythoncom  # type: ignore[import-not-found]
                pythoncom_mod = _pythoncom
                _pythoncom.CoInitialize()
            except Exception:
                pythoncom_mod = None

            loop = asyncio.new_event_loop()
            self._worker_loop = loop
            asyncio.set_event_loop(loop)

            # 预编译 recognizer（耗时操作，只做一次）
            t0 = time.monotonic()
            self._prebuilt_recognizer = loop.run_until_complete(self._prebuild_recognizer())
            elapsed = time.monotonic() - t0
            if self._prebuilt_recognizer:
                self._recognizer_ready.set()
                logger.info("recognizer 预编译完成（%.1fs），后续 start() 将秒起", elapsed)
            else:
                logger.warning("recognizer 预编译失败，将使用传统 start()")

            self._worker_alive.set()

            # 主循环：等待 start/stop/shutdown 指令
            while not self._shutdown_worker.is_set():
                # 等待 start 指令
                while not self._cmd_start.is_set() and not self._shutdown_worker.is_set():
                    self._cmd_start.wait(timeout=0.1)

                if self._shutdown_worker.is_set():
                    break

                # 执行识别会话
                try:
                    loop.run_until_complete(self._run_session_fast())
                except Exception as exc:
                    logger.error("识别会话异常: %s", exc, exc_info=True)
                    if not self._start_event.is_set():
                        self._start_error = str(exc)
                        self._start_event.set()
                    self._result_event.set()

                logger.debug(
                    "worker 会话结束，清理事件: cmd_start=%s, cmd_stop=%s, "
                    "result_event=%s, start_event=%s",
                    self._cmd_start.is_set(),
                    self._cmd_stop.is_set(),
                    self._result_event.is_set(),
                    self._start_event.is_set(),
                )
                self._cmd_start.clear()
                self._cmd_stop.clear()

        except Exception as exc:
            logger.error("常驻 worker 线程异常: %s", exc, exc_info=True)
            if not self._start_event.is_set():
                self._start_error = str(exc)
                self._start_event.set()
            self._result_event.set()
        finally:
            # 清理预编译的 recognizer
            if self._prebuilt_recognizer:
                try:
                    self._prebuilt_recognizer.close()
                except Exception:
                    pass
                self._prebuilt_recognizer = None
            if loop is not None:
                try:
                    loop.close()
                except Exception:
                    pass
            self._worker_loop = None
            self._worker_thread = None
            self._recognizer = None
            self._session = None
            self._is_listening.clear()
            self._session_completed.set()
            self._result_event.set()
            self._worker_alive.clear()
            self._recognizer_ready.clear()
            if pythoncom_mod is not None:
                try:
                    pythoncom_mod.CoUninitialize()
                except Exception:
                    pass

    async def _prebuild_recognizer(self):
        """在 worker 线程中预创建并编译 recognizer，供后续 start() 复用。"""
        try:
            from winsdk.windows.media.speechrecognition import SpeechRecognitionResultStatus

            recognizer = self._create_recognizer()
            compile_result = await recognizer.compile_constraints_async()

            compile_status = getattr(compile_result, "status", SpeechRecognitionResultStatus.UNKNOWN)
            if compile_status != SpeechRecognitionResultStatus.SUCCESS:
                status_name = getattr(compile_status, "name", str(compile_status))
                logger.error("recognizer 预编译失败: %s", status_name)
                try:
                    recognizer.close()
                except Exception:
                    pass
                return None

            logger.info("recognizer 预编译成功")
            return recognizer
        except Exception as e:
            logger.error("recognizer 预编译异常: %s", e)
            return None

    async def _run_session_fast(self) -> None:
        """快速识别会话：直接使用预编译的 recognizer，跳过创建+编译延迟。"""
        from winsdk.windows.media.speechrecognition import (
            SpeechContinuousRecognitionMode,
            SpeechRecognitionResultStatus,
        )

        # 标记 recognizer 不再就绪（正在使用中）
        self._recognizer_ready.clear()

        recognizer = self._prebuilt_recognizer
        if not recognizer:
            # 降级：重新创建+编译（可能耗时数秒）
            logger.info("预编译 recognizer 不可用，重新创建中...")
            recognizer = self._create_recognizer()
            compile_result = await recognizer.compile_constraints_async()
            compile_status = getattr(compile_result, "status", SpeechRecognitionResultStatus.UNKNOWN)
            if compile_status != SpeechRecognitionResultStatus.SUCCESS:
                status_name = getattr(compile_status, "name", str(compile_status))
                raise RuntimeError(f"Windows 语音识别初始化失败: {status_name}")

        # 消费预编译的 recognizer，防止下次 start() 复用同一对象
        self._prebuilt_recognizer = None
        self._recognizer = recognizer

        try:
            if recognizer.timeouts is not None:
                recognizer.timeouts.initial_silence_timeout = dt.timedelta(
                    seconds=self._initial_silence_timeout_sec
                )
                recognizer.timeouts.end_silence_timeout = dt.timedelta(
                    seconds=self._end_silence_timeout_sec
                )

            session = recognizer.continuous_recognition_session
            if session is None:
                raise RuntimeError("Windows 连续识别会话创建失败")
            self._session = session

            try:
                session.auto_stop_silence_timeout = dt.timedelta(
                    seconds=self._auto_stop_silence_sec
                )
            except Exception as exc:
                logger.debug("设置 auto_stop_silence_timeout 失败: %s", exc)

            self._register_handlers()
            t0 = time.monotonic()
            await session.start_async(SpeechContinuousRecognitionMode.DEFAULT)
            elapsed = time.monotonic() - t0
            self._is_listening.set()

            if not self._start_event.is_set():
                self._start_event.set()
                logger.info("Windows 原生语音识别已开始监听（快速模式, session.start: %.0fms）", elapsed * 1000)

            # 等待 stop 指令或会话结束
            while not self._cmd_stop.is_set() and not self._session_completed.is_set():
                await asyncio.sleep(0.02)

            if self._cmd_stop.is_set():
                try:
                    await session.stop_async()
                except Exception as exc:
                    logger.debug("停止 Windows 连续识别会话时出现异常: %s", exc)

                for _ in range(20):
                    if self._session_completed.is_set():
                        break
                    await asyncio.sleep(0.02)

        except Exception as exc:
            if not self._start_event.is_set():
                raise
            logger.warning("识别会话异常: %s", exc)
        finally:
            self._unregister_handlers()
            self._recognizer = None
            self._session = None
            self._is_listening.clear()
            self._session_completed.clear()

            with self._state_lock:
                if not self._final_text:
                    self._final_text = self._partial_text
            self._result_event.set()

            # 关闭当前 recognizer（会话结束后不可复用）
            try:
                recognizer.close()
            except Exception:
                pass

            # 后台重新预编译 recognizer，为下次 start() 做准备
            try:
                new_recognizer = self._create_recognizer()
                compile_result = await new_recognizer.compile_constraints_async()
                compile_status = getattr(compile_result, "status", SpeechRecognitionResultStatus.UNKNOWN)
                if compile_status != SpeechRecognitionResultStatus.SUCCESS:
                    status_name = getattr(compile_status, "name", str(compile_status))
                    logger.warning("会话结束后重新预编译失败: %s", status_name)
                    try:
                        new_recognizer.close()
                    except Exception:
                        pass
                    # 预编译失败，_recognizer_ready 保持 clear，下次 start() 会走降级路径
                else:
                    self._prebuilt_recognizer = new_recognizer
                    self._recognizer_ready.set()
                    logger.info("会话结束后 recognizer 重新预编译完成，下次 start() 可用")
            except Exception as e:
                logger.warning("重新预编译异常: %s", e)
                # 预编译失败，_recognizer_ready 保持 clear

    # ══════════════════════════════════════════════════════════════════
    # 降级：传统 start（预编译失败时使用）
    # ══════════════════════════════════════════════════════════════════

    def _fallback_start(self) -> None:
        """降级启动：使用传统方式（每次创建新 recognizer）。"""
        if self._worker_thread and self._worker_thread.is_alive():
            self._shutdown_worker.set()
            self._worker_thread.join(timeout=3.0)

        self._shutdown_worker.clear()
        self._cmd_start.clear()
        self._cmd_stop.clear()

        self._worker_thread = threading.Thread(
            target=self._worker_main_legacy,
            name="windows-speech-legacy",
            daemon=True,
        )
        self._worker_thread.start()

        if not self._start_event.wait(timeout=8.0):
            self._cmd_stop.set()
            raise RuntimeError("Windows 原生语音识别启动超时")

        if self._start_error:
            raise RuntimeError(self._start_error)

    def _worker_main_legacy(self) -> None:
        """传统 worker（降级使用）。"""
        pythoncom_mod = None
        loop: Optional[asyncio.AbstractEventLoop] = None
        try:
            try:
                import pythoncom as _pythoncom  # type: ignore[import-not-found]
                pythoncom_mod = _pythoncom
                _pythoncom.CoInitialize()
            except Exception:
                pythoncom_mod = None

            loop = asyncio.new_event_loop()
            self._worker_loop = loop
            asyncio.set_event_loop(loop)
            loop.run_until_complete(self._run_session_legacy())
        except Exception as exc:
            logger.error("Windows 原生语音识别线程异常: %s", exc, exc_info=True)
            if not self._start_event.is_set():
                self._start_error = str(exc)
                self._start_event.set()
            self._result_event.set()
        finally:
            if loop is not None:
                try:
                    loop.close()
                except Exception:
                    pass
            self._worker_loop = None
            self._worker_thread = None
            self._recognizer = None
            self._session = None
            self._is_listening.clear()
            self._session_completed.set()
            self._result_event.set()
            if pythoncom_mod is not None:
                try:
                    pythoncom_mod.CoUninitialize()
                except Exception:
                    pass

    async def _run_session_legacy(self) -> None:
        """传统识别会话（降级使用，每次创建新 recognizer）。"""
        from winsdk.windows.media.speechrecognition import (
            SpeechContinuousRecognitionMode,
            SpeechRecognitionResultStatus,
        )

        recognizer = self._create_recognizer()
        self._recognizer = recognizer
        self._session_completed.clear()

        try:
            compile_result = await recognizer.compile_constraints_async()
            compile_status = getattr(compile_result, "status", SpeechRecognitionResultStatus.UNKNOWN)
            if compile_status != SpeechRecognitionResultStatus.SUCCESS:
                status_name = getattr(compile_status, "name", str(compile_status))
                raise RuntimeError(f"Windows 语音识别初始化失败: {status_name}")

            if recognizer.timeouts is not None:
                recognizer.timeouts.initial_silence_timeout = dt.timedelta(
                    seconds=self._initial_silence_timeout_sec
                )
                recognizer.timeouts.end_silence_timeout = dt.timedelta(
                    seconds=self._end_silence_timeout_sec
                )

            session = recognizer.continuous_recognition_session
            if session is None:
                raise RuntimeError("Windows 连续识别会话创建失败")
            self._session = session

            try:
                session.auto_stop_silence_timeout = dt.timedelta(
                    seconds=self._auto_stop_silence_sec
                )
            except Exception as exc:
                logger.debug("设置 auto_stop_silence_timeout 失败: %s", exc)

            self._register_handlers()
            await session.start_async(SpeechContinuousRecognitionMode.DEFAULT)
            self._is_listening.set()

            if not self._start_event.is_set():
                self._start_event.set()
                logger.info("Windows 原生语音识别已开始监听（传统模式）")

            while not self._cmd_stop.is_set() and not self._session_completed.is_set():
                await asyncio.sleep(0.03)

            if self._cmd_stop.is_set():
                try:
                    await session.stop_async()
                except Exception as exc:
                    logger.debug("停止 Windows 连续识别会话时出现异常: %s", exc)

                for _ in range(20):
                    if self._session_completed.is_set():
                        break
                    await asyncio.sleep(0.03)

        except Exception as exc:
            if not self._start_event.is_set():
                raise
            logger.warning("Windows 识别会话异常: %s", exc)
        finally:
            self._unregister_handlers()
            self._recognizer = None
            self._session = None
            self._is_listening.clear()
            self._session_completed.set()
            try:
                recognizer.close()
            except Exception:
                pass

        with self._state_lock:
            if not self._final_text:
                self._final_text = self._partial_text
        self._result_event.set()

    # ══════════════════════════════════════════════════════════════════
    # 事件处理器
    # ══════════════════════════════════════════════════════════════════

    def _register_handlers(self) -> None:
        if self._recognizer is None or self._session is None:
            return

        self._token_completed = self._session.add_completed(self._on_completed)
        self._token_result_generated = self._session.add_result_generated(self._on_result_generated)
        self._token_hypothesis = self._recognizer.add_hypothesis_generated(
            self._on_hypothesis_generated
        )
        self._token_quality = self._recognizer.add_recognition_quality_degrading(
            self._on_quality_degrading
        )
        self._token_state_changed = self._recognizer.add_state_changed(self._on_state_changed)

    def _unregister_handlers(self) -> None:
        session = self._session
        recognizer = self._recognizer

        if session is not None and self._token_completed is not None:
            try:
                session.remove_completed(self._token_completed)
            except Exception:
                pass
        if session is not None and self._token_result_generated is not None:
            try:
                session.remove_result_generated(self._token_result_generated)
            except Exception:
                pass
        if recognizer is not None and self._token_hypothesis is not None:
            try:
                recognizer.remove_hypothesis_generated(self._token_hypothesis)
            except Exception:
                pass
        if recognizer is not None and self._token_quality is not None:
            try:
                recognizer.remove_recognition_quality_degrading(self._token_quality)
            except Exception:
                pass
        if recognizer is not None and self._token_state_changed is not None:
            try:
                recognizer.remove_state_changed(self._token_state_changed)
            except Exception:
                pass

        self._token_completed = None
        self._token_result_generated = None
        self._token_hypothesis = None
        self._token_quality = None
        self._token_state_changed = None

    def _compose_text(self, transient: str = "") -> str:
        parts = [segment for segment in self._segments if segment]
        if transient:
            parts.append(transient)

        if not parts:
            return ""

        text = self._joiner.join(parts) if self._joiner else "".join(parts)
        text = re.sub(r"\s+([,.;:!?])", r"\1", text)
        return text.strip()

    def _on_hypothesis_generated(self, sender, args) -> None:
        hypothesis = getattr(args, "hypothesis", None)
        raw_text = getattr(hypothesis, "text", "") or ""
        text = _clean_fragment(raw_text)
        logger.debug("Windows hypothesis 回调: raw=%r, clean=%r", raw_text, text)
        if not text:
            return

        with self._state_lock:
            composed = self._compose_text(text)
            self._partial_text = composed

        if self._on_partial_text and composed:
            try:
                self._on_partial_text(composed)
            except Exception:
                pass

    def _on_result_generated(self, sender, args) -> None:
        result = getattr(args, "result", None)
        if result is None:
            logger.debug("Windows result_generated 回调: result=None")
            return

        raw_text = getattr(result, "text", "") or ""
        text = _clean_fragment(raw_text)
        status = getattr(result, "status", None)
        status_name = getattr(status, "name", str(status))
        logger.debug(
            "Windows result_generated 回调: raw=%r, clean=%r, status=%s",
            raw_text,
            text,
            status_name,
        )
        if status_name and status_name != "SUCCESS":
            logger.debug("Windows 识别结果状态非 SUCCESS: %s", status_name)

        if not text:
            return

        with self._state_lock:
            if not self._segments or self._segments[-1] != text:
                self._segments.append(text)
            composed = self._compose_text()
            self._partial_text = composed
            self._final_text = composed

        if self._on_final_text and composed:
            try:
                self._on_final_text(composed)
            except Exception:
                pass

    def _on_completed(self, sender, args) -> None:
        status = getattr(args, "status", None)
        status_name = getattr(status, "name", str(status))
        with self._state_lock:
            seg_count = len(self._segments)
            partial_len = len(self._partial_text)
            final_len = len(self._final_text)
        logger.info(
            "Windows 连续识别会话结束: %s (segments=%d, partial=%d, final=%d)",
            status_name,
            seg_count,
            partial_len,
            final_len,
        )
        self._session_completed.set()

    def _on_quality_degrading(self, sender, args) -> None:
        problem = getattr(args, "problem", None)
        problem_name = getattr(problem, "name", str(problem))
        logger.warning("Windows 识别音频质量下降: %s", problem_name)

    def _on_state_changed(self, sender, args) -> None:
        state = getattr(args, "state", None)
        state_name = getattr(state, "name", str(state))
        logger.debug("Windows 识别状态变更: %s", state_name)

    def __repr__(self) -> str:
        status = "监听中" if self._is_listening.is_set() else ("已加载" if self._loaded else "未加载")
        return f"WindowsSpeechEngine(language={self._language_tag or 'system'}, {status})"
