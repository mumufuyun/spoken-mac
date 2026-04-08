# Whisper 本地语音识别方案研究

> Last updated: 2026-04-06

---

## 一、whisper.cpp 简介

GitHub: https://github.com/ggml-org/whisper.cpp

OpenAI Whisper 的 C/C++ 实现，专为本地推理优化：
- Apple Silicon 优先支持（Metal GPU + CoreML ANE 加速）
- Mac OS 上支持 Vulkan/Metal
- 纯 C/C++，无外部依赖
- 支持 VAD（语音活动检测）

---

## 二、Mac 安装方式

### 方式 1：brew（推荐）
```bash
brew install whisper-cpp
```
自动安装 CLI 和 server 二进制文件。

### 方式 2：从源码编译
```bash
git clone https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
brew install cmake sdl2
cmake -B build -DWHISPER_SDL2=ON
cmake --build build --config Release
```

---

## 三、模型选择

### 模型对比

| 模型 | 文件大小 | Mac 内存占用 | CPU 速度 | 中文准确率 | 推荐用途 |
|------|---------|-------------|---------|-----------|---------|
| tiny | 75 MB | ~273 MB | 10x realtime | 一般 | 极轻量场景 |
| base | 142 MB | ~388 MB | 7x realtime | 够用 | **推荐首选** |
| small | 466 MB | ~852 MB | 3x realtime | 较好 | 高质量需求 |
| medium | 1.5 GB | ~2.1 GB | 1x realtime | 好 | 最高质量 |

> 速度基准：Mac mini M2，real-time = 1x

### 模型下载
```bash
# 通过 huggingface 下载
huggingface-cli download ggerganov/whisper.cpp models/ggml-base.bin --local-dir ./models

# 或用脚本
cd whisper.cpp
./models/download-ggml-model.sh base
```

---

## 四、流式识别方案

whisper.cpp 有两个相关工具：

### 方案 A：whisper-server（HTTP 服务）

启动本地 HTTP 服务，客户端发送音频文件，服务器返回识别结果。

```bash
# 启动服务
./build/bin/whisper-server \
  -m ./models/ggml-base.bin \
  --port 8080 \
  -t 4 \
  --language zh

# 客户端调用（文件方式）
curl -X POST http://127.0.0.1:8080/inference \
  -F "file=@audio.wav" \
  -F "language=zh" \
  -F "response_format=json"
```

**问题：** 这个 server 是文件方式，不适合实时流式。

### 方案 B：whisper-stream（实时流，推荐）

专门为麦克风实时输入设计的流式工具：
```bash
./build/bin/whisper-stream \
  -m ./models/ggml-base.bin \
  -t 8 \
  --step 500 \
  --length 5000 \
  --language zh
```

参数说明：
- `--step 500`：每 500ms 采样一次音频
- `--length 5000`：每次送 5000ms 的音频给识别引擎
- `-t 8`：8 线程

**支持 VAD 模式（语音活动检测）：**
```bash
./build/bin/whisper-stream \
  -m ./models/ggml-base.bin \
  -t 6 \
  --step 0 \
  --length 30000 \
  -vth 0.6 \
  --language zh
```
- `--step 0` 开启 VAD 模式
- `-vth 0.6` 语音检测阈值
- 检测到静音后自动输出识别结果

---

## 五、CoreML 加速（Mac Silicon）

Mac M1/M2/M3 支持 CoreML ANE 加速，推理速度快 3-5x。

### 1. 生成 CoreML 模型
```bash
# 需要 Python 环境
pip install ane_transformers openai-whisper coremltools

# 生成 base.en 模型
./models/generate-coreml-model.sh base.en
```

### 2. 使用 CoreML 加速
```bash
# 构建时启用 CoreML
cmake -B build -DWHISPER_COREML=ON
cmake --build build --config Release

# 运行
./build/bin/whisper-stream \
  -m ./models/ggml-base.en-encoder.mlmodelc \
  --backend coreml \
  --step 500 \
  --length 5000
```

---

## 六、spoken 的集成方案

### 架构设计
```
Spoken App
    │
    ├── 麦克风录音 (AudioCaptureEngine)
    │       ↓ 音频 chunk (16kHz, 16bit PCM)
    │
    ├── whisper-stream 子进程
    │       ↓ stdin 实时流 或 HTTP API
    │       ↓ partial / final 识别结果
    │
    ├── MiniMaxService (AI 优化)
    │       ↓ 优化后文本
    │
    └── TextInjectionEngine (注入到焦点窗口)
```

### 推荐方案

**方案：whisper-stream 作为子进程 + stdin 管道**

理由：
1. whisper-stream 支持实时麦克风输入
2. 输出格式简单，便于解析
3. 不需要额外 HTTP 服务
4. 支持 VAD，自动检测说话停顿

### 集成步骤

1. **安装 whisper.cpp**
   ```bash
   brew install whisper-cpp
   # 或从源码编译
   ```

2. **下载 base 模型**
   ```bash
   ./models/download-ggml-model.sh base
   ```

3. **启动 whisper-stream 子进程**
   ```swift
   // Process.launch("/path/to/whisper-stream", arguments: [...])
   // 通过 stdout 管道读取识别结果
   ```

4. **发送音频到 stdin**
   ```swift
   // 16kHz PCM 音频数据
   // fwrite(audioData, 1, audioData.count, stdin)
   ```

5. **解析输出**
   whisper-stream 输出格式：
   ```
   [00:00.000 --> 00:02.500] 你好
   [00:02.500 --> 00:05.000] 今天天气不错
   ```

---

## 七、备选方案：whisper.cpp HTTP Server

如果 whisper-stream 不好集成，可以用 whisper-server：

```bash
# 启动服务
./build/bin/whisper-server \
  -m ./models/ggml-base.bin \
  --port 8080 \
  -t 4 \
  --language zh

# spoken 调用
curl -X POST http://127.0.0.1:8080/inference \
  -F "file=@/tmp/audio_chunk.wav" \
  -F "language=zh"
```

但这种方式延迟较高，不适合实时场景。

---

## 八、总结

| 方案 | 复杂度 | 实时性 | 集成难度 | 推荐度 |
|------|--------|--------|---------|--------|
| whisper-stream 子进程 | 低 | ✅ 好 | 中 | ⭐⭐⭐⭐ |
| whisper-server HTTP | 低 | ⚠️ 一般 | 低 | ⭐⭐⭐ |
| whisper-stream VAD 模式 | 中 | ✅ 好 | 中 | ⭐⭐⭐⭐⭐ |

**建议：** 先用 whisper-stream 跑通，VAD 模式优先（自动检测说话停顿）。

---

## 九、待验证事项

- [ ] Mac mini 上 whisper.cpp 是否需要从源码编译
- [ ] whisper-stream 的 VAD 模式对中文的支持
- [ ] CoreML 加速在 Mac mini (M1) 上的效果
- [ ] 集成到 Swift 项目的方式（Process vs NSTask）
- [ ] 模型大小 vs 速度的平衡点
