"""快速测试 WebView2 浮窗"""
import sys, time
sys.path.insert(0, "d:/spoken")
from overlay.window import OverlayWindow

ov = OverlayWindow()
ov.start()
time.sleep(1)
print("STARTED")

ov.show()
time.sleep(4)
print("SHOW done")

ov.update_text("Hello World")
time.sleep(1.5)
ov.update_text("Hello World, 这是一段测试文字，用来验证浮窗的多行显示效果")
time.sleep(2)
ov.update_text("今天天气真好，我想出去走走，顺便买点东西回来做晚饭。你觉得呢？")
time.sleep(2)
print("UPDATE done")

ov.hide()
time.sleep(3)
print("HIDE done")

ov.destroy()
print("TEST COMPLETE")
