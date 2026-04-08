# Spoken 项目进度文档

> Last updated: 2026-04-09
> 下次继续：从这里开始，不需要再问"继续什么"

---

## 一、项目概述

**是什么：** macOS 菜单栏语音输入工具。⌥; 触发 → 说话 → AI 处理 → 文字注入到焦点 App

**核心技术链：**
```
麦克风 → 语音识别 → AI 优化 → 文本注入 → 目标窗口
```

**项目位置：** `~/Projects/spoken/`
**参考项目：** type4me（https://github.com/joewongjc/type4me）— 完美跑通，可直接参考

---

## 二、当前进度总览

| 模块 | 状态 | 说明 |
|------|------|------|
| 菜单栏入口 | ✅ 完成 | NSStatusItem + NSPopover |
| 全局快捷键 ⌥; | ✅ 完成 | Carbon HIToolbox |
| 语音录制 | ✅ 完成 | AVAudioEngine |
| 语音识别 | ✅ 完成 | SFSpeechRecognizer（离线识别） |
| MiniMax AI 处理 | ✅ 完成 | 6 种模式 |
| 文字注入 | ✅ 修复完成 | 剪贴板 + CGEvent ⌘V |
| 通知 | ✅ 完成 | UNUserNotificationCenter |
| 权限管理 | ✅ 完成 | 麦克风 + 辅助功能 |
| UI（ElevenLabs 风格） | ✅ 完成 | 暖白配色 |

**未完成 / 待测试：**
- 流式识别（VADWhisperService，pip install 卡住）
- 真机文字注入稳定性
- 全流程联调

---

## 三、技术架构

```
Spoken/
├── App/
│   ├── main.swift              # 入口，手动 NSApplication
│   └── AppDelegate.swift       # 菜单栏 + 快捷键 + 录音面板
├── Services/
│   ├── HotKeyService.swift     # ⌥; 全局快捷键
│   ├── SpeechService.swift     # SFSpeechRecognizer 语音识别
│   ├── WhisperService.swift    # openai-whisper CLI 识别（备用）
│   ├── VADWhisperService.swift # VAD + streaming whisper（未完成）
│   ├── KeyboardService.swift   # 文字注入入口
│   ├── TextInjectionEngine.swift # 剪贴板 + CGEvent ⌘V
│   ├── MiniMaxService.swift    # MiniMax AI 处理
│   ├── AccessibilityService.swift # 辅助功能权限
│   └── NotificationService.swift # 系统通知
├── Views/
│   └── ContentView.swift       # 菜单栏弹出 UI（6 种模式）
└── Extensions/
    └── Color+Hex.swift         # 颜色工具
```

---

## 四、关键代码说明

### 4.1 文字注入（最关键）

**原理：** 剪贴板方式
1. 保存原剪贴板内容
2. 写目标文字到剪贴板
3. 等 50ms
4. 模拟 ⌘V
5. 等 100ms
6. 2 秒后恢复原剪贴板

**文件：** `TextInjectionEngine.swift`

**usleep 参数（重要）：**
```swift
usleep(50_000)   // 50ms，等待剪贴板写入生效
usleep(100_000)   // 100ms，等待 ⌘V 的 CGEvent 生效 ← 曾写成 usleep(100)=0.1ms
```

**type4me vs Spoken：** type4me 用 `CGEventSource` 创建 event，Spoken 用 `nil`。差异未知，需要真机对比。

### 4.2 语音识别（SpeechService）

**方式：** SFSpeechRecognizer 离线识别

**流程：**
```
startRecording()
  → tap 音频写入 recognitionRequest
  → silence 2秒 → stopAndFinish()
  → onFinal 回调返回文字
```

**关键：** `stopAndFinish()` 是唯一出口，所有结束路径都走这里。

### 4.3 MiniMax AI（MiniMaxService）

**模型：** abab6.5s

**API Key：** `sk-cp-Feg_2DXayfN4ChLCbLTk3LvnnJRslowaGwb4grRbyTHNnjS4fJ-SvNRLRw2G62imJUoKVJG55blkhjnQ7V6o9Q1f-el5TfR5WDQj9q6l_LhyEsY16h0vB_E`

**6 种模式：**
| 模式 | prompt 策略 |
|------|------------|
| 直接输入 | 不调 AI，直接注入 |
| 润色 | 错别字+标点+重复+口语化 |
| Prompt | 重构为结构化 AI Prompt |
| 翻译 | 翻译为目标语言（英文/日文/韩文） |
| 摘要 | 提取核心要点 |
| 格式化 | 整理为 bullet points |

### 4.4 UI 模式选择

**文件：** `ContentView.swift`

**快捷键 ⌥; 的两种触发方式：**
1. 点击菜单栏图标 → 弹出 ContentView（轻量，直接注入）
2. 任意位置按 ⌥; → 弹出 RecordingPanel（大面板，录音+实时波形）

---

## 五、已修复的 Bug

### Bug 1: `finishWithFinal` 未调用 `onFinal`（最严重）
- **发现：** 2026-04-09 review
- **现象：** 静默超时后 onFinal 永远不触发，录音永远无结果
- **修复：** 统一 `stopAndFinish()` 入口，所有路径统一处理

