import os
p = os.path.expandvars(r'%APPDATA%\Spoken\config.toml')
with open(p, 'r', encoding='utf-8') as f:
    s = f.read()

if 'realtime_provider' not in s:
    s = s.replace('[asr]\nmode = "realtime"', '[asr]\nmode = "realtime"\nrealtime_provider = "windows"')

if '/v1/openai/native' not in s:
    s = s.replace('base_url = "https://aigc.sankuai.com/v1/openai"', 'base_url = "https://aigc.sankuai.com/v1/openai/native"')

with open(p, 'w', encoding='utf-8') as f:
    f.write(s)
print('fixed')
