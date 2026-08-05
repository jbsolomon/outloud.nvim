local Voice = require("outloud.voice").Voice
local Sidebar = require("outloud.sidebar").Sidebar
local Accumulator = require("outloud.accumulator").Accumulator
local ui = require("outloud.ui")
local install = require("outloud.install")

local M = {}

---@class outloud.Config
---@field backend? string "whisper" (default) or "openai" (OpenAI-compatible)
---@field model { size?: string, path?: string, hf_repo?: string, server_port: number, server_url?: string }
---@field audio { sample_rate: number, channels: number, vad_threshold: number, silence_duration_ms: number, max_duration_ms: number, partial_interval_ms: number, window_ms: number, live_buffer: boolean }
---@field accumulator { enabled: boolean, mode: string, handler?: table, context: table }
---@field ui { sidebar_position: string, sidebar_width: number, sidebar_auto_open: boolean, statusline: boolean }
---@field keys { push_to_talk: string, cancel: string, sidebar: string }
---@field daemon_cmd? string

---@type outloud.Config
M.defaults = {
	backend = "whisper",
	model = {
		size = "medium",           -- whisper model size: "tiny", "base", "small", "medium", "large"
		hf_repo = install.HF_REPO, -- for openai backend: llama-server HuggingFace repo
		server_port = install.WHISPER_DEFAULT_PORT,
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
	},
	accumulator = {
		enabled = false,
		mode = "hidden",           -- "hidden" | "preview"
		handler = nil,             -- { name = "default" } for CodeCompanion, or { fn = function(text, context) ... end }
		context = {
			buffer = true,
			selection = true,
			cursor = true,
			diagnostics = false,
			filename = true,
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

Return only the updated scratch pad content. Do not include explanations or markdown fences.]],
	},
	ui = {
		sidebar_position = "right",
		sidebar_width = 48,
		sidebar_auto_open = true,
		statusline = true,
	},
	keys = {
		push_to_talk = "<leader>ls",
		cancel = "<leader>lc",
		sidebar = "<leader>ll",
	},
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

---@type table?
M._partial_range = nil

---@type outloud.Accumulator?
M._accumulator = nil

---@return outloud.Sidebar
function M._ensure_sidebar()
	if not M._sidebar then
		local cfg = M.config.ui or M.defaults.ui
		M._sidebar = Sidebar:new({
			width = cfg.sidebar_width,
			position = cfg.sidebar_position,
			keys = M.config.keys or M.defaults.keys,
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
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

	local keys = M.config.keys

	-- Never leave a daemon or llama-server process behind on exit.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("outloud_shutdown", { clear = true }),
		desc = "outloud: shut down daemon and STT server",
		callback = function()
			M.stop()
		end,
	})

	vim.keymap.set("n", keys.push_to_talk, function()
		if not M._voice or not M._voice:is_running() then
			M.start()
		end

		local sidebar = M._ensure_sidebar()
		if M.config.ui.sidebar_auto_open then
			sidebar:open(false)
		end
		sidebar:set_state("ready")

		local buf = vim.api.nvim_get_current_buf()

		local function cleanup()
			M._listening = false
			pcall(vim.keymap.del, "n", "<Space>", { buffer = buf })
			pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
		end

		-- <Space> toggles recording on/off
		vim.keymap.set("n", "<Space>", function()
			if not M._voice or not M._voice:is_running() then
				vim.notify("[outloud] waiting for daemon to start...", vim.log.levels.INFO)
				return
			end
			if M._listening then
				M._voice:stop_listening()
				M._listening = false
			else
				M._voice:start_listening()
				M._listening = true
			end
		end, { buffer = buf, desc = "outloud: toggle recording" })

		-- <Esc> cancels and dismisses the UI
		vim.keymap.set("n", "<Esc>", function()
			if M._listening and M._voice then
				M._voice:cancel()
			end
			cleanup()
			M.dismiss()
		end, { buffer = buf, desc = "outloud: close" })

		M._session_cleanup = cleanup
	end, { desc = "outloud: open" })

	vim.keymap.set("n", keys.cancel, function()
		if M._voice and M._voice:is_running() then
			M._voice:cancel()
			M._listening = false
		end
	end, { desc = "outloud: cancel" })

	vim.keymap.set("n", keys.sidebar, function()
		M._ensure_sidebar():toggle()
	end, { desc = "outloud: toggle session sidebar" })
