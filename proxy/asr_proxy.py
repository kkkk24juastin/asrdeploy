#!/usr/bin/env python3
"""Qwen3-ASR OpenAI-compatible proxy.

Sits in front of llama-server and exposes a clean OpenAI /v1/audio/transcriptions
API: strips the "language X<asr_text>" prefix Qwen3-ASR emits, normalizes the
response, optionally runs ffmpeg to 16 kHz mono WAV, and enforces an optional
bearer token.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from typing import Optional

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "http://127.0.0.1:8081").rstrip("/")
API_KEY = os.environ.get("ASR_API_KEY", "").strip()
MODEL_NAME = os.environ.get("MODEL_NAME", "Qwen3-ASR-1.7B")
REQUEST_TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "3600"))

PREFIX_RE = re.compile(r"^\s*language\s+(\S+?)\s*<asr_text>\s*", re.IGNORECASE)
SUPPORTED_FORMATS = {"json", "text", "verbose_json"}

app = FastAPI(title="Qwen3-ASR proxy", version="1.0")
client = httpx.AsyncClient(timeout=httpx.Timeout(connect=10.0, read=REQUEST_TIMEOUT, write=REQUEST_TIMEOUT, pool=None))


def _check_auth(authorization: Optional[str]) -> None:
    if not API_KEY:
        return
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    if authorization.split(" ", 1)[1].strip() != API_KEY:
        raise HTTPException(status_code=401, detail="invalid api key")


def _to_16k_wav(src_path: str, tmpdir: str) -> str:
    """Convert any ffmpeg-readable audio to 16 kHz mono PCM WAV."""
    if not shutil.which("ffmpeg"):
        return src_path
    dst_path = os.path.join(tmpdir, "converted16k.wav")
    proc = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", src_path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
            dst_path,
        ],
        capture_output=True,
    )
    return dst_path if proc.returncode == 0 else src_path


def _clean_text(raw: str) -> tuple[str, Optional[str]]:
    """Strip the ASR prefix; returns (text, language or None)."""
    m = PREFIX_RE.match(raw)
    if not m:
        return raw.strip(), None
    return PREFIX_RE.sub("", raw, count=1).strip(), m.group(1)


@app.get("/health")
async def health() -> JSONResponse:
    try:
        r = await client.get(f"{UPSTREAM_URL}/health", timeout=5.0)
        upstream_ok = r.status_code == 200
    except httpx.HTTPError:
        upstream_ok = False
    status_code = 200 if upstream_ok else 503
    return JSONResponse(
        {"status": "ok" if upstream_ok else "upstream_unavailable", "upstream": UPSTREAM_URL},
        status_code=status_code,
    )


@app.get("/v1/models")
async def models() -> JSONResponse:
    return JSONResponse(
        {
            "object": "list",
            "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "local"}],
        }
    )


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form("qwen3-asr"),
    language: Optional[str] = Form(None),
    response_format: str = Form("json"),
    temperature: float = Form(0.0),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)
    if response_format not in SUPPORTED_FORMATS:
        raise HTTPException(status_code=400, detail=f"response_format '{response_format}' not supported (use json / text / verbose_json)")

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="empty file")

    suffix = os.path.splitext(file.filename or "")[1].lower() or ".bin"
    with tempfile.TemporaryDirectory() as tmpdir:
        src_path = os.path.join(tmpdir, "input" + suffix)
        with open(src_path, "wb") as fh:
            fh.write(raw)
        send_path = _to_16k_wav(src_path, tmpdir)
        with open(send_path, "rb") as fh:
            try:
                resp = await client.post(
                    f"{UPSTREAM_URL}/v1/audio/transcriptions",
                    files={"file": (os.path.basename(send_path), fh, "audio/wav")},
                    data={"response_format": "json", "temperature": "0"},
                )
            except httpx.HTTPError as exc:
                raise HTTPException(status_code=502, detail=f"upstream request failed: {exc}")

    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"upstream error {resp.status_code}: {resp.text[:500]}")

    payload = resp.json()
    text, detected_lang = _clean_text(str(payload.get("text", "")))

    if response_format == "text":
        return PlainTextResponse(text)
    if response_format == "verbose_json":
        return JSONResponse(
            {
                "task": "transcribe",
                "language": (language or detected_lang or "unknown"),
                "duration": None,
                "text": text,
                "segments": [],
            }
        )
    return JSONResponse({"text": text})
