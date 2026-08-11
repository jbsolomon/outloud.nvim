local Scratchpad = require("outloud.scratchpad").Scratchpad

local M = {}

--- Accumulator mode: collects transcript chunks in a temp buffer instead of
--- inserting them directly. The user reviews the accumulated text and confirms
--- with :VoiceConfirmBuf, which delegates to a CodeCompanion handler (or custom
--- function) that transforms the voice input into buffer edits.
---
--- In **scratchpad mode** (`mode = "scratchpad"`), chunks buffer while
--- refinements are running. If a refinement finishes while there are chunks
--- buffered, the remaining chunks are sent for further refinement. Otherwise,
--- if no refinement is running and any chunk arrives, it triggers a refinement.
--- `is_final` is informational only — processing is the same for all chunks.
---
---@class outloud.Accumulator
---@field buf number?           temp buffer holding accumulated text
---@field win number?           optional window for the accumulator preview
---@field chunks string[]       raw transcript chunks in order
---@field text string           joined accumulated text
---@field mode string           "hidden" | "preview" | "scratchpad"
---@field _refining boolean     gate to prevent concurrent LLM calls
---@field _chunk_buffer string[] chunks buffered while refinement is in flight
---@field _scratchpad Scratchpad?  floating preview window
---@field _cc_chat table?         CodeCompanion chat object (reused across refinements)
local Accumulator = {}
Accumulator.__index = Accumulator

local DEFAULT_OPTS = {
	mode = "hidden",       -- "hidden" | "preview" | "scratchpad"
	width = 48,
	position = "right",
	-- Handler configuration
	handler = nil,          -- { name = "default" } for CodeCompanion, or { fn = function(text, context) ... end }
	context = {
		buffer = true,
		selection = true,
		cursor = true,
		diagnostics = false,
		filename = true,
	},
	-- Scratchpad system prompt (customizable)
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
}

---@param opts? table
---@return outloud.Accumulator
function Accumulator:new(opts)
	opts = vim.tbl_deep_extend("force", {}, DEFAULT_OPTS, opts or {})
	return setmetatable({
		buf = nil,
		win = nil,
		chunks = {},
		text = "",
		mode = opts.mode,
		opts = opts,
		_refining = false,
		_chunk_buffer = {},
		_scratchpad = nil,
		_cc_chat = nil,
	}, Accumulator)
end

