# Spoken 项目技术架构梳理与优化方案

> 生成时间：2026-05-04
> 代码总量：1,957 行 Swift
> 文件数：12 个 Swift 文件

---

## 一、技术架构全景

### 1.1 架构分层

```
┌─────────────────────────────────────────────────────────────┐
│                      UI 层 (SwiftUI)                         │
│  ┌─────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │ ContentView │  │ RecordingPanel  │  │   WaveformView  │  │
│  │ (菜单栏面板) │  │  (快捷键浮动窗)  │  │   (波形动画)     │  │
│  └─────────────┘  └─────────────────┘  └─────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                    应用层 (AppDelegate)                       │
│         状态机 · 生命周期 · 窗口管理 · 流程编排                 │
├─────────────────────────────────────────────────────────────┤
│                      服务层 (Services)                        │
│  Speech ──→ MiniMax ──→ Keyboard ──→ HotKey ──→ Notify    │
│    │          │           │          │          │           │
│    ↓          ↓           ↓          ↓          ↓           │
│ AVAudio   URLSession   TextInjection Carbon    UNUser      │
│ Engine    (同步回调)    Engine      HIToolbox  Notification│
├─────────────────────────────────────────────────────────────┤
│                      系统框架层                               │
│      SFSpeechRecognizer · AppKit · CoreGraphics · AX        │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 核心数据流

```
[用户按 ⌥+空格] → HotKeyService
         ↓
[AppDelegate] 保存 frontmostApp → 显示 RecordingPanel
         ↓
[SpeechService] AVAudioEngine → SFSpeechRecognizer
         ↓ (onFinal 回调)
[RecordingViewModel] processAndInput()
         ↓
[MiniMaxService] 网络请求 (非 direct 模式)
         ↓ (completion 回调)
[AppDelegate.onComplete] activate() 目标 App
         ↓
[KeyboardService → TextInjectionEngine] 剪贴板 + ⌘V 模拟
         ↓
[2秒后] finishClipboardRestore() → 恢复剪贴板
```

### 1.3 当前项目结构

```
Spoken/
├── App/
│   ├── main.swift              # 6行，手动 NSApplication
│   └── AppDelegate.swift       # 723行，臃肿，含6个类型定义
├── Services/
│   ├── HotKeyService.swift     # 101行，Carbon 快捷键
│   ├── SpeechService.swift     # 251行，SFSpeechRecognizer
│   ├── MiniMaxService.swift    # 316行，AI API 调用
│   ├── TextInjectionEngine.swift # 221行，剪贴板注入
│   ├── KeyboardService.swift   # 29行，注入包装器
│   ├── AccessibilityService.swift # 28行，未使用
│   ├── NotificationService.swift  # 51行，未使用
│   └── StateManager.swift      # 43行，与 AppDelegate 中重复
├── Views/
│   └── ContentView.swift       # 161行，菜单栏 UI
└── Extensions/
    └── Color+Hex.swift         # 27行，颜色扩展
