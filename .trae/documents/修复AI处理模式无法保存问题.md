# 修复 AI 处理模式无法保存到 UserDefaults 的问题

## 问题分析

日志始终显示：`AI mode from UserDefaults: none -> 直接注入`

**根本原因：SettingsView 中的 `.onChange` API 使用了 macOS 14 已废弃的单参数版本，导致回调可能未正确触发。**

## 关键代码位置

`/Users/vincent/Projects/spoken/Spoken/Views/SettingsView.swift:106-109`

当前代码：
```swift
.onChange(of: selectedMode) { newMode in
    UserDefaults.standard.set(newMode.rawValue, forKey: "aiProcessingMode")
    print("Spoken: [DEBUG] SettingsView: AI mode saved: \(newMode.rawValue)")
}
```

这是 macOS 12/13 的旧 API，在 macOS 14+ 中行为不一致，可能不会被触发。

## 修复方案

### 第一步：更新 SettingsView 的 onChange API

1. 将 `AIProcessingMode` 设为 `Equatable`（支持 onChange 比较）
2. 改用 macOS 14+ 双参数 `.onChange` API
3. 添加 `UserDefaults.standard.synchronize()` 确保立即写入
4. 增强日志输出以便调试

修改 `SettingsView.swift`：
- 给 Picker 添加 `.onChange(of: selectedMode) { oldValue, newValue in ... }`
- 添加 debug print 确认回调被触发

### 第二步：更新其他 onChange 调用

同时修复其他 deprecated API 警告：
- `SettingsView.swift` 的语言选择 onChange
- `AppDelegate.swift` 的 WaveBar 和 WaveformView 的 onChange

### 第三步：验证修复

编译运行后，在日志中应能看到：
- `SettingsView: AI mode saved: polish` (或其他模式)
- 然后记录时看到 `AI mode from UserDefaults: polish -> 润色`

## 实施步骤

1. 修改 `AIProcessingMode` 枚举添加 `Equatable` 协议
2. 更新 `SettingsView.swift` 的 AI 模式 onChange 为双参数版本
3. 更新 `SettingsView.swift` 的语言选择 onChange 为双参数版本
4. 更新 `AppDelegate.swift` 的 WaveBar onChange 已经是双参数版本（OK）
5. 更新 `AppDelegate.swift` 的 WaveformView onChange 已经是双参数版本（OK）
6. 编译测试
