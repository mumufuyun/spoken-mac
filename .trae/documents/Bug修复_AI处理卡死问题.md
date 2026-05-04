# Bug 修复计划：AI 处理卡死问题

## 问题分析

### 根因
`MiniMaxService.swift` 的 `callWithTimeout` 方法中，`cancelCurrentTask()` 的实现有致命缺陷：

```swift
func cancelCurrentTask() {
    currentTask?.cancel()
    currentTask = nil
    completionHandler?(.failure(MiniMaxError.cancelled))
    completionHandler = nil  // ← 问题：同步清除了 handler
}
```

而在 `callWithTimeout` 的 timer 回调中：

```swift
let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
    guard !completed else { return }
    completed = true
    self.cancelCurrentTask()  // ← 调用上面的方法
    print("Spoken: [WARN] AI timeout, falling back to original text")
    DispatchQueue.main.async {
        self.completionHandler?(.success(originalText))  // ← 此时 completionHandler 已经是 nil！
    }
}
```

### 执行流程
1. Timer 触发 → `cancelCurrentTask()` 被调用
2. `cancelCurrentTask()` 中 `completionHandler?(.failure(.cancelled))` 在主线程执行
3. 紧接着 `completionHandler = nil` 同步执行
4. Timer 后续代码 `DispatchQueue.main.async { completionHandler?(...) }` 排队等待
5. 队列执行到这一步时，`completionHandler` 已经是 `nil`，什么都不发生
6. **`processAndInput` 中的 completion 永远不会被调用**
7. UI 卡在 `isProcessing = true`，永远不会回到 idle 状态

### 为什么用户能触发
- API 网络请求慢、MiniMax 服务无响应时触发 15 秒超时
- 或者用户手动点击"取消"按钮时触发

## 修复方案

### 1. 修复 `cancelCurrentTask` 中 `completionHandler` 被过早清除的问题
- 移除 `cancelCurrentTask` 中的 `completionHandler = nil`
- `completed` 标志位已经保证不会重复调用，不需要清除 handler

### 2. 移除 timer 回调中多余的 `DispatchQueue.main.async`
- `cancelCurrentTask()` 已经在主线程执行了 `completionHandler?(.failure(.cancelled))`
- 不需要再异步调用一次

### 3. 简化 timeout 逻辑
- 将 timer 回调简化为直接调用 `cancelCurrentTask()`，然后 `completionHandler?(.success(originalText))` 作为超时降级
- 确保正常响应和超时两种路径都能正确触发 `processAndInput` 的 completion

## 实施步骤

1. 修改 `MiniMaxService.swift` 中的 `cancelCurrentTask` 方法
2. 修改 `callWithTimeout` 方法中的 timer 回调逻辑
3. 编译验证
4. 提交代码
5. 重新封装 DMG
