# Spoken for macOS

原生 macOS 菜单栏语音输入工具。通过全局快捷键录音，完成语音识别和 AI 优化后，
将文字直接输入当前焦点窗口。

## 功能

- **原生录音与识别**：AVAudioEngine + SFSpeechRecognizer
- **稳定的云端实时识别**：每次录音独立会话，支持自动重连、音频重放和本地降级
- **模型连接**：MiniMax、DeepSeek、智谱、Kimi、千问及自定义 OpenAI 兼容接口；每个连接独立保存密钥
- **自定义模式**：额外添加最多三个模式，支持整理、翻译、问答和文案生成
- **两层提示词**：全局基础规则＋各模式的场景规则，支持编辑与恢复默认
- **深浅色界面**：模式网格、录音中切换、统一设置页面
- **文本注入**：通过辅助功能和系统剪贴板写入焦点窗口
- **场景化后处理**：原样转写、日常聊天、工作沟通、正式材料、会议记录、内容分享、AI 指令
- **独立输出语言**：任意场景可选择原语言、英文、日文或韩文
- **全局快捷键**：默认 `⌥ Space`，`Esc` 取消
- **菜单栏应用**：不占用 Dock

## 使用方式

### 菜单栏

1. 点击屏幕右上角的 Spoken 图标。
2. 选择处理模式。
3. 在目标应用按 `⌥ Space` 开始说话，再按一次结束。
4. 完成后，文字会输入目标窗口；录音期间可在浮窗中切换模式。

### 快捷键

1. 按 `⌥ Space` 弹出录音窗口。
2. 开始说话，再次触发快捷键结束录音。
3. 按 `Esc` 可取消当前录音。

### AI 指令与长语音

Spoken 对百炼 `qwen3.8-flash` 默认关闭深度思考，可在模型设置中单独开启。长文本的处理等待上限会随长度增加。AI 超时、未返回正文或输出不完整时，会保留原文并显示提示。

AI 回复经过正文解析、思考内容过滤和粘贴前复查。遇到无法可靠分离的内部过程或协议元数据时，会保留原转录并提示。详见 [AI 正文输出保障](docs/ai-output-safety.md)。

AI 指令模式会归并口述中的重复和分散事项，保留具体条件及不确定语气，只整理指令，不回答其中的问题。需要直接回答时，可创建自定义问答模式。

2.1 首次启动会先备份旧 Prompt，再统一启用新的两层结构。旧内容可在“模式与提示词 → 查看旧版 Prompt”复制。模型、地址和思考偏好保留，旧密钥仅迁移到当时正在使用的连接。

配置流程和订阅范围见 [自定义模式与模型接入](docs/customization.md)。

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

该入口编译实际应用源码，使用内存偏好、临时配置文件、模拟钥匙串和 HTTP 响应，不读取真实 API Key、不修改应用设置，也不调用外部模型。

生成原生界面检查图（仅合成数据，不启动录音）：

```bash
bash scripts/run_offline_ai_tests.sh --render-ui build/ui-preview
```

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

当前项目版本：2.1.1；本地构建脚本生成的构建号为218.1。
