#!/usr/bin/env bash
# smoke.sh — 冒烟测试：上传一段音频，打印转写结果与耗时
#
# 用法: ./tests/smoke.sh 音频文件 [服务地址]
# 例:   ./tests/smoke.sh ~/test.wav
#       ./tests/smoke.sh ~/test.mp3 http://127.0.0.1:8000
set -euo pipefail

AUDIO="${1:?用法: ./tests/smoke.sh 音频文件 [服务地址]}"
BASE="${2:-http://127.0.0.1:8000}"

[[ -f "$AUDIO" ]] || { echo "文件不存在: $AUDIO" >&2; exit 1; }

echo "==> POST $BASE/v1/audio/transcriptions"
echo "    文件: $AUDIO"
echo

time curl -sS -X POST "$BASE/v1/audio/transcriptions" \
  -F "file=@$AUDIO" \
  -F "model=qwen3-asr" \
  -F "response_format=json"
echo
