"""
spoken/__main__.py
Spoken 主入口 — 串联所有模块。

启动流程：
  1. 初始化日志
  2. 加载配置（config/settings.py）
  3. 初始化 ASR 引擎（Windows 原生 / 讯飞实时）
  4. 初始化文本注入器
  5. 初始化 AI 处理器
  6. 构建流水线（Pipeline）和状态控制器（StateController）
  7. 注册全局热键
  8. 启动系统托盘
  9. 事件循环：热键触发 → 录音 → Pipeline(ASR → AI → 注入)
  10. 优雅退出

架构说明：
  SpokenApp 只负责模块初始化和事件分发，
  核心业务逻辑在 Pipeline（pipeline.py）中，
  状态管理在 StateController（state.py）中。

运行方式：
    python -m spoken
    python -m spoken --config C:\\MyConfig\\config.toml
    python -m spoken --mode B
    python -m spoken --log-level DEBUG
"""

from __future__ import annotations

import sys

# ══════════════════════════════════════════════════════════════════════
# Windows OpenSSL Applink 全局补丁 —— 必须在所有第三方库导入之前执行
# Python 3.12 (uv build) 中 ssl.create_default_context() 在 C 层直接 abort，
# 无法被 try/except 捕获。后续 httpx/urllib3/websockets 都会调用它，
# 因此必须在入口点全局替换为安全的实现。
# ══════════════════════════════════════════════════════════════════════
if sys.platform == "win32":
    import ssl as _ssl

    def _safe_create_default_context(*args, **kwargs):
        ctx = _ssl.SSLContext(_ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = True
        ctx.verify_mode = _ssl.CERT_REQUIRED
        ctx.load_default_certs()
        return ctx

    _ssl.create_default_context = _safe_create_default_context

import argparse
import logging
import os
import signal
import threading
from pathlib import Path
from typing import Optional

# Windows 系统提示音（模式切换反馈）
if sys.platform == "win32":
    import winsound

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 主应用类
# ══════════════════════════════════════════════════════════════════════

class SpokenApp:
    """Spoken 应用主类，负责初始化和协调所有模块。

    生命周期::

        app = SpokenApp()
        app.setup(config_path=None, initial_mode="A")
        app.run()   # 阻塞，直到用户退出
    """

    def __init__(self) -> None:
        # 各模块实例，setup() 后才可用
        self._settings = None
        self._asr_engine = None
        self._audio_capture = None
        self._dispatcher = None
        self._ai_processor = None
        self._hotkey_manager = None
        self._toggle_hotkey = None
        self._tray_icon = None
        self._paused = False  # 暂停状态（暂停时热键不响应）

        # 中断信号：Esc 按下时设置，由正在运行的流程自行检查并优雅退出
        self._interrupt_requested = False

        # ASR 模式："realtime" 或 "batch"
        self._asr_mode: str = "realtime"

        # 退出事件
        self._quit_event = threading.Event()

        # 实时识别浮窗
        self._overlay = None

        # ── 新架构：流水线 + 状态控制器 ──────────────────────────
        self._pipeline = None      # Pipeline 实例
        self._state_ctrl = None    # StateController 实例

        # ──────────────────────────────────────────────────────────────────
        # 初始化
        # ──────────────────────────────────────────────────────────────────

    def setup(
        self,
        config_path: Optional[Path] = None,
        initial_mode: Optional[str] = None,
        log_level: Optional[str] = None,
    ) -> None:
        """初始化所有模块。

        Args:
            config_path: 自定义配置文件路径，None 使用默认路径
            initial_mode: 覆盖配置文件中的默认模式（A-F）
            log_level: 覆盖日志级别

        Raises:
            SystemExit: 初始化失败时退出
        """
        # ── 1. 加载配置 ────────────────────────────────────────────
        self._setup_config(config_path)

        # ── 2. 初始化日志 ──────────────────────────────────────────
        self._setup_logging(override_level=log_level)

        logger.info("=" * 60)
        logger.info("Spoken 启动中...")
        logger.info("配置文件: %s", self._settings.user_config_path)

        # 输出脱敏后的配置摘要（仅 DEBUG 级别）
        from .config.settings import mask_sensitive
        logger.debug("当前配置（脱敏）: %s", mask_sensitive(self._settings._config))

        # ── 3. 初始化状态控制器 ────────────────────────────────────
        from .state import StateController
        initial = initial_mode or self._settings.get("mode", "default", default="A")
        if initial not in ("A", "B", "C", "D", "E", "F"):
            logger.warning("无效的默认模式: %s，使用 A", initial)
            initial = "A"
        self._state_ctrl = StateController(
            initial_mode=initial,
            settings=self._settings,
        )
        logger.info("初始模式: %s", initial)

        # ── 4. 初始化 ASR 引擎 ────────────────────────────────────
        self._setup_asr()
        # 降级同步：如果实际引擎与配置不一致，更新配置和托盘初始状态
        self._sync_actual_engine_to_config()

        # ── 5. 初始化录音器 ────────────────────────────────────────
        self._setup_audio()

        # ── 6. 初始化文本注入器 ───────────────────────────────────
        self._setup_injector()

        # ── 7. 初始化 AI 处理器 ───────────────────────────────────
        self._setup_ai()

        # ── 8. 构建流水线 ─────────────────────────────────────────
        self._setup_pipeline()

        # ── 9. 注册热键 ────────────────────────────────────────────
        self._setup_hotkeys()

        # ── 10. 初始化系统托盘 ─────────────────────────────────────
        self._setup_tray()

        # ── 11. 初始化实时识别浮窗 ────────────────────────────────
        self._setup_overlay()

        # ── 12. 启动自检 ──────────────────────────────────────────
        self._run_health_check()

        logger.info("Spoken 初始化完成，等待热键触发...")

    def _setup_config(self, config_path: Optional[Path]) -> None:
        """加载配置文件，并自动修复已知的遗留配置问题。"""
        from .config.settings import Settings
        try:
            self._settings = Settings.load(user_config_path=config_path)
        except FileNotFoundError as e:
            print(f"[ERROR] 默认配置文件缺失: {e}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"[ERROR] 配置加载失败: {e}", file=sys.stderr)
            sys.exit(1)

        # 自动修复已知的遗留配置问题
        self._fix_legacy_config()

    def _fix_legacy_config(self) -> None:
        """自动修复已知的遗留配置问题。

        修复列表：
        1. toggle_record 从 "win+space" 改为 "alt+r"
           （旧版本默认快捷键与系统输入法切换冲突）
        """
        if not self._settings:
            return

        # 修复旧版快捷键：win+space → alt+r
        current_hotkey = self._settings.get("hotkey", "toggle_record", default="alt+r")
        if current_hotkey == "win+space":
            logger.info("检测到遗留快捷键配置: toggle_record=win+space，自动修复为 alt+r")
            self._settings.set_and_save_async("hotkey", "toggle_record", "alt+r")

    def _setup_logging(self, override_level: Optional[str] = None) -> None:
        """初始化日志系统。"""
        from .utils.logger import setup_logging
        log_cfg = self._settings.get_section("log")
        level = override_level or log_cfg.get("level", "INFO")
        log_file = log_cfg.get("file", "")
        max_size_mb = int(log_cfg.get("max_size_mb", 10))
        backup_count = int(log_cfg.get("backup_count", 3))

        try:
            setup_logging(
                level=level,
                log_file=log_file or None,
                max_size_mb=max_size_mb,
                backup_count=backup_count,
            )
        except Exception as e:
            logging.basicConfig(level=logging.INFO)
            logger.error("日志初始化失败（使用基础配置）: %s", e)

    def _setup_asr(self) -> None:
        """初始化 ASR 引擎。

        支持 3 条实时识别路径：
          1. meituan   → 美团内部 ASR 服务（WebSocket）
          2. xunfei    → 讯飞实时转写（云端 WebSocket）
          3. windows   → Windows 原生 SpeechRecognizer
        """
        from .asr.factory import load_windows_engine, load_xunfei_engine

        asr_cfg = self._settings.get_section("asr")
        self._asr_mode = "realtime"
        provider = str(asr_cfg.get("realtime_provider", "xunfei")).lower()
        self._asr_engine = None

        # V3: 支持 meituan 引擎及降级策略
        load_plans = {
            "meituan": ["meituan", "xunfei", "windows"],
            "xunfei": ["xunfei", "windows"],
            "windows": ["windows", "xunfei"],
        }
        plan = load_plans.get(provider)
        if plan is None:
            logger.warning("未知 realtime_provider=%s，回退按 xunfei 策略加载", provider)
            plan = load_plans["xunfei"]

        for p in plan:
            if p == "windows":
                logger.info("尝试 Windows 原生语音识别...")
                engine = load_windows_engine(
                    asr_cfg,
                    on_partial_text=self._on_partial_text,
                    on_final_text=self._on_final_text_callback,
                )
            elif p == "meituan":
                logger.info("尝试美团内部 ASR...")
                engine = self._load_meituan_engine(asr_cfg)
            else:
                logger.info("尝试讯飞实时转写...")
                engine = load_xunfei_engine(
                    asr_cfg,
                    on_partial_text=self._on_partial_text,
                    on_final_text=self._on_final_text_callback,
                )

            if engine is not None:
                self._asr_engine = engine
                logger.info("[OK] 主引擎就绪: %s", engine)
                return

        logger.error("所有 ASR 引擎均加载失败")
        sys.exit(1)

    def _load_meituan_engine(self, asr_cfg: dict):
        """加载美团 ASR 引擎。"""
        try:
            from .asr.meituan_asr import MeituanASREngine

            mt_cfg = asr_cfg.get("meituan", {})
            engine = MeituanASREngine(
                endpoint=mt_cfg.get("endpoint", "wss://asr.sankuai.com/v1/realtime"),
                app_key=mt_cfg.get("app_key", ""),
                app_secret=mt_cfg.get("app_secret", ""),
                language=asr_cfg.get("language", "zh"),
                max_duration=mt_cfg.get("max_duration_sec", 3600),
                on_partial_text=self._on_partial_text,
                on_final_text=self._on_final_text_callback,
            )
            engine.load()
            return engine
        except Exception as e:
            logger.warning("美团 ASR 引擎加载失败: %s", e)
            return None

    def _sync_actual_engine_to_config(self, requested: str = "") -> str:
        """根据实际加载的引擎同步配置和托盘状态，处理降级场景。

        Returns:
            实际加载的 provider 名（"meituan"/"xunfei"/"windows"）
        """
        engine_class_to_provider = {
            "MeituanASREngine": "meituan",
            "XunfeiRealtimeEngine": "xunfei",
            "WindowsSpeechEngine": "windows",
        }
        actual_name = type(self._asr_engine).__name__ if self._asr_engine else ""
        actual = engine_class_to_provider.get(actual_name, requested or "xunfei")
        requested = requested or self._settings.get("asr", "realtime_provider", "xunfei")
        if actual != requested:
            logger.info("引擎降级同步: 请求 %s, 实际 %s", requested, actual)
            self._settings._config["asr"] = self._settings._config.get("asr", {})
            self._settings._config["asr"]["realtime_provider"] = actual
            if self._tray_icon:
                self._tray_icon.set_engine(actual)
                # 降级时弹出托盘通知，避免用户困惑
                reason = ""
                if requested == "meituan":
                    reason = "美团 ASR 未配置 app_key/app_secret"
                elif requested == "windows":
                    reason = "Windows 语音识别未授权或缺少 winsdk"
                elif requested == "xunfei":
                    reason = "讯飞 ASR 未配置密钥或缺少 websockets"
                self._tray_icon.notify(
                    "引擎已降级",
                    f"{reason}，已自动降级到 {actual} 引擎继续工作。",
                )
        return actual

    def _setup_audio(self) -> None:
        """初始化录音器（batch 模式已移除，此模块当前仅作兼容性保留）。"""
        try:
            from .audio.capture import AudioCapture
            audio_cfg = self._settings.get_section("audio")
            self._audio_capture = AudioCapture(
                device_index=int(audio_cfg.get("device_index", -1)),
                sample_rate=int(audio_cfg.get("sample_rate", 16000)),
                channels=int(audio_cfg.get("channels", 1)),
                sample_width=int(audio_cfg.get("sample_width", 2)),
                chunk_size=int(audio_cfg.get("chunk_size", 1024)),
            )
            logger.info("录音器已初始化")
        except Exception as e:
            logger.warning("录音器初始化失败（当前仅 realtime 模式，不影响核心功能）: %s", e)
            self._audio_capture = None

    def _setup_injector(self) -> None:
        """初始化文本注入器。"""
        from .injector.dispatcher import TextDispatcher
        injection_cfg = self._settings.get_section("injection")
        self._dispatcher = TextDispatcher.from_config(injection_cfg)
        logger.info("文本注入器已初始化（方案: %s）", injection_cfg.get("method", "auto"))

    def _setup_ai(self) -> None:
        """初始化 AI 处理器。"""
        ai_cfg = self._settings.get_section("ai")
        ai_enabled = bool(ai_cfg.get("enabled", False))
        default_mode = self._settings.get("mode", "default", default="A")

        if not ai_enabled:
            self._ai_processor = None
            logger.info(
                "AI 启动摘要: enabled=%s, key_source=%s, model=%s, base_url=%s, default_mode=%s",
                False,
                "disabled",
                "-",
                "-",
                default_mode,
            )
            logger.info("AI 润色已禁用，Mode B-F 将直接使用原始识别结果")
            return

        from .ai.processor import AIProcessor
        mode_cfg = self._settings.get_section("mode")
        self._ai_processor = AIProcessor.from_config(ai_cfg, mode_config=mode_cfg)

        key_source = {
            "environment": "environment (SPOKEN_AI_API_KEY)",
            "config": "config ([ai].api_key)",
            "missing": "missing",
        }.get(self._ai_processor.key_source, self._ai_processor.key_source)
        logger.info(
            "AI 启动摘要: enabled=%s, key_source=%s, model=%s, base_url=%s, default_mode=%s",
            True,
            key_source,
            self._ai_processor.model_name,
            self._ai_processor.base_url,
            default_mode,
        )

        if not self._ai_processor.is_enabled():
            logger.warning(
                "AI 润色已在配置中启用，但未找到 API Key。"
                "请设置环境变量 SPOKEN_AI_API_KEY。"
                "当前将在 Mode B-F 下自动降级为 Mode A。"
            )
        logger.info("AI 处理器已初始化: %s", self._ai_processor)

    def _setup_pipeline(self) -> None:
        """构建处理流水线（核心业务逻辑）。"""
        from .pipeline import Pipeline
        self._pipeline = Pipeline(
            asr_engine=self._asr_engine,
            audio_capture=self._audio_capture,
            ai_processor=self._ai_processor,
            dispatcher=self._dispatcher,
            overlay=self._overlay,
            state_listener=self._state_ctrl,
            asr_mode=self._asr_mode,
            current_mode=self._state_ctrl.mode_str,
            language=self._settings.get("asr", "language", default="zh"),
            interrupt_checker=lambda: getattr(self, "_interrupt_requested", False),
        )
        logger.info("处理流水线已构建（模式: %s）", self._asr_mode)

    def _setup_hotkeys(self) -> None:
        """注册全局热键。"""
        from .hotkey.manager import HotkeyManager, PushToTalkHotkey, ToggleRecordHotkey
        hotkey_cfg = self._settings.get_section("hotkey")

        record_combo    = str(hotkey_cfg.get("toggle_record", "alt+r"))
        switch_combo    = str(hotkey_cfg.get("switch_mode",   "alt+m"))
        interrupt_combo = str(hotkey_cfg.get("interrupt",     "esc"))
        record_mode = str(hotkey_cfg.get("record_mode", "toggle")).strip().lower()

        self._hotkey_manager = HotkeyManager()

        if record_mode in ("push_to_talk", "push", "hold", "ptt"):
            self._toggle_hotkey = PushToTalkHotkey(
                combo=record_combo,
                on_start=self._on_record_start,
                on_stop=self._on_record_stop,
            )
            self._hotkey_manager.register_raw_hook(self._toggle_hotkey.handle_event)
            record_mode_label = "按住说话"
        else:
            self._toggle_hotkey = ToggleRecordHotkey(
                combo=record_combo,
                on_start=self._on_record_start,
                on_stop=self._on_record_stop,
            )
            self._hotkey_manager.register(record_combo, self._toggle_hotkey.handle)
            record_mode_label = "切换录音"

        self._hotkey_manager.register(switch_combo, self._on_switch_mode)
        self._hotkey_manager.register(interrupt_combo, self._on_interrupt)

        try:
            self._hotkey_manager.start()
            logger.info(
                "热键已注册: 录音(%s)=%s, 切换模式=%s, 中断=%s",
                record_mode_label, record_combo, switch_combo, interrupt_combo,
            )
        except ImportError as e:
            if "keyboard 未安装" in str(e):
                logger.error("热键注册失败（keyboard 库未安装）: %s", e)
                logger.error("请运行: pip install keyboard")
            else:
                logger.error("热键注册失败（keyboard 导入异常）: %s", e)
            sys.exit(1)
        except Exception as e:
            logger.error("热键注册失败（可能需要管理员权限）: %s", e)
            logger.warning("程序将继续运行，但热键可能不可用")

    def _setup_overlay(self) -> None:
        """初始化实时识别浮窗（WebView2 渲染）。

        策略：创建 OverlayWindow 对象，但不在此时启动 WebView。
        WebView2 的 start() 必须在主线程调用，
        将在 run() 中通过 start_webview() 在主线程启动。
        """
        # 先进行环境诊断，提前发现 WebView2 / pythonnet 缺失
        try:
            from .overlay.diagnose import diagnose_overlay_environment, get_webview2_download_url
            diag = diagnose_overlay_environment()
            if not diag["overall_ready"]:
                logger.warning("浮窗环境未就绪，跳过创建: %s", diag["summary"])
                if sys.platform == "win32":
                    webview2 = diag.get("webview2", {})
                    if not webview2.get("installed"):
                        logger.warning(
                            "WebView2 Runtime 未安装，浮窗将无法显示。"
                            "请下载安装: %s",
                            get_webview2_download_url(),
                        )
                self._overlay = None
                return
        except Exception as e:
            logger.debug("浮窗环境诊断失败（继续尝试创建）: %s", e)

        try:
            from .overlay.window import OverlayWindow
            self._overlay = OverlayWindow()
            # 先同步到 Pipeline，确保录音回调能找到 overlay
            if self._pipeline:
                self._pipeline.set_overlay(self._overlay)
        except Exception as e:
            logger.warning("浮窗对象创建失败: %s", e, exc_info=True)
            self._overlay = None
            return

        # 注册为状态观察者
        if self._state_ctrl and self._overlay:
            self._state_ctrl.add_observer(_OverlayAdapter(self._overlay))
            logger.info("浮窗对象已创建，将在主线程启动 WebView2")

    def _setup_tray(self) -> None:
        """初始化并启动系统托盘图标。"""
        from .tray.icon import TrayIcon
        tray_cfg = self._settings.get_section("tray")

        # 获取当前 ASR 引擎配置
        asr_cfg = self._settings.get_section("asr")
        current_engine = str(asr_cfg.get("realtime_provider", "xunfei")).lower()

        self._tray_icon = TrayIcon(
            on_mode_change=self._on_tray_mode_change,
            on_quit=self._on_quit,
            on_view_log=self._on_view_log,
            on_pause_resume=self._on_pause_resume,
            on_engine_change=self._on_engine_change,
            initial_mode=self._state_ctrl.mode_str,
            initial_engine=current_engine,
            show_mode_indicator=bool(tray_cfg.get("show_mode_indicator", True)),
            done_flash_ms=int(tray_cfg.get("done_flash_ms", 1500)),
        )

        # 注册为状态观察者
        if self._state_ctrl:
            self._state_ctrl.add_observer(_TrayAdapter(self._tray_icon))

        try:
            self._tray_icon.start()
            logger.info("系统托盘图标已启动")
        except ImportError as e:
            logger.warning("pystray/Pillow 未安装，托盘图标不可用: %s", e)
            logger.warning("程序将继续运行（无托盘图标）。运行: pip install pystray Pillow")
        except Exception as e:
            logger.warning("托盘图标启动失败，程序继续运行: %s", e)

    def _run_health_check(self) -> None:
        """启动自检：验证关键模块是否就绪。"""
        issues = []

        if not self._asr_engine or not self._asr_engine.is_loaded:
            issues.append("ASR 引擎未加载")

        if not self._dispatcher:
            issues.append("文本注入器未初始化")

        # 检查管理员权限
        if sys.platform == "win32":
            try:
                import ctypes
                is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
                if not is_admin:
                    issues.append("未以管理员权限运行（向提权窗口注入可能失败）")
            except Exception:
                pass

        # 检查麦克风
        try:
            from .audio.devices import get_default_device
            default_dev = get_default_device("pyaudio")
            if default_dev is None:
                issues.append("未检测到麦克风设备")
        except Exception:
            issues.append("无法检测麦克风设备（PyAudio 可能未安装）")

        if issues:
            logger.warning("启动自检发现 %d 个问题:", len(issues))
            for issue in issues:
                logger.warning("  [WARN] %s", issue)
        else:
            logger.info("启动自检通过 [OK]")

    # ──────────────────────────────────────────────────────────────────
    # 事件处理回调
    # ──────────────────────────────────────────────────────────────────

    def _on_partial_text(self, text: str) -> None:
        """流式识别 partial result 回调（仅 realtime 模式）。"""
        logger.info("[流式识别中] %s", text)
        if self._overlay and text:
            self._overlay.update_text(text)
    def _on_final_text_callback(self, text: str) -> None:
        """流式识别 final result 回调（仅 realtime 模式）。"""
        logger.info("[流式识别完成] %s", text[:60] if text else "(空)")

    def _on_record_start(self) -> None:
        """录音开始回调（热键按下时触发）。"""
        # 清除中断标志，确保新录音流程不受上次 Esc 残留影响
        self._interrupt_requested = False

        # 暂停模式下忽略热键
        if self._paused:
            logger.debug("Spoken 已暂停，忽略录音热键")
            if self._toggle_hotkey:
                self._toggle_hotkey.reset()
            return

        # Pipeline 处理中时忽略录音热键，避免在 B/C 模式下误把 AI 处理打断。
        # 如需主动中断，统一使用 Esc，避免 Toggle 模式下的误触造成“看起来像没生效”。
        if self._pipeline and self._pipeline.is_processing:
            current_state = self._state_ctrl.state.value if self._state_ctrl else "unknown"
            if current_state == "ai_processing":
                logger.info("AI 处理中，忽略录音热键；如需中断请按 Esc")
                if self._overlay:
                    self._overlay.set_state("ai_processing", text="AI 处理中，按 Esc 可中断")
            elif current_state == "injecting":
                logger.info("正在注入文字，忽略本次录音触发")
                if self._overlay:
                    self._overlay.set_state("injecting", text="正在写入目标窗口，请稍候...")
            else:
                logger.info("Pipeline 仍在处理中，忽略本次录音触发")
                if self._overlay:
                    self._overlay.set_state("recognizing", text="上一条语音仍在处理中，请稍候...")
            if self._toggle_hotkey:
                self._toggle_hotkey.reset()
            return

        # ASR 引擎状态检查：若被卸载或回退失败清除，重新初始化
        if self._asr_engine is None:
            logger.info("ASR 引擎未加载，尝试重新初始化...")
            try:
                self._setup_asr()
            except Exception as e:
                logger.error("ASR 引擎重新初始化失败: %s", e)
                self._handle_record_error("引擎初始化失败，请检查配置")
                return

        # 通过 Pipeline 防并发
        if not self._pipeline.try_start():
            if self._toggle_hotkey:
                self._toggle_hotkey.reset()
            return

        # 记录当前焦点窗口（用于后续注入）
        if self._dispatcher:
            self._dispatcher.capture_focus()

        startup_text = "正在启动语音引擎..."

        # 统一状态流程：启动中 -> 识别中 -> AI处理中 -> 注入中
        self._state_ctrl.set_state("starting")

        # 显示识别浮窗（立刻显示，不等 ASR 启动）
        if self._overlay:
            logger.info("调用 overlay.show(), overlay=%s", self._overlay)
            self._overlay.show(icon="🎙️", state="starting", text=startup_text)
            self._overlay.set_mode(self._state_ctrl.mode_str)
        else:
            logger.warning("浮窗对象为 None，跳过显示")

        # 在后台线程启动 ASR，避免阻塞浮窗显示
        def _start_asr_async():
            _fallback_succeeded = False
            try:
                self._asr_engine.start()
                # 启动完成后进入识别中状态
                self._state_ctrl.set_state("recognizing")
                if self._overlay:
                    self._overlay.set_state("recognizing")
                logger.info("【流式录音开始】等待用户说话...")

                # 录音启动成功
            except OSError as e:
                # Windows 语音策略未同意等系统级错误
                logger.error("流式录音启动失败: %s", e)
                err_str = str(e)
                error_hint = "录音启动失败，请重试"
                if '0x80045509' in err_str:
                    error_hint = "语音识别未授权，请在 Windows 设置中开启在线语音识别"
                    logger.error(
                        "Windows 在线语音识别策略未同意。"
                        "请打开 Windows 设置 → 隐私和安全性 → 语音 → 开启「在线语音识别」，"
                        "或将 config.toml 中 [asr] realtime_provider 改为 \"xunfei\"。"
                    )
                elif 'microphone' in err_str.lower() or '麦克风' in err_str:
                    error_hint = "无法访问麦克风，请检查麦克风权限"
                else:
                    # 尝试回退到讯飞引擎
                    if self._try_fallback_to_xunfei():
                        _fallback_succeeded = True
                        return
                self._handle_record_error(error_hint)
            except Exception as e:
                logger.error("流式录音启动失败: %s", e)
                error_hint = "录音启动失败，请重试"
                err_str = str(e).lower()
                if 'microphone' in err_str or '麦克风' in err_str or 'audio' in err_str:
                    error_hint = "无法访问麦克风，请检查麦克风权限"
                elif 'permission' in err_str or '权限' in err_str:
                    error_hint = "权限不足，请以管理员身份运行"
                else:
                    # Windows 引擎各类超时/异常 → 尝试回退到讯飞
                    if self._try_fallback_to_xunfei():
                        _fallback_succeeded = True
                        return
                    error_hint = "录音启动失败，建议切换到讯飞引擎"
                self._handle_record_error(error_hint)
            finally:
                # 确保任何异常路径下 Pipeline 都被释放，避免 is_processing 死锁
                # 但若回退成功并已重新启动，则不要释放
                if not _fallback_succeeded and self._pipeline and self._pipeline.is_processing:
                    try:
                        self._pipeline.finish()
                    except Exception as ex:
                        logger.warning("_start_asr_async finally 中释放 Pipeline 失败: %s", ex)

        threading.Thread(target=_start_asr_async, daemon=True, name="asr-start").start()

    def _try_fallback_to_xunfei(self) -> bool:
        """Windows ASR 启动失败时，尝试运行时回退到讯飞引擎。

        Returns:
            True 表示已成功切换到讯飞引擎并重新启动了录音；
            False 表示回退失败。
        """
        from .asr.factory import load_xunfei_engine

        # 已经是讯飞引擎，不再回退
        if self._asr_engine and type(self._asr_engine).__name__ == "XunfeiRealtimeEngine":
            return False

        asr_cfg = self._settings.get_section("asr")
        logger.warning("Windows ASR 失败，尝试运行时回退到讯飞引擎...")

        # 停止旧引擎（如果还在运行）
        if self._asr_engine:
            try:
                self._asr_engine.stop()
            except Exception:
                pass
            try:
                self._asr_engine.unload()
            except Exception:
                pass

        # 创建并加载讯飞引擎
        new_engine = load_xunfei_engine(
            asr_cfg,
            on_partial_text=self._on_partial_text,
            on_final_text=self._on_final_text_callback,
        )
        if new_engine is None:
            logger.error("回退到讯飞引擎失败: 引擎创建或加载失败")
            self._asr_engine = None
            return False

        # 替换引擎
        self._asr_engine = new_engine
        logger.info("[回退] 已切换到讯飞引擎，重新启动录音...")

        # 更新 pipeline 中的 ASR 引擎引用
        if self._pipeline:
            self._pipeline.asr_engine = new_engine

        # 重新启动录音
        try:
            self._asr_engine.start()
            self._state_ctrl.set_state("recognizing")
            if self._overlay:
                self._overlay.set_state("recognizing")
            logger.info("【流式录音开始（讯飞引擎）】等待用户说话...")
            return True
        except Exception as start_err:
            logger.error("讯飞引擎启动也失败: %s", start_err)
            return False

    def _handle_record_error(self, error_hint: str) -> None:
        """统一处理录音启动失败的错误流程：更新状态、显示浮窗、释放资源。"""
        self._state_ctrl.set_state("error")
        if self._overlay:
            self._overlay.set_state("error", text=error_hint) if hasattr(self._overlay, "set_state") else self._overlay.hide()
            # 3 秒后自动隐藏浮窗，避免持续刷 SetWindowPos 日志
            def _auto_hide():
                self._quit_event.wait(timeout=3.0)
                if self._state_ctrl.state == "error" and self._overlay:
                    try:
                        self._overlay.hide()
                    except Exception:
                        pass
            threading.Thread(target=_auto_hide, daemon=True, name="auto-hide-overlay").start()
        if self._pipeline:
            self._pipeline.finish()
        if self._toggle_hotkey:
            self._toggle_hotkey.reset()

    def _on_record_stop(self) -> None:
        """录音停止回调，在后台线程中执行流水线（避免阻塞热键回调）。"""
        # 同步模式到 Pipeline
        if self._pipeline:
            self._pipeline.current_mode = self._state_ctrl.mode_str

        def _run_pipeline():
            """在后台线程中执行流水线，带超时保护。"""
            pipeline_timeout_sec = 120  # 流水线最大执行时间（秒）
            try:
                # 如果 Esc 已经按下，直接跳过执行，避免与 _on_interrupt 竞争
                if self._interrupt_requested:
                    logger.info("检测到 Esc 中断，跳过流水线执行")
                    if self._pipeline:
                        self._pipeline.finish()
                    self._state_ctrl.set_state("ready")
                    return

                self._pipeline.run_realtime()
            except Exception as e:
                logger.error("流水线执行异常: %s", e, exc_info=True)
                if self._overlay:
                    self._overlay.dismiss() if hasattr(self._overlay, "dismiss") else self._overlay.hide()
                self._state_ctrl.set_state("ready")
                if self._pipeline:
                    self._pipeline.finish()
            finally:
                # 兜底：确保 pipeline 槽位被释放、热键状态被重置
                if self._pipeline and self._pipeline.is_processing:
                    self._pipeline.finish()
                if self._toggle_hotkey:
                    self._toggle_hotkey.reset()
                logger.debug("_run_pipeline  finally 执行完毕，pipeline_is_processing=%s", self._pipeline.is_processing if self._pipeline else None)

        t = threading.Thread(target=_run_pipeline, daemon=True, name="pipeline-run")
        t.start()

        # 超时哨兵：如果流水线运行过久，强制释放
        def _timeout_guard():
            t.join(timeout=pipeline_timeout_sec)
            if t.is_alive():
                logger.error("流水线执行超时（%ds），强制释放", pipeline_timeout_sec)
                if self._pipeline:
                    self._pipeline.finish()
                if self._toggle_hotkey:
                    self._toggle_hotkey.reset()
                self._state_ctrl.set_state("ready")

        threading.Thread(target=_timeout_guard, daemon=True, name="pipeline-timeout").start()

    def _on_switch_mode(self) -> None:
        """模式循环切换回调（ctrl+alt+m），委托 StateController。"""
        new_mode = self._state_ctrl.cycle_mode()
        # 播放短促提示音
        if sys.platform == "win32":
            try:
                winsound.MessageBeep(winsound.MB_OK)
            except Exception:
                pass
        if self._overlay:
            self._overlay.set_mode(new_mode)
            if not (self._pipeline and self._pipeline.is_processing):
                mode_label = {
                    "A": "直出",
                    "B": "润色",
                    "C": "Prompt",
                    "D": "翻译",
                    "E": "摘要",
                    "F": "结构化",
                }.get(new_mode, new_mode)
                suffix = ""
                if new_mode in ("B", "C", "D", "E", "F") and not self._ai_processor:
                    suffix = "；AI 未启用，将直出原文"
                self._overlay.show()
                self._overlay.set_mode(new_mode)
                self._overlay.set_state("notice", text=f"已切换到 {new_mode} 模式（{mode_label}）{suffix}")

    def _on_interrupt(self) -> None:
        """Esc 中断回调：发信号让正在运行的流程自行优雅退出。

        增强版：录音阶段按 Esc 会主动停止 ASR 引擎，立即中断录音。
        """
        logger.info("Esc 中断触发")

        # 0. 如果当前不在录音/处理中，忽略 Esc 键，避免空闲时弹出浮窗
        current_state = self._state_ctrl.state.value if self._state_ctrl else "ready"
        if current_state == "ready" and not (self._pipeline and self._pipeline.is_processing):
            logger.debug("Esc 忽略：当前处于就绪状态，无正在进行的操作")
            return

        # 1. 设置中断标志——由正在运行的流程自行检查并退出
        self._interrupt_requested = True

        # 2. 中断 AI 处理（如果正在进行）
        if self._ai_processor:
            self._ai_processor.interrupt()

        # 3. 如果 ASR 引擎正在录音，主动停止（让 run_realtime 中的 stop() 尽快返回）
        if self._asr_engine and getattr(self._asr_engine, 'is_recording', False):
            logger.info("Esc 中断：ASR 引擎正在录音，主动停止")
            try:
                self._asr_engine.stop()
            except Exception as e:
                logger.debug("Esc 停止 ASR 引擎异常（不影响中断流程）: %s", e)

        # 4. 重置 toggle 热键状态，确保下次按键触发 start 而非 stop
        #    Esc 中断时 _run_pipeline 的 finally 可能还没执行（ASR start 阶段中断），
        #    如果不在此处 reset，toggle._recording 仍为 True，下次按键走 stop 分支（无效），
        #    导致用户需要按两次才能重新唤起。
        if self._toggle_hotkey:
            self._toggle_hotkey.reset()

        # 5. 释放 Pipeline 槽位，确保下次录音可以正常启动
        #    Esc 中断可能发生在 _start_asr_async 阶段，
        #    此时 _run_pipeline 还没执行，pipeline 不会被其 finally 释放。
        if self._pipeline and self._pipeline.is_processing:
            self._pipeline.finish()

        # 6. 在浮窗显示取消提示
        if self._overlay:
            try:
                self._overlay.set_state("notice", text="已取消")
            except Exception:
                pass

        # 7. 回到就绪状态
        self._state_ctrl.set_state("ready")
        logger.info("Esc 中断信号已发出，等待后台流程自行清理")

    def _on_tray_mode_change(self, mode: str) -> None:
        """托盘菜单模式切换回调，委托 StateController。"""
        self._state_ctrl.set_mode(mode)

    def _on_engine_change(self, engine: str) -> None:
        """托盘菜单引擎切换回调。

        安全地停止当前引擎，重新加载新引擎，并更新 Pipeline。
        """
        logger.info("用户通过托盘切换 ASR 引擎: %s", engine)

        # 1. 保存当前处理状态（如果正在处理则先停止）
        was_processing = False
        if self._pipeline and self._pipeline.is_processing:
            was_processing = True
            try:
                self._pipeline.finish()
            except Exception as e:
                logger.warning("切换引擎前释放流水线失败: %s", e)

        # 2. 安全卸载当前引擎
        if self._asr_engine:
            try:
                self._asr_engine.stop()
            except Exception:
                pass
            try:
                self._asr_engine.unload()
            except Exception:
                pass
            self._asr_engine = None

        # 3. 重新加载配置，确保获取最新的用户配置（如刚更新的 meituan 凭证）
        if self._settings:
            try:
                from .config.settings import Settings
                self._settings = Settings.load(self._settings._user_config_path)
                logger.debug("配置已重新加载: %s", self._settings._user_config_path)
            except Exception as e:
                logger.warning("重新加载配置失败，继续使用当前配置: %s", e)
            self._settings._config["asr"] = self._settings._config.get("asr", {})
            self._settings._config["asr"]["realtime_provider"] = engine

        # 4. 重新加载新引擎
        try:
            self._setup_asr()
        except Exception as e:
            logger.error("切换引擎失败: %s", e)
            if self._tray_icon:
                self._tray_icon.notify_error(f"引擎切换失败: {e}")
            return

        # 5. 根据实际加载的引擎同步配置和托盘状态（处理降级场景）
        actual_provider = self._sync_actual_engine_to_config(requested=engine)

        # 6. 更新 Pipeline 中的引擎引用
        if self._pipeline:
            self._pipeline.asr_engine = self._asr_engine

        # 7. 如果之前正在处理，提示用户可继续
        if was_processing and self._asr_engine:
            logger.info("引擎切换完成，可继续录音")

        logger.info("ASR 引擎切换完成: %s", actual_provider)

    def _on_pause_resume(self, paused: bool) -> None:
        """托盘菜单暂停/恢复回调。"""
        self._paused = paused
        if paused:
            logger.info("Spoken 已暂停，热键将不响应")
        else:
            logger.info("Spoken 已恢复，热键重新生效")

    def _on_view_log(self) -> None:
        """查看日志文件（托盘菜单点击）。"""
        if sys.platform == "win32":
            log_cfg = self._settings.get_section("log") if self._settings else {}
            log_file = log_cfg.get("file", "")
            if log_file:
                expanded = os.path.expandvars(log_file)
                try:
                    os.startfile(expanded)
                    return
                except Exception as e:
                    logger.error("打开日志文件失败: %s", e)
        logger.info("日志查看（仅 Windows 支持自动打开文件）")

    def _on_quit(self) -> None:
        """退出回调。"""
        logger.info("收到退出请求")
        self._quit_event.set()

    def _show_critical_error(self, title: str, message: str) -> None:
        """显示关键错误提示（console=False 时替代控制台输出）。"""
        if sys.platform != "win32":
            return
        try:
            import ctypes
            ctypes.windll.user32.MessageBoxW(0, message, title, 0x10 | 0x0)
        except Exception:
            pass

    # ──────────────────────────────────────────────────────────────────
    # 运行与退出
    # ──────────────────────────────────────────────────────────────────

    def run(self) -> None:
        """启动应用主循环。

        策略：将应用事件循环放在后台线程，
        主线程留给 WebView2（pywebview 要求在主线程运行）。
        如果 WebView2 不可用，回退到传统阻塞循环。
        """
        def _signal_handler(sig: int, frame: object) -> None:
            logger.info("收到系统信号 %d，准备退出...", sig)
            self._quit_event.set()

        # signal 只能在主线程注册；WebView2 场景下 app-loop 会跑在后台线程。
        if threading.current_thread() is threading.main_thread():
            signal.signal(signal.SIGINT, _signal_handler)
            if hasattr(signal, "SIGTERM"):
                signal.signal(signal.SIGTERM, _signal_handler)

        # ── 后台线程：应用事件循环（热键、退出） ──
        def _app_loop():
            record_combo = self._settings.get("hotkey", "toggle_record", default="alt+r") if self._settings else "alt+r"
            record_mode = str(self._settings.get("hotkey", "record_mode", default="toggle") if self._settings else "toggle").strip().lower()
            if record_mode in ("push_to_talk", "push", "hold", "ptt"):
                logger.info("Spoken 运行中: 按住 %s 说话，松开停止并注入", record_combo)
            else:
                logger.info("Spoken 运行中: 按 %s 开始/停止录音", record_combo)

            try:
                while not self._quit_event.is_set():
                    self._quit_event.wait(timeout=1.0)
            except KeyboardInterrupt:
                logger.info("收到 KeyboardInterrupt，退出")

            self._shutdown()
            # 注意：不再在此处调用 overlay.destroy()，
            # 因为 _shutdown() 内部已经调用了，双重 destroy 会导致
            # WinForms Form.Close() 被多次调用，引发异常。

        # ── 尝试主线程启动 WebView2 ──
        webview_ok = False
        if self._overlay:
            try:
                import webview  # noqa: F401
                webview_ok = True
            except ImportError:
                pass

        if webview_ok and self._overlay:
            # 启动应用事件循环（后台线程）
            app_thread = threading.Thread(target=_app_loop, daemon=True, name="app-loop")
            app_thread.start()

            # 主线程：启动 WebView2（阻塞直到窗口关闭）
            try:
                self._overlay.start()
                if self._quit_event.is_set():
                    logger.info("WebView2 主循环已退出")
                else:
                    logger.warning("WebView2 主循环提前退出，回退到无浮窗模式")
                    self._quit_event.wait()
            except Exception as e:
                logger.error("WebView2 启动失败: %s，回退到无浮窗模式", e, exc_info=True)
                # 尝试弹窗提示用户（console=False 时日志不可见）
                self._show_critical_error(
                    "浮窗启动失败",
                    f"WebView2 浮窗启动失败: {e}\n\n"
                    "程序将继续运行，但浮窗不可见。\n"
                    "请检查日志或重新安装 WebView2 Runtime。",
                )
                # 回退：在主线程等待退出
                self._quit_event.wait()
        else:
            # 无浮窗：传统阻塞循环
            if self._overlay is None:
                logger.warning("浮窗未创建，以无浮窗模式运行")
            else:
                logger.warning("pywebview 不可用，以无浮窗模式运行")
            _app_loop()

    def _shutdown(self) -> None:
        """优雅退出：清理所有资源。"""
        logger.info("Spoken 正在退出...")

        # 停止热键监听
        if self._hotkey_manager:
            try:
                self._hotkey_manager.stop()
            except Exception as e:
                logger.error("停止热键监听失败: %s", e)

        # 停止录音（如果正在录音）
        if self._audio_capture:
            try:
                if self._audio_capture.is_recording:
                    self._audio_capture.stop()
                self._audio_capture.cleanup()
            except Exception as e:
                logger.error("停止录音失败: %s", e)

        # 卸载 ASR 模型（释放内存）
        if self._asr_engine and self._asr_engine.is_loaded:
            try:
                self._asr_engine.unload()
            except Exception as e:
                logger.error("卸载 ASR 模型失败: %s", e)

        # 停止托盘图标
        if self._tray_icon:
            try:
                self._tray_icon.stop()
            except Exception as e:
                logger.error("停止托盘图标失败: %s", e)

        # 销毁识别浮窗
        if self._overlay:
            try:
                self._overlay.destroy()
            except Exception as e:
                logger.debug("销毁浮窗失败（忽略）: %s", e)

        logger.info("Spoken 已退出，再见 👋")


# ══════════════════════════════════════════════════════════════════════
# UI 适配器（将旧接口桥接到 StateObserver 协议）
# ══════════════════════════════════════════════════════════════════════

class _TrayAdapter:
    """将 TrayIcon 适配为 StateObserver。"""

    def __init__(self, tray_icon) -> None:
        self._tray = tray_icon

    def on_state_change(self, state: str) -> None:
        try:
            self._tray.set_state(state)
        except Exception as e:
            logger.debug("TrayAdapter 状态通知失败: %s", e)

    def on_mode_change(self, mode: str) -> None:
        try:
            self._tray.set_mode(mode)
        except Exception as e:
            logger.debug("TrayAdapter 模式通知失败: %s", e)


class _OverlayAdapter:
    """将 OverlayWindow 适配为 StateObserver（仅关心状态变更）。"""

    def __init__(self, overlay) -> None:
        self._overlay = overlay

    def on_state_change(self, state: str) -> None:
        # 浮窗状态由 Pipeline 内部直接控制（更精细），此处不做额外操作
        pass

    def on_mode_change(self, mode: str) -> None:
        try:
            self._overlay.set_mode(mode)
        except Exception as e:
            logger.debug("OverlayAdapter 模式通知失败: %s", e)


# ══════════════════════════════════════════════════════════════════════
# 命令行入口
# ══════════════════════════════════════════════════════════════════════

def _parse_args() -> argparse.Namespace:
    """解析命令行参数。"""
    parser = argparse.ArgumentParser(
        prog="spoken",
        description="Spoken — Windows 全局语音输入工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例：
  python -m spoken                          使用默认配置启动
  python -m spoken --mode B                 以润色模式启动
  python -m spoken --log-level DEBUG        调试模式
  python -m spoken --config C:\\my.toml     使用自定义配置文件
        """,
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        metavar="PATH",
        help="自定义配置文件路径（默认: %%APPDATA%%\\Spoken\\config.toml）",
    )
    parser.add_argument(
        "--mode",
        choices=["A", "B", "C", "D", "E", "F"],
        default=None,
        metavar="MODE",
        help="覆盖默认模式：A=直接注入 B=润色优化 C=转Prompt D=翻译英文 E=摘要总结 F=结构化纪要",
    )
    parser.add_argument(
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        default=None,
        metavar="LEVEL",
        help="覆盖日志级别",
    )
    parser.add_argument(
        "--version",
        action="version",
        version="Spoken 1.6.0",
    )
    return parser.parse_args()


def main() -> None:
    """Spoken 主函数。"""
    # Windows 控制台编码修复（防止中文乱码）
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)  # UTF-8
        except Exception:
            pass

        # DPI 感知：Per-Monitor V2，确保 pywebview 浮窗在高 DPI 下尺寸正确
        try:
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
            ctypes.windll.user32.SetProcessDpiAwarenessContext(
                DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            )
        except Exception:
            # 回退到 SetProcessDPIAware（Windows 8.1 及以下）
            try:
                ctypes.windll.user32.SetProcessDPIAware()
            except Exception:
                pass

    args = _parse_args()

    app = SpokenApp()
    app.setup(
        config_path=args.config,
        initial_mode=args.mode,
        log_level=args.log_level,
    )
    app.run()


if __name__ == "__main__":
    main()
