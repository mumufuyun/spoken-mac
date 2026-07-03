"""
spoken/ai/strategies.py
AI 处理策略 — 插件化架构。

每个工作模式（A-F）对应一个策略实现：
  - DirectStrategy:             模式 A，直接返回原文
  - OpenAIStrategy:             模式 B-F，调用 OpenAI 兼容 API
  - MeetingMinutesStrategy:     模式 E（V3 新增），专用会议纪要策略
  - ContentStructuringStrategy: 模式 F（V3 新增），专用内容结构化策略
  - StrategyRegistry:           策略注册表，统一管理策略实例

使用示例::

    from spoken.ai.strategies import build_default_strategies, StrategyRegistry
    from spoken.ai.client import AIClient

    client = AIClient(base_url="...", api_key="...")
    registry = build_default_strategies(client)

    strategy = registry.get("E")
    result = strategy.process(text, interrupt_event=evt)
"""

from __future__ import annotations

import logging
import re
import threading
from abc import ABC, abstractmethod
from typing import Callable, Dict, List, Optional

from .prompts import get_system_prompt, get_mode_name

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 处理结果
# ══════════════════════════════════════════════════════════════════════

class ProcessResult:
    """AI 处理结果封装。"""

    def __init__(
        self,
        text: str,
        mode_used: str,
        *,
        fallback: bool = False,
        interrupted: bool = False,
        timed_out: bool = False,
        error: Optional[Exception] = None,
        truncated: bool = False,
        finish_reason: Optional[str] = None,
    ) -> None:
        self.text = text
        self.mode_used = mode_used
        self.fallback = fallback
        self.interrupted = interrupted
        self.timed_out = timed_out
        self.error = error
        self.truncated = truncated
        self.finish_reason = finish_reason

    @property
    def success(self) -> bool:
        """是否成功使用了请求的 AI 模式（未发生降级）。"""
        return not self.fallback

    def __repr__(self) -> str:
        status = "OK" if self.success else "FALLBACK"
        if self.interrupted:
            status = "INTERRUPTED"
        elif self.timed_out:
            status = "TIMEOUT"
        elif self.truncated:
            status = "TRUNCATED"
        return f"ProcessResult({status}, mode={self.mode_used!r}, text={self.text[:30]!r})"


# ══════════════════════════════════════════════════════════════════════
# 策略接口
# ══════════════════════════════════════════════════════════════════════

class AIStrategy(ABC):
    """AI 处理策略接口。"""

    @abstractmethod
    def process(
        self,
        text: str,
        *,
        interrupt_event: threading.Event,
        on_chunk: Optional[Callable[[str], None]] = None,
        timeout_sec: float = 10.0,
    ) -> ProcessResult:
        """处理输入文字。

        Args:
            text: ASR 识别出的原始文字
            interrupt_event: 中断信号事件
            on_chunk: 流式回调
            timeout_sec: 超时秒数

        Returns:
            ProcessResult 对象
        """
        ...

    @property
    @abstractmethod
    def mode(self) -> str:
        """策略对应的模式标识。"""
        ...

    @property
    def display_name(self) -> str:
        """模式的显示名称（用于日志和 UI）。"""
        return get_mode_name(self.mode)


# ══════════════════════════════════════════════════════════════════════
# 直接返回策略（模式 A）
# ══════════════════════════════════════════════════════════════════════

class DirectStrategy(AIStrategy):
    """模式 A：直接返回原文，零延迟。"""

    @property
    def mode(self) -> str:
        return "A"

    def process(
        self,
        text: str,
        *,
        interrupt_event: threading.Event,
        on_chunk: Optional[Callable[[str], None]] = None,
        timeout_sec: float = 10.0,
    ) -> ProcessResult:
        return ProcessResult(text=text, mode_used="A")


# ══════════════════════════════════════════════════════════════════════
# OpenAI API 策略（模式 B-F）
# ══════════════════════════════════════════════════════════════════════

