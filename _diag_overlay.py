#!/usr/bin/env python3
"""诊断浮窗倒计时和模式标签问题。"""
import ctypes
import ctypes.wintypes
import time

# 查找 Spoken 浮窗的 hwnd
user32 = ctypes.windll.user32
EnumWindows = user32.EnumWindows
GetWindowTextW = user32.GetWindowTextW
GetWindowThreadProcessId = user32.GetWindowThreadProcessId
IsWindowVisible = user32.IsWindowVisible

WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)

spoken_hwnds = []

def enum_callback(hwnd, lparam):
    if IsWindowVisible(hwnd):
        length = user32.GetWindowTextLengthW(hwnd)
        if length > 0:
            buf = ctypes.create_unicode_buffer(length + 1)
            GetWindowTextW(hwnd, buf, length + 1)
            title = buf.value
            if 'Spoken' in title or 'spoken' in title.lower():
                pid = ctypes.wintypes.DWORD()
                GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                spoken_hwnds.append((hwnd, pid.value, title))
    return True

EnumWindows(WNDENUMPROC(enum_callback), 0)

print(f"找到 {len(spoken_hwnds)} 个 Spoken 窗口:")
for hwnd, pid, title in spoken_hwnds:
    print(f"  hwnd={hwnd}, pid={pid}, title={title}")

# 检查窗口大小
for hwnd, pid, title in spoken_hwnds:
    rect = ctypes.wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w = rect.right - rect.left
    h = rect.bottom - rect.top
    print(f"  窗口尺寸: {w}x{h}, 位置: ({rect.left}, {rect.top})")

print("\n提示：如果窗口宽度远小于 640，则说明 WebView2 没有正确设置窗口大小。")
