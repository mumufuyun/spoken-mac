# Spoken 文档索引

当前版本：2.4.9 / 249.2。先看[项目说明](../README.md)、[产品需求](../PRD.md)和[阶段进度](../PROGRESS.md)。

## 使用与实现

| 主题 | 文档 |
| --- | --- |
| 首次安装 | [安装指引](安装与首次打开.txt)、[打不开时的设置入口](打不开%20Spoken？点这里.html) |
| 辅助功能 | [授权与更新后恢复](accessibility.md) |
| 快捷键 | [配置、冲突与验证](hotkeys.md) |
| 场景、个人背景和模型 | [自定义配置](customization.md) |
| 语音识别 | [供应商接入](speech-providers.md) |
| AI 整理 | [请求与回退](ai-postprocessing.md)、[正文输出保障](ai-output-safety.md) |
| 找回输入 | [数据、交互与验证](input-recovery.md) |
| 提示词迭代 | [2.4.9 冻结提示词与迁移](prompt-v8-integration.md) |
| 更新与签名 | [客户端更新](updates.md)、[发布签名](release-signing.md) |

## 发布与验证

- 当前发布：[2.4.9 记录](releases/2.4.9.json)、[发布前检查](release-preflight-2.4.9.json)、[更新验证](verification-updates-2.4.9.json)。
- 集成检查：[2.4.9](integration-2.4.9.json)、[语音识别](verification-asr-2026-10-02.md)。
- 提示词与模型资料：[评测目录](../evaluations/README.md)、[长文时延](nonthinking-latency-2.4.7.json)。
- `releases/` 保存各版本发布记录；`verification-*` 和 `integration-*` 按文件日期与版本解释，不代表后续版本的新增验收。

## 方案与历史

- [使用统计改版计划](plans/product-analytics-revision-plan.md)、[技术与指标附录](plans/product-analytics-plan.md)、[事件字典](plans/product-analytics-events.csv)：尚未实现的客户端统计方案。
- [场景化处理与找回原方案](plans/scene-processing-and-recovery-plan.md)：保留最初设计，已实现范围以上方功能文档为准。
- [历史文档目录](archive/README.md)：工程复盘、早期进度和历次评测。

## 本地资料边界

`build/` 保存构建、日志和安装产物；`evaluations/experiments/` 与 `evaluations/prompt-tuning-*/` 保存本地实验原始数据，均不提交。需要共享的合成样本、测试快照和结论单独检查后入库。

`spoken-web-v2/` 是[官网独立仓库](https://github.com/mumufuyun/spoken-web-v2)，分别提交和推送，不作为客户端子模块。Xcode 个人工作区状态、环境变量文件和签名私钥不入库。
