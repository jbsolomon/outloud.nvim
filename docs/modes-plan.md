# Plan: Sliding Window & Accumulator Modes

## Context

The daemon **already emits partial transcripts** every ~700ms (`partial_interval_ms`) while the user is speaking. These partials flow through the pipeline, get transcribed, and arrive as `partial` events in the plugin sidebar. The transcript is inserted directly into the buffer at the cursor position.

The constraint is the **single-in-flight** policy: the `partial_gate` atomic bool blocks new partials from being emitted until the previous transcription completes. So it's streaming, but serialized.

**Problem with the current approach:** Each partial re-encodes the **entire audio buffer from t=0**. Partial #3 isn't incremental — it's everything from partials #1 and #2 plus more. This means:
- Each request gets bigger and more expensive over time
- The model re-processes audio it just transcribed
- Concurrent partials would waste compute on results that immediately get superseded

We want to add two orthogonal modes:

1. **Sliding window mode** — replace full-buffer re-encoding with a fixed-size sliding window (~5s), constant cost per partial, live buffer updates
2. **Accumulator mode** — accumulate chunks in a temp buffer, delegate to a CodeCompanion handler for analysis, update the working buffer in-place with context, user approves with `:VoiceConfirmBuf`

These modes are **orthogonal**: you can use sliding window without accumulation, accumulation without sliding window, or both together.

---

## Mode 1: Sliding Window Mode

### What It Changes

Replace the current "re-encode everything from t=0" approach with a **fixed-size sliding window** that only transcribes the most recent N seconds of audio. Each partial is roughly the same size and cost. The window slides forward as new audio arrives, providing live feedback without wasted re-processing.

### Current Behavior (Full Buffer Re-encode)

```
t=0:   [------- chunk 1 -------] → encode full buffer → "add a function"
t=0.7: [----------------- chunk 1+2 -----------------] → encode full buffer → "add a function that"
t=1.4: [------------------------- chunk 1+2+3 -------------------------] → encode full buffer → "add a function that sorts"
```

Each request is bigger than the last. The model re-processes audio it already transcribed.

### New Behavior (Sliding Window)

```
Window = 5s

t=0:   [----- 5s window -----] → "add a function that sorts the array in"
t=0.7: [----- 5s window -----] → "that sorts the array in ascending order using"
t=1.4: [----- 5s window -----] → "the array in ascending order using quicksort algorithm"

Buffer live-updates as window slides, final transcript on silence.
```

Each request is roughly the same size (~5s of audio). Constant cost. No wasted re-processing.

### Architecture Changes

#### Daemon (Rust)

**`crates/outloud/src/audio.rs`**
- Replace `partial_gate` with a **sliding window buffer**: maintain a ring buffer of audio samples
- Window size configurable via `LAZYSPEAK_WINDOW_MS` (default 5000ms)
- On partial emission, extract only the window's worth of audio (not the full buffer)
- Remove the "clone entire buffer" approach; instead slice the ring buffer

**`crates/outloud/src/protocol.rs`**
- Extend `Partial` event with window metadata:
  ```rust
  Partial {
      text: String,
      window_start_ms: u64,  // offset from utterance start
      window_end_ms: u64,    // offset from utterance start  
      seq: u64,              // monotonic sequence number for ordering
  }
  ```
- `window_start_ms` / `window_end_ms` allow the plugin to understand which portion of the utterance this partial covers
- `seq` ensures ordering when results arrive out of order

**`crates/outloud/src/pipeline/transform.rs`**
- Remove `GateGuard` — with sliding windows, each partial is independent and same-cost
- Keep single-in-flight for simplicity, but no gate blocking — if one is in-flight, drop the new partial (latest wins)
- Pass window metadata through to `Event::Partial`

**`crates/outloud/src/main.rs`**
- Read `LAZYSPEAK_WINDOW_MS` env var (default 5000)
- Pass to audio capture for window sizing

#### Plugin (Lua)

**`lua/outloud/voice.lua`**
- `on_partial` callback now receives `(text, window_start_ms, window_end_ms, seq)`
- Track the **insertion range** in the buffer: which lines/columns correspond to the current partial text
- On new partial, replace only the tracked range with the new text
- Maintain a simple ordered delivery: if `seq` is older than last displayed, discard

**`lua/outloud/init.lua`**
- New config in `audio` section:
  ```lua
  audio = {
    -- ... existing ...
    window_ms = 5000,        -- sliding window size in milliseconds
    live_buffer = true,      -- enable live buffer updates from partials
  },
  ```
- Build env var: `LAZYSPEAK_WINDOW_MS`
- On final transcript (`Utterance` event), replace the partial insertion range with the complete transcript

