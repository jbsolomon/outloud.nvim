local M = {}

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
	local backend = M.config and M.config.backend or "whisper"
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
