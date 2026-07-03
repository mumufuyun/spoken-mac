"""
spoken/ai/client.py
OpenAI 兼容 API 客户端封装。

职责：
  - 管理 OpenAI 客户端生命周期（懒加载 + 复用）
  - 执行请求（流式/非流式）
  - CoT 内容过滤
"""

from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

logger = logging.getLogger(__name__)


class AIClient:
    """OpenAI 兼容 API 客户端。

    线程安全，可在多个策略间复用。
    """

    def __init__(
        self,
        base_url: str = "https://api.openai.com/v1",
        api_key: str = "",
        model: str = "gpt-4o-mini",
        timeout_sec: float = 10.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._model = model
        self._timeout_sec = timeout_sec
        self._client: Optional[object] = None

    def request(
        self,
        system_prompt: str,
        user_text: str,
        *,
        stream: bool = False,
        on_chunk: Optional[Callable[[str], None]] = None,
        interrupt_event: Optional[threading.Event] = None,
    ) -> dict:
        """发送聊天补全请求。

        Args:
            system_prompt: System 消息内容
            user_text: User 消息内容
            stream: 是否使用流式输出
            on_chunk: 流式回调
            interrupt_event: 中断信号

        Returns:
            {"text": str, "finish_reason": str|None}

        Raises:
            ImportError: openai 库未安装
            RuntimeError: API Key 未配置
            Exception: API 调用失败
        """
        try:
            from openai import OpenAI
        except ImportError as e:
            raise ImportError("openai 库未安装，请运行: pip install openai") from e

        client = self._get_or_create_client(OpenAI)

        logger.debug(
            "AI 请求: base_url=%s model=%s stream=%s",
            self._base_url,
            self._model,
            stream,
        )

        response = client.chat.completions.create(
            model=self._model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_text},
            ],
            temperature=0.3,
            stream=stream,
        )

        if stream:
            return self._handle_stream(response, on_chunk, interrupt_event)
        else:
            return self._handle_blocking(response)

    def _handle_stream(
        self,
        response,
        on_chunk: Optional[Callable[[str], None]],
        interrupt_event: Optional[threading.Event],
    ) -> dict:
        from spoken.utils.text import strip_think_tags

        collected: list[str] = []
        finish_reason = None

        for chunk in response:
            if interrupt_event and interrupt_event.is_set():
                logger.debug("流式请求被中断")
                break

            if chunk.choices:
                delta = chunk.choices[0].delta
                if delta and delta.content:
                    collected.append(delta.content)
                    if on_chunk:
                        try:
                            on_chunk("".join(collected))
                        except Exception as e:
                            logger.debug("on_chunk 回调异常: %s", e)
                if chunk.choices[0].finish_reason:
                    finish_reason = chunk.choices[0].finish_reason

        result = "".join(collected)
        result = strip_think_tags(result)
        return {"text": result.strip(), "finish_reason": finish_reason}

    def _handle_blocking(self, response) -> dict:
        from spoken.utils.text import strip_think_tags

        choice = response.choices[0]
        result = choice.message.content or ""
        finish_reason = getattr(choice, "finish_reason", None)

        if response.usage:
            logger.debug("AI 响应 token 数: %d", response.usage.total_tokens)

        result = strip_think_tags(result)
        return {"text": result.strip(), "finish_reason": finish_reason}

    def _get_or_create_client(self, OpenAI_cls: type) -> object:
        if self._client is None:
            if not self._api_key:
                raise RuntimeError(
                    "AI API Key 未配置。请在 config.toml 中设置 [ai].api_key，"
                    "或设置环境变量 SPOKEN_AI_API_KEY"
                )
            self._client = OpenAI_cls(
                base_url=self._base_url,
                api_key=self._api_key,
                timeout=self._timeout_sec,
            )
            logger.debug("OpenAI 客户端已创建")
        return self._client

    def close(self) -> None:
        """关闭客户端，释放连接池。"""
        if self._client is not None:
            try:
                self._client.close()
            except Exception as e:
                logger.debug("关闭客户端时出错: %s", e)
            self._client = None

    def __repr__(self) -> str:
        return f"AIClient(model={self._model!r}, base_url={self._base_url!r})"
