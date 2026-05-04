# Bug 修复：AI 处理永久卡死

## 根因定位

`callWithTimeout` 方法的流程存在根本性缺陷。

### 问题流程分析

```swift
func process(text: String, mode: SpokenMode, ..., completion: @escaping ...) {
    callWithTimeout(timeout: aiTimeout, originalText: text) { cb in
        self.polish(text: text, completion: cb)   // ← cb 被传入 polish → chat → executeChat
    }
}
```

在 `callWithTimeout` 内部：

```swift
private func callWithTimeout(timeout: TimeInterval, originalText: String,
    call: @escaping (@escaping (Result<String, Error>) -> Void) -> Void
) {
    var completed = false
    let timer = Timer... { [weak self] _ in
        strongSelf.completionHandler?(.success(originalText))  // ← A
    }

    call { [weak self] result in
        strongSelf.completionHandler?(result)  // ← B: 这里引用的是 completionHandler
    }
}
```

**致命问题**：
- `call` 闭包中的 `{ [weak self] result in ... strongSelf.completionHandler?(result) }` 被当作参数 `cb` 传给了 `polish` → `chat` → `executeChat` → URLSession 的 completion handler
- 当 URLSession 请求完成时，调用 `cb(result)`
- `cb` 内部引用的是 `completionHandler` 属性
- 但 `completionHandler` 属性**从未被赋值**！它是 `nil`
- 所以 `completionHandler?(result)` **什么都不做**，`process()` 的 `completion` 永远不会被调用

### 正常响应为什么偶尔能工作
正常响应走的是 `cb` → `completionHandler`，而 `completionHandler` 一直是 `nil`，所以正常响应也会失败。之前修复前用户说"有时能工作"是因为旧版本中 `completionHandler` 在 `cancelCurrentTask` 被调用的时机偶然不为 `nil`。

### 为什么 Timer 超时也不会工作
Timer 回调走 `completionHandler?(.success(originalText))`，同样是 `nil`。

### 总结
**所有路径都调用了 `completionHandler` 属性，但该属性从未被赋值，始终是 `nil`。**

## 修复方案

### 方案：去掉 `completionHandler` 属性，直接传递回调

将 `callWithTimeout` 改造为直接捕获 `completion` 回调，不再依赖多余的 `completionHandler` 属性。

```swift
private func callWithTimeout(
    timeout: TimeInterval,
    originalText: String,
    completion: @escaping (Result<String, Error>) -> Void,  // 直接接收 completion
    call: @escaping (@escaping (Result<String, Error>) -> Void) -> Void
) {
    var completed = false

    let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
        guard !completed else { return }
        completed = true
        self?.currentTask?.cancel()
        self?.currentTask = nil
        print("Spoken: [WARN] AI timeout (\(timeout)s), falling back to original text")
        completion(.success(originalText))
    }

    call { [weak self] result in
        guard let strongSelf = self else { return }
        guard !completed else { return }
        timer.invalidate()
        completed = true
        completion(result)  // 直接调用 completion，不再通过 completionHandler 属性
    }
}
```

同时在 `process()` 中将 `completion` 传入 `callWithTimeout`。

### 同时删除不再需要的 `completionHandler` 属性

## 实施步骤

1. 修改 `callWithTimeout` 方法签名，直接接收 `completion` 参数
2. 修改 `process()` 调用 `callWithTimeout` 时传入 `completion`
3. 删除 `completionHandler` 属性
4. 更新 `cancelCurrentTask()` 中 `completionHandler` 的引用（改为直接取消任务，不触发回调）
5. 编译验证
6. 提交代码
7. 重新封装 DMG
