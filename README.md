<p align="center">
  <h1 align="center">outloud.nvim</h1>
  <p align="center">
    Voice-to-text for Neovim. Speak, and your words appear at the cursor.
    <br /><br />
    <a href="#installation">Install</a>
    &middot;
    <a href="#usage">Usage</a>
    &middot;
    <a href="#configuration">Configuration</a>
    &middot;
    <a href="https://github.com/jbsolomon/outloud.nvim/issues">Report Bug</a>
  </p>
</p>

<p align="center">
  <a href="https://github.com/jbsolomon/outloud.nvim/actions/workflows/ci.yml"><img src="https://github.com/jbsolomon/outloud.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  &nbsp;
  <a href="LICENSE"><img src="https://img.shields.io/github/license/jbsolomon/outloud.nvim" alt="License"></a>
</p>

<p align="center">
  <img src="showcase/outloud-demo.gif" alt="outloud.nvim demo" width="80%">
</p>

```
Mic → whisper-server (local STT) → transcript → inserted at cursor
          GGML model, Apache 2.0
```

No cloud STT. No TTS. Local-only. You speak, text appears.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Neovim >= 0.10 | Editor | [neovim.io](https://neovim.io) |
| Rust toolchain | Build daemon binary | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |

`whisper-server` and the Whisper model are auto-downloaded on first run. No manual install needed.

Optional: [just](https://github.com/casey/just) for convenient dev commands.

## Installation

### With [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)

```lua
{
  "jbsolomon/outloud.nvim",
  build = ":OutloudInstall",
  opts = {},
}
```

`:OutloudInstall` will build and install the `outloud` daemon binary via `cargo install`.

When you run `:OutloudStart`, the plugin automatically downloads `whisper-server` and the Whisper GGML model (~1.5 GB for `medium`) on first run, then starts the server. It shuts down with `:OutloudStop`.

#### External STT server (advanced)

To use your own STT server instead of the auto-managed whisper-server:

```lua
require("outloud").setup({
  model = {
    server_url = "http://127.0.0.1:8000",
  },
})
```

The server must expose a whisper-server-compatible `/inference` endpoint.

### Manual installation

```sh
# 1. Clone the plugin
git clone https://github.com/jbsolomon/outloud.nvim ~/.local/share/nvim/lazy/outloud.nvim

# 2. Build and install the daemon binary
cd ~/.local/share/nvim/lazy/outloud.nvim
cargo install --path crates/outloud
```

### Verify installation

Open Neovim and run:

```vim
:checkhealth outloud
```

## First Run

From a fresh install to your first transcript.

**1. Confirm the pieces are in place.**

```vim
:checkhealth outloud
```

This checks the `outloud` daemon binary, the STT server, and your plugin config.
If the daemon line warns, run `:OutloudInstall` to build it (`cargo install --path
crates/outloud`, roughly a minute).

**2. Open a file** you want to transcribe into.

**3. Start a session** with `<leader>ls`.

The sidebar opens on the right. Its header carries two process signals (STT
server and daemon), the current phase, and contextual hints:

```
 ● stt  ● daemon
 press <Space> to record
 <Space> record   <Esc> close   ? help
────────────────────────────────
```

`○` down, `◐` starting, `●` up, `✗` failed.

On the very first run two slow things happen here, both one-time:

- `whisper-server` downloads the Whisper GGML model (default: `medium`, ~1.5 GB).
  The header tracks it as `downloading model NN%`, then `loading model...`.
  This can take a while on a slow link; the editor stays responsive throughout.
- Your OS may prompt for **microphone access** for your terminal application.
  Grant it. If you dismiss the prompt, recording silently produces nothing.

Wait for the header to read `press <Space> to record`.

**4. Speak.** Press `<Space>` to start recording, say what you want, press
`<Space>` again to stop. The final transcript is inserted at your cursor position.

Your interim transcript appears in the sidebar while you talk, and is replaced
by the final text when you stop.

**5. Finish up.** `<Esc>` dismisses the UI but leaves the daemon warm, so the
next `<leader>ls` is instant. `:OutloudStop` shuts everything down and frees
the model's memory. Quitting Neovim tears it all down either way.

### Tuning after a few turns

| Symptom | Knob |
|---------|------|
| It cuts you off mid-sentence | raise `audio.silence_duration_ms` (default 400) |
| It waits too long before sending | lower `audio.silence_duration_ms` |
| It triggers on background noise | raise `audio.vad_threshold` (default 0.01) |
| The sidebar is in the way | `ui.sidebar_auto_open = false`, open it with `<leader>ll` |
| The sidebar is too narrow or wide | `ui.sidebar_width` (default 48) |
| You want it on the left | `ui.sidebar_position = "left"` |

## Resource Requirements

The Whisper model runs entirely on your machine via `whisper-server`. Budget roughly:

| | |
|---|---|
| Disk | ~1.5 GB for the `medium` GGML model (smaller with `tiny`/`base`/`small`), downloaded once |
| Memory, resident | ~1-2 GB for `medium` once loaded |
| Practical floor | 8 GB RAM; Apple Silicon uses Metal automatically via whisper.cpp |

Smaller models (`tiny`, `base`, `small`) use less memory and load faster but
produce less accurate transcripts. Configure with `model.size`:

```lua
require("outloud").setup({
  model = {
    size = "small",  -- "tiny", "base", "small", "medium", "large"
  },
})
```

## Usage

### Keybindings

| Key | Mode | Action |
|-----|------|--------|
| `<leader>ls` | n | Open the session (starts the daemon if needed) |
| `<Space>` | n | Start/stop recording while the session is open |
| `<Esc>` | n | Cancel recording and dismiss the UI |
| `<leader>lc` | n | Cancel current recording |
| `<leader>ll` | n | Toggle the session sidebar |

### Commands

| Command | Description |
|---------|-------------|
| `:OutloudStart` | Start daemon + STT server |
| `:OutloudStop` | Stop everything and tear down the UI |
| `:OutloudStatus` | Show daemon/STT status |
| `:OutloudSidebar` | Toggle the session sidebar |
| `:OutloudHelp` | Toggle the key reference in the sidebar |
| `:OutloudDismiss` | Hide the sidebar, leave the daemon running |
| `:OutloudInstall` | Build daemon binary |
| `:VoiceConfirmBuf` | Confirm accumulated text (accumulator mode) |
| `:VoiceCancelBuf` | Cancel and discard accumulated text |
| `:VoiceClearBuf` | Clear accumulation without cancelling |

### The sidebar

One surface, on the right, full height. A fixed four-row header carries two
process signals (STT server and daemon), the current phase, and contextual hints;
below it the session reads as a conversation.

Hints follow state, so they only ever show keys that do something right now:

| State | Hints |
|-------|-------|
| idle | `<leader>ls` talk |
| ready | `<Space> record`, `<Esc> close` |
| listening | `<Space> send`, `<Esc> cancel` |

They reflect what you actually bound, not the defaults. Two keys are local to the
sidebar window: `?` toggles the full reference, `q` closes it.

Colours link to standard groups (`DiagnosticOk`/`Warn`/`Error`, `Comment`,
`Title`, `Function`), so the sidebar follows your colorscheme. Override any of
the `Outloud*` groups to change it.

Every transcript is framed as its own block with a timestamp, so you can see
what was said and when.

Text is hard-wrapped to the window width rather than soft-wrapped, so borders
and gutters stay aligned. Resizing the window re-flows the whole conversation.

The sidebar persists across turns and has real scrollback. Following the tail
pauses automatically when you scroll back, so reading mid-stream does not yank
you to the bottom.

| Action | Sidebar window | Conversation | Daemon |
|--------|---------------|--------------|--------|
| `<Esc>` / `:OutloudDismiss` | closed | kept | running |
| `:OutloudStop` | closed | deleted | stopped |
| Exit Neovim | closed | deleted | stopped |

Everything shuts down on exit, so quitting Neovim never leaves the daemon or
`whisper-server` running.

### Status line

Add to your status line (lualine, etc.):

```lua
require("outloud").status()
-- Returns: "" (inactive/idle), "ls:mic" (listening), "ls:..." (transcribing)
```

## Configuration

Full configuration with defaults:

```lua
require("outloud").setup({
  backend = "whisper",  -- "whisper" (default) or "openai" (OpenAI-compatible)

  model = {
    size = "medium",           -- whisper model size: "tiny", "base", "small", "medium", "large"
    repo = "ggerganov/whisper.cpp",  -- HuggingFace repo for model download
    -- filename = "ggml-medium.bin",  -- override model filename (e.g. "ggml-tiny-q5_1.bin")
    -- download_url = "...",          -- direct download URL (bypasses HuggingFace)
    -- path = "/path/to/model.bin",  -- explicit local model path
    server_port = 8000,        -- whisper-server port (default 8000, 8674 for openai)
    -- server_url = "http://127.0.0.1:8000",  -- use external server
  },

  audio = {
    sample_rate = 16000,
    channels = 1,
    vad_threshold = 0.01,        -- RMS energy threshold for speech
    silence_duration_ms = 400,   -- trailing silence before finalizing (latency knob)
    max_duration_ms = 30000,
    partial_interval_ms = 700,   -- interim transcript cadence while speaking (0 disables)
    window_ms = 5000,            -- sliding window size for partials
    live_buffer = true,          -- insert partials directly at cursor
  },

  accumulator = {
    enabled = false,             -- collect transcripts in a buffer before inserting
    mode = "hidden",             -- "hidden" | "preview" | "scratchpad"
    handler = nil,               -- { name = "default" } for CodeCompanion, or { fn = function(text, context) ... end }
    context = {
      buffer = true,
      selection = true,
      cursor = true,
      diagnostics = false,
      filename = true,
    },
  },

  ui = {
    sidebar_position = "right",   -- "right" | "left"
    sidebar_width = 48,
    sidebar_auto_open = true,     -- open the sidebar when a session starts
    statusline = true,
  },

  keys = {
    push_to_talk = "<leader>ls",
    cancel = "<leader>lc",
    sidebar = "<leader>ll",
  },
})
```

### Accumulator mode

By default, transcripts are inserted directly at the cursor. With accumulator
mode enabled, transcripts are collected in a temporary buffer instead. This
lets you build up a longer passage of text before inserting it.

```lua
require("outloud").setup({
  accumulator = {
    enabled = true,
    mode = "preview",  -- show accumulated text in a preview window
  },
})
```

Once you're happy with the accumulated text, confirm with `:VoiceConfirmBuf` to
insert it at the cursor, or cancel with `:VoiceCancelBuf` to discard.

### OpenAI-compatible backend

To use an OpenAI-compatible STT server (e.g. `llama-server` with Voxtral):

```lua
require("outloud").setup({
  backend = "openai",
  model = {
    server_port = 8674,
    hf_repo = "ggml-org/Voxtral-Mini-3B-2507-GGUF",
  },
})
```

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

The daemon uses the `streamsafe` crate for an async pipeline:

```
AudioSource (cpal → mpsc → async)
  → VadFilter (VAD events → side-channel, utterances → downstream)
  → TranscribeTransform (audio → STT HTTP → text)
  → EventSink (events → stdout JSON lines)
```

The daemon uses a `SpeechTranscriber` trait to abstract over STT backends
(`whisper` default, `openai` optional).

## Development

```sh
just build          # Build daemon (release)
just test           # Run tests
just lint           # Clippy + format check
just fmt            # Format code
just daemon-dev     # Run daemon in dev mode
just nvim-dev       # Launch Neovim with plugin loaded
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTLOUD_STT_BACKEND` | `whisper` | Backend: `whisper` (default) or `openai` (OpenAI-compatible) |
| `OUTLOUD_STT_URL` | `http://127.0.0.1:8000` | Server URL (8000 for whisper, 8674 for openai) |
| `OUTLOUD_VAD_THRESHOLD` | `0.01` | RMS energy threshold for speech detection |
| `OUTLOUD_SILENCE_MS` | `400` | Trailing silence before an utterance is finalized |
| `OUTLOUD_MAX_MS` | `30000` | Max utterance length before forced finalization |
| `OUTLOUD_PARTIAL_MS` | `700` | Interim transcript cadence while speaking (0 disables) |
| `OUTLOUD_WINDOW_MS` | `5000` | Sliding window size for partial transcriptions |

These are set automatically from your `audio` config; override them directly only when running the daemon standalone.

## License

[Apache 2.0](LICENSE)
