#!/usr/bin/env python3
"""
Spoken Whisper 流式识别脚本
从麦克风实时读取音频，实时输出识别文本
"""
import sys
import os

# 确保用 Apple Silicon GPU（如果可用）
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import whisper
import numpy as np
import torch
import pyaudio
import threading
import time
import collections

# 配置
MODEL_SIZE = "small"          # tiny/base/small/medium/large
MODEL_DIR = "/Users/vincent/.cache/whisper"
LANGUAGE = "zh"
SAMPLE_RATE = 16000           # whisper 期望的采样率
CHUNK_DURATION = 3.0          # 每块音频秒数
SILENCE_DURATION = 2.0        # 静默超时（秒）
MIN_AUDIO_LENGTH = 0.5        # 最小音频长度（秒）

class StreamingWhisper:
    def __init__(self):
        print(f"[WhisperStream] Loading model {MODEL_SIZE}...", file=sys.stderr)
        self.model = whisper.load_model(MODEL_SIZE, download_root=MODEL_DIR)
        print(f"[WhisperStream] Model loaded", file=sys.stderr)
        
        self.audio_queue = collections.deque()
        self.running = False
        self.lock = threading.Lock()
        
        # PyAudio
        self.pyaudio = pyaudio.PyAudio()
        self.stream = None
        
    def audio_capture_thread(self):
        """后台线程：持续采集音频"""
        # 重采样到 16000Hz
        import scipy.signal
        
        def resample(audio_data, orig_sr):
            if orig_sr == SAMPLE_RATE:
                return audio_data
            num_samples = int(len(audio_data) * float(SAMPLE_RATE) / orig_sr)
            resampled = scipy.signal.resample(audio_data, num_samples)
            return resampled
        
        while self.running:
            try:
                if self.stream is None:
                    time.sleep(0.1)
                    continue
                    
                # 读取音频块
                chunk = self.stream.read(int(SAMPLE_RATE * CHUNK_DURATION / 2), exception_on_overflow=False)
                audio_np = np.frombuffer(chunk, dtype=np.float32)
                
                # 转为单声道 float32 [-1, 1]
                if len(audio_np.shape) > 1:
                    audio_np = audio_np.mean(axis=1)
                
                # 归一化
                if audio_np.max() > 1.0:
                    audio_np = audio_np / 32768.0
                
                with self.lock:
                    self.audio_queue.append(audio_np)
                    
            except Exception as e:
                print(f"[WhisperStream] Audio capture error: {e}", file=sys.stderr)
                time.sleep(0.1)
    
    def is_silent(self, audio_np, threshold=0.01):
        """判断音频是否静音"""
        return np.abs(audio_np).mean() < threshold
    
    def run(self):
        """主循环"""
        # 打开麦克风
        self.stream = self.pyaudio.open(
            format=pyaudio.paFloat32,
            channels=1,
            rate=int(self.model.audio_context * 100),  # whisper 的采样率
            input=True,
            frames_per_buffer=int(SAMPLE_RATE * CHUNK_DURATION / 2)
        )
        
        # 启动音频采集线程
        self.running = True
        capture_thread = threading.Thread(target=self.audio_capture_thread)
        capture_thread.daemon = True
        capture_thread.start()
        
        # 等待初始音频积累
        time.sleep(0.5)
        
        print(f"[WhisperStream] Started. Listening...", file=sys.stderr)
        
        last_text = ""
        silence_start = None
        
        try:
            while self.running:
                time.sleep(0.3)  # 轮询间隔
                
                with self.lock:
                    if len(self.audio_queue) < 2:
                        continue
                    # 合并所有音频块
                    all_audio = np.concatenate(list(self.audio_queue))
                    self.audio_queue.clear()
                
                # 检查最小长度
                if len(all_audio) / SAMPLE_RATE < MIN_AUDIO_LENGTH:
                    continue
                
                # 转 MEL spectrogram
                mel = whisper.log_mel_spectrogram(all_audio, model=self.model.dims.n_mels).to(self.model.device)
                
                # 识别（temperature=0 最准确）
                # 不做 beam search，用 greedy 加快速度
                result = self.model.decode(mel, whisper.decoding.DecodingOptions(temperature=0))
                text = result.text.strip()
                
                if text:
                    print(f"[PARTIAL] {text}")
                    last_text = text
                    silence_start = None
                else:
                    # 静音检测
                    if silence_start is None:
                        silence_start = time.time()
                    elif time.time() - silence_start > SILENCE_DURATION and last_text:
                        print(f"[FINAL] {last_text}")
                        last_text = ""
                        silence_start = None
                        
        except KeyboardInterrupt:
            print("[WhisperStream] Stopped", file=sys.stderr)
        finally:
            self.running = False
            if self.stream:
                self.stream.stop_stream()
                self.stream.close()
            self.pyaudio.terminate()

if __name__ == "__main__":
    # 检查 pyaudio
    try:
        import pyaudio
    except ImportError:
        print("pyaudio not installed. Run: pip3 install pyaudio")
        sys.exit(1)
    
    streamer = StreamingWhisper()
    streamer.run()
