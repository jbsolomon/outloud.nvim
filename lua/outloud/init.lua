local Voice = require("outloud.voice").Voice
local Sidebar = require("outloud.sidebar").Sidebar
local Accumulator = require("outloud.accumulator").Accumulator
local ui = require("outloud.ui")
local install = require("outloud.install")

local V = vim
local VK = vim.keymap
local VL = V.log
local VLL = VL.levels

local M = {}

---@class outloud.Config
---@field backend?    string                                                                                                                                                                                                        "whisper" (default) or "openai" (OpenAI-compatible)
---@field model       { size?: string, path?: string, repo?: string, filename?: string, download_url?: string, hf_repo?: string, server_port: number, server_url?: string }
---@field audio       { sample_rate: number, channels: number, vad_threshold: number, silence_duration_ms: number, max_duration_ms: number, partial_interval_ms: number, window_ms: number, live_buffer: boolean, device?: string }
---@field accumulator { enabled: boolean, mode: string, handler?: table, context: table, register: string }
---@field ui          { sidebar_position: string, sidebar_width: number, sidebar_auto_open: boolean, statusline: boolean }
---@field keys        { push_to_talk: string, cancel: string, sidebar: string }
---@field daemon_cmd? string

---@type outloud.Config
M.defaults = {
	backend = "whisper",
	model = {
		size = "large-v3-turbo-q8_0", -- whisper model name: tiny, tiny.en, base, base.en, small, small.en, medium, medium.en, large-v1, large-v2, large-v3, large-v3-turbo (plus -q5_0, -q5_1, -q8_0 quantized variants)
		-- filename = "ggml-medium.bin",      -- local model filename (must exist in data_dir/models/)
		-- download_url = "...",              -- direct download URL (bypasses canonical source)
		hf_repo = install.HF_REPO, -- for openai backend: llama-server HuggingFace repo
		server_port = install.WHISPER_DEFAULT_PORT
		-- server_url = "http://127.0.0.1:8000",  -- override to use external server
	},
	audio = {
		sample_rate = 16000,
		channels = 1,
		vad_threshold = 0.01,
		silence_duration_ms = 400,
		max_duration_ms = 30000,
		partial_interval_ms = 700,
		window_ms = 5000,
		live_buffer = true,
		device = nil -- optional default device name
	},
	accumulator = {
		enabled = false,
		mode = "hidden", -- "hidden" | "preview"
		handler = nil,   -- { name = "default" } for CodeCompanion, or { fn = function(text, context) ... end }
		register = "o", -- named register to save scratchpad content to on stop
		context = {
			buffer = true,
			selection = true,
			cursor = true,
			diagnostics = false,
			filename = true
		},
		scratchpad_system = [[You are editing a scratch pad. The user speaks instructions and you maintain the scratch pad content.

Here is the current scratch pad content (may be empty initially):
<scratchpad>
%s
</scratchpad>

Here is the user's latest instruction:
<instruction>
%s
</instruction>

Return only the updated scratch pad content. Do not include explanations or markdown fences.]]
	},
	ui = {
		sidebar_position = "right",
		sidebar_width = 48,
		sidebar_auto_open = true,
		statusline = true
	},
	keys = {
		push_to_talk = "<leader>ls",
		cancel = "<leader>lc",
		sidebar = "<leader>ll",
		scratchpad = "<leader>lp",
		accept = "<leader>lt"
	}
}

---@type outloud.Config
M.config = {}

---@type outloud.Voice?
M._voice = nil

---@type outloud.Sidebar?
M._sidebar = nil

---@type string
M._state = "inactive"

---@type boolean
M._listening = false

---@type boolean true after start_listening is sent until the daemon confirms
--- (or the start is cancelled/fails). Prevents a fast second toggle from
--- sending a duplicate start instead of a stop.
M._start_pending = false

---@type string? last backend health the daemon reported ("pending"|"healthy"|"unhealthy")
M._backend_status = nil

---@type string?
M._active_device = nil

---@type boolean true when a device list was explicitly requested via
---:OutloudDevices. The daemon also answers a silent list_devices pre-fetch
---on startup (used to cache native sample formats); only an explicit request
---shows the list, since a multi-line vim.notify can block on a hit-enter
---prompt.
M._devices_requested = false

---@type boolean true when <leader>lt was pressed while the daemon was still starting
M._listen_on_ready = false

