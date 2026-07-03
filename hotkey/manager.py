"""
spoken/hotkey/manager.py
全局热键管理器。

使用 keyboard 库注册全局热键，无需管理员权限。
支持两种录音热键模式：
  - PushToTalk（默认）：按住录音，松开停止
  - Toggle（兼容）：按一次开始，再按停止
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Dict, Optional, Set

logger = logging.getLogger(__name__)

# 回调类型别名
HotkeyCallback = Callable[[], None]


class HotkeyManager:
    """全局热键注册与管理。

    使用示例::

        manager = HotkeyManager()
        manager.register("ctrl+alt+m", on_switch_mode)
        manager.start()   # 开始监听
        # ...
        manager.stop()    # 停止监听并解除所有热键

    内部机制：
        keyboard 库在 Windows 上使用低级键盘钩子（WH_KEYBOARD_LL），
        要求安装钩子的线程必须有活跃的消息泵，否则 Windows 会静默移除钩子。
        keyboard 库的消息泵循环存在 bug（while not GetMessage(...)），
        可能在收到第一条消息后就退出，导致钩子长时间空闲后被 Windows 移除。
        本管理器通过定期健康检查自动检测并恢复失效的钩子。
    """

    # 健康检查间隔（秒）
    _HEALTH_CHECK_INTERVAL = 30.0

    def __init__(self) -> None:
        self._hotkeys: Dict[str, HotkeyCallback] = {}  # 热键组合 → 回调
        self._hooks = []      # keyboard.add_hotkey 返回的 hook 句柄
        self._raw_hooks = []  # keyboard.on_press/on_release 返回的 hook 句柄
        self._running = False
        self._lock = threading.Lock()
        self._health_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

    def register(self, combo: str, callback: HotkeyCallback) -> None:
        """注册一个全局热键（press 触发，适合 toggle 类热键）。

        如果热键已注册，会替换原有回调。

        Args:
            combo: 热键组合字符串，如 "ctrl+alt+m"
            callback: 触发时调用的函数（无参数）
        """
        with self._lock:
            self._hotkeys[combo] = callback
            if self._running:
                self._bind(combo, callback)
        logger.debug("已注册热键: %s", combo)

    def unregister(self, combo: str) -> None:
        """解除指定热键的注册。"""
        with self._lock:
            if combo in self._hotkeys:
                del self._hotkeys[combo]
                logger.debug("已解除热键: %s", combo)

    def register_raw_hook(self, hook_fn: Callable) -> None:
        """注册原始键盘 hook（供 PushToTalkHotkey 使用）。

        hook_fn 接受一个 keyboard.KeyboardEvent 参数。
        需在 start() 之前调用。

        Args:
            hook_fn: keyboard.hook() 风格的回调函数
        """
        with self._lock:
            self._raw_hooks.append(hook_fn)

    def start(self) -> None:
        """开始监听所有已注册的热键。"""
        try:
            import keyboard as _kb
            self._kb = _kb
        except ModuleNotFoundError as e:
            if getattr(e, "name", None) == "keyboard":
                raise ImportError(
                    "keyboard 未安装，请运行: pip install keyboard"
                ) from e
            raise ImportError(f"keyboard 导入失败: {e}") from e
        except ImportError as e:
            raise ImportError(f"keyboard 导入失败: {e}") from e

        with self._lock:
            if self._running:
                logger.warning("HotkeyManager 已在运行，忽略重复 start()")
                return
            self._running = True
            self._stop_event.clear()
            for combo, callback in self._hotkeys.items():
                self._bind(combo, callback)
            for hook_fn in self._raw_hooks:
                self._kb.hook(hook_fn, suppress=False)

        # 启动钩子健康检查线程
        self._health_thread = threading.Thread(
            target=self._health_check_loop,
            daemon=True,
            name="hotkey-health-check",
        )
        self._health_thread.start()

        logger.info(
            "热键监听已启动，共注册 %d 个热键 + %d 个原始 hook",
            len(self._hotkeys),
            len(self._raw_hooks),
        )

    def stop(self) -> None:
        """停止监听并解除所有热键注册。"""
        self._stop_event.set()
        with self._lock:
            if not self._running:
                return
            try:
                self._kb.unhook_all()
            except Exception as e:
                logger.error("解除热键失败: %s", e)
            self._hooks.clear()
            self._running = False
        logger.info("热键监听已停止")

    def _health_check_loop(self) -> None:
        """定期检查 keyboard 库的钩子线程是否仍在工作，失效时自动重注册。

        keyboard 库的 _winkeyboard.listen() 使用消息泵循环：
            while not GetMessage(msg, 0, 0, 0):
                TranslateMessage(msg)
                DispatchMessage(msg)
        该循环在收到第一条正常消息后就会退出（GetMessage 返回正数时
        not 正数 = False），导致钩子线程失去消息泵。Windows 会在
        一段时间后静默移除没有消息泵的低级键盘钩子（MSDN 文档说明）。

        健康检查通过检测 keyboard 库内部 listening_thread 的存活状态
        来判断钩子是否失效，失效时重新注册所有热键。
        """
        while not self._stop_event.is_set():
            self._stop_event.wait(timeout=self._HEALTH_CHECK_INTERVAL)
            if self._stop_event.is_set():
                return
            if not self._running:
                return
            try:
                self._check_and_restore_hooks()
            except Exception as e:
                logger.debug("钩子健康检查异常: %s", e)

    def _check_and_restore_hooks(self) -> None:
        """检查钩子是否存活，失效时重新注册所有热键。"""
        try:
            # keyboard 库内部维护了一个 _listener 单例，
            # 其 listening_thread 是运行消息泵的线程。
            # 如果该线程已退出，说明消息泵已停止，钩子很可能已被 Windows 移除。
            listener = getattr(self._kb, '_listener', None)
            if listener is None:
                return

            listening_thread = getattr(listener, 'listening_thread', None)
            if listening_thread is None:
                return

            if listening_thread.is_alive():
                return  # 钩子线程仍在运行，无需恢复

            # 钩子线程已退出，需要重新注册
            # 关键：必须将 listening 标志重置为 False，
            # 否则 start_if_necessary() 会认为已在监听而跳过线程创建。
            listener.listening = False

            logger.warning(
                "keyboard 库钩子线程已退出（消息泵 bug），正在重新注册所有热键..."
            )
            self._rebind_all()

        except Exception as e:
            logger.debug("钩子健康检查失败: %s", e)

    def _rebind_all(self) -> None:
        """重新绑定所有热键（先清除旧的，再重新注册）。"""
        with self._lock:
            if not self._running:
                return
            try:
                self._kb.unhook_all()
            except Exception as e:
                logger.debug("清除旧热钩子失败: %s", e)
            self._hooks.clear()

            # 重新注册所有热键
            for combo, callback in self._hotkeys.items():
                self._bind(combo, callback)
            for hook_fn in self._raw_hooks:
                self._kb.hook(hook_fn, suppress=False)

        logger.info("所有热键已重新注册（钩子恢复完成）")

    def _bind(self, combo: str, callback: HotkeyCallback) -> None:
        """内部方法：绑定单个 add_hotkey 热键。"""
        try:
            hook = self._kb.add_hotkey(combo, callback, suppress=True)
            self._hooks.append(hook)
        except Exception as e:
            logger.error("绑定热键 %s 失败: %s", combo, e)

    @property
    def is_running(self) -> bool:
        """是否正在监听热键。"""
        return self._running

    def __repr__(self) -> str:
        status = "运行中" if self._running else "已停止"
        return f"HotkeyManager({status}, {len(self._hotkeys)} 个热键)"


# ──────────────────────────────────────────────────────────────────────
# Push-to-Talk 热键控制器（主力，v1.2+）
# ──────────────────────────────────────────────────────────────────────

class PushToTalkHotkey:
    """Push-to-Talk 录音热键控制器。

    按住热键 → 触发 on_start（只触发一次，防抖）
    松开热键 → 触发 on_stop

    支持修饰键组合，如 "alt+semicolon"。
    内部使用 keyboard.hook 监听原始键事件，而非 add_hotkey，
    以便区分 press / release。

    使用示例::

        ptt = PushToTalkHotkey(
            combo="alt+semicolon",
            on_start=lambda: print("开始录音"),
            on_stop=lambda: print("停止录音"),
        )
        manager.register_raw_hook(ptt.handle_event)
        manager.start()
    """

    # keyboard 库中修饰键的标准名称
    _MODIFIER_NAMES: Dict[str, Set[str]] = {
        "alt":   {"alt", "left alt", "right alt", "alt gr"},
        "ctrl":  {"ctrl", "left ctrl", "right ctrl"},
        "shift": {"shift", "left shift", "right shift"},
        "win":   {"windows", "left windows", "right windows"},
    }

    def __init__(
        self,
        combo: str,
        on_start: HotkeyCallback,
        on_stop: HotkeyCallback,
    ) -> None:
        """初始化 PTT 热键。

        Args:
            combo: 热键组合，如 "alt+semicolon" 或 "ctrl+alt+r"
                   最后一段为主键，前面均为修饰键。
            on_start: 按下时的回调（只触发一次）
            on_stop:  松开时的回调
        """
        self.combo = combo
        self._on_start = on_start
        self._on_stop = on_stop

        # 解析 combo
        parts = [p.strip().lower() for p in combo.split("+")]
        self._main_key: str = parts[-1]          # 主键名，如 "semicolon" / "r"
        self._modifiers: list[str] = parts[:-1]  # 修饰键列表，如 ["alt"]

        # 状态
        self._recording = False   # 当前是否在录音
        self._lock = threading.Lock()
        self._watcher_thread: Optional[threading.Thread] = None

        logger.debug(
            "PTT 热键初始化: 主键=%s, 修饰键=%s",
            self._main_key,
            self._modifiers,
        )

    # ── 公开属性 ──────────────────────────────────────────────────

    @property
    def is_recording(self) -> bool:
        return self._recording

    def reset(self) -> None:
        """强制重置录音状态（外部中断后调用）。"""
        with self._lock:
            self._recording = False

    # ── 核心事件处理 ──────────────────────────────────────────────

    def handle_event(self, event) -> None:
        """keyboard.hook 回调，处理所有键盘事件。

        Args:
            event: keyboard.KeyboardEvent
        """
        if event.event_type == "down":
            # 仅在主键按下且修饰键满足时开始录音。
            if self._is_main_key(event) and self._modifiers_held():
                self._on_key_down()
            return

        if event.event_type == "up":
            # 录音期间，只要主键或任一必需修饰键松开，就立刻停止。
            if self.is_recording and (
                self._is_main_key(event) or self._is_required_modifier_key(event)
            ):
                self._on_key_up()

    def _on_key_down(self) -> None:
        """主键按下：防抖，只在未录音时触发 on_start。"""
        with self._lock:
            if self._recording:
                # 按住不放会持续触发 down 事件，忽略
                return
            self._recording = True
            logger.debug("PTT: 按下 → 开始录音")

        self._start_release_watcher()
        threading.Thread(target=self._on_start, daemon=True).start()

    def _on_key_up(self) -> None:
        """主键松开：触发 on_stop。"""
        with self._lock:
            if not self._recording:
                # 已被外部 reset（如 Esc 中断），忽略
                return
            self._recording = False
            logger.debug("PTT: 松开 → 停止录音")

        threading.Thread(target=self._on_stop, daemon=True).start()

    def _start_release_watcher(self) -> None:
        """启动按键释放兜底检测，避免漏掉 keyup 导致一直录音。"""
        with self._lock:
            if self._watcher_thread and self._watcher_thread.is_alive():
                return

        def _watch() -> None:
            try:
                import keyboard as _kb
            except Exception:
                return

            while True:
                with self._lock:
                    if not self._recording:
                        return

                try:
                    main_pressed = _kb.is_pressed(self._main_key)
                except Exception:
                    main_pressed = False

                if not main_pressed or not self._modifiers_held():
                    logger.debug("PTT: 轮询检测到按键已松开 → 停止录音")
                    self._on_key_up()
                    return

                time.sleep(0.02)

        self._watcher_thread = threading.Thread(
            target=_watch,
            daemon=True,
            name="ptt-release-watch",
        )
        self._watcher_thread.start()

    # ── 辅助方法 ──────────────────────────────────────────────────

    def _is_main_key(self, event) -> bool:
        """判断事件是否对应主键。"""
        name = (event.name or "").lower()
        return name == self._main_key

    def _is_required_modifier_key(self, event) -> bool:
        """判断事件是否对应任一必需修饰键。"""
        name = (event.name or "").lower()
        for mod in self._modifiers:
            aliases = self._MODIFIER_NAMES.get(mod, {mod})
            if name in aliases:
                return True
        return False

    def _modifiers_held(self) -> bool:
        """检查所有要求的修饰键是否被按住。"""
        try:
            import keyboard as _kb
            for mod in self._modifiers:
                aliases = self._MODIFIER_NAMES.get(mod, {mod})
                if not any(_kb.is_pressed(alias) for alias in aliases):
                    return False
            return True
        except Exception:
            return False


# ──────────────────────────────────────────────────────────────────────
# Toggle 热键控制器（兼容保留，v1.1 及之前行为）
# ──────────────────────────────────────────────────────────────────────

class ToggleRecordHotkey:
    """Toggle 录音热键控制器（兼容保留）。

    封装 toggle 模式逻辑：
    - 按一次热键 → 触发 on_start 回调
    - 再按一次 → 触发 on_stop 回调

    使用示例::

        toggle = ToggleRecordHotkey(
            combo="ctrl+alt+r",
            on_start=lambda: print("开始录音"),
            on_stop=lambda: print("停止录音"),
        )
        manager.register(toggle.combo, toggle.handle)
    """

    def __init__(
        self,
        combo: str,
        on_start: HotkeyCallback,
        on_stop: HotkeyCallback,
    ) -> None:
        self.combo = combo
        self._on_start = on_start
        self._on_stop = on_stop
        self._recording = False
        self._lock = threading.Lock()

    def handle(self) -> None:
        """处理热键触发事件（注册到 HotkeyManager 的实际回调）。"""
        with self._lock:
            if self._recording:
                self._recording = False
                logger.debug("Toggle: 停止录音")
                threading.Thread(target=self._on_stop, daemon=True).start()
            else:
                self._recording = True
                logger.debug("Toggle: 开始录音")
                threading.Thread(target=self._on_start, daemon=True).start()

    def reset(self) -> None:
        """重置 toggle 状态（如录音被强制中断后调用）。"""
        with self._lock:
            self._recording = False

    @property
    def is_recording(self) -> bool:
        return self._recording