### Bug 2: `usleep(100)` = 0.1 毫秒
- **发现：** 2026-04-09 review
- **问题：** 粘贴后几乎不等就继续，文本注入失败
- **修复：** 改为 `usleep(100_000)` = 100 毫秒

### Bug 3: 权限检查缺失
- **发现：** 2026-04-09 review
- **问题：** ContentView 录音前不检查权限，直接 start 导致崩溃
- **修复：** 录音前检查麦克风+辅助功能权限

### Bug 4: `onPartial` 回调漏掉
- **发现：** 2026-04-06，EXP 文档记录
- **问题：** 函数签名新增 `onPartial` 但实现里没有调用
- **修复：** 已修复

### Bug 5: Oray 虚拟音频驱动冲突
- **发现：** 2026-04-06，EXP 文档记录
- **问题：** 向日葵的虚拟音频驱动和 USB 麦克风冲突，tap 不触发
- **修复：** 删除 `/Library/Audio/Plug-Ins/HAL/OrayVirtualAudioDevice.driver`

---

## 六、下周末任务清单

### 必须做（阻塞）

#### 1. 真机测试文字注入
**位置：** Mac mini（外接 REDMI 音箱麦克风）
**测试步骤：**
```
1. 打开 Spoken
2. 打开备忘录 / 任何文本输入框
3. 按 ⌥; 
4. 说一句话
5. 停顿 2 秒
6. 看文字是否注入成功
```

**验证点：**
- [ ] ⌥; 是否正常触发
- [ ] 文字是否注入到焦点窗口
- [ ] 剪贴板是否恢复（说一句话前后，复制的内容是否保留）
- [ ] 6 种模式是否都正常

#### 2. pip install faster-whisper（VPN 环境）
```bash
pip install faster-whisper
```
如果失败，试：
```bash
pip install --no-cache-dir faster-whisper
# 或者用 conda
conda install -c conda-forge faster-whisper
```

**目的：** VADWhisperService 流式识别依赖此库

---

### 重要（不阻塞但想做）

#### 3. VADWhisperService 流式识别最终集成
**文件：** `VADWhisperService.swift`
**脚本：** `~/Projects/spoken/scripts/stream_whisper.py`
**依赖：** faster-whisper 安装成功

**架构：**
```
AVAudioEngine 录音
  → VAD（语音活动检测，silero-vad）
  → 流式发送音频到 Python HTTP Server（localhost:8765）
  → faster-whisper 实时返回文字
  → SSE 流回 Swift
```

#### 4. CGEventSource 优化
type4me 用 `CGEventSource(nil)` 创建 event，Spoken 用 `nil`。
可能影响：系统对合成事件的处理优先级。
**需要对比测试。**

---

## 七、type4me 参考信息

**关键文件（需要下载 DMG 看）：**
- `Type4Me/Injection/TextInjectionEngine.swift` — 文字注入
- `Type4Me/Session/RecognitionSession.swift` — 1125 行状态机
- `Type4Me/ASR/AppleASRClient.swift` — 苹果 ASR 封装

**DMG 下载：**
```
https://github.com/joewongjc/type4me/releases
→ Type4Me-v1.8.1-cloud.dmg
```

**重要参考实现细节：**
1. **状态机：** idle / starting / recording / finishing / injecting / postProcessing
2. **Batch Fallback：** streaming 断了，用完整音频重发一次
3. **Task.detached 注入：** 不阻塞主 actor
4. **Speculative LLM：** 录音时预热 LLM，减少感知延迟
5. **超时兜底：** 每个 await 都有 timeout，有 forceReset

---

## 八、MiniMax API 信息

**基础 URL：** `https://api.minimax.chat/v1`

**Chat API：** `POST /text/chatcompletion_v2`

**请求体：**
```json
{
  "model": "abab6.5s",
  "messages": [{"role": "user", "content": "..."}],
  "temperature": 0.3
}
```

**可能返回的格式（需要兼容）：**
```json
// 格式1
{"choices": [{"messages": [{"text": "..."}]}]}

// 格式2
{"choices": [{"message": {"content": "..."}}]}

// 格式3
{"output": "..."}
```

---

## 九、相关文件路径

| 文件 | 路径 |
|------|------|
| Spoken 项目根目录 | `~/Projects/spoken/` |
| Whisper 模型目录 | `~/.cache/whisper/small.pt` |
| type4me DMG | `~/Downloads/Type4Me-v1.8.1-cloud.dmg` |
| 本文档 | `~/Projects/spoken/PROGRESS.md` |
| 经验总结 | `~/Projects/spoken/EXPERIENCE.md` |

---

## 十、Git 提交记录（按时间顺序）

| 日期 | Commit | 内容 |
|------|--------|------|
| 2026-04-09 | `b08c1c9` | fix: SpeechService 录音结束回调 + usleep 参数 + 权限检查 + macOS14 兼容 |
| 2026-04-09 | `f7f7ba5` | feat: 6种工作模式 + 翻译语言选择 |
| 2026-04-07 | `03965b7` | refactor: UI 重构为 ElevenLabs 暖白风格 |
| 2026-04-07 | （更早） | 基础框架 + WhisperService |

---

*下次开始：git pull 后直接看本文档，不需要再问"继续什么"*
