"""
spoken/ai/processor.py
AI 处理器 — 策略调度器。

职责：
  - 注册和管理 AI 处理策略（模式 A-F）
  - 根据模式选择对应策略执行
  - 维护 AIClient 实例（供多个策略复用）
  - 提供与 v1 兼容的接口

架构::

    AIProcessor (调度器)
        ├── AIStrategy (接口)
        │     ├── DirectStrategy   → 模式 A
        │     └── OpenAIStrategy   → 模式 B-F
        └── AIClient (OpenAI API 封装)
"""

from __future__ import annotations

import logging
import os
import threading
from typing import Callable, Dict, Optional

from .client import AIClient
from .strategies import AIStrategy, DirectStrategy, OpenAIStrategy, ProcessResult

logger = logging.getLogger(__name__)


class AIProcessor:
    """AI 处理器，基于策略模式调度不同工作模式。

    兼容 v1 接口，内部使用策略模式实现。
    """

    ENV_API_KEY = "SPOKEN_AI_API_KEY"

    def __init__(
        self,
        base_url: str = "https://api.openai.com/v1",
        api_key: str = "",
        model: str = "gpt-4o-mini",
        timeout_sec: float = 10.0,
        custom_prompt_b: str = "",
        custom_prompt_c: str = "",
        custom_prompt_d: str = "",
        custom_prompt_e: str = "",
        custom_prompt_f: str = "",
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._key_source = self._detect_key_source(api_key)
        self._api_key = self._resolve_api_key(api_key)
        self._model = model
        self._timeout_sec = timeout_sec
        self._mode_timeouts: dict[str, float] = {}
        self._custom_prompts = {
            "B": custom_prompt_b,
            "C": custom_prompt_c,
            "D": custom_prompt_d,
            "E": custom_prompt_e,
            "F": custom_prompt_f,
        }

        # 中断信号
        self.interrupt_event: threading.Event = threading.Event()

        # AI 客户端（懒加载）
        self._client: Optional[AIClient] = None

        # 策略注册表
        self._strategies: Dict[str, AIStrategy] = {}
        self._register_default_strategies()

    # ── 策略注册 ──────────────────────────────────────────────────

    def _register_default_strategies(self) -> None:
        """注册默认的策略（A-F）。"""
        self.register("A", DirectStrategy())

        # B-F 使用 OpenAI 策略，但只有客户端就绪后才可用
        for mode in ("B", "C", "D", "E", "F"):
            self.register(
                mode,
                OpenAIStrategy(
                    client=self._get_or_create_client(),
                    mode=mode,
                    custom_prompt=self._custom_prompts.get(mode, ""),
                    mode_timeout_sec=self._mode_timeouts.get(mode),
                ),
            )

    def register(self, mode: str, strategy: AIStrategy) -> None:
        """注册一个处理策略。

        Args:
            mode: 模式标识，如 "A", "B"
            strategy: 策略实例
        """
        self._strategies[mode] = strategy
        logger.debug("注册 AI 策略: %s -> %s", mode, type(strategy).__name__)

    def unregister(self, mode: str) -> bool:
        """注销策略。"""
        if mode in self._strategies:
            del self._strategies[mode]
            return True
        return False

    # ── 主处理入口 ────────────────────────────────────────────────

    def process(self, text: str, mode: str = "A", on_chunk: Optional[Callable[[str], None]] = None) -> ProcessResult:
        """处理识别文字，根据模式选择对应策略。

        Args:
            text: ASR 识别出的原始文字
            mode: 处理模式 "A" / "B" / "C" / "D" / "E" / "F"
            on_chunk: 流式回调

        Returns:
            ProcessResult 对象
        """
        if not text.strip():
            return ProcessResult(text="", mode_used=mode)

        if mode not in self._strategies:
            logger.warning("未知模式 %s，降级为 Mode A", mode)
            return ProcessResult(text=text, mode_used="A", fallback=True)

        # 清除旧的中断信号
        self.interrupt_event.clear()

        strategy = self._strategies[mode]
        logger.info("AI 处理开始（模式: %s，策略: %s）", mode, type(strategy).__name__)

        result = strategy.process(
            text,
            interrupt_event=self.interrupt_event,
            on_chunk=on_chunk,
            timeout_sec=self._get_timeout_for_mode(mode),
        )
        return result

    def interrupt(self) -> None:
        """发送中断信号。"""
        self.interrupt_event.set()
        logger.info("AI 中断信号已发送")

    # ── 配置与状态 ────────────────────────────────────────────────

    def set_mode_timeout(self, mode: str, timeout_sec: float) -> None:
        """为特定模式设置超时时间。"""
        if mode in ("B", "C", "D", "E", "F") and timeout_sec > 0:
            self._mode_timeouts[mode] = timeout_sec
            # 更新已有策略
            strategy = self._strategies.get(mode)
            if isinstance(strategy, OpenAIStrategy):
                strategy._mode_timeout_sec = timeout_sec

    def is_enabled(self) -> bool:
        """AI 功能是否可用。"""
        return bool(self._api_key)

    @property
    def key_source(self) -> str:
        return self._key_source

    @property
    def model_name(self) -> str:
        return self._model

    @property
    def base_url(self) -> str:
        return self._base_url

    def close(self) -> None:
        """关闭资源。"""
        if self._client is not None:
            self._client.close()
            self._client = None

    # ── 内部方法 ──────────────────────────────────────────────────

    def _get_or_create_client(self) -> AIClient:
        if self._client is None:
            self._client = AIClient(
                base_url=self._base_url,
                api_key=self._api_key,
                model=self._model,
                timeout_sec=self._timeout_sec,
            )
        return self._client

    def _get_timeout_for_mode(self, mode: str) -> float:
        return self._mode_timeouts.get(mode, self._timeout_sec)

    @classmethod
    def _detect_key_source(cls, config_key: str) -> str:
        env_key = os.environ.get(cls.ENV_API_KEY, "")
        if env_key:
            return "environment"
        if config_key:
            return "config"
        return "missing"

    @classmethod
    def _resolve_api_key(cls, config_key: str) -> str:
        env_key = os.environ.get(cls.ENV_API_KEY, "")
        if env_key:
            return env_key
        return config_key

    @classmethod
    def from_config(cls, config: dict, mode_config: dict | None = None) -> "AIProcessor":
        """从配置字典创建实例（兼容 v1 接口）。"""
        custom_b = custom_c = custom_d = custom_e = custom_f = ""
        if mode_config:
            prompts = mode_config.get("prompts", {})
            if isinstance(prompts, dict):
                custom_b = str(prompts.get("B", ""))
                custom_c = str(prompts.get("C", ""))
                custom_d = str(prompts.get("D", ""))
                custom_e = str(prompts.get("E", ""))
                custom_f = str(prompts.get("F", ""))

        base_url = str(config.get("base_url", "https://api.openai.com/v1"))
        stripped = base_url.rstrip("/")
        if stripped == "https://aigc.sankuai.com/v1/openai":
            base_url = "https://aigc.sankuai.com/v1/openai/native"
            logger.warning("base_url 自动修正为 Friday 平台正确路径: %s", base_url)

        raw_cfg_key = str(config.get("api_key", ""))
        resolved_key = cls._resolve_api_key(raw_cfg_key)

        # Friday 平台特殊处理
        if "aigc.sankuai.com" in base_url:
            if resolved_key and not resolved_key.isdigit():
                if raw_cfg_key.isdigit():
                    logger.warning(
                        "环境变量 %s 的值不是 Friday 平台 AppID 格式，回退使用配置文件",
                        cls.ENV_API_KEY,
                    )
                    resolved_key = raw_cfg_key
                else:
                    logger.error(
                        "Friday 平台 AppID 格式错误（应为纯数字）",
                    )

        return cls(
            base_url=base_url,
            api_key=resolved_key,
            model=str(config.get("model", "gpt-4o-mini")),
            timeout_sec=float(config.get("timeout_sec", 10.0)),
            custom_prompt_b=custom_b,
            custom_prompt_c=custom_c,
            custom_prompt_d=custom_d,
            custom_prompt_e=custom_e,
            custom_prompt_f=custom_f,
        )

    def __repr__(self) -> str:
        return f"AIProcessor(model={self._model!r}, strategies={list(self._strategies.keys())})"


# 向后兼容：导出 ProcessResult
__all__ = ["AIProcessor", "ProcessResult"]
