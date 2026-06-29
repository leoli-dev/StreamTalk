# StreamTalk

A native macOS **voice chat** app: hold a button (or tap the **left ⌥ Option**
key), talk, and the AI replies **out loud** — streaming the answer sentence by
sentence so you hear the first words while the rest is still being generated.

```
You speak ─▶ Apple Speech (STT) ─▶ LLM (streaming) ─▶ split into sentences
                                                          │
   speaker ◀── AVAudioEngine queue ◀── WAV ◀── TTS ◀──────┘
```

Built in SwiftUI. Talks to **any OpenAI-compatible / Anthropic LLM** and a
**CosyVoice-style TTS HTTP service** that you host yourself.

> ⚠️ **Prerequisite: you must already have a TTS service running** (and an LLM).
> StreamTalk is just the client — it does **not** ship a TTS engine. See
> [Prerequisites](#prerequisites).

---

## Features

- 🎙 **Voice in, voice out** — push-to-talk with auto-stop on silence; AI answer
  is spoken back.
- ⚡ **Low latency pipeline** — the reply is chunked into sentences; sentence *N*
  plays while *N+1* is still being synthesized.
- ♾ **Continuous mode** — after the AI finishes, the mic reopens automatically so
  you can just keep talking. Stops gracefully if you go quiet.
- ⌥ **Global hotkey** — tap the left Option key to start/stop talking (works in
  the background with Accessibility permission).
- 💬 **Sessions** — multiple conversations, saved to disk, each with its **own
  optional system prompt**.
- 🌐 **Independent input/output languages** — recognize Cantonese while the AI
  replies in English, etc. (粤语 / 普通话 / English).
- 🧠 **Multiple LLM providers** — local OpenAI-compatible (e.g. an MLX server),
  OpenAI, Claude, DeepSeek, MiniMax — switch from the toolbar.

---

## Prerequisites

You provide two backends; StreamTalk connects to them.

### 1. A TTS service (required)

An HTTP endpoint compatible with the **CosyVoice FastAPI** shape:

```
POST {TTS_SERVER}/v1/audio/speech
Content-Type: application/json

{ "input": "text to speak", "response_format": "wav",
  "instruct": "请用广东话表达，语气清晰、自然。" }

→ 200, body = audio bytes (WAV)
```

- The app sends `input` + `response_format: "wav"` + `instruct` (the instruct
  string carries the dialect/style, derived from the selected reply language).
- Any service that accepts that request and returns a WAV the system can decode
  will work. Reference implementation: the CosyVoice3 FastAPI server
  (`/v1/audio/speech`, returns 24 kHz mono WAV).
- A `GET {TTS_SERVER}/health` returning `200` is nice to have but not required.

> The `tts-proxy/` directory contains an optional legacy Python bridge (Gradio /
> Triton gRPC adapters) from earlier iterations. It is **not needed** for the
> current build — the app calls the TTS HTTP API directly.

### 2. An LLM (required — pick one)

- **Local / OpenAI-compatible**: anything exposing `POST /v1/chat/completions`
  with SSE streaming (e.g. an MLX or vLLM server). Default target
  `http://127.0.0.1:8000/v1`.
- **Cloud**: OpenAI, DeepSeek, MiniMax (OpenAI-compatible) or **Claude**
  (Anthropic Messages API). Enter the key/model in Settings.

### 3. Toolchain

- macOS 14+ and **Xcode 16+ / Swift 6** (`swift build`).

---

## Build & run

```bash
cd StreamTalk
./build-app.sh          # compiles, assembles StreamTalk.app, ad-hoc signs it
open StreamTalk.app
```

First launch asks for **Microphone** and **Speech Recognition** permission.
For the global Option-key hotkey to work in the background, also allow StreamTalk
under **System Settings → Privacy & Security → Accessibility**.

> Because the app is **ad-hoc signed**, Gatekeeper may block a double-click the
> first time — right-click the app → **Open**, or run `open StreamTalk.app` from
> a terminal once.

---

## Configuration

Two ways, in order of precedence: **Settings UI** (persisted to UserDefaults) and
a **`.env`** file read on first run to seed defaults.

### `.env` (keeps secrets out of the app / out of git)

Copy the template and fill in your values:

```bash
cp .env.example ~/.config/streamtalk/.env
# then edit ~/.config/streamtalk/.env
```

```ini
STREAMTALK_LOCAL_KEY=your-local-llm-key
STREAMTALK_LLM_BASE=http://127.0.0.1:8000/v1
STREAMTALK_LLM_MODEL=your-model-id
STREAMTALK_TTS_SERVER=http://your-tts-host:5055
```

Lookup order: `$STREAMTALK_ENV` → `~/.config/streamtalk/.env` → `./.env`.
`.env` is gitignored — **never commit real keys**.

### Settings UI

Open the gear icon. You can set, per provider, the base URL / API key / model;
the TTS server address; the spoken (STT) language and reply language; the system
prompt; continuous mode; and the Option-key hotkey. Cloud keys are entered here
(not in source).

---

## Usage

- **Talk**: click the mic button, or tap the **left ⌥ Option** key. Speak; it
  auto-stops after a short silence. Tap again to interrupt.
- **Type**: use the text box and press return.
- **Languages** (toolbar): 🎙 = what you speak (STT), 🔊 = how the AI replies
  (voice + text). They're independent.
- **Provider** (toolbar): switch LLM backend.
- **♾**: toggle continuous (hands-free) mode.
- **💬**: give the current conversation its own system prompt (empty = default).
- **Sidebar**: manage saved sessions.

---

## Notes & limitations

- **macOS only** (native AppKit/AVFoundation/Speech).
- **Cantonese STT** uses Apple's `yue-CN`, which is **online** recognition
  (needs a network / the dictation language installed). `zh-HK` is Mandarin-ish,
  not Cantonese — don't use it for Cantonese input.
- **Smoothness depends on your TTS speed.** If the TTS server's real-time factor
  (RTF) is > 1 (generating slower than playback), long replies can still stutter
  — keep replies short (the default prompt enforces this) or speed up the server.
- The app sends plain-HTTP requests to a LAN TTS host, so ATS arbitrary loads is
  enabled in `Info.plist` (fine for a personal LAN app).

## Repo layout

```
StreamTalk/        SwiftUI app (Swift Package) + build-app.sh + Info.plist
  Sources/StreamTalk/
    ChatViewModel   orchestrator (STT → LLM → chunk → TTS → playback)
    LLMProvider / OpenAICompatibleProvider / ClaudeProvider
    SpeechRecognizer / SentenceChunker / TTSClient / AudioPlayer
    SessionStore / Config / Models / MainView / SettingsView
  icon/            app icon generator + assets
tts-proxy/         optional legacy Python TTS bridge (not used by current build)
.env.example       config template (copy to ~/.config/streamtalk/.env)
```

## License

No license yet — add one (e.g. MIT) before sharing if you want others to reuse it.
