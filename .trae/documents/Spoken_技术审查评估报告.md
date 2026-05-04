# Spoken 技术架构审查评估报告

> 基于 kimi agent 输出的 `SPOKEN_TECH_REVIEW.md` 进行逐项核实

---

## 一、问题逐一核实

### 🔴 P0 问题

#### 1. API Key 硬编码 — ✅ 属实
- **位置**: `MiniMaxService.swift:7`
- **核实**: 已确认，完整的 API Key 明文写在代码中
- **风险**: 反编译即可获取，任何人拿到 DMG 就能提取 Key 盗用
- **结论**: **必须立即处理**。建议在 MiniMax 控制台重置 Key，改用 Keychain 存储。

#### 2. StateManager 重复定义 —  不属实（已不存在）
- **核实**: 已检查 `AppDelegate.swift` 和 `StateManager.swift`，当前只有 `Services/StateManager.swift` 一个定义，AppDelegate 中已无重复。
- **结论**: 此问题不存在，审查报告基于旧版本代码。

#### 3. 语音识别实为云端，宣传为离线 — ️ 部分属实
- **核实**: `SpeechService.swift:117` 确实设置 `requiresOnDeviceRecognition = false`
- **实际情况**: README.md 中写的是 "macOS 原生听写"，并未宣传"离线识别"
- **结论**: 代码确实是云端识别，但 README 描述没有夸大，问题不严重。可在下期考虑添加真正的离线模式。

#### 4. HotKey 内存不安全 — ✅ 属实
- **核实**: `HotKeyService.swift:37-52` 使用 `Unmanaged.passUnretained` 传递 `self` 到 C 回调
- **风险**: 如果 `HotKeyService` 被释放而回调仍被触发，会产生野指针崩溃
- **结论**: 应修复，但当前 `HotKeyService` 是全局单例且生命周期与 App 相同，实际风险较低。

#### 5. AppDelegate 臃肿（723行，7个类型） — ⚠️ 部分属实
- **核实**: 当前 AppDelegate.swift 约 600+ 行，包含多个类型（AppDelegate、RecordingPanelView、WaveBar、WaveformView、VisualEffectView 等）
- **实际情况**: 录音面板相关类型放在 AppDelegate.swift 中确实不够理想
- **结论**: 属于代码组织问题，不影响功能。建议下期拆分。

---

### 🟠 P1 问题

#### 6. 剪贴板恢复 race condition — ⚠️ 影响有限
- **核实**: `TextInjectionEngine` 在注入后 2 秒恢复剪贴板
- **实际情况**: 当前用户流程是"录音→AI处理→注入"，注入完成后 2 秒用户通常不需要再复制，实际风险较低
- **结论**: 可优化，但不是高优问题。

#### 7. NotificationService 注册但从未使用 — ✅ 属实
- **核实**: 文件中定义了 `NotificationService`，但搜索全项目未找到任何调用
- **结论**: 死代码。要么删除，要么接入完成/失败通知。

#### 8. AccessibilityService 未接入主流程 — ✅ 属实
- **核实**: 文件存在但未被 import 或调用
- **结论**: 死代码。要么删除，要么接入使用。

#### 9. 缺少超时与降级机制 — ✅ 属实
- **核实**: `MiniMaxService` 和 `SpeechService` 均无超时处理
- **结论**: 网络故障时 UI 会卡住，建议添加超时和降级逻辑。

#### 10. frontmostApp 保存不一致 — ⚠️ 需确认
- **核实**: 需要在 AppDelegate 中检查是否有两处保存 frontmostApp
- **结论**: 待核实。

---

### 🟡 P2 问题

#### 11. Swift 并发模型老旧 — ✅ 属实
- 大量使用 `DispatchQueue.main.asyncAfter` 和 completion handler
- 结论: 不影响功能，但代码可读性和维护性较差。建议下期改造为 async/await。

#### 12. 死代码堆积 — ✅ 完全属实
- `VisualEffectView`（AppDelegate.swift:707）— 定义但从未被实例化
- `WaveBar`（AppDelegate.swift:584）— 定义但从未被引用
- `tryAXSetFocusedTextValue`（TextInjectionEngine.swift:135）— 方法定义但从未被调用（已改为 CGEvent 方式）
- `NotificationService` — 从未被调用
- `AccessibilityService` — 从未被调用
- 结论: 5 处死代码，应清理。

#### 13. UserDefaults Key 硬编码散落 — ✅ 属实
- 结论: 建议统一管理。

#### 14. 快捷键完全硬编码 — ️ 可接受
- 全局快捷键 ⌥+空格 是应用的核心交互方式，硬编码在初期可接受
- 结论: P2 级别，非紧急。

#### 15. 无单元测试 — ✅ 属实
- 结论: 正常，当前项目规模尚小。

#### 16. Entitlements 权限声明不全 — ✅ 属实
- 结论: 应补充。

#### 17. 剪贴板恢复依赖 sleep 时序 — 同上 #6

---

###  P3 问题

#### 18-20 — 均为低优先级优化项，属实但不紧急。

---

## 二、综合评估

### 审查报告的质量

| 维度 | 评分 | 说明 |
|------|------|------|
| **覆盖全面性** | ⭐⭐⭐⭐ | 涵盖了安全、架构、并发、工程化等多个维度 |
| **问题准确性** | ⭐⭐ | 部分问题基于旧版本代码（如 StateManager 重复），需逐项核实 |
| **优先级判断** | ⭐⭐⭐⭐ | P0/P1/P2 分级合理 |
| **解决方案可行性** | ⭐⭐⭐⭐ | 方案务实，分阶段推进 |

### 与项目实际的差距

1. **部分问题已不存在** — StateManager 重复定义、API Key 位置等需以当前代码为准
2. **部分风险被高估** — HotKey 内存安全问题在单例场景下实际风险低
3. **未注意到近期修复** — 如文本注入已从 AX direct 改为 CGEvent 方式

---

## 三、下期迭代建议优先级

### 第一期（建议立即处理）
1. **API Key 外部化** — 安全风险最高，必须处理
2. **清理死代码** — NotificationService、AccessibilityService、VisualEffectView 等

### 第二期（1-2 周内）
3. **超时与降级机制** — 提升稳定性
4. **拆分 AppDelegate** — 改善代码组织
5. **修复 HotKey 内存安全** — 消除隐患

### 第三期（后续迭代）
6. **async/await 并发改造**
7. **Service 协议化 + 依赖注入**
8. **快捷键自定义 + 多模型支持**

---

*注：以上评估基于对当前代码的逐项核实。具体执行需结合用户优先级决定。*
