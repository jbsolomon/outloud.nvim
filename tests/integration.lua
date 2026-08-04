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
test_voice:_handle_line(vim.json.encode({ type = "partial", text = "hello" }))
test_voice:_handle_line(vim.json.encode({ type = "partial", text = "hello world" }))
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
  { type = "partial", text = "add a function" },
  { type = "partial", text = "add a function that sorts" },
  { type = "partial", text = "add a function that sorts the array" },
  
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
