"""
spoken/pipeline.py
语音处理流水线 — 从 SpokenApp 中提取的核心业务逻辑。

职责：
  - 录音停止后的完整流水线：ASR → AI 润色 → CoT 过滤 → 文本注入
  - 流式（realtime）识别路径
  - 处理状态的回调通知（通过 StateController）

SpokenApp 只负责模块初始化和事件分发，
Pipeline 负责具体的数据流转和错误恢复。
"""

from __future__ import annotations

import logging
import re
import threading
from typing import Callable, Optional, Protocol

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════
# 协议定义（依赖倒置，Pipeline 不直接依赖具体实现）
# ══════════════════════════════════════════════════════════════════════

class ASRProvider(Protocol):
    """ASR 引擎协议（Pipeline 所需的最小接口）。"""

    @property
    def is_recording(self) -> bool: ...

    def start(self) -> None: ...

    def stop(self) -> str: ...

    def transcribe(self, audio_bytes: bytes, language: Optional[str] = None) -> str: ...


class AudioProvider(Protocol):
    """录音器协议。"""

    @property
    def is_recording(self) -> bool: ...

    def start(self) -> None: ...

    def stop(self) -> bytes: ...


class AIProvider(Protocol):
    """AI 处理器协议。"""

    def process(self, text: str, mode: str = "A", on_chunk: Optional[object] = None) -> "ProcessResult": ...

    def interrupt(self) -> None: ...


class InjectorProvider(Protocol):
    """文本注入器协议。"""

    def capture_focus(self) -> object: ...

    def inject_with_fallback(self, text: str) -> bool: ...


class OverlayProvider(Protocol):
    """浮窗协议。"""

    def show(self, icon: str = "🎙️") -> None: ...

    def update_text(self, text: str) -> None: ...

    def set_icon(self, icon: str) -> None: ...

    def set_mode(self, mode: str) -> None: ...

    def hide(self) -> None: ...


class StateListener(Protocol):
    """状态变更通知协议。"""

    def on_state_change(self, state: str) -> None: ...


from spoken.utils.text import strip_think_tags


# ══════════════════════════════════════════════════════════════════════
# 核心流水线
# ══════════════════════════════════════════════════════════════════════

