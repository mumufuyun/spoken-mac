"""
spoken/audio/capture.py
麦克风录音模块。

功能：
- PyAudio 后端，16kHz / mono / 16bit PCM
- Toggle 模式：调用 start() 开始录音，stop() 停止并返回 WAV bytes
- 线程安全，支持从任意线程调用 start/stop
"""

from __future__ import annotations

import io
import logging
import threading
import time
import wave
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# 录音参数常量
SAMPLE_RATE = 16000    # 标准语音识别采样率（16kHz）
CHANNELS = 1           # 单声道
SAMPLE_WIDTH = 2       # 16bit = 2 bytes
CHUNK_SIZE = 1024      # 每次读取帧数
MAX_RECORDING_SECONDS = 300  # 最大录音时长（5 分钟），超时自动停止


class AudioCapture:
    """麦克风录音器，支持 toggle 开/停模式。

    使用示例::

        capture = AudioCapture()
        capture.start()          # 开始录音
        wav_bytes = capture.stop()  # 停止并获取 WAV 数据
    """

    def __init__(
        self,
        device_index: int = -1,
        sample_rate: int = SAMPLE_RATE,
        channels: int = CHANNELS,
        sample_width: int = SAMPLE_WIDTH,
        chunk_size: int = CHUNK_SIZE,
        on_data: Optional[Callable[[bytes], None]] = None,
    ) -> None:
        """初始化录音器。

        Args:
            device_index: 麦克风设备索引，-1 使用系统默认
            sample_rate: 采样率（Hz）
            channels: 声道数
            sample_width: 采样精度（字节数，2=16bit）
            chunk_size: 每次读取帧数
            on_data: 实时数据回调，每个 chunk 到来时触发（可选）
        """
        self._device_index = device_index if device_index >= 0 else None
        self._sample_rate = sample_rate
        self._channels = channels
        self._sample_width = sample_width
        self._chunk_size = chunk_size
        self._on_data = on_data

        self._pa = None          # PyAudio 实例
        self._stream = None      # 音频流
        self._frames: list[bytes] = []
        self._lock = threading.Lock()
        self._recording = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._start_time: float = 0.0  # 录音开始时间，用于超时保护

    def _ensure_pyaudio(self) -> None:
        """延迟初始化 PyAudio（避免在 import 时就要求安装）。"""
        if self._pa is None:
            try:
                import pyaudio
                self._pa = pyaudio.PyAudio()
                self._pyaudio = pyaudio  # 保存模块引用
            except ImportError as e:
                raise ImportError(
                    "PyAudio 未安装，请运行: pip install PyAudio"
                ) from e

    @property
    def is_recording(self) -> bool:
        """是否正在录音。"""
        return self._recording.is_set()

    def start(self) -> None:
        """开始录音。

        如果已在录音，则忽略此调用。

        Raises:
            RuntimeError: PyAudio 初始化失败或设备不可用
        """
        if self._recording.is_set():
            logger.warning("AudioCapture.start() 被调用时已在录音，忽略")
            return

        self._ensure_pyaudio()

        with self._lock:
            self._frames = []

        try:
            self._stream = self._pa.open(
                format=self._pa.get_format_from_width(self._sample_width),
                channels=self._channels,
                rate=self._sample_rate,
                input=True,
                input_device_index=self._device_index,
                frames_per_buffer=self._chunk_size,
            )
        except Exception as e:
            logger.error("打开音频流失败: %s", e)
            raise RuntimeError(f"无法打开麦克风: {e}") from e

        self._recording.set()
        self._start_time = time.time()
        self._thread = threading.Thread(target=self._record_loop, daemon=True)
        self._thread.start()
        logger.info(
            "开始录音（设备=%s, 采样率=%dHz, 声道=%d）",
            self._device_index or "默认",
            self._sample_rate,
            self._channels,
        )

    def stop(self) -> bytes:
        """停止录音并返回 WAV 格式的音频数据。

        Returns:
            WAV bytes，可直接传给 ASR 引擎或写入文件

        Raises:
            RuntimeError: 停止时发生错误
        """
        if not self._recording.is_set():
            logger.warning("AudioCapture.stop() 被调用时未在录音，返回空数据")
            return self._encode_wav(b"")

        # 通知录音线程停止
        self._recording.clear()

        # 等待录音线程结束（最多等待 2 秒）
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)
            if self._thread.is_alive():
                logger.warning("录音线程未在预期时间内结束")

        # 关闭音频流
        if self._stream:
            try:
                self._stream.stop_stream()
                self._stream.close()
            except Exception as e:
                logger.error("关闭音频流失败: %s", e)
            finally:
                self._stream = None

        with self._lock:
            raw_data = b"".join(self._frames)
            self._frames = []

        logger.info("录音停止，共采集 %.2f 秒音频", len(raw_data) / (self._sample_rate * self._channels * self._sample_width))
        return self._encode_wav(raw_data)

    def _record_loop(self) -> None:
        """录音循环（在独立线程中运行）。"""
        logger.debug("录音线程启动")
        while self._recording.is_set():
            # 超时保护：超过最大时长自动停止
            if time.time() - self._start_time > MAX_RECORDING_SECONDS:
                logger.warning(
                    "录音超过 %d 秒，自动停止",
                    MAX_RECORDING_SECONDS,
                )
                break

            try:
                chunk = self._stream.read(self._chunk_size, exception_on_overflow=False)
                with self._lock:
                    self._frames.append(chunk)
                # 触发实时数据回调
                if self._on_data:
                    try:
                        self._on_data(chunk)
                    except Exception as e:
                        logger.error("on_data 回调异常: %s", e)
            except Exception as e:
                if self._recording.is_set():
                    logger.error("读取音频数据失败: %s", e)
                break
        logger.debug("录音线程结束")

    def _encode_wav(self, raw_pcm: bytes) -> bytes:
        """将原始 PCM 数据封装为 WAV 格式。

        Args:
            raw_pcm: 原始 PCM 数据

        Returns:
            WAV bytes
        """
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(self._channels)
            wf.setsampwidth(self._sample_width)
            wf.setframerate(self._sample_rate)
            wf.writeframes(raw_pcm)
        return buf.getvalue()

    def toggle(self) -> Optional[bytes]:
        """切换录音状态（toggle 模式）。

        - 未录音时：开始录音，返回 None
        - 录音中时：停止录音，返回 WAV bytes

        Returns:
            None（开始录音）或 WAV bytes（停止录音）
        """
        if self._recording.is_set():
            return self.stop()
        else:
            self.start()
            return None

    def cleanup(self) -> None:
        """释放所有资源（程序退出时调用）。"""
        if self._recording.is_set():
            self.stop()
        if self._pa:
            try:
                self._pa.terminate()
            except Exception as e:
                logger.error("PyAudio terminate 失败: %s", e)
            finally:
                self._pa = None
        logger.debug("AudioCapture 资源已释放")

    def __del__(self) -> None:
        """析构时自动清理资源。"""
        try:
            self.cleanup()
        except Exception:
            pass  # 析构时不应抛出异常