```

---

## 二、技术债务清单（按严重程度排序）

### 🔴 P0 — 严重 / 必须立即修复

| # | 问题 | 位置 | 风险 |
|---|------|------|------|
| 1 | **API Key 硬编码** | `MiniMaxService.swift:7` | 反编译即可获取，密钥泄露风险 |
| 2 | **StateManager 重复定义** | `AppDelegate.swift:13` + `StateManager.swift:1` | 编译冲突隐患，维护混乱 |
| 3 | **语音识别实为云端，宣传为离线** | `SpeechService.swift:117` | `requiresOnDeviceRecognition = false`，与 README/PRD 的"离线识别"矛盾 |
| 4 | **HotKey 内存不安全** | `HotKeyService.swift:37-52` | `Unmanaged.passUnretained` + 闭包回调，释放后野指针 |
| 5 | **AppDelegate 臃肿（723行，7个类型）** | `AppDelegate.swift` | 严重违反 SRP，无法维护 |

### 🟠 P1 — 高 / 影响稳定性

| # | 问题 | 位置 | 风险 |
|---|------|------|------|
| 6 | **剪贴板恢复 race condition** | `TextInjectionEngine.swift:72-83` | 用户 2 秒内复制内容会被覆盖 |
| 7 | **通知服务注册但从未使用** | `NotificationService.swift` | 死代码，功能缺失（完成/失败无通知） |
| 8 | **AccessibilityService 未接入主流程** | `AccessibilityService.swift` | AppDelegate 直接内联 AX 检查，重复代码 |
| 9 | **缺少超时与降级机制** | `MiniMaxService` / `SpeechService` | 网络卡顿或识别失败时无兜底，UI 卡住 |
| 10 | ** frontmostApp 保存不一致** | `AppDelegate:141` vs `RecordingViewModel:333` | 两处保存可能指向不同应用 |

### 🟡 P2 — 中 / 影响工程质量和可扩展性

| # | 问题 | 位置 | 风险 |
|---|------|------|------|
| 11 | **Swift 并发模型老旧** | 全局 | 大量使用 `DispatchQueue.main.asyncAfter`，无 async/await |
| 12 | **死代码堆积** | `AppDelegate.swift` / `TextInjectionEngine.swift` | `VisualEffectView`、`WaveBar`、`tryAXSetFocusedTextValue` 等未使用 |
| 13 | **UserDefaults Key 硬编码散落** | `ContentView.swift` / `RecordingViewModel.swift` | 维护困难，拼写错误风险 |
| 14 | **快捷键完全硬编码** | `HotKeyService.swift:56-57` | 用户无法自定义 |
| 15 | **无单元测试 / UI 测试** | 全局 | 回归风险高 |
| 16 | **Entitlements 权限声明不全** | `Spoken.entitlements` | 缺少 `com.apple.security.temporary-exception.apple-events` 等 |
| 17 | **剪贴板恢复依赖 sleep 时序** | `TextInjectionEngine.swift` | 系统负载高时可能失效 |

### 🟢 P3 — 低 / 优化项

| # | 问题 | 位置 | 建议 |
|---|------|------|------|
| 18 | **Hex 颜色初始化未处理 `#` 前缀容错** | `Color+Hex.swift:6` | 输入 `#fff` 和 `fff` 行为不一致 |
| 19 | **Popover 和 RecordingPanel 状态未统一** | `AppDelegate.swift` | 两者独立管理，可能同时存在 |
| 20 | **MiniMax 模型名硬编码** | `MiniMaxService.swift:78` | 无法切换模型或兼容其他 OpenAI 格式 API |

---

## 三、根因分析

### 3.1 为什么这些问题会发生？

1. **快速迭代，缺乏代码审查** — 从文档看，项目在短时间内从 v0.1 冲到 v0.3，多个模块由不同 agent session 完成，缺乏统一 review。
2. **对参考项目 type4me 的理解停留在"复制代码"而非"理解架构"** — EXPERIENCE.md 也总结了这一点：边角情况和异常处理太薄。
3. **单文件多类型** — AppDelegate.swift 包含 `StateManager`、`AppDelegate`、`RecordingViewModel`、`RecordingPanelView`、`WaveBar`、`WaveformView`、`VisualEffectView` 七个类型，说明缺乏文件拆分意识。
4. **Swift 现代并发知识缺失** — 项目未使用 `async/await`、`Task`、`Actor`，导致回调地狱和时序控制依赖 `usleep`/`asyncAfter`。

### 3.2 与 type4me 的差距

| 维度 | type4me | Spoken 当前 |
|------|---------|-------------|
| 状态机 | 6 状态，1125 行，完备 | 6 状态，但分散在各处，不完备 |
| 超时兜底 | 每个 await 都有 timeout | 无 |
| Batch Fallback | streaming 断后重发完整音频 | 无 |
| 注入方式 | Task.detached 不阻塞主线程 | 主线程注入 |
| Speculative LLM | 录音时预热 LLM | 无 |
| 剪贴板恢复 | 可靠机制 | 有 race condition |

---

## 四、完整优化方案

### Phase 1 — 紧急修复（1-2 天）

**目标：消除安全风险和编译隐患，让现有功能稳定运行。**

1. **API Key 外部化**
   - 从代码中移除硬编码 Key
   - 改为从 `~/.config/spoken/config.json` 或 Keychain 读取
   - 提供首次启动配置界面或环境变量 fallback
   - 当前硬编码 Key 应立即在 MiniMax 控制台重置

2. **消除 StateManager 重复定义**
   - 删除 `AppDelegate.swift` 中的 `StateManager` 和 `AppState`
   - 统一使用 `Services/StateManager.swift`
   - 删除 `AppDelegate.swift` 中的 `StateManager` 内联定义

3. **修复语音识别离线/云端的准确描述**
   - 方案 A：改为真正的离线识别（`requiresOnDeviceRecognition = true`，需下载语言模型）
   - 方案 B：保持云端，修改 README/PRD 描述（推荐，离线识别质量通常不如云端）