---@type outloud.Accumulator?
M._accumulator = nil

---@return outloud.Sidebar
function M._ensure_sidebar()
	if not M._sidebar then
		local cfg = M.config.ui or M.defaults.ui
		M._sidebar = Sidebar:new({
			width = cfg.sidebar_width,
			position = cfg.sidebar_position,
			keys = M.config.keys or M.defaults.keys
		})
	end
	return M._sidebar
end

--- Dismiss the sidebar without stopping the daemon.
function M.dismiss()
	if M._sidebar then
		M._sidebar:close()
	end
end

---@param opts? table
function M.setup(opts)
	M.config = V.tbl_deep_extend("force", M.defaults, opts or {})

	local keys = M.config.keys

	-- Never leave a daemon or llama-server process behind on exit.
	V.api.nvim_create_autocmd("VimLeavePre", {
		group = V.api.nvim_create_augroup("outloud_shutdown", { clear = true }),
		desc = "outloud: shut down daemon and STT server",
		callback = function ()
			M.stop()
		end
	})

VK.set("n", keys.push_to_talk, function ()
		if not M._voice or not M._voice:is_running() then
			M.start()
		end
	end, { desc = "outloud: start/stop daemon" })

	--- Save accumulated content to register.
	local function _save_to_register()
		if M._accumulator then
			local reg = M.config.accumulator and M.config.accumulator.register or "o"
			M._accumulator:to_register(reg)
		end
	end

	VK.set("n", keys.cancel, function ()
		if M._voice and M._voice:is_running() then
			-- Yank, clear accumulator, stop mic, close preview
			_save_to_register()
			if M._accumulator then
				M._accumulator:_cancel()
				M._accumulator:clear()
				M._accumulator:close_preview()
			end
			M._voice:stop_listening()
			M._voice:cancel()
			M._listening = false
			M._start_pending = false
		end
	end, { desc = "outloud: cancel" }
	)

	VK.set("n", keys.sidebar, function ()
		M._ensure_sidebar():toggle()
	end, { desc = "outloud: toggle session sidebar" }
	)

	VK.set("n", keys.scratchpad, function ()
		-- Opening the scratchpad preview should start the daemon if not running
		if not M._voice or not M._voice:is_running() then
			M.start()
		end

		-- Ensure accumulator exists for scratchpad mode
		if not M._accumulator then
			if M.config.accumulator and M.config.accumulator.enabled then
				M._accumulator = Accumulator:new(M.config.accumulator)
			else
				V.notify("[outloud] accumulator not active", VLL.WARN)
				return
			end
		end
		M._accumulator:toggle_scratchpad()
	end, { desc = "outloud: toggle scratchpad preview" }
	)

	VK.set("n", keys.accept, function ()
		if not M._voice or not M._voice:is_running() then
			-- Startup includes an asynchronous server probe/model load. Remember
			-- the user's intent so the first press starts the microphone too,
			-- rather than requiring a second press after the daemon appears.
			M._listen_on_ready = true
			V.notify("[outloud] starting daemon...", VLL.INFO)
			M.start()
			return
		end
		if M._listening then
			-- Done with this session: yank, clear accumulator, keep mic open
			_save_to_register()
			if M._accumulator then
				M._accumulator:clear()
			end
			M._listening = false
		elseif M._start_pending then
			-- Start sent but not yet confirmed by the daemon: treat a second
			-- press as cancelling the pending start rather than starting twice.
			M._voice:stop_listening()
			M._start_pending = false
		else
			M._voice:start_listening(M.config.audio.device)
			-- Don't set _listening = true optimistically; wait for the
			-- daemon's "status: listening" event to confirm.
			M._start_pending = true
		end
	end, { desc = "outloud: accept" }
	)
end

--- Build the environment variable table for the daemon process.
---@param backend string
---@param model   table  the model config table
---@param audio   table  the audio config table
---@return table<string, string>
local function build_daemon_env(backend, model, audio)
	local default_port = (backend == "whisper") and install.WHISPER_DEFAULT_PORT or install.DEFAULT_PORT
	local url = model.server_url or ("http://127.0.0.1:" .. (model.server_port or default_port))
	local env = {
		OUTLOUD_STT_BACKEND = backend,
		OUTLOUD_STT_URL = url,
		OUTLOUD_VAD_THRESHOLD = tostring(audio.vad_threshold),
		OUTLOUD_SILENCE_MS = tostring(audio.silence_duration_ms),
		OUTLOUD_MAX_MS = tostring(audio.max_duration_ms),
		OUTLOUD_PARTIAL_MS = tostring(audio.partial_interval_ms),
		OUTLOUD_WINDOW_MS = tostring(audio.window_ms)
	}
	if audio.device and audio.device ~= "" then
		env.OUTLOUD_MIC_DEVICE = audio.device
	end
	return env
