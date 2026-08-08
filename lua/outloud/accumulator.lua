local Scratchpad = require("outloud.scratchpad").Scratchpad

local M = {}

--- Accumulator mode: collects transcript chunks in a temp buffer instead of
--- inserting them directly. The user reviews the accumulated text and confirms
--- with :VoiceConfirmBuf, which delegates to a CodeCompanion handler (or custom
--- function) that transforms the voice input into buffer edits.
---
--- In **scratchpad mode** (`mode = "scratchpad"`), each transcript chunk is sent
--- to the LLM together with the current scratchpad content. The LLM returns an
--- updated scratchpad, which replaces the accumulator text. This enables iterative
--- refinement: the user can say "add a function", then "no, delete that line",
--- and the LLM evaluates each instruction against the evolving scratchpad.
---
--- Orthogonal to sliding window mode — you can use accumulator alone or
--- combined with sliding window partials.
---
---@class outloud.Accumulator
---@field buf number?           temp buffer holding accumulated text
---@field win number?           optional window for the accumulator preview
---@field chunks string[]       raw transcript chunks in order
---@field text string           joined accumulated text
---@field mode string           "hidden" | "preview" | "scratchpad"
---@field _partial_text string   raw partial text accumulated since last iteration (scratchpad mode only)
---@field _iterating boolean    gate to prevent concurrent LLM calls
---@field _scratchpad Scratchpad?  floating preview window
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
		_partial_text = "",
		mode = opts.mode,
		opts = opts,
		_iterating = false,
		_augroup = nil,
		_scratchpad = nil,
	}, Accumulator)
end

--- Append a transcript chunk to the accumulation.
--- In scratchpad mode, partials go to `_partial_text` (hidden from scratchpad preview,
--- sent as context to the LLM on next iteration). In other modes, appends to `self.text`.
---@param text string
function Accumulator:append(text)
	if not text or text == "" then
		return
	end
	if self.mode == "scratchpad" then
		-- Scratchpad mode: accumulate partials separately from refined text
		self._partial_text = self._partial_text ~= "" and (self._partial_text .. " " .. text) or text
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
	self._partial_text = ""
	self:_refresh_buf()
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
		-- Normalize to (line, col) 0-indexed
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

--- Build a scratchpad prompt: current scratchpad content + accumulated partials + latest utterance.
--- The LLM sees the refined scratchpad, any raw partial text, and the new instruction.
--- Used in scratchpad mode for iterative LLM refinement.
---@param utterance string  the latest transcript chunk (final transcript)
---@return string
function Accumulator:_build_scratchpad_prompt(utterance)
	-- Combine partials with the final utterance for the instruction
	local instruction = self._partial_text ~= "" and (self._partial_text .. " " .. utterance) or utterance
	return string.format(self.opts.scratchpad_system, self.text or "(empty)", instruction)
end

--- Iterate the scratchpad: send (current content + latest utterance) to the LLM,
--- and replace the scratchpad with the LLM's response.
---
--- This is the core of scratchpad mode. Each utterance is treated as an
--- instruction to update the scratch pad. The LLM sees the full scratch pad
--- state and the latest instruction, and returns the revised scratch pad.
---
--- If an LLM call is already in flight (_iterating gate), the utterance is
--- queued and will be processed after the current call completes. Only one
--- queued item is ever dispatched at a time, and each is scheduled via
--- vim.schedule so the Neovim event loop stays responsive.
---@param utterance string  the latest transcript chunk
---@param on_complete? fun(text: string) callback with the updated scratchpad text
function Accumulator:iterate(utterance, on_complete)
	if not utterance or utterance == "" then
		return
	end

	-- If already iterating, queue the utterance for after the current call
	if self._iterating then
		if not self._queued then
			self._queued = {}
		end
		table.insert(self._queued, { utterance = utterance, on_complete = on_complete })
		return
	end

	self._iterating = true
	-- Push the initial utterance onto the queue so _drain_queue can pick it up
	if not self._queued then
		self._queued = {}
	end
	table.insert(self._queued, { utterance = utterance, on_complete = on_complete })
	vim.schedule(function()
		self:_drain_queue()
	end)
end

