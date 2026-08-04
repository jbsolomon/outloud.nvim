#!/usr/bin/env -S nvim --headless -l

-- Headless verification script for outloud.nvim
-- Run: nvim --headless -l tests/verify.lua

-- Add project lua/ directory to package.path so modules are discoverable
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:match("^@(.*)"), ":h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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

local function section(name)
  print(string.format("\n=== %s ===", name))
end

print("outloud.nvim headless verification")
print(string.rep("=", 40))

-- 1. Module loading
section("Module Loading")

local modules = {
  "outloud",
  "outloud.voice",
  "outloud.sidebar",
  "outloud.ui",
  "outloud.install",
  "outloud.health",
}

for _, mod_path in ipairs(modules) do
  local ok, mod = pcall(require, mod_path)
  assert_ok(ok, string.format("require('%s')", mod_path), mod)
end

-- Modules that should NOT exist (deleted)
section("Deleted Modules (should not load)")

local deleted = {
  "outloud.core",
  "outloud.snapshot",
  "outloud.adapters.acp",
  "outloud.adapters.claudecode",
}

for _, mod_path in ipairs(deleted) do
  local ok, _ = pcall(require, mod_path)
  assert_ok(not ok, string.format("require('%s') should fail", mod_path))
end

-- 2. Public API surface
section("Public API")

local ls = require("outloud")

local required_methods = {
  "setup",
  "start",
  "stop",
  "status",
  "dismiss",
}

for _, method in ipairs(required_methods) do
  assert_ok(type(ls[method]) == "function", string.format("outloud.%s()", method))
end

-- Config structure
section("Config Defaults")

assert_ok(type(ls.defaults) == "table", "defaults table exists")
assert_ok(type(ls.defaults.model) == "table", "defaults.model exists")
assert_ok(type(ls.defaults.audio) == "table", "defaults.audio exists")
assert_ok(type(ls.defaults.ui) == "table", "defaults.ui exists")
assert_ok(type(ls.defaults.keys) == "table", "defaults.keys exists")

-- Agent config should NOT exist
assert_ok(ls.defaults.agent == nil, "defaults.agent removed (no ACP)")

-- 3. Voice class
section("Voice Daemon")

local Voice = require("outloud.voice").Voice
assert_ok(type(Voice) == "table", "Voice class exists")
assert_ok(type(Voice.new) == "function", "Voice:new()")
assert_ok(type(Voice.start) == "function", "Voice:start()")
assert_ok(type(Voice.stop) == "function", "Voice:stop()")
assert_ok(type(Voice.start_listening) == "function", "Voice:start_listening()")
assert_ok(type(Voice.stop_listening) == "function", "Voice:stop_listening()")
assert_ok(type(Voice.on_transcript) == "function", "Voice:on_transcript()")
assert_ok(type(Voice.on_partial) == "function", "Voice:on_partial()")

--- 4. Sidebar class
section("Sidebar UI")

local Sidebar = require("outloud.sidebar").Sidebar
assert_ok(type(Sidebar) == "table", "Sidebar class exists")
assert_ok(type(Sidebar.new) == "function", "Sidebar:new()")
assert_ok(type(Sidebar.open) == "function", "Sidebar:open()")
assert_ok(type(Sidebar.close) == "function", "Sidebar:close()")
assert_ok(type(Sidebar.set_state) == "function", "Sidebar:set_state()")
assert_ok(type(Sidebar.set_status) == "function", "Sidebar:set_status()")
assert_ok(type(Sidebar.begin_turn) == "function", "Sidebar:begin_turn()")
assert_ok(type(Sidebar.set_partial) == "function", "Sidebar:set_partial()")

