#!/usr/bin/env -S nvim --headless -l

-- End-to-end integration test for lazyspeak.nvim
-- Simulates the full pipeline: setup -> start -> simulated daemon -> transcript -> buffer insertion
-- Run: nvim --headless -l tests/integration.lua

-- Add project lua/ directory to package.path
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:match("^@(.*)"), ":h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Test harness
local passed = 0
local failed = 0
local errors = {}

local function assert_ok(ok, msg, err)
  if ok then
    passed = passed + 1
    print(string.format("  ✓ %s", msg))
  else
    failed = failed + 1
    table.insert(errors, { msg, err })
    print(string.format("  ✗ %s: %s", msg, tostring(err or "unknown")))
  end
end

local function assert_eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
    print(string.format("  ✓ %s", msg))
  else
    failed = failed + 1
    local err = string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual))
    table.insert(errors, { msg, err })
    print(string.format("  ✗ %s: %s", msg, err))
  end
end

local function assert_type(value, expected_type, msg)
  if type(value) == expected_type then
    passed = passed + 1
    print(string.format("  ✓ %s", msg))
  else
    failed = failed + 1
    local err = string.format("expected type %s, got %s", expected_type, type(value))
    table.insert(errors, { msg, err })
    print(string.format("  ✗ %s: %s", msg, err))
  end
end

local function section(name)
  print(string.format("\n=== %s ===", name))
end

print("lazyspeak.nvim integration test")
print(string.rep("=", 45))

-- ============================================================================
-- Test 1: Module Loading
-- ============================================================================
section("1. Module Loading")

local modules = {
  "lazyspeak",
  "lazyspeak.voice",
  "lazyspeak.sidebar",
  "lazyspeak.ui",
  "lazyspeak.install",
  "lazyspeak.health",
}

for _, mod_path in ipairs(modules) do
  local ok, mod = pcall(require, mod_path)
  assert_ok(ok, string.format("require('%s')", mod_path), mod)
end

-- ============================================================================
-- Test 2: Config Setup & Defaults
-- ============================================================================
section("2. Config Setup & Defaults")

local ls = require("lazyspeak")

-- Test defaults structure
assert_type(ls.defaults, "table", "defaults is a table")
assert_type(ls.defaults.model, "table", "defaults.model exists")
assert_type(ls.defaults.audio, "table", "defaults.audio exists")
assert_type(ls.defaults.ui, "table", "defaults.ui exists")
assert_type(ls.defaults.keys, "table", "defaults.keys exists")

-- Test specific default values
assert_eq(ls.defaults.audio.sample_rate, 16000, "default sample_rate is 16000")
assert_eq(ls.defaults.audio.channels, 1, "default channels is 1")
assert_eq(ls.defaults.audio.silence_duration_ms, 400, "default silence_duration_ms is 400")
assert_eq(ls.defaults.audio.max_duration_ms, 30000, "default max_duration_ms is 30000")
assert_eq(ls.defaults.audio.partial_interval_ms, 700, "default partial_interval_ms is 700")
assert_eq(ls.defaults.audio.window_ms, 5000, "default window_ms is 5000")
assert_eq(ls.defaults.audio.live_buffer, true, "default live_buffer is true")
assert_eq(ls.defaults.ui.sidebar_position, "right", "default sidebar_position is 'right'")
assert_eq(ls.defaults.ui.sidebar_width, 48, "default sidebar_width is 48")
assert_eq(ls.defaults.keys.push_to_talk, "<leader>ls", "default push_to_talk key")

-- Test setup() merges defaults with user config
ls.setup({
  audio = {
    silence_duration_ms = 600,
  },
  ui = {
    sidebar_width = 60,
  },
})

assert_eq(ls.config.audio.silence_duration_ms, 600, "custom silence_duration_ms merged")
assert_eq(ls.config.audio.sample_rate, 16000, "default sample_rate preserved after merge")
assert_eq(ls.config.ui.sidebar_width, 60, "custom sidebar_width merged")
assert_eq(ls.config.ui.sidebar_position, "right", "default sidebar_position preserved")

-- ============================================================================
-- Test 3: Voice Class - Construction & API
-- ============================================================================
section("3. Voice Class - Construction & API")

local Voice = require("lazyspeak.voice").Voice

-- Test construction
local voice = Voice:new({
  daemon_cmd = "echo",
  env = { TEST_VAR = "test" },
})
assert_type(voice, "table", "Voice instance is a table")
assert_eq(voice.daemon_cmd, "echo", "custom daemon_cmd set")
assert_eq(voice.env.TEST_VAR, "test", "custom env vars set")
assert_eq(voice:is_running(), false, "new Voice is not running")