end

--- Build the environment variable table for the daemon process.
---@param backend string
---@param model table the model config table
---@param audio table the audio config table
---@return table<string, string>
local function build_daemon_env(backend, model, audio)
	local default_port = (backend == "whisper") and install.WHISPER_DEFAULT_PORT or install.DEFAULT_PORT
	local url = model.server_url or ("http://127.0.0.1:" .. (model.server_port or default_port))
	return {
		OUTLOUD_STT_BACKEND = backend,
		OUTLOUD_STT_URL = url,
		OUTLOUD_VAD_THRESHOLD = tostring(audio.vad_threshold),
		OUTLOUD_SILENCE_MS = tostring(audio.silence_duration_ms),
		OUTLOUD_MAX_MS = tostring(audio.max_duration_ms),
		OUTLOUD_PARTIAL_MS = tostring(audio.partial_interval_ms),
		OUTLOUD_WINDOW_MS = tostring(audio.window_ms),
	}
end

--- Start voice + UI, auto-launching the STT server if needed.
function M.start()
	if M._voice and M._voice:is_running() then
		return
	end

	local backend = M.config.backend or "whisper"

	local function ui_state(state, detail)
		vim.schedule(function()
			M._ensure_sidebar():set_state(state, detail)
		end)
	end

	local function signal(key, value)
		vim.schedule(function()
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
			signal("stt", "error")
			ui_state("inactive", detail)
		end
	end

	local function on_server_ready()
		signal("stt", "up")
		ui_state("starting_daemon")
		M._start_pipeline()
		ui_state("ready")
	end

	-- If using the built-in server (no custom server_url), auto-start
	if not M.config.model.server_url then
		signal("stt", "starting")
		ui_state("starting_server")

		if backend == "whisper" then
			install.start_whisper_server({
				port = M.config.model.server_port or install.WHISPER_DEFAULT_PORT,
				model_size = M.config.model.size or "medium",
				model_path = M.config.model.path,
				on_phase = on_server_phase,
			}, on_server_ready)
		else
			install.start_llama_server({
				port = M.config.model.server_port or install.DEFAULT_PORT,
				hf_repo = M.config.model.hf_repo,
				on_phase = on_server_phase,
			}, on_server_ready)
		end
	else
		signal("stt", "up")
		ui_state("starting_daemon")
		M._start_pipeline()
		ui_state("ready")
	end
end

--- Internal: start the voice daemon and UI (called after server is ready).
function M._start_pipeline()
	if M._voice and M._voice:is_running() then
		return
	end

	-- Initialize UI
	local sidebar = M._ensure_sidebar()
	if M.config.ui.sidebar_auto_open then
		sidebar:open(false)
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

	M._voice:on_transcript(function(text, duration_ms)
		M._state = "idle"
		ui.set_state("idle")
		M._listening = false
		vim.schedule(function()
			local sb = M._ensure_sidebar()
			sb:begin_turn(text)
			sb:set_state("idle")
		end)

	if accum_enabled and M._accumulator then
		-- Accumulator mode: add final transcript to accumulator
		vim.schedule(function()
			local accum_mode = M.config.accumulator and M.config.accumulator.mode
			if accum_mode == "scratchpad" then
				-- Scratchpad mode: iterate the scratchpad with the latest utterance
				M._accumulator:iterate(text)
			else
				-- Classic accumulator mode: append to buffer
				M._accumulator:append(text)
			end
		end)
		else
			-- Direct insertion mode: replace any partial insertion range with the complete text.
			vim.schedule(function()
				local buf = vim.api.nvim_get_current_buf()
				vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

				if M._partial_range then
					-- Replace the tracked partial range with the final transcript
					local r = M._partial_range
					M._partial_range = nil
					local lines = vim.split(text, "\n")
					vim.api.nvim_buf_set_text(buf, r.sline, r.scol, r.eline, r.ecol, lines)
				else
					-- No partials were shown, insert at cursor like before
					local line = vim.api.nvim_win_get_cursor(0)[1] - 1
					local col = vim.api.nvim_win_get_cursor(0)[2]
					local lines = vim.split(text, "\n")
					if #lines == 1 then
						vim.api.nvim_buf_set_text(buf, line, col, line, col, { text })
					else
						vim.api.nvim_buf_set_lines(buf, line, line, false, { lines[1] })
						for i = 2, #lines do
							vim.api.nvim_buf_add_line(buf, lines[i], true)
						end
					end
				end
			end)
		end
	end)

	M._voice:on_partial(function(text)
		local accum_mode = M.config.accumulator and M.config.accumulator.mode
		if accum_enabled and M._accumulator and text ~= "" then
			if accum_mode == "scratchpad" then
				-- Scratchpad mode: partials are just appended for preview,
				-- iteration happens on final transcript
				vim.schedule(function()
					M._accumulator:append(text)
				end)
			else
				-- Classic accumulator mode: feed partials into the accumulator
				vim.schedule(function()
					M._accumulator:append(text)
				end)
			end
		else
			-- Direct insertion mode: show in sidebar
			vim.schedule(function()
				if text ~= "" then
					M._ensure_sidebar():set_partial(text)
				end
			end)
		end
	end)

	M._voice:on_status(function(state)
		M._state = state
		ui.set_state(state)
		vim.schedule(function()
			if state == "listening" then
				M._ensure_sidebar():set_state("listening")
			elseif state == "transcribing" then
				M._ensure_sidebar():set_state("transcribing")
			end
		end)
	end)

	M._voice:on_error(function(message)
		vim.schedule(function()
			vim.notify("[outloud] daemon error: " .. message, vim.log.levels.ERROR)
			local sb = M._ensure_sidebar()
			sb:set_status("daemon", "error")
			sb:add_error("daemon: " .. message)
		end)
	end)

	M._voice:start()
	sidebar:set_status("daemon", M._voice:is_running() and "up" or "error")
end

--- Tear everything down: daemon, STT server, and UI. Also runs on
--- VimLeavePre so quitting Neovim never strands a background process.
function M.stop()
	if M._voice then
		pcall(function()
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
		M._accumulator:dispose()
		M._accumulator = nil
	end

	M._state = "inactive"
	ui.set_state("inactive")
	M._listening = false
end

---@return string
function M.status()
	return ui.statusline()
end

--- Confirm the accumulated text: invoke the handler and apply the result.
function M.confirm_accumulator()
	if not M._accumulator then
		vim.notify("[outloud] accumulator not active", vim.log.levels.WARN)
		return
	end
	if not M._accumulator:has_text() then
		vim.notify("[outloud] accumulator is empty", vim.log.levels.WARN)
		return
	end
	M._accumulator:confirm(function(text)
		-- After handler completes, insert result at cursor
		local sb = M._ensure_sidebar()
		sb:begin_turn(text)
		M._accumulator:clear()
	end)
end

--- Cancel and discard the accumulated text.
function M.cancel_accumulator()
	if not M._accumulator then
		vim.notify("[outloud] accumulator not active", vim.log.levels.WARN)
		return
	end
	M._accumulator:clear()
	vim.notify("[outloud] accumulator cleared", vim.log.levels.INFO)
end

--- Clear the accumulation without cancelling.
function M.clear_accumulator()
	if not M._accumulator then
		vim.notify("[outloud] accumulator not active", vim.log.levels.WARN)
		return
	end
	M._accumulator:clear()
end

return M
