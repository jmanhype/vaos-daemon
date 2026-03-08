# Voice Input System

Voice input for the OSA TUI — press F2 to toggle recording. The transcript appears in the input box for review before sending.

---

## Status

The voice system is implemented in the Rust TUI binary (`priv/rust/tui/`). It is not active in the Elixir backend — all audio capture and transcription runs entirely within the TUI process. The Elixir backend receives the transcript as a normal text message; it has no awareness that voice was used.

---

## Architecture

```
TUI (Rust)
├── cpal          — cross-platform mic capture
├── hound         — PCM → WAV encoding
└── Transcription
    ├── Local: whisper-rs (behind feature flag, needs LLVM)
    └── Cloud: OpenAI Whisper API (reqwest, existing HTTP client)
```

### Local Mode (Default)

- Uses `whisper-rs` — Rust bindings to whisper.cpp
- Model auto-downloads to `~/.osa/models/ggml-base.bin` (~140 MB) on first run
- No API keys required
- Requires `cargo build --features local-voice` (needs LLVM/libclang for bindgen)

### Cloud Mode

- Set `VOICE_PROVIDER=cloud` and `OPENAI_API_KEY`
- Sends WAV to OpenAI Whisper API
- Falls back to local mode if the API call fails and local mode is enabled
- Higher accuracy, no local LLVM requirement

---

## User Flow

1. Press **F2** in Idle state — recording starts
2. Status bar shows: `Recording — F2 stop · Esc cancel`
3. Speak, then press **F2** to stop (or **Esc** to cancel)
4. Transcript is inserted into the input box (same as paste)
5. Review, edit if needed, then press **Enter** to send

---

## Audio Specs

| Property | Value |
|----------|-------|
| Sample rate | 16 kHz mono (Whisper's native format) |
| Encoding | 16-bit PCM WAV |
| Max recording | 60 seconds |
| Buffer | In-memory (no temp files on disk) |

---

## Key Bindings

| Key | State | Action |
|-----|-------|--------|
| F2 | Idle | Start recording |
| F2 | Recording | Stop and transcribe |
| Esc | Recording | Cancel (discard audio) |

---

## Build

```bash
# Default build — cloud voice works, no LLVM needed
cargo build

# With local whisper support — requires LLVM/libclang
cargo build --features local-voice
```

---

## Source Files

| File | Purpose |
|------|---------|
| `priv/rust/tui/src/voice/mod.rs` | Module root, `VoiceState`, `VoiceProvider` enum |
| `priv/rust/tui/src/voice/capture.rs` | `VoiceCapture` — cpal mic input, WAV buffer |
| `priv/rust/tui/src/voice/transcribe.rs` | `LocalTranscriber` + `CloudTranscriber` |

Modified files: `Cargo.toml`, `src/app/state.rs`, `src/event/mod.rs`, `src/app/mod.rs`, `src/app/update.rs`, `src/app/handle_actions.rs`, `src/components/status_bar.rs`

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VOICE_PROVIDER` | `local` | `local` or `cloud` |
| `OPENAI_API_KEY` | — | Required for cloud mode |
| `WHISPER_MODEL` | `base` | Model size: `tiny`, `base`, `small`, `medium` |
| `WHISPER_MODEL_DIR` | `~/.osa/models` | Model download directory |

---

## Scope (v1)

| Included | Not Included |
|----------|--------------|
| F2 toggle recording | Auto-submit (user always presses Enter) |
| Transcript injected into input box | TTS / read-back |
| Local whisper-rs (feature flag) | Continuous listening mode |
| Cloud OpenAI fallback | Conversation mode |
| Recording indicator in status bar | |

---

## Crate Versions

| Crate | Version | Purpose |
|-------|---------|---------|
| `cpal` | 0.15 | Cross-platform audio input |
| `hound` | 3.5 | PCM → WAV encoding |
| `whisper-rs` | 0.12 | whisper.cpp Rust bindings (optional feature) |
| `reqwest` | existing | Cloud Whisper API HTTP calls |
