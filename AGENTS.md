# AGENTS.md

> Context file for AI agents working on **outloud.nvim**.
> Read this before making changes. It summarises the project state, points to plans, and records architectural decisions.

---

## What This Project Is

**outloud.nvim** — a Neovim plugin for voice-driven coding.

```
Mic → whisper-server (local STT) → transcript → inserted at cursor
          GGML model, Apache 2.0
```

No cloud STT. No TTS. Local-only. You speak, text appears.

**Current version:** 0.6.0 (July 2026)
**License:** Apache 2.0
**Repository:** github.com/jbsolomon/outloud.nvim

---

## Current State: Transcription-Only Mode

The plugin is currently in **transcription-only mode**. The ACP agent integration (Claude Code, Gemini, etc.) has been removed. The plugin:

1. Captures microphone audio via a Rust daemon (`cpal`)
2. Runs energy-based VAD to detect speech boundaries
3. Transcribes audio locally via `whisper-server` + GGML Whisper model (default) or `llama-server` + Voxtral (openai backend)
4. Inserts the final transcript into the **current buffer at cursor position**

What is **NOT** present (removed from the codebase):
- No agent dispatch (no `core.lua`, no `adapters/` directory)
- No snapshot/undo system (no `snapshot.lua`)
- No permission prompts
- No file editing from agent responses

Commands `:OutloudUndo`, `:OutloudSnapshots`, and `:OutloudSnapshotsPrune` exist in `plugin/outloud.vim` but emit a warning that they are unavailable in transcription-only mode.

---

## Plans & Roadmaps

| Document | Purpose | Location |
|----------|---------|----------|
| **Roadmap** | Feature timeline: completed, near-term, mid-term, long-term | [`docs/roadmap.md`](docs/roadmap.md) |
| **Modes Plan** | Streaming & accumulator modes design | [`docs/modes-plan.md`](docs/modes-plan.md) |
| **SPEC** | Technical architecture spec (includes ACP design — partially outdated) | [`SPEC.md`](SPEC.md) |
| **Changelog** | Version history | [`CHANGELOG.md`](CHANGELOG.md) |
| **README** | User-facing documentation (includes ACP sections — partially outdated) | [`README.md`](README.md) |

> **Note:** `SPEC.md` and `README.md` still describe the full ACP agent integration architecture. The actual codebase has been simplified to transcription-only. When making changes, trust the code over the docs if there is a conflict. The `docs/roadmap.md` is the most up-to-date source of truth for what is planned vs. what is done.

---

## File Map

### Lua Plugin (`lua/outloud/`)

| File | Responsibility |
|------|----------------|
| `init.lua` | `setup()`, config defaults, keybindings, `start()`/`stop()`, transcript → buffer insertion |
| `voice.lua` | Spawns/manages the Rust daemon process via `vim.fn.jobstart`. JSON lines protocol over stdin/stdout. |
| `sidebar.lua` | Session sidebar: fixed 4-row status header + conversation entries (turns, partials, errors). Hard-wrapped, re-flowing on resize. |
| `ui.lua` | Statusline component only. Returns compact state strings (`ls:mic`, `ls:...`). |
| `scratchpad.lua` | Floating preview window for scratchpad mode. Uses `snacks.win`. Shows live accumulator content with spinner in title while LLM is refining. |
| `accumulator.lua` | Collects transcript chunks, manages scratchpad mode (iterative LLM refinement via CodeCompanion). |
| **install.lua** | `:OutloudInstall` (cargo build), `whisper-server` and `llama-server` lifecycle (spawn, probe, stall detection, stop, auto-download). |
| **health.lua** | `:checkhealth outloud` — checks daemon binary, STT server (backend-aware), plugin config. |

### Plugin Entry (`plugin/`)

| File | Responsibility |
|------|----------------|
| `outloud.vim` | User commands: `:OutloudStart`, `:OutloudStop`, `:OutloudSidebar`, etc. |

### Rust Daemon (`crates/outloud/`)

| File | Responsibility |
|------|----------------|
| `src/main.rs` | `tokio::main` entry point. Wires stdin commands → audio capture → pipeline → stdout events. |
| `src/audio.rs` | `cpal` microphone capture + energy-based VAD. Emits `AudioEvent::Vad`, `Partial`, `Utterance`, `Error`. |
| `src/protocol.rs` | JSON lines `Command` (stdin) and `Event` (stdout) types. |
| `src/pipeline/mod.rs` | Re-exports pipeline stages. |
| `src/pipeline/source.rs` | Bridges sync `std::sync::mpsc` (from cpal) into async `streamsafe::Source`. |
| `src/pipeline/filter.rs` | `VadFilter`: emits VAD/error as side-effects, passes utterances downstream as `UtteranceData`. |
| `src/pipeline/transform.rs` | `TranscribeTransform`: sends audio to STT backend. Single-in-flight `partial_gate` (semaphore). |
| `src/pipeline/sink.rs` | `EventSink`: writes transcript events to stdout channel. |
| `src/transcribe/mod.rs` | `SpeechTranscriber` trait definition. Re-exports `whisper` and `http` modules. |
| `src/transcribe/whisper.rs` | Whisper backend: WAV encoding, `/inference` endpoint targeting whisper-server. Default. |
| `src/transcribe/http.rs` | OpenAI-compatible backend: WAV encoding, `/v1/audio/transcriptions` + `/v1/chat/completions` fallback. Optional (`openai` feature). |

