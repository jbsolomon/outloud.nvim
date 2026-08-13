local M = {}

local DEFAULT_PORT = 8674
local HEALTH_PATH = "/health"
local HF_REPO = "ggml-org/Voxtral-Mini-3B-2507-GGUF"

-- Whisper-server defaults
local WHISPER_DEFAULT_PORT = 8000
local WHISPER_HEALTH_PATH = "/"

--- Known whisper.cpp model names (from ggerganov/whisper.cpp repo).
--- These are downloaded directly, no HuggingFace probing needed.
local GG_WHISPER_MODELS = {
    ["tiny"] = "ggml-tiny.bin",
    ["tiny.en"] = "ggml-tiny.en.bin",
    ["tiny-q5_1"] = "ggml-tiny-q5_1.bin",
    ["tiny.en-q5_1"] = "ggml-tiny.en-q5_1.bin",
    ["tiny-q8_0"] = "ggml-tiny-q8_0.bin",
    ["base"] = "ggml-base.bin",
    ["base.en"] = "ggml-base.en.bin",
    ["base-q5_1"] = "ggml-base-q5_1.bin",
    ["base.en-q5_1"] = "ggml-base.en-q5_1.bin",
    ["base-q8_0"] = "ggml-base-q8_0.bin",
    ["small"] = "ggml-small.bin",
    ["small.en"] = "ggml-small.en.bin",
    ["small.en-tdrz"] = "ggml-small.en-tdrz.bin",
    ["small-q5_1"] = "ggml-small-q5_1.bin",
    ["small.en-q5_1"] = "ggml-small.en-q5_1.bin",
    ["small-q8_0"] = "ggml-small-q8_0.bin",
    ["medium"] = "ggml-medium.bin",
    ["medium.en"] = "ggml-medium.en.bin",
    ["medium-q5_0"] = "ggml-medium-q5_0.bin",
    ["medium.en-q5_0"] = "ggml-medium.en-q5_0.bin",
    ["medium-q8_0"] = "ggml-medium-q8_0.bin",
    ["large-v1"] = "ggml-large-v1.bin",
    ["large-v2"] = "ggml-large-v2.bin",
    ["large-v2-q5_0"] = "ggml-large-v2-q5_0.bin",
    ["large-v2-q8_0"] = "ggml-large-v2-q8_0.bin",
    ["large-v3"] = "ggml-large-v3.bin",
    ["large-v3-q5_0"] = "ggml-large-v3-q5_0.bin",
    ["large-v3-turbo"] = "ggml-large-v3-turbo.bin",
    ["large-v3-turbo-q5_0"] = "ggml-large-v3-turbo-q5_0.bin",
    ["large-v3-turbo-q8_0"] = "ggml-large-v3-turbo-q8_0.bin",
}

