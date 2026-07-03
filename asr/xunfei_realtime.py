"""
spoken/asr/xunfei_realtime.py
讯飞语音听写（流式版）WebSocket 引擎

API: wss://iat-api.xfyun.cn/v2/iat
文档: https://www.xfyun.cn/doc/asr/voicedictation/API.html

流程:
  1. HMAC-SHA256 鉴权握手
  2. 首帧: common + business + data(status=0)
  3. 音频帧: data(status=1, audio=base64) 每40ms/1280B
  4. 结束帧: data(status=2, audio="")
  5. 实时接收识别结果（支持动态修正 dwa=wpgs）
"""

from __future__ import annotations

import asyncio
import base64
import collections
import hashlib
import hmac
import io
import json
import logging
import os
import sys
import threading
import time
import wave
from datetime import datetime
from typing import Callable, List, Optional
from urllib.parse import urlencode, urlparse

from .engine import ASREngine

logger = logging.getLogger(__name__)

WS_URL = "wss://iat-api.xfyun.cn/v2/iat"
SAMPLE_RATE = 16000
FRAME_DURATION_SEC = 0.04
FRAME_SAMPLES = int(SAMPLE_RATE * FRAME_DURATION_SEC)  # 40ms = 640 frames
FRAME_BYTES = FRAME_SAMPLES * 2  # PCM 16bit mono => 1280 bytes
SEND_INTERVAL = FRAME_DURATION_SEC
DEFAULT_STARTUP_PREBUFFER_SEC = 0.8