class Pipeline:
    """语音处理流水线，负责 ASR → AI → 注入的完整数据流转。

    设计原则：
      - 依赖倒置：通过 Protocol 定义依赖，不直接耦合具体实现
      - 状态通知：通过 StateListener 回调通知 UI 状态变更
      - 线程安全：processing_lock 保证同一时间只有一条流水线在运行

    使用示例::

        pipeline = Pipeline(
            asr_engine=engine,
            audio_capture=capture,
            ai_processor=processor,
            dispatcher=dispatcher,
            overlay=overlay_window,
            state_listener=state_ctrl,
            asr_mode="realtime",
            language="zh",
        )
        # 录音停止后
        pipeline.run_realtime()
    """

    def __init__(
        self,
        asr_engine: ASRProvider,
        audio_capture: AudioProvider,
        ai_processor: AIProvider,
        dispatcher: InjectorProvider,
        overlay: Optional[OverlayProvider],
        state_listener: Optional[StateListener],
        asr_mode: str = "realtime",
        current_mode: str = "A",
        language: str = "zh",
        interrupt_checker: Optional[Callable[[], bool]] = None,
    ) -> None:
        self._asr_engine = asr_engine
        self._audio_capture = audio_capture
        self._ai_processor = ai_processor
        self._dispatcher = dispatcher
        self._overlay = overlay
        self._state_listener = state_listener
        self._asr_mode = asr_mode
        self._current_mode = current_mode
        self._language = language
        self._interrupt_checker = interrupt_checker

        # 处理锁（防止并发）
        self._processing_lock = threading.Lock()
        self._is_processing = False

    @property
    def is_processing(self) -> bool:
        """当前是否有流水线在运行。"""
        return self._is_processing

    @property
    def current_mode(self) -> str:
        """当前工作模式。"""
        return self._current_mode

    @property
    def asr_engine(self) -> ASRProvider:
        """当前 ASR 引擎。"""
        return self._asr_engine

    @asr_engine.setter
    def asr_engine(self, engine: ASRProvider) -> None:
        """动态更换 ASR 引擎（用于托盘切换引擎）。"""
        self._asr_engine = engine

    @current_mode.setter
    def current_mode(self, mode: str) -> None:
        """设置工作模式。"""
        if mode in ("A", "B", "C", "D", "E", "F"):
            self._current_mode = mode

    def set_overlay(self, overlay: Optional[OverlayProvider]) -> None:
        """更新浮窗实例（运行时热替换）。"""
        self._overlay = overlay

    def set_asr_engine(self, engine: ASRProvider) -> None:
        """更新 ASR 引擎实例（运行时热替换）。"""
        self._asr_engine = engine

    # ──────────────────────────────────────────────────────────────────
    # 流水线入口
    # ──────────────────────────────────────────────────────────────────

    def try_start(self) -> bool:
        """尝试占用处理槽位，覆盖录音和后续流水线（防并发）。

        Returns:
            True 表示本次触发已成功占位，False 表示上次流程尚未结束
        """
        with self._processing_lock:
            if self._is_processing:
                logger.warning("上一次处理尚未完成，忽略本次触发")
                return False
            self._is_processing = True
            return True

    def finish(self) -> None:
        """释放处理槽位。"""
        with self._processing_lock:
            self._is_processing = False

    def _handle_pipeline_error(self, error: Exception, context: str = "处理") -> None:
        """统一处理流水线异常：日志 + 浮窗提示 + 状态更新。"""
        logger.error("%s流水线异常: %s", context, error, exc_info=True)
        error_hint = f"{context}失败，请重试"
        err_str = str(error).lower()
        if 'network' in err_str or '网络' in err_str or 'timeout' in err_str or '连接' in err_str:
            error_hint = "网络连接失败，请检查网络"
        elif 'api' in err_str or 'key' in err_str:
            error_hint = "API 错误，请检查配置"
        self._overlay_set_state("error", error_hint)
        self._notify_state("error")

    def _overlay_set_state(self, state: str, text: str = "") -> None:
        if not self._overlay:
            return

        setter = getattr(self._overlay, "set_state", None)
        if callable(setter):
            try:
                setter(state, text=text)
                return
            except TypeError:
                setter(state, text)
                return
            except Exception as e:
                logger.debug("浮窗状态更新失败: %s", e)

        try:
            if state == "recording":
                self._overlay.show(icon="🎙️")
            elif state == "done":
                self._overlay.hide()
            elif state == "error":
                self._overlay.hide()
            else:
                if text:
                    self._overlay.update_text(text)
                self._overlay.set_icon("✨" if state == "ai_processing" else "⏳")
        except Exception as e:
            logger.debug("浮窗状态更新失败: %s", e)

    def _overlay_dismiss(self) -> None:
        if not self._overlay:
            return

        dismiss = getattr(self._overlay, "dismiss", None)
        if callable(dismiss):
            try:
                dismiss()
                return
            except Exception as e:
                logger.debug("浮窗隐藏失败: %s", e)

        try:
            self._overlay.hide()
        except Exception as e:
            logger.debug("浮窗隐藏失败: %s", e)

    def _overlay_notice_then_dismiss(self, message: str, delay_sec: float = 1.5) -> None:
        """在浮窗上显示提示消息，延迟后自动消失（用于空识别等场景）。"""
        if not self._overlay:
            return
        try:
            self._overlay_set_state("notice", message)
            import threading as _th
            def _delayed_dismiss():
                _th.Event().wait(timeout=delay_sec)
                self._overlay_dismiss()
            _th.Thread(target=_delayed_dismiss, daemon=True, name="notice-dismiss").start()
        except Exception as e:
            logger.debug("浮窗提示显示失败: %s", e)
            self._overlay_dismiss()

    def _is_interrupted(self) -> bool:
        """检查是否被 Esc 中断。"""
        if self._interrupt_checker is not None:
            return self._interrupt_checker()
        return False

    def run_realtime(self) -> None:
        """流式识别流水线：停止流式录音 → 等待最终文字 → AI 润色 → 注入。"""

        try:
            # ── 1. 停止流式录音，等待最终识别结果 ─────────────────
            self._notify_state("recognizing")
            self._overlay_set_state("recognizing")

            raw_text = self._asr_engine.stop()

            # 检查是否被 Esc 中断（用户主动取消）
            if self._is_interrupted():
                logger.info("流水线被 Esc 中断，跳过后续处理")
                self._overlay_notice_then_dismiss("已取消", delay_sec=1.0)
                self._notify_state("ready")
                return

            if not raw_text or not raw_text.strip():
                # 增强诊断：检查引擎状态，帮助定位是静音还是引擎异常
                is_rec_after = getattr(self._asr_engine, 'is_recording', None)
                logger.info(
                    "流式 ASR 未识别到有效文字（可能是静音或噪音）。"
                    "引擎类型=%s, 录音状态=%s, 原始文本长度=%d",
                    type(self._asr_engine).__name__,
                    is_rec_after,
                    len(raw_text) if raw_text else 0,
                )
                self._overlay_notice_then_dismiss("未识别到语音内容")
                self._notify_state("ready")
                return

            logger.info("流式 ASR 识别结果: %s", raw_text[:60])

            # ── 2. AI 润色 + 注入 ─────────────────────────────────
            self._run_ai_and_inject(raw_text)

        except Exception as e:
            self._handle_pipeline_error(e, "流式")
        finally:
            self.finish()


    # ──────────────────────────────────────────────────────────────────
    # 核心子流程
    # ──────────────────────────────────────────────────────────────────

    def _run_ai_and_inject(self, raw_text: str) -> None:
        """AI 润色（可选）-> CoT 过滤 -> 文本注入。"""
        # ── 先显示识别结果，让用户立刻看到 ASR 输出 ────────────────
        if self._overlay:
            self._overlay.update_text(raw_text)

        # ── Mode A 快速通道：跳过 AI，直接注入 ───────────────────
        final_text = raw_text
        if self._current_mode == "A":
            # Mode A 无需 AI 处理，直接跳到注入
            pass
        elif self._ai_processor:
            self._notify_state("ai_processing")
            self._overlay_set_state("ai_processing", raw_text)

            # 流式回调：仅内部收集结果，不刷新浮窗
            # （浮窗保持显示原始识别文字，避免 AI 中间结果闪烁）
            def _on_ai_chunk(partial_text: str) -> None:
                pass

            result = self._ai_processor.process(raw_text, mode=self._current_mode, on_chunk=_on_ai_chunk)
            final_text = result.text

            if result.fallback:
                reason = "中断" if result.interrupted else ("超时" if result.timed_out else ("截断" if getattr(result, "truncated", False) else "错误"))
                logger.warning("AI 处理降级（%s），使用原始文字", reason)
            else:
                logger.info("AI 处理完成（模式 %s）: %s", self._current_mode, final_text[:60])
                # 浮窗保持原始识别文字，不在 AI 处理阶段刷新

        # ── CoT 过滤（所有模式统一执行）────────────────────────
        final_text = strip_think_tags(final_text)
        if not final_text:
            logger.info("过滤 CoT 后文字为空，跳过注入")
            self._overlay_dismiss()
            self._notify_state("ready")
            return

        # ── 文本注入 ────────────────────────────────────────────
        logger.info("准备注入文字: %s", final_text[:60])
        self._notify_state("injecting")
        self._overlay_set_state("injecting", final_text)

        success = self._dispatcher.inject_with_fallback(final_text)
        if success:
            logger.info("文字注入成功 [OK]")
            if self._overlay:
                self._overlay.hide()
            self._notify_state("ready")
        else:
            logger.error("文字注入失败")
            error_hint = "注入失败，请检查目标窗口"
            captured = self._dispatcher.captured_window
            if captured:
                exe_name = captured.exe_name
                if exe_name:
                    if 'electron' in exe_name.lower() or 'chrome' in exe_name.lower():
                        error_hint = f"注入失败，{exe_name} 可能需要手动粘贴"
                    elif captured.is_elevated:
                        error_hint = "注入失败，请以管理员身份运行 Spoken"
            self._overlay_set_state("error", error_hint)
            self._notify_state("error")

    def _notify_state(self, state: str) -> None:
        """通知状态变更。"""
        if self._state_listener:
            try:
                self._state_listener.on_state_change(state)
            except Exception as e:
                logger.debug("状态通知失败: %s", e)
