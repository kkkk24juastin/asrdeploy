# Qwen3-ASR-1.7B 私有部署（Docker + GitHub CI/CD）

在无 GPU 的 Ubuntu 服务器上部署 Qwen3-ASR-1.7B，对外提供 **OpenAI 兼容语音转写接口**。

- 推理引擎：llama.cpp（官方 GGUF，CPU 量化推理，自动利用 AVX-512）
- 镜像构建：GitHub Actions 自动构建并推送到 **GHCR**（`ghcr.io/<owner>/<repo>`）
- 服务器部署：Docker Compose，一条命令拉起
- 模型：`ggml-org/Qwen3-ASR-1.7B-GGUF`（Q8_0，约 2.6 GB，容器首次启动自动下载到 volume）

## 架构

```
本机/仓库 ──push──> GitHub Actions ──构建──> ghcr.io/<owner>/<repo>:latest
                                                     │
服务器:  docker compose pull && up -d                │
        ┌────────────── 容器 qwen3-asr ──────────────▼──────────────┐
        │  代理 0.0.0.0:8000 (OpenAI /v1/audio/transcriptions)      │
        │    └─> llama-server 127.0.0.1:8081 (Qwen3-ASR-1.7B Q8)   │
        │  volume: asr-models -> /models（模型持久化，只下载一次）   │
        └──────────────────────────────────────────────────────────┘
```

## 目录说明

```
asrdeploy/
├── Dockerfile                    # 多阶段构建（llama.cpp 官方二进制 + 代理）
├── docker-compose.yml            # 服务器部署入口
├── docker/entrypoint.sh          # 容器入口：下载模型 -> 启动 llama-server -> 启动代理
├── proxy/
│   ├── asr_proxy.py              # OpenAI 兼容层（清洗输出前缀 / ffmpeg 转码 / 可选鉴权）
│   └── requirements.txt
├── .github/workflows/docker.yml  # CI：构建并推送 GHCR
├── .env.example                  # 配置模板
├── scripts/                      # 裸机（非 Docker）部署脚本，见文末
├── systemd/                      # 裸机 systemd 服务单元
└── tests/                        # 接口测试（smoke.sh / OpenAI SDK 示例）
```

---

## 一、推送到 GitHub（首次，本机执行）

先在 GitHub 网页创建一个**空仓库**（不要勾选初始化 README），然后在本机 PowerShell 执行：

```powershell
cd C:\Users\kkkk24\Desktop\asrdeploy
git init -b main
git add .
git commit -m "init: Qwen3-ASR docker deployment"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> 若安装了 GitHub CLI（`gh`），可以一行完成创建+推送：
> `gh repo create <仓库名> --private --source . --push`

## 二、CI/CD：自动构建镜像（推送即触发）

`.github/workflows/docker.yml` 已配置好，**无需任何额外配置**：

| 触发条件 | 说明 |
|---|---|
| push 到 `main` | 构建并推送 `latest` + `sha-xxxxxxx` |
| 推送 tag（如 `v1.0.0`） | 构建并推送 `v1.0.0` + `sha-xxxxxxx` |
| 手动触发 | Actions 页面 → docker → Run workflow |

构建结果：`ghcr.io/<小写owner>/<小写repo>`（约 600 MB，含 llama.cpp + ffmpeg + 代理）。

**首次推送后建议将镜像设为公开**（否则服务器拉取需要登录 GitHub）：
仓库页面 → 右侧 **Packages** → 打开对应包 → Package settings → Change visibility → Public。

## 三、服务器部署（Ubuntu 24.04）

### 1. 安装 Docker（如已安装跳过）

```bash
# 官方 apt 仓库方式（推荐）
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"    # 重新登录后免 sudo
```

> 也可以使用官方一键脚本 `curl -fsSL https://get.docker.com | sh`（会执行来自网络的安装脚本，请自行评估）。

### 2. 获取部署文件

方式 A：直接在服务器 clone 仓库（推荐）：

```bash
git clone https://github.com/<你的用户名>/<仓库名>.git ~/asrdeploy
cd ~/asrdeploy
cp .env.example .env
```

方式 B：从本机传：

```powershell
scp docker-compose.yml .env user@服务器IP:~/asrdeploy/
```

### 3. 修改镜像地址

编辑 `docker-compose.yml`，把 `image:` 改成你实际的 GHCR 地址：

```yaml
image: ghcr.io/<你的用户名>/<仓库名>:latest
```

### 4. 启动

```bash
docker compose pull          # 拉取 CI 构建好的镜像
docker compose up -d         # 启动
docker compose logs -f       # 首次启动会自动下载模型（约 2.6 GB）
```

