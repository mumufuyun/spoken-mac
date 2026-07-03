import os

p = os.path.expandvars(r'%APPDATA%\Spoken\config.toml')
content = """# Spoken 用户配置文件
# 覆盖 defaults.toml 中的默认值
# 敏感信息（AppId）建议走环境变量：setx SPOKEN_AI_API_KEY \"22046856405852057673\"

[hotkey]
# 录音热键：alt+r
toggle_record = \"alt+r\"
switch_mode = \"alt+m\"
interrupt = \"esc\"

[asr]
# 使用讯飞实时转写引擎
realtime_provider = \"xunfei\"

[asr.xunfei]
app_id = \"9c9ecba8\"
api_key = \"57cccdc5586f75f5974411544bfe44a8\"
api_secret = \"ZjhiN2UxYmVlZDM0ZDlhMDRjNzlmZTM1\"

[ai]
# Friday 大模型平台（OpenAI 兼容接口）
base_url = \"https://aigc.sankuai.com/v1/openai/native\"
# 若不想明文存储 AppId，可删除下一行并通过环境变量设置
api_key = \"22046856405852057673\"
# 推荐模型：gpt-4o-mini（性价比高，润色/翻译/摘要完全够用）
model = \"gpt-4o-mini\"
# 15 秒超时，超时后自动降级直接注入原始文字
timeout_sec = 15
"""

with open(p, 'w', encoding='utf-8') as f:
    f.write(content)

print('config written to', p)