-- Test default daemon_cmd
local voice_default = Voice:new({})
assert_eq(voice_default.daemon_cmd, "lazyspeak", "default daemon_cmd is 'lazyspeak'")

-- Test callback registration
local transcript_called = false
local partial_called = false
local status_called = false
local error_called = false

voice:on_transcript(function(text, duration_ms)
  transcript_called = true
end)
voice:on_partial(function(text)
  partial_called = true
end)
voice:on_status(function(state)
  status_called = true
end)
voice:on_error(function(message)
  error_called = true
end)

assert_type(voice.callbacks.transcript, "function", "transcript callback registered")
assert_type(voice.callbacks.partial, "function", "partial callback registered")
assert_type(voice.callbacks.status, "function", "status callback registered")
assert_type(voice.callbacks.error, "function", "error callback registered")

-- ============================================================================
-- Test 4: Voice Class - Simulated Daemon Communication
-- ============================================================================
section("4. Voice Class - Simulated Daemon Events")

-- Simulate the daemon sending events via _handle_line
local test_voice = Voice:new({})

local events = {}

test_voice:on_transcript(function(text, duration_ms)
  table.insert(events, { type = "transcript", text = text, duration_ms = duration_ms })
end)
test_voice:on_partial(function(text)
  table.insert(events, { type = "partial", text = text })
end)
test_voice:on_status(function(state)
  table.insert(events, { type = "status", state = state })
end)
test_voice:on_vad(function(speaking)
  table.insert(events, { type = "vad", speaking = speaking })
end)
test_voice:on_error(function(message)
  table.insert(events, { type = "error", message = message })
end)

