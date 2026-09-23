#!/usr/bin/env bash
# 容器入口：
#   1. 模型不存在时自动从 HF 镜像下载（挂载 volume 后只需下载一次）
#   2. 后台启动 llama-server 并等待就绪
#   3. 前台运行 OpenAI 兼容代理（uvicorn）
set -euo pipefail

MODEL_DIR="${MODEL_DIR:-/models}"
MODEL_FILE="${MODEL_FILE:-Qwen3-ASR-1.7B-Q8_0.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-mmproj-Qwen3-ASR-1.7B-Q8_0.gguf}"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
HF_REPO="${HF_REPO:-ggml-org/Qwen3-ASR-1.7B-GGUF}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
LLAMA_THREADS="${LLAMA_THREADS:-16}"
LLAMA_CTX="${LLAMA_CTX:-16384}"
LLAMA_EXTRA_ARGS="${LLAMA_EXTRA_ARGS:-}"
PROXY_HOST="${PROXY_HOST:-0.0.0.0}"
PROXY_PORT="${PROXY_PORT:-8000}"

# 代理到 llama-server 的上游地址（随 LLAMA_PORT 自动匹配）
export UPSTREAM_URL="${UPSTREAM_URL:-http://127.0.0.1:$LLAMA_PORT}"

log() { echo "[entrypoint] $*"; }

mkdir -p "$MODEL_DIR"

download_if_missing() {
  local name="$1" dest="$MODEL_DIR/$1"
  if [[ -s "$dest" ]]; then
    log "模型已存在: $name"
    return 0
  fi
  log "下载 $name（源: $HF_ENDPOINT，支持断点续传）..."
  curl -fL --retry 3 --retry-delay 2 -C - \
    -o "$dest" "$HF_ENDPOINT/$HF_REPO/resolve/main/$name"
  log "完成: $name"
}

download_if_missing "$MODEL_FILE"
download_if_missing "$MMPROJ_FILE"

log "启动 llama-server (threads=$LLAMA_THREADS, ctx=$LLAMA_CTX) ..."
log "附加参数: ${LLAMA_EXTRA_ARGS:-（无）}"
# shellcheck disable=SC2086
/opt/llama/llama-server \
  -m "$MODEL_DIR/$MODEL_FILE" \
  --mmproj "$MODEL_DIR/$MMPROJ_FILE" \
  --host 127.0.0.1 --port "$LLAMA_PORT" \
  -t "$LLAMA_THREADS" -c "$LLAMA_CTX" \
  $LLAMA_EXTRA_ARGS &

LLAMA_PID=$!

log "等待 llama-server 就绪（加载模型需要一些时间）..."
ready=0
for _ in $(seq 1 600); do
  if curl -fsS "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
    log "错误：llama-server 意外退出"
    exit 1
  fi
  sleep 1
done
if [[ "$ready" -ne 1 ]]; then
  log "错误：等待 llama-server 超时"
  exit 1
fi
log "llama-server 就绪"

log "启动代理 http://${PROXY_HOST}:${PROXY_PORT} ..."
exec /opt/venv/bin/uvicorn asr_proxy:app \
  --app-dir /opt/proxy \
  --host "$PROXY_HOST" --port "$PROXY_PORT"
