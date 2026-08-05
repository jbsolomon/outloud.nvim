local M = {}

local DEFAULT_PORT = 8674
local HEALTH_PATH = "/health"
local HF_REPO = "ggml-org/Voxtral-Mini-3B-2507-GGUF"

-- Whisper-server defaults
local WHISPER_DEFAULT_PORT = 8000
local WHISPER_HEALTH_PATH = "/"
local WHISPER_MODEL_SIZES = {
    tiny = "ggml-tiny.bin",
    base = "ggml-base.bin",
    small = "ggml-small.bin",
    medium = "ggml-medium.bin",
    large = "ggml-large.bin",
}
local WHISPER_MODEL_REPO = "ggerganov/whisper.cpp"

--- Resolve the plugin root directory.
---@return string
local function plugin_dir()
	local src = debug.getinfo(1, "S").source:match("@(.*/)")
	if src then
		return src:gsub("/lua/outloud/$", "")
	end
	return ""
end

--- Read the expected daemon version from Cargo.toml.
---@return string|nil
local function cargo_version()
	local toml_path = plugin_dir() .. "/Cargo.toml"
	if vim.fn.filereadable(toml_path) ~= 1 then
		return nil
	end
	for line in io.lines(toml_path) do
		local v = line:match("^version%s*=%s*%[(.+)%]")
		if v then
			return v:match("%s*(.-)%s*")
		end
	end
	return nil
end

--- Run `outloud --version` and return the output.
---@return string|nil
local function daemon_version()
	if vim.fn.executable("outloud") ~= 1 then
		return nil
	end
	local ok, res = pcall(vim.system, { "outloud", "--version" }, { text = true })
	if ok and res and res.code == 0 then
		return (res.stdout:gsub("%s+", ""))
	end
	return nil
end

--- Check if the daemon needs rebuilding.
---@return boolean
local function needs_rebuild()
	local expected = cargo_version()
	if not expected then
		-- No Cargo.toml found, assume no rebuild needed
		return false
	end
	local actual = daemon_version()
	if not actual then
		-- Daemon not installed, needs build
		return true
	end
	return expected ~= actual
end

--- Build the daemon binary.
---@param cb fun(ok: boolean)
local function build_daemon(cb)
	local pdir = plugin_dir()
	if not pdir or vim.fn.isdirectory(pdir .. "/crates") ~= 1 then
		vim.notify(
			"[outloud] could not find crates/ dir — run `cargo install --path crates/outloud` manually",
			vim.log.levels.WARN
		)
		cb(false)
		return
	end

	vim.notify("[outloud] building daemon binary...")
	vim.fn.jobstart({ "cargo", "install", "--path", pdir .. "/crates/outloud" }, {
		on_exit = function(_, code, _)
			vim.schedule(function()
				if code == 0 then
					vim.notify("[outloud] daemon binary installed")
					cb(true)
				else
					vim.notify(
						"[outloud] daemon build failed — run `cargo install --path crates/outloud` manually",
						vim.log.levels.ERROR
					)
					cb(false)
				end
			end)
		end,
	})
end

--- Install daemon binary (model is auto-downloaded by llama-server via -hf).
function M.run()
	if needs_rebuild() then
		build_daemon(function(ok)
			if not ok then
				return
			end

			-- Show backend-appropriate model info
			local outloud = require("outloud")
			local cfg = outloud.config.backend or outloud.defaults.backend or "whisper"
			if cfg == "openai" then
				vim.notify(
					"[outloud] model will be auto-downloaded on first :OutloudStart via llama-server -hf " .. HF_REPO
				)
			else
				vim.notify(
					"[outloud] model will be auto-downloaded on first :OutloudStart via whisper-server (" .. (outloud.config.model and outloud.config.model.size or outloud.defaults.model.size) .. ")"
				)
			end
		end)
	else
		vim.notify("[outloud] daemon binary already installed")

		-- Show backend-appropriate model info
		local outloud = require("outloud")
		local cfg = outloud.config.backend or outloud.defaults.backend or "whisper"
		if cfg == "openai" then
			vim.notify(
				"[outloud] model will be auto-downloaded on first :OutloudStart via llama-server -hf " .. HF_REPO
			)
		else
			vim.notify(
				"[outloud] model will be auto-downloaded on first :OutloudStart via whisper-server (" .. (outloud.config.model and outloud.config.model.size or outloud.defaults.model.size) .. ")"
			)
		end
	end
