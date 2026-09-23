"""OpenAI SDK 调用示例。

准备: pip install openai
用法: python client_example.py 音频.wav [http://127.0.0.1:8000/v1] [api_key]

与官方 OpenAI 用法完全一致，只需替换 base_url。
"""
import sys

from openai import OpenAI


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(1)

    audio_path = sys.argv[1]
    base_url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8000/v1"
    api_key = sys.argv[3] if len(sys.argv) > 3 else "sk-no-key-required"

    client = OpenAI(base_url=base_url, api_key=api_key)

    with open(audio_path, "rb") as fh:
        result = client.audio.transcriptions.create(
            model="qwen3-asr",
            file=fh,
            response_format="json",
        )

    print("文本:", result.text)


if __name__ == "__main__":
    main()
