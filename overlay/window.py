"""
spoken/overlay/window.py
录音状态浮窗 — WebView2 现代化 UI

使用 pywebview + HTML/CSS/JS 实现高品质浮窗：
  - Acrylic 毛玻璃半透明背景
  - CSS3 平滑动画（脉冲、波形、渐隐）
  - 单行文字展示（横向滚动跟随最新内容）
  - 状态栏：图标 + 状态文字 + 模式标签
  - 内容区：流式识别文字实时更新

架构说明：
  webview.start() 必须在主线程中调用（阻塞运行），
  因此采用 "延迟启动" 模式：
  - OverlayWindow 先创建，记录命令到队列
  - 应用主循环空闲时调用 start_loop()，在主线程启动 WebView
  - 或者通过 start_in_thread() 在独立线程中启动

线程安全：通过 queue + 定时轮询实现跨线程通信。
"""

from __future__ import annotations

import ctypes
import json
import logging
import platform
import queue
import threading
import time
from typing import Optional

_IS_WINDOWS = platform.system() == "Windows"

logger = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════════════
# 常量
# ═══════════════════════════════════════════════════════════════════════
WIN_W = 640
WIN_H_INIT = 120
WIN_H_MAX = 420
BOTTOM_OFFSET = 80
POLL_MS = 20
TOPMOST_INTERVAL_VISIBLE_SEC = 0.25

# ═══════════════════════════════════════════════════════════════════════
# 命令
# ═══════════════════════════════════════════════════════════════════════
CMD_SHOW = "show"
CMD_UPDATE = "update"
CMD_SET_ICON = "set_icon"
CMD_SET_STATE = "set_state"
CMD_HIDE = "hide"
CMD_DESTROY = "destroy"
CMD_SET_MODE = "set_mode"