4. **修复 HotKey 内存安全**
   - 将 `Unmanaged.passUnretained` 改为 `passRetained`，在 `unregister/deinit` 中 `release`
   - 或改用 Swift 安全的第三方库（如 `sindresorhus/KeyboardShortcuts`）

5. **拆分 AppDelegate.swift**
   - 提取 `RecordingViewModel.swift`
   - 提取 `RecordingPanelView.swift`
   - 提取 `WaveformView.swift`
   - 提取 `AppState.swift`
   - AppDelegate 只保留生命周期和窗口管理

### Phase 2 — 稳定性加固（2-3 天）

**目标：引入状态机、超时、降级，让全流程在异常情况下也能优雅退出。**

6. **引入真正的状态机（参考 type4me）**
   ```
   idle → starting → recording → processing → injecting → completed → idle
                    ↓ (错误)           ↓ (错误)        ↓ (错误)
                   error ─────────────────────────────────→ idle (forceReset)
   ```
   - 每个状态转换只允许特定前置状态
   - 提供 `forceReset()` 方法，任何状态都能回到 idle
   - 状态转换通过 `StateMachine` 统一处理，而非分散在各 Service

7. **全流程超时机制**
   - 录音启动超时：5 秒无音频 → 报错
   - 语音识别超时：30 秒无 final → 强制结束并返回当前 bestTranscription
   - AI 处理超时：15 秒 → 降级为直接输入原文
   - 注入超时：5 秒 → 仅复制到剪贴板，通知用户手动粘贴

8. **剪贴板恢复机制重构**
   - 问题：当前 2 秒后恢复，用户在期间复制的内容会被覆盖
   - 方案：
     - 方法 A：缩短恢复时间为 500ms（注入完成后立即恢复）
     - 方法 B：使用 `NSPasteboard.observe` 检测 changeCount 变化，变化后放弃恢复
     - 方法 C：不恢复剪贴板，改为使用 `CGEventPost` 直接逐字输入（慢但无剪贴板副作用）
   - 推荐：A + B 组合

9. **接入 NotificationService**
   - 注入成功 → `notifySuccess`
   - 注入失败 / AI 失败 / 权限不足 → `notifyFailure`
   - 录音超时无内容 → `notifyFailure("未检测到语音")`

10. **统一 frontmostApp 获取**
    - 在 `handleHotKey()` 单点获取，通过参数传递到 ViewModel
    - 移除 `RecordingViewModel.startRecording()` 中的重复获取

### Phase 3 — 架构现代化（3-5 天）

**目标：将回调地狱改造为 Swift 结构化并发，提升可维护性。**

11. **Swift 结构化并发改造**
    ```swift
    // Before: 嵌套 completion handler
    SpeechService.shared.startRecording(onPartial: { text in
        // ...
    }, onFinal: { text in
        MiniMaxService.shared.process(text: text, mode: mode) { result in
            DispatchQueue.main.async {
                // ...
                KeyboardService.shared.typeText(finalText)
            }
        }
    })

    // After: async/await + Task
    func handleRecording() async {
        do {
            let text = try await speechService.recordUntilSilence()
            let processed = try await miniMaxService.process(text, mode: mode)
                .timeout(15, fallback: text)
            await keyboardService.typeText(processed)
        } catch {
            await notify(error)
        }
    }
    ```

12. **Service 协议化**
    ```swift
    protocol SpeechRecognizing {
        func startRecording() -> AsyncThrowingStream<SpeechEvent, Error>
        func stopRecording()
    }
    
    protocol TextInjecting {
        func inject(_ text: String) async throws
    }
    
    protocol AIProcessing {
        func process(_ text: String, mode: SpokenMode) async throws -> String
    }
    ```
    - 便于 Mock 和测试
    - 便于未来替换 MiniMax 为其他模型

13. **引入依赖注入容器**
    - 使用简单工厂或 `EnvironmentValues` 替代 `Service.shared` 单例模式
    - 测试中可注入 Mock 服务

14. **配置管理统一化**
    ```swift
    @propertyWrapper
    struct AppConfig<T> {
        let key: String
        var wrappedValue: T { /* UserDefaults / Keychain */ }
    }
    ```
    - 统一 `spokenMode`、`translateLang`、`apiKey` 等配置读写

### Phase 4 — 功能扩展与工程完善（持续）

15. **可自定义快捷键**
    - 使用 `KeyboardShortcuts` 库或自己封装 Carbon API
    - 配置持久化到 UserDefaults
    - UI 中提供快捷键设置界面