end

-- llama-server process management

---@type number?
M._llama_job_id = nil

--- How long the server may make no observable progress before we give up.
--- This is an *idle* timeout, not a total one: a multi-gigabyte first-run
--- download may legitimately take far longer than any fixed deadline, so what
--- matters is whether bytes are still moving.
local DEFAULT_STALL_MS = 120000

--- Probe the server's health endpoint without blocking the editor.
---
--- The old implementation used `io.popen("curl ...")`, which blocks Neovim's
--- main loop for as long as curl runs. A loading `llama-server` accepts the
--- connection before it can answer, and curl without `--max-time` waits
--- indefinitely on that, freezing the whole session. This is async and doubly
--- bounded by curl's own timeouts.
---@param port number
---@param cb fun(ok: boolean)
function M.probe_server(port, cb)
	local url = string.format("http://127.0.0.1:%d%s", port, HEALTH_PATH)
	local ok, err = pcall(vim.system, {
		"curl",
		"-sf",
		"--connect-timeout",
		"1",
		"--max-time",
		"2",
		url,
	}, { text = true }, function(res)
		vim.schedule(function()
			cb(res.code == 0)
		end)
	end)
	if not ok then
		vim.schedule(function()
			vim.notify("[outloud] health probe failed to spawn: " .. tostring(err), vim.log.levels.WARN)
			cb(false)
		end)
	end
end

--- Start llama-server with the Voxtral model if not already running.
--- Uses -hf to auto-download model + mmproj from HuggingFace on first run.
---
--- Fully asynchronous: nothing here blocks the main loop, and readiness is
--- reported through `on_ready`. Progress is reported through `on_phase` so the
--- UI can distinguish a long download from a stuck server.
---@param opts? { port?: number, hf_repo?: string, on_phase?: fun(phase: string, detail?: string), stall_timeout_ms?: number }
---@param on_ready? fun() called once the server is healthy
function M.start_llama_server(opts, on_ready)
	opts = opts or {}
	local port = opts.port or DEFAULT_PORT
	local hf_repo = opts.hf_repo or HF_REPO
	local on_phase = opts.on_phase or function() end
	local stall_ms = opts.stall_timeout_ms or DEFAULT_STALL_MS

	-- Already managed by us
	if M._llama_job_id then
		if on_ready then
			on_ready()
		end
		return
	end

	-- Something else may already be listening on the port.
	M.probe_server(port, function(alive)
		if alive then
			vim.notify("[outloud] llama-server already running on port " .. port)
			on_phase("ready")
			if on_ready then
				on_ready()
			end
			return
		end
		M._spawn_llama_server(port, hf_repo, on_phase, stall_ms, on_ready)
	end)
end

