"""
StreamTalk TTS proxy — Triton gRPC (CosyVoice3 full-power) edition.

Bridges the native macOS app to the CosyVoice3 Triton server (gRPC streaming,
decoupled mode). The app POSTs text; this proxy runs a zero-shot synthesis
against Triton using a reference voice, collects the streamed audio chunks, and
returns one WAV.

    POST /tts   {"text": "...", "server": "host:18001", "ref_text": "...", "ref_audio": "/path.wav"}
    GET  /health

CosyVoice3 is zero-shot: the OUTPUT VOICE is cloned from the reference audio, and
the language is whatever the target text is written in. There is no "instruct".

Config via env:
    TRITON_SERVER   gRPC host:port      (default pc-lan.home:18001)
    TRITON_MODEL    model name          (default cosyvoice3)
    REF_WAV         reference voice wav  (default voices/ref_zh.wav)
    REF_TEXT        transcript of REF_WAV, end with <|endofprompt|>
    PORT            listen port          (default 8787)
"""

import functools
import io
import os
import queue
import threading
import uuid

import numpy as np
import soundfile as sf
import tritonclient.grpc as grpcclient
from tritonclient.utils import InferenceServerException

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

HERE = os.path.dirname(os.path.abspath(__file__))
TRITON_SERVER = os.environ.get("TRITON_SERVER", "pc-lan.home:18001")
MODEL = os.environ.get("TRITON_MODEL", "cosyvoice3")
REF_WAV = os.environ.get("REF_WAV", os.path.join(HERE, "voices", "ref_zh.wav"))
REF_TEXT = os.environ.get(
    "REF_TEXT", "希望你以后能够做得比我还好，每天都开开心心。<|endofprompt|>"
)
PORT = int(os.environ.get("PORT", "8787"))

REF_SR = 16000      # server hard-codes 16k reference input
OUT_SR = 24000      # cosyvoice3 output sample rate
PADDING = 10        # matches the official streaming client

app = FastAPI(title="StreamTalk TTS proxy (Triton)")


# ---- reference voice -------------------------------------------------------

def load_ref(path: str) -> np.ndarray:
    wav, sr = sf.read(path)
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    if sr != REF_SR:
        from scipy.signal import resample
        wav = resample(wav, int(len(wav) * REF_SR / sr))
    return wav.astype(np.float32)


_ref_cache: dict[str, np.ndarray] = {}


def ref_waveform(path: str) -> np.ndarray:
    if path not in _ref_cache:
        _ref_cache[path] = load_ref(path)
    return _ref_cache[path]


# ---- Triton streaming client (serialised: one synth at a time) -------------

class _UserData:
    def __init__(self):
        self.q: queue.Queue = queue.Queue()


def _stream_cb(user_map, result, error):
    rid = None
    if not error:
        rid = result.get_response().id
    if rid and rid in user_map:
        user_map[rid].q.put(error if error else result)
    elif error:
        for ud in user_map.values():   # unroutable error → wake all waiters
            ud.q.put(error)


_lock = threading.Lock()
_client: grpcclient.InferenceServerClient | None = None
_client_addr: str | None = None
_user_map: dict[str, _UserData] = {}


def _norm_addr(addr: str) -> str:
    return addr.replace("http://", "").replace("https://", "").strip().rstrip("/")


def ensure_stream(addr: str, force_new: bool = False) -> grpcclient.InferenceServerClient:
    global _client, _client_addr
    if force_new or _client is None or _client_addr != addr:
        if _client is not None:
            try:
                _client.stop_stream()
                _client.close()
            except Exception:
                pass
        _client = grpcclient.InferenceServerClient(url=addr, verbose=False)
        _client.start_stream(callback=functools.partial(_stream_cb, _user_map))
        _client_addr = addr
    return _client


