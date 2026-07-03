# Requirements Document

## Introduction

Spoken V3 是 Spoken 应用的重大版本迭代，旨在解决 V2 版本中存在的稳定性问题、性能瓶颈，并增加新的功能特性。V3 的核心目标包括：增强架构稳定性（特别是浮窗展示）、提升整体链路效率、优化应用模式、支持长语音识别以及集成美团内部 ASR 服务。

## Glossary

- **Overlay**: 浮窗组件，用于实时展示语音识别状态和 AI 处理进度
- **ASR Engine**: 自动语音识别引擎，负责将音频转换为文本
- **Pipeline**: 处理流水线，包含 ASR → AI → 注入的完整流程
- **Injection**: 文本注入，将处理结果输入到当前活动窗口
- **Meeting Minutes Mode**: 会议纪要模式，专门用于会议内容的记录和整理
- **Content Structuring Mode**: 内容结构化整理模式，用于将杂乱内容整理成结构化形式
- **Long Audio**: 长语音，指时长超过 60 秒的语音输入

## Requirements

### Requirement 1: 架构稳定性增强

**User Story:** 作为用户，我希望应用能够稳定运行而不出现浮窗闪烁、裁切异常或意外崩溃，以便我能够专注于语音输入工作。

#### Acceptance Criteria

1. THE Overlay SHALL 初始化时隐藏窗口直到 WebView2 内容完全加载
2. WHEN 浮窗显示或隐藏时，THE Overlay SHALL 平滑过渡而不出现闪烁
3. WHEN 浮窗内容更新时，THE Overlay SHALL 正确计算并应用裁切区域，确保内容完整显示
4. WHEN 窗口大小改变时，THE Overlay SHALL 重新计算裁切区域并保持稳定性
5. WHEN 应用收到 Windows 电源管理事件时，THE System SHALL 正确处理而不崩溃
6. WHEN 多线程操作发生竞态条件时，THE System SHALL 使用适当的同步机制避免死锁或崩溃
7. THE Overlay SHALL 在多显示器环境下正确显示在活动窗口附近

### Requirement 2: 整体链路性能优化

**User Story:** 作为用户，我希望语音识别到文本注入的整个过程尽可能快速，以便获得流畅的输入体验。

#### Acceptance Criteria

1. WHEN 用户停止语音输入时，THE Pipeline SHALL 在最短时间内开始 AI 处理
2. WHEN ASR 引擎处理音频时，THE System SHALL 使用高效的音频缓冲策略减少延迟
3. WHEN AI 处理结果返回时，THE System SHALL 立即将文本注入到目标窗口
4. WHEN 多个处理任务排队时，THE Pipeline SHALL 优化任务调度以减少等待时间
5. THE System SHALL 移除不必要的等待和延迟

### Requirement 3: 模式优化拆分

**User Story:** 作为用户，我希望会议纪要和内容结构化是两个独立的模式，以便我能够根据不同场景选择合适的功能。

#### Acceptance Criteria

1. WHEN 用户选择会议纪要模式时，THE System SHALL 提供专门针对会议场景的 AI 提示词和处理流程
2. WHEN 用户选择内容结构化模式时，THE System SHALL 提供通用内容整理的 AI 提示词和处理流程
3. THE System SHALL 在配置文件中支持两种模式的独立配置
4. WHEN 切换模式时，THE UI SHALL 清晰显示当前选中的模式
5. THE System SHALL 为每种模式维护独立的最近使用历史

### Requirement 4: 长语音识别支持

**User Story:** 作为用户，我希望能够进行超过 60 秒的长语音输入，以便在会议或长时间表达时不需要频繁停顿。

#### Acceptance Criteria

1. WHEN 用户持续说话超过 60 秒时，THE ASR Engine SHALL 继续识别而不中断
2. WHEN 识别长语音时，THE System SHALL 提供实时进度反馈
3. WHEN 长语音处理过程中出现网络波动时，THE System SHALL 尝试重连并保留已识别内容
4. WHEN 长语音处理完成时，THE System SHALL 正确处理和注入完整结果
5. THE System SHALL 显示当前录制的时长信息

### Requirement 5: 美团内部 ASR 服务集成

**User Story:** 作为美团内部用户，我希望使用美团内部的语音识别服务，以便获得更好的服务稳定性和数据安全性。

#### Acceptance Criteria

1. WHEN 配置使用美团 ASR 服务时，THE System SHALL 正确初始化美团 ASR 引擎
2. WHEN 美团 ASR 服务不可用时，THE System SHALL 自动回退到其他可用引擎
3. THE System SHALL 支持美团 ASR 服务的身份认证机制
4. THE System SHALL 保护美团 ASR 服务的 API 凭证不被泄露
5. WHEN 美团 ASR 服务返回结果时，THE System SHALL 正确解析并传递给处理流水线

### Requirement 6: 兼容性和平滑升级

**User Story:** 作为现有用户，我希望从 V2 升级到 V3 时能够保留原有配置和数据，以便无缝过渡。

#### Acceptance Criteria

1. WHEN 用户从 V2 升级到 V3 时，THE System SHALL 自动迁移现有配置
2. WHEN 配置迁移过程中遇到不兼容项时，THE System SHALL 提示用户并使用默认值
3. THE System SHALL 保持与 V2 相同的热键绑定方式
4. THE System SHALL 保持与 V2 相同的基本使用流程
