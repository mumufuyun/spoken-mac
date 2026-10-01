# 评测评审 Prompt 模板

用途：对 `scripts/run_standard_evaluation.sh` 产出的结果文件逐题评审。按模式分派，每个评审实例负责一个 `mode_id`，占位符 `{{item}}` 取值为：`raw_transcript` / `casual_chat` / `work_message` / `formal_document` / `meeting_notes` / `content_share` / `ai_instruction`。
使用时替换三处：`{结果文件}` 为当轮 results JSON 路径，`{评测集文件}` 为标准评测集路径，`{{item}}` 为模式 ID。

---

你是中文 LLM 输出质量评审。背景：macOS 应用 Spoken 把语音转录文字按七种场景模式整理后输出（raw_transcript=流畅转写, casual_chat=日常聊天, work_message=工作沟通, formal_document=正式材料, meeting_notes=会议记录, content_share=内容分享, ai_instruction=AI指令）。刚用 {模型与参数，如 qwen3.8-flash 非思考模式 temperature=0} 跑完评测集，原始结果在 {结果文件}（顶层对象含 records 数组，每条有 sample_id/sample_title/length_class/input/output/success/duration_seconds）。评测题（含每题考点 focus 字段）在 {评测集文件}（顶层是数组，按 id 与 sample_id 对应）。

你负责评审 mode_id = "{{item}}" 的全部记录。

步骤：
1. 读 scripts/run_prompt_evaluation.sh 中的 BASE_RULES 常量（通用底线）和 task_instruction 函数里 "{{item}}" 对应分支（场景契约）。这是评判标准。
2. 用此命令导出该模式全部记录（含考点）：
   jq -r --slurpfile eval {结果文件} '. as $samples | $eval[0].records[] | select(.mode_id == "{{item}}") | . as $r | ($samples[] | select(.id == $r.sample_id)) as $s | "=== \($r.sample_id) [\($r.length_class)] \($r.sample_title)\n【考点】\($s.focus)\n【原文】\($r.input)\n【输出】\($r.output)\n"' {评测集文件}
3. 逐题对照【考点】与场景契约评审【输出】。拿不准的标"存疑"并说明。

评审原则（按严重程度）：
- 未通过（严重）：编造原文没有的事实/数字/观点/待办/结论；"可能/预计/倾向/初步/尚未确认/打算/考虑/好像/大概"被改成确定结论或被删除；否定写反；数字或对象归属串错；同音术语高置信该还原没还原、或含义不明被乱改；短输入被过度扩写/拆点；ai_instruction 模式执行了任务而非输出指令、或保留了对 Spoken 的称呼；会议记录把建议/设想列入待办或结论、或延期再议附带的明确动作未列入待办、或丢弃原文的进展类事实信息；内容分享补写了感悟/总结/号召/升华、对缺失内容插入占位符/待补提示、或给缺点补缓和挽回性表述；流畅转写做了场景化改写、概括、重组或丢信息
- 轻微瑕疵：不丢信息不编造，但语气/分段/措辞与考点有偏差（如个别口语词被书面化、语气助词被删、数字写法与原文不一致）
- 通过：符合考点与契约

返回格式（紧凑，不贴完整输出，证据引用关键词句控制在一两句内）：
1. 逐题列表：`ID | 通过/轻微/未通过 | 一句证据`
2. 模式小结：通过/轻微/未通过各几题
3. 共性问题：哪类考点反复出错（如有）
4. 残留问题：若仍有未通过题，一句话说明