看到 `llama-server 就绪` 后即可使用。等待时间 = 下载模型 + 加载模型（首次较长，之后 volume 里有模型，几十秒内就绪）。

### 5. 测试

```bash
curl -sS http://127.0.0.1:8000/v1/audio/transcriptions \
  -F file=@你的音频.wav \
  -F model=qwen3-asr \
  -F response_format=json
# => {"text": "转写文本"}
```

也可以把 `tests/smoke.sh` 和 `tests/client_example.py` 拷到服务器使用。

### 6. 更新版本

```bash
docker compose pull && docker compose up -d
```

模型保存在命名 volume `asr-models` 中，更新镜像不会重新下载。

## 四、配置（.env / compose environment）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PROXY_PORT` | 8000 | 宿主机映射端口 |
| `ASR_API_KEY` | 空 | 设置后客户端需要 `Authorization: Bearer <key>`；**对外暴露前务必设置** |
| `HF_ENDPOINT` | `https://hf-mirror.com` | 模型下载源，可换 `https://huggingface.co` |
| `LLAMA_THREADS` | 16 | CPU 推理线程数（9950X 为 16 物理核，可实测 8/12/16） |
| `LLAMA_CTX` | 16384 | 上下文长度，决定单文件可处理的最长音频（约 10 分钟） |

## 五、API 用法

### POST /v1/audio/transcriptions（OpenAI 兼容）

| 参数 | 说明 |
|---|---|
| `file` | 音频文件（wav / mp3 / m4a / flac 等，容器内 ffmpeg 自动转 16kHz 单声道） |
| `model` | 任意值（固定使用加载的 Qwen3-ASR-1.7B，兼容传 `whisper-1`） |
| `language` | 可选，模型自动检测（中英混说支持） |
| `response_format` | `json`（默认）/ `text` / `verbose_json` |
| `Authorization` | `Bearer <ASR_API_KEY>`（若已配置） |

其他端点：`GET /health`、`GET /v1/models`。

Python（OpenAI SDK）：

```python
from openai import OpenAI
client = OpenAI(base_url="http://服务器IP:8000/v1", api_key="你的ASR_API_KEY")
with open("audio.wav", "rb") as f:
    print(client.audio.transcriptions.create(model="qwen3-asr", file=f).text)
```

## 六、性能与调优

- **线程**：`LLAMA_THREADS=16` 起步，实测 8/12/16 选最优（超线程反而可能略慢）。
- **精度档**：改 `MODEL_FILE=Qwen3-ASR-1.7B-bf16.gguf`（4.1 GB，质量最高、速度约减半）。
- **速度档**：换社区 Q4_K_M 量化（约 1.2 GB）或 Qwen3-ASR-0.6B。
- **镜像自带多指令集**：llama.cpp 官方二进制含 CPU 变体分发，9950X 会自动走 AVX-512 优化路径。
- **长音频**：默认约支持 10 分钟内单文件；更长可加大 `LLAMA_CTX`（256 GB 内存充裕）。

## 七、常见问题

| 现象 | 处理 |
|---|---|
| **服务器拉不动 ghcr.io（国内常见）** | ① 服务器本地构建：把仓库 clone 到服务器后 `docker compose up -d --build`，跳过拉镜像；② 在 GitHub Actions 里追加推送到阿里云 ACR / 腾讯云 TCR 再拉取；③ 配置 Docker 代理 |
| 模型下载卡住 | `.env` 中 `HF_ENDPOINT` 更换下载源；重试会断点续传 |
| 首次启动 "卡住" | 正常：正在下载 2.6 GB 模型，看 `docker compose logs -f` |
| 端口冲突 | 修改 `.env` 的 `PROXY_PORT` |
| 转写慢 | 检查 `LLAMA_THREADS`；避免与其他重负载抢 CPU |
| 识别错字多 | 换 bf16 权重；确认音频质量；必要时用 `Qwen3-ForcedAligner` 做时间轴或考虑加 GPU |

## 八、本机（无 Docker 环境）验证镜像构建

CI 会在 GitHub 上完成构建；如需本地验证：

```bash
docker build -t qwen3-asr:local .
docker run --rm -p 8000:8000 -v asr-models:/models qwen3-asr:local
```

## 九、裸机（非 Docker）备选方案

同一仓库保留了不经 Docker 的部署方式，适合不能用容器的环境：

```bash
./scripts/01-install.sh        # 装依赖 + llama.cpp 预编译包 + venv
./scripts/02-download-models.sh
./scripts/service.sh start     # 或安装 systemd/ 下的服务单元
```

细节见 `scripts/`、`systemd/` 内注释。

## 许可

- llama.cpp：MIT ｜ Qwen3-ASR 权重：Apache License 2.0 ｜ 本项目脚本：随仓库使用
