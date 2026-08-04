local Voice = require("lazyspeak.voice").Voice
local Sidebar = require("lazyspeak.sidebar").Sidebar
local ui = require("lazyspeak.ui")
local install = require("lazyspeak.install")

local M = {}

---@class lazyspeak.Config
---@field model { path: string, server_port: number, server_url?: string }
---@field audio { sample_rate: number, channels: number, vad_threshold: number, silence_duration_ms: number, max_duration_ms: number, partial_interval_ms: number }
---@field ui { sidebar_position: string, sidebar_width: number, sidebar_auto_open: boolean, statusline: boolean }
---@field keys { push_to_talk: string, cancel: string, sidebar: string }
---@field daemon_cmd? string

---@type lazyspeak.Config
M.defaults = {
	model = {
		hf_repo = install.HF_REPO,
		server_port = install.DEFAULT_PORT,
		-- server_url = "http://127.0.0.1:8674",  -- override to use external server
	},
	audio = {
		sample_rate = 16000,
		channels = 1,
		vad_threshold = 0.01,
		silence_duration_ms = 400,
		max_duration_ms = 30000,
		partial_interval_ms = 700,
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

---@type lazyspeak.Config
M.config = {}

---@type lazyspeak.Voice?
M._voice = nil

---@type lazyspeak.Sidebar?
M._sidebar = nil

---@type string
M._state = "inactive"

---@type boolean
M._listening = false

---@return lazyspeak.Sidebar
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
		group = vim.api.nvim_create_augroup("lazyspeak_shutdown", { clear = true }),
		desc = "lazyspeak: shut down daemon and STT server",
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
				vim.notify("[lazyspeak] waiting for daemon to start...", vim.log.levels.INFO)
				return
			end
			if M._listening then
				M._voice:stop_listening()
				M._listening = false
			else
				M._voice:start_listening()
				M._listening = true
			end
		end, { buffer = buf, desc = "lazyspeak: toggle recording" })

		-- <Esc> cancels and dismisses the UI
		vim.keymap.set("n", "<Esc>", function()
			if M._listening and M._voice then
				M._voice:cancel()
			end
			cleanup()
			M.dismiss()
		end, { buffer = buf, desc = "lazyspeak: close" })

		M._session_cleanup = cleanup
	end, { desc = "lazyspeak: open" })

	vim.keymap.set("n", keys.cancel, function()
		if M._voice and M._voice:is_running() then
			M._voice:cancel()
			M._listening = false
		end
	end, { desc = "lazyspeak: cancel" })

	vim.keymap.set("n", keys.sidebar, function()
		M._ensure_sidebar():toggle()
	end, { desc = "lazyspeak: toggle session sidebar" })
end

--- Build the environment variable table for the daemon process.
---@param model table the model config table
---@param audio table the audio config table
---@return table<string, string>
local function build_daemon_env(model, audio)
	local url = model.server_url or ("http://127.0.0.1:" .. model.server_port)
	return {
		LAZYSPEAK_STT_URL = url,
		LAZYSPEAK_VAD_THRESHOLD = tostring(audio.vad_threshold),
		LAZYSPEAK_SILENCE_MS = tostring(audio.silence_duration_ms),
		LAZYSPEAK_MAX_MS = tostring(audio.max_duration_ms),
		LAZYSPEAK_PARTIAL_MS = tostring(audio.partial_interval_ms),
	}
end

--- Start voice + UI, auto-launching llama-server if needed.
function M.start()
	if M._voice and M._voice:is_running() then
		return
	end

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

	-- If using the built-in server (no custom server_url), auto-start llama-server
	if not M.config.model.server_url then
		signal("stt", "starting")
		ui_state("starting_server")
		install.start_llama_server({
			port = M.config.model.server_port,
			hf_repo = M.config.model.hf_repo,
			on_phase = function(phase, detail)
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
			end,
		}, function()
			signal("stt", "up")
			ui_state("starting_daemon")
			M._start_pipeline()
			ui_state("ready")
		end)
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
	local daemon_env = build_daemon_env(M.config.model, M.config.audio)
	M._voice = Voice:new({ daemon_cmd = M.config.daemon_cmd, env = daemon_env })

	M._voice:on_transcript(function(text, duration_ms)
		M._state = "idle"
		ui.set_state("idle")
		M._listening = false
		vim.schedule(function()
			local sb = M._ensure_sidebar()
			sb:begin_turn(text)
			sb:set_state("idle")
		end)
		-- Pipe the transcript into the current buffer at the cursor position.
		vim.schedule(function()
			local buf = vim.api.nvim_get_current_buf()
			local line = vim.api.nvim_win_get_cursor(0)[1] - 1
			local col = vim.api.nvim_win_get_cursor(0)[2]
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			-- Insert the transcript at the cursor, splitting on newlines for multi-line text
			local lines = vim.split(text, "\n")
			if #lines == 1 then
				-- Single line: insert at cursor column
				local current = vim.api.nvim_buf_get_text(buf, line, col, line, col, {})[1]
				vim.api.nvim_buf_set_text(buf, line, col, line, col, { text })
			else
				-- Multi-line: replace current line and insert additional lines below
				vim.api.nvim_buf_set_lines(buf, line, line, false, { lines[1] })
				for i = 2, #lines do
					vim.api.nvim_buf_add_line(buf, lines[i], true)
				end
			end
		end)
	end)

	M._voice:on_partial(function(text)
		vim.schedule(function()
			if text ~= "" then
				M._ensure_sidebar():set_partial(text)
			end
		end)
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
			vim.notify("[lazyspeak] daemon error: " .. message, vim.log.levels.ERROR)
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
	install.stop_llama_server()

	if M._sidebar then
		M._sidebar:dispose()
		M._sidebar = nil
	end

	M._state = "inactive"
	ui.set_state("inactive")
	M._listening = false
end

---@return string
function M.status()
	return ui.statusline()
end

return M
