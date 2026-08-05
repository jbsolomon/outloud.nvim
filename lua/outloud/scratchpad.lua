local M = {}

--- Scratchpad preview: a floating window that shows the live accumulator
--- content with a visual indicator when the LLM is refining it.
---
--- Uses `snacks.win` for the floating window. The window auto-updates when
--- content changes and shows a spinner in the title while iterating.
---
---@class outloud.Scratchpad
---@field win snacks.win?   the floating window
---@field opts table        config options
---@field _tick number      spinner frame tick
---@field _timer userdata?  spinner timer
local Scratchpad = {}
Scratchpad.__index = Scratchpad

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local IDLE_TITLE = "󰈙 Outloud Scratchpad"
local SPINNER_TITLE = "󰈙 Outloud Scratchpad — refining"

--- Create a new scratchpad preview.
---@param opts? table  { width?: number, height?: number, position?: string }
---@return outloud.Scratchpad
function Scratchpad:new(opts)
	opts = opts or {}
	return setmetatable({
		win = nil,
		opts = {
			width = opts.width or 60,
			height = opts.height or 20,
			position = opts.position or "float",
			border = opts.border or "rounded",
		},
		_tick = 0,
		_timer = nil,
	}, Scratchpad)
end

--- Open (or update) the scratchpad preview window.
---@param text string  the current scratchpad content
---@param iterating? boolean  true while LLM call is in flight
function Scratchpad:show(text, iterating)
	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("[outloud] snacks.nvim not available, scratchpad preview disabled", vim.log.levels.WARN)
		return
	end

	local frame = SPINNER[self._tick % #SPINNER + 1]
	local title = iterating
		and ("[%s] %s"):format(frame, SPINNER_TITLE)
		or IDLE_TITLE

	-- If window already exists, update it in place
	if self.win and not self.win.closed then
		local buf = self.win.buf
		if buf and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
			vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		end
		-- Update title
		if self.win.win and vim.api.nvim_win_is_valid(self.win.win) then
			vim.api.nvim_win_set_config(self.win.win, {
				title = title,
				title_pos = "center",
			})
		end
		self:_set_spinner(iterating)
		return
	end

	-- Create new window
	self.win = Snacks.win({
		position = self.opts.position,
		width = self.opts.width,
		height = self.opts.height,
		border = self.opts.border,
		title = title,
		title_pos = "center",
		zindex = 40,
		resize = true,
		enter = false,
		ft = "text",
		wo = {
			wrap = true,
			linebreak = true,
		},
		keys = {
			q = "close",
			["<C-c>"] = "close",
		},
	})

	-- Set initial content and buffer options
	local buf = self.win.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		vim.api.nvim_set_option_value("readonly", true, { buf = buf })
	end

	self:_set_spinner(iterating)
end

--- Close the scratchpad preview window.
function Scratchpad:close()
	if self.win then
		self.win:close()
		self.win = nil
	end
	self:_stop_spinner()
end

--- Toggle the scratchpad preview.
---@param text string  current content
---@param iterating? boolean
function Scratchpad:toggle(text, iterating)
	if self.win and not self.win.closed then
		self:close()
	else
		self:show(text, iterating)
	end
end

--- Check if the preview is currently open.
---@return boolean
function Scratchpad:is_open()
	return self.win ~= nil and not self.win.closed
end

--- Start or stop the spinner animation timer.
---@param iterating boolean
function Scratchpad:_set_spinner(iterating)
	self:_stop_spinner()
	if iterating then
		self._timer = vim.uv.new_timer()
		self._timer:start(0, 100, vim.schedule_wrap(function()
			self._tick = self._tick + 1
			if self.win and not self.win.closed then
				local frame = SPINNER[self._tick % #SPINNER + 1]
				local title = ("[%s] %s"):format(frame, SPINNER_TITLE)
				if self.win.win and vim.api.nvim_win_is_valid(self.win.win) then
					vim.api.nvim_win_set_config(self.win.win, {
						title = title,
						title_pos = "center",
					})
				end
			end
		end))
	end
end

function Scratchpad:_stop_spinner()
	if self._timer then
		self._timer:stop()
		self._timer:close()
		self._timer = nil
	end
end

--- Clean up.
function Scratchpad:dispose()
	self:close()
end

M.Scratchpad = Scratchpad
return M
