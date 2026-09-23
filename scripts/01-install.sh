#!/usr/bin/env bash
# 01-install.sh — 安装系统依赖 + 下载 llama.cpp 预编译包 + 创建 Python 虚拟环境
#
# 需要 sudo 的操作（会先打印命令）：
#   apt-get install curl ffmpeg python3-venv
#
# 用法: ./scripts/01-install.sh [--skip-apt]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/bin" "$ROOT/models" "$ROOT/logs" "$ROOT/run"

SKIP_APT=0
if [[ "${1:-}" == "--skip-apt" ]]; then
  SKIP_APT=1
fi

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    echo "需要 root 或 sudo 才能安装系统包，或使用 --skip-apt 跳过。" >&2
    exit 1
  fi
fi

# ---------- 1. 系统依赖 ----------
if [[ $SKIP_APT -eq 0 ]]; then
  echo "==> [1/3] 安装系统依赖: curl ffmpeg python3-venv"
  $SUDO apt-get update -y
  $SUDO apt-get install -y curl ffmpeg python3-venv
else
  echo "==> [1/3] 跳过 apt（--skip-apt）"
fi

# ---------- 2. llama.cpp 预编译包 ----------
if [[ -x "$ROOT/bin/llama/llama-server" ]]; then
  echo "==> [2/3] 已存在 bin/llama/llama-server，跳过下载"
else
  echo "==> [2/3] 查找 llama.cpp 最新 Ubuntu x64 预编译包 ..."
  api_url="https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20"
  asset_url="$(curl -fsSL "$api_url" | python3 -c '
import json, sys
for rel in json.load(sys.stdin):
    for a in rel.get("assets", []):
        n = a["name"]
        if n.startswith("llama-") and n.endswith("bin-ubuntu-x64.tar.gz"):
            print(a["browser_download_url"]); sys.exit(0)
sys.exit("未找到 Ubuntu x64 构建资产")
')"
  echo "    下载: $asset_url"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  curl -fL --retry 3 --progress-bar -o "$tmpdir/llama.tar.gz" "$asset_url"
  tar -xzf "$tmpdir/llama.tar.gz" -C "$tmpdir"
  server_bin="$(find "$tmpdir" -name llama-server -type f | head -n1)"
  if [[ -z "$server_bin" ]]; then
    echo "解压包中未找到 llama-server" >&2
    exit 1
  fi
  src_dir="$(dirname "$server_bin")"
  rm -rf "$ROOT/bin/llama"
  mkdir -p "$ROOT/bin/llama"
  cp -a "$src_dir/." "$ROOT/bin/llama/"
  echo "    llama-server 位置: $ROOT/bin/llama/llama-server"
fi
"$ROOT/bin/llama/llama-server" --version | head -n2 || true

# ---------- 3. Python 虚拟环境 ----------
echo "==> [3/3] 创建 venv 并安装代理依赖"
if [[ ! -d "$ROOT/venv" ]]; then
  python3 -m venv "$ROOT/venv"
fi
"$ROOT/venv/bin/pip" install --quiet --upgrade pip
# 国内网络可加: -i https://pypi.tuna.tsinghua.edu.cn/simple
"$ROOT/venv/bin/pip" install --quiet -r "$ROOT/proxy/requirements.txt"

# ---------- 完成 ----------
if [[ ! -f "$ROOT/.env" ]]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  echo "已生成 $ROOT/.env（按需修改）"
fi

echo
echo "安装完成。下一步："
echo "  ./scripts/02-download-models.sh"