16. **多模型支持**
    - 将 MiniMaxService 抽象为 `LLMProvider`
    - 支持 OpenAI / Claude / 本地 Ollama 等兼容 OpenAI API 格式的服务
    - 用户可自定义 Base URL、Model、API Key

17. **增加测试覆盖**
    - `TextInjectionEngine` 的剪贴板快照/恢复逻辑
    - `StateManager` 状态转换规则
    - `MiniMaxService` 的响应解析（Mock URLSession）
    - `SpeechService` 的静音检测逻辑

18. **引入 SwiftLint / SwiftFormat**
    - 统一代码风格
    - 强制文件长度限制（如 300 行）
    - 强制类型文档注释

19. **CI/CD 构建**
    - GitHub Actions 自动构建、签名、打包 DMG
    - 自动版本号管理

20. **真正的离线识别支持（可选）**
    - `SFSpeechRecognizer.supportsOnDeviceRecognition()` 检测
    - 允许用户选择"云端（准）"或"离线（快）"

---

## 五、推荐执行顺序

```
Week 1: Phase 1（紧急修复）
  Day 1: API Key 外部化 + StateManager 去重 + 拆分 AppDelegate
  Day 2: HotKey 内存安全修复 + 语音识别云端/离线说明修正

Week 2: Phase 2（稳定性）
  Day 3-4: 状态机重构 + 超时机制 + 剪贴板恢复修复
  Day 5: 接入通知 + frontmostApp 统一 + 真机测试

Week 3-4: Phase 3（现代化）
  Day 6-8: async/await 改造 + Service 协议化
  Day 9-10: 配置管理统一 + DI 引入

Week 5+: Phase 4（扩展）
  快捷键自定义 / 多模型 / 测试 / CI / SwiftLint
```

---

## 六、关键文件改造示例

### 6.1 AppDelegate 拆分后

```
Spoken/
├── App/
│   ├── main.swift
│   ├── AppDelegate.swift          # ~150行，仅生命周期
│   └── AppAssembly.swift          # 依赖注入配置
├── Core/
│   ├── AppState.swift             # 枚举
│   ├── StateMachine.swift         # 真正的状态机
│   └── AppConfig.swift            # 配置管理
├── Services/
│   ├── SpeechRecognizing.swift    # 协议
│   ├── SpeechService.swift        # 实现
│   ├── LLMProvider.swift          # 协议
│   ├── MiniMaxService.swift       # 实现
│   ├── TextInjecting.swift        # 协议
│   ├── TextInjectionEngine.swift  # 实现
│   ├── HotKeyService.swift
│   └── NotificationService.swift
├── Views/
│   ├── ContentView.swift
│   ├── RecordingPanelView.swift
│   └── WaveformView.swift
└── ViewModels/
    └── RecordingViewModel.swift
```

### 6.2 状态机核心设计

```swift
actor StateMachine {
    enum State: Equatable {
        case idle
        case starting
        case recording(startTime: Date)
        case processing(task: Task<Void, Never>)
        case injecting
        case postProcessing
    }
    
    private(set) var state: State = .idle
    
    func transition(to newState: State) -> Bool {
        guard canTransition(from: state, to: newState) else { return false }
        if case .processing(let task) = state { task.cancel() }
        state = newState
        return true
    }
    
    func forceReset() {
        if case .processing(let task) = state { task.cancel() }
        state = .idle
    }
    
    private func canTransition(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.idle, .starting): return true
        case (.starting, .recording): return true
        case (.starting, .idle): return true
        case (.recording, .processing): return true
        case (.recording, .idle): return true  // 取消
        case (.processing, .injecting): return true
        case (.processing, .idle): return true  // 取消/失败
        case (.injecting, .postProcessing): return true
        case (.postProcessing, .idle): return true
        default: return false
        }
    }
}
```

---

## 七、立即行动项（今天可以做）

1. ✅ **重置 MiniMax API Key** — 当前硬编码的 Key 已经暴露在代码中，必须立即在控制台重置
2. ✅ **删除 `AppDelegate.swift` 中的 StateManager** — 一行删除，消除重复定义
3. ✅ **移除死代码** — `VisualEffectView`、`WaveBar`、`tryAXSetFocusedTextValue`
4. ✅ **在 `KeyboardService.typeText` 成功/失败处调用 NotificationService**
5. ✅ **README 修正** — "离线识别"改为 "macOS 原生听写"，避免误导

---

*本方案可根据团队优先级和资源调整执行顺序。建议至少完成 Phase 1 后再发布新版本。*
