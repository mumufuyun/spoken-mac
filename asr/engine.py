"""
spoken/asr/engine.py
ASR 引擎抽象基类。

定义统一接口，具体实现在各子类中（如 WindowsSpeechEngine、XunfeiRealtimeEngine）。
"""

from __future__ import annotations

import io
import logging
from abc import ABC, abstractmethod
from typing import Optional

logger = logging.getLogger(__name__)


class ASREngine(ABC):
    """ASR 引擎抽象基类。

    所有 ASR 实现都必须继承此类并实现 transcribe() 方法。

    生命周期::

        engine = SomeASREngine(config)
        engine.load()           # 加载模型（可能耗时）
        text = engine.transcribe(wav_bytes)
        engine.unload()         # 释放资源
    """

    def __init__(self) -> None:
        self._loaded = False

    @property
    def is_loaded(self) -> bool:
        """模型是否已加载。"""
        return self._loaded

    @abstractmethod
    def load(self) -> None:
        """加载 ASR 模型（阻塞调用，可能耗时数秒）。

        Raises:
            RuntimeError: 模型加载失败
        """
        ...

    @abstractmethod
    def unload(self) -> None:
        """释放模型资源，释放内存/显存。"""
        ...

    @abstractmethod
    def transcribe(self, audio_bytes: bytes, language: Optional[str] = None) -> str:
        """将音频数据转录为文字。

        Args:
            audio_bytes: WAV 格式的音频数据（16kHz / mono / 16bit）
            language: 强制指定语言代码（如 "zh" / "en"），None 则自动检测

        Returns:
            识别到的文字，去除首尾空白；识别失败或无声音返回空字符串

        Raises:
            RuntimeError: 引擎未加载（未调用 load()）
            ValueError: audio_bytes 格式不合法
        """
        ...

    def ensure_loaded(self) -> None:
        """确保模型已加载，否则抛出 RuntimeError。"""
        if not self._loaded:
            raise RuntimeError(
                f"{type(self).__name__} 尚未加载，请先调用 load()"
            )

    def transcribe_file(self, wav_path: str, language: Optional[str] = None) -> str:
        """从文件路径读取音频并转录。

        Args:
            wav_path: WAV 文件路径
            language: 语言代码（可选）

        Returns:
            识别到的文字
        """
        with open(wav_path, "rb") as f:
            audio_bytes = f.read()
        return self.transcribe(audio_bytes, language=language)

    def __enter__(self) -> "ASREngine":
        """支持 with 语句，自动 load。"""
        self.load()
        return self

    def __exit__(self, *args: object) -> None:
        """支持 with 语句，自动 unload。"""
        self.unload()

    def __repr__(self) -> str:
        status = "已加载" if self._loaded else "未加载"
        return f"{type(self).__name__}({status})"
