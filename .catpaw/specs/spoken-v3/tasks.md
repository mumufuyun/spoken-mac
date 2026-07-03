# Implementation Plan: Spoken V3

## Overview

Spoken V3 的实现计划分为以下几个主要阶段：基础设施和稳定性修复、ASR 层升级、模式扩展、性能优化、配置迁移。每个阶段包含具体的编码任务和测试任务。

## Tasks

- [ ] 1. 浮窗裁切稳定性修复
- [ ] 1.1 实现裁切区域缓存机制
  - 在 `OverlayWindow` 类中添加 `_cached_region`、`_region_width`、`_region_height` 属性
  - 实现 `_should_update_region()` 方法，判断是否需要更新裁切区域
  - 修改 `_apply_rounded_region()` 方法，在应用前检查缓存
  - _Requirements: 1.3, 1.4_

- [ ] 1.2 实现裁切区域验证和重试机制
  - 实现 `_verify_region_applied()` 方法，验证裁切区域是否正确应用
  - 实现 `_retry_apply_region()` 方法，失败时自动重试
  - 在 `_apply_rounded_region()` 中添加验证步骤
  - _Requirements: 1.3, 1.4_

- [ ] 1.3 编写浮窗裁切属性测试
  - **Property 1: Overlay cropping region consistency**
  - 使用 hypothesis 测试各种窗口尺寸下裁切区域正确性
  - **Validates: Requirements 1.3, 1.4**

- [ ] 2. ASR Manager 实现
- [ ] 2.1 创建 ASR Manager 核心类
  - 创建 `asr/manager.py` 文件
  - 实现 `ASRManager` 类的基本结构
  - 实现 `register()`、`start()`、`stop()` 方法
  - 实现引擎优先级管理
  - _Requirements: 5.2_

- [ ] 2.2 实现引擎降级和故障转移
  - 实现 `fallback()` 方法
  - 在 `start()` 和 `stop()` 中捕获异常并触发降级
  - 添加降级日志和状态通知
  - _Requirements: 5.2_

- [ ] 2.3 实现长语音支持逻辑
  - 添加 `_long_audio_threshold` 配置
  - 实现 `get_engine_for_duration()` 方法
  - 在 `start()` 中根据预估时长选择合适引擎
  - _Requirements: 4.1, 4.4_

- [ ]* 2.4 编写 ASR Manager 属性测试
  - **Property 7: ASR engine fallback**
  - 测试引擎故障时自动降级逻辑
  - **Validates: Requirements 5.2**

- [ ] 3. 美团 ASR Engine 实现
- [ ] 3.1 创建美团 ASR 适配器基础结构
  - 创建 `asr/meituan_asr.py` 文件
  - 实现 `MeituanASREngine` 类，继承 `ASREngine` 接口
  - 定义配置项（endpoint, app_key, app_secret）
  - _Requirements: 5.1, 5.3_

- [ ] 3.2 实现认证机制
  - 实现 `_authenticate()` 方法
  - 实现 token 缓存和刷新逻辑
  - 处理认证失败场景
  - _Requirements: 5.3_

- [ ] 3.3 实现实时识别 WebSocket 连接
  - 实现 `start()` 方法，建立 WebSocket 连接
  - 实现音频流发送逻辑
  - 实现结果接收和解析
  - 实现 `stop()` 方法，关闭连接并返回结果
  - _Requirements: 5.5_

- [ ] 3.4 实现断线重连和长语音支持
  - 实现 `_reconnect()` 方法
  - 添加已识别内容缓存
  - 处理网络波动场景
  - _Requirements: 4.3_

- [ ]* 3.5 编写美团 ASR 适配器测试
  - **Property 8: API credential protection**
  - 测试日志输出不含敏感信息
  - **Property 9: API response parsing**
  - 测试各种 API 响应格式解析
  - **Validates: Requirements 5.4, 5.5**

- [ ] 4. 检查点 - ASR 层基础完成
- 确保 ASR Manager 和美团 ASR 引擎测试通过
- 验证引擎降级和故障转移工作正常
- 如有疑问询问用户

- [ ] 5. 模式策略扩展
- [ ] 5.1 创建会议纪要策略
  - 在 `ai/strategies.py` 中添加 `MeetingMinutesStrategy` 类
  - 定义会议纪要专用系统提示词
  - 配置模式 E 使用此策略
  - _Requirements: 3.1_