# ═══════════════════════════════════════════════════════════════════════
# HTML/CSS/JS — 浮窗 UI
# ═══════════════════════════════════════════════════════════════════════
OVERLAY_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<style>
  *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }

  /* ════ 大众点评 2026 设计系统 — 浮窗适配版 ════ */
  :root {
    /* 品牌主色 */
    --dp-primary:           #FF6633;
    --dp-primary-light:     #FFEFEA;
    --dp-gradient-start:    #FFA546;

    /* 功能色 */
    --dp-red:               #FF463A;
    --dp-yellow:            #FFC71E;
    --dp-green:             #30D158;
    --dp-link:              #466899;

    /* 文字色 */
    --dp-text-1:            rgba(0,0,0,0.9);
    --dp-text-2:            rgba(0,0,0,0.6);
    --dp-text-3:            rgba(0,0,0,0.35);
    --dp-text-white:        #FFFFFF;

    /* 背景/中性 */
    --dp-bg-page:           #F7F8F9;
    --dp-bg-card:           #FFFFFF;
    --dp-bg-secondary:      #F6F6F6;
    --dp-border:            #EFF0F2;
    --dp-border-mid:        #DDDDDD;
    --dp-shadow:            0 2px 8px rgba(0,0,0,0.08);

    /* 浮窗专用 — 半透明暗色变体 */
    --overlay-bg:           rgba(255, 255, 255, 0.95);
    --overlay-bg-bar:       rgba(247, 248, 249, 0.98);
    --overlay-text:         rgba(0,0,0,0.9);
    --overlay-text-dim:     rgba(0,0,0,0.35);
    --overlay-text-sec:     rgba(0,0,0,0.6);

    /* 状态色 */
    --state-starting:       #466899;
    --state-recording:      #FF6633;
    --state-recognizing:    #FF6633;
    --state-ai:             #FFA546;
    --state-injecting:      #466899;
    --state-error:          #FF463A;
    --state-done:           #30D158;
  }

  html, body {
    width: 100%; height: 100%;
    overflow: hidden;
    background: transparent;
    font-family: "PingFang SC", "Noto Sans SC", "Microsoft YaHei UI", system-ui, sans-serif;
    color: var(--overlay-text);
    -webkit-font-smoothing: antialiased;
  }

  /* ════ 稳定性：初始隐藏，防白块/黑块 ════ */
  body {
    display: flex;
    flex-direction: column;
    background: transparent !important;
    border: none;
    border-radius: 0;
    overflow: hidden;
    box-shadow: none;
    visibility: hidden;
    opacity: 0;
    transition: opacity 0.4s ease, visibility 0s linear 0.4s;
    width: 100%;
    height: 100%;
  }
  body.visible {
    visibility: visible;
    opacity: 1;
    transition: opacity 0.4s ease, visibility 0s linear 0s;
  }

  /* 内层容器：承载白色背景 + 圆角，body 保持完全透明以消除圆角外白框 */
  /* height: auto — 由 JS 动态设置精确高度，避免填满 Win32 窗口导致底部白色露出 */
  .overlay-shell {
    display: flex;
    flex-direction: column;
    width: 100%;
    height: auto;
    max-height: 100vh;  /* 防止超出屏幕高度 */
    border-radius: 20px;
    overflow: hidden;
    background: var(--overlay-bg);
    box-shadow: 0 8px 32px rgba(0,0,0,0.18), 0 2px 8px rgba(0,0,0,0.10);
  }

  /* ── 状态栏 ── */
  .status-bar {
    display: flex;
    align-items: center;
    padding: 0 12px;
    height: 44px;
    min-height: 44px;
    background: var(--overlay-bg-bar);
    border-radius: 20px 20px 0 0;
    border-bottom: 1px solid var(--dp-border);
    gap: 6px;
    user-select: none;
  }

  /* 脉冲圆点 — 点评橙红为主色 */
  .dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
    transition: background 0.3s, box-shadow 0.3s;
  }
  .dot.starting {
    background: transparent;
    border: 2px solid rgba(70,104,153,0.3);
    border-top-color: var(--state-starting);
    animation: spin-dot 1s linear infinite;
  }
  @keyframes spin-dot {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
  }
  .dot.recording {
    background: var(--dp-primary);
    box-shadow: 0 0 6px rgba(255,102,51,0.35);
    animation: pulse-dot 1.2s ease-in-out infinite;
  }
  .dot.recognizing {
    background: var(--dp-primary);
    box-shadow: 0 0 6px rgba(255,102,51,0.35);
    animation: pulse-dot 1.5s ease-in-out infinite;
  }
  .dot.ai-processing {
    background: var(--state-ai);
    box-shadow: 0 0 6px rgba(255,165,70,0.35);
    animation: pulse-dot 1.5s ease-in-out infinite;
  }
  .dot.injecting {
    background: var(--state-injecting);
    box-shadow: 0 0 6px rgba(70,104,153,0.35);
    animation: pulse-dot 1.2s ease-in-out infinite;
  }
  .dot.error {
    background: var(--state-error);
    box-shadow: 0 0 6px rgba(255,70,58,0.25);
  }
  .dot.done {
    background: var(--state-done);
    box-shadow: 0 0 6px rgba(48,209,88,0.25);
  }

  @keyframes pulse-dot {
    0%, 100% { transform: scale(1); opacity: 1; }
    50% { transform: scale(1.5); opacity: 0.6; }
  }

  /* 状态文字 — 点评字号体系 */
  .status-text {
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 0.2px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 140px;
    flex-shrink: 1;
  }
  .status-text.starting { color: var(--state-starting); }
  .status-text.recording { color: var(--dp-primary); }
  .status-text.recognizing { color: var(--dp-primary); }
  .status-text.ai-processing { color: var(--state-ai); }
  .status-text.injecting { color: var(--state-injecting); }
  .status-text.error { color: var(--state-error); }
  .status-text.done { color: var(--state-done); }

  /* 波形动画 — 品牌色 */
  .wave-container {
    display: flex;
    align-items: center;
    gap: 3px;
    height: 20px;
    margin-left: 2px;
  }
  .wave-bar {
    width: 3px;
    border-radius: 1.5px;
    background: var(--dp-primary);
    transition: height 0.08s ease-out;
  }
  .wave-bar.orange { background: var(--state-ai); }
  .wave-bar.blue { background: var(--state-injecting); }

  /* 模式标签 — 点评胶囊全圆角风格（高度/2） */
  .mode-tag {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 2px 10px;
    height: 20px;
    border-radius: 10px;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.3px;
    white-space: nowrap;
    flex-shrink: 0;
  }
  .mode-tag.A { background: var(--dp-primary-light); color: var(--dp-primary); }
  .mode-tag.B { background: #FFF3E0; color: #E68A00; }
  .mode-tag.C { background: #E8F0FE; color: #466899; }
  .mode-tag.D { background: #E8F5E9; color: #2E8B57; }
  .mode-tag.E { background: #FFF8E1; color: #BF8F00; }
  .mode-tag.F { background: #F3E5F5; color: #7B1FA2; }

  /* ── 内容区 ── */
  .content {
    flex: 1;
    min-height: 0;
    padding: 8px 16px 12px;
    overflow-y: auto;
    overflow-x: hidden;
    overscroll-behavior: contain;
    min-height: 28px;
    max-height: 280px;
    background: var(--dp-bg-card);
  }
  .content::-webkit-scrollbar { width: 3px; height: 3px; }
  .content::-webkit-scrollbar-track { background: transparent; }
  .content::-webkit-scrollbar-thumb {
    background: var(--dp-border-mid);
    border-radius: 1.5px;
  }
  .content.single-line {
    display: flex;
    align-items: center;
    overflow-x: auto;
    overflow-y: hidden;
    white-space: nowrap;
    padding-bottom: 8px;
  }
  .content.single-line::-webkit-scrollbar { width: 0; height: 0; }

  .content-text {
    font-size: 14px;
    line-height: 1.5;
    color: var(--dp-text-1);
    white-space: pre-wrap;
    word-break: break-word;
    padding-bottom: 2px;
  }
  .content.single-line .content-text {
    display: inline-flex;
    align-items: center;
    white-space: nowrap;
    word-break: normal;
    line-height: 1.4;
    min-width: max-content;
    padding-bottom: 0;
  }
  .content-text.dim { color: var(--dp-text-3); }
  .content-text.done-text {
    color: var(--dp-text-2);
    font-size: 13px;
  }

  /* 闪烁光标 — 品牌色 */
  .cursor {
    display: inline-block;
    width: 2px;
    height: 1.1em;
    background: var(--dp-primary);
    margin-left: 1px;
    vertical-align: text-bottom;
    animation: blink-cursor 0.85s steps(1) infinite;
  }
  @keyframes blink-cursor {
    0%, 49% { opacity: 1; }
    50%, 100% { opacity: 0; }
  }

  /* 整体渐隐 */
  body.fade-out {
    visibility: visible !important;
    opacity: 0 !important;
    transition: opacity 0.5s ease !important, visibility 0s linear 0.5s !important;
  }
</style>
</head>
<body>
  <div class="overlay-shell">
  <div class="status-bar">
    <div class="dot" id="dot"></div>
    <span class="status-text" id="statusText">录音中</span>
    <div class="wave-container" id="waveContainer"></div>
    <span class="mode-tag A" id="modeTag">直出</span>
  </div>
  <div class="content">
    <div class="content-text dim" id="contentText">正在聆听...<span class="cursor" id="cursor"></span></div>
  </div>

<script>
var dot = document.getElementById('dot');
var statusText = document.getElementById('statusText');
var waveContainer = document.getElementById('waveContainer');
var modeTag = document.getElementById('modeTag');
var contentText = document.getElementById('contentText');
var cursor = document.getElementById('cursor');
var contentEl = document.querySelector('.content');

var waveAnimId = null;
var currentState = 'idle';
var overlayReadyNotified = false;

function createWaveBars(count, colorClass) {
  waveContainer.innerHTML = '';
  for (var i = 0; i < count; i++) {
    var bar = document.createElement('div');
    bar.className = 'wave-bar' + (colorClass ? ' ' + colorClass : '');
    bar.style.height = '4px';
    waveContainer.appendChild(bar);
  }
}

function animateWave() {
  var bars = waveContainer.querySelectorAll('.wave-bar');
  var t = performance.now() / 1000;
  for (var i = 0; i < bars.length; i++) {
    var h = 4 + 10 * Math.abs(Math.sin(t * 3.5 + i * 0.9));
    bars[i].style.height = h + 'px';
  }
  waveAnimId = requestAnimationFrame(animateWave);
}

function stopWave() {
  if (waveAnimId) { cancelAnimationFrame(waveAnimId); waveAnimId = null; }
  waveContainer.innerHTML = '';
}

function truncate(str, max) {
  if (!str) return '';
  return str.length > max ? '\u2026' + str.slice(-(max - 1)) : str;
}

function keepLatestTextVisible() {
  if (!contentEl) return;
  if (contentEl.classList.contains('single-line')) {
    contentEl.scrollLeft = contentEl.scrollWidth;
    contentEl.scrollTop = 0;
    return;
  }
  contentEl.scrollLeft = 0;
  contentEl.scrollTop = contentEl.scrollHeight;
}

function setContentMode(singleLine) {
  if (!contentEl) return;
  contentEl.classList.toggle('single-line', !!singleLine);
}

function setContent(text, className, showCursor, singleLine) {
  setContentMode(singleLine);
  contentText.className = 'content-text' + (className ? ' ' + className : '');
  contentText.textContent = text;
  if (showCursor) {
    contentText.appendChild(cursor);
    cursor.style.display = '';
  } else {
    cursor.style.display = 'none';
  }
  keepLatestTextVisible();
  scheduleAutoResize();
  // 延迟二次保障滚动到底部：确保在 resize_window 回调后仍能正确滚动
  setTimeout(keepLatestTextVisible, 150);
  setTimeout(keepLatestTextVisible, 350);
}

var _lastResizeH = 0;  // 缓存上次请求的窗口高度，避免不必要的 resize

function autoResize() {
  var content = contentEl;
  var statusBar = document.querySelector('.status-bar');
  var shell = document.querySelector('.overlay-shell');
  if (!content || !statusBar) return;

  // 保存当前滚动位置，防止后续操作导致 scrollTop 丢失
  var savedScrollTop = content.scrollTop;

  var singleLine = content.classList.contains('single-line');
  var contentNatural = singleLine ? 28 : Math.max((contentText.scrollHeight || 0) + 10, 28);
  var contentH = singleLine ? 28 : Math.min(contentNatural, 280);
  content.style.height = contentH + 'px';

  var statusH = Math.max(statusBar.offsetHeight || 0, 44);
  var nextH = statusH + contentH + 28;
  var newH = Math.min(Math.max(nextH, 100), 420);

  // 显式设置 .overlay-shell 高度精确匹配内容，而非依赖 height:100% 填满 Win32 窗口
  // 这样即使 Win32 窗口比内容稍高，白色背景也不会从底部溢出
  if (shell) {
    shell.style.height = newH + 'px';
  }

  // 只有高度真正变化时才调用 resize_window，减少不必要的重绘和 scrollTop 丢失
  if (newH !== _lastResizeH) {
    _lastResizeH = newH;
    try {
      if (window.pywebview && window.pywebview.api) {
        window.pywebview.api.resize_window(newH);
      }
    } catch(e) {}
  }

  // 在所有布局操作完成后恢复滚动位置并滚动到底部
  // 使用 requestAnimationFrame 确保在浏览器完成布局重计算后再操作 scrollTop
  requestAnimationFrame(function() {
    if (savedScrollTop > 0 && content.scrollTop < savedScrollTop) {
      content.scrollTop = savedScrollTop;
    }
    keepLatestTextVisible();
  });
}

function scheduleAutoResize() {
  // 简化为 rAF + 200ms 去抖动，减少快速连续 resize 回调到 Python 的次数
  // 旧版 3 次调用（rAF + 100ms + 250ms）增加了竞态窗口概率
  requestAnimationFrame(autoResize);
  setTimeout(autoResize, 200);
}

function notifyOverlayReady() {
  if (overlayReadyNotified) return;
  overlayReadyNotified = true;
  try {
    if (window.pywebview && window.pywebview.api && window.pywebview.api.overlay_ready) {
      window.pywebview.api.overlay_ready();
    }
  } catch (e) {}
}

function armOverlayReadyNotification() {
  requestAnimationFrame(function() {
    requestAnimationFrame(function() {
      scheduleAutoResize();
      notifyOverlayReady();
    });
  });
  setTimeout(notifyOverlayReady, 300);
}

// ── 被 Python 调用的接口 ──

window.setState = function(state, data) {
  document.body.classList.remove('fade-out');
  document.body.classList.add('visible');
  currentState = state;

  if (state === 'starting') {
    dot.className = 'dot starting';
    statusText.className = 'status-text starting';
    statusText.textContent = '启动中';
    stopWave();
    createWaveBars(3, 'blue');
    animateWave();
    var startingText = (data && data.text) ? data.text : '';
    setContent(startingText || '正在启动语音引擎，请稍候再开始说话...', 'dim', false, false);
    scheduleAutoResize();
  }
  else if (state === 'recording' || state === 'recognizing') {
    dot.className = 'dot recognizing';
    statusText.className = 'status-text recognizing';
    statusText.textContent = '识别中';
    stopWave();
    createWaveBars(3, '');
    animateWave();
    var text = (data && data.text) ? data.text : '';
    setContent(text || '正在聆听...', text ? '' : 'dim', true, false);
    scheduleAutoResize();
  }
  else if (state === 'ai_processing') {
    dot.className = 'dot ai-processing';
    statusText.className = 'status-text ai-processing';
    statusText.textContent = 'AI 处理中';
    stopWave();
    createWaveBars(4, 'orange');
    animateWave();
    var aiText = (data && data.text) ? data.text : '';
    setContent(aiText || '正在润色文本...', '', false, false);
    scheduleAutoResize();
  }
  else if (state === 'injecting') {
    dot.className = 'dot injecting';
    statusText.className = 'status-text injecting';
    statusText.textContent = '注入中';
    stopWave();
    createWaveBars(2, 'blue');
    animateWave();
    var injectingText = (data && data.text) ? data.text : '';
    setContent(injectingText || '正在写入目标窗口...', '', false, false);
    scheduleAutoResize();
  }
  else if (state === 'error') {
    stopWave();
    dot.className = 'dot error';
    statusText.className = 'status-text error';
    statusText.textContent = '处理失败';
    var errorText = (data && data.text) ? data.text : '请查看日志';
    setContent(errorText, 'done-text', false, false);
    scheduleAutoResize();
  }
  else if (state === 'notice') {
    stopWave();
    dot.className = 'dot done';
    statusText.className = 'status-text done';
    statusText.textContent = '模式已切换';
    var noticeText = (data && data.text) ? data.text : '';
    setContent(noticeText, 'done-text', false, false);
    scheduleAutoResize();

    setTimeout(function() {
      document.body.classList.add('fade-out');
      setTimeout(function() {
        try { window.pywebview.api.hide_window(); } catch(e) {}
      }, 550);
    }, 900);
  }
  else if (state === 'done') {
    stopWave();
    dot.className = 'dot done';
    statusText.className = 'status-text done';
    statusText.textContent = '已注入';
    var summary = (data && data.text) ? truncate(data.text, 80) : '';
    setContent(summary, 'done-text', false, false);
    scheduleAutoResize();

    setTimeout(function() {
      document.body.classList.add('fade-out');
      setTimeout(function() {
        try { window.pywebview.api.hide_window(); } catch(e) {}
      }, 550);
    }, 500);
  }
};

window.updateText = function(text) {
  if (currentState === 'starting') {
    window.setState('recognizing', { text: text });
  } else if (currentState === 'recording' || currentState === 'recognizing') {
    window.setState('recognizing', { text: text });
  } else if (currentState === 'ai_processing' || currentState === 'injecting') {
    setContent(text, '', false, true);
  }
};

window.setMode = function(mode) {
  var labels = { A: '直出', B: '润色', C: 'Prompt', D: '翻译', E: '会议纪要', F: '结构化' };
  if (!modeTag) {
    modeTag = document.getElementById('modeTag');
  }
  if (!modeTag) return 'modeTag is null';
  modeTag.textContent = labels[mode] || mode;
  modeTag.className = 'mode-tag ' + mode;
  scheduleAutoResize();
  return 'mode set to ' + mode;
};

// 初始化时先隐藏，等首帧布局完成后通知 Python 可以安全显示
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', armOverlayReadyNotification, { once: true });
} else {
  armOverlayReadyNotification();
}
</script>
  </div><!-- /.overlay-shell -->
</body>
</html>
"""


class _OverlayAPI:
    """pywebview 暴露给 JS 的 API。"""

    def __init__(self, overlay: OverlayWindow) -> None:
        self._overlay = overlay

    def resize_window(self, height: int) -> None:
        try:
            h = max(100, min(WIN_H_MAX, int(height)))
            self._overlay._resize(h)
        except Exception:
            pass

    def hide_window(self) -> None:
        try:
            self._overlay._do_hide_internal()
        except Exception:
            pass

    def overlay_ready(self) -> None:
        try:
            self._overlay._mark_dom_ready()
        except Exception:
            pass


class OverlayWindow:
    """录音状态浮窗 — WebView2 渲染。

    跨线程通过 queue 传递命令，GUI 本身必须在主线程启动。

    使用方式：
        ov = OverlayWindow()
        ov.start()           # 在主线程启动 WebView2（阻塞直到退出）
        ov.show()            # 显示录音中
        ov.update_text("你好")  # 更新识别文字
        ov.hide()            # 完成 → 渐隐
        ov.destroy()         # 销毁

    状态流程：recording → recognizing → done → fade out
    """

    def __init__(self) -> None:
        self._window = None
        self._thread: Optional[threading.Thread] = None
        self._cmd_queue: queue.Queue = queue.Queue()
        self._ready = threading.Event()
        self._dom_ready = threading.Event()
        self._show_waiting_for_dom = False
        self._pending_show_payload = None
        self._destroyed = False
        self._visible = False
        self._current_mode = "A"
        self._current_text = ""
        self._api = _OverlayAPI(self)
        self._screen_cache = None  # (sw, sh)
        # Win32 置顶始终启用（on_top=True 直接传入，不再动态检测）
        self._hwnd_cache: Optional[int] = None  # 缓存窗口句柄
        self._last_hwnd_source: Optional[str] = None
        self._last_topmost_diag_at = 0.0
        self._last_missing_hwnd_log_at = 0.0
        self._last_resize_diag_at = 0.0
        # 裁切区域缓存（DPI-aware 圆角裁切）
        self._cached_region: Optional[int] = None  # 缓存的顶层窗口裁切区域句柄
        self._cached_child_regions: list = []  # 缓存的子窗口裁切区域句柄列表
        self._region_width: int = 0
        self._region_height: int = 0

    # ══════════════════════════════════════════════════════════════════
    # 公开接口（任意线程安全调用）
    # ══════════════════════════════════════════════════════════════════

    def start(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError("OverlayWindow.start() must be called on the main thread")
        self._thread = threading.current_thread()
        self._web_main()

    def show(self, icon: str = "🎙️", state: str = "recording", text: str = "") -> None:
        self._cmd_queue.put((CMD_SHOW, {"icon": icon, "state": state, "text": text}))

    def update_text(self, text: str) -> None:
        self._cmd_queue.put((CMD_UPDATE, text))

    def set_icon(self, icon: str) -> None:
        self._cmd_queue.put((CMD_SET_ICON, icon))

    def set_mode(self, mode: str) -> None:
        self._cmd_queue.put((CMD_SET_MODE, mode))

    def set_state(self, state: str, text: str = "") -> None:
        self._cmd_queue.put((CMD_SET_STATE, {"state": state, "text": text}))

    def hide(self) -> None:
        self._cmd_queue.put((CMD_HIDE, None))

    def dismiss(self) -> None:
        self._cmd_queue.put((CMD_HIDE, {"immediate": True}))

    def destroy(self) -> None:
        self._destroyed = True
        self._cmd_queue.put((CMD_DESTROY, None))

    # ══════════════════════════════════════════════════════════════════
    # WebView2 主循环（必须在主线程运行）
    # ══════════════════════════════════════════════════════════════════

    def _web_main(self) -> None:
        # ── 启动前环境诊断 ──
        try:
            from .diagnose import diagnose_overlay_environment
            diag = diagnose_overlay_environment()
            logger.info("Overlay 启动前诊断: %s", diag["summary"])
            if not diag["overall_ready"]:
                logger.warning("Overlay 环境未完全就绪，继续尝试启动...")
        except Exception as e:
            logger.debug("Overlay 诊断模块异常（不影响启动）: %s", e)

        try:
            import webview
            logger.info("Overlay pywebview 导入成功，版本=%s", getattr(webview, "__version__", "unknown"))

            # 缓存屏幕尺寸
            self._cache_screen_size()
            logger.info(
                "Overlay 创建窗口: size=%sx%s, always_on_top=%s, focus=%s, transparent=%s, frameless=%s",
                WIN_W,
                WIN_H_INIT,
                True,
                False,
                True,
                True,
            )

            window_kwargs = {
                "title": "Spoken",
                "html": OVERLAY_HTML,
                "width": WIN_W,
                "height": WIN_H_INIT,
                "frameless": True,
                "transparent": True,
                "resizable": False,
                "focus": False,
                "js_api": self._api,
                # 注意：不使用 hidden=True，因为某些 pywebview/WebView2 组合下
                # hidden=True 会导致后续 show() 无法显示。
                # 初始隐藏由 _on_shown 回调 + CSS + Win32 透明三重保险完成。
                "on_top": True,
                "easy_drag": False,
            }

            self._window = webview.create_window(**window_kwargs)

            # 注册 shown 事件回调：窗口首次显示时立刻隐藏，防止白块/黑块闪现
            self._window.events.shown += self._on_shown

            logger.info(
                "Overlay pywebview 窗口已创建, on_top=True, hidden=True, events.shown 已注册",
            )

            # DOM ready 超时兜底：如果 JS 回调 3 秒未到达，强制就绪
            self._dom_ready_timer = threading.Timer(3.0, self._dom_ready_timeout)
            self._dom_ready_timer.daemon = True
            self._dom_ready_timer.start()

            # 延迟设置：等待 WebView2 初始化完成后执行初始隐藏 + 圆角裁切
            def _setup_overlay_shape():
                time.sleep(2.0)  # 等待 WebView2 内核完全初始化（过短会导致 Form 异常）
                # 应用圆角裁切区域（无论是否可见，都需要裁切）
                self._apply_rounded_region(WIN_W, WIN_H_INIT)
                # 如果此时浮窗没有被用户触发显示，执行初始隐藏（透明度方式）
                if not self._visible:
                    self._apply_win32_initial_hide()
            threading.Thread(target=_setup_overlay_shape, daemon=True, name="wv2-shape-setup").start()

            # start() 阻塞，func 参数会在 GUI 线程启动后调用
            webview.start(
                debug=False,
                http_server=False,
                func=self._poll_loop,
            )

            # webview.start() 返回后的诊断
            if self._destroyed:
                logger.info("OverlayWindow WebView2 已正常关闭")
            else:
                logger.warning(
                    "OverlayWindow WebView2 主循环提前退出！"
                    "visible=%s, dom_ready=%s, destroyed=%s",
                    self._visible,
                    self._dom_ready.is_set(),
                    self._destroyed,
                )
                # 标记窗口不可用，避免后续操作访问已释放的 Form
                self._window = None
                self._visible = False

        except Exception as e:
            logger.error("OverlayWindow WebView2 异常: %s", e, exc_info=True)
            # 取消可能还在运行的 DOM ready 超时定时器
            timer = getattr(self, "_dom_ready_timer", None)
            if timer:
                timer.cancel()
            self._ready.set()

    def _on_shown(self) -> None:
        """窗口显示后立刻隐藏（初始状态不可见），防止白块/黑块闪现。

        注意：在 transparent=True + edgechromium 模式下，不能调用
        pywebview 的 self._window.hide()，因为底层 WinForms Form.Hide()
        可能触发 Form 关闭/Dispose，导致 webview.start() 提前退出
        （Application.Exit()）。改为仅用 Win32 透明度方式隐藏。
        """
        try:
            # 1. Win32 透明度隐藏（alpha=0，窗口仍存在但不可见）
            self._apply_win32_initial_hide()
            # 2. 延迟二次透明度隐藏，确保 WebView2 渲染完成后仍然不可见
            def _delayed_hide():
                time.sleep(0.5)
                self._apply_win32_initial_hide()
            threading.Thread(target=_delayed_hide, daemon=True, name="overlay-delayed-hide").start()
            self._ready.set()
            self._log_overlay_diag("webview_shown", level=logging.INFO)
            logger.info("OverlayWindow WebView2 就绪（shown 回调已执行透明度隐藏）")
        except Exception as e:
            logger.error("OverlayWindow shown 回调异常: %s", e)
            self._ready.set()

    def _poll_loop(self) -> None:
        """在 WebView2 事件循环中定期检查命令队列，并高频加固可见浮窗置顶。"""
        import time as _time
        last_topmost = 0.0
        while not self._destroyed:
            try:
                processed = 0
                while processed < 10:
                    try:
                        cmd, data = self._cmd_queue.get_nowait()
                    except queue.Empty:
                        break
                    self._dispatch(cmd, data)
                    processed += 1
                now = _time.monotonic()
                if self._visible and now - last_topmost >= TOPMOST_INTERVAL_VISIBLE_SEC:
                    self._apply_win32_topmost(force_show=False)
                    last_topmost = now
            except Exception as e:
                logger.error("Overlay 轮询异常: %s", e)
            _time.sleep(POLL_MS / 1000.0)

    def _dispatch(self, cmd: str, data) -> None:
        try:
            if cmd == CMD_SHOW:
                self._do_show(data)
            elif cmd == CMD_UPDATE:
                self._do_update(data)
            elif cmd == CMD_SET_ICON:
                self._do_set_icon(data)
            elif cmd == CMD_SET_STATE:
                self._do_set_state(data)
            elif cmd == CMD_HIDE:
                self._do_hide(data)
            elif cmd == CMD_DESTROY:
                self._do_destroy()
            elif cmd == CMD_SET_MODE:
                self._do_set_mode(data)
        except Exception as e:
            logger.error("Overlay 命令执行异常: cmd=%s, err=%s", cmd, e)

    # ══════════════════════════════════════════════════════════════════
    # 命令处理
    # ══════════════════════════════════════════════════════════════════

    def _do_show(self, payload=None) -> None:
        state = "recording"
        text = ""
        if isinstance(payload, dict):
            state = str(payload.get("state") or "recording")
            text = str(payload.get("text") or "")
        self._current_text = text
        if not self._dom_ready.is_set():
            if not self._show_waiting_for_dom:
                logger.debug("Overlay DOM 尚未就绪，延迟显示录音浮窗")
                self._show_waiting_for_dom = True
            self._pending_show_payload = payload
            return
        self._show_waiting_for_dom = False
        self._eval_js(f'window.setMode({json.dumps(self._current_mode)})')
        if text:
            safe = json.dumps(text, ensure_ascii=False)
            self._eval_js(f'window.setState({json.dumps(state)}, {{text: {safe}}})')
        else:
            self._eval_js(f'window.setState({json.dumps(state)}, null)')
        self._show_and_position()
        self._log_overlay_diag(f"show_{state}", level=logging.INFO)
        logger.info("Overlay: %s 状态", state)

    def _do_update(self, text: str) -> None:
        self._current_text = text
        safe = json.dumps(text, ensure_ascii=False)
        self._eval_js(f'window.updateText({safe})')

    def _do_set_icon(self, payload) -> None:
        """处理 set_icon 命令（仅设置图标，保留当前状态）。"""
        if isinstance(payload, str) and payload:
            # set_icon 只传图标名，不做状态切换
            self._eval_js(f'window.setIcon({json.dumps(payload)})')

    def _do_set_state(self, payload) -> None:
        """处理 set_state 命令：切换浮窗状态并更新文本。"""
        state = "recognizing"
        text = self._current_text

        if isinstance(payload, dict):
            state = str(payload.get("state") or "recognizing")
            _new_text = payload.get("text")
            if _new_text is not None:
                text = str(_new_text)

        if text:
            self._current_text = text
        elif not self._current_text:
            self._current_text = "识别中..."

        if not self._visible and state in {"notice", "error"} and self._dom_ready.is_set():
            self._eval_js(f'window.setMode({json.dumps(self._current_mode)})')

        safe = json.dumps(self._current_text, ensure_ascii=False)
        self._eval_js(f'window.setState({json.dumps(state)}, {{text: {safe}}})')

        if not self._visible and state in {"notice", "error"} and self._dom_ready.is_set():
            self._show_and_position()

    def _do_hide(self, payload=None) -> None:
        if isinstance(payload, dict) and payload.get("immediate"):
            self._do_hide_internal()
            return

        safe = json.dumps(self._current_text, ensure_ascii=False)
        self._eval_js(f'window.setState("done", {{text: {safe}}})')

    def _do_hide_internal(self) -> None:
        """JS 渐隐完成后回调。"""
        try:
            if self._window:
                self._window.hide()
            self._visible = False
            self._log_overlay_diag("hidden", level=logging.INFO)
        except Exception:
            pass

    def _do_destroy(self) -> None:
        try:
            if self._window:
                self._window.destroy()
                self._window = None
        except Exception:
            pass

    def _do_set_mode(self, mode: str) -> None:
        self._current_mode = mode
        logger.info("浮窗设置模式: %s", mode)
        self._eval_js(f'window.setMode({json.dumps(mode)})')

    # ══════════════════════════════════════════════════════════════════
    # 窗口操作
    # ══════════════════════════════════════════════════════════════════

    def _cache_screen_size(self) -> None:
        """缓存屏幕尺寸。"""
        try:
            import tkinter as tk
            r = tk.Tk()
            self._screen_cache = (r.winfo_screenwidth(), r.winfo_screenheight())
            r.destroy()
        except Exception:
            self._screen_cache = (1920, 1080)

    def _show_and_position(self) -> None:
        if not self._window or not self._dom_ready.is_set():
            return
        try:
            # 恢复窗口透明度（初始隐藏时设为了完全透明）
            self._restore_window_opacity()
            # 先移动到底部，再显示，避免窗口在屏幕中央闪烁后跳到底部
            self._move_center_bottom(WIN_H_INIT)
            self._window.show()
            self._window.resize(WIN_W, WIN_H_INIT)
            # 重置 resize 高度缓存（浮窗重新显示，高度从初始值开始）
            self._last_resize_h = WIN_H_INIT
            self._visible = True
            # Win32 兜底：强制 ShowWindow SW_SHOW，确保窗口真正可见
            if _IS_WINDOWS:
                hwnd = self._get_hwnd()
                if hwnd:
                    try:
                        user32 = ctypes.windll.user32
                        SW_SHOW = 5
                        user32.ShowWindow(hwnd, SW_SHOW)
                    except Exception:
                        pass
            # 重新应用圆角裁切（窗口大小变化后需重新设置）
            self._apply_rounded_region(WIN_W, WIN_H_INIT)
            self._apply_win32_topmost(force_show=True)
            self._log_overlay_diag("show_and_position", level=logging.INFO)
        except Exception as e:
            logger.error("显示浮窗异常: %s", e)

    def _resize(self, height: int) -> None:
        if not self._window:
            return
        try:
            # 高度缓存：与上次一致时跳过 resize，减少不必要的 Win32 调用和重绘
            if hasattr(self, '_last_resize_h') and self._last_resize_h == height:
                return
            self._last_resize_h = height
            self._window.resize(WIN_W, height)
            self._move_center_bottom(height)
            # 重新应用圆角裁切（窗口大小变化后需重新设置）
            # 立即执行一次，裁切顶层窗口（顶层窗口 resize 是同步的）
            self._apply_rounded_region(WIN_W, height)
            # 延迟再执行一次：WebView2 子窗口的 resize 是异步的，
            # 立即执行时子窗口可能还是旧尺寸，导致裁切区域偏小、底部露出白色背景。
            # 延迟 100ms 后子窗口应该已完成 resize，此时重新裁切确保对齐。
            # 为应对顽固的异步问题，再延迟 300ms 执行第三次校正。
            def _delayed_reapply():
                # 第一次延迟：100ms
                time.sleep(0.1)
                if self._visible and not self._destroyed:
                    # 清除缓存标记，确保延迟调用不会被缓存跳过
                    self._region_width = 0
                    self._region_height = 0
                    self._apply_rounded_region(WIN_W, height)
                    
                # 第二次延迟：再等 200ms（总计 300ms），做最后一次确认校正
                time.sleep(0.2)
                if self._visible and not self._destroyed:
                    self._region_width = 0
                    self._region_height = 0
                    self._apply_rounded_region(WIN_W, height)
            threading.Thread(target=_delayed_reapply, daemon=True, name="overlay-delayed-region").start()
            if self._visible:
                self._apply_win32_topmost(force_show=True)
                if self._should_log_diag("_last_resize_diag_at", 2.0):
                    self._log_overlay_diag(f"resize:{height}", level=logging.DEBUG)
        except Exception:
            pass

    def _move_center_bottom(self, height: int) -> None:
        if not self._screen_cache:
            return
        sw, sh = self._screen_cache
        x = (sw - WIN_W) // 2
        y = sh - height - BOTTOM_OFFSET
        try:
            self._window.move(x, y)
        except Exception:
            pass

    def _should_log_diag(self, attr_name: str, interval_sec: float) -> bool:
        now = time.monotonic()
        last = float(getattr(self, attr_name, 0.0) or 0.0)
        if now - last < interval_sec:
            return False
        setattr(self, attr_name, now)
        return True

    def _get_window_title(self, hwnd: int) -> str:
        if not _IS_WINDOWS or not hwnd:
            return ""
        try:
            user32 = ctypes.windll.user32
            buf = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, buf, 256)
            return buf.value
        except Exception:
            return ""

    def _note_hwnd_source(self, source: str, hwnd: int) -> None:
        if self._last_hwnd_source == source and self._hwnd_cache == hwnd:
            return
        self._last_hwnd_source = source
        logger.debug(
            "Overlay hwnd 解析成功: source=%s hwnd=%s title=%r",
            source,
            hwnd,
            self._get_window_title(hwnd),
        )

    def _build_window_diag(self, hwnd: Optional[int]) -> str:
        parts = [
            f"visible={self._visible}",
            f"dom_ready={self._dom_ready.is_set()}",
            f"on_top=True",
        ]
        if not _IS_WINDOWS:
            parts.append(f"hwnd={hwnd}")
            return ", ".join(parts)

        try:
            user32 = ctypes.windll.user32
            parts.append(f"hwnd={hwnd or 0}")
            if hwnd and user32.IsWindow(hwnd):
                exstyle = int(user32.GetWindowLongW(hwnd, -20))
                parts.extend(
                    [
                        f"title={self._get_window_title(hwnd)!r}",
                        f"is_visible={bool(user32.IsWindowVisible(hwnd))}",
                        f"is_iconic={bool(user32.IsIconic(hwnd))}",
                        f"exstyle=0x{exstyle & 0xFFFFFFFF:08X}",
                        f"topmost={bool(exstyle & 0x00000008)}",
                    ]
                )
            else:
                parts.append("window_state=missing")

            fg = int(user32.GetForegroundWindow() or 0)
            parts.append(f"foreground={fg}")
            if fg:
                parts.append(f"foreground_title={self._get_window_title(fg)!r}")
        except Exception as e:
            parts.append(f"diag_error={e}")
        return ", ".join(parts)

    def _log_overlay_diag(
        self,
        reason: str,
        *,
        level: int = logging.DEBUG,
        hwnd: Optional[int] = None,
    ) -> None:
        logger.log(level, "Overlay诊断[%s]: %s", reason, self._build_window_diag(hwnd))

    def _get_hwnd(self) -> Optional[int]:
        """尝试获取窗口句柄（优先用缓存和原生句柄）。"""
        if not self._window:
            return None
        try:
            user32 = ctypes.windll.user32
            if self._hwnd_cache and user32.IsWindow(self._hwnd_cache):
                self._note_hwnd_source("cache", self._hwnd_cache)
                return self._hwnd_cache
            self._hwnd_cache = None

            native = getattr(self._window, "native", None)
            for source, candidate in (
                ("native.Handle", getattr(native, "Handle", None)),
                ("native.handle", getattr(native, "handle", None)),
                ("native.hwnd", getattr(native, "hwnd", None)),
                ("window.Handle", getattr(self._window, "Handle", None)),
                ("window.handle", getattr(self._window, "handle", None)),
                ("window.hwnd", getattr(self._window, "hwnd", None)),
            ):
                if candidate is None:
                    continue
                try:
                    # pythonnet 3.x: System.IntPtr 不支持 int()，需用 ToInt32/ToInt64
                    if hasattr(candidate, "ToInt64"):
                        hwnd = candidate.ToInt64()
                    elif hasattr(candidate, "ToInt32"):
                        hwnd = candidate.ToInt32()
                    else:
                        hwnd = int(candidate)
                except (TypeError, ValueError):
                    hwnd = 0
                if hwnd and user32.IsWindow(hwnd):
                    self._hwnd_cache = hwnd
                    self._note_hwnd_source(source, hwnd)
                    return hwnd

            # 优先按 uid（pywebview 的窗口标识）
            uid = getattr(self._window, "uid", None)
            if uid is not None:
                hwnd = user32.FindWindowW(None, str(uid))
                if hwnd and user32.IsWindow(hwnd):
                    self._hwnd_cache = hwnd
                    self._note_hwnd_source("uid", hwnd)
                    return hwnd
            # 再按标题
            hwnd = user32.FindWindowW(None, "Spoken")
            if hwnd and user32.IsWindow(hwnd):
                self._hwnd_cache = hwnd
                self._note_hwnd_source("title", hwnd)
                return hwnd
            # 枚举所有顶层窗口，匹配标题
            @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
            def enum_callback(hwnd_, _):
                buf = ctypes.create_unicode_buffer(256)
                user32.GetWindowTextW(hwnd_, buf, 256)
                if "Spoken" in buf.value:
                    self._hwnd_cache = hwnd_
                    return False  # 停止枚举
                return True
            user32.EnumWindows(enum_callback, 0)
            if self._hwnd_cache and user32.IsWindow(self._hwnd_cache):
                self._note_hwnd_source("enum", self._hwnd_cache)
                return self._hwnd_cache
            self._hwnd_cache = None
            if self._visible and self._should_log_diag("_last_missing_hwnd_log_at", 2.0):
                logger.warning("Overlay 可见但未获取到 hwnd: %s", self._build_window_diag(None))
            return None
        except Exception as e:
            if self._visible and self._should_log_diag("_last_missing_hwnd_log_at", 2.0):
                logger.warning("Overlay 获取 hwnd 异常: %s", e)
            return None

    def _apply_rounded_region(self, width: int, height: int) -> None:
        """使用 SetWindowRgn 设置圆角裁切区域，消除圆角外的白色方框。

        根本原因：WebView2 窗口是矩形的，CSS border-radius 只裁切 HTML 内容，
        窗口本身的白色背景仍填充整个矩形，导致圆角外出现白色方框。
        更深层原因：pywebview 在 Windows 上使用 WinForms Form + WebView2 子控件
        的层级结构，WebView2 子控件也会创建子窗口，这些子窗口同样是矩形的，
        仅裁切顶层窗口不够，还必须裁切所有子窗口。

        解决方案：用 Win32 CreateRoundRectRgn + SetWindowRgn 让窗口形状
        就是圆角矩形，圆角外的区域根本不属于窗口，自然不显示白色。
        同时枚举所有子窗口，逐一应用相同的圆角裁切。

        DPI-aware：使用 GetDpiForWindow 获取精确 DPI 缩放因子，
        确保圆角半径在任意 DPI 下都与 CSS border-radius 物理像素对齐。
        """
        if not _IS_WINDOWS or not self._window:
            return
        hwnd = self._get_hwnd()
        if not hwnd:
            return

        # 缓存：如果窗口尺寸未变化且已有有效裁切区域，跳过更新以避免闪烁
        if width == self._region_width and height == self._region_height:
            if self._cached_region and self._cached_child_regions:
                return

        try:
            gdi32 = ctypes.windll.gdi32
            user32 = ctypes.windll.user32

            # ── 清理旧的 GDI 区域句柄，防止资源泄漏 ──
            for old_hrgn in self._cached_child_regions:
                try:
                    gdi32.DeleteObject(old_hrgn)
                except Exception:
                    pass
            self._cached_child_regions.clear()

            # 获取窗口实际矩形（含非客户区，与屏幕坐标对齐）
            rect = ctypes.wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            actual_w = rect.right - rect.left
            actual_h = rect.bottom - rect.top

            # 获取 DPI 缩放因子
            dpi = 96  # 默认值
            try:
                if hasattr(user32, 'GetDpiForWindow'):
                    dpi = user32.GetDpiForWindow(hwnd) or 96
            except Exception:
                pass

            scale = dpi / 96.0  # DPI 缩放因子

            # CSS border-radius: 20px 对应的物理像素圆角半径
            radius_px = int(20 * scale)

            # ── 裁切顶层窗口 ──
            hrgn = gdi32.CreateRoundRectRgn(0, 0, actual_w + 1, actual_h + 1, radius_px * 2, radius_px * 2)
            if hrgn:
                user32.SetWindowRgn(hwnd, hrgn, True)
                self._cached_region = hrgn
                self._region_width = width
                self._region_height = height

            # ── 枚举并裁切所有子窗口 ──
            # WebView2 会在 Form 内创建子窗口（如 WebView2 控件窗口），
            # 这些子窗口也是矩形的，会透过圆角裁切区域显示直角半透明背景。
            # 必须对所有子窗口也应用相同的圆角裁切。
            child_hwnds: list = []

            @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
            def _enum_child_callback(child_hwnd, _lparam):
                child_hwnds.append(child_hwnd)
                return True  # 继续枚举

            user32.EnumChildWindows(hwnd, _enum_child_callback, 0)

            for child_hwnd in child_hwnds:
                # 获取子窗口的尺寸
                child_rect = ctypes.wintypes.RECT()
                user32.GetWindowRect(child_hwnd, ctypes.byref(child_rect))
                child_w = child_rect.right - child_rect.left
                child_h = child_rect.bottom - child_rect.top

                if child_w <= 0 or child_h <= 0:
                    continue

                # 创建与子窗口位置和大小匹配的圆角裁切区域
                # 圆角半径与顶层窗口一致，确保视觉对齐
                child_hrgn = gdi32.CreateRoundRectRgn(
                    0, 0, child_w + 1, child_h + 1, radius_px * 2, radius_px * 2,
                )
                if child_hrgn:
                    # SetWindowRgn 使用相对于窗口自身客户区的坐标，
                    # 因此不需要偏移，直接按子窗口大小创建圆角区域即可
                    user32.SetWindowRgn(child_hwnd, child_hrgn, True)
                    self._cached_child_regions.append(child_hrgn)

            logger.debug(
                "Overlay 圆角区域已设置: actual=%dx%d, dpi=%d, scale=%.2f, r=%d, children=%d",
                actual_w, actual_h, dpi, scale, radius_px, len(child_hwnds),
            )
        except Exception as e:
            logger.debug("Overlay 设置圆角区域失败: %s", e)

    def _apply_win32_initial_hide(self) -> None:
        """在 Windows 上用透明度方式隐藏窗口，防止 WebView2 渲染白块/黑块。

        关键：不能使用 ShowWindow(SW_HIDE) 来隐藏窗口！
        在 transparent=True + edgechromium 模式下，SW_HIDE 会触发
        WinForms Form 的关闭流程，导致 webview.start() 提前退出
        （Application.Exit()）。改为使用 SetLayeredWindowAttributes
        将窗口 alpha 设为 0（完全透明），窗口仍存在但不可见。
        """
        if not _IS_WINDOWS or not self._window:
            return
        hwnd = self._get_hwnd()
        if not hwnd:
            logger.debug("Overlay 初始隐藏跳过: 未获取到 hwnd")
            return
        try:
            user32 = ctypes.windll.user32
            # 设置分层窗口 + 完全透明（alpha=0），窗口仍存在但不可见
            GWL_EXSTYLE = -20
            WS_EX_LAYERED = 0x00080000
            LWA_ALPHA = 0x02
            exstyle = int(user32.GetWindowLongW(hwnd, GWL_EXSTYLE))
            if not (exstyle & WS_EX_LAYERED):
                user32.SetWindowLongW(hwnd, GWL_EXSTYLE, exstyle | WS_EX_LAYERED)
            ctypes.windll.user32.SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA)
            logger.debug("Overlay Win32 透明度隐藏已执行: hwnd=%s", hwnd)
        except Exception as e:
            logger.debug("Overlay Win32 初始隐藏失败: %s", e)

    def _restore_window_opacity(self) -> None:
        """恢复窗口完全不透明（在 _show_and_position 时调用，撤销初始隐藏的透明设置）。

        由于初始隐藏现在使用 SetLayeredWindowAttributes(alpha=0) 而非 SW_HIDE，
        恢复时需要：1) 将 alpha 设回 255（完全不透明），2) 确保 SW_SHOW
        （虽然窗口没有被 SW_HIDE，但 pywebview 的 transparent 模式下
        某些内部状态可能需要 SW_SHOW 来激活渲染）。
        """
        if not _IS_WINDOWS or not self._window:
            return
        hwnd = self._get_hwnd()
        if not hwnd:
            return
        try:
            user32 = ctypes.windll.user32
            # 1. 确保 SW_SHOW（窗口可见状态）
            SW_SHOW = 5
            user32.ShowWindow(hwnd, SW_SHOW)
            # 2. 设置分层窗口 + 完全不透明
            GWL_EXSTYLE = -20
            WS_EX_LAYERED = 0x00080000
            LWA_ALPHA = 0x02
            exstyle = int(user32.GetWindowLongW(hwnd, GWL_EXSTYLE))
            if not (exstyle & WS_EX_LAYERED):
                user32.SetWindowLongW(hwnd, GWL_EXSTYLE, exstyle | WS_EX_LAYERED)
            ctypes.windll.user32.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
            logger.debug("Overlay Win32 透明度已恢复: hwnd=%s", hwnd)
        except Exception as e:
            logger.debug("Overlay 恢复透明度失败: %s", e)

    def _dom_ready_timeout(self) -> None:
        """DOM ready 超时兜底：3 秒后 JS 仍未回调，强制标记就绪。"""
        if self._dom_ready.is_set():
            return
        logger.warning("Overlay DOM ready 超时（3秒），强制标记就绪")
        self._mark_dom_ready()

    def _apply_win32_topmost(self, force_show: bool = False) -> None:
        """在 Windows 上用 Win32 API 强制置顶，并尽量不打断当前焦点。"""
        if not _IS_WINDOWS or not self._window:
            return
        # 窗口不可见时跳过心跳置顶（force_show 除外）
        if not force_show and not self._visible:
            return
        hwnd = self._get_hwnd()
        if not hwnd:
            if force_show and self._should_log_diag("_last_missing_hwnd_log_at", 2.0):
                logger.warning("Overlay 置顶跳过: 未获取到 hwnd, force_show=%s", force_show)
            return
        try:
            user32 = ctypes.windll.user32

            # 心跳模式：如果窗口已经是 topmost + visible，跳过 SetWindowPos 调用
            # （避免反复调用导致日志垃圾和性能浪费）
            if not force_show:
                exstyle = int(user32.GetWindowLongW(hwnd, -20))
                is_topmost = bool(exstyle & 0x00000008)
                is_visible = bool(user32.IsWindowVisible(hwnd))
                if is_topmost and is_visible:
                    return  # 已经在 topmost 且可见，无需重复调用

            HWND_TOPMOST = -1
            SWP_NOSIZE = 0x0001
            SWP_NOMOVE = 0x0002
            SWP_NOACTIVATE = 0x0010
            SWP_SHOWWINDOW = 0x0040
            SWP_NOOWNERZORDER = 0x0200
            SWP_ASYNCWINDOWPOS = 0x4000
            flags = SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS
            if force_show or self._visible:
                flags |= SWP_SHOWWINDOW
            ok = bool(
                user32.SetWindowPos(
                    hwnd,
                    HWND_TOPMOST,
                    0,
                    0,
                    0,
                    0,
                    flags,
                )
            )
            if not ok:
                # 限流：SetWindowPos 失败时每 30 秒最多记录一次 WARNING
                if self._should_log_diag("_last_topmost_fail_log_at", 30.0):
                    logger.warning(
                        "Overlay SetWindowPos 返回失败: force_show=%s, %s",
                        force_show,
                        self._build_window_diag(hwnd),
                    )
                return

            exstyle = int(user32.GetWindowLongW(hwnd, -20))
            is_topmost = bool(exstyle & 0x00000008)
            if force_show:
                self._log_overlay_diag("topmost_force", level=logging.INFO, hwnd=hwnd)
            elif self._should_log_diag("_last_topmost_diag_at", 2.0):
                self._log_overlay_diag("topmost_heartbeat", level=logging.DEBUG, hwnd=hwnd)

            if not is_topmost:
                # 限流：TOPMOST 检测失败时每 30 秒最多记录一次 WARNING
                if self._should_log_diag("_last_not_topmost_log_at", 30.0):
                    logger.warning(
                        "Overlay 置顶调用后仍未检测到 TOPMOST: force_show=%s, %s",
                        force_show,
                        self._build_window_diag(hwnd),
                    )
        except Exception as e:
            logger.debug("Overlay Win32 置顶失败: %s", e)

    def _mark_dom_ready(self) -> None:
        pending_show = self._show_waiting_for_dom
        pending_payload = self._pending_show_payload
        self._dom_ready.set()
        self._ready.set()
        self._show_waiting_for_dom = False
        self._pending_show_payload = None
        # 取消超时定时器
        timer = getattr(self, "_dom_ready_timer", None)
        if timer:
            timer.cancel()
        if pending_show:
            self._cmd_queue.put((CMD_SHOW, pending_payload))
        self._log_overlay_diag("dom_ready", level=logging.INFO)
        logger.debug("Overlay DOM 已就绪")

    def _eval_js(self, code: str) -> None:
        if not self._window:
            return
        try:
            self._window.evaluate_js(code)
        except Exception as e:
            logger.debug("eval_js 异常: %s", e)
