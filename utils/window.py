"""
spoken/utils/window.py
Win32 窗口工具模块。

提供：
- 获取前台窗口句柄和进程信息
- 检测进程是否为 Electron 应用
- 检测 UWP（Windows Store 应用）
- 进程权限级别检测（是否需要 UAC 提权才能注入）
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Optional

logger = logging.getLogger(__name__)

# Electron 应用进程名（小写）
ELECTRON_APPS = frozenset({
    "code.exe",          # VS Code
    "cursor.exe",        # Cursor
    "windsurf.exe",      # Windsurf
    "notion.exe",        # Notion
    "lark.exe",          # 飞书
    "feishu.exe",        # 飞书（旧版）
    "obsidian.exe",      # Obsidian
    "slack.exe",         # Slack
    "discord.exe",       # Discord
    "figma.exe",         # Figma
    "postman.exe",       # Postman
    "cline.exe",         # Cline
})


class WindowInfo:
    """前台窗口信息快照。"""

    def __init__(
        self,
        hwnd: int,
        pid: int,
        exe_name: str,
        exe_path: str,
        title: str,
        is_electron: bool,
        is_uwp: bool,
        is_elevated: bool,
    ) -> None:
        self.hwnd = hwnd
        self.pid = pid
        self.exe_name = exe_name        # 进程名（小写），如 "code.exe"
        self.exe_path = exe_path        # 完整路径
        self.title = title              # 窗口标题
        self.is_electron = is_electron  # 是否为 Electron 应用
        self.is_uwp = is_uwp            # 是否为 UWP 应用
        self.is_elevated = is_elevated  # 是否以管理员权限运行

    def __repr__(self) -> str:
        return (
            f"WindowInfo(hwnd={self.hwnd}, exe={self.exe_name!r}, "
            f"electron={self.is_electron}, uwp={self.is_uwp}, "
            f"elevated={self.is_elevated})"
        )


if sys.platform == "win32":
    import ctypes
    import ctypes.wintypes

    def get_foreground_window() -> Optional[int]:
        """获取当前前台窗口句柄。

        Returns:
            窗口句柄（HWND），无前台窗口时返回 None
        """
        hwnd = ctypes.windll.user32.GetForegroundWindow()
        return hwnd if hwnd else None

    def get_window_pid(hwnd: int) -> int:
        """获取窗口所属进程 PID。

        Args:
            hwnd: 窗口句柄

        Returns:
            进程 PID，失败返回 0
        """
        pid = ctypes.wintypes.DWORD(0)
        ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return pid.value

    def get_window_title(hwnd: int) -> str:
        """获取窗口标题。

        Args:
            hwnd: 窗口句柄

        Returns:
            窗口标题字符串
        """
        length = ctypes.windll.user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return ""
        buf = ctypes.create_unicode_buffer(length + 1)
        ctypes.windll.user32.GetWindowTextW(hwnd, buf, length + 1)
        return buf.value

    def get_process_exe_path(pid: int) -> str:
        """获取进程的可执行文件完整路径。

        Args:
            pid: 进程 PID

        Returns:
            可执行文件路径，失败返回空字符串
        """
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION, False, pid
        )
        if not handle:
            logger.debug("OpenProcess 失败，PID=%d", pid)
            return ""
        try:
            buf = ctypes.create_unicode_buffer(260)
            size = ctypes.wintypes.DWORD(260)
            if ctypes.windll.kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                return buf.value
            else:
                logger.debug("QueryFullProcessImageNameW 失败，PID=%d", pid)
                return ""
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)

    def is_process_elevated(pid: int) -> bool:
        """检测进程是否以管理员/提权模式运行。

        注：检测本身也可能因权限不足而失败，此时保守返回 False。

        Args:
            pid: 进程 PID

        Returns:
            True 表示目标进程已提权（UAC 管理员），False 表示普通权限
        """
        PROCESS_QUERY_INFORMATION = 0x0400
        TOKEN_QUERY = 0x0008
        TokenElevation = 20

        process_handle = ctypes.windll.kernel32.OpenProcess(
            PROCESS_QUERY_INFORMATION, False, pid
        )
        if not process_handle:
            return False

        token_handle = ctypes.wintypes.HANDLE()
        try:
            if not ctypes.windll.advapi32.OpenProcessToken(
                process_handle, TOKEN_QUERY, ctypes.byref(token_handle)
            ):
                return False

            elevation = ctypes.wintypes.DWORD(0)
            return_length = ctypes.wintypes.DWORD(0)
            if ctypes.windll.advapi32.GetTokenInformation(
                token_handle,
                TokenElevation,
                ctypes.byref(elevation),
                ctypes.sizeof(elevation),
                ctypes.byref(return_length),
            ):
                return bool(elevation.value)
        except Exception as e:
            logger.debug("进程权限检测失败，PID=%d: %s", pid, e)
        finally:
            if token_handle:
                ctypes.windll.kernel32.CloseHandle(token_handle)
            ctypes.windll.kernel32.CloseHandle(process_handle)

        return False

    def is_uwp_process(exe_path: str) -> bool:
        """检测是否为 UWP（Windows Store）应用。

        UWP 应用通常运行在 WindowsApps 目录下，注入行为受限。

        Args:
            exe_path: 进程可执行文件路径

        Returns:
            True 表示是 UWP 应用
        """
        if not exe_path:
            return False
        return "\\WindowsApps\\" in exe_path or "\\Program Files\\WindowsApps\\" in exe_path

    def restore_focus(hwnd: int, delay_ms: int = 50) -> bool:
        """将焦点恢复到指定窗口。

        注入前调用，防止文字注入到错误的窗口。

        Args:
            hwnd: 目标窗口句柄
            delay_ms: 焦点切换后的等待时间（毫秒）

        Returns:
            True 表示成功，False 表示窗口已不可用
        """
        import time
        if not hwnd:
            return False
        if not ctypes.windll.user32.IsWindow(hwnd):
            logger.warning("窗口 hwnd=%d 已不存在，无法恢复焦点", hwnd)
            return False

        current = ctypes.windll.user32.GetForegroundWindow()
        if current == hwnd:
            return True

        try:
            # AllowSetForegroundWindow 允许设置前台窗口
            ctypes.windll.user32.AllowSetForegroundWindow(
                ctypes.wintypes.DWORD(0xFFFFFFFF)  # ASFW_ANY
            )
            ctypes.windll.user32.SetForegroundWindow(hwnd)
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)
            return True
        except Exception as e:
            logger.error("SetForegroundWindow 失败 hwnd=%d: %s", hwnd, e)
            return False

    def get_foreground_window_info() -> Optional[WindowInfo]:
        """获取当前前台窗口的完整信息快照。

        Returns:
            WindowInfo 实例，无前台窗口时返回 None
        """
        hwnd = get_foreground_window()
        if hwnd is None:
            return None

        pid = get_window_pid(hwnd)
        if pid == 0:
            logger.warning("无法获取 hwnd=%d 的 PID", hwnd)
            return None

        exe_path = get_process_exe_path(pid)
        exe_name = os.path.basename(exe_path).lower() if exe_path else ""
        title = get_window_title(hwnd)

        return WindowInfo(
            hwnd=hwnd,
            pid=pid,
            exe_name=exe_name,
            exe_path=exe_path,
            title=title,
            is_electron=(exe_name in ELECTRON_APPS),
            is_uwp=is_uwp_process(exe_path),
            is_elevated=is_process_elevated(pid),
        )

else:
    # 非 Windows 平台的占位实现（仅供开发/测试）
    def get_foreground_window() -> Optional[int]:  # type: ignore[misc]
        logger.warning("get_foreground_window 仅支持 Windows")
        return None

    def get_window_pid(hwnd: int) -> int:  # type: ignore[misc]
        return 0

    def get_window_title(hwnd: int) -> str:  # type: ignore[misc]
        return ""

    def get_process_exe_path(pid: int) -> str:  # type: ignore[misc]
        return ""

    def is_process_elevated(pid: int) -> bool:  # type: ignore[misc]
        return False

    def is_uwp_process(exe_path: str) -> bool:  # type: ignore[misc]
        return False

    def restore_focus(hwnd: int, delay_ms: int = 50) -> bool:  # type: ignore[misc]
        return False

    def get_foreground_window_info() -> Optional[WindowInfo]:  # type: ignore[misc]
        return None
