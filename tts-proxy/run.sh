#!/bin/bash
# Start the TTS proxy (Triton gRPC edition).
# Uses Python 3.12 — grpcio/tritonclient have no wheels for 3.14 yet.
set -euo pipefail
cd "$(dirname "$0")"

PY=python3.12
command -v "$PY" >/dev/null || PY=python3   # fallback (grpcio must build)

if [ ! -d .venv ]; then
    echo "==> creating venv ($PY) + installing deps (first run)"
    "$PY" -m venv .venv
    .venv/bin/pip install -q --upgrade pip
    .venv/bin/pip install -q -r requirements.txt
fi

# CosyVoice3 Triton gRPC server (host:port). Override if your IP differs.
export TRITON_SERVER="${TRITON_SERVER:-pc-lan.home:18001}"
# Reference voice (zero-shot): the OUTPUT voice is cloned from this clip.
# export REF_WAV="$(pwd)/voices/ref_zh.wav"
# export REF_TEXT="希望你以后能够做得比我还好，每天都开开心心。<|endofprompt|>"

exec .venv/bin/python tts_proxy.py