--- Internal: spawn llama-server and watch it until healthy or stalled.
---@param port number
---@param hf_repo string
---@param on_phase fun(phase: string, detail?: string)
---@param stall_ms number
---@param on_ready? fun()
function M._spawn_llama_server(port, hf_repo, on_phase, stall_ms, on_ready)
	if vim.fn.executable("llama-server") ~= 1 then
		vim.notify(
			"[outloud] llama-server not found — install llama.cpp (brew install llama.cpp)",
			vim.log.levels.ERROR
		)
		on_phase("error", "llama-server not installed")
		return
	end

	vim.notify("[outloud] starting llama-server on port " .. port .. " (model: " .. hf_repo .. ")...")

	local phase = "starting"
	local last_progress = vim.uv.now()
	local output_buf = {}

	--- Classify a line of server output and reset the stall watchdog. Any
	--- output at all counts as progress, which is what lets a slow download
	--- run as long as it needs without tripping the timeout.
	---@param line string
	local function observe(line)
		last_progress = vim.uv.now()
		output_buf[#output_buf + 1] = line
		if #output_buf > 20 then table.remove(output_buf, 1) end
		local pct = line:match("(%d?%d?%d)%%")
		if phase ~= "loading" and pct then
			phase = "downloading"
			on_phase("downloading", pct .. "%")
		elseif line:match("loading model") or line:match("llama_model_loader") or line:match("load_tensors") then
			if phase ~= "loading" then
				phase = "loading"
				on_phase("loading")
			end
		end
	end

	local function drain(data)
		for _, line in ipairs(data or {}) do
			if line ~= "" then
				observe(line)
			end
		end
	end

	M._llama_job_id = vim.fn.jobstart({
		"llama-server",
		"-hf",
		hf_repo,
		"--port",
		tostring(port),
	}, {
		on_stdout = function(_, data, _)
			drain(data)
		end,
		on_stderr = function(_, data, _)
			drain(data)
		end,
		on_exit = function(_, code, _)
			M._llama_job_id = nil
			if code ~= 0 then
				vim.schedule(function()
					vim.notify("[outloud] llama-server exited with code " .. code, vim.log.levels.WARN)
				end)
			end
		end,
	})

	if M._llama_job_id <= 0 then
		vim.notify("[outloud] failed to start llama-server", vim.log.levels.ERROR)
		M._llama_job_id = nil
		on_phase("error", "failed to spawn llama-server")
		return
	end

	local timer = vim.uv.new_timer()
	local finished = false
	local in_flight = false

	---@param ok boolean
	---@param message? string
	local function finish(ok, message)
		if finished then
			return
		end
		finished = true
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		if ok then
			vim.notify("[outloud] llama-server ready")
			on_phase("ready")
			if on_ready then
				on_ready()
			end
		else
			vim.notify("[outloud] " .. (message or "llama-server failed"), vim.log.levels.ERROR)
			on_phase("error", message)
		end
	end

	timer:start(
		500,
		1000,
		vim.schedule_wrap(function()
			if finished then
				return
			end
			if M._llama_job_id == nil then
				return finish(false, "llama-server exited before becoming ready")
			end
		if vim.uv.now() - last_progress > stall_ms then
			local diag = #output_buf > 0 and ("\nLast output:\n" .. table.concat(output_buf, "\n")) or "\nNo output captured."
			return finish(
				false,
				("llama-server (job %d) made no progress for %ds — check memory pressure.%s"):format(
					M._llama_job_id or -1, math.floor(stall_ms / 1000), diag
				)
			)
		end
			-- One probe at a time; a slow probe must not queue up behind itself.
			if in_flight then
				return
			end
			in_flight = true
			M.probe_server(port, function(alive)
				in_flight = false
				if alive then
					last_progress = vim.uv.now()
					finish(true)
				end
			end)
		end)
	)
end

--- Stop the managed llama-server process.
function M.stop_llama_server()
	if M._llama_job_id then
		vim.fn.jobstop(M._llama_job_id)
		M._llama_job_id = nil
	end
end

-- whisper-server process management

---@type number?
M._whisper_job_id = nil

--- Get the data directory for outloud artifacts.
---@return string
local function data_dir()
	local base = vim.env.XDG_DATA_HOME
	if not base or base == "" then
		base = vim.env.LOCALAPPDATA or (vim.env.HOME .. "/.local/share")
	end
	local d = base .. "/outloud"
	vim.fn.mkdir(d, "p")
	return d
end

--- Resolve the whisper-server binary path.
--- Checks: explicit path, then data_dir/bin, then PATH.
---@return string|nil
local function find_whisper_server()
	-- Check PATH first
	if vim.fn.executable("whisper-server") == 1 then
		return "whisper-server"
	end
	-- Check data dir
	local candidate = data_dir() .. "/bin/whisper-server"
	if vim.fn.filereadable(candidate) == 1 then
		return candidate
	end
	return nil
end

--- Resolve the whisper model path.
--- Checks: explicit path, then data_dir/models, then nil.
---@param model_size string
---@param model_path? string
---@return string|nil
local function find_whisper_model(model_size, model_path)
	if model_path and vim.fn.filereadable(model_path) == 1 then
		return model_path
	end
	local fname = WHISPER_MODEL_SIZES[model_size] or WHISPER_MODEL_SIZES.medium
	local candidate = data_dir() .. "/models/" .. fname
	if vim.fn.filereadable(candidate) == 1 then
		return candidate
	end
	return nil
end

--- Download the whisper-server binary for the current platform.
---@param on_done fun(ok: boolean, detail?: string)
local function download_whisper_server(on_done)
	local os_name = vim.uv.os_uname()
	local sysname = os_name and os_name.sysname or "Unknown"
	local platform = sysname:lower()

	local bin_dir = data_dir() .. "/bin"
	vim.fn.mkdir(bin_dir, "p")
	local dest = bin_dir .. "/whisper-server"

	-- Build download URL from GitHub releases
	local arch = vim.uv.os_uname() and vim.uv.os_uname().machine or "x86_64"
	local url

	if platform:find("darwin") then
		if arch:find("arm") or arch:find("aarch") then
			url = "https://github.com/fstirl/whisper-server/releases/latest/download/whisper-server-darwin-arm64"
		else
			url = "https://github.com/fstirl/whisper-server/releases/latest/download/whisper-server-darwin-amd64"
		end
	elseif platform:find("linux") then
		if arch:find("arm") or arch:find("aarch") then
			url = "https://github.com/fstirl/whisper-server/releases/latest/download/whisper-server-linux-arm64"
		else
			url = "https://github.com/fstirl/whisper-server/releases/latest/download/whisper-server-linux-amd64"
		end
	else
		on_done(false, "unsupported platform: " .. sysname)
		return
	end

	vim.notify("[outloud] downloading whisper-server...", vim.log.levels.INFO)

	vim.system({
		"curl",
		"-fSL",
		"--output",
		dest,
		url,
	}, {}, function(res)
		if res.code == 0 then
			vim.fn.execute("chmod +x " .. dest)
			on_done(true)
		else
			on_done(false, "failed to download whisper-server (curl exit " .. res.code .. ")")
		end
	end)
end

--- Download a whisper model from HuggingFace with progress reporting.
--- Uses a HEAD request to get Content-Length, then polls file size via uv.fs_stat.
---@param model_size string
---@param on_phase fun(phase: string, detail?: string)
---@param on_done fun(ok: boolean, detail?: string)
local function download_whisper_model(model_size, on_phase, on_done)
	local fname = WHISPER_MODEL_SIZES[model_size] or WHISPER_MODEL_SIZES.medium
	local model_dir = data_dir() .. "/models"
	vim.fn.mkdir(model_dir, "p")
	local dest = model_dir .. "/" .. fname

	-- HuggingFace direct download URL
	local url = "https://huggingface.co/" .. WHISPER_MODEL_REPO .. "/resolve/main/" .. fname

	vim.notify("[outloud] downloading whisper model (" .. model_size .. ")...", vim.log.levels.INFO)

	on_phase("downloading", "connecting...")

	-- Step 1: HEAD request to get Content-Length
	vim.system({
		"curl",
		"-sIL",
		url,
	}, { text = true }, function(res)
		local total_bytes = nil
		if res.code == 0 then
			for line in res.stdout:gsub("\r", ""):gmatch("[^\n]+") do
				local val = line:match("^Content-Length%s*:%s*(%d+)")
				if val then
					total_bytes = tonumber(val)
					break
				end
			end
		else
			vim.schedule(function()
				vim.notify(
					"[outloud] HEAD request failed (curl exit " .. res.code .. "), progress will show size without total",
					vim.log.levels.WARN
				)
			end)
		end

		-- Step 2: Start the actual download
		local timer = vim.uv.new_timer()
		local started = vim.uv.now()

		timer:start(0, 500, function()
			local stat = vim.uv.fs_stat(dest)
			if stat and stat.size then
				local mb = math.floor(stat.size / 1048576)
				local total_mb = total_bytes and math.floor(total_bytes / 1048576) or nil
				local elapsed = math.floor((vim.uv.now() - started) / 1000)
				local speed = elapsed > 0 and (stat.size / elapsed / 1048576) or 0
				local detail
				if total_mb then
					local pct = math.floor((stat.size / total_bytes) * 100)
					detail = string.format("%d%% (%d/%d MB, %.1f MB/s)", pct, mb, total_mb, speed)
				else
					detail = string.format("%d MB, %.1f MB/s", mb, speed)
				end
				on_phase("downloading", detail)
			end
		end)

		vim.system({
			"curl",
			"-fSL",
			"--output",
			dest,
			url,
		}, {}, function(res)
			timer:stop()
			timer:close()
			if res.code == 0 and vim.fn.filereadable(dest) == 1 then
				on_phase("loading")
				on_done(true)
			else
				vim.schedule(function()
					vim.notify(
						"[outloud] model download failed (curl exit " .. res.code .. ")",
						vim.log.levels.ERROR
					)
				end)
				on_done(false, "failed to download model (curl exit " .. res.code .. ")")
			end
		end)
	end)
end

--- Probe whisper-server health.
---@param port number
---@param cb fun(ok: boolean)
function M.probe_whisper_server(port, cb)
	local url = string.format("http://127.0.0.1:%d%s", port, WHISPER_HEALTH_PATH)
	local ok, err = pcall(vim.system, {
		"curl",
		"-sf",
		"--connect-timeout",
		"1",
		"--max-time",
		"2",
		url,
	}, { text = true }, function(res)
		vim.schedule(function()
			cb(res.code == 0)
		end)
	end)
	if not ok then
		vim.schedule(function()
			vim.notify("[outloud] whisper health probe failed: " .. tostring(err), vim.log.levels.WARN)
			cb(false)
		end)
	end
end

--- Start whisper-server with the specified model.
--- Auto-downloads binary and model if missing.
---@param opts? { port?: number, model_size?: string, model_path?: string, on_phase?: fun(phase: string, detail?: string), stall_timeout_ms?: number }
---@param on_ready? fun()
function M.start_whisper_server(opts, on_ready)
	opts = opts or {}
	local port = opts.port or WHISPER_DEFAULT_PORT
	local model_size = opts.model_size or "medium"
	local model_path = opts.model_path
	local on_phase = opts.on_phase or function() end
	local stall_ms = opts.stall_timeout_ms or DEFAULT_STALL_MS

	-- Already managed
	if M._whisper_job_id then
		if on_ready then
			on_ready()
		end
		return
	end

	-- Check if something else is already listening
	M.probe_whisper_server(port, function(alive)
		if alive then
			vim.notify("[outloud] whisper-server already running on port " .. port)
			on_phase("ready")
			if on_ready then
				on_ready()
			end
			return
		end

		-- Check for binary
		local bin = find_whisper_server()
		if not bin then
			on_phase("downloading", "downloading whisper-server")
			download_whisper_server(function(ok, detail)
				if not ok then
					on_phase("error", detail or "failed to download whisper-server")
					return
				end
				bin = find_whisper_server()
				M._ensure_model_and_start(bin, port, model_size, model_path, on_phase, stall_ms, on_ready)
			end)
		else
			M._ensure_model_and_start(bin, port, model_size, model_path, on_phase, stall_ms, on_ready)
		end
	end)
end

--- Ensure model exists, then spawn whisper-server.
M._ensure_model_and_start = function(bin, port, model_size, model_path, on_phase, stall_ms, on_ready)
	local model = find_whisper_model(model_size, model_path)
	if not model then
		on_phase("downloading", "downloading model (" .. model_size .. ")")
		download_whisper_model(model_size, on_phase, function(ok, detail)
			if not ok then
				on_phase("error", detail or "failed to download model")
				return
			end
			model = find_whisper_model(model_size, model_path)
			if not model then
				on_phase("error", "model download succeeded but file not found")
				return
			end
			M._spawn_whisper_server(bin, model, port, on_phase, stall_ms, on_ready)
		end)
	else
		M._spawn_whisper_server(bin, model, port, on_phase, stall_ms, on_ready)
	end
end

--- Spawn whisper-server and wait for it to become healthy.
M._spawn_whisper_server = function(bin, model, port, on_phase, stall_ms, on_ready)
	vim.notify("[outloud] starting whisper-server on port " .. port .. " (model: " .. model .. ")...")

	local phase = "starting"
	local last_progress = vim.uv.now()
	local output_buf = {}

	local function observe(line)
		last_progress = vim.uv.now()
		output_buf[#output_buf + 1] = line
		if #output_buf > 20 then table.remove(output_buf, 1) end
		if line:match("loading model") or line:match("ggml") or line:match("whisper") then
			if phase ~= "loading" then
				phase = "loading"
				on_phase("loading")
			end
		end
	end

	local function drain(data)
		for _, line in ipairs(data or {}) do
			if line ~= "" then
				observe(line)
			end
		end
	end

	M._whisper_job_id = vim.fn.jobstart({
		bin,
		"--model",
		model,
		"--port",
		tostring(port),
	}, {
		on_stdout = function(_, data, _) drain(data) end,
		on_stderr = function(_, data, _) drain(data) end,
		on_exit = function(_, code, _)
			M._whisper_job_id = nil
			if not finished then
				finish(false, "whisper-server exited with code " .. code)
			elseif code ~= 0 then
				vim.schedule(function()
					vim.notify("[outloud] whisper-server exited with code " .. code, vim.log.levels.WARN)
				end)
			end
		end,
	})

	if M._whisper_job_id and M._whisper_job_id <= 0 then
		vim.notify("[outloud] failed to start whisper-server", vim.log.levels.ERROR)
		M._whisper_job_id = nil
		on_phase("error", "failed to spawn whisper-server")
		return
	end

	local timer = vim.uv.new_timer()
	local finished = false
	local in_flight = false

	local function finish(ok, message)
		if finished then
			return
		end
		finished = true
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		if ok then
			vim.notify("[outloud] whisper-server ready")
			on_phase("ready")
			if on_ready then
				on_ready()
			end
		else
			vim.notify("[outloud] " .. (message or "whisper-server failed"), vim.log.levels.ERROR)
			on_phase("error", message)
		end
	end

	timer:start(500, 1000, vim.schedule_wrap(function()
		if finished then
			return
		end
		if M._whisper_job_id == nil then
			return finish(false, "whisper-server exited before becoming ready")
		end
		if vim.uv.now() - last_progress > stall_ms then
			local diag = #output_buf > 0 and ("\nLast output:\n" .. table.concat(output_buf, "\n")) or "\nNo output captured."
			return finish(false, ("whisper-server (job %d) made no progress for %ds.%s"):format(M._whisper_job_id or -1, math.floor(stall_ms / 1000), diag))
		end
		if in_flight then
			return
		end
		in_flight = true
		M.probe_whisper_server(port, function(alive)
			in_flight = false
			if alive then
				last_progress = vim.uv.now()
				finish(true)
			end
		end)
	end))
end

--- Stop the managed whisper-server process.
function M.stop_whisper_server()
	if M._whisper_job_id then
		vim.fn.jobstop(M._whisper_job_id)
		M._whisper_job_id = nil
	end
end

M.HF_REPO = HF_REPO
M.DEFAULT_PORT = DEFAULT_PORT
M.WHISPER_DEFAULT_PORT = WHISPER_DEFAULT_PORT

return M
