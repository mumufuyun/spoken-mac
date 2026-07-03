"""
spoken/asr/meituan_asr.py
美团内部语音识别引擎适配器。

设计原则：
  - 参考讯飞实时转写的 WebSocket 架构
  - 支持美团内部 OAuth/AppKey 认证
  - 支持长语音识别（默认最大 10 分钟）
  - 断线自动重连并保留已识别内容
  - 敏感信息（凭证）不记录到日志

使用示例::

    from spoken.asr.meituan_asr import MeituanASREngine

    engine = MeituanASREngine(
        endpoint="wss://asr.sankuai.com/v1/realtime",
        app_key="your-app-key",
        app_secret="your-app-secret",
    )
    engine.load()
    engine.start()
    # ... 录音中 ...
    text = engine.stop()
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import threading
import time
import traceback
from typing import Callable, List, Optional

from .engine import ASREngine

logger = logging.getLogger(__name__)

# 默认配置
DEFAULT_ENDPOINT = "wss://asr.sankuai.com/v1/realtime"
SAMPLE_RATE = 16000
FRAME_DURATION_SEC = 0.04
FRAME_BYTES = int(SAMPLE_RATE * FRAME_DURATION_SEC * 2)  # 16bit mono
MAX_RETRY_COUNT = 3
RECONNECT_DELAY_SEC = 2.0


class MeituanASREngine(ASREngine):
    """美团语音识别引擎适配器。

    支持：
      - 实时流式识别 via WebSocket
      - 美团内部 OAuth/AppKey 认证
      - 断线自动重连（最多 3 次）
      - 长语音识别（默认最大 10 分钟）
    """

    def __init__(
        self,
        endpoint: str = "",
        app_key: str = "",
        app_secret: str = "",
        language: str = "zh",
        max_duration: int = 600,
        on_partial_text: Optional[Callable[[str], None]] = None,
        on_final_text: Optional[Callable[[str], None]] = None,
    ) -> None:
        super().__init__()
        self._endpoint = endpoint or DEFAULT_ENDPOINT
        self._app_key = app_key
        self._app_secret = app_secret
        self._language = language
        self.max_duration = max_duration  # 最大支持时长（秒），供 ASRManager 查询

        self._on_partial_text = on_partial_text
        self._on_final_text = on_final_text

        # WebSocket 连接
        self._ws = None
        self._ws_connected = threading.Event()
        self._ws_thread: Optional[threading.Thread] = None

        # 状态
        self._is_listening = threading.Event()
        self._stop_event = threading.Event()
        self._result_lock = threading.Lock()
        self._final_result = ""
        self._partial_results: List[str] = []

        # 录音线程
        self._record_thread: Optional[threading.Thread] = None
        self._audio_buffer: List[bytes] = []
        self._buffer_lock = threading.Lock()

        # 重连计数
        self._reconnect_count = 0
        self._start_error: Optional[str] = None

        # 已识别内容缓存（用于重连后恢复）
        self._recognized_segments: List[str] = []

    # ══════════════════════════════════════════════════════════════════
    # ASREngine 接口实现
    # ══════════════════════════════════════════════════════════════════

    def load(self) -> None:
        """加载引擎，验证凭证和端点配置。"""
        if not self._app_key or not self._app_secret:
            raise RuntimeError("美团 ASR 未配置 app_key 或 app_secret")
        if not self._endpoint:
            raise RuntimeError("美团 ASR 未配置 endpoint")

        # 验证端点格式（简单检查）
        if not (self._endpoint.startswith("wss://") or self._endpoint.startswith("ws://")):
            raise RuntimeError(f"美团 ASR endpoint 格式错误: {self._endpoint}")

        self._loaded = True
        logger.info("美团 ASR 引擎已加载: endpoint=%s", self._endpoint)

    def unload(self) -> None:
        """释放引擎资源。"""
        self._loaded = False
        self._disconnect()
        logger.info("美团 ASR 引擎已卸载")

    def transcribe(self, audio_bytes: bytes, language: Optional[str] = None) -> str:
        """将音频数据转录为文字（批量模式）。

        当前实现将音频发送到服务端并返回完整结果。
        """
        self.ensure_loaded()
        # 批量模式：发送完整音频并等待结果
        return self._transcribe_batch(audio_bytes, language or self._language)

    # ══════════════════════════════════════════════════════════════════
    # 实时识别接口
    # ══════════════════════════════════════════════════════════════════

    def start(self) -> None:
        """开始实时识别。

        启动录音线程和 WebSocket 线程。
        """
        self.ensure_loaded()

        if self._is_listening.is_set():
            logger.warning("美团 ASR 已经在运行中")
            return

        # 重置状态
        self._stop_event.clear()
        self._final_result = ""
        self._partial_results = []
        self._audio_buffer = []
        self._recognized_segments = []
        self._reconnect_count = 0
        self._start_error = None

        # 启动录音线程
        self._record_thread = threading.Thread(target=self._record_loop, daemon=True, name="meituan-record")
        self._record_thread.start()

        # 启动 WebSocket 线程
        self._ws_thread = threading.Thread(target=self._ws_loop, daemon=True, name="meituan-ws")
        self._ws_thread.start()

        # 等待 WebSocket 连接
        if not self._ws_connected.wait(timeout=10.0):
            self._start_error = "美团 ASR WebSocket 连接超时"
            logger.error(self._start_error)
            self.stop()
            raise RuntimeError(self._start_error)

        self._is_listening.set()
        logger.info("美团 ASR 实时识别已启动")

    def stop(self) -> str:
        """停止识别并返回最终结果。"""
        if not self._is_listening.is_set():
            return self._final_result

        logger.info("美团 ASR 停止识别...")
        self._is_listening.clear()
        self._stop_event.set()

        # 发送结束帧
        self._send_end_frame()

        # 等待最终结果
        wait_time = min(5.0 + len(self._audio_buffer) * 0.02, 15.0)
        logger.debug("美团 ASR 等待最终结果，最多 %.1f 秒", wait_time)

        start_wait = time.time()
        while time.time() - start_wait < wait_time:
            with self._result_lock:
                if self._final_result:
                    break
            time.sleep(0.1)

        # 断开连接
        self._disconnect()

        with self._result_lock:
            result = self._final_result

        # 合并已缓存的片段
        all_segments = self._recognized_segments + ([result] if result else [])
        combined = " ".join(s.strip() for s in all_segments if s.strip())

        logger.info("美团 ASR 识别完成，结果长度=%d", len(combined))
        return combined

    # ══════════════════════════════════════════════════════════════════
    # 内部方法
    # ══════════════════════════════════════════════════════════════════

    def _authenticate(self) -> dict:
        """获取 Basic Auth 认证头。

        遵循美团 ASR 鉴权文档（AIAUTH-V1 Basic Auth）：
            Authorization = "AIAUTH-V1" + " " + appKey + ":" + signature
            signature     = base64( HMAC-SHA1( string_to_sign, secretKey ) )
            string_to_sign= HTTP-Verb + " " + REQUEST_URI + "\n" + Date
            Date          = "EEE, d MMM yyyy HH:mm:00 'GMT'" (GMT 格式，秒固定 00)

        对 WebSocket 握手请求：
            HTTP-Verb = GET
            REQUEST_URI = endpoint 路径（不含 query）

        Returns:
            dict: {"Authorization": ..., "Date": ...}
        """
        import hmac
        import hashlib
        from urllib.parse import urlparse
        from datetime import datetime, timezone

        # Date 格式：Fri, 8 Apr 2022 08:49:00 GMT（秒固定为 00）
        # %-d 在 Windows 不支持，手动构造
        dt = datetime.now(timezone.utc)
        date_str = dt.strftime(f"%a, {dt.day} %b %Y %H:%M:00 GMT")

        # 取 endpoint 的路径作为 REQUEST_URI
        parsed = urlparse(self._endpoint)
        request_uri = parsed.path or "/"

        string_to_sign = f"GET {request_uri}\n{date_str}"
        signature = base64.b64encode(
            hmac.new(
                self._app_secret.encode("utf-8"),
                string_to_sign.encode("utf-8"),
                hashlib.sha1,
            ).digest()
        ).decode("utf-8")

        auth_header = f"AIAUTH-V1 {self._app_key}:{signature}"

        logger.debug("美团 ASR Basic Auth 头已生成 (Date=%s)", date_str)
        return {"Authorization": auth_header, "Date": date_str}

    def _build_ws_url(self) -> str:
        """构建 WebSocket URL（认证信息通过 HTTP Header 传递）。"""
        from urllib.parse import urlencode, urlparse, urlunparse, parse_qs

        parsed = urlparse(self._endpoint)
        query_params = parse_qs(parsed.query)
        query_params["lang"] = [self._language]

        new_query = urlencode(query_params, doseq=True)
        return urlunparse(parsed._replace(query=new_query))

    def _ws_loop(self) -> None:
        """WebSocket 连接和消息处理循环。"""
        try:
            asyncio.run(self._ws_async_loop())
        except Exception as e:
            logger.error("美团 ASR WebSocket 线程异常: %s", e)
            self._start_error = str(e)

    async def _ws_async_loop(self) -> None:
        """异步 WebSocket 循环。"""
        try:
            import websockets
        except ImportError:
            logger.error("websockets 库未安装")
            self._start_error = "websockets 库未安装"
            return

        ws_url = self._build_ws_url()
        auth_headers = self._authenticate()
        # 不记录包含敏感信息的完整 URL
        logger.info("美团 ASR 连接 WebSocket: %s...", ws_url[:30])

        try:
            async with websockets.connect(ws_url, additional_headers=auth_headers) as ws:
                self._ws = ws
                self._ws_connected.set()
                logger.info("美团 ASR WebSocket 已连接")

                # 发送首帧配置
                await self._send_config_frame(ws)

                # 消息接收循环
                while not self._stop_event.is_set():
                    try:
                        msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
                        self._handle_message(msg)
                    except asyncio.TimeoutError:
                        continue
                    except Exception as e:
                        logger.warning("美团 ASR 接收消息异常: %s", e)
                        break

        except Exception as e:
            logger.error("美团 ASR WebSocket 连接失败: %s", e)
            # 尝试重连
            if self._reconnect_count < MAX_RETRY_COUNT and not self._stop_event.is_set():
                self._reconnect_count += 1
                logger.info("美团 ASR 尝试第 %d 次重连...", self._reconnect_count)
                await asyncio.sleep(RECONNECT_DELAY_SEC)
                await self._ws_async_loop()
            else:
                self._start_error = f"WebSocket 连接失败且重连耗尽: {e}"

    async def _send_config_frame(self, ws) -> None:
        """发送首帧配置。"""
        config = {
            "type": "config",
            "data": {
                "sample_rate": SAMPLE_RATE,
                "language": self._language,
                "enable_partial": True,
            },
        }
        await ws.send(json.dumps(config))
        logger.debug("美团 ASR 配置帧已发送")

    def _handle_message(self, msg: str) -> None:
        """处理服务端返回的消息。"""
        try:
            data = json.loads(msg)
            msg_type = data.get("type", "")

            if msg_type == "partial":
                text = data.get("text", "")
                if text:
                    with self._result_lock:
                        self._partial_results.append(text)
                    if self._on_partial_text:
                        self._on_partial_text(text)
                    logger.debug("美团 ASR 中间结果: %s", text[:30])

            elif msg_type == "final":
                text = data.get("text", "")
                if text:
                    with self._result_lock:
                        self._final_result = text
                    if self._on_final_text:
                        self._on_final_text(text)
                    logger.info("美团 ASR 最终结果: %s", text[:60])

            elif msg_type == "segment":
                # 长语音分段结果
                text = data.get("text", "")
                if text:
                    self._recognized_segments.append(text)
                    logger.debug("美团 ASR 分段结果已缓存")

            elif msg_type == "error":
                error_msg = data.get("message", "未知错误")
                logger.error("美团 ASR 服务端错误: %s", error_msg)

        except json.JSONDecodeError:
            logger.warning("美团 ASR 收到非 JSON 消息")
        except Exception as e:
            logger.warning("美团 ASR 消息处理异常: %s", e)

    def _record_loop(self) -> None:
        """录音循环，将音频数据发送到 WebSocket。"""
        logger.debug("美团 ASR 录音线程已启动")

        while not self._stop_event.is_set():
            if not self._is_listening.is_set():
                time.sleep(0.05)
                continue

            # 从音频缓冲区读取数据
            audio_chunk = None
            with self._buffer_lock:
                if self._audio_buffer:
                    audio_chunk = self._audio_buffer.pop(0)

            if audio_chunk and self._ws:
                try:
                    self._send_audio_frame(audio_chunk)
                except Exception as e:
                    logger.warning("美团 ASR 发送音频帧失败: %s", e)
            else:
                time.sleep(FRAME_DURATION_SEC)

        logger.debug("美团 ASR 录音线程已结束")

    def _send_audio_frame(self, audio_bytes: bytes) -> None:
        """发送音频帧。"""
        if not self._ws:
            return

        frame = {
            "type": "audio",
            "data": {
                "audio": base64.b64encode(audio_bytes).decode("utf-8"),
            },
        }
        # 使用 asyncio.run_coroutine_threadsafe 在线程中发送
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                asyncio.run_coroutine_threadsafe(
                    self._ws.send(json.dumps(frame)),
                    loop,
                )
        except Exception as e:
            logger.debug("美团 ASR 发送音频异常: %s", e)

    def _send_end_frame(self) -> None:
        """发送结束帧。"""
        if not self._ws:
            return

        end_frame = {
            "type": "end",
            "data": {},
        }
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                asyncio.run_coroutine_threadsafe(
                    self._ws.send(json.dumps(end_frame)),
                    loop,
                )
                logger.debug("美团 ASR 结束帧已发送")
        except Exception as e:
            logger.debug("美团 ASR 发送结束帧异常: %s", e)

    def _disconnect(self) -> None:
        """断开 WebSocket 连接。"""
        self._ws_connected.clear()
        if self._ws:
            try:
                # 尝试优雅关闭
                loop = asyncio.get_event_loop()
                if loop.is_running():
                    asyncio.run_coroutine_threadsafe(self._ws.close(), loop)
            except Exception:
                pass
            self._ws = None
        logger.debug("美团 ASR WebSocket 已断开")

    def _transcribe_batch(self, audio_bytes: bytes, language: str) -> str:
        """批量转录（非流式）。"""
        # 批量模式实现：发送完整音频并等待结果
        # 这里提供一个基础实现，实际使用时可能需要根据美团 API 调整
        logger.info("美团 ASR 批量转录: %d bytes", len(audio_bytes))

        # 简化实现：使用流式接口处理完整音频
        self._audio_buffer = [audio_bytes[i:i + FRAME_BYTES] for i in range(0, len(audio_bytes), FRAME_BYTES)]
        self.start()

        # 等待所有音频发送完毕
        while self._audio_buffer:
            time.sleep(0.1)

        # 发送结束并等待结果
        return self.stop()

    # ══════════════════════════════════════════════════════════════════
    # 状态查询
    # ══════════════════════════════════════════════════════════════════

    @property
    def is_recording(self) -> bool:
        """是否正在录音中。"""
        return self._is_listening.is_set()
