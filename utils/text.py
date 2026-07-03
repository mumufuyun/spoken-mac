"""
spoken/utils/text.py
文本处理工具函数。

提供跨模块共享的文本处理功能，如 CoT/思考标签过滤。
"""

from __future__ import annotations

import re

# ══════════════════════════════════════════════════════════════════════
# CoT 过滤工具
# ══════════════════════════════════════════════════════════════════════

# 预编译正则（模块级缓存，避免每次调用都编译）
# 支持多种 CoT/思考标签格式：
#   <think>...</think>          — DeepSeek-R1 / MiniMax / QwQ
#   <thinking>...</thinking>    — 部分 Claude 兼容模型
#   <думаю>...</resposta>       — 部分俄语模型
#   <reasoning>...</reasoning>  — 部分推理模型
_COT_PATTERN = re.compile(r"<думаю>.*?</resposta>", re.DOTALL)
_THINK_PATTERN = re.compile(r"<think(?:ing)?>.*?</think(?:ing)?>", re.DOTALL)
_REASONING_PATTERN = re.compile(r"<reasoning>.*?</reasoning>", re.DOTALL)


def strip_think_tags(text: str) -> str:
    """过滤 LLM 推理过程标签，适用于所有注入路径。

    支持的标签格式：
    - ``<think>...</think>`` （DeepSeek-R1 / MiniMax / QwQ）
    - ``<thinking>...</thinking>`` （部分 Claude 兼容模型）
    - ``<думаю>...</resposta>`` （部分其他模型）
    - ``<reasoning>...</reasoning>`` （部分推理模型）

    Args:
        text: 待过滤文字

    Returns:
        去除所有推理标签后的文字（strip 前后空白）
    """
    if not text:
        return text
    text = _THINK_PATTERN.sub("", text)
    text = _COT_PATTERN.sub("", text)
    text = _REASONING_PATTERN.sub("", text)
    # 清理可能残留的不完整标签（流式输出时标签可能被截断）
    text = re.sub(r"<think(?:ing)?>[^<]*$", "", text, flags=re.DOTALL)
    text = re.sub(r"^[^>]*</think(?:ing)?>", "", text, flags=re.DOTALL)
    text = re.sub(r"<reasoning>[^<]*$", "", text, flags=re.DOTALL)
    return text.strip()
