# Spoken

> 语音输入 AI 优化工具 — macOS 菜单栏应用

把脑子里的语音快速转化成高质量文本，⌥V 说一句话，文字直接进到任何输入框。

---

## 功能

- 🎤 **语音录制** — 按住说话，松开自动识别
- 🤖 **AI 优化** — MiniMax 大模型，纠错 + 润色
- ⌨️ **直接输入** — 文字直接进焦点窗口，不需要粘贴
- ⚡ **离线识别** — macOS 原生听写，无需网络
- ⌥V **全局快捷键** — 任意界面随时触发
- 🔔 **通知提示** — 完成/失败系统通知

## 使用方式

### 方式一：菜单栏
1. 点击屏幕右上角 🎤 图标
2. 选择模式（文本 / Prompt）
3. 点击「开始说话」
4. 文字直接出现在光标处

### 方式二：快捷键
1. 按 **⌥V** 弹出浮动窗口
2. 点击开始说话
3. 说完后自动输入，窗口消失

## 模式

| 模式 | 说明 |
|------|------|
| 文本模式 | 语音 → 纠错润色 → 直接输入 |
| Prompt 模式 | 语音 → 结构化 Prompt → 直接输入 |

## 技术栈

- **语言:** Swift / SwiftUI
- **语音识别:** SFSpeechRecognizer（macOS 原生，离线）
- **AI 优化:** MiniMax API
- **快捷键:** Carbon HIToolbox
- **键盘模拟:** CGEvent

## 开发

```bash
# 安装依赖
brew install xcodegen

# 生成 Xcode 项目
xcodegen generate

# 编译
xcodebuild -project Spoken.xcodeproj -scheme Spoken -configuration Debug build
```

## 版本

- v0.1 — 基础框架 + 语音录制 + 离线识别 + 键盘输入
- v0.2 — MiniMax AI 优化接入
- v0.3 — ⌥V 浮动窗口 + 系统通知