**`lua/outloud/sidebar.lua`**
- Already has `set_partial()` — receives partials from voice module
- No changes needed for display; the sidebar shows the latest partial text

### Live Buffer Update Strategy

The tricky part is merging sliding window partials back into the output buffer:

1. **On first partial:** Insert text at cursor, record the insertion range (start_line, start_col, end_line, end_col)
2. **On subsequent partials:** Replace the recorded range with the new partial text, update the range
3. **On final transcript:** Replace the recorded range with the complete utterance transcript
4. **On silence/utterance end:** Finalize, cursor moves to end of inserted text

This avoids stitching weirdness because each partial is self-contained (the window has enough context for coherent transcription). The final transcript (full utterance) is still the authoritative version.

### Configuration

```lua
require("outloud").setup({
  audio = {
    -- ... existing ...
    window_ms = 5000,        -- sliding window size (5 seconds)
    live_buffer = true,      -- update buffer live with partials
  },
})
```

### Daemon Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LAZYSPEAK_WINDOW_MS` | `5000` | Sliding window size in milliseconds |

---

## Mode 2: Accumulator Mode

### What It Changes

Instead of inserting the transcript directly into the buffer, accumulated text is held in a temporary buffer. A CodeCompanion handler (configurable LLM) analyzes the accumulated text in the context of the current buffer and proposes edits. The user reviews and approves with `:VoiceConfirmBuf`.

### Current Behavior

```
Transcript received → insert text at cursor position in current buffer
```

### New Behavior (Accumulator)

```
Transcript chunks accumulated → held in temp buffer →
user types :VoiceConfirmBuf → CodeCompanion handler invoked with:
  - accumulated text (the "intent")
  - current buffer contents (the "context")
  - cursor position / visual selection (optional context)
→ handler returns proposed edits → applied to buffer → user can undo
```

### Scratchpad Mode (Iterative Accumulator)

In **scratchpad mode** (`mode = "scratchpad"`), the accumulator becomes a live WIP buffer that the LLM iteratively refines. Each utterance is treated as an instruction to update the scratch pad. The LLM sees the full scratch pad state and the latest instruction, and returns the revised scratch pad.

```
speak → iterate (scratchpad + utterance → LLM) → updated scratchpad
speak → iterate (scratchpad + utterance → LLM) → updated scratchpad
speak → iterate (scratchpad + utterance → LLM) → updated scratchpad
[confirm] → insert final scratchpad at cursor
```

The user can say "add a function", then "no, delete that line", and the LLM evaluates each instruction against the evolving scratch pad.

#### Scratchpad Architecture

**`Accumulator:iterate(utterance, on_complete)`**
- Sends `(scratchpad_content, latest_utterance)` to the LLM
- The LLM response **replaces** the scratchpad content (not appends)
- Preview buffer auto-refreshes after each LLM response
- `_iterating` gate prevents concurrent LLM calls
- If an LLM call is in-flight, utterances are queued and processed sequentially

**`Accumulator:_build_scratchpad_prompt(utterance)`**
- Builds a prompt with `<scratchpad>` and `<instruction>` XML tags
- Uses configurable `scratchpad_system` template (customizable in config)
- Default template: "You are editing a scratch pad... Return only the updated scratch pad content."

**`Accumulator:_apply_scratchpad_response(response, utterance, on_complete)`**
- Extracts text from CodeCompanion response
- Trims whitespace for clean scratchpad content
- Calls `_apply_scratchpad_update` to replace accumulator text

**`Accumulator:_apply_scratchpad_update(text, on_complete)`**
- Replaces `self.text` with LLM response
- Refreshes the preview buffer
- Clears `_iterating` gate
- Processes any queued utterances sequentially

#### Scratchpad Fallback Chain

1. **CodeCompanion handler** (`handler.name`) — primary path
2. **Custom function handler** (`handler.fn`) — receives `(utterance, { scratchpad = text })`
3. **Direct append** — if no handler, falls back to dumb accumulation

#### Scratchpad Wiring in `init.lua`

- On final transcript: calls `iterate(text)` in scratchpad mode, `append(text)` in classic mode
- On partials: always `append(text)` for live preview (iteration only on authoritative transcript)
- Preview window auto-refreshes after each LLM response

### Architecture Changes

#### Plugin (Lua)

**`lua/outloud/accumulator.lua`** *(new module)*

The accumulator manages the temp buffer, accumulated text, and the CodeCompanion integration.

```lua
---@class outloud.Accumulator
---@field buf number?           -- the temp buffer holding accumulated text
---@field win number?           -- optional window for the accumulator
---@field chunks string[]       -- raw chunks in order
---@field text string           -- joined accumulated text
---@field mode string           -- "hidden" | "visible"
local Accumulator = {}
Accumulator.__index = Accumulator
```