--- Dispatch the next item from the queue (or the current utterance if the
--- queue is empty). Called from `iterate()` and recursively from
--- `_apply_scratchpad_update` — always via vim.schedule so the event loop
--- stays responsive between LLM calls.
function Accumulator:_drain_queue()
	-- Pick the next utterance: first from queue, then fall back to the one
	-- that triggered the original `iterate()` call (stored temporarily).
	local item
	if self._queued and #self._queued > 0 then
		item = table.remove(self._queued, 1)
	end

	-- If nothing to process, clear the gate and return
	if not item then
		self._iterating = false
		return
	end

	local utterance = item.utterance
	local on_complete = item.on_complete
	local prompt = self:_build_scratchpad_prompt(utterance)

	-- Update scratchpad preview immediately so user sees "refining" state
	self:_refresh_buf()

	-- Try CodeCompanion first if handler.name is set
	local handler = self.opts.handler
	if handler and handler.name then
		local ok, cc = pcall(require, "CodeCompanion")
		if ok and cc.chat then
			vim.notify("[outloud] scratchpad: refining with CodeCompanion", vim.log.levels.INFO)
			cc.chat({
				params = { adapter = handler.name },
				messages = { { role = "user", content = prompt } },
				auto_submit = true,
				hidden = true,
				callbacks = {
					on_completed = vim.schedule_wrap(function(chat)
						-- Extract assistant response from chat messages
						local response_text = ""
						if chat and chat.messages then
							for _, msg in ipairs(chat.messages) do
								if msg.role == "llm" then
									response_text = msg.content or ""
								end
							end
						end
						self:_apply_scratchpad_update(response_text, on_complete)
					end),
					-- If the adapter errors out, fall through to plain-text merge
					on_error = vim.schedule_wrap(function(_, err_msg)
						vim.notify("[outloud] CodeCompanion error: " .. tostring(err_msg or "unknown"), vim.log.levels.WARN)
						-- Fall through to plain-text merge below
						self:_fallback_merge(utterance, on_complete)
					end),
				},
			})
			return
		end
		-- CodeCompanion not available
		vim.notify("[outloud] CodeCompanion not available, falling back to direct merge", vim.log.levels.WARN)
	end

	-- Custom function handler
	if handler and handler.fn then
		local result = handler.fn(utterance, { scratchpad = self.text })
		if result and type(result) == "string" then
			self:_apply_scratchpad_update(result, on_complete)
			return
		end
	end

	-- No handler — fall back to plain-text merge
	self:_fallback_merge(utterance, on_complete)
end

--- Fallback: merge partials + utterance directly into scratchpad text
--- without an LLM call (no handler configured, or handler failed).
---@param utterance string
---@param on_complete? fun(text: string)
function Accumulator:_fallback_merge(utterance, on_complete)
	local combined = self._partial_text ~= "" and (self._partial_text .. " " .. utterance) or utterance
	self.text = self.text ~= "" and (self.text .. "\n" .. combined) or combined
	self._partial_text = ""

	if on_complete then
		on_complete(self.text)
	end

	self._iterating = false
	self:_refresh_buf()

	-- _fallback_merge is called directly from _drain_queue (not via
	-- _apply_scratchpad_update), so it must schedule the next drain itself.
	if self._queued and #self._queued > 0 then
		vim.schedule(function()
			self:_drain_queue()
		end)
	end
end

--- Update the scratchpad text and refresh the buffer.
--- Clears accumulated partials after a successful LLM iteration.
---@param text string  the new scratchpad content
---@param on_complete? fun(text: string) callback
function Accumulator:_apply_scratchpad_update(text, on_complete)
	-- Replace the scratchpad content (not append)
	self.text = text
	-- Clear partials — they were incorporated into the LLM prompt and the response is the new state
	self._partial_text = ""
	self:_refresh_buf()
	self._iterating = false

	-- Always call the callback for the current iteration before processing queue
	if on_complete then
		on_complete(text)
	end

	-- Schedule the next queued item (non-blocking, one at a time)
	if self._queued and #self._queued > 0 then
		vim.schedule(function()
			self:_drain_queue()
		end)
	end
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
			-- CodeCompanion is available — use it
			vim.notify("[outloud] sending to CodeCompanion handler: " .. handler.name, vim.log.levels.INFO)
			cc.chat({
				params = { adapter = handler.name },
				messages = { { role = "user", content = prompt } },
				auto_submit = true,
				hidden = true,
				callbacks = {
					on_completed = function(chat)
						-- Extract assistant response from chat messages
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
		-- Replace current line with first line of multi-line text
		vim.api.nvim_buf_set_lines(buf, line, line + 1, false, { lines[1] })
		-- Insert remaining lines after it
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

	if not vim.api.nvim_win_is_valid(prev) then
		return
	end
	vim.api.nvim_set_current_win(prev)
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
		self._scratchpad:show(self.text, self._iterating)
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
	self._scratchpad:toggle(self.text, self._iterating)
end

--- Clean up buffer and window.
function Accumulator:dispose()
	self:_cancel()
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

--- Cancel any in-flight LLM iteration and discard the queue.
--- Called when the user stops transcription or disposes the accumulator.
function Accumulator:_cancel()
	-- Clear the queue so no more utterances are processed
	self._queued = {}
	self._iterating = false
end

--- Check if there is accumulated text.
---@return boolean
function Accumulator:has_text()
	return self.text ~= ""
end

M.Accumulator = Accumulator
return M