def build_inputs(waveform: np.ndarray, ref_text: str, target_text: str):
    dur = len(waveform) / REF_SR
    est = dur / max(len(ref_text), 1) * len(target_text) if ref_text else dur
    total = PADDING * REF_SR * ((int(est + dur) // PADDING) + 1)
    padded = np.zeros((1, total), dtype=np.float32)
    padded[0, : len(waveform)] = waveform
    lengths = np.array([[len(waveform)]], dtype=np.int32)

    inp = [
        grpcclient.InferInput("reference_wav", padded.shape, "FP32"),
        grpcclient.InferInput("reference_wav_len", lengths.shape, "INT32"),
        grpcclient.InferInput("reference_text", [1, 1], "BYTES"),
        grpcclient.InferInput("target_text", [1, 1], "BYTES"),
    ]
    inp[0].set_data_from_numpy(padded)
    inp[1].set_data_from_numpy(lengths)
    inp[2].set_data_from_numpy(np.array([ref_text], dtype=object).reshape(1, 1))
    inp[3].set_data_from_numpy(np.array([target_text], dtype=object).reshape(1, 1))
    return inp, [grpcclient.InferRequestedOutput("waveform")]


def synth(addr: str, target_text: str, ref_wav: np.ndarray, ref_text: str) -> np.ndarray:
    inputs, outputs = build_inputs(ref_wav, ref_text, target_text)
    rid = str(uuid.uuid4())
    ud = _UserData()
    _user_map[rid] = ud
    try:
        client = ensure_stream(addr)
        client.async_stream_infer(MODEL, inputs, request_id=rid, outputs=outputs,
                                  enable_empty_final_response=True)
        chunks = []
        while True:
            res = ud.q.get(timeout=120)
            if isinstance(res, InferenceServerException):
                raise res
            resp = res.get_response()
            if resp.parameters["triton_final_response"].bool_param:
                break
            chunk = res.as_numpy("waveform").reshape(-1)
            if chunk.size > 0:
                chunks.append(chunk)
        if not chunks:
            raise RuntimeError("no audio chunks returned")
        return np.concatenate(chunks)
    finally:
        _user_map.pop(rid, None)


# ---- HTTP API --------------------------------------------------------------

class TTSRequest(BaseModel):
    text: str
    server: str | None = None      # Triton gRPC host:port override
    ref_audio: str | None = None   # reference voice wav path override
    ref_text: str | None = None    # reference transcript override
    instruct: str | None = None    # ignored (legacy)


@app.get("/health")
def health():
    addr = _norm_addr(TRITON_SERVER)
    try:
        ready = grpcclient.InferenceServerClient(url=addr, verbose=False).is_server_ready()
        return {"ok": bool(ready), "server": addr, "model": MODEL, "ref": REF_WAV}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "server": addr, "error": str(e)}


@app.post("/tts")
def tts(req: TTSRequest):
    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")

    addr = _norm_addr(req.server or TRITON_SERVER)
    ref_path = req.ref_audio or REF_WAV
    ref_text = req.ref_text or REF_TEXT
    try:
        ref_wav = ref_waveform(ref_path)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=f"参考音频读取失败 {ref_path}: {e}")

    audio = None
    last_err = None
    with _lock:   # CosyVoice runs one job at a time; serialise + retry on drop
        for attempt in range(2):
            try:
                audio = synth(addr, text, ref_wav, ref_text)
                break
            except Exception as e:  # noqa: BLE001
                last_err = e
                try:
                    ensure_stream(addr, force_new=True)
                except Exception:
                    pass
    if audio is None:
        raise HTTPException(
            status_code=502,
            detail=f"连接 TTS(Triton) 失败：{addr}（内网 PC / 容器是否在线？）原始错误: {last_err!r}",
        )

    buf = io.BytesIO()
    sf.write(buf, audio, OUT_SR, format="WAV", subtype="PCM_16")
    return Response(content=buf.getvalue(), media_type="audio/wav")


if __name__ == "__main__":
    import uvicorn
    print(f"[tts-proxy] triton={TRITON_SERVER} model={MODEL} ref={REF_WAV} port={PORT}")
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")
