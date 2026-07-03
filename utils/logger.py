"""
spoken/utils/logger.py
日志模块：统一配置 Spoken 的日志输出。

支持同时输出到控制台和滚动文件，文件路径支持 %APPDATA% 等环境变量。
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import sys
from pathlib import Path
from typing import Optional


def setup_logging(
    level: str = "INFO",
    log_file: Optional[str] = None,
    max_size_mb: int = 10,
    backup_count: int = 3,
) -> None:
    """初始化全局日志配置。

    Args:
        level: 日志级别字符串（DEBUG/INFO/WARNING/ERROR）
        log_file: 日志文件路径（支持环境变量展开），None 则仅输出到控制台
        max_size_mb: 单个日志文件最大体积（MB）
        backup_count: 保留的历史日志文件数量

    Raises:
        ValueError: 日志级别字符串无效
    """
    numeric_level = getattr(logging, level.upper(), None)
    if not isinstance(numeric_level, int):
        raise ValueError(f"无效的日志级别: {level}")

    # 日志格式：时间 + 级别 + 模块名 + 消息
    fmt = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    datefmt = "%Y-%m-%d %H:%M:%S"
    formatter = logging.Formatter(fmt=fmt, datefmt=datefmt)

    root_logger = logging.getLogger()
    root_logger.setLevel(numeric_level)

    # 避免重复添加 handler
    if root_logger.handlers:
        root_logger.handlers.clear()

    # 控制台 handler
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    root_logger.addHandler(console_handler)

    # 文件 handler（可选）
    if log_file:
        expanded_path = os.path.expandvars(log_file) if sys.platform == "win32" else log_file
        log_path = Path(expanded_path)
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            file_handler = logging.handlers.RotatingFileHandler(
                filename=log_path,
                maxBytes=max_size_mb * 1024 * 1024,
                backupCount=backup_count,
                encoding="utf-8",
            )
            file_handler.setFormatter(formatter)
            root_logger.addHandler(file_handler)
        except Exception as e:
            # 文件 handler 创建失败不应阻止程序运行
            root_logger.warning("日志文件创建失败，仅输出到控制台: %s - %s", log_path, e)


def get_logger(name: str) -> logging.Logger:
    """获取指定名称的 logger。

    Args:
        name: logger 名称，通常传 __name__

    Returns:
        logging.Logger 实例
    """
    return logging.getLogger(name)
