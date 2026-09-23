# syntax=docker/dockerfile:1

# ============================================================
# 阶段 1：获取 llama.cpp 官方预编译二进制（服务器无需编译）
# 更新方法：在 https://github.com/ggml-org/llama.cpp/releases
# 找一个带 llama-*-bin-ubuntu-x64.tar.gz 资产的 build 号（nightly tag），
# 修改下面 LLAMA_BUILD 的值即可。
# ============================================================
FROM ubuntu:24.04 AS llama

ARG LLAMA_BUILD=b11120

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl ca-certificates libgomp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) pkg="llama-${LLAMA_BUILD}-bin-ubuntu-x64.tar.gz" ;; \
      arm64) pkg="llama-${LLAMA_BUILD}-bin-ubuntu-arm64.tar.gz" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fL --retry 3 -o /tmp/llama.tar.gz \
      "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/${pkg}"; \
    mkdir -p /llama; \
    tar -xzf /tmp/llama.tar.gz -C /tmp; \
    server_bin="$(find /tmp -name llama-server -type f | head -n1)"; \
    test -n "$server_bin"; \
    src_dir="$(dirname "$server_bin")"; \
    cp -a "$src_dir/." /llama/; \
    rm -rf /tmp/llama.tar.gz "$src_dir"; \
    LD_LIBRARY_PATH=/llama/lib:/llama /llama/llama-server --version

# ============================================================
# 阶段 2：运行时镜像（llama-server + FFmpeg + OpenAI 兼容代理）
# ============================================================
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 python3-venv ffmpeg curl ca-certificates \
        libgomp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# llama.cpp 二进制与动态库
COPY --from=llama /llama /opt/llama
ENV LD_LIBRARY_PATH=/opt/llama/lib:/opt/llama

# Python 代理（OpenAI 兼容层）
RUN python3 -m venv /opt/venv
COPY proxy/requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt
COPY proxy/asr_proxy.py /opt/proxy/asr_proxy.py

# 容器入口
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 模型目录（建议挂载 volume，避免每次重启重新下载）
VOLUME ["/models"]

# ---------- 运行参数（docker run -e / compose environment 可覆盖）----------
ENV MODEL_DIR=/models \
    MODEL_FILE=Qwen3-ASR-1.7B-Q8_0.gguf \
    MMPROJ_FILE=mmproj-Qwen3-ASR-1.7B-Q8_0.gguf \
    HF_ENDPOINT=https://hf-mirror.com \
    HF_REPO=ggml-org/Qwen3-ASR-1.7B-GGUF \
    LLAMA_PORT=8081 \
    LLAMA_THREADS=16 \
    LLAMA_CTX=16384 \
    PROXY_HOST=0.0.0.0 \
    PROXY_PORT=8000 \
    ASR_API_KEY=""

EXPOSE 8000

# 首次启动含模型下载，宽限期给足
HEALTHCHECK --interval=30s --timeout=10s --start-period=1800s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
