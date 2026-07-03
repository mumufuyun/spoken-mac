"""
spoken/core/errors.py
统一错误码体系。

设计原则：
  - 所有模块使用统一的错误码，便于前端展示和用户诊断
  - 错误码分层：E1xx 系统 / E2xx ASR / E3xx AI / E4xx 注入 / E5xx 网络

使用示例::

    from spoken.core.errors import SpokenError, ErrorCode

    raise SpokenError(ErrorCode.ASR_LOAD_FAILED, "Windows ASR 初始化失败")
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Optional


class ErrorCode(Enum):
    """Spoken 错误码枚举。"""

    # 系统级 (E1xx)
    UNKNOWN = ("E100", "未知错误")
    CONFIG_LOAD_FAILED = ("E101", "配置加载失败")
    CONFIG_INVALID = ("E102", "配置格式错误")

    # ASR (E2xx)
    ASR_LOAD_FAILED = ("E200", "语音识别引擎加载失败")
    ASR_START_FAILED = ("E201", "语音识别启动失败")
    ASR_NO_ENGINE = ("E202", "没有可用的语音识别引擎")
    ASR_MICROPHONE_DENIED = ("E203", "麦克风权限被拒绝")
    ASR_ELEVATION_REQUIRED = ("E204", "需要管理员权限")

    # AI (E3xx)
    AI_NO_API_KEY = ("E300", "AI API Key 未配置")
    AI_REQUEST_TIMEOUT = ("E301", "AI 请求超时")
    AI_REQUEST_FAILED = ("E302", "AI 请求失败")
    AI_INTERRUPTED = ("E303", "AI 处理被中断")
    AI_OUTPUT_TRUNCATED = ("E304", "AI 输出被截断")

    # 注入 (E4xx)
    INJECT_FAILED = ("E400", "文本注入失败")
    INJECT_ELEVATION_REQUIRED = ("E401", "目标窗口需要管理员权限")
    INJECT_NO_TARGET = ("E402", "未找到注入目标窗口")

    # 网络 (E5xx)
    NETWORK_ERROR = ("E500", "网络连接错误")
    API_AUTH_FAILED = ("E501", "API 认证失败")
    API_RATE_LIMITED = ("E502", "API 请求过于频繁")

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message


@dataclass(frozen=True)
class SpokenError(Exception):
    """Spoken 标准异常。

    Attributes:
        code: 错误码枚举
        detail: 详细错误信息
        suggestion: 给用户建议
    """

    code: ErrorCode
    detail: str = ""
    suggestion: str = ""

    def __str__(self) -> str:
        parts = [f"[{self.code.code}] {self.code.message}"]
        if self.detail:
            parts.append(self.detail)
        if self.suggestion:
            parts.append(f"建议: {self.suggestion}")
        return " — ".join(parts)

    def to_dict(self) -> dict:
        """转换为字典（便于序列化到前端）。"""
        return {
            "code": self.code.code,
            "message": self.code.message,
            "detail": self.detail,
            "suggestion": self.suggestion,
        }
