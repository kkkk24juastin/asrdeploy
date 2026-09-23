#!/usr/bin/env bash
# 02-download-models.sh — 下载 Qwen3-ASR-1.7B GGUF 模型（支持 HF 镜像 + 断点续传）
#
# 默认从 hf-mirror.com 下载（国内推荐）。
# 海外/可直连 HuggingFace 时: HF_ENDPOINT=https://huggingface.co ./scripts/02-download-models.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/models"

HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
REPO="ggml-org/Qwen3-ASR-1.7B-GGUF"
FILES=(
  "Qwen3-ASR-1.7B-Q8_0.gguf"
  "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"
)

echo "下载源: $HF_ENDPOINT/$REPO"
echo

for f in "${FILES[@]}"; do
  dest="$ROOT/models/$f"
  echo "==> $f"
  curl -fL --retry 3 --retry-delay 2 -C - --progress-bar \
    -o "$dest" \
    "$HF_ENDPOINT/$REPO/resolve/main/$f"
  ls -lh "$dest"
  echo
done

echo "模型下载完成："
ls -lh "$ROOT/models"
echo
echo "下一步："
echo "  ./scripts/service.sh start"
