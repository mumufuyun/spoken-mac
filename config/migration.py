"""
spoken/config/migration.py
配置迁移工具 — 从 V2 迁移到 V3。

职责：
  - 检测 V2 配置格式
  - 自动迁移兼容的配置项
  - 对不兼容项使用默认值并记录日志

迁移规则：
  - V2 的 [asr] 配置基本兼容，新增字段使用默认值
  - V2 的模式名称"摘要"改为"会议纪要"
  - V2 的模式名称"结构化纪要"改为"内容结构化"
  - 新增美团 ASR 配置（使用默认值）
  - 新增长语音配置（使用默认值）
"""

from __future__ import annotations

import logging
from typing import Any, Dict

logger = logging.getLogger(__name__)

# V2 → V3 配置映射
# 键为 V2 中的字段路径，值为 V3 中的字段路径或迁移函数
_CONFIG_REMAP: Dict[str, Any] = {
    # 基本兼容的字段（路径不变）
    "hotkey.record_mode": "hotkey.record_mode",
    "hotkey.toggle_record": "hotkey.toggle_record",
    "hotkey.switch_mode": "hotkey.switch_mode",
    "hotkey.interrupt": "hotkey.interrupt",
    "asr.mode": "asr.mode",
    "asr.language": "asr.language",
    "asr.realtime_provider": "asr.realtime_provider",
    "asr.windows.language_tag": "asr.windows.language_tag",
    "asr.windows.initial_silence_timeout_sec": "asr.windows.initial_silence_timeout_sec",
    "asr.windows.end_silence_timeout_sec": "asr.windows.end_silence_timeout_sec",
    "asr.xunfei.app_id": "asr.xunfei.app_id",
    "asr.xunfei.api_key": "asr.xunfei.api_key",
    "asr.xunfei.api_secret": "asr.xunfei.api_secret",
    "injection.method": "injection.method",
    "injection.focus_delay_ms": "injection.focus_delay_ms",
    "ai.base_url": "ai.base_url",
    "ai.api_key": "ai.api_key",
    "ai.model": "ai.model",
    "ai.timeout_sec": "ai.timeout_sec",
    "ai.custom_prompt_b": "ai.custom_prompt_b",
    "ai.custom_prompt_c": "ai.custom_prompt_c",
    "ai.custom_prompt_d": "ai.custom_prompt_d",
}

# V3 新增字段的默认值
_V3_DEFAULTS: Dict[str, Any] = {
    "asr.fallback_order": "meituan, xunfei, windows",
    "asr.long_audio_threshold_sec": 60.0,
    "asr.max_audio_duration_sec": 600.0,
    "asr.meituan.endpoint": "wss://asr.sankuai.com/v1/realtime",
    "asr.meituan.app_key": "",
    "asr.meituan.app_secret": "",
    "asr.meituan.max_duration_sec": 600,
    "ai.custom_prompt_e": "",
    "ai.custom_prompt_f": "",
}


def migrate_v2_to_v3(v2_config: Dict[str, Any]) -> Dict[str, Any]:
    """将 V2 配置迁移到 V3 格式。

    Args:
        v2_config: V2 格式的配置字典

    Returns:
        V3 格式的配置字典
    """
    v3_config: Dict[str, Any] = {}
    migrated_count = 0
    skipped_count = 0

    # 迁移兼容字段
    for v2_path, v3_path in _CONFIG_REMAP.items():
        value = _get_nested_value(v2_config, v2_path)
        if value is not None:
            _set_nested_value(v3_config, v3_path, value)
            migrated_count += 1
        else:
            skipped_count += 1

    # 添加 V3 新增字段的默认值
    for path, default_value in _V3_DEFAULTS.items():
        # 只在 V2 中不存在该字段时才添加默认值
        if _get_nested_value(v3_config, path) is None:
            _set_nested_value(v3_config, path, default_value)

    logger.info(
        "配置迁移完成: 迁移 %d 项, 跳过 %d 项, 新增 %d 项默认值",
        migrated_count,
        skipped_count,
        len(_V3_DEFAULTS),
    )

    return v3_config


def _get_nested_value(config: Dict[str, Any], path: str) -> Any:
    """获取嵌套字典中的值。

    Args:
        config: 配置字典
        path: 点分隔的路径，如 "asr.language"

    Returns:
        值或 None（不存在时）
    """
    parts = path.split(".")
    current = config
    for part in parts:
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            return None
    return current


def _set_nested_value(config: Dict[str, Any], path: str, value: Any) -> None:
    """设置嵌套字典中的值。

    Args:
        config: 配置字典
        path: 点分隔的路径
        value: 要设置的值
    """
    parts = path.split(".")
    current = config
    for part in parts[:-1]:
        if part not in current:
            current[part] = {}
        current = current[part]
    current[parts[-1]] = value


def detect_config_version(config: Dict[str, Any]) -> str:
    """检测配置版本。

    Args:
        config: 配置字典

    Returns:
        "v3" 或 "v2"
    """
    # V3 特有的字段
    v3_indicators = [
        "asr.fallback_order",
        "asr.meituan",
    ]

    for indicator in v3_indicators:
        if _get_nested_value(config, indicator) is not None:
            return "v3"

    return "v2"


def migrate_if_needed(config: Dict[str, Any]) -> Dict[str, Any]:
    """如果需要，自动迁移配置。

    Args:
        config: 配置字典

    Returns:
        迁移后的配置字典（或原配置如果已经是 V3）
    """
    version = detect_config_version(config)

    if version == "v3":
        logger.debug("配置已是 V3 格式，无需迁移")
        return config

    logger.info("检测到 V2 配置，开始迁移到 V3...")
    return migrate_v2_to_v3(config)