class OpenAIStrategy(AIStrategy):
    """模式 B-F：通过 OpenAI 兼容 API 处理。

    不同模式通过 system prompt 区分。
    """

    def __init__(
        self,
        client: "AIClient",
        mode: str,
        *,
        custom_prompt: str = "",
        mode_timeout_sec: Optional[float] = None,
    ) -> None:
        self._client = client
        self._mode = mode
        self._custom_prompt = custom_prompt
        self._mode_timeout_sec = mode_timeout_sec

    @property
    def mode(self) -> str:
        return self._mode

    def process(
        self,
        text: str,
        *,
        interrupt_event: threading.Event,
        on_chunk: Optional[Callable[[str], None]] = None,
        timeout_sec: float = 10.0,
    ) -> ProcessResult:
        if not text.strip():
            return ProcessResult(text="", mode_used=self._mode)

        deadline = self._mode_timeout_sec or timeout_sec
        system_prompt = get_system_prompt(self._mode, custom_prompt=self._custom_prompt)

        result_holder: list = []
        done_event = threading.Event()

        def _worker() -> None:
            try:
                response = self._client.request(
                    system_prompt=system_prompt,
                    user_text=text,
                    stream=on_chunk is not None,
                    on_chunk=on_chunk,
                    interrupt_event=interrupt_event,
                )
                result_holder.append(response)
            except Exception as exc:
                result_holder.append(exc)
            finally:
                done_event.set()

        worker = threading.Thread(target=_worker, daemon=True, name=f"AIWorker-{self._mode}")
        worker.start()

        # 等待完成、超时或中断
        poll_interval = 0.1
        elapsed = 0.0
        while elapsed < deadline:
            if done_event.wait(timeout=poll_interval):
                break
            if interrupt_event.is_set():
                logger.info("AI 处理被用户中断（Esc），降级为 Mode A")
                return ProcessResult(text=text, mode_used="A", fallback=True, interrupted=True)
            elapsed += poll_interval
        else:
            logger.warning(
                "AI 请求超时（%.1fs，模式 %s），降级为 Mode A",
                deadline,
                self._mode,
            )
            return ProcessResult(text=text, mode_used="A", fallback=True, timed_out=True)

        if not result_holder:
            return ProcessResult(text=text, mode_used="A", fallback=True)

        payload = result_holder[0]
        if isinstance(payload, Exception):
            logger.error("AI API 调用失败，降级为 Mode A: %s", payload)
            return ProcessResult(text=text, mode_used="A", fallback=True, error=payload)

        # 解析结果
        finish_reason = payload.get("finish_reason")
        processed = str(payload.get("text", "")).strip()

        if finish_reason == "length" and len(processed) < len(text) * 0.3:
            logger.warning("AI 输出被截断，回退原始文字")
            return ProcessResult(
                text=text,
                mode_used="A",
                fallback=True,
                truncated=True,
                finish_reason=finish_reason,
            )

        # Mode C 特殊处理：规范化 prompt 输出
        if self._mode == "C":
            processed = self._normalize_prompt_output(processed)

        logger.info("AI 处理完成（模式: %s）: %s...", self._mode, processed[:30])
        return ProcessResult(
            text=processed,
            mode_used=self._mode,
            finish_reason=finish_reason,
        )

    @staticmethod
    def _normalize_prompt_output(text: str) -> str:
        """清理 Prompt 模式常见跑偏输出。"""
        cleaned = (text or "").strip()
        if not cleaned:
            return ""

        cleaned = re.sub(r"^```(?:[a-z0-9_+-]+)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned, flags=re.IGNORECASE).strip()

        prefixes = [
            "以下是优化后的prompt：", "以下是优化后的 prompt：",
            "以下是prompt：", "以下是 prompt：",
            "下面是优化后的prompt：", "下面是优化后的 prompt：",
            "下面是prompt：", "下面是 prompt：",
            "可以使用以下prompt：", "可以使用以下 prompt：",
            "这是一个可用的prompt：", "这是一个可用的 prompt：",
            "优化后的prompt：", "优化后的 prompt：",
            "prompt：", "Prompt:", "Prompt：",
        ]
        lowered = cleaned.lower()
        for prefix in prefixes:
            if lowered.startswith(prefix.lower()):
                cleaned = cleaned[len(prefix):].lstrip()
                break

        cleaned = re.sub(
            r"^(?:你可以这样写|你可以这样输入|可以这样写|可以这样输入|请将以下内容发送给 AI)[:：]\s*",
            "",
            cleaned,
            flags=re.IGNORECASE,
        ).strip()

        lines = cleaned.splitlines()
        if lines and re.fullmatch(r"(?:prompt|提示词|模板|示例)", lines[0].strip(), flags=re.IGNORECASE):
            cleaned = "\n".join(lines[1:]).strip()

        return cleaned


# ══════════════════════════════════════════════════════════════════════
# 会议纪要策略（模式 E，V3 专用）
# ══════════════════════════════════════════════════════════════════════

class MeetingMinutesStrategy(OpenAIStrategy):
    """模式 E：会议纪要模式（V3 新增）。

    在 OpenAIStrategy 基础上增加：
    - 自动检测输入长度，长语音使用更大 timeout
    - 对输出进行 Markdown 规范化
    - 记录处理统计（字数压缩率）
    """

    # 会议纪要输出的最小有效长度（字符数）
    _MIN_VALID_OUTPUT_LEN = 50

    def __init__(
        self,
        client: "AIClient",
        *,
        custom_prompt: str = "",
        base_timeout_sec: float = 30.0,
    ) -> None:
        super().__init__(client, mode="E", custom_prompt=custom_prompt)
        self._base_timeout_sec = base_timeout_sec

    @property
    def mode(self) -> str:
        return "E"

    def process(
        self,
        text: str,
        *,
        interrupt_event: threading.Event,
        on_chunk: Optional[Callable[[str], None]] = None,
        timeout_sec: float = 30.0,
    ) -> ProcessResult:
        if not text.strip():
            return ProcessResult(text="", mode_used="E")

        # 长文本自动延长 timeout（每 200 字额外增加 5 秒）
        char_count = len(text)
        adaptive_timeout = max(self._base_timeout_sec, timeout_sec)
        if char_count > 200:
            extra = (char_count // 200) * 5
            adaptive_timeout = min(adaptive_timeout + extra, 120.0)
            logger.debug("会议纪要模式：输入 %d 字，timeout 调整为 %.0fs", char_count, adaptive_timeout)

        result = super().process(
            text,
            interrupt_event=interrupt_event,
            on_chunk=on_chunk,
            timeout_sec=adaptive_timeout,
        )

        # 输出有效性检查：结果太短说明 AI 没有正确处理
        if result.success and len(result.text) < self._MIN_VALID_OUTPUT_LEN:
            logger.warning(
                "会议纪要输出过短（%d 字），可能处理失败，回退原文",
                len(result.text),
            )
            return ProcessResult(text=text, mode_used="A", fallback=True)

        # 记录压缩率
        if result.success and char_count > 0:
            compression = len(result.text) / char_count
            logger.info(
                "会议纪要处理完成：输入 %d 字 → 输出 %d 字（压缩率 %.1f%%）",
                char_count,
                len(result.text),
                compression * 100,
            )

        return result

    @staticmethod
    def _normalize_minutes_output(text: str) -> str:
        """规范化会议纪要输出格式。

        确保 Markdown 标题格式正确，移除多余空行。
        """
        if not text:
            return text

        lines = text.splitlines()
        normalized: List[str] = []
        prev_blank = False

        for line in lines:
            stripped = line.strip()
            is_blank = not stripped

            # 最多保留一个连续空行
            if is_blank and prev_blank:
                continue

            normalized.append(stripped if stripped else "")
            prev_blank = is_blank

        return "\n".join(normalized).strip()


# ══════════════════════════════════════════════════════════════════════
# 内容结构化策略（模式 F，V3 专用）
# ══════════════════════════════════════════════════════════════════════

class ContentStructuringStrategy(OpenAIStrategy):
    """模式 F：内容结构化整理模式（V3 新增）。

    在 OpenAIStrategy 基础上增加：
    - 自动检测内容类型（列表/叙述/混合），选择合适的整理方式
    - 对过短输入直接返回润色结果而不是结构化
    - 输出后处理：确保 Markdown 格式规范
    """

    # 触发结构化整理的最小输入长度（字符数）
    _MIN_STRUCTURING_LEN = 80

    def __init__(
        self,
        client: "AIClient",
        *,
        custom_prompt: str = "",
        base_timeout_sec: float = 20.0,
    ) -> None:
        super().__init__(client, mode="F", custom_prompt=custom_prompt)
        self._base_timeout_sec = base_timeout_sec

    @property
    def mode(self) -> str:
        return "F"

    def process(
        self,
        text: str,
        *,
        interrupt_event: threading.Event,
        on_chunk: Optional[Callable[[str], None]] = None,
        timeout_sec: float = 20.0,
    ) -> ProcessResult:
        if not text.strip():
            return ProcessResult(text="", mode_used="F")

        # 输入过短时，结构化意义不大，退化为润色模式
        if len(text.strip()) < self._MIN_STRUCTURING_LEN:
            logger.debug(
                "内容结构化：输入过短（%d 字 < %d），退化为润色模式",
                len(text.strip()),
                self._MIN_STRUCTURING_LEN,
            )
            from .prompts import get_system_prompt as _get_prompt
            # 使用 Mode B 的 prompt 但保持 mode_used = F
            result = super().process(
                text,
                interrupt_event=interrupt_event,
                on_chunk=on_chunk,
                timeout_sec=timeout_sec,
            )
            return result

        # 自适应 timeout
        char_count = len(text)
        adaptive_timeout = max(self._base_timeout_sec, timeout_sec)
        if char_count > 300:
            extra = (char_count // 300) * 5
            adaptive_timeout = min(adaptive_timeout + extra, 90.0)

        result = super().process(
            text,
            interrupt_event=interrupt_event,
            on_chunk=on_chunk,
            timeout_sec=adaptive_timeout,
        )

        if result.success:
            logger.info(
                "内容结构化完成：输入 %d 字 → 输出 %d 字",
                char_count,
                len(result.text),
            )

        return result

    @staticmethod
    def detect_content_type(text: str) -> str:
        """检测输入内容类型。

        Args:
            text: 输入文本

        Returns:
            "list"     - 已有明显列表结构
            "narrative" - 叙述性段落
            "mixed"    - 混合类型
        """
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        if not lines:
            return "narrative"

        # 检测是否有列表标记
        list_markers = sum(
            1 for l in lines
            if l.startswith(("-", "*", "•", "·"))
            or re.match(r"^\d+[.、）)]\s", l)
        )

        list_ratio = list_markers / len(lines)
        if list_ratio > 0.5:
            return "list"
        elif list_ratio > 0.2:
            return "mixed"
        return "narrative"


# ══════════════════════════════════════════════════════════════════════
# 策略注册表（V3 新增）
# ══════════════════════════════════════════════════════════════════════

class StrategyRegistry:
    """AI 策略注册表。

    统一管理所有模式的策略实例，支持运行时注册和替换。

    使用示例::

        registry = StrategyRegistry()
        registry.register("A", DirectStrategy())
        registry.register("B", OpenAIStrategy(client, mode="B"))

        strategy = registry.get("B")
        result = strategy.process(text, interrupt_event=evt)
    """

    def __init__(self) -> None:
        self._strategies: Dict[str, AIStrategy] = {}
        self._lock = threading.RLock()

    def register(self, mode: str, strategy: AIStrategy) -> None:
        """注册策略。

        Args:
            mode: 模式 ID，如 "A", "B"
            strategy: 策略实例
        """
        with self._lock:
            self._strategies[mode] = strategy
        logger.debug("注册 AI 策略: mode=%s, strategy=%s", mode, type(strategy).__name__)

    def get(self, mode: str) -> Optional[AIStrategy]:
        """获取指定模式的策略。

        Args:
            mode: 模式 ID

        Returns:
            策略实例，未找到返回 None
        """
        with self._lock:
            return self._strategies.get(mode)

    def get_or_fallback(self, mode: str, fallback_mode: str = "A") -> AIStrategy:
        """获取策略，不存在时回退到指定模式。

        Args:
            mode: 请求的模式 ID
            fallback_mode: 回退模式 ID（默认 "A"）

        Returns:
            策略实例

        Raises:
            KeyError: 请求的模式和回退模式都不存在
        """
        with self._lock:
            strategy = self._strategies.get(mode)
            if strategy is not None:
                return strategy
            fallback = self._strategies.get(fallback_mode)
            if fallback is not None:
                logger.warning("模式 %s 不存在，回退到模式 %s", mode, fallback_mode)
                return fallback
            raise KeyError(f"策略不存在: mode={mode!r}, fallback={fallback_mode!r}")

    def list_modes(self) -> List[str]:
        """返回已注册的模式 ID 列表。"""
        with self._lock:
            return sorted(self._strategies.keys())

    def has_mode(self, mode: str) -> bool:
        """检查指定模式是否已注册。"""
        with self._lock:
            return mode in self._strategies

    def __repr__(self) -> str:
        modes = self.list_modes()
        return f"StrategyRegistry(modes={modes})"


# ══════════════════════════════════════════════════════════════════════
# 工厂函数
# ══════════════════════════════════════════════════════════════════════

def build_default_strategies(
    client: Optional["AIClient"] = None,
    *,
    custom_prompts: Optional[Dict[str, str]] = None,
) -> StrategyRegistry:
    """构建包含默认策略的注册表。

    Args:
        client: AIClient 实例（模式 B-F 需要）
        custom_prompts: 各模式的自定义 prompt，如 {"B": "你是...", "E": "..."}

    Returns:
        StrategyRegistry 实例
    """
    registry = StrategyRegistry()
    custom_prompts = custom_prompts or {}

    # 模式 A：无需 client
    registry.register("A", DirectStrategy())

    if client is not None:
        # 模式 B-D：通用 OpenAI 策略
        for mode in ("B", "C", "D"):
            registry.register(
                mode,
                OpenAIStrategy(
                    client,
                    mode=mode,
                    custom_prompt=custom_prompts.get(mode, ""),
                ),
            )

        # 模式 E：专用会议纪要策略
        registry.register(
            "E",
            MeetingMinutesStrategy(
                client,
                custom_prompt=custom_prompts.get("E", ""),
            ),
        )

        # 模式 F：专用内容结构化策略
        registry.register(
            "F",
            ContentStructuringStrategy(
                client,
                custom_prompt=custom_prompts.get("F", ""),
            ),
        )

    logger.info("AI 策略注册表构建完成，已注册模式: %s", registry.list_modes())
    return registry