Key methods:
- `Accumulator:new(opts)` — create, optionally open a visible buffer
- `Accumulator:append(text)` — append a chunk to the accumulation
- `Accumulator:clear()` — reset the accumulation
- `Accumulator:confirm()` — trigger CodeCompanion handler with accumulated text + context
- `Accumulator:cancel()` — discard the accumulation
- `Accumulator:dispose()` — clean up buffer/window

**`lua/outloud/init.lua`**

New config section:
```lua
accumulator = {
  enabled = false,
  -- CodeCompanion handler configuration
  handler = {
    name = "default",          -- CodeCompanion handler name
    -- Or use a custom function:
    -- fn = function(accumulated_text, buffer_context) ... end
  },
  -- Context to include when delegating to the handler
  context = {
    buffer = true,             -- include current buffer contents
    selection = true,          -- include visual selection if any
    cursor = true,             -- include cursor position
    diagnostics = false,       -- include buffer diagnostics
    filename = true,           -- include current file name/path
  },
  -- How the accumulator is displayed
  display = {
    mode = "hidden",           -- "hidden" | "preview" | "sidebar"
    -- "hidden": no visible buffer, accumulation is internal
    -- "preview": temp buffer shown in a split
    -- "sidebar": accumulated text shown in the outloud sidebar
  },
},
```

New commands:
- `:VoiceConfirmBuf` — confirm the accumulated text, invoke handler
- `:VoiceCancelBuf` — cancel and discard the accumulation
- `:VoiceClearBuf` — clear the accumulation without cancelling

**`lua/outloud/sidebar.lua`**

- New entry kind `"accumulation"` — shows the accumulated text in the sidebar
- `Sidebar:set_accumulation(text)` — update the accumulation entry
- `Sidebar:clear_accumulation()` — remove the accumulation entry

**`plugin/outloud.vim`**

- Add `:VoiceConfirmBuf` and `:VoiceCancelBuf` commands

#### CodeCompanion Integration

The accumulator delegates to CodeCompanion (or a custom handler function). The integration works like this:

```lua
-- Pseudo-code for the confirm flow
local function accumulator_confirm(accumulated_text, context)
  -- Build the prompt for the handler
  local prompt = string.format(
    [[
Transform the following voice input into edits for the current buffer.

Voice input:
%s

Buffer context:
Filename: %s
Cursor: line %d, col %d
%s
%s

Return the transformed text that should replace the current content at the cursor.
    ]],
    accumulated_text,
    context.filename,
    context.cursor.line,
    context.cursor.col,
    context.selection and ("Selection:\n" .. context.selection) or "",
    context.buffer_lines  -- relevant lines around cursor
  )

  -- Invoke CodeCompanion handler
  local ok, cc = pcall(require, "CodeCompanion")
  if ok then
    cc.chat({
      handler = config.handler.name,
      prompt = prompt,
      on_complete = function(response)
        -- Apply response to buffer
        apply_to_buffer(response, context)
      end,
    })
  else
    -- Fallback: use custom function handler
    if config.handler.fn then
      config.handler.fn(accumulated_text, context)
    else
      -- Last resort: direct insertion
      insert_at_cursor(accumulated_text)
    end
  end
end
```

### Context Gathering

When `:VoiceConfirmBuf` is called, gather context from the current buffer:

```lua
local function gather_context(opts)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local context = {}

  if opts.filename then
    context.filename = vim.api.nvim_buf_get_name(buf)
  end

  if opts.cursor then
    context.cursor = { line = cursor[1], col = cursor[2] }
  end

  if opts.selection and vim.fn.mode() == "v" then
    -- Get visual selection
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    context.selection = vim.api.nvim_buf_get_text(
      buf,
      start_pos[2] - 1, start_pos[3] - 1,
      end_pos[2] - 1, end_pos[3],
      {}
    )
  end

  if opts.buffer then
    -- Get relevant lines (window or buffer)
    local win = vim.api.nvim_get_current_win()
    local config = vim.api.nvim_win_get_config(win)
    local top = vim.api.nvim_win_call(win, vim.fn.winsaveview).topline
    local height = vim.api.nvim_win_get_height(win)
    context.buffer_lines = vim.api.nvim_buf_get_lines(
      buf, top - 1, top + height, false
    )
  end

  if opts.diagnostics then
    context.diagnostics = vim.diagnostic.get(buf)
  end

  return context
end
```

### Configuration