end

--- Probe an external STT server to see if it's online.
---@param url string           the server URL
---@param cb  fun(ok: boolean)
local function probe_external_server(url, cb)
	-- Extract host and port, determine health path from backend
	local scheme, host, port = url:match("^(https?)://([^:/]+)(?::(%d+))?")
	if not host then
		V.schedule(function ()
			cb(false)
		end)
		return
	end
	port = tonumber(port) or (scheme == "https" and 443 or 80)

	-- Try the health endpoint first, then root
	local health_paths = { "/health", "/" }
	local idx = 1

	local function try_next()
		if idx > #health_paths then
			-- All probes failed
			V.schedule(function ()
				cb(false)
			end)
			return
		end
		local path = health_paths[idx]
		local probe_url = string.format("%s://%s:%d%s", scheme, host, port, path)

		V.system({
			"curl",
			"-sf",
			"--connect-timeout",
			"2",
			"--max-time",
			"3",
			probe_url
		},
			{ text = true }, function (res)
				if res.code == 0 then
					V.schedule(function ()
						cb(true)
					end)
				else
					idx = idx + 1
					try_next()
				end
			end)
	end

	try_next()
end

--- Forward declaration: defined below (starts the STT server, then pipeline).
local _start_with_server

--- Start voice + UI, auto-launching the STT server if needed.
function M.start()
	-- Re-entry guard: server startup is async, so is_running() stays false
	-- for the whole probe/download/spawn window.
	if M._starting or (M._voice and M._voice:is_running()) then
		return
	end
	M._starting = true

	local backend = M.config.backend or "whisper"

	local function ui_state(state, detail)
		V.schedule(function ()
			M._ensure_sidebar():set_state(state, detail)
		end)
	end

	local function signal(key, value)
		V.schedule(function ()
			M._ensure_sidebar():set_status(key, value)
		end)
	end

	local function on_server_phase(phase, detail)
		if phase == "downloading" then
			ui_state("downloading_model", detail)
		elseif phase == "loading" then
			ui_state("loading_model")
		elseif phase == "ready" then
			signal("stt", "up")
		elseif phase == "error" then
			M._starting = false
			M._listen_on_ready = false
			signal("stt", "error")
			ui_state("inactive", detail)
		end
	end

	local function on_server_ready()
		M._starting = false
		ui_state("initializing")
		M._start_pipeline()
	end

	-- Check if daemon needs rebuilding before starting
	if install.needs_rebuild() then
		ui_state("starting_server", "building daemon...")
		V.notify("[outloud] daemon out of date, rebuilding...")
		install.build_daemon(function (ok)
			if not ok then
				M._starting = false
				M._listen_on_ready = false
				ui_state("inactive", "daemon build failed")
				return
			end
			_start_with_server(backend, ui_state, signal, on_server_phase, on_server_ready)
		end)
	else
		_start_with_server(backend, ui_state, signal, on_server_phase, on_server_ready)
	end
end

--- Internal: start the STT server and pipeline.
_start_with_server = function (backend, ui_state, signal, on_server_phase, on_server_ready)
	if not M.config.model.server_url then
		signal("stt", "starting")
		ui_state("starting_server")

		if backend == "whisper" then
			install.start_whisper_server({
				port = M.config.model.server_port or install.WHISPER_DEFAULT_PORT,
				model_name = M.config.model.size,
				model_path = M.config.model.path,
				model_filename = M.config.model.filename,
				download_url = M.config.model.download_url,
				on_phase = on_server_phase
			}, on_server_ready)
		else
			install.start_llama_server({
				port = M.config.model.server_port or install.DEFAULT_PORT,
				hf_repo = M.config.model.hf_repo,
				on_phase = on_server_phase
			}, on_server_ready)
		end
	else
		-- External server: probe it first
		signal("stt", "starting")
		ui_state("starting_server")
		probe_external_server(M.config.model.server_url, function (ok)
			M._starting = false
			if ok then
				signal("stt", "up")
				ui_state("starting_daemon")
				M._start_pipeline()
				ui_state("ready")
			else
				M._listen_on_ready = false
				signal("stt", "error")
				ui_state("inactive", "external server unreachable")
				V.notify(
					"[outloud] external STT server unreachable: " .. M.config.model.server_url,
					VLL.ERROR
				)
			end
		end)
	end