class XunfeiRealtimeEngine(ASREngine):
    """讯飞语音听写（流式版）引擎。"""

    def __init__(
        self,
        app_id: str = "",
        api_key: str = "",
        api_secret: str = "",
        language: str = "zh",
        vad_eos_ms: int = 8000,
        startup_prebuffer_sec: float = DEFAULT_STARTUP_PREBUFFER_SEC,
        on_partial_text: Optional[Callable[[str], None]] = None,
        on_final_text: Optional[Callable[[str], None]] = None,
    ) -> None:
        super().__init__()
        self._app_id = app_id
        self._api_key = api_key
        self._api_secret = api_secret
        self._language = language
        self.max_duration = 120  # 讯飞单条会话最长 120 秒
        self._vad_eos_ms = max(1000, int(vad_eos_ms))
        self._startup_prebuffer_frames = max(
            1,
            int(round(max(0.12, float(startup_prebuffer_sec)) / FRAME_DURATION_SEC)),
        )
        self._on_partial_text = on_partial_text
        self._on_final_text = on_final_text

        # 状态
        self._is_listening = threading.Event()
        self._stop_event = threading.Event()
        self._record_stopped = threading.Event()
        self._result_lock = threading.Lock()
        self._final_result = ""
        self._partial_result = ""
        self._segment_map: dict[int, str] = {}
        self._result_event = threading.Event()
        self._ws_connected = threading.Event()
        self._start_error: Optional[str] = None

        # 音频队列
        self._audio_queue: collections.deque[bytes] = collections.deque()
        self._audio_lock = threading.Lock()

        # 完整录音缓存（用于长语音结束后做最终复识别）
        self._recorded_pcm = bytearray()
        self._recorded_pcm_lock = threading.Lock()

        # 线程/异步循环引用
        self._record_thread: Optional[threading.Thread] = None
        self._ws_thread: Optional[threading.Thread] = None
        self._async_loop: Optional[asyncio.AbstractEventLoop] = None

        # VAD 重连控制
        self._vad_ended = threading.Event()       # VAD 触发了会话结束
        self._reconnect_count = 0                 # 当前重连次数
        self._MAX_RECONNECT = 5                   # 最大重连次数

    # ─────────────────────────────────────────────────────────────
    # 生命周期
    # ─────────────────────────────────────────────────────────────

    def load(self) -> None:
        if self._loaded:
            return
        if not self._app_id or not self._api_key or not self._api_secret:
            raise RuntimeError(
                "讯飞语音听写需要 APPID、APIKey、APISecret。"
                "请在 config.toml [asr.xunfei] 中配置，"
                "或设置环境变量 XUNFEI_APP_ID / XUNFEI_API_KEY / XUNFEI_API_SECRET。"
            )
        # 预检 websockets 依赖，避免加载成功但 start() 时报错
        try:
            import websockets
        except ImportError as exc:
            raise RuntimeError(
                "websockets 未安装，请运行: pip install websockets"
            ) from exc
        self._loaded = True
        logger.info("讯飞语音听写引擎就绪（APPID: %s...）", self._app_id[:4])

    def preconnect(self) -> None:
        """预热鉴权 URL，提前计算 HMAC 签名参数。

        在 load() 后后台调用，提前触发 DNS 解析和 TLS 会话缓存，
        使后续 start() 时的 WebSocket 建连更快。
        如果预热失败则静默忽略，不影响正常 start() 流程。
        """
        if not self._loaded:
            return
        try:
            # 提前构建鉴权 URL，触发 DNS 解析
            auth_url = self._build_auth_url()
            from urllib.parse import urlparse
            parsed = urlparse(auth_url)
            import socket
            # 预解析 DNS，结果会被系统 DNS 缓存
            socket.getaddrinfo(parsed.hostname, 443, socket.AF_INET, socket.SOCK_STREAM)
            logger.debug("讯飞预连接: DNS 预解析完成 (%s)", parsed.hostname)
        except Exception as e:
            logger.debug("讯飞预连接预热失败（不影响正常使用）: %s", e)

    def unload(self) -> None:
        self._loaded = False

    # ─────────────────────────────────────────────────────────────
    # 流式控制
    # ─────────────────────────────────────────────────────────────

    def start(self) -> None:
        """开始实时识别：先开麦预缓冲，再并行建立 WebSocket。"""
        self.ensure_loaded()
        if self._is_listening.is_set():
            return

        # 重置状态
        self._final_result = ""
        self._partial_result = ""
        self._segment_map.clear()
        self._result_event.clear()
        self._stop_event.clear()
        self._record_stopped.clear()
        self._ws_connected.clear()
        self._start_error = None
        self._vad_ended.clear()
        self._reconnect_count = 0
        with self._audio_lock:
            self._audio_queue.clear()
        with self._recorded_pcm_lock:
            self._recorded_pcm.clear()

        self._is_listening.set()

        # 先启动录音线程，避免等待建连时丢掉按键后的前几个字。
        self._record_thread = threading.Thread(
            target=self._record_loop,
            name="xunfei-record",
            daemon=True,
        )
        self._record_thread.start()

        self._ws_thread = threading.Thread(target=self._run_async_loop, name="xunfei-ws", daemon=True)
        self._ws_thread.start()

        # 等待 WebSocket 连接建立；录音线程已提前把起始音频放入本地缓冲。
        if not self._ws_connected.wait(timeout=10.0):
            self._start_error = "讯飞 WebSocket 连接超时"

        if self._start_error:
            self._stop_event.set()
            self._record_stopped.wait(timeout=0.8)
            self._is_listening.clear()
            raise RuntimeError(self._start_error)

        logger.info("讯飞语音听写已启动（预缓冲 %d 帧）", self._startup_prebuffer_frames)

    def stop(self) -> str:
        """停止识别，尽量等待尾音频和最终结果都收完整。"""
        if not self._is_listening.is_set():
            return ""

        logger.info("停止讯飞语音听写...")
        self._stop_event.set()

        # 等录音线程退出，确保最后几帧已进入发送队列。
        # 根据录音时长动态等待：至少 0.3s，每 10s 语音多等 0.5s
        duration = self.get_recorded_duration_sec()
        record_wait = max(0.3, min(2.0, 0.3 + duration / 20.0))
        self._record_stopped.wait(timeout=record_wait)

        # 等服务端处理结束帧并回传最终结果。
        # 根据录音时长动态计算超时：至少 5s，每 10s 语音多等 3s
        result_wait_start = time.monotonic()
        result_timeout = max(5.0, 5.0 + duration / 10.0 * 3.0)
        while (time.monotonic() - result_wait_start) < result_timeout:
            if self._result_event.wait(timeout=0.05):
                break
            # Early result 检测：final_result 已非空时提前返回
            with self._result_lock:
                if self._final_result:
                    logger.debug("讯飞 early result 检测命中，提前返回")
                    self._is_listening.clear()
                    result = self._final_result
                    logger.info("讯飞最终结果: %s", result[:80])
                    return result

        self._is_listening.clear()

        with self._result_lock:
            result = self._final_result or self._partial_result or ""

        logger.info("讯飞最终结果: %s", result[:80])
        return result

    @property
    def is_recording(self) -> bool:
        return self._is_listening.is_set()

    def get_recorded_audio(self) -> bytes:
        """返回当前这次实时录音的完整 WAV 数据。"""
        with self._recorded_pcm_lock:
            pcm_data = bytes(self._recorded_pcm)

        if not pcm_data:
            return b""

        buf = io.BytesIO()
        with wave.open(buf, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm_data)
        return buf.getvalue()

    def get_recorded_duration_sec(self) -> float:
        with self._recorded_pcm_lock:
            pcm_len = len(self._recorded_pcm)
        return pcm_len / float(SAMPLE_RATE * 2)

    # ─────────────────────────────────────────────────────────────
    # 鉴权
    # ─────────────────────────────────────────────────────────────

    def _build_auth_url(self) -> str:
        """构建带 HMAC-SHA256 签名的 WebSocket URL。"""
        url_obj = urlparse(WS_URL)
        # RFC1123 格式时间（GMT）
        now = datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")

        # 签名原始串
        signature_origin = (
            f"host: {url_obj.hostname}\n"
            f"date: {now}\n"
            f"GET {url_obj.path} HTTP/1.1"
        )
        # HMAC-SHA256 签名 → base64
        signature = base64.b64encode(
            hmac.new(
                self._api_secret.encode(),
                signature_origin.encode(),
                hashlib.sha256,
            ).digest()
        ).decode()

        # authorization 原始串
        authorization_origin = (
            f'api_key="{self._api_key}", '
            f'algorithm="hmac-sha256", '
            f'headers="host date request-line", '
            f'signature="{signature}"'
        )
        authorization = base64.b64encode(authorization_origin.encode()).decode()

        params = {
            "authorization": authorization,
            "date": now,
            "host": url_obj.hostname,
        }
        return f"{WS_URL}?{urlencode(params)}"

    # ─────────────────────────────────────────────────────────────
    # 异步事件循环
    # ─────────────────────────────────────────────────────────────

    def _run_async_loop(self) -> None:
        """在独立线程中运行 asyncio 事件循环。"""
        try:
            import websockets
        except ImportError:
            self._start_error = "websockets 未安装，请运行: pip install websockets"
            logger.error(self._start_error)
            self._ws_connected.set()
            self._result_event.set()
            return

        self._async_loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._async_loop)
        try:
            self._async_loop.run_until_complete(self._ws_main(websockets))
        except Exception as e:
            logger.error("讯飞 WebSocket 异常: %s", e)
            if not self._ws_connected.is_set():
                self._start_error = f"讯飞 WebSocket 启动失败: {e}"
                self._ws_connected.set()
            self._result_event.set()
        finally:
            self._async_loop.close()
            self._async_loop = None

    async def _ws_main(self, websockets) -> None:
        """WebSocket 主流程：连接 → 首帧 → 收发 → 结束（支持 VAD 自动重连）。

        当 VAD 检测到用户停顿后，讯飞会自动结束当前会话（status=2）。
        如果用户没有主动停止录音（_stop_event 未设置），则自动重连继续识别，
        已识别的文本保留，新内容追加。
        """
        # SSL 上下文（只需创建一次）
        ssl_ctx = None
        if sys.platform == "win32":
            import ssl
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ssl_ctx.check_hostname = True
            ssl_ctx.verify_mode = ssl.CERT_REQUIRED
            ssl_ctx.load_default_certs()

        try:
            while not self._stop_event.is_set():
                self._vad_ended.clear()
                self._ws_connected.clear()
                self._result_event.clear()

                auth_url = self._build_auth_url()

                try:
                    async with websockets.connect(auth_url, ssl=ssl_ctx) as ws:
                        if self._reconnect_count > 0:
                            logger.info("讯飞 WebSocket 第 %d 次重连成功", self._reconnect_count)
                        else:
                            logger.debug("讯飞 WebSocket 已连接")

                        # ── 首帧 ──────────────────────────────────
                        first_chunk = self._pop_audio_chunk()
                        if first_chunk is None:
                            deadline = time.monotonic() + (FRAME_DURATION_SEC * 2)
                            while not self._stop_event.is_set() and time.monotonic() < deadline:
                                await asyncio.sleep(0.005)
                                first_chunk = self._pop_audio_chunk()
                                if first_chunk is not None:
                                    break

                        # 语言参数
                        if self._language == "en":
                            lang = "en_us"
                        elif self._language == "zh":
                            lang = "zh_cn"
                        else:
                            lang = None
                        start_frame = json.dumps({
                            "common": {"app_id": self._app_id},
                            "business": {
                                **({"language": lang} if lang else {}),
                                "domain": "iat",
                                **({"accent": "mandarin"} if lang in ("zh_cn", None) else {}),
                                "vad_eos": self._vad_eos_ms,
                                "dwa": "wpgs",
                                "nbest": 1,
                                **({"ent": "1"} if lang == "zh_cn" else {}),
                            },
                            "data": {
                                "status": 0,
                                "format": "audio/L16;rate=16000",
                                "encoding": "raw",
                                "audio": base64.b64encode(first_chunk or b"").decode(),
                            },
                        })
                        await ws.send(start_frame)
                        self._ws_connected.set()

                        # ── 并行：发送音频 + 接收结果 ──────────────
                        send_task = asyncio.create_task(self._send_audio(ws))
                        recv_task = asyncio.create_task(self._recv_results(ws))

                        await send_task
                        recv_timeout = max(5.0, 5.0 + self.get_recorded_duration_sec() / 10.0 * 3.0)
                        try:
                            await asyncio.wait_for(recv_task, timeout=recv_timeout)
                        except asyncio.TimeoutError:
                            logger.warning("等待讯飞最终结果超时（%.1fs），使用当前结果返回", recv_timeout)
                            recv_task.cancel()
                            try:
                                await recv_task
                            except asyncio.CancelledError:
                                pass

                except Exception as e:
                    if not self._ws_connected.is_set() and self._reconnect_count == 0:
                        self._start_error = f"讯飞 WebSocket 连接失败: {e}"
                        self._ws_connected.set()
                        self._result_event.set()
                        return
                    logger.warning("讯飞 WebSocket 会话异常: %s", e)

                # ── 检查是否需要重连 ──────────────────────────────
                # VAD 触发了会话结束，且用户没有主动停止录音 → 自动重连
                if self._vad_ended.is_set() and not self._stop_event.is_set():
                    self._reconnect_count += 1
                    if self._reconnect_count > self._MAX_RECONNECT:
                        logger.warning("讯飞 VAD 重连次数已达上限（%d 次），结束识别", self._MAX_RECONNECT)
                        self._result_event.set()
                        break
                    logger.info(
                        "VAD 触发会话结束，自动重连（第 %d/%d 次）...",
                        self._reconnect_count, self._MAX_RECONNECT,
                    )
                    # 重连时保留已识别文本：合并到 _final_result 中作为前缀
                    # 清空 _segment_map 以避免新旧会话的 sn 编号冲突
                    with self._result_lock:
                        existing = self._final_result or self._partial_result or ""
                        self._segment_map.clear()
                        self._partial_result = ""
                        self._final_result = existing  # 保留前缀
                    # 只重置 _result_event 和 _ws_connected 供下次会话使用
                    await asyncio.sleep(0.1)  # 短暂延迟避免频繁重连
                    continue
                else:
                    # 用户主动停止或正常结束，退出循环
                    break

        except Exception as e:
            logger.error("讯飞 WebSocket 异常: %s", e)
            if not self._ws_connected.is_set():
                self._start_error = f"讯飞 WebSocket 启动失败: {e}"
                self._ws_connected.set()
            self._result_event.set()

    # ─────────────────────────────────────────────────────────────
    # 发送音频
    # ─────────────────────────────────────────────────────────────

    def _pop_audio_chunk(self) -> Optional[bytes]:
        with self._audio_lock:
            if not self._audio_queue:
                return None
            return self._audio_queue.popleft()

    def _append_audio_chunk(self, data: bytes) -> None:
        with self._audio_lock:
            self._audio_queue.append(data)

            # 建连前只保留最近一小段音频，既补上首字，又避免建连后长期追赶积压。
            if not self._ws_connected.is_set() or self._start_error:
                while len(self._audio_queue) > self._startup_prebuffer_frames:
                    self._audio_queue.popleft()
                return

            # 网络抖动时保留更长的上行缓冲，避免长语音丢帧。
            # 阈值提高到 600/500 帧（24s/20s），支持更长语音不丢失
            if len(self._audio_queue) > 600:
                dropped = len(self._audio_queue) - 500
                while len(self._audio_queue) > 500:
                    self._audio_queue.popleft()
                logger.warning("讯飞音频发送队列积压，已丢弃 %d 帧旧音频", dropped)

    async def _send_audio(self, ws) -> None:
        """从音频队列取数据，按 40ms 间隔发送到 WebSocket。"""
        last_send = time.monotonic()

        while True:
            chunk = self._pop_audio_chunk()
            with self._audio_lock:
                queue_empty = not self._audio_queue

            if chunk:
                audio_b64 = base64.b64encode(chunk).decode()
                frame = json.dumps({
                    "data": {
                        "status": 1,
                        "format": "audio/L16;rate=16000",
                        "encoding": "raw",
                        "audio": audio_b64,
                    }
                })
                try:
                    await ws.send(frame)
                except Exception:
                    break

                # 控制发送节奏：每 40ms 一帧
                elapsed = time.monotonic() - last_send
                if elapsed < SEND_INTERVAL:
                    await asyncio.sleep(SEND_INTERVAL - elapsed)
                last_send = time.monotonic()
            else:
                if self._stop_event.is_set() and self._record_stopped.is_set() and queue_empty:
                    break
                await asyncio.sleep(0.02)

        # ── 结束帧 ───────────────────────────────────────────
        try:
            end_frame = json.dumps({
                "data": {
                    "status": 2,
                    "format": "audio/L16;rate=16000",
                    "encoding": "raw",
                    "audio": "",
                }
            })
            await ws.send(end_frame)
            logger.debug("结束帧已发送")
        except Exception:
            pass

    # ─────────────────────────────────────────────────────────────
    # 接收结果
    # ─────────────────────────────────────────────────────────────

    def _compose_text(self) -> str:
        with self._result_lock:
            prefix = self._final_result or ""
            current = "".join(self._segment_map[idx] for idx in sorted(self._segment_map))
            return prefix + current

    async def _recv_results(self, ws) -> None:
        """持续接收识别结果，直到服务端确认识别完成或连接关闭。"""
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=5.0)
                except asyncio.TimeoutError:
                    continue
                except Exception:
                    break

                try:
                    data = json.loads(msg)
                except json.JSONDecodeError:
                    continue

                code = data.get("code", -1)
                if code != 0:
                    logger.error("讯飞返回错误: code=%s, message=%s, sid=%s",
                                 code, data.get("message", ""), data.get("sid", ""))
                    if code == 10106:  # 无效参数
                        break
                    if code == 10107:  # 非法参数
                        break
                    if code == 10110:  # 无授权
                        logger.error("请检查讯飞 APPID/APIKey/APISecret 是否正确")
                        break
                    if code == 10114:  # 引擎未授权
                        logger.error("请确保应用已添加\"语音听写（流式版）\"服务")
                        break
                    continue

                result_data = data.get("data", {})
                result = result_data.get("result", {})
                ws_list = result.get("ws", [])

                text_parts = []
                for ws_item in ws_list:
                    for cw in ws_item.get("cw", []):
                        text_parts.append(cw.get("w", ""))

                text = "".join(text_parts)
                if not text:
                    continue

                is_final = result.get("ls", False)
                pgs = result.get("pgs", "")
                rg = result.get("rg", [])
                sn = int(result.get("sn", len(self._segment_map) + 1) or (len(self._segment_map) + 1))

                with self._result_lock:
                    if pgs == "rpl" and rg and len(rg) == 2:
                        start_sn = int(rg[0])
                        end_sn = int(rg[1])
                        for seg_sn in range(start_sn, end_sn + 1):
                            self._segment_map.pop(seg_sn, None)
                        self._segment_map[sn] = text
                    else:
                        self._segment_map[sn] = text

                    # 拼接文本：前缀（重连前已识别的）+ 当前会话新识别的
                    prefix = self._final_result or ""
                    current_session = "".join(self._segment_map[idx] for idx in sorted(self._segment_map))
                    composed = prefix + current_session
                    if is_final:
                        self._final_result = composed
                        self._partial_result = composed
                    else:
                        self._partial_result = composed

                # 回调通知
                if is_final:
                    display = self._final_result
                    if self._on_final_text and display:
                        try:
                            self._on_final_text(display)
                        except Exception:
                            pass
                else:
                    display = self._partial_result
                    if self._on_partial_text and display:
                        try:
                            self._on_partial_text(display)
                        except Exception:
                            pass

                if result_data.get("status") == 2:
                    # status=2 表示服务端结束了当前识别会话
                    # 如果用户没有主动停止录音，说明是 VAD 触发的会话结束
                    if not self._stop_event.is_set():
                        logger.info("讯飞 VAD 触发会话结束（status=2），标记重连")
                        self._vad_ended.set()
                    else:
                        logger.info("讯飞识别完成（status=2）")
                    break
        finally:
            with self._result_lock:
                prefix = self._final_result or ""
                current_session = "".join(self._segment_map[idx] for idx in sorted(self._segment_map))
                composed = prefix + current_session
                if composed:
                    self._final_result = composed
                    self._partial_result = composed
            self._result_event.set()

    # ─────────────────────────────────────────────────────────────
    # 录音循环
    # ─────────────────────────────────────────────────────────────

    def _record_loop(self) -> None:
        """录音线程：采集音频 → 放入队列供 WebSocket 发送。"""
        try:
            import pyaudio
        except ImportError:
            logger.error("pyaudio 未安装")
            self._result_event.set()
            return

        pa = pyaudio.PyAudio()
        stream = None

        try:
            stream = pa.open(
                format=pyaudio.paInt16,
                channels=1,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=FRAME_SAMPLES,
            )
            logger.info("麦克风已打开，开始讯飞实时听写")

            while not self._stop_event.is_set():
                try:
                    data = stream.read(FRAME_SAMPLES, exception_on_overflow=False)
                    if len(data) != FRAME_BYTES:
                        logger.debug("讯飞音频帧大小异常: got=%d, expected=%d", len(data), FRAME_BYTES)
                    with self._recorded_pcm_lock:
                        self._recorded_pcm.extend(data)
                    self._append_audio_chunk(data)
                except Exception as e:
                    logger.debug("读取麦克风失败: %s", e)
                    break

        except Exception as e:
            logger.error("录音线程异常: %s", e)
        finally:
            if stream:
                try:
                    stream.stop_stream()
                    stream.close()
                except Exception:
                    pass
            pa.terminate()
            self._record_stopped.set()
            logger.debug("录音线程结束")

    # ─────────────────────────────────────────────────────────────
    # 兼容接口
    # ─────────────────────────────────────────────────────────────

    def _extract_pcm_from_wav(self, audio_bytes: bytes) -> bytes:
        """从 WAV bytes 中提取 16kHz/mono/16bit PCM 数据。"""
        try:
            with wave.open(io.BytesIO(audio_bytes), "rb") as wf:
                channels = wf.getnchannels()
                sample_width = wf.getsampwidth()
                sample_rate = wf.getframerate()
                comp_type = wf.getcomptype()
                pcm_data = wf.readframes(wf.getnframes())
        except Exception as e:
            logger.error("讯飞批量转录失败，WAV 解析异常: %s", e)
            return b""

        if comp_type != "NONE":
            logger.error("讯飞批量转录仅支持未压缩 WAV，当前 comptype=%s", comp_type)
            return b""
        if channels != 1 or sample_width != 2 or sample_rate != SAMPLE_RATE:
            logger.error(
                "讯飞批量转录仅支持 16kHz/mono/16bit WAV，当前=%dHz/%dch/%dB",
                sample_rate,
                channels,
                sample_width,
            )
            return b""

        return pcm_data

    def transcribe(self, audio_bytes: bytes, language: Optional[str] = None) -> str:
        """批量转录 WAV bytes（复用讯飞 WebSocket 流式接口）。"""
        self.ensure_loaded()
        if not audio_bytes:
            return ""

        pcm_data = self._extract_pcm_from_wav(audio_bytes)
        if not pcm_data:
            return ""

        chunks = [
            pcm_data[i:i + FRAME_BYTES]
            for i in range(0, len(pcm_data), FRAME_BYTES)
        ]
        if not chunks:
            return ""

        duration_sec = len(pcm_data) / float(SAMPLE_RATE * 2)
        logger.info("讯飞批量转录开始: duration=%.2fs", duration_sec)

        original_language = self._language
        with self._result_lock:
            self._final_result = ""
            self._partial_result = ""
            self._segment_map.clear()
        self._result_event.clear()
        self._ws_connected.clear()
        self._start_error = None
        self._is_listening.clear()
        self._stop_event.set()
        self._record_stopped.set()
        with self._audio_lock:
            self._audio_queue.clear()
            self._audio_queue.extend(chunks)

        if language:
            self._language = language

        try:
            import websockets
        except ImportError:
            logger.error("websockets 未安装，请运行: pip install websockets")
            return ""

        loop = asyncio.new_event_loop()
        try:
            asyncio.set_event_loop(loop)
            loop.run_until_complete(self._ws_main(websockets))
        except Exception as e:
            logger.error("讯飞批量转录失败: %s", e)
            return ""
        finally:
            asyncio.set_event_loop(None)
            loop.close()
            self._language = original_language
            self._stop_event.clear()
            self._record_stopped.clear()
            self._ws_connected.clear()
            with self._audio_lock:
                self._audio_queue.clear()

        with self._result_lock:
            result = (self._final_result or self._partial_result or "").strip()

        logger.info("讯飞批量转录完成: %s", result[:80] if result else "(空)")
        return result

    # ─────────────────────────────────────────────────────────────
    # 工厂方法
    # ─────────────────────────────────────────────────────────────

    @classmethod
    def from_config(
        cls,
        config: dict,
        on_partial_text: Optional[Callable[[str], None]] = None,
        on_final_text: Optional[Callable[[str], None]] = None,
    ) -> "XunfeiRealtimeEngine":
        xf_cfg = config.get("xunfei", {})

        app_id = xf_cfg.get("app_id", "") or os.environ.get("XUNFEI_APP_ID", "")
        api_key = xf_cfg.get("api_key", "") or os.environ.get("XUNFEI_API_KEY", "")
        api_secret = xf_cfg.get("api_secret", "") or os.environ.get("XUNFEI_API_SECRET", "")

        return cls(
            app_id=str(app_id),
            api_key=str(api_key),
            api_secret=str(api_secret),
            language=str(config.get("language", "zh")),
            vad_eos_ms=int(xf_cfg.get("vad_eos_ms", 8000) or 8000),
            # 注意：配置键名为 startup_prebuffer_ms（毫秒值），需转换为秒
            startup_prebuffer_sec=max(0.12, float(xf_cfg.get("startup_prebuffer_ms", 800) or 800) / 1000.0),
            on_partial_text=on_partial_text,
            on_final_text=on_final_text,
        )

    def __repr__(self) -> str:
        status = "监听中" if self._is_listening.is_set() else ("已加载" if self._loaded else "未加载")
        return f"XunfeiRealtimeEngine(app_id={self._app_id[:4]}..., {status})"