--- Append a transcript chunk to the accumulation.
--- In scratchpad mode, chunks buffer while refining, or trigger a refinement
--- when idle. In other modes, appends directly to `self.text`.
---@param text string
---@param is_final? boolean  true if this is the last chunk for the utterance
function Accumulator:append(text, is_final)
	if not text or text == "" then
		return
	end
	if self.mode == "scratchpad" then
		if self._refining then
			-- Buffer the chunk — it will be processed when refinement completes
			table.insert(self._chunk_buffer, text)
		else
			-- No refinement in flight: trigger one with this chunk
			self:_refine(text)
		end
	else
		-- Classic mode: append directly to text
		self.chunks[#self.chunks + 1] = text
		self.text = table.concat(self.chunks, " ")
	end
	self:_refresh_buf()
end

--- Clear all accumulated chunks.
function Accumulator:clear()
	self.chunks = {}
	self.text = ""
	self._chunk_buffer = {}
	self:_refresh_buf()
end

--- Send combined instruction text to the LLM for scratchpad refinement.
--- Sets _refining = true, dispatches to CodeCompanion (or handler.fn, or fallback),
--- and clears _refining on completion. If _chunk_buffer has items, triggers
--- another refinement with the buffered chunks.
---@param instruction string  the instruction text to send
function Accumulator:_refine(instruction)
	self._refining = true

	local prompt = string.format(self.opts.scratchpad_system, self.text or "(empty)", instruction)

	-- Update scratchpad preview so user sees "refining" state
	self:_refresh_buf()

	local handler = self.opts.handler

	-- Try CodeCompanion first if handler.name is set
	if handler and handler.name then
		local ok, cc = pcall(require, "CodeCompanion")
		if ok and cc.chat then
			vim.notify("[outloud] scratchpad: refining with CodeCompanion", vim.log.levels.INFO)

			if self._cc_chat and vim.api.nvim_buf_is_valid(self._cc_chat.bufnr) then
				-- Reuse existing chat session
				vim.notify("[outloud] scratchpad: sending follow-up in existing session", vim.log.levels.INFO)

				local _self = self
				self._cc_chat.callbacks.on_completed = {vim.schedule_wrap(function(chat)
					local response_text = ""
					if chat and chat.messages then
						for _, msg in ipairs(chat.messages) do
							if msg.role == "llm" then
								response_text = msg.content or ""
							end
						end
					end
					_self:_apply_refinement(response_text)
				end)}

				self._cc_chat:add_message({ role = "user", content = prompt })
				self._cc_chat:submit({ auto_submit = true })
			else
				-- Create a new chat session
				cc.chat({
					params = { adapter = handler.name },
					messages = { { role = "user", content = prompt } },
					auto_submit = true,
					hidden = true,
					callbacks = {
						on_completed = vim.schedule_wrap(function(chat)
							self._cc_chat = chat
							local response_text = ""
							if chat and chat.messages then
								for _, msg in ipairs(chat.messages) do
									if msg.role == "llm" then
										response_text = msg.content or ""
									end
								end
							end
							self:_apply_refinement(response_text)
						end),
						on_error = vim.schedule_wrap(function(_, err_msg)
							vim.notify("[outloud] CodeCompanion error: " .. tostring(err_msg or "unknown"), vim.log.levels.WARN)
							self:_fallback_refine(instruction)
						end),
					},
				})
			end
			return
		end
		vim.notify("[outloud] CodeCompanion not available, falling back to direct merge", vim.log.levels.WARN)
	end

	-- Custom function handler
	if handler and handler.fn then
		local result = handler.fn(instruction, { scratchpad = self.text })
		if result and type(result) == "string" then
			self:_apply_refinement(result)
			return
		end
	end

	-- No handler — fall back to plain-text merge
	self:_fallback_refine(instruction)
end

--- Fallback: merge instruction directly into scratchpad text without LLM.
---@param instruction string
function Accumulator:_fallback_refine(instruction)
	self.text = self.text ~= "" and (self.text .. "\n" .. instruction) or instruction
	self:_apply_refinement(self.text)
end

--- Apply the LLM response: update scratchpad text, refresh buffer, yank to register,
--- then check for buffered chunks and trigger further refinement if needed.
---@param text string  the new scratchpad content
function Accumulator:_apply_refinement(text)
	self.text = text
	self._refining = false
	self:_refresh_buf()

	-- Yank refined content to register so user can paste immediately
	local reg = self.opts.register or "o"
	vim.fn.setreg(reg, text)

	-- If chunks were buffered while we were refining, combine them and refine again
	if #self._chunk_buffer > 0 then
		local buffered = table.concat(self._chunk_buffer, " ")
		self._chunk_buffer = {}
		vim.schedule(function()
			self:_refine(buffered)
		end)
	end
end

--- Gather context from the current buffer for the handler.
---@return table
function Accumulator:_gather_context()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local ctx = self.opts.context
	local result = {}

	if ctx.filename then
		result.filename = vim.api.nvim_buf_get_name(buf)
		result.filetype = vim.bo[buf].filetype
	end

	if ctx.cursor then
		result.cursor = { line = cursor[1], col = cursor[2] }
	end

	if ctx.selection and vim.fn.mode() == "v" then
		local start_pos = vim.fn.getpos("v")
		local end_pos = vim.fn.getpos(".")
		local sline = math.min(start_pos[2], end_pos[2]) - 1
		local schar = math.min(start_pos[3], end_pos[3]) - 1
		local eline = math.max(start_pos[2], end_pos[2]) - 1
		local echar = math.max(start_pos[3], end_pos[3])
		result.selection = vim.api.nvim_buf_get_text(buf, sline, schar, eline, echar, {})
		result.selection_start = { line = sline, col = schar }
		result.selection_end = { line = eline, col = echar }
	end

	if ctx.buffer then
		local win = vim.api.nvim_get_current_win()
		local height = vim.api.nvim_win_get_height(win)
		local view = vim.api.nvim_win_call(win, function()
			return vim.fn.winsaveview()
		end)
		local top = math.max(0, view.topline - 1)
		local bottom = vim.api.nvim_buf_line_count(buf)
		result.buffer_lines = vim.api.nvim_buf_get_lines(buf, top, bottom, false)
		result.buffer_line_count = vim.api.nvim_buf_line_count(buf)
		result.window_top = view.topline
	end

	if ctx.diagnostics then
		result.diagnostics = vim.diagnostic.get(buf)
	end

	return result
end

--- Build a prompt for the handler from accumulated text + context.
---@param context table
---@return string
function Accumulator:_build_prompt(context)
	local parts = {}

	table.insert(parts, "Transform the following voice input into edits for the current buffer.")
	table.insert(parts, "")

	if context.filename then
		table.insert(parts, ("Filename: %s (filetype: %s)"):format(context.filename, context.filetype or "unknown"))
	end
	if context.cursor then
		table.insert(parts, ("Cursor: line %d, col %d"):format(context.cursor.line, context.cursor.col))
	end
	if context.selection then
		table.insert(parts, "")
		table.insert(parts, "Selected text:")
		table.insert(parts, table.concat(context.selection, "\n"))
	end
	if context.buffer_lines then
		table.insert(parts, "")
		table.insert(parts, "Buffer context (visible lines):")
		table.insert(parts, table.concat(context.buffer_lines, "\n"))
	end

	table.insert(parts, "")
	table.insert(parts, "Voice input:")
	table.insert(parts, self.text)
	table.insert(parts, "")
	table.insert(parts, "Return only the transformed text that should be inserted at the cursor position.")

	return table.concat(parts, "\n")
end

--- Confirm the accumulated text: invoke the handler and apply the result.
---@param on_complete? fun(text: string) callback with the handler result
function Accumulator:confirm(on_complete)
	if self.text == "" then
		vim.notify("[outloud] accumulator is empty", vim.log.levels.WARN)
		return
	end

	local context = self:_gather_context()
	local prompt = self:_build_prompt(context)

	-- Try CodeCompanion first if handler.name is set
	local handler = self.opts.handler
	if handler and handler.name then
		local ok, cc = pcall(require, "CodeCompanion")
		if ok then
			vim.notify("[outloud] sending to CodeCompanion handler: " .. handler.name, vim.log.levels.INFO)
			cc.chat({
				params = { adapter = handler.name },
				messages = { { role = "user", content = prompt } },
				auto_submit = true,
				hidden = true,
				callbacks = {
					on_completed = function(chat)
						local result_text = ""
						if chat and chat.messages then
							for _, msg in ipairs(chat.messages) do
								if msg.role == "llm" then
									result_text = msg.content or ""
								end
							end
						end
						if type(result_text) == "table" then
							result_text = table.concat(result_text, "\n")
						end
						if on_complete then
							on_complete(result_text)
						else
							self:_insert_at_cursor(result_text)
						end
					end,
				},
			})
			return
		end
	end

	-- Custom function handler
	if handler and handler.fn then
		local result = handler.fn(self.text, context)
		if result and type(result) == "string" then
			if on_complete then
				on_complete(result)
			else
				self:_insert_at_cursor(result)
			end
			return
		end
	end

	-- No handler configured — direct insertion fallback
	vim.notify("[outloud] no handler configured, inserting directly", vim.log.levels.INFO)
	self:_insert_at_cursor(self.text)
	if on_complete then
		on_complete(self.text)
	end
end

--- Insert text at the cursor position in the current buffer.
---@param text string
function Accumulator:_insert_at_cursor(text)
	local buf = vim.api.nvim_get_current_buf()
	local line, col = unpack(vim.api.nvim_win_get_cursor(0))
	line = line - 1 -- 0-indexed
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local lines = vim.split(text, "\n")
	if #lines == 1 then
		vim.api.nvim_buf_set_text(buf, line, col, line, col, { text })
	else
		vim.api.nvim_buf_set_lines(buf, line, line + 1, false, { lines[1] })
		for i = 2, #lines do
			vim.api.nvim_buf_set_lines(buf, line + i - 1, line + i - 1, false, { lines[i] })
		end
	end
end

--- Toggle the preview window showing accumulated text.
function Accumulator:toggle_preview()
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		self:close_preview()
	else
		self:open_preview()
	end
end

--- Open a preview window showing the accumulated text.
function Accumulator:open_preview()
	self:_ensure_buf()
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		return
	end

	local prev = vim.api.nvim_get_current_win()
	local side = self.opts.position == "left" and "topleft" or "botright"
	vim.cmd(side .. " vsplit")
	self.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(self.win, self.buf)
	vim.api.nvim_set_option_value("winfixwidth", true, { win = self.win })
	vim.api.nvim_win_set_width(self.win, self.opts.width)
	vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf })
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = self.buf })
	vim.api.nvim_set_option_value("filetype", "outloud-accum", { buf = self.buf })
	vim.api.nvim_set_option_value("wrap", true, { win = self.win })

	if vim.api.nvim_win_is_valid(prev) then
		vim.api.nvim_set_current_win(prev)
	end
