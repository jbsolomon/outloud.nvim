# Backend Migration: llama-server → whisper-server

> **Status:** COMPLETED — Rust daemon and Lua plugin updated. Docs partially updated (AGENTS.md, roadmap, CHANGELOG done; README and SPEC still reference old architecture).
> **Date:** July 2026
> **Goal:** Replace llama-server + Voxtral Mini 3B with whisper-server as the default STT backend, while supporting generic backends via the existing `SpeechTranscriber` trait.

---

## Why This Migration

- **llama.cpp does not support streaming STT** in the whisper-style incremental fashion needed for low-latency partials
- **whisper-server** provides a dedicated STT HTTP server with streaming support, better endpointing, and whisper models that are purpose-built for transcription (not repurposed LLMs)
- The existing `SpeechTranscriber` trait already provides the abstraction boundary — the work is in wiring a new backend implementation and updating the lifecycle management

---

## Current Architecture (Baseline)

```
Neovim (Lua)
  │
  │ JSON lines
  ▼
outloud daemon (Rust)
  │  - cpal mic capture
  │  - energy-based VAD
  │  - HttpTranscriber → llama-server HTTP
  ▼
transcript → buffer insertion
```

**Key files touching llama-server:**

| File | What It Does |
|------|-------------|
| `crates/outloud/src/transcribe/http.rs` | HTTP client targeting llama-server's OpenAI-compatible endpoints (`/v1/audio/transcriptions`, `/v1/chat/completions`). Model hardcoded to `"voxtral"`. Default URL `127.0.0.1:8674`. |
| `crates/outloud/src/transcribe/mod.rs` | `SpeechTranscriber` trait — the abstraction. Already generic. |
| `crates/outloud/src/main.rs` | `build_transcriber()` function — currently only builds `HttpTranscriber`. Reads `OUTLOUD_STT_URL` env var. |
| `lua/outloud/install.lua` | Spawns/manages `llama-server` process. Auto-downloads Voxtral GGUF from HuggingFace (`ggml-org/Voxtral-Mini-3B-2507-GGUF`). Health probes `/health` on port 8674. |
| `lua/outloud/init.lua` | Config defaults: `model.server_port = 8674`, `model.hf_repo = "ggml-org/Voxtral-Mini-3B-..."`. `build_daemon_env()` passes `OUTLOUD_STT_URL`. Calls `install.start_llama_server()` on `M.start()`. |
| `lua/outloud/health.lua` | Checks for `llama-server` binary in PATH. |
| `crates/outloud/Cargo.toml` | Feature flag `http` enables reqwest/base64/hound deps. |

---

## Target Architecture

```
Neovim (Lua)
  │
  │ JSON lines
  ▼
outloud daemon (Rust)
  │  - cpal mic capture
  │  - energy-based VAD
  │  - WhisperTranscriber → whisper-server HTTP  (DEFAULT)
  │  - HttpTranscriber → generic OpenAI-compatible (OPTIONAL)
  ▼
transcript → buffer insertion
```

**Design principle:** whisper-server is the **default** backend. The existing `HttpTranscriber` (OpenAI-compatible) remains as an **optional** backend for users who want to use llama-server, vLLM, or other OpenAI-compatible servers.

---

## Required Changes

### Phase 1: Rust Daemon — New Backend Implementation

#### 1.1 New file: `crates/outloud/src/transcribe/whisper.rs`

Create a `WhisperTranscriber` implementing `SpeechTranscriber`, targeting whisper-server's API.

