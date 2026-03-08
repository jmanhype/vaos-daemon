# Voice Input System

## Overview
Voice input for the OSA TUI — press F2 to toggle recording, transcript appears in the input box for review before sending.

## Architecture

### Local-First (Default — requires `local-voice` feature)
- **whisper-rs** (Rust bindings to whisper.cpp) runs directly in the TUI binary
- No backend changes needed — everything stays in the Rust TUI process
- Model auto-downloads to `~/.osa/models/ggml-base.bin` (~140MB) on first use
- Zero API keys required for basic voice input
- Build with: `cargo build --features local-voice`

### Cloud Optional
- If `VOICE_PROVIDER=cloud` + `OPENAI_API_KEY` are set, uses OpenAI Whisper API
- Falls back to local if cloud fails (and local-voice feature enabled)
- Useful for users who want higher accuracy or don't want local model

## User Flow
1. User presses **F2** in Idle state → recording starts
2. Status bar shows `🎤 Recording — F2 stop · Esc cancel`
3. User speaks, then presses **F2** again to stop (or **Esc** to cancel)
4. Transcript is inserted into the input box (same as paste)
5. User reviews, edits if needed, presses **Enter** to send

## Tech Stack

| Component | Crate | Purpose |
|-----------|-------|---------|
| Mic capture | `cpal 0.15` | Cross-platform audio input |
| WAV encoding | `hound 3.5` | PCM → WAV for Whisper |
| Local transcription | `whisper-rs 0.12` (optional) | whisper.cpp Rust bindings |
| Cloud transcription | `reqwest` (existing) | OpenAI Whisper API |

## Build Requirements
- **Default** (`cargo build`): cpal + hound only — cloud voice works, no LLVM needed
- **Local voice** (`cargo build --features local-voice`): needs LLVM/libclang for whisper-rs bindgen

## New Files
- `priv/rust/tui/src/voice/mod.rs` — Module root, VoiceState, VoiceProvider
- `priv/rust/tui/src/voice/capture.rs` — VoiceCapture (cpal mic, WAV buffer)
- `priv/rust/tui/src/voice/transcribe.rs` — LocalTranscriber + CloudTranscriber

## Modified Files
- `Cargo.toml` — add cpal, hound, whisper-rs (optional), local-voice feature
- `src/main.rs` — add `mod voice;`
- `src/app/state.rs` — add `Recording` variant to AppState
- `src/event/mod.rs` — add `VoiceEvent` enum, `Voice(VoiceEvent)` variant
- `src/app/mod.rs` — add voice fields to App struct
- `src/app/update.rs` — F2 key handling, VoiceEvent dispatch, handle_recording_key
- `src/app/handle_actions.rs` — start_recording, stop_recording, cancel_recording
- `src/app/keys.rs` — add voice_toggle binding
- `src/components/status_bar.rs` — recording indicator

## Audio Specs
- Sample rate: 16kHz mono (Whisper's native format)
- Format: 16-bit PCM WAV
- Max recording: 60 seconds
- Buffer: in-memory (no temp files)

## Key Bindings
| Key | State | Action |
|-----|-------|--------|
| F2 | Idle | Start recording |
| F2 | Recording | Stop recording → transcribe → insert |
| Esc | Recording | Cancel recording (discard audio) |

## Scope Boundaries (v1)
- ✅ F2 toggle recording
- ✅ Transcript → input box
- ✅ Local whisper-rs (behind feature flag)
- ✅ Cloud OpenAI optional
- ✅ Recording indicator in status bar
- ❌ No auto-submit (user presses Enter)
- ❌ No TTS / read-back
- ❌ No continuous listening
- ❌ No conversation mode

## Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| `VOICE_PROVIDER` | `local` | `local` or `cloud` |
| `OPENAI_API_KEY` | — | Required for cloud provider |
| `WHISPER_MODEL` | `base` | Model size: tiny, base, small, medium |
| `WHISPER_MODEL_DIR` | `~/.osa/models` | Where models are stored |