```lua
require("outloud").setup({
  accumulator = {
    enabled = true,
    handler = {
      name = "default",  -- CodeCompanion handler
      -- Or custom:
      -- fn = function(text, context)
      --   -- Your custom logic here
      --   -- text: accumulated voice input
      --   -- context: { filename, cursor, selection, buffer_lines, diagnostics }
      -- end
    },
    context = {
      buffer = true,
      selection = true,
      cursor = true,
      diagnostics = false,
      filename = true,
    },
    display = {
      mode = "sidebar",  -- show accumulation in sidebar
    },
  },
})
```

---

## Orthogonality

The two modes are independent:

| Sliding Window | Accumulator | Behavior |
|----------------|-------------|----------|
| ❌ | ❌ | Current behavior: single-shot transcript, direct insertion |
| ✅ | ❌ | Sliding window: live partial feedback via windowed STT, final transcript inserted |
| ❌ | ✅ (classic) | Accumulator mode: single-shot transcript, accumulated, LLM-processed on confirm |
| ❌ | ✅ (scratchpad) | Scratchpad mode: each utterance iteratively refines the scratch pad via LLM |
| ✅ | ✅ (scratchpad) | Sliding window chunks feed scratchpad, LLM refines iteratively (best UX) |

When both are enabled, sliding window chunks feed into the scratchpad buffer, giving the user a live preview of what they've said while the LLM iteratively refines it.

---

## Implementation Order

### Phase 1: Sliding Window Mode (Daemon + Plugin)

1. **Daemon**: Replace full-buffer clone with ring buffer in `audio.rs`
2. **Daemon**: Add `window_start_ms`, `window_end_ms`, `seq` to `Partial` event in `protocol.rs`
3. **Daemon**: Remove `GateGuard`, implement latest-wins drop policy in `transform.rs`
4. **Daemon**: Read `LAZYSPEAK_WINDOW_MS` env var in `main.rs`
5. **Plugin**: Track insertion range in `voice.lua`, replace on each partial
6. **Plugin**: Final transcript replaces partial range in `init.lua`
7. **Tests**: Integration tests for sliding window partials + buffer merging

### Phase 2: Accumulator Mode (Plugin Only) ✅ DONE

1. **New module**: `lua/outloud/accumulator.lua` — accumulator module with classic + scratchpad modes
2. **Config**: Add accumulator config section to `init.lua`
3. **Commands**: `:VoiceConfirmBuf`, `:VoiceCancelBuf`, `:VoiceClearBuf`
4. **CodeCompanion integration**: Handler invocation with context
5. **Sidebar**: Accumulation entry display
6. **Tests**: Integration tests for accumulator flow (sections 14, 14b, 15)
7. **Scratchpad mode**: Iterative LLM refinement with `_iterating` gate and queuing (section 16)

### Phase 3: Polish

1. **Sidebar**: Unified display showing both sliding window chunks and accumulation
2. **Status**: Update statusline/sidebar header for accumulator state
3. **Docs**: Update `SPEC.md` with new modes
4. **Tests**: Full E2E tests for all mode combinations

---

## Risk & Mitigation

| Risk | Mitigation |
|------|-------------|
| Window too small, partials lack context | Configurable window size, default 5s provides ample context |
| Window too large, latency increases | User-tunable via `window_ms` config |
| Buffer merge range gets corrupted by user edits | Detect range invalidation, fall back to cursor insertion |
| CodeCompanion not installed | Graceful fallback to direct insertion |
| Sliding window partials out of order | `seq` field ensures ordering, discard stale results |
| Accumulator buffer state confusion | Clear visual indication in sidebar, `:VoiceStatus` command |

---

## File Changes Summary

### New Files
- `lua/outloud/accumulator.lua` — accumulator module (classic + scratchpad modes)

### Modified Files
- `lua/outloud/init.lua` — config, wiring, commands, scratchpad iteration on transcript
- `lua/outloud/voice.lua` — partial callbacks with insertion range tracking
- `plugin/outloud.vim` — new commands (`:VoiceConfirmBuf`, `:VoiceCancelBuf`, `:VoiceClearBuf`)
- `tests/integration.lua` — tests for accumulator (sections 14, 14b, 15) + scratchpad (section 16)
- `tests/verify.lua` — accumulator smoke tests + API checks

### Pending (Sliding Window)
- `crates/outloud/src/audio.rs` — sliding window ring buffer, remove full-buffer clone
- `crates/outloud/src/protocol.rs` — window metadata on `Partial` event
- `crates/outloud/src/pipeline/transform.rs` — remove `GateGuard`, latest-wins policy
- `crates/outloud/src/main.rs` — `LAZYSPEAK_WINDOW_MS` config
- `lua/outloud/sidebar.lua` — accumulation entry display
- `lua/outloud/health.lua` — check CodeCompanion availability
- `SPEC.md` — documentation update