end

--- Internal: start the voice daemon and UI (called after server is ready).
function M._start_pipeline()
	if M._voice and M._voice:is_running() then
		return
	end

	-- Initialize voice daemon
	local backend = M.config.backend or "whisper"
	local daemon_env = build_daemon_env(backend, M.config.model, M.config.audio)
	M._voice = Voice:new({ daemon_cmd = M.config.daemon_cmd, env = daemon_env })

	-- Set up accumulator if enabled
	local accum_enabled = M.config.accumulator and M.config.accumulator.enabled
	if accum_enabled then
		M._accumulator = Accumulator:new(M.config.accumulator)
	end

	M._voice:on_chunk(function (text, duration_ms, is_final)
		if not text or text == "" then return end

		-- Show chunks in sidebar
		V.schedule(function ()
			M._ensure_sidebar():set_chunk(text)
		end)

		if accum_enabled and M._accumulator then
			-- Feed chunks into the accumulator
			V.schedule(function ()
				M._accumulator:append(text, is_final)
			end)
		else
			-- Direct insertion mode: insert chunk at cursor
			V.schedule(function ()
				local buf = V.api.nvim_get_current_buf()
				V.api.nvim_set_option_value("modifiable", true, { buf = buf })
				local line = V.api.nvim_win_get_cursor(0)[1] - 1
				local col = V.api.nvim_win_get_cursor(0)[2]
				V.api.nvim_buf_set_text(buf, line, col, line, col, { text })
			end)
		end
	end)

	M._voice:on_status(function (state, device, backend_status)
		M._state = state
		M._active_device = device
		ui.set_state(state)
		ui.set_device(device)

		-- state: 'idle'|'listening'|'transcribing'
		-- backend_status: {
		--   status: 'pending'|'healthy'|'unhealthy',
		--   error: string
		-- }

		if state == "listening" and M._start_pending then
			-- Daemon confirmed the start we requested. Stale "listening"
			-- re-emits (e.g. a heartbeat that was in flight before a stop)
			-- have _start_pending == false and can't resurrect the flag.
			M._listening = true
			M._start_pending = false
		end

		V.schedule(function ()
			local sb = M._ensure_sidebar()

			-- Backend health transitions. Every daemon status carries a
			-- (state, device, backend) snapshot; only log an error entry on
			-- the transition into "unhealthy" so the 5s heartbeat doesn't
			-- spam the conversation while the server is down.
			local prev_backend = M._backend_status
			if backend_status and backend_status.status then
				M._backend_status = backend_status.status
			end

			if backend_status and backend_status.status == "pending" then
				-- Daemon alive, waiting for STT probe
				sb:set_state("initializing")
		elseif backend_status and backend_status.status == "healthy" then
			sb:clear_error()
			sb:set_status("stt", "up")
			if state == "idle" then
				sb:set_state("stt_ready")
			elseif state == "listening" then
				sb:set_state("listening")
				sb:set_device(device)
			elseif state == "transcribing" then
				sb:set_state("transcribing")
				sb:set_device(device)
			end
			elseif backend_status and backend_status.status == "unhealthy" then
				sb:set_status("stt", "error")
				if backend_status.error and prev_backend ~= "unhealthy" then
					sb:add_error("STT: " .. backend_status.error)
				end
				sb:set_state("stt_unavailable")
			end
		end)
	end)

	M._voice:on_error(function (message)
		V.schedule(function ()
			M._listening = false
			M._start_pending = false
			V.notify("[outloud] daemon error: " .. message, VLL.ERROR)
			local sb = M._ensure_sidebar()
			sb:set_status("daemon", "error")
			sb:add_error("daemon: " .. message)
		end)
	end)

	M._voice:on_devices(function (devices, default)
		-- Silent for the startup pre-fetch; only an explicit :OutloudDevices
		-- request shows the list. With no configured device the daemon opens
		-- the system default (the first entry of its sorted list) anyway.
		if not M._devices_requested then
			return
		end
		M._devices_requested = false
		V.schedule(function ()
			local names = {}
			for _, d in ipairs(devices) do
				local mark = d.is_default and " *" or ""
				local fmt = d.sample_format and (" [" .. d.sample_format .. "]") or ""
				names[#names + 1] = d.name .. mark .. fmt
			end
			V.notify("[outloud] input devices:\n" .. table.concat(names, "\n"), VLL.INFO)
		end)
	end)

	-- Daemon process death (crash, device loss, external kill): reflect it in
	-- the UI instead of leaving stale "listening"/"up" state behind.
	M._voice:on_exit(function (code)
		V.schedule(function ()
			M._listening = false
			M._start_pending = false
			if M._sidebar then
				M._sidebar:set_status("daemon", "down")
				if code ~= 0 then
					M._sidebar:add_error(("daemon exited unexpectedly (code %d)"):format(code))
				end
			end
			if code ~= 0 then
				V.notify(("[outloud] daemon exited unexpectedly (code %d)"):format(code), VLL.WARN)
			end
		end)
	end)

	M._voice:start()
	M._ensure_sidebar():set_status("daemon", M._voice:is_running() and "up" or "error")

	-- Pre-fetch the device list so the first start_listening can forward the
	-- device's native sample format. If this response hasn't arrived yet,
	-- the daemon probes the device itself.
	if M._voice:is_running() then
		M._voice:list_devices()

		-- A first <leader>lt press may have started the asynchronous pipeline.
		-- Begin capture now that the daemon exists; status confirmation will set
		-- _listening and clear _start_pending as usual.
		if M._listen_on_ready then
			M._listen_on_ready = false
			M._start_pending = true
			M._voice:start_listening(M.config.audio.device)
		end
	end
end

--- Tear everything down: daemon, STT server, and UI. Also runs on
--- VimLeavePre so quitting Neovim never strands a background process.
function M.stop()
	M._starting = false
	-- Cancel any in-flight LLM iterations before tearing down
	if M._accumulator then
		M._accumulator:_cancel()
	end
	if M._voice then
		pcall(function ()
			M._voice:stop()
		end)
		M._voice = nil
	end
	local backend = M.config.backend or "whisper"
	if backend == "whisper" then
		install.stop_whisper_server()
	else
		install.stop_llama_server()
	end

	if M._sidebar then
		M._sidebar:dispose()
		M._sidebar = nil
	end

	if M._accumulator then
		-- Save accumulated text to register before disposing
		local reg = M.config.accumulator and M.config.accumulator.register or "o"
			M._accumulator:to_register(reg)
		M._accumulator:dispose()
		M._accumulator = nil
	end

	M._state = "inactive"
	ui.set_state("inactive")
	M._listening = false
	M._start_pending = false
	M._backend_status = nil
	M._devices_requested = false
	M._listen_on_ready = false
end

---@return string
function M.status()
	return ui.statusline()
end

--- List available input devices.
function M.list_devices()
	if not M._voice or not M._voice:is_running() then
		V.notify("[outloud] daemon not running", VLL.WARN)
		return
	end
	M._devices_requested = true
	M._voice:list_devices()
end

--- Confirm the accumulated text: invoke the handler and apply the result.
function M.confirm_accumulator()
	if not M._accumulator then
		V.notify("[outloud] accumulator not active", VLL.WARN)
		return
	end
	if not M._accumulator:has_text() then
		V.notify("[outloud] accumulator is empty", VLL.WARN)
		return
	end
	M._accumulator:confirm(function (text)
		-- After handler completes, insert result at cursor
		local sb = M._ensure_sidebar()
		sb:begin_turn(text)
		M._accumulator:clear()
	end)
end

--- Cancel and discard the accumulated text.
function M.cancel_accumulator()
	if not M._accumulator then
		V.notify("[outloud] accumulator not active", VLL.WARN)
		return
	end
	M._accumulator:clear()
	V.notify("[outloud] accumulator cleared", VLL.INFO)
end

--- Clear the accumulation without cancelling.
function M.clear_accumulator()
	if not M._accumulator then
		V.notify("[outloud] accumulator not active", VLL.WARN)
		return
	end
	M._accumulator:clear()
end

--- Toggle the scratchpad floating preview window.
function M.toggle_scratchpad()
	if not M._accumulator then
		V.notify("[outloud] accumulator not active", VLL.WARN)
		return
	end
	M._accumulator:toggle_scratchpad()
end

return M
