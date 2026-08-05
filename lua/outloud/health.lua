local M = {}

-- Whisper model sizes mapped to filenames (mirrors install.lua)
local WHISPER_MODEL_SIZES = {
    tiny = "ggml-tiny.bin",
    base = "ggml-base.bin",
    small = "ggml-small.bin",
    medium = "ggml-medium.bin",
    large = "ggml-large.bin",
}

--- Resolve the data directory for outloud artifacts.
local function data_dir()
    local base = vim.fn.expand("$XDG_DATA_HOME")
    if base == "" or base == "v:null" then
        base = vim.fn.expand("~/.local/share")
    end
    return base .. "/outloud"
end

--- Format a file size in human-readable units.
local function fmt_size(bytes)
    if bytes >= 1073741824 then
        return string.format("%.1f GB", bytes / 1073741824)
    elseif bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

--- Format a unix timestamp as a readable date.
local function fmt_date(ts)
    if ts then
        return os.date("%Y-%m-%d %H:%M:%S", ts)
    end
    return "unknown"
end

--- Probe a server's health endpoint synchronously.
--- Returns true if the server responds, false otherwise.
local function probe_server_sync(port, health_path)
    local url = string.format("http://127.0.0.1:%d%s", port, health_path or "/")
    local ok, res = pcall(vim.fn.system, {
        "curl",
        "-sf",
        "--connect-timeout",
        "1",
        "--max-time",
        "2",
        url,
    })
    return ok and res == ""
end

--- Report file info (size, modification date) for a model path.
local function report_model_file(path, label)
    if vim.fn.filereadable(path) == 1 then
        local stat = vim.uv.fs_stat(path)
        local size = stat and stat.size or 0
        local mtime = stat and stat.mtime and stat.mtime.sec or 0
        vim.health.ok(
            string.format(
                "%s found (%s, modified %s)",
                label or path,
                fmt_size(size),
                fmt_date(mtime)
            )
        )
    else
        vim.health.warn(
            string.format("%s not found: %s", label or "model", path),
            { "Will be auto-downloaded on first :OutloudStart" }
        )
    end
end

function M.check()
	vim.health.start("outloud")

	-- Daemon binary
	if vim.fn.executable("outloud") == 1 then
		vim.health.ok("daemon binary found in PATH")
	else
		vim.health.warn("daemon binary not in PATH", {
			"Run: cargo install --path crates/outloud",
			"Or: just install",
		})
	end

	-- STT server (depends on backend)
	local ok, outloud = pcall(require, "outloud")
	local backend, model_cfg
	if ok and outloud.config then
		backend = outloud.config.backend or "whisper"
		model_cfg = outloud.config.model or {}
	else
		backend = "whisper"
		model_cfg = {}
	end

	if backend == "whisper" then
		if vim.fn.executable("whisper-server") == 1 then
			vim.health.ok("whisper-server found")
		else
			vim.health.warn("whisper-server not found (needed for whisper STT backend)", {
				"Will be auto-downloaded on first :OutloudStart",
				"Or manually download from: github.com/fstirl/whisper-server/releases",
			})
		end
	else
		if vim.fn.executable("llama-server") == 1 then
			vim.health.ok("llama-server found")
		else
			vim.health.warn("llama-server not found (needed for openai STT backend)", {
				"Install: brew install llama.cpp",
			})
		end
	end

	-- Model check (based on config)

	if backend == "whisper" then
		if not model_cfg.server_url then
			local model_size = model_cfg.size or "medium"
			if model_cfg.path then
				report_model_file(model_cfg.path, "whisper model (explicit path)")
			else
				local fname = WHISPER_MODEL_SIZES[model_size] or WHISPER_MODEL_SIZES.medium
				local default_path = data_dir() .. "/models/" .. fname
				report_model_file(default_path, string.format("whisper model '%s'", model_size))
			end
		else
			vim.health.info("whisper model check skipped (external server_url configured)")
		end
	else
		if not model_cfg.server_url then
			local hf_repo = model_cfg.hf_repo or "ggml-org/Voxtral-Mini-3B-2507-GGUF"
			local repo_name = hf_repo:match("[^/]+/%[^/]+")
			local cache_dirs = {}
			local xdg_cache = vim.fn.expand("$XDG_CACHE_HOME")
			if xdg_cache ~= "" and xdg_cache ~= "v:null" then
				table.insert(cache_dirs, xdg_cache .. "/llama.cpp")
			end
			table.insert(cache_dirs, vim.fn.expand("~/.cache/llama.cpp"))
			table.insert(cache_dirs, vim.fn.expand("~/Library/Caches/llama.cpp"))

			local found = false
			for _, cache_dir in ipairs(cache_dirs) do
				if vim.fn.isdirectory(cache_dir) == 1 then
					local files = vim.fn.globpath(cache_dir, "**/*.gguf", false, true)
					if #files > 0 then
						local matched = {}
						for _, f in ipairs(files) do
							if repo_name and f:find(repo_name) then
								table.insert(matched, f)
							end
						end
						if #matched > 0 then
							local stat = vim.uv.fs_stat(matched[1])
							local size = stat and stat.size or 0
							local mtime = stat and stat.mtime and stat.mtime.sec or 0
							vim.health.ok(
								string.format(
									"llama model '%s' found in cache (%s, modified %s)",
									hf_repo,
									fmt_size(size),
									fmt_date(mtime)
								)
							)
							found = true
							break
						elseif not found then
							-- Report any .gguf found (repo may not match exactly)
							local stat = vim.uv.fs_stat(files[1])
							local size = stat and stat.size or 0
							vim.health.ok(
								string.format(
									"llama.cpp cache has %d .gguf file(s), largest %s",
									#files,
									fmt_size(size)
								)
							)
							found = true
							break
						end
					end
				end
			end
			if not found then
				vim.health.info(
					string.format("llama model '%s' not in cache yet", hf_repo),
					{
						"Will be auto-downloaded on first :OutloudStart via llama-server -hf",
						"Check ~/.cache/llama.cpp/ for cached models after first run",
					}
				)
			end
		else
			vim.health.info("llama model check skipped (external server_url configured)")
		end
	end

	-- Daemon running check
	if not model_cfg.server_url then
		local port = model_cfg.server_port
		if backend == "whisper" then
			port = port or 8000
			if probe_server_sync(port, "/") then
				vim.health.ok(string.format("whisper-server is running on port %d", port))
			else
				vim.health.info(string.format("whisper-server is not running on port %d (will be auto-started on :OutloudStart)", port))
			end
		else
			port = port or 8674
			if probe_server_sync(port, "/health") then
				vim.health.ok(string.format("llama-server is running on port %d", port))
			else
				vim.health.info(string.format("llama-server is not running on port %d (will be auto-started on :OutloudStart)", port))
			end
		end
	else
		vim.health.info(string.format("external STT server configured: %s", model_cfg.server_url))
	end

	-- Plugin state
	local ok, ls = pcall(require, "outloud")
	if ok and ls.config and ls.config.model then
		vim.health.ok("plugin loaded and configured")
	elseif ok then
		vim.health.warn("plugin loaded but not configured — call require('outloud').setup()")
	else
		vim.health.error("plugin failed to load")
	end
end

return M