-- Agent methods should NOT exist on sidebar
assert_ok(Sidebar.append_message == nil, "Sidebar:append_message() removed")
assert_ok(Sidebar.append_thought == nil, "Sidebar:append_thought() removed")
assert_ok(Sidebar.add_tool_call == nil, "Sidebar:add_tool_call() removed")
assert_ok(Sidebar.add_diff == nil, "Sidebar:add_diff() removed")
assert_ok(Sidebar.set_permission == nil, "Sidebar:set_permission() removed")
assert_ok(Sidebar.resolve_permission == nil, "Sidebar:resolve_permission() removed")
assert_ok(Sidebar._stream == nil, "Sidebar:_stream() removed")

-- Sidebar status should NOT have agent key
local sb = Sidebar:new({ width = 48, position = "right", keys = {} })
assert_ok(sb.status.agent == nil, "sidebar status has no agent key")
assert_ok(sb.status.stt ~= nil, "sidebar status has stt key")
assert_ok(sb.status.daemon ~= nil, "sidebar status has daemon key")

-- 5. Install module
section("Install / STT Server")

local install = require("outloud.install")
assert_ok(type(install.run) == "function", "install.run()")
assert_ok(type(install.start_llama_server) == "function", "install.start_llama_server()")
assert_ok(type(install.stop_llama_server) == "function", "install.stop_llama_server()")
assert_ok(type(install.HF_REPO) == "string", "install.HF_REPO")
assert_ok(type(install.DEFAULT_PORT) == "number", "install.DEFAULT_PORT")

-- 6. Health check
section("Health Check")

-- Health check should not error
local ok, err = pcall(function()
  require("outloud.health").check()
end)
assert_ok(ok, "health.check() runs without error", err)

-- 7. Setup smoke test
section("Setup")

local setup_ok, setup_err = pcall(function()
  ls.setup({})
end)
assert_ok(setup_ok, "setup({}) runs without error", setup_err)

-- Config should be populated after setup
assert_ok(type(ls.config) == "table", "config table exists after setup")
assert_ok(ls.config.agent == nil, "config.agent is nil (no ACP)")
assert_ok(ls.config.accumulator ~= nil, "config.accumulator exists")
assert_ok(ls.config.accumulator.enabled == false, "accumulator disabled by default")

-- 8. Accumulator module
section("Accumulator")

local Accumulator = require("outloud.accumulator").Accumulator
assert_ok(type(Accumulator) == "table", "Accumulator class exists")
assert_ok(type(Accumulator.new) == "function", "Accumulator:new()")
assert_ok(type(Accumulator.append) == "function", "Accumulator:append()")
assert_ok(type(Accumulator.clear) == "function", "Accumulator:clear()")
assert_ok(type(Accumulator.confirm) == "function", "Accumulator:confirm()")
assert_ok(type(Accumulator.dispose) == "function", "Accumulator:dispose()")
assert_ok(type(Accumulator.has_text) == "function", "Accumulator:has_text()")

-- Smoke test accumulator instance
local acc = Accumulator:new({})
assert_ok(acc:has_text() == false, "new accumulator has no text")
acc:append("hello world")
assert_ok(acc:has_text() == true, "accumulator has text after append")
assert_ok(acc.text == "hello world", "accumulator text correct")
acc:append("more text")
assert_ok(acc.text == "hello world more text", "accumulator joins chunks with space")
acc:clear()
assert_ok(acc:has_text() == false, "accumulator empty after clear")
acc:dispose()

-- 9. Public API for accumulator commands
section("Accumulator API")

assert_ok(type(ls.confirm_accumulator) == "function", "outloud.confirm_accumulator()")
assert_ok(type(ls.cancel_accumulator) == "function", "outloud.cancel_accumulator()")
assert_ok(type(ls.clear_accumulator) == "function", "outloud.clear_accumulator()")

-- Summary
section("Results")
print(string.format("\nPassed: %d", passed))
print(string.format("Failed: %d", failed))

if failed > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print(string.format("  - %s: %s", e[1], tostring(e[2])))
  end
end

print(string.format("\n%d/%d checks passed", passed, passed + failed))

vim.cmd("quit!")
