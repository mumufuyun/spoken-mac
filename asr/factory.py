"""
spoken/asr/factory.py
ASR 引擎工厂 — 统一创建和初始化 ASR 引擎实例。

消除 __main__.py 中 _setup_asr() 与 _try_fallback_to_xunfei() 的重复代码。
"""

from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

from .engine import ASREngine

logger = logging.getLogger(__name__)


def load_windows_engine(
    asr_cfg: dict,
    *,
    on_partial_text: Optional[Callable[[str], None]] = None,
    on_final_text: Optional[Callable[[str], None]] = None,
) -> Optional[ASREngine]:
    """创建并加载 Windows 原生语音识别引擎。

    Returns:
        加载成功的引擎实例，失败时返回 None
    """
    try:
        from .windows_speech import WindowsSpeechEngine

        engine = WindowsSpeechEngine.from_config(
            asr_cfg,
            on_partial_text=on_partial_text,
            on_final_text=on_final_text,
        )
        engine.load()
        logger.info("[OK] Windows 原生语音识别引擎已加载")
        return engine
    except Exception as e:
        logger.warning("Windows 原生语音识别不可用: %s", e)
        return None


def load_xunfei_engine(
    asr_cfg: dict,
    *,
    on_partial_text: Optional[Callable[[str], None]] = None,
    on_final_text: Optional[Callable[[str], None]] = None,
    preconnect: bool = True,
) -> Optional[ASREngine]:
    """创建并加载讯飞实时转写引擎。

    Args:
        asr_cfg: ASR 配置字典
        on_partial_text: 流式 partial 回调
        on_final_text: 流式 final 回调
        preconnect: 是否在后台预热 DNS

    Returns:
        加载成功的引擎实例，失败时返回 None
    """
    try:
        from .xunfei_realtime import XunfeiRealtimeEngine

        engine = XunfeiRealtimeEngine.from_config(
            asr_cfg,
            on_partial_text=on_partial_text,
            on_final_text=on_final_text,
        )
        engine.load()
        logger.info("[OK] 讯飞实时转写引擎已加载")

        if preconnect:
            _preconnect_xunfei(engine)

        return engine
    except Exception as e:
        logger.warning("讯飞实时转写不可用: %s", e)
        return None


def _preconnect_xunfei(engine: ASREngine) -> None:
    """后台预热讯飞引擎的 DNS，加速首次 WebSocket 建连。"""
    preconnect_fn = getattr(engine, "preconnect", None)
    if callable(preconnect_fn):
        threading.Thread(
            target=preconnect_fn,
            daemon=True,
            name="xunfei-preconnect",
        ).start()
        logger.debug("讯飞引擎 DNS 预热已启动")


def create_engine_by_provider(
    provider: str,
    asr_cfg: dict,
    *,
    on_partial_text: Optional[Callable[[str], None]] = None,
    on_final_text: Optional[Callable[[str], None]] = None,
) -> Optional[ASREngine]:
    """根据 provider 名称创建对应引擎。

    Args:
        provider: "windows" 或 "xunfei"
        asr_cfg: ASR 配置字典
        on_partial_text: 流式 partial 回调
        on_final_text: 流式 final 回调

    Returns:
        加载成功的引擎实例，失败时返回 None
    """
    if provider == "windows":
        return load_windows_engine(
            asr_cfg,
            on_partial_text=on_partial_text,
            on_final_text=on_final_text,
        )
    elif provider == "xunfei":
        return load_xunfei_engine(
            asr_cfg,
            on_partial_text=on_partial_text,
            on_final_text=on_final_text,
        )
    else:
        logger.warning("未知 ASR provider: %s", provider)
        return None
