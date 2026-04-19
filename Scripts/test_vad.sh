#!/bin/bash
# 测试 VADWhisperService 的 Python backend 是否正常
# 用法: bash test_vad.sh

curl -s http://localhost:8765/health && echo "" || echo "Python backend 未启动（正常，还没集成）"