end

--- Close the preview window.
function Accumulator:close_preview()
	if self.win and vim.api.nvim_win_is_valid(self.win) then
		vim.api.nvim_win_close(self.win, true)
		self.win = nil
	end
end

--- Ensure the temp buffer exists.
function Accumulator:_ensure_buf()
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		return
	end
	self.buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, self.buf, "outloud://accumulator")
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = self.buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = self.buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = self.buf })
end

--- Refresh the buffer content with current accumulated text.
function Accumulator:_refresh_buf()
	self:_ensure_buf()
	local lines = vim.split(self.text, "\n")
	vim.api.nvim_set_option_value("modifiable", true, { buf = self.buf })
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf })

	-- Also update the scratchpad floating preview if open
	if self._scratchpad and self._scratchpad:is_open() then
		self._scratchpad:show(self.text, self._refining)
	end
end

--- Toggle the scratchpad floating preview window.
--- Uses snacks.win for a live preview with spinner indicator during LLM calls.
function Accumulator:toggle_scratchpad()
	if not self._scratchpad then
		self._scratchpad = Scratchpad:new({
			width = self.opts.scratchpad_width or 60,
			height = self.opts.scratchpad_height or 20,
		})
	end
	self._scratchpad:toggle(self.text, self._refining)
end

--- Copy the scratchpad content to the configured register.
--- Called when recording stops so the user can paste with `<reg>p`.
--- @param reg string the register name (e.g. "a", "z", "0")
function Accumulator:to_register(reg)
    if self.text == "" then
        return
    end
    vim.fn.setreg(reg, self.text)
    vim.notify(('[outloud] scratchpad saved to register "%s (paste with "%sp)'):format(reg, reg), vim.log.levels.INFO)
end

--- Clean up buffer and window.
function Accumulator:dispose()
	self._refining = false
	self._chunk_buffer = {}
	self._cc_chat = nil
	self:close_preview()
	if self._scratchpad then
		self._scratchpad:dispose()
		self._scratchpad = nil
	end
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
	end
	self.buf = nil
	self.chunks = {}
	self.text = ""
end

--- Check if there is accumulated text.
---@return boolean
function Accumulator:has_text()
	return self.text ~= ""
end

M.Accumulator = Accumulator
return M
