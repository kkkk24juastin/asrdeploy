#!/usr/bin/env bash
# service.sh — 启动 / 停止 / 状态 / 日志（试运行用；生产环境请用 systemd/）
#
# 用法:
#   ./scripts/service.sh start     # 启动 llama-server + 代理
#   ./scripts/service.sh stop      # 停止
#   ./scripts/service.sh restart
#   ./scripts/service.sh status    # 健康状态
#   ./scripts/service.sh logs      # 跟踪日志
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/logs" "$ROOT/run"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-8000}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
LLAMA_THREADS="${LLAMA_THREADS:-16}"
LLAMA_CTX="${LLAMA_CTX:-16384}"
MODEL_FILE="${MODEL_FILE:-models/Qwen3-ASR-1.7B-Q8_0.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-models/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf}"
UPSTREAM_URL="${UPSTREAM_URL:-http://127.0.0.1:$LLAMA_PORT}"

LLAMA_BIN="$ROOT/bin/llama/llama-server"
PID_DIR="$ROOT/run"

is_running() {
  [[ -f "$PID_DIR/$1.pid" ]] && kill -0 "$(cat "$PID_DIR/$1.pid")" 2>/dev/null
}

start() {
  [[ -x "$LLAMA_BIN" ]] || { echo "缺少 $LLAMA_BIN，请先运行: ./scripts/01-install.sh"; exit 1; }
  [[ -f "$ROOT/$MODEL_FILE" ]] || { echo "缺少 $ROOT/$MODEL_FILE，请先运行: ./scripts/02-download-models.sh"; exit 1; }
  [[ -f "$ROOT/$MMPROJ_FILE" ]] || { echo "缺少 $ROOT/$MMPROJ_FILE，请先运行: ./scripts/02-download-models.sh"; exit 1; }

  if is_running llama; then
    echo "llama-server 已在运行 (pid $(cat "$PID_DIR/llama.pid"))"
  else
    echo "启动 llama-server (threads=$LLAMA_THREADS, ctx=$LLAMA_CTX) ..."
    export LD_LIBRARY_PATH="$ROOT/bin/llama/lib:$ROOT/bin/llama:${LD_LIBRARY_PATH:-}"
    nohup "$LLAMA_BIN" \
      -m "$ROOT/$MODEL_FILE" \
      --mmproj "$ROOT/$MMPROJ_FILE" \
      --host 127.0.0.1 --port "$LLAMA_PORT" \
      -t "$LLAMA_THREADS" -c "$LLAMA_CTX" \
      > "$ROOT/logs/llama-server.log" 2>&1 &
    echo $! > "$PID_DIR/llama.pid"
    echo -n "等待模型加载"
    ready=0
    for _ in $(seq 1 180); do
      if curl -fsS "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1; then ready=1; break; fi
      echo -n "."
      sleep 1
    done
    echo
    if [[ $ready -ne 1 ]]; then
      echo "加载超时，请查看 logs/llama-server.log" >&2
      exit 1
    fi
    echo "llama-server 就绪"
  fi

  if is_running proxy; then
    echo "代理已在运行 (pid $(cat "$PID_DIR/proxy.pid"))"
  else
    echo "启动代理 ..."
    UPSTREAM_URL="$UPSTREAM_URL" ASR_API_KEY="${ASR_API_KEY:-}" \
      nohup "$ROOT/venv/bin/uvicorn" asr_proxy:app \
        --app-dir "$ROOT/proxy" \
        --host "$PROXY_HOST" --port "$PROXY_PORT" \
        > "$ROOT/logs/proxy.log" 2>&1 &
    echo $! > "$PID_DIR/proxy.pid"
    sleep 1
    if curl -fsS "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
      echo "代理就绪"
    else
      echo "代理未就绪，请查看 logs/proxy.log" >&2
      exit 1
    fi
  fi

  echo
  echo "服务已启动："
  echo "  API:  http://$PROXY_HOST:$PROXY_PORT/v1/audio/transcriptions"
  echo "  健康: curl http://$PROXY_HOST:$PROXY_PORT/health"
}

stop_one() {
  local name="$1" pidfile="$PID_DIR/$1.pid"
  if is_running "$name"; then
    local pid
    pid="$(cat "$pidfile")"
    echo "停止 $name (pid $pid) ..."
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  else
    echo "$name 未在运行"
    rm -f "$pidfile"
  fi
}

status() {
  echo "llama-server:"
  if is_running llama; then
    echo "  进程: 运行中 (pid $(cat "$PID_DIR/llama.pid"))"
    curl -sS "http://127.0.0.1:$LLAMA_PORT/health" || echo "  （health 无响应）"
    echo
  else
    echo "  进程: 未运行"
  fi
  echo "proxy:"
  if is_running proxy; then
    echo "  进程: 运行中 (pid $(cat "$PID_DIR/proxy.pid"))"
    curl -sS "http://127.0.0.1:$PROXY_PORT/health" || echo "  （health 无响应）"
    echo
  else
    echo "  进程: 未运行"
  fi
}

case "${1:-}" in
  start)   start ;;
  stop)    stop_one llama; stop_one proxy ;;
  restart) stop_one llama; stop_one proxy; start ;;
  status)  status ;;
  logs)    tail -n 50 -f "$ROOT/logs/llama-server.log" "$ROOT/logs/proxy.log" ;;
  *)
    echo "用法: $0 {start|stop|restart|status|logs}" >&2
    exit 1
    ;;
esac
