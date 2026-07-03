# Bug修复：AI处理失败后原文注入未执行

## 问题现象
用户反馈：AI 处理均显示失败，系统提示"使用原文"，但实际文本未完成注入到目标应用。

## 问题链分析

### 问题 1：AI 处理失败

**根因分析**：需要确认为什么 MiniMaxService.process() 总是返回 failure。

**可能原因**：

1. **API Key 问题**
   - [MiniMaxService.swift:8-18](file:///Users/vincent/Projects/spoken/Spoken/Services/MiniMaxService.swift#L8-L18) 中 API Key 从 Keychain 读取
   - 如果 Keychain 中无 Key 且硬编码 Key 为空，会导致 API 调用失败
   - **状态**：已添加硬编码 Key 和 UI 配置界面

2. **API 响应解析问题** ⚠️
   - [MiniMaxService.swift:332-351](file:///Users/vincent/Projects/spoken/Spoken/Services/MiniMaxService.swift#L332-L351) 解析 JSON 响应
   - 目前支持三种解析路径：
     - `choices[0].messages[0].text`（MiniMax 标准格式）
     - `choices[0].message.content`（OpenAI 兼容格式）
     - `output`（直接输出格式）
   - 如果 MiniMax API 返回格式有变化或字段名不同，会导致解析失败
   - **这是最可能的根因**

3. **网络超时问题**
   - [MiniMaxService.swift:42](file:///Users/vincent/Projects/spoken/Spoken/Services/MiniMaxService.swift#L42) 超时设置为 15 秒
   - [MiniMaxService.swift:272](file:///Users/vincent/Projects/spoken/Spoken/Services/MiniMaxService.swift#L272) URLRequest 超时为 60 秒
   - 如果网络不稳定或 API 响应慢，可能触发超时

### 问题 2：原文注入失败（核心问题）⚠️

**根因分析**：当 AI 处理失败时，系统应回退到原文注入，但注入也失败了。

**根因**：[TextInjectionEngine.swift:119-120](file:///Users/vincent/Projects/spoken/Spoken/Services/TextInjectionEngine.swift#L119-L120)

```swift
let hasFrontmostApp = NSWorkspace.shared.frontmostApplication != nil
let outcome: InjectionOutcome = hasFrontmostApp ? .inserted : .copiedToClipboard
```

**致命缺陷**：
- 只检查是否有前台应用，不检查是否是**目标应用**
- 如果注入时 Spoken 的 recordingPanel 仍是前台，`hasFrontmostApp` 为 true，返回 `.inserted`
- 但实际 CGEvent 粘贴可能注入到了 Spoken 自身而非目标应用

### 问题 3：注入时序问题

**根因分析**：[AppDelegate.swift](file:///Users/vincent/Projects/spoken/Spoken/App/AppDelegate.swift) 中的注入流程

1. 目标应用激活后立即开始注入（只等待 0.3-0.5s）
2. 输入框可能还未获得焦点
3. recordingPanel 仍在前台，干扰输入焦点

## 完整修复方案

### 修复 1：增强 AI 错误诊断

**文件**：`Spoken/Services/MiniMaxService.swift`

1. 添加 API Key 日志（打印前 10 个字符，方便排查）
2. 增强 JSON 解析错误日志，记录实际返回的字段名
3. 添加网络请求状态日志（HTTP 状态码等）

### 修复 2：修复 TextInjectionEngine 成功判断逻辑

**文件**：`Spoken/Services/TextInjectionEngine.swift`

修改 [injectViaClipboard](file:///Users/vincent/Projects/spoken/Spoken/Services/TextInjectionEngine.swift#L85-L131) 方法：

```swift
// 修改前：只检查是否有前台应用
let hasFrontmostApp = NSWorkspace.shared.frontmostApplication != nil
let outcome: InjectionOutcome = hasFrontmostApp ? .inserted : .copiedToClipboard

// 修改后：检查目标应用是否在前台
let frontmostApp = NSWorkspace.shared.frontmostApplication
let isSpokenFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier
let outcome: InjectionOutcome = (!isSpokenFrontmost) ? .inserted : .copiedToClipboard
```

### 修复 3：简化并修复 AppDelegate 注入流程

**文件**：`Spoken/App/AppDelegate.swift`

**核心修改**：

1. **注入前隐藏 recordingPanel**：避免焦点干扰
2. **固定等待 0.5s**：确保目标应用和输入框就绪
3. **移除复杂重试逻辑**：删除 `injectTextWithRetry`、`performInjectAttempt` 等方法
4. **增强兜底机制**：注入失败时将文本复制到剪贴板

```swift
viewModel.onComplete = { [weak self] text, appFromViewModel in
    guard let strongSelf = self else { return }
    let textToInject = text
    let targetApp = appFromViewModel ?? strongSelf.frontmostAppBeforeHotKey
    
    print("Spoken: [DEBUG] onComplete - text length: \(textToInject.count)")
    
    // 状态转换：finishing -> injecting
    strongSelf.stateManager.transition(to: .injecting)
    
    // 隐藏 recordingPanel，避免干扰目标应用焦点
    strongSelf.recordingPanel?.orderOut(nil)
    
    if let app = targetApp {
        app.activate(options: [.activateAllWindows])
    }
    
    // 等待 0.5s 确保目标应用就绪
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        print("Spoken: [DEBUG] frontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
        let success = KeyboardService.shared.typeText(textToInject)
        print("Spoken: [DEBUG] injection success: \(success)")
        
        if !success {
            // 剪贴板兜底
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(textToInject, forType: .string)
            print("Spoken: [DEBUG] text copied to clipboard as fallback")
        }
        
        // 更新 UI 状态
        DispatchQueue.main.async {
            strongSelf.recordingViewModel.statusText = "已完成 ✓"
            strongSelf.recordingViewModel.isProcessing = false
            strongSelf.recordingViewModel.isRecording = false
        }
        
        // 关闭 panel 和状态转换
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            strongSelf.recordingPanel?.orderOut(nil)
            strongSelf.recordingPanel = nil
            strongSelf.stateManager.transition(to: .postProcessing)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                strongSelf.stateManager.transition(to: .idle)
            }
        }
    }
}
```

## 实施步骤

1. 增强 MiniMaxService 错误诊断日志
2. 修复 TextInjectionEngine 成功判断逻辑
3. 简化 AppDelegate 注入流程，移除复杂重试逻辑
4. 编译验证
5. 提交代码
6. 封装 DMG