- [ ] 5.2 创建内容结构化策略
  - 在 `ai/strategies.py` 中添加 `ContentStructuringStrategy` 类
  - 定义内容结构化专用系统提示词
  - 配置模式 F 使用此策略
  - _Requirements: 3.2_

- [ ] 5.3 更新 AIProcessor 注册新策略
  - 在 `AIProcessor._register_default_strategies()` 中注册模式 E 和 F
  - 更新配置文件支持模式 E/F 的自定义提示词
  - _Requirements: 3.3_

- [ ] 5.4 更新 StateController 支持新模式
  - 扩展 `WorkMode` 枚举包含 E 和 F
  - 更新 `_MODE_CYCLE` 循环顺序
  - 更新 `MODE_NAMES` 映射
  - _Requirements: 3.4_

- [ ] 5.5 编写模式策略测试
  - **Property 4: Mode configuration independence**
  - 测试模式配置相互独立
  - **Property 5: Mode prompt correctness**
  - 测试各模式提示词包含正确关键词
  - **Validates: Requirements 3.1, 3.2, 3.3, 3.5**

- [ ] 6. 浮窗长语音进度反馈
- [ ] 6.1 添加录音时长显示
  - 在 `OverlayWindow` HTML 中添加时长显示元素
  - 实现 `_update_duration()` 方法
  - 在录音过程中定期更新时长
  - _Requirements: 4.2, 4.5_

- [ ] 6.2 添加长语音状态反馈
  - 在浮窗中显示"长语音录制中"提示
  - 添加进度指示器
  - _Requirements: 4.2_

- [ ] 7. Pipeline 性能优化
- [ ] 7.1 审查并移除固定延迟
  - 扫描 `pipeline.py` 中所有 `time.sleep()` 调用
  - 评估每个延迟的必要性
  - 移除或替换为事件驱动机制
  - _Requirements: 2.1, 2.5_

- [ ] 7.2 优化 ASR 停止后的处理
  - 审查 `run_realtime()` 方法
  - 确保识别结果返回后立即进入下一步
  - _Requirements: 2.3_

- [ ] 7.3 集成 ASR Manager 到 Pipeline
  - 修改 `Pipeline` 使用 `ASRManager` 替代直接使用引擎
  - 更新 `__main__.py` 中的初始化逻辑
  - _Requirements: 5.1, 5.2_

- [ ]* 7.4 编写流水线性能测试
  - 编写基准测试测量各阶段延迟
  - 对比优化前后的性能数据
  - _Requirements: 2.1, 2.3_

- [ ] 8. 检查点 - 核心功能完成
- 确保所有新模式测试通过
- 验证长语音识别功能正常
- 验证性能优化效果
- 如有疑问询问用户

- [ ] 9. 配置迁移和兼容性
- [ ] 9.1 实现配置迁移逻辑
  - 创建 `config/migration.py` 文件
  - 实现 V2 到 V3 的配置转换
  - 处理不兼容项，使用默认值并提示用户
  - _Requirements: 6.1, 6.2_

- [ ] 9.2 编写配置迁移属性测试
  - **Property 10: Configuration migration**
  - 测试各种 V2 配置格式迁移正确性
  - **Validates: Requirements 6.1**

- [ ] 9.3 更新默认配置文件
  - 更新 `config/defaults.toml` 添加新模式配置
  - 添加美团 ASR 配置项
  - 保持热键配置与 V2 兼容
  - _Requirements: 6.3_

- [ ] 10. 托盘图标更新
- [ ] 10.1 更新模式角标
  - 为模式 E 和 F 设计新的角标图标
  - 更新托盘图标渲染逻辑
  - _Requirements: 3.4_

- [ ] 11. 最终检查点
- 确保所有测试通过
- 进行完整的端到端测试
- 更新 README 和用户文档
- 如有疑问询问用户

## Notes

- 每个任务引用具体的需求编号以保持可追溯性
- 检查点确保增量验证，及时发现和修复问题
- 性能优化任务需要基准测试对比，确保优化有效
- 美团 ASR 集成需要等待 API 文档确认具体细节
