#!/usr/bin/env python3
"""
VAD + faster-whisper 流式识别服务
架构：Swift录音 → ffmpeg流式写入PCM → Python消费 → SSE推送结果

启动方式：python3 stream_whisper.py <pipe_path>
"""

import sys
import os
import struct
import json
import threading
import numpy as np
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs
from socketserver import ThreadingMixIn
import signal

# 音频参数（与 Swift WhisperService 保持一致）
SAMPLE_RATE = 48000
CHANNELS = 1
BYTES_PER_SAMPLE = 2  # 16-bit

# faster-whisper 参数
MODEL_SIZE = "small"
MODEL_DIR = "/Users/vincent/.cache/whisper"
LANGUAGE = "zh"

# VAD 参数
VAD_THRESHOLD = 0.5
VAD_MIN_SPEECH_MS = 250
VAD_MIN_SILENCE_MS = 500
MAX_SEGMENT_SECS = 30  # 强制截断最大时长

# SSE 端口
PORT = 8765

# 全局变量
pipe_path = None
vad_model = None
whisper_model = None
current_segments = []  # 当前识别结果
final_text = ""  # 最终完整文本
is_recording = False
audio_buffer = bytearray()
lock = threading.Lock()


class SSEHandler(BaseHTTPRequestHandler):
    """SSE 流式输出 Handler"""
    
    def log_message(self, format, *args):
        pass  # 静默日志
    
    def do_GET(self):
        if self.path.startswith("/stream"):
            self.send_headers()
            self.serve_sse()
        elif self.path.startswith("/status"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            with lock:
                resp = {
                    "status": "ready" if whisper_model else "loading",
                    "final": final_text
                }
            self.wfile.write(json.dumps(resp).encode())
        else:
            self.send_error(404)
    
    def send_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
    
    def serve_sse(self):
        """保持连接，持续推送识别结果"""
        while True:
            try:
                with lock:
                    if current_segments:
                        # 发送最新识别段落
                        for seg in current_segments:
                            self.send_sse_event("partial", seg)
                        current_segments = []
                    elif final_text:
                        self.send_sse_event("final", final_text)
                
                threading.Event().wait(0.1)  # 100ms 轮询
            except (BrokenPipeError, ConnectionResetError):
                break
    
    def send_sse_event(self, event_type, data):
        try:
            payload = json.dumps({"type": event_type, "data": data})
            self.wfile.write(f"event: {event_type}\ndata: {payload}\n\n".encode())


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def load_models():
    """加载 VAD 和 Whisper 模型"""
    global vad_model, whisper_model
    
    # 加载 Silero VAD
    print("[stream_whisper] Loading Silero VAD...", file=sys.stderr)
    torch_impl = __import__("torch")
    torch = torch_impl
    torch.set_num_threads(4)
    
    # Silero VAD
    import torch
    torch.set_num_threads(4)
    silero_path = os.path.join(os.path.dirname(__file__), "silero_vad.jit")
    if os.path.exists(silero_path):
        vad_model = torch.jit.load(silero_path)
    else:
        # 动态下载
        torch_hub_dir = os.path.expanduser("~/.cache/torch")
        os.makedirs(torch_hub_dir, exist_ok=True)
        try:
            vad_model, _ = torch.hub.load(
                repo_or_dir="snakers4/silero-vad",
                model="silero_vad",
                trust_repo=True,
                verbose=False
            )
        except Exception as e:
            print(f"[stream_whisper] [WARN] Silero VAD load failed: {e}", file=sys.stderr)
            vad_model = None
    
    # 加载 faster-whisper
    print("[stream_whisper] Loading faster-whisper...", file=sys.stderr)
    from faster_whisper import WhisperModel
    whisper_model = WhisperModel(
        MODEL_SIZE,
        device="cpu",  # Mac M1/M2 用 cpu，GPU 用 cuda
        compute_type="int8",  # int8 量化，Mac CPU 上快
        download_root=MODEL_DIR
    )
    print("[stream_whisper] Models loaded!", file=sys.stderr)


def read_audio_chunk(pipe_fd, timeout=0.1):
    """从 named pipe 读取一个 chunk"""
    import select
    ready, _, _ = select.select([pipe_fd], [], [], timeout)
    if not ready:
        return b""
    return os.read(pipe_fd, 4096)


def process_audio_vad(audio_bytes):
    """
    用 VAD 检测语音段落，返回检测到的语音段
    audio_bytes: 原始 PCM 字节
    返回: (is_speech: bool, samples: np.ndarray)
    """
    if not vad_model or len(audio_bytes) < SAMPLE_RATE * BYTES_PER_SAMPLE * 0.1:
        # VAD 不可用或数据不足，返回默认有语音
        samples = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        return len(samples) > 0, samples
    
    # 转换为 float32 samples
    samples = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    
    # 按 30ms 一帧切分（与 Silero 训练一致）
    frame_size = int(SAMPLE_RATE * 0.03)  # 48000 * 0.03 = 1440 samples
    
    speech_probs = []
    for i in range(0, len(samples) - frame_size, frame_size):
        frame = samples[i:i+frame_size]
        with torch.no_grad():
            prob = vad_model(frame, SAMPLE_RATE).item()
        speech_probs.append(prob)
    
    if not speech_probs:
        return False, samples
    
    avg_prob = np.mean(speech_probs)
    is_speech = avg_prob > VAD_THRESHOLD
    
    return is_speech, samples


def recognize_segment(samples_np):
    """对一段音频进行识别"""
    if whisper_model is None:
        return ""
    
    try:
        segments, _ = whisper_model.transcribe(
            samples_np,
            language=LANGUAGE,
            vad_filter=False,  # 已在 VAD 层过滤
            beam_size=5,
            vad_parameters=None
        )
        
        text = "".join([seg.text for seg in segments])
        return text.strip()
    except Exception as e:
        print(f"[stream_whisper] [ERROR] whisper failed: {e}", file=sys.stderr)
        return ""


def run_vad_pipeline(pipe_path):
    """
    主 VAD pipeline
    从 named pipe 读取音频，用 VAD 检测语音段，
    每检测到一个语音段结束，立即调用 faster-whisper 识别并推送
    """
    global current_segments, final_text, is_recording, audio_buffer
    
    if not os.path.exists(pipe_path):
        print(f"[stream_whisper] [ERROR] pipe not found: {pipe_path}", file=sys.stderr)
        return
    
    # 打开 named pipe
    pipe_fd = os.open(pipe_path, os.O_RDONLY | os.O_NONBLOCK)
    
    # 重置状态
    with lock:
        is_recording = True
        audio_buffer = bytearray()
        current_segments = []
        final_text = ""
    
    speech_buffer = bytearray()
    silence_frames = 0
    FRAMES_TO_SILENCE = int(VAD_MIN_SILENCE_MS / 30)  # 500ms / 30ms ≈ 17 frames
    MIN_SPEECH_FRAMES = int(VAD_MIN_SPEECH_MS / 30)  # 250ms / 30ms ≈ 8 frames
    
    frame_size_bytes = int(SAMPLE_RATE * 0.03) * BYTES_PER_SAMPLE * CHANNELS
    
    print(f"[stream_whisper] VAD pipeline started, reading from {pipe_path}", file=sys.stderr)
    
    try:
        while True:
            # 从 pipe 读取
            import select
            ready, _, _ = select.select([pipe_fd], [], [], 0.1)
            
            if ready:
                chunk = os.read(pipe_fd, 8192)
                if not chunk:
                    break
                audio_buffer.extend(chunk)
            
            # 取最新一帧做 VAD 判断
            if len(audio_buffer) >= frame_size_bytes:
                # 用最新帧判断
                latest_bytes = audio_buffer[-frame_size_bytes:]
                is_speech, samples = process_audio_vad(bytes(latest_bytes))
                
                if is_speech:
                    speech_buffer.extend(latest_bytes)
                    silence_frames = 0
                else:
                    silence_frames += 1
                
                # 强制截断（最大段落长度）
                if len(speech_buffer) >= SAMPLE_RATE * BYTES_PER_SAMPLE * MAX_SEGMENT_SECS:
                    silence_frames = FRAMES_TO_SILENCE  # 触发识别
                
                # 静默超过阈值 → 语音段结束
                if silence_frames >= FRAMES_TO_SILENCE and len(speech_buffer) >= MIN_SPEECH_FRAMES * frame_size_bytes:
                    # 识别这段
                    seg_samples = np.frombuffer(bytes(speech_buffer), dtype=np.int16).astype(np.float32) / 32768.0
                    text = recognize_segment(seg_samples)
                    
                    if text:
                        with lock:
                            current_segments.append(text)
                        
                        # SSE 推送（在 HTTP 线程中做，这里只更新状态）
                        # HTTP Server 会自动发现 current_segments 变化并推送
                        print(f"[stream_whisper] [PARTIAL] {text}", file=sys.stderr)
                    
                    speech_buffer.clear()
                    silence_frames = 0
            
            # pipe 读完了，跳出
            if not ready and len(audio_buffer) < frame_size_bytes:
                break
        
        # 处理最后一段
        if speech_buffer and len(speech_buffer) >= MIN_SPEECH_FRAMES * frame_size_bytes:
            seg_samples = np.frombuffer(bytes(speech_buffer), dtype=np.int16).astype(np.float32) / 32768.0
            text = recognize_segment(seg_samples)
            if text:
                with lock:
                    current_segments.append(text)
                    final_text = "".join(current_segments)
                print(f"[stream_whisper] [FINAL] {final_text}", file=sys.stderr)
        
        # 最终全部合并
        with lock:
            final_text = "".join(current_segments)
            is_recording = False
        
    finally:
        os.close(pipe_fd)


def main():
    global pipe_path
    
    if len(sys.argv) < 2:
        print("Usage: python3 stream_whisper.py <pipe_path>")
        sys.exit(1)
    
    pipe_path = sys.argv[1]
    
    # 清理旧的 pipe
    if os.path.exists(pipe_path):
        os.unlink(pipe_path)
    os.mkfifo(pipe_path)
    
    # 加载模型（阻塞）
    load_models()
    
    # 启动 SSE HTTP 服务器
    server = ThreadedHTTPServer(("127.0.0.1", PORT), SSEHandler)
    http_thread = threading.Thread(target=server.serve_forever, daemon=True)
    http_thread.start()
    print(f"[stream_whisper] SSE server running on http://127.0.0.1:{PORT}/stream", file=sys.stderr)
    
    # 启动 VAD pipeline（阻塞）
    run_vad_pipeline(pipe_path)
    
    # 清理
    os.unlink(pipe_path)
    print("[stream_whisper] Done.", file=sys.stderr)


if __name__ == "__main__":
    main()
