# Spoken for macOS

原生 macOS 菜单栏语音输入工具。通过全局快捷键录音，完成语音识别和 AI 优化后，
将文字直接输入当前焦点窗口。

## 功能

- **原生录音与识别**：AVAudioEngine + SFSpeechRecognizer
- **稳定的云端实时识别**：每次录音独立会话，支持自动重连、音频重放和本地降级
- **AI 优化**：MiniMax/OpenAI 兼容接口
- **文本注入**：通过辅助功能和系统剪贴板写入焦点窗口
- **场景化后处理**：原样转写、日常聊天、工作沟通、正式材料、会议记录、内容分享、AI 指令
- **独立输出语言**：任意场景可选择原语言、英文、日文或韩文
- **全局快捷键**：默认 `⌥ Space`，`Esc` 取消
- **菜单栏应用**：不占用 Dock

## 使用方式

### 菜单栏

1. 点击屏幕右上角的 Spoken 图标。
2. 选择处理模式。
3. 点击开始说话。
4. 完成后，文字会输入当前焦点窗口。

### 快捷键

1. 按 `⌥ Space` 弹出录音窗口。
2. 开始说话，再次触发快捷键结束录音。
3. 按 `Esc` 可取消当前录音。

### AI 指令与长语音

Spoken 对百炼 `qwen3.8-flash` 默认关闭深度思考，可在模型设置中单独开启。长文本的处理等待上限会随长度增加。AI 超时、未返回正文或输出不完整时，会保留原文并显示提示。

AI 指令模式会归并口述中的重复和分散事项，保留具体条件及不确定语气；已保存的自定义提示词仍优先使用。

参数策略、回退行为和验证方法见 [AI 后处理说明](docs/ai-postprocessing.md)。

## 开发

要求：macOS 14+、Xcode 15+。

```bash
xcodebuild \
  -project Spoken.xcodeproj \
  -scheme Spoken \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

也可以直接使用 Xcode 打开 `Spoken.xcodeproj`。

运行单元测试：

```bash
xcodebuild test \
  -project Spoken.xcodeproj \
  -scheme Spoken \
  -destination 'platform=macOS'
```

仅安装 Command Line Tools 时，可运行 AI 处理的离线回归：

```bash
bash scripts/run_offline_ai_tests.sh
```

该入口编译实际应用源码，使用内存配置和模拟 HTTP 响应，不读取 API Key、不修改应用设置，也不调用外部模型。

使用 Command Line Tools 构建本机试用版：

```bash
bash scripts/build_local_app.sh
```

产物位于 `build/Spoken.app`，仅做本地签名，不自动安装或启动。正式构建仍使用 Xcode。

首次运行需要授予：

- 麦克风权限
- 语音识别权限
- 辅助功能权限（用于向其他应用输入文字）

## 项目结构

```text
Spoken/
├── App/                 # 应用生命周期与窗口编排
├── Views/               # SwiftUI 界面
├── Services/            # 语音、AI、热键和文本注入服务
├── Models/              # 使用场景与配置迁移
├── Assets.xcassets/     # 应用资源
├── Info.plist
└── Spoken.entitlements

SpokenTests/
├── WritingSceneTests.swift          # 场景与提示词单元测试
├── CloudSessionTests.swift          # 云端识别与模型配置测试
└── Offline/AIProcessingRegression.swift # 不依赖XCTest的AI处理回归

scripts/
├── run_offline_ai_tests.sh          # 离线回归入口
├── build_local_app.sh               # 本地应用构建
└── run_prompt_evaluation.sh         # 手动真实模型评测，会产生调用费用

docs/                               # 实现与验证说明
```

云端稳定性面板只在本机保存会话、成功、失败、重连和降级次数，不保存音频或转录正文。

当前项目版本：2.0.16；本地构建脚本生成的构建号为216.1。