-- Simulate a status event (listening)
test_voice:_handle_line(vim.json.encode({ type = "status", state = "listening" }))
assert_eq(#events, 1, "one event after status")
assert_eq(events[1].type, "status", "first event is status")
assert_eq(events[1].state, "listening", "status is 'listening'")

-- Simulate a VAD event (user started speaking)
test_voice:_handle_line(vim.json.encode({ type = "vad", speaking = true }))
assert_eq(#events, 2, "two events after vad")
assert_eq(events[2].speaking, true, "vad speaking is true")

-- Simulate partial transcripts (streaming)
  test_voice:_handle_line(vim.json.encode({ type = "partial", text = "hello", window_start_ms = 0, window_end_ms = 5000, seq = 1 }))
  test_voice:_handle_line(vim.json.encode({ type = "partial", text = "hello world", window_start_ms = 0, window_end_ms = 6000, seq = 2 }))
assert_eq(#events, 4, "four events after partials")
assert_eq(events[3].text, "hello", "first partial is 'hello'")
assert_eq(events[4].text, "hello world", "second partial is 'hello world'")

-- Simulate final transcript
test_voice:_handle_line(vim.json.encode({
  type = "transcript",
  text = "hello world this is a test",
  duration_ms = 1500,
}))
assert_eq(#events, 5, "five events after transcript")
assert_eq(events[5].text, "hello world this is a test", "transcript text correct")
assert_eq(events[5].duration_ms, 1500, "transcript duration correct")

-- Simulate an error event
test_voice:_handle_line(vim.json.encode({ type = "error", message = "audio device not found" }))
assert_eq(#events, 6, "six events after error")
assert_eq(events[6].message, "audio device not found", "error message correct")

-- Simulate transcribing status
test_voice:_handle_line(vim.json.encode({ type = "status", state = "transcribing" }))
assert_eq(#events, 7, "seven events after transcribing status")

-- Test that invalid JSON is silently ignored
test_voice:_handle_line("not valid json {")
assert_eq(#events, 7, "invalid JSON ignored, still seven events")

-- Test that empty lines are ignored
test_voice:_handle_line("")
assert_eq(#events, 7, "empty line ignored, still seven events")

-- ============================================================================
-- Test 5: Sidebar - Construction & State Management
-- ============================================================================
section("5. Sidebar - Construction & State")

local Sidebar = require("lazyspeak.sidebar").Sidebar

local sidebar = Sidebar:new({
  width = 48,
  position = "right",
  keys = {
    push_to_talk = "<leader>ls",
    cancel = "<leader>lc",
    sidebar = "<leader>ll",
  },
})

assert_type(sidebar, "table", "Sidebar instance is a table")
assert_eq(sidebar.state, "inactive", "initial state is 'inactive'")
assert_eq(sidebar.status.stt, "down", "initial stt status is 'down'")
assert_eq(sidebar.status.daemon, "down", "initial daemon status is 'down'")
assert_eq(#sidebar.entries, 0, "initial entries is empty")

-- Test state transitions
sidebar:set_state("ready")
assert_eq(sidebar.state, "ready", "state changed to 'ready'")

sidebar:set_state("listening")
assert_eq(sidebar.state, "listening", "state changed to 'listening'")

sidebar:set_state("transcribing")
assert_eq(sidebar.state, "transcribing", "state changed to 'transcribing'")

sidebar:set_state("idle")
assert_eq(sidebar.state, "idle", "state changed to 'idle'")

-- Test status updates
sidebar:set_status("stt", "up")
assert_eq(sidebar.status.stt, "up", "stt status changed to 'up'")

sidebar:set_status("daemon", "up")
assert_eq(sidebar.status.daemon, "up", "daemon status changed to 'up'")

-- ============================================================================
-- Test 6: Sidebar - Conversation Entries
-- ============================================================================
section("6. Sidebar - Conversation Flow")

local conv = Sidebar:new({ width = 48, position = "right", keys = {} })

-- Simulate a partial transcript appearing
conv:set_partial("hello world")
assert_ok(#conv.entries >= 1, "partial entry added")

-- Update the partial
conv:set_partial("hello world this is")
assert_ok(#conv.entries >= 1, "partial entry updated")

-- Clear partial and begin a real turn
conv:begin_turn("hello world this is a test")
assert_ok(#conv.entries >= 1, "turn entry added after partial cleared")

-- Check that the last entry is a turn
local last = conv.entries[#conv.entries]
assert_eq(last.kind, "turn", "last entry is a turn")
assert_eq(last.text, "hello world this is a test", "turn text is correct")
assert_type(last.time, "string", "turn has a time stamp")

-- Simulate an error
conv:add_error("simulated error message")
last = conv.entries[#conv.entries]
assert_eq(last.kind, "error", "error entry added")

-- Simulate end of turn
conv:end_turn()
assert_ok(true, "end_turn completes without error")

-- Simulate cancelled turn
conv:end_turn("cancelled")
last = conv.entries[#conv.entries]
assert_eq(last.kind, "note", "cancelled note added")

-- ============================================================================
-- Test 7: UI Statusline
-- ============================================================================
section("7. UI Statusline")

local ui = require("lazyspeak.ui")

ui.set_state("")
assert_eq(ui.statusline(), "", "empty state returns empty string")

ui.set_state("inactive")
assert_eq(ui.statusline(), "", "inactive returns empty string")

ui.set_state("idle")
assert_eq(ui.statusline(), "", "idle returns empty string")

ui.set_state("listening")
assert_eq(ui.statusline(), "ls:mic", "listening returns 'ls:mic'")

ui.set_state("transcribing")
assert_eq(ui.statusline(), "ls:...", "transcribing returns 'ls:...'")

-- Reset
ui.set_state("inactive")

-- ============================================================================
-- Test 8: Install Module - API Surface
-- ============================================================================
section("8. Install Module")

local install = require("lazyspeak.install")

assert_type(install.HF_REPO, "string", "HF_REPO is a string")
assert_type(install.DEFAULT_PORT, "number", "DEFAULT_PORT is a number")
assert_type(install.run, "function", "install.run is a function")
assert_type(install.start_llama_server, "function", "start_llama_server is a function")
assert_type(install.stop_llama_server, "function", "stop_llama_server is a function")
assert_type(install.probe_server, "function", "probe_server is a function")

assert_eq(install.DEFAULT_PORT, 8674, "DEFAULT_PORT is 8674")
assert_ok(install.HF_REPO:match("Voxtral"), "HF_REPO contains 'Voxtral'")

-- ============================================================================
-- Test 9: Health Check
-- ============================================================================
section("9. Health Check")

local health_ok, health_err = pcall(function()
  require("lazyspeak.health").check()
end)
assert_ok(health_ok, "health.check() runs without error", health_err)

-- ============================================================================
-- Test 10: End-to-End Simulated Pipeline
-- ============================================================================
section("10. E2E Simulated Pipeline")

-- Simulate the full user flow:
-- 1. User presses push_to_talk
-- 2. Plugin starts the pipeline
-- 3. Daemon emits status events
-- 4. User speaks, VAD detects speech
-- 5. Partial transcripts stream in
-- 6. Final transcript arrives
-- 7. Transcript is inserted into buffer
-- 8. User dismisses sidebar

-- Create a test buffer
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)

-- Create a simulated voice instance
local sim_voice = Voice:new({ daemon_cmd = "echo" })

local transcript_results = {}
local partial_results = {}
local status_results = {}

sim_voice:on_transcript(function(text, duration_ms)
  table.insert(transcript_results, { text = text, duration_ms = duration_ms })
end)
sim_voice:on_partial(function(text)
  table.insert(partial_results, text)
end)
sim_voice:on_status(function(state)
  table.insert(status_results, state)
end)

-- Simulate the full event sequence a real daemon would produce
local sim_events = {
  -- Daemon starts
  { type = "status", state = "ready" },
  
  -- User starts listening
  { type = "status", state = "listening" },
  
  -- VAD: user starts speaking
  { type = "vad", speaking = true },
  
  -- Partial transcripts stream in as user speaks
  { type = "partial", text = "add a function", window_start_ms = 0, window_end_ms = 3000, seq = 1 },
  { type = "partial", text = "add a function that sorts", window_start_ms = 0, window_end_ms = 5000, seq = 2 },
  { type = "partial", text = "add a function that sorts the array", window_start_ms = 0, window_end_ms = 7000, seq = 3 },
  
  -- VAD: user stops speaking
  { type = "vad", speaking = false },
  
  -- Transcribing
  { type = "status", state = "transcribing" },
  
  -- Final transcript
  { type = "transcript", text = "add a function that sorts the array", duration_ms = 2300 },
  
  -- Back to idle
  { type = "status", state = "ready" },
}

-- Process all simulated events
for _, event in ipairs(sim_events) do
  sim_voice:_handle_line(vim.json.encode(event))
end

-- Verify the results
assert_eq(#status_results, 4, "received 4 status events")
assert_eq(status_results[1], "ready", "first status is 'ready'")
assert_eq(status_results[2], "listening", "second status is 'listening'")
assert_eq(status_results[3], "transcribing", "third status is 'transcribing'")
assert_eq(status_results[4], "ready", "fourth status is 'ready'")

assert_eq(#partial_results, 3, "received 3 partial transcripts")
assert_eq(partial_results[1], "add a function", "first partial")
assert_eq(partial_results[2], "add a function that sorts", "second partial")
assert_eq(partial_results[3], "add a function that sorts the array", "third partial")

assert_eq(#transcript_results, 1, "received 1 final transcript")
assert_eq(transcript_results[1].text, "add a function that sorts the array", "final transcript text")
assert_eq(transcript_results[1].duration_ms, 2300, "final transcript duration")

-- Test buffer insertion (simulating what init.lua does)
local test_text = transcript_results[1].text
vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })  -- Start with empty buffer
local line, col = 0, 0
vim.api.nvim_buf_set_text(buf, line, col, line, col, { test_text })

local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert_eq(buf_lines[1], test_text, "transcript inserted into buffer")

-- Cleanup test buffer
vim.api.nvim_buf_delete(buf, { force = true })

-- ============================================================================
-- Test 11: Sidebar Window Operations (headless-safe)
-- ============================================================================
section("11. Sidebar Window Operations")

local sb = Sidebar:new({ width = 48, position = "right", keys = {} })

-- Test that sidebar can be created without opening (lazy buffer creation)
assert_eq(sb:is_open(), false, "sidebar not open initially")

-- Test dispose cleans up
sb:dispose()
assert_eq(sb.win, nil, "window is nil after dispose")
assert_eq(sb.buf, nil, "buffer is nil after dispose")

-- ============================================================================
-- Test 12: Voice Command Simulation (no agent)
-- ============================================================================
section("12. Voice Command Patterns")

-- Verify the simplified plugin doesn't have agent-related config
assert_eq(ls.config.agent, nil, "config.agent is nil (no ACP)")
assert_eq(ls.defaults.agent, nil, "defaults.agent is nil (no ACP)")

-- Verify deleted modules don't load
local deleted_modules = {
  "lazyspeak.core",
  "lazyspeak.snapshot",
  "lazyspeak.adapters.acp",
  "lazyspeak.adapters.claudecode",
}

for _, mod_path in ipairs(deleted_modules) do
  -- Clear from cache if previously loaded
  package.loaded[mod_path:gsub("%.", "/")] = nil
  local ok, _ = pcall(require, mod_path)
  assert_ok(not ok, string.format("require('%s') should fail", mod_path))
end

-- ============================================================================
-- Test 13: Daemon Environment Building
-- ============================================================================
section("13. Daemon Environment")

-- Test that the internal build_daemon_env function works correctly
-- We can't access it directly, but we can verify the config values
-- that would be used to build the env

assert_eq(ls.config.model.server_port, 8674, "server_port for env")
assert_eq(ls.config.audio.vad_threshold, 0.01, "vad_threshold for env")
assert_eq(ls.config.audio.silence_duration_ms, 600, "silence_ms for env (custom)")
assert_eq(ls.config.audio.max_duration_ms, 30000, "max_ms for env")
assert_eq(ls.config.audio.partial_interval_ms, 700, "partial_ms for env")
assert_eq(ls.config.audio.window_ms, 5000, "window_ms for env")
assert_eq(ls.config.audio.live_buffer, true, "live_buffer for env")

-- ============================================================================
-- Test 14: Accumulator Module
-- ============================================================================
section("14. Accumulator Module")

local Accumulator = require("lazyspeak.accumulator").Accumulator

-- Construction
local acc = Accumulator:new({ mode = "hidden" })
assert_type(acc, "table", "Accumulator instance is a table")
assert_eq(acc.text, "", "initial text is empty")
assert_eq(acc:has_text(), false, "initial has_text is false")
assert_eq(#acc.chunks, 0, "initial chunks is empty")
assert_eq(acc.mode, "hidden", "initial mode is hidden")

-- Construction with custom opts
local acc2 = Accumulator:new({ mode = "preview", width = 60, position = "left" })
assert_eq(acc2.mode, "preview", "custom mode set")
assert_eq(acc2.opts.width, 60, "custom width set")
assert_eq(acc2.opts.position, "left", "custom position set")
acc2:dispose()

-- Construction with nil opts
local acc3 = Accumulator:new(nil)
assert_type(acc3, "table", "new(nil) works")
assert_eq(acc3.mode, "hidden", "default mode with nil opts")
acc3:dispose()

-- Append chunks
acc:append("hello")
assert_eq(acc.text, "hello", "text after first append")
assert_eq(#acc.chunks, 1, "one chunk after first append")
assert_eq(acc:has_text(), true, "has_text after append")

acc:append("world")
assert_eq(acc.text, "hello world", "text after second append (space-joined)")
assert_eq(#acc.chunks, 2, "two chunks after second append")

acc:append("this is a test")
assert_eq(acc.text, "hello world this is a test", "text after third append")
assert_eq(#acc.chunks, 3, "three chunks after third append")

-- Empty append is no-op
acc:append("")
assert_eq(#acc.chunks, 3, "empty append is no-op")
acc:append(nil)
assert_eq(#acc.chunks, 3, "nil append is no-op")

-- Buffer operations
assert_ok(acc.buf ~= nil, "buffer created after append")
assert_ok(vim.api.nvim_buf_is_valid(acc.buf), "buffer is valid")

-- Verify buffer content matches accumulated text
local buf_lines = vim.api.nvim_buf_get_lines(acc.buf, 0, -1, false)
local buf_text = table.concat(buf_lines, "\n")
assert_eq(buf_text, acc.text, "buffer content matches accumulated text")

-- Clear
acc:clear()
assert_eq(acc.text, "", "text is empty after clear")
assert_eq(#acc.chunks, 0, "chunks is empty after clear")
assert_eq(acc:has_text(), false, "has_text is false after clear")

-- Verify buffer is cleared
buf_lines = vim.api.nvim_buf_get_lines(acc.buf, 0, -1, false)
buf_text = table.concat(buf_lines, "\n")
assert_eq(buf_text, "", "buffer content is empty after clear")

-- Re-append after clear
acc:append("fresh start")
assert_eq(acc.text, "fresh start", "text after re-append")
assert_eq(#acc.chunks, 1, "one chunk after re-append")

-- Context gathering
local ctx = acc:_gather_context()
assert_type(ctx, "table", "gather_context returns a table")
assert_type(ctx.filename, "string", "context has filename")
assert_type(ctx.cursor, "table", "context has cursor")
assert_type(ctx.buffer_lines, "table", "context has buffer_lines")
assert_type(ctx.buffer_line_count, "number", "context has buffer_line_count")
assert_type(ctx.window_top, "number", "context has window_top")
assert_type(ctx.filetype, "string", "context has filetype")

-- Context with diagnostics enabled
local acc_diag = Accumulator:new({ context = { diagnostics = true } })
local ctx_diag = acc_diag:_gather_context()
assert_type(ctx_diag.diagnostics, "table", "context has diagnostics when enabled")
acc_diag:dispose()

-- Context with options disabled
local acc_minimal = Accumulator:new({ context = { filename = false, cursor = false, buffer = false } })
local ctx_minimal = acc_minimal:_gather_context()
assert_eq(ctx_minimal.filename, nil, "filename omitted when disabled")
assert_eq(ctx_minimal.cursor, nil, "cursor omitted when disabled")
assert_eq(ctx_minimal.buffer_lines, nil, "buffer_lines omitted when disabled")
acc_minimal:dispose()

-- Prompt building
local prompt = acc:_build_prompt(ctx)
assert_type(prompt, "string", "build_prompt returns a string")
assert_ok(prompt:find("Transform the following voice input"), "prompt has instruction")
assert_ok(prompt:find("Voice input:"), "prompt has voice input section")
assert_ok(prompt:find("fresh start"), "prompt contains accumulated text")
assert_ok(prompt:find("Filename:"), "prompt contains filename")
assert_ok(prompt:find("Cursor:"), "prompt contains cursor position")
assert_ok(prompt:find("Buffer context"), "prompt contains buffer context")
assert_ok(prompt:find("Return only the transformed text"), "prompt has output instruction")

-- Prompt with selection
local ctx_with_sel = vim.tbl_extend("force", ctx, {
	selection = { "selected text here" },
})
local prompt_sel = acc:_build_prompt(ctx_with_sel)
assert_ok(prompt_sel:find("Selected text:"), "prompt has selected text section")
assert_ok(prompt_sel:find("selected text here"), "prompt contains selection content")

-- Dispose
acc:dispose()
assert_eq(acc.buf, nil, "buffer is nil after dispose")
assert_eq(acc.text, "", "text is empty after dispose")
assert_eq(#acc.chunks, 0, "chunks is empty after dispose")

-- ============================================================================
-- Test 14b: Accumulator Insertion & Confirm Flow
-- ============================================================================
section("14b. Accumulator Insertion & Confirm")

-- Test single-line insertion at cursor
local ins_acc = Accumulator:new({})
local ins_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(ins_buf)
vim.api.nvim_buf_set_lines(ins_buf, 0, -1, false, { "line one", "line two", "line three" })
vim.api.nvim_win_set_cursor(0, { 2, 3 }) -- line 2 (1-indexed), col 3

ins_acc:_insert_at_cursor("inserted")
local ins_lines = vim.api.nvim_buf_get_lines(ins_buf, 0, -1, false)
assert_eq(ins_lines[2], "lininsertede two", "single-line insertion at cursor column")

-- Test multi-line insertion
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- line 1, col 0
ins_acc:_insert_at_cursor("first\nsecond\nthird")
ins_lines = vim.api.nvim_buf_get_lines(ins_buf, 0, -1, false)
assert_eq(ins_lines[1], "first", "multi-line: first line inserted")
assert_eq(ins_lines[2], "second", "multi-line: second line inserted")
assert_eq(ins_lines[3], "third", "multi-line: third line inserted")

ins_acc:dispose()
vim.api.nvim_buf_delete(ins_buf, { force = true })

-- Test confirm with custom handler
local confirm_acc = Accumulator:new({
	handler = {
		fn = function(text, context)
			return "transformed: " .. text
		end,
	},
})
confirm_acc:append("hello world")

local confirm_result = nil
confirm_acc:confirm(function(text)
	confirm_result = text
end)
assert_eq(confirm_result, "transformed: hello world", "custom handler transforms text")

-- Test confirm with handler returning nil (falls back to direct insertion)
local nil_handler_acc = Accumulator:new({
	handler = {
		fn = function() return nil end,
	},
})
nil_handler_acc:append("test text")
local nil_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(nil_buf)
vim.api.nvim_buf_set_lines(nil_buf, 0, -1, false, { "" })

local nil_result = nil
nil_handler_acc:confirm(function(text)
	nil_result = text
end)
assert_eq(nil_result, "test text", "nil handler falls back to direct insertion with original text")

nil_handler_acc:dispose()
vim.api.nvim_buf_delete(nil_buf, { force = true })

-- Test confirm with no handler (direct insertion fallback)
local no_handler_acc = Accumulator:new({})
no_handler_acc:append("direct text")
local no_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(no_buf)
vim.api.nvim_buf_set_lines(no_buf, 0, -1, false, { "" })

local no_result = nil
no_handler_acc:confirm(function(text)
	no_result = text
end)
assert_eq(no_result, "direct text", "no handler falls back to direct insertion")

no_handler_acc:dispose()
vim.api.nvim_buf_delete(no_buf, { force = true })

-- Test confirm on empty accumulator (should not call on_complete)
local empty_acc = Accumulator:new({})
local empty_called = false
empty_acc:confirm(function() empty_called = true end)
assert_eq(empty_called, false, "confirm on empty does not call on_complete")
empty_acc:dispose()

-- Test confirm with CodeCompanion not available (handler.name set but module missing)
local cc_acc = Accumulator:new({
	handler = { name = "nonexistent" },
})
cc_acc:append("cc test")
local cc_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(cc_buf)
vim.api.nvim_buf_set_lines(cc_buf, 0, -1, false, { "" })

local cc_result = nil
cc_acc:confirm(function(text)
	cc_result = text
end)
assert_eq(cc_result, "cc test", "missing CodeCompanion falls back to direct insertion")

cc_acc:dispose()
vim.api.nvim_buf_delete(cc_buf, { force = true })

-- Test preview window operations (headless-safe)
local preview_acc = Accumulator:new({ mode = "preview" })
preview_acc:append("preview text")

-- Open preview
preview_acc:open_preview()
assert_ok(preview_acc.win ~= nil, "preview window created")
assert_ok(vim.api.nvim_win_is_valid(preview_acc.win), "preview window is valid")

-- Verify preview buffer content
local preview_buf = vim.api.nvim_win_get_buf(preview_acc.win)
local preview_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
assert_eq(table.concat(preview_lines, "\n"), "preview text", "preview buffer shows accumulated text")

-- Open again is no-op
local old_win = preview_acc.win
preview_acc:open_preview()
assert_eq(preview_acc.win, old_win, "open_preview is no-op when already open")

-- Close preview
preview_acc:close_preview()
assert_eq(preview_acc.win, nil, "preview window is nil after close")

-- Toggle preview
preview_acc:toggle_preview()
assert_ok(preview_acc.win ~= nil, "toggle opens preview")
preview_acc:toggle_preview()
assert_eq(preview_acc.win, nil, "toggle closes preview")

-- Update preview after append
preview_acc:open_preview()
local preview_win_before = preview_acc.win
preview_acc:append("more preview")
-- Buffer should be updated
preview_buf = vim.api.nvim_win_get_buf(preview_acc.win)
preview_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
assert_eq(table.concat(preview_lines, "\n"), "preview text more preview", "preview buffer updates on append")

preview_acc:dispose()

-- ============================================================================
-- Test 15: Accumulator Config & Wiring
-- ============================================================================
section("15. Accumulator Config & Wiring")

-- Verify defaults
assert_eq(ls.defaults.accumulator.enabled, false, "accumulator disabled by default")
assert_eq(ls.defaults.accumulator.mode, "hidden", "accumulator mode is hidden by default")
assert_eq(ls.defaults.accumulator.handler, nil, "accumulator handler is nil by default")
assert_type(ls.defaults.accumulator.context, "table", "accumulator context is a table")

-- Verify config has accumulator section after setup
assert_type(ls.config.accumulator, "table", "config.accumulator exists after setup")
assert_eq(ls.config.accumulator.enabled, false, "config.accumulator.enabled is false")

-- Test setup with accumulator enabled
ls.setup({
	accumulator = {
		enabled = true,
		mode = "preview",
	},
})
assert_eq(ls.config.accumulator.enabled, true, "accumulator enabled after setup")
assert_eq(ls.config.accumulator.mode, "preview", "accumulator mode is preview after setup")

-- Reset config for remaining tests
ls.setup({})

-- Test public API methods exist
assert_type(ls.confirm_accumulator, "function", "confirm_accumulator is a function")
assert_type(ls.cancel_accumulator, "function", "cancel_accumulator is a function")
assert_type(ls.clear_accumulator, "function", "clear_accumulator is a function")

-- ============================================================================
-- Test 16: Scratchpad Mode (Iterative Accumulator)
-- ============================================================================
section("16. Scratchpad Mode")

-- Verify scratchpad mode exists in defaults
assert_type(ls.defaults.accumulator.scratchpad_system, "string", "scratchpad_system prompt template exists")

-- Test scratchpad accumulator construction
local sp = Accumulator:new({ mode = "scratchpad" })
assert_type(sp, "table", "scratchpad accumulator instance is a table")
assert_eq(sp.mode, "scratchpad", "mode is scratchpad")
assert_eq(sp._iterating, false, "not iterating initially")
assert_eq(sp._queued, nil, "no queue initially")

-- Test scratchpad prompt building
local sp_prompt = sp:_build_scratchpad_prompt("hello world")
assert_type(sp_prompt, "string", "scratchpad prompt is a string")
assert_ok(sp_prompt:find("<scratchpad>"), "prompt has scratchpad tag")
assert_ok(sp_prompt:find("(empty)"), "prompt shows empty scratchpad")
assert_ok(sp_prompt:find("<instruction>"), "prompt has instruction tag")
assert_ok(sp_prompt:find("hello world"), "prompt contains utterance")

-- Test scratchpad prompt with existing content
sp:append("first line of content")
local sp_prompt2 = sp:_build_scratchpad_prompt("add more")
assert_ok(sp_prompt2:find("first line of content"), "prompt contains existing scratchpad content")
assert_ok(sp_prompt2:find("add more"), "prompt contains new instruction")

-- Test iterate with no handler (falls back to direct append)
sp:clear()
local iter_result = nil
sp:iterate("test utterance", function(text)
	iter_result = text
end)
assert_eq(iter_result, "test utterance", "iterate with no handler falls back to append")
assert_eq(sp._iterating, false, "gate is clear after iterate with no handler")

-- Test iterate with custom function handler
local sp_handler = Accumulator:new({
	mode = "scratchpad",
	handler = {
		fn = function(utterance, ctx)
			local base = ctx.scratchpad or ""
			if base == "" then
				return "LLM transformed: " .. utterance
			else
				return base .. " + " .. utterance
			end
		end,
	},
})

-- First iteration (empty scratchpad)
local result1 = nil
sp_handler:iterate("write a function", function(text)
	result1 = text
end)
assert_eq(result1, "LLM transformed: write a function", "first iteration transforms utterance")
assert_eq(sp_handler.text, "LLM transformed: write a function", "scratchpad text updated")
assert_eq(sp_handler._iterating, false, "gate is clear after first iteration")

-- Second iteration (scratchpad has content)
local result2 = nil
sp_handler:iterate("add error handling", function(text)
	result2 = text
end)
assert_eq(result2, "LLM transformed: write a function + add error handling", "second iteration appends to scratchpad")
assert_eq(sp_handler.text, "LLM transformed: write a function + add error handling", "scratchpad text updated again")

-- Third iteration (simulating "delete that line")
local result3 = nil
sp_handler:iterate("remove the error handling part", function(text)
	result3 = text
end)
assert_eq(result3, "LLM transformed: write a function + add error handling + remove the error handling part", "third iteration continues building")

sp_handler:dispose()

-- Test iterate with empty/nil utterance (no-op)
sp:clear()
local noop_called = false
sp:iterate("", function() noop_called = true end)
assert_eq(noop_called, false, "empty utterance does not iterate")
sp:iterate(nil, function() noop_called = true end)
assert_eq(noop_called, false, "nil utterance does not iterate")

-- Test queuing: simulate concurrent iterations
local queue_acc = Accumulator:new({
	mode = "scratchpad",
	handler = {
		fn = function(utterance, ctx)
			return ctx.scratchpad .. " | " .. utterance
		end,
	},
})

-- Manually set gate to simulate in-flight LLM call
queue_acc._iterating = true

-- Queue two utterances
queue_acc:iterate("utterance A")
assert_ok(queue_acc._queued ~= nil, "queue created")
assert_eq(#queue_acc._queued, 1, "one item queued")

queue_acc:iterate("utterance B")
assert_eq(#queue_acc._queued, 2, "two items queued")

-- Clear the gate and process first queued item
queue_acc._iterating = false
local first_result = nil
queue_acc:iterate("utterance C", function(text)
	first_result = text
end)
-- After processing C, the queue should have been processed
assert_eq(first_result, " | utterance C", "first unqueued item processed")

queue_acc:dispose()
sp:dispose()

-- Test scratchpad mode in config
ls.setup({
	accumulator = {
		enabled = true,
		mode = "scratchpad",
	},
})
assert_eq(ls.config.accumulator.mode, "scratchpad", "scratchpad mode set in config")

-- Reset config
ls.setup({})

-- ============================================================================
-- Summary
-- ============================================================================
section("Results")
print(string.format("\nPassed: %d", passed))
print(string.format("Failed: %d", failed))

if failed > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print(string.format("  - %s: %s", e[1], tostring(e[2])))
  end
end

local total = passed + failed
print(string.format("\n%d/%d checks passed", passed, total))

if failed > 0 then
  print("\n❌ INTEGRATION TEST FAILED")
else
  print("\n✅ ALL INTEGRATION TESTS PASSED")
end

vim.cmd("quit!")
