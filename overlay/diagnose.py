"""
spoken/overlay/diagnose.py
浮窗环境诊断模块 — 在启动前检测 WebView2 / pywebview 运行环境

用途：
  1. 提前发现 WebView2 运行时缺失（最常见的浮窗失败原因）
  2. 检测 pythonnet / clr 是否可用（pywebview Windows 后端依赖）
  3. 输出结构化诊断报告，便于排查
"""

from __future__ import annotations

import logging
import os
import platform
import sys
from typing import Optional

logger = logging.getLogger(__name__)

_IS_WINDOWS = platform.system() == "Windows"


def _read_registry_value(key_path: str, value_name: str, hive: str = "HKLM") -> Optional[str]:
    """读取 Windows 注册表值（仅 Windows）。"""
    if not _IS_WINDOWS:
        return None
    try:
        import winreg
        hives = {
            "HKLM": winreg.HKEY_LOCAL_MACHINE,
            "HKCU": winreg.HKEY_CURRENT_USER,
        }
        hkey = hives.get(hive)
        if hkey is None:
            return None
        with winreg.OpenKey(hkey, key_path) as key:
            value, _ = winreg.QueryValueEx(key, value_name)
            return str(value) if value is not None else None
    except Exception:
        return None


def check_webview2_runtime() -> dict:
    """检查 WebView2 运行时安装状态。

    Returns:
        包含以下字段的字典：
        - installed: bool
        - version: str | None
        - location: str | None
        - details: str
    """
    result = {
        "installed": False,
        "version": None,
        "location": None,
        "details": "",
    }

    if not _IS_WINDOWS:
        result["details"] = "非 Windows 系统，无需 WebView2"
        return result

    # WebView2 Runtime 注册表路径（64 位系统上的 32 位注册表视图）
    reg_paths = [
        (
            "HKLM",
            r"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        ),
        (
            "HKLM",
            r"SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        ),
        (
            "HKCU",
            r"Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        ),
    ]

    for hive, key_path in reg_paths:
        version = _read_registry_value(key_path, "pv", hive)
        location = _read_registry_value(key_path, "location", hive)
        if version:
            result["installed"] = True
            result["version"] = version
            result["location"] = location
            result["details"] = f"WebView2 Runtime 已安装（版本 {version}，{hive}）"
            return result

    # 尝试通过文件夹存在性兜底检测（Evergreen Bootstrapper 安装路径）
    program_files = os.environ.get("ProgramFiles(x86)") or os.environ.get("ProgramFiles")
    if program_files:
        runtime_path = os.path.join(
            program_files,
            "Microsoft",
            "EdgeWebView",
            "Application",
        )
        if os.path.isdir(runtime_path):
            try:
                versions = [d for d in os.listdir(runtime_path) if os.path.isdir(os.path.join(runtime_path, d))]
                if versions:
                    result["installed"] = True
                    result["version"] = versions[0]
                    result["details"] = f"WebView2 Runtime 已安装（路径探测，版本 {versions[0]}）"
                    return result
            except Exception:
                pass

    result["details"] = (
        "未检测到 WebView2 Runtime。"
        "请从 https://developer.microsoft.com/microsoft-edge/webview2/ 下载并安装 "
        "Microsoft Edge WebView2 Runtime（Evergreen Standalone Installer）。"
    )
    return result


def check_pythonnet() -> dict:
    """检查 pythonnet (clr) 是否可用。

    pywebview 在 Windows 上使用 WebView2 后端时，依赖 pythonnet 与 .NET 交互。
    """
    result = {
        "available": False,
        "version": None,
        "details": "",
    }

    if not _IS_WINDOWS:
        result["details"] = "非 Windows 系统，无需 pythonnet"
        return result

    try:
        import clr
        result["available"] = True
        try:
            result["version"] = clr.__version__
        except Exception:
            pass
        result["details"] = f"pythonnet 可用（版本 {result['version'] or 'unknown'}）"
    except ImportError:
        result["details"] = (
            "pythonnet (clr) 未安装。pywebview 在 Windows 上需要它作为 WebView2 的桥梁。"
            "请运行: pip install pythonnet"
        )
    except Exception as e:
        result["details"] = f"pythonnet 导入异常: {e}"

    return result


def check_pywebview() -> dict:
    """检查 pywebview 本身是否可导入及版本信息。"""
    result = {
        "available": False,
        "version": None,
        "platform": None,
        "details": "",
    }

    try:
        import webview
        result["available"] = True
        try:
            result["version"] = webview.__version__
        except Exception:
            pass
        try:
            result["platform"] = webview.platform
        except Exception:
            pass
        result["details"] = (
            f"pywebview 可用（版本 {result['version'] or 'unknown'}, "
            f"平台 {result['platform'] or 'unknown'}）"
        )
    except ImportError as e:
        result["details"] = f"pywebview 未安装: {e}"
    except Exception as e:
        result["details"] = f"pywebview 导入异常: {e}"

    return result


def diagnose_overlay_environment() -> dict:
    """综合诊断浮窗环境，返回完整报告。

    Returns:
        {
            "webview2": {...},
            "pythonnet": {...},
            "pywebview": {...},
            "overall_ready": bool,
            "summary": str,
        }
    """
    webview2 = check_webview2_runtime()
    pythonnet = check_pythonnet()
    pywebview = check_pywebview()

    # 判定是否就绪：
    # - Windows 上需要 pywebview + pythonnet + WebView2 Runtime
    # - 非 Windows 上只需要 pywebview
    if _IS_WINDOWS:
        overall_ready = (
            pywebview["available"]
            and pythonnet["available"]
            and webview2["installed"]
        )
    else:
        overall_ready = pywebview["available"]

    parts = []
    if not pywebview["available"]:
        parts.append(pywebview["details"])
    if _IS_WINDOWS and not pythonnet["available"]:
        parts.append(pythonnet["details"])
    if _IS_WINDOWS and not webview2["installed"]:
        parts.append(webview2["details"])

    if overall_ready:
        summary = f"浮窗环境就绪。{pywebview['details']} | {pythonnet['details']} | {webview2['details']}"
    else:
        summary = "浮窗环境未就绪: " + "; ".join(parts) if parts else "未知问题"

    return {
        "webview2": webview2,
        "pythonnet": pythonnet,
        "pywebview": pywebview,
        "overall_ready": overall_ready,
        "summary": summary,
    }


def log_diagnosis(level: int = logging.WARNING) -> bool:
    """运行诊断并记录到日志。

    Returns:
        True 表示环境就绪，False 表示有缺失。
    """
    report = diagnose_overlay_environment()
    logger.log(level, "浮窗环境诊断: %s", report["summary"])
    if not report["overall_ready"]:
        logger.log(level, "  pywebview: %s", report["pywebview"]["details"])
        if _IS_WINDOWS:
            logger.log(level, "  pythonnet: %s", report["pythonnet"]["details"])
            logger.log(level, "  WebView2:  %s", report["webview2"]["details"])
    return report["overall_ready"]


def get_webview2_download_url() -> str:
    """获取 WebView2 运行时下载链接。"""
    return (
        "https://developer.microsoft.com/zh-cn/microsoft-edge/webview2/"
        "?form=MA13LH#download"
    )