**whisper-server API** (reference: [fstirl/whisper-server](https://github.com/fstirl/whisper-server)):
- Default port: `8000` (configurable)
- Transcription endpoint: `POST /inference` — accepts WAV/PCM audio, returns JSON with `text` field
- Health endpoint: `GET /` or `GET /health` (depends on version)
- Model selection: typically via command-line flag when starting whisper-server, not per-request
- Streaming: `POST /inference` with `stream=true` for Server-Sent Events (future work, not required for initial migration)

```rust
// Sketch of the implementation
pub const DEFAULT_SERVER_URL: &str = "http://127.0.0.1:8000";

pub struct WhisperTranscriberConfig {
    pub server_url: String,
}

pub struct WhisperTranscriber {
    server_url: String,
    client: reqwest::blocking::Client,
}

impl WhisperTranscriber {
    pub fn new(config: WhisperTranscriberConfig) -> Self { ... }

    fn try_inference_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        // POST {server_url}/inference
        // multipart form with audio file
        // parse JSON response for .text field
    }
}

impl SpeechTranscriber for WhisperTranscriber {
    fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<TranscribeResult> { ... }
    fn is_ready(&self) -> bool { ... }  // GET /health or GET /
    fn name(&self) -> &str { "whisper" }
}
```

**Key differences from `HttpTranscriber`:**
- Single endpoint (`/inference`) vs two endpoints (transcription + chat fallback)
- No model name in request (model is selected at server startup)
- Response format: `{ "text": "..." }` vs OpenAI's `{ "text": "..." }` (similar but no choices array)
- Default port 8000 vs 8674

#### 1.2 Update: `crates/outloud/src/transcribe/mod.rs`

```rust
#[cfg(feature = "http")]
pub mod http;

#[cfg(feature = "whisper")]  // NEW feature flag
pub mod whisper;
```

#### 1.3 Update: `crates/outloud/src/main.rs`

Update `build_transcriber()` to support backend selection:

```rust
fn build_transcriber() -> Result<Box<dyn SpeechTranscriber>> {
    let backend = std::env::var("OUTLOUD_STT_BACKEND").unwrap_or_else(|_| "whisper".to_string());
    let server_url = std::env::var("OUTLOUD_STT_URL").unwrap_or_else(|_| {
        // Default URL depends on backend
        match backend.as_str() {
            "whisper" => "http://127.0.0.1:8000".to_string(),
            "http" => "http://127.0.0.1:8674".to_string(),  // llama-server default
            _ => "http://127.0.0.1:8000".to_string(),
        }
    });

    match backend.as_str() {
        #[cfg(feature = "whisper")]
        "whisper" => {
            use outloud::transcribe::whisper::{WhisperTranscriber, WhisperTranscriberConfig};
            Ok(Box::new(WhisperTranscriber::new(WhisperTranscriberConfig { server_url })))
        }
        #[cfg(feature = "http")]
        "http" => {
            use outloud::transcribe::http::{HttpTranscriber, HttpTranscriberConfig};
            Ok(Box::new(HttpTranscriber::new(HttpTranscriberConfig { server_url })))
        }
        _ => anyhow::bail!("unknown STT backend: {}", backend),
    }
}
```

**New env var:** `OUTLOUD_STT_BACKEND` — `"whisper"` (default) or `"http"` (OpenAI-compatible)

#### 1.4 Update: `crates/outloud/Cargo.toml`

```toml
[features]
default = ["whisper"]          # CHANGE: whisper is now default
http = ["dep:reqwest", "dep:base64", "dep:hound"]
whisper = ["dep:reqwest", "dep:hound"]  # NEW: whisper backend (doesn't need base64)
```

> **Note:** `whisper` feature doesn't need `base64` since whisper-server's `/inference` endpoint takes multipart form data, not base64-encoded chat messages.

---

### Phase 2: Lua Plugin — Lifecycle & Config

#### 2.1 Update: `lua/outloud/install.lua`

**Add whisper-server management alongside (or replacing) llama-server:**

```lua
-- NEW constants
local WHISPER_DEFAULT_PORT = 8000
local WHISPER_HEALTH_PATH = "/"  -- or "/health" depending on version

-- NEW: whisper-server download/install logic
-- whisper-server is a pre-built binary (no cargo build needed)
-- Download from GitHub releases: fstirl/whisper-server/releases
-- Platform-specific binaries: macOS ARM, macOS x86, Linux ARM, Linux x86

-- NEW: Whisper model download
-- Models are GGML format: ggml-base.bin, ggml-small.bin, ggml-medium.bin, ggml-large.bin
-- Download from: https://huggingface.co/ggerganov/whisper.cpp
-- Default model: ggml-medium.bin (~1.5 GB, good balance of speed/accuracy)

-- NEW function
function M.start_whisper_server(opts, on_ready)
    -- Similar structure to start_llama_server but:
    -- 1. Check for whisper-server binary (download if missing)
    -- 2. Check for model file (download if missing)
    -- 3. Spawn: whisper-server --model <path> --port <port>
    -- 4. Health probe on GET /
    -- 5. Stall detection based on stdout progress
end

function M.stop_whisper_server()
    -- Kill managed whisper-server process
end
```

**Binary download strategy for whisper-server:**
- whisper-server publishes pre-built binaries on GitHub Releases
- Detect platform (macOS ARM/x86, Linux ARM/x86)
- Download appropriate binary to `$XDG_DATA_HOME/outloud/bin/whisper-server`
- Make executable

**Model download strategy:**
- Default: `ggml-medium.bin` from HuggingFace (`ggerganov/whisper.cpp`)
- Configurable via `model.path` in user config
- Download to `$XDG_DATA_HOME/outloud/models/`

**Keep `start_llama_server()` as a fallback** when `backend = "http"`.

#### 2.2 Update: `lua/outloud/init.lua`

**Config changes:**

```lua
M.defaults = {
    backend = "whisper",  -- NEW: "whisper" (default) or "http" (OpenAI-compatible)
    model = {
        -- For whisper backend:
        path = nil,  -- optional: path to whisper model file (ggml-*.bin)
        size = "medium",  -- "tiny", "base", "small", "medium", "large" — auto-download if path not set

        -- For http backend:
        hf_repo = nil,  -- no longer needed for whisper
        server_port = 8000,  -- CHANGE: default port for whisper-server
        server_url = nil,  -- override to use external server
    },
    -- ... rest unchanged ...
}
```

**`build_daemon_env()` changes:**

```lua
local function build_daemon_env(backend, model, audio)
    local default_port = (backend == "whisper") and 8000 or 8674
    local url = model.server_url or ("http://127.0.0.1:" .. (model.server_port or default_port))
    return {
        OUTLOUD_STT_BACKEND = backend,  -- NEW
        OUTLOUD_STT_URL = url,
        -- ... rest unchanged ...
    }
end
```

**`M.start()` changes:**

```lua
function M.start()
    -- ... existing checks ...

    local backend = M.config.backend or "whisper"

    if not M.config.model.server_url then
        if backend == "whisper" then
            install.start_whisper_server({
                port = M.config.model.server_port or 8000,
                model_size = M.config.model.size or "medium",
                model_path = M.config.model.path,
                on_phase = function(phase, detail) ... end,
            }, function() M._start_pipeline() end)
        else
            install.start_llama_server({
                port = M.config.model.server_port or 8674,
                hf_repo = M.config.model.hf_repo,
                on_phase = function(phase, detail) ... end,
            }, function() M._start_pipeline() end)
        end
    else
        -- External server, skip lifecycle management
        M._start_pipeline()
    end
end
```

#### 2.3 Update: `lua/outloud/health.lua`

```lua
function M.check()
    vim.health.start("outloud")

    -- ... daemon binary check unchanged ...

    -- NEW: Check for whisper-server (default backend)
    local backend = require("outloud").config.backend or "whisper"
    if backend == "whisper" then
        if vim.fn.executable("whisper-server") == 1 then
            vim.health.ok("whisper-server found")
        else
            vim.health.warn("whisper-server not found (needed for STT)", {
                "Will be auto-downloaded on first :OutloudStart",
                "Or manually download from: github.com/fstirl/whisper-server/releases",
            })
        end
    else
        -- http backend: check for llama-server
        if vim.fn.executable("llama-server") == 1 then
            vim.health.ok("llama-server found")
        else
            vim.health.warn("llama-server not found (needed for http STT backend)", {
                "Install: brew install llama.cpp",
            })
        end
    end

    -- ... rest unchanged ...
end
```

---

### Phase 3: Documentation & Cleanup

#### 3.1 Update: `AGENTS.md`

- Update "What This Project Is" section: replace Voxtral Mini 3B / llama-server with whisper-server
- Update architecture diagram
- Update environment variables table: add `OUTLOUD_STT_BACKEND`, update defaults
- Update "Key Design Decisions" section
- Update "Things to Be Careful About" section

#### 3.2 Update: `README.md`

- Prerequisites: whisper-server instead of llama.cpp
- Installation: whisper-server binary + model download
- Configuration: new `backend` option, `model.size` for whisper
- Default port: 8000 instead of 8674

#### 3.3 Update: `SPEC.md`

- STT backend section: whisper-server as default, OpenAI-compatible as optional
- API endpoints: whisper-server `/inference` vs llama-server `/v1/audio/transcriptions`

#### 3.4 Update: `docs/roadmap.md`

- Mark "Backend migration to whisper-server" as completed in near-term
- Update "In-process STT" section: candle has Whisper implementations, relevant for in-process path

#### 3.5 Update: `CHANGELOG.md`

- Add entry for the migration

#### 3.6 Update: `plugin/outloud.vim`

- No changes needed (commands are backend-agnostic)

---

## Environment Variables Summary (After Migration)

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTLOUD_STT_BACKEND` | `whisper` | Backend: `whisper` or `http` |
| `OUTLOUD_STT_URL` | `http://127.0.0.1:8000` | Server URL (default depends on backend) |
| `OUTLOUD_VAD_THRESHOLD` | `0.01` | RMS energy threshold |
| `OUTLOUD_SILENCE_MS` | `400` | Trailing silence before finalization |
| `OUTLOUD_MAX_MS` | `30000` | Max utterance length |
| `OUTLOUD_PARTIAL_MS` | `700` | Partial transcript interval (0 = disabled) |

---

## User-Facing Config (After Migration)

```lua
require("outloud").setup({
    backend = "whisper",  -- "whisper" (default) or "http"

    model = {
        -- Whisper-specific:
        size = "medium",     -- "tiny", "base", "small", "medium", "large"
        path = nil,          -- custom model path (ggml-*.bin)

        -- Shared:
        server_port = 8000,  -- whisper-server default (8674 for http backend)
        server_url = nil,    -- external server override (skips lifecycle management)
    },

    audio = {
        -- ... unchanged ...
    },
})
```

---

## Testing Checklist

- [ ] `cargo test --workspace` passes with `whisper` feature
- [ ] `cargo test --workspace --features http` passes with `http` feature
- [ ] `cargo test --workspace --all-features` passes with both features
- [ ] Daemon starts with `OUTLOUD_STT_BACKEND=whisper` and connects to whisper-server
- [ ] Daemon starts with `OUTLOUD_STT_BACKEND=http` and connects to llama-server
- [ ] `:checkhealth outloud` shows correct checks for each backend
- [ ] `:OutloudInstall` downloads whisper-server binary + model
- [ ] Auto-start of whisper-server on `:OutloudStart` works
- [ ] External server mode (`model.server_url`) skips lifecycle management for both backends
- [ ] Transcription produces correct output via whisper-server
- [ ] Partial transcripts flow through the pipeline
- [ ] Full teardown on `VimLeavePre` kills whisper-server
- [ ] Lua integration tests pass (`nvim --headless -l tests/integration.lua`)

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| whisper-server API differs from docs | Test against actual whisper-server instance early; keep `HttpTranscriber` as fallback |
| Binary download fails on some platforms | Graceful error with manual install instructions; support `model.path` for pre-installed binaries |
| whisper-server model download is large (medium = ~1.5GB) | Same stall-detection pattern as llama-server; show download progress in sidebar |
| Sample rate mismatch (whisper expects 16kHz, cpal may differ) | Existing WAV encoding already handles sample rate; whisper-server accepts various rates |
| Breaking change for existing users | `backend = "http"` config option preserves llama-server workflow; default env var can be overridden |

---

## Files to Create

| File | Purpose |
|------|---------|
| `crates/outloud/src/transcribe/whisper.rs` | whisper-server HTTP backend implementation |

## Files to Modify

| File | Changes |
|------|---------|
| `crates/outloud/src/transcribe/mod.rs` | Add `whisper` module re-export |
| `crates/outloud/src/main.rs` | Backend selection in `build_transcriber()` |
| `crates/outloud/Cargo.toml` | New `whisper` feature, update defaults |
| `lua/outloud/install.lua` | whisper-server lifecycle management |
| `lua/outloud/init.lua` | Config defaults, backend selection, env vars |
| `lua/outloud/health.lua` | Backend-aware health checks |
| `AGENTS.md` | Update project description, architecture, env vars |
| `README.md` | Update prerequisites, config, defaults |
| `SPEC.md` | Update STT backend section |
| `docs/roadmap.md` | Mark migration as completed |
| `CHANGELOG.md` | Add migration entry |

## Files Unchanged

| File | Reason |
|------|--------|
| `crates/outloud/src/audio.rs` | Audio capture is backend-agnostic |
| `crates/outloud/src/protocol.rs` | Protocol is backend-agnostic |
| `crates/outloud/src/pipeline/*.rs` | Pipeline is backend-agnostic (uses `SpeechTranscriber` trait) |
| `lua/outloud/voice.lua` | Daemon protocol is unchanged |
| `lua/outloud/sidebar.lua` | UI is backend-agnostic |
| `lua/outloud/ui.lua` | Statusline is backend-agnostic |
| `lua/outloud/accumulator.lua` | Accumulator is backend-agnostic |
| `plugin/outloud.vim` | Commands are backend-agnostic |
| `tests/integration.lua` | Tests exercise the plugin interface, not the backend |

---

## Execution Order (Recommended)

1. **Rust daemon first** — implement `whisper.rs`, update `mod.rs`, `main.rs`, `Cargo.toml`
2. **Test daemon independently** — `just daemon-dev` with whisper-server running
3. **Lua lifecycle** — implement `install.lua` whisper-server management
4. **Lua config** — update `init.lua` defaults and env var building
5. **Health checks** — update `health.lua`
6. **Documentation** — update all docs
7. **Integration tests** — verify end-to-end flow

---

## Notes for the Next Agent

- The `SpeechTranscriber` trait is the key abstraction — any backend implementing it can be plugged in
- The existing `HttpTranscriber` in `http.rs` is a good reference implementation for the HTTP client pattern (WAV encoding, multipart form, JSON parsing)
- whisper-server's `/inference` endpoint is simpler than llama-server's (single endpoint, no chat fallback needed)
- The WAV encoding function (`encode_wav` in `http.rs`) can be shared or moved to a common utility module if both backends are compiled
- whisper-server publishes pre-built binaries, so no Rust compilation is needed for the server itself — just download and run
- Model files are GGML format (`.bin`), not GGUF — different from the current Voxtral model
- Consider whether to keep `llama-server` management code or remove it entirely (recommendation: keep behind `backend = "http"` for backward compatibility)