--local OTHER_WHISPER_MODELS = {
--    ['
--}

--- Canonical source for whisper.cpp models (not an arbitrary HF repo).
local WHISPER_MODEL_SRC = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
local WHISPER_MODEL_TDRZ_SRC = "https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/main"

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
		-- Cargo versions are quoted strings: version = "0.6.0"
		local v = line:match('^version%s*=%s*"([^"]+)"')
		if v then
			return v
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
	-- vim.system is async; wait for --version to complete (fast in practice).
	local ok, obj = pcall(vim.system, { "outloud", "--version" }, { text = true })
	if not ok or not obj then
		return nil
	end
	local res = obj:wait(5000)
	if res and res.code == 0 and res.stdout then
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
				local model_cfg = outloud.config.model or outloud.defaults.model or {}
				local model_label
				if model_cfg.download_url then
					model_label = "custom (download_url)"
				elseif model_cfg.filename then
					model_label = model_cfg.filename .. " (local)"
				else
					model_label = model_cfg.size or outloud.defaults.model.size
				end
				vim.notify(
					"[outloud] model will be auto-downloaded on first :OutloudStart via whisper-server (" .. model_label .. ")"
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
			local model_cfg = outloud.config.model or outloud.defaults.model or {}
			local model_label
			if model_cfg.download_url then
				model_label = "custom (download_url)"
			elseif model_cfg.filename then
				model_label = model_cfg.filename .. " (local)"
			else
				model_label = model_cfg.size or outloud.defaults.model.size
			end
			vim.notify(
				"[outloud] model will be auto-downloaded on first :OutloudStart via whisper-server (" .. model_label .. ")"
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

	-- Already managed, or a start is in flight (probe/download window).
	if M._llama_job_id or M._llama_starting then
		if M._llama_job_id and on_ready then
			on_ready()
		end
		return
	end
	M._llama_starting = true

	-- Clear the in-flight flag on any terminal outcome (ready or error).
	local raw_phase = on_phase
	on_phase = function(phase, detail)
		if phase == "error" then
			M._llama_starting = false
		end
		raw_phase(phase, detail)
	end
	if on_ready then
		local raw_ready = on_ready
		on_ready = function()
			M._llama_starting = false
			raw_ready()
		end
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
			-- Kill the stalled/failed process before dropping the handle;
			-- otherwise it is orphaned and stop_llama_server() can't reach it.
			if M._llama_job_id then
				pcall(vim.fn.jobstop, M._llama_job_id)
				M._llama_job_id = nil
			end
			on_phase("error", message)
		end
	end

	local job_id = vim.fn.jobstart({
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
			if not finished then
				local diag = #output_buf > 0 and ("\nLast output:\n" .. table.concat(output_buf, "\n")) or ""
				finish(false, ("llama-server exited with code %d%s"):format(code, diag))
			elseif code ~= 0 then
				vim.schedule(function()
					vim.notify("[outloud] llama-server exited with code " .. code, vim.log.levels.WARN)
				end)
			end
		end,
	})

	-- If on_exit fired synchronously (immediate crash), finished is now true
	-- and M._llama_job_id was already cleared. Don't overwrite with stale ID.
	if finished then
		return
	end

	M._llama_job_id = job_id

	if M._llama_job_id <= 0 then
		vim.notify("[outloud] failed to start llama-server", vim.log.levels.ERROR)
		M._llama_job_id = nil
		on_phase("error", "failed to spawn llama-server")
		return
	end

	timer:start(
		500,
		1000,
		vim.schedule_wrap(function()
			if finished then
				return
			end
	if M._llama_job_id == nil then
			return finish(false, "llama-server exited before becoming ready" .. (#output_buf > 0 and ("\nLast output:\n" .. table.concat(output_buf, "\n")) or ""))
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
	M._llama_starting = false
	if M._llama_job_id then
		vim.fn.jobstop(M._llama_job_id)
		M._llama_job_id = nil
	end
end

-- whisper-server process management

---@type number?
M._whisper_job_id = nil

--- Resolve the data directory for outloud artifacts.
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

--- Resolve the whisper model filename from the model name.
--- Uses the known model list from whisper.cpp, so no HuggingFace probing is needed.
---@param model_name string the model name (e.g. "medium", "large-v3-turbo")
---@return string filename, or nil if model name is unknown
local function resolve_model_filename(model_name)
	return GG_WHISPER_MODELS[model_name]
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
--- Checks: explicit path, then data_dir/models (using resolved filename), then nil.
---@param model_path? string
---@param filename string
---@return string|nil
local function find_whisper_model(model_path, filename)
	if model_path and vim.fn.filereadable(model_path) == 1 then
		return model_path
	end
	local candidate = data_dir() .. "/models/" .. filename
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
		-- vim.system callbacks run in a fast-event context; on_done chains into
		-- jobstart/API calls downstream, so it must leave the fast event first.
		vim.schedule(function()
			if res.code == 0 then
				vim.fn.execute("chmod +x " .. dest)
				on_done(true)
			else
				on_done(false, "failed to download whisper-server (curl exit " .. res.code .. ")")
			end
		end)
	end)
end

--- Download a whisper model from the canonical whisper.cpp source.
--- Uses a HEAD request to get Content-Length, then polls file size via uv.fs_stat.
---@param filename string the remote filename (e.g. "ggml-medium.bin")
---@param download_url? string optional direct download URL override
---@param on_phase fun(phase: string, detail?: string)
---@param on_done fun(ok: boolean, detail?: string)
local function download_whisper_model(filename, download_url, on_phase, on_done)
	local model_dir = data_dir() .. "/models"
	vim.fn.mkdir(model_dir, "p")
	local dest = model_dir .. "/" .. filename

	-- Determine download URL: explicit URL > canonical source
	local url
	if download_url then
		url = download_url
	elseif filename:find("tdrz") then
		url = WHISPER_MODEL_TDRZ_SRC .. "/" .. filename
	else
		url = WHISPER_MODEL_SRC .. "/" .. filename
	end

	vim.notify("[outloud] downloading whisper model (" .. filename .. ")...", vim.log.levels.INFO)

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
			-- Fast-event context: filereadable/on_phase/on_done all touch the API
			-- or spawn jobs downstream, so schedule the whole completion path.
			vim.schedule(function()
				if res.code == 0 and vim.fn.filereadable(dest) == 1 then
					on_phase("loading")
					on_done(true)
				else
					vim.notify(
						"[outloud] model download failed (curl exit " .. res.code .. ")",
						vim.log.levels.ERROR
					)
					on_done(false, "failed to download model (curl exit " .. res.code .. ")")
				end
			end)
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
---@param opts? { port?: number, model_name?: string, model_path?: string, model_filename?: string, download_url?: string, on_phase?: fun(phase: string, detail?: string), stall_timeout_ms?: number }
---@param on_ready? fun()
function M.start_whisper_server(opts, on_ready)
	opts = opts or {}
	local port = opts.port or WHISPER_DEFAULT_PORT
	local model_name = opts.model_name or "large-v3-turbo-q8_0"
	local model_path = opts.model_path
	local model_filename = opts.model_filename
	local download_url = opts.download_url
	local on_phase = opts.on_phase or function() end
	local stall_ms = opts.stall_timeout_ms or DEFAULT_STALL_MS

	-- Already managed, or a start is in flight (probe/download window).
	if M._whisper_job_id or M._whisper_starting then
		if M._whisper_job_id and on_ready then
			on_ready()
		end
		return
	end
	M._whisper_starting = true

	-- Clear the in-flight flag on any terminal outcome (ready or error).
	local raw_phase = on_phase
	on_phase = function(phase, detail)
		if phase == "error" then
			M._whisper_starting = false
		end
		raw_phase(phase, detail)
	end
	if on_ready then
		local raw_ready = on_ready
		on_ready = function()
			M._whisper_starting = false
			raw_ready()
		end
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
				M._ensure_model_and_start(bin, port, model_name, model_path, model_filename, download_url, on_phase, stall_ms, on_ready)
			end)
		else
			M._ensure_model_and_start(bin, port, model_name, model_path, model_filename, download_url, on_phase, stall_ms, on_ready)
		end
	end)
end

--- Ensure model exists, then spawn whisper-server.
---
--- Priority:
--- 1. model_path → explicit path, load directly
--- 2. model_filename → user-specified local filename, must exist in cache (error if missing)
--- 3. model_name → named model from WHISPER_MODELS, download from canonical source if missing
M._ensure_model_and_start = function(bin, port, model_name, model_path, model_filename, download_url, on_phase, stall_ms, on_ready)
	-- 1. Explicit path: load directly
	if model_path and vim.fn.filereadable(model_path) == 1 then
		M._spawn_whisper_server(bin, model_path, port, on_phase, stall_ms, on_ready)
		return
	end

	-- 2. User-specified filename: must exist locally, don't download
	if model_filename then
		local candidate = data_dir() .. "/models/" .. model_filename
		if vim.fn.filereadable(candidate) == 1 then
			M._spawn_whisper_server(bin, candidate, port, on_phase, stall_ms, on_ready)
			return
		end
		on_phase("error", ("model file '%s' not found in %s/models/ — place it there or use model.path"):format(model_filename, data_dir()))
		return
	end

	-- 3. Named model: look up in known list, download if missing
	local resolved = resolve_model_filename(model_name)
	if not resolved then
		-- List available models for the error message
		local available = {}
		for name, _ in pairs(GG_WHISPER_MODELS) do
			table.insert(available, name)
		end
		table.sort(available)
		on_phase("error", ("unknown model '%s'. Available: %s"):format(model_name, table.concat(available, ", ")))
		return
	end

	-- Check local cache
	local model = find_whisper_model(nil, resolved)
	if model then
		M._spawn_whisper_server(bin, model, port, on_phase, stall_ms, on_ready)
		return
	end

	-- Model not cached: download it from canonical source
	on_phase("downloading", "downloading model")
	download_whisper_model(resolved, download_url, on_phase, function(ok, detail)
		if not ok then
			on_phase("error", detail or "failed to download model")
			return
		end
		model = find_whisper_model(nil, resolved)
		if not model then
			on_phase("error", "model download succeeded but file not found")
			return
		end
		M._spawn_whisper_server(bin, model, port, on_phase, stall_ms, on_ready)
	end)
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
			-- Kill the stalled/failed process before dropping the handle;
			-- otherwise it is orphaned and stop_whisper_server() can't reach it.
			if M._whisper_job_id then
				pcall(vim.fn.jobstop, M._whisper_job_id)
				M._whisper_job_id = nil
			end
			on_phase("error", message)
		end
	end

	local job_id = vim.fn.jobstart({
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
				local diag = #output_buf > 0 and ("\nLast output:\n" .. table.concat(output_buf, "\n")) or ""
				finish(false, ("whisper-server exited with code %d%s"):format(code, diag))
			elseif code ~= 0 then
				vim.schedule(function()
					vim.notify("[outloud] whisper-server exited with code " .. code, vim.log.levels.WARN)
				end)
			end
		end,
	})

	-- If on_exit fired synchronously (immediate crash), finished is now true
	-- and M._whisper_job_id was already cleared. Don't overwrite with stale ID.
	if finished then
		return
	end

	M._whisper_job_id = job_id

	if M._whisper_job_id and M._whisper_job_id <= 0 then
		vim.notify("[outloud] failed to start whisper-server", vim.log.levels.ERROR)
		M._whisper_job_id = nil
		on_phase("error", "failed to spawn whisper-server")
		return
	end

	timer:start(500, 1000, vim.schedule_wrap(function()
		if finished then
			return
		end
	if M._whisper_job_id == nil then
			return finish(false, "whisper-server exited before becoming ready" .. (#output_buf > 0 and ("\nLast output:\n" .. table.concat(output_buf, "\n")) or ""))
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
	M._whisper_starting = false
	if M._whisper_job_id then
		vim.fn.jobstop(M._whisper_job_id)
		M._whisper_job_id = nil
	end
end

M.HF_REPO = HF_REPO
M.DEFAULT_PORT = DEFAULT_PORT
M.WHISPER_DEFAULT_PORT = WHISPER_DEFAULT_PORT
M.WHISPER_MODELS = GG_WHISPER_MODELS
M.resolve_model_filename = resolve_model_filename

-- Daemon build lifecycle (called from init.lua's M.start()).
M.needs_rebuild = needs_rebuild
M.build_daemon = build_daemon

return M