### Tests (`tests/`)

| File | Responsibility |
|------|----------------|
| `integration.lua` | Full integration test suite (13 sections). Run: `nvim --headless -l tests/integration.lua` |
| `verify.lua` | Lightweight headless verification. Run: `nvim --headless -l tests/verify.lua` |

---

## Architecture

```
Neovim (Lua plugin)
  │
  │ stdin/stdout JSON lines
  ▼
outloud daemon (Rust binary)
  │  - mic capture (cpal)
  │  - energy-based VAD
  │  - STT via whisper-server (HTTP, default) or llama-server (HTTP, openai backend)
  ▼
transcript → inserted at cursor in current buffer
```

### Pipeline (Rust daemon)

The daemon uses the `streamsafe` crate for an async pipeline:

```
AudioSource (cpal → mpsc → async)
  → VadFilter (VAD events → side-channel, utterances → downstream)
  → TranscribeTransform (audio → STT HTTP → text)
  → EventSink (events → stdout JSON lines)
```

### Daemon Protocol (JSON lines)

**Plugin → Daemon (stdin):**
```json
{"cmd": "start_listening"}
{"cmd": "stop_listening"}
{"cmd": "cancel"}
{"cmd": "shutdown"}
```

**Daemon → Plugin (stdout):**
```json
{"type": "status", "state": "listening"}
{"type": "vad", "speaking": true}
{"type": "partial", "text": "interim transcript..."}
{"type": "transcript", "text": "final transcript", "duration_ms": 3200}
{"type": "error", "message": "something went wrong"}
```

---

## Key Design Decisions

1. **Local-only STT** — No cloud dependency. Whisper model runs on-device via `whisper-server` (default) or Voxtral via `llama-server` (openai backend).
2. **Single-in-flight partials** — The `partial_gate` atomic bool ensures only one partial transcription is in flight at a time. Latest-wins policy.
3. **Transcript insertion at cursor** — The transcript is inserted directly into the current buffer at the cursor position. No agent, no file edits.
4. **Auto-managed STT server** — The plugin spawns, probes, and tears down the STT server (`whisper-server` or `llama-server`). Binary and model auto-download from GitHub/HuggingFace on first run.
5. **Full teardown on `VimLeavePre`** — Quitting Neovim always kills the daemon and STT server.
6. **Hard-wrapped sidebar** — Text is hard-wrapped to window width with `wrap` off so box borders stay aligned.
7. **Sidebar entries as a model** — The conversation is a list of typed entries, not appended text. Enables per-entry streaming and resize re-flow.

---

## Development

### Prerequisites
- Neovim >= 0.10
- Rust toolchain (for building the daemon)
- `whisper-server` (auto-downloaded, or install from fstirl/whisper-server)
- Optional: `just` for dev commands

### Commands

```sh
just build          # Build daemon (release)
just test           # Run Rust tests
just lint           # Clippy + format check
just fmt            # Format code
just daemon-dev     # Run daemon in dev mode (reads from mic)
just nvim-dev       # Launch Neovim with plugin loaded
```

### Running Tests

```sh
# Rust daemon tests
cargo test --workspace

# Lua integration tests (requires Neovim)
nvim --headless -l tests/integration.lua

# Lua verification (lightweight)
nvim --headless -l tests/verify.lua
```

### Environment Variables (daemon)

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTLOUD_STT_BACKEND` | `whisper` | Backend: `whisper` (default) or `openai` (OpenAI-compatible) |
| `OUTLOUD_STT_URL` | `http://127.0.0.1:8000` | Server URL (default depends on backend: 8000 for whisper, 8674 for openai) |
| `OUTLOUD_VAD_THRESHOLD` | `0.01` | RMS energy threshold |
| `OUTLOUD_SILENCE_MS` | `400` | Trailing silence before finalization |
| `OUTLOUD_MAX_MS` | `30000` | Max utterance length |
| `OUTLOUD_PARTIAL_MS` | `700` | Partial transcript interval (0 = disabled) |

---

## Git Branches

| Branch | Purpose |
|--------|---------|
| `main` | Primary development branch |
| `fork/voice-transcription-only` | The transcription-only fork (current codebase state) |

---

## Things to Be Careful About

1. **The SPEC and README are partially outdated** — They describe the full ACP agent integration. The actual code is transcription-only. Trust the code.
2. **`partial_gate` is single-in-flight** — The `GateGuard` in `transform.rs` clears the gate on drop. The `modes-plan.md` describes making this a bounded semaphore for concurrent partials.
3. **Sidebar buffer is unlisted** — The sidebar uses `nvim_create_buf(false, true)`. It is cleaned up on `dispose()`.
4. **STT server is managed by the plugin** — `install.lua` spawns `whisper-server` (default) or `llama-server` (openai backend), probes health, and detects stalls. External server mode (`model.server_url`) skips this.
5. **No agent config in current code** — `init.lua` has no `agent` section in defaults. The `README.md` and `SPEC.md` still document it.
6. **Snapshot commands warn** — `:OutloudUndo`, `:OutloudSnapshots`, `:OutloudSnapshotsPrune` emit warnings rather than doing anything.
