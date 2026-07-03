#!/usr/bin/env python3
"""直接在浮窗 WebView2 上测试倒计时和模式标签。"""
import ctypes
import ctypes.wintypes

user32 = ctypes.windll.user32

# 找到 Spoken 浮窗
hwnd = 8455818  # 从上一步诊断得到的 hwnd
print(f"Spoken 浮窗 hwnd: {hwnd}")
print(f"IsWindow: {user32.IsWindow(hwnd)}")
print(f"IsWindowVisible: {user32.IsWindowVisible(hwnd)}")

# 获取窗口位置和大小
rect = ctypes.wintypes.RECT()
user32.GetWindowRect(hwnd, ctypes.byref(rect))
print(f"窗口位置: ({rect.left}, {rect.top}) - ({rect.right}, {rect.bottom})")
print(f"窗口尺寸: {rect.right - rect.left} x {rect.bottom - rect.top}")

gdi32 = ctypes.windll.gdi32

# 检查窗口区域（裁切）
hrgn = gdi32.CreateRectRgn(0, 0, 0, 0)
result = user32.GetWindowRgn(hwnd, hrgn)
print(f"GetWindowRgn 结果: {result} (0=ERROR, 1=NULLREGION, 2=SIMPLEREGION, 3=COMPLEXREGION)")

if result > 1:
    rgn_rect = ctypes.wintypes.RECT()
    gdi32 = ctypes.windll.gdi32
    gdi32.GetRgnBox(hrgn, ctypes.byref(rgn_rect))
    print(f"窗口裁切区域: ({rgn_rect.left}, {rgn_rect.top}) - ({rgn_rect.right}, {rgn_rect.bottom})")
    print(f"裁切区域尺寸: {rgn_rect.right - rgn_rect.left} x {rgn_rect.bottom - rgn_rect.top}")
