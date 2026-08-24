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
```

云端稳定性面板只在本机保存会话、成功、失败、重连和降级次数，不保存音频或转录正文。

当前版本：2.0.10。
