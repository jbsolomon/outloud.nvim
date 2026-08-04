local M = {}

function M.check()
	vim.health.start("lazyspeak")

	-- Daemon binary
	if vim.fn.executable("lazyspeak") == 1 then
		vim.health.ok("daemon binary found in PATH")
	else
		vim.health.warn("daemon binary not in PATH", {
			"Run: cargo install --path crates/lazyspeak",
			"Or: just install",
		})
	end

	-- llama-server (STT inference)
	if vim.fn.executable("llama-server") == 1 then
		vim.health.ok("llama-server found")
	else
		vim.health.warn("llama-server not found (needed for STT)", {
			"Install: brew install llama.cpp",
		})
	end

	-- Plugin state
	local ok, ls = pcall(require, "lazyspeak")
	if ok and ls.config and ls.config.model then
		vim.health.ok("plugin loaded and configured")
	elseif ok then
		vim.health.warn("plugin loaded but not configured — call require('lazyspeak').setup()")
	else
		vim.health.error("plugin failed to load")
	end
end

return M
