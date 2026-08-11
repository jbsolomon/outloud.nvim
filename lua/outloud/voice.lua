local M = {}

---@class outloud.Voice
---@field job_id number?
---@field partial string buffered partial line from stdout
---@field callbacks table<string, function>
---@field daemon_cmd string
---@field device_formats table<string, string>? lowercased device name -> native sample format
---@field default_device string? default input device name from the last list_devices response
local Voice = {}
Voice.__index = Voice

---@param opts? { daemon_cmd?: string, env?: table<string, string> }
function Voice:new(opts)
	opts = opts or {}
	return setmetatable({
		job_id = nil,
		partial = "",
		callbacks = {},
		daemon_cmd = opts.daemon_cmd or "outloud",
		env = opts.env or {},
		device_formats = nil,
		default_device = nil,
	}, Voice)
end

---@param line string
function Voice:_handle_line(line)
	if line == "" then
		return
	end

	local ok, data = pcall(vim.json.decode, line)
	if not ok then
		return
	end

	-- The protocol's nullable fields (`device` on status events, `default` on
	-- devices events) serialize as explicit JSON null when unset, and
	-- vim.json.decode maps null to the vim.NIL userdata sentinel rather than
	-- Lua nil. Normalize them here so callbacks never receive userdata —
	-- concatenating one (e.g. in the sidebar header) would raise.
	if data.device == vim.NIL then
		data.device = nil
	end
	if data.default == vim.NIL then
		data.default = nil
	end

	local event_type = data.type
	if event_type == "chunk" and self.callbacks.chunk then
		self.callbacks.chunk(data.text, data.duration_ms, data.is_final or false)
	elseif event_type == "status" and self.callbacks.status then
		self.callbacks.status(data.state, data.device, data.backend)
	elseif event_type == "vad" and self.callbacks.vad then
		self.callbacks.vad(data.speaking)
	elseif event_type == "error" and self.callbacks.error then
		self.callbacks.error(data.message)
	elseif event_type == "devices" then
		self:_cache_devices(data.devices, data.default)
		if self.callbacks.devices then
			self.callbacks.devices(data.devices, data.default)
		end
	end
end

function Voice:start()
	if self.job_id then
		return
	end

	self.job_id = vim.fn.jobstart({ self.daemon_cmd }, {
		env = self.env,
		on_stdout = function(_, data, _)
			-- data is a list of strings split by newlines.
			-- Last element may be partial (empty string if line was complete).
			for i, chunk in ipairs(data) do
				if i == 1 then
					-- Prepend any buffered partial from last callback
					chunk = self.partial .. chunk
					self.partial = ""
				end

				if i == #data then
					-- Last chunk is either empty (complete line) or partial
					self.partial = chunk
				else
					self:_handle_line(chunk)
				end
			end
		end,
		on_exit = function(_, code, _)
			self.job_id = nil
			if self.callbacks.exit then
				self.callbacks.exit(code)
			end
		end,
		stdout_buffered = false,
	})

	if self.job_id <= 0 then
		vim.notify("[outloud] failed to start daemon: " .. self.daemon_cmd, vim.log.levels.ERROR)
		self.job_id = nil
	end
end

function Voice:stop()
	if not self.job_id then
		return
	end
	local job_id = self.job_id
	self:_send({ cmd = "shutdown" })
	if vim.fn.jobwait({ job_id }, 2000)[1] == -1 then
		-- Daemon ignored the shutdown command within 2s. jobwait only waits;
		-- it never kills — jobstop it rather than orphaning the process.
		pcall(vim.fn.jobstop, job_id)
	end
	self.job_id = nil
end

---@param device? string optional device name
---@param sample_format? string optional explicit native sample format (e.g. "i16")
function Voice:start_listening(device, sample_format)
	local cmd = { cmd = "start_listening" }
	if device then
		cmd.device = device
	end
	-- Forward the device's native sample format so the daemon can open the
	-- stream without a conversion layer. When unknown, omit it and let the
	-- daemon probe the device itself.
	local fmt = sample_format or self:_native_format(device)
	if fmt then
		cmd.sample_format = fmt
	end
	self:_send(cmd)
end

--- Cache the native sample formats reported by the daemon's `list_devices`
--- response, keyed by lowercased device name.
---@param devices table[]
---@param default_device string?
function Voice:_cache_devices(devices, default_device)
	local formats = {}
	for _, d in ipairs(devices or {}) do
		if d.name and d.sample_format then
			formats[d.name:lower()] = d.sample_format
		end
	end
	self.device_formats = formats
	self.default_device = default_device
end

--- Resolve the native sample format for the device about to be opened, from
--- the cached `list_devices` response. `nil` device means the default device.
--- Returns `nil` when unknown (the daemon then probes the device itself).
---@param device? string
---@return string?
function Voice:_native_format(device)
	if not self.device_formats then
		return nil
	end
	local name = device or self.default_device
	if not name then
		return nil
	end
	return self.device_formats[name:lower()]
end

function Voice:stop_listening()
	self:_send({ cmd = "stop_listening" })
end

function Voice:cancel()
	self:_send({ cmd = "cancel" })
end

--- Request the list of available input devices.
--- The result is delivered via the `on_devices` callback.
function Voice:list_devices()
	self:_send({ cmd = "list_devices" })
end

---@param cmd table
function Voice:_send(cmd)
	if not self.job_id then
		return
	end
	vim.fn.chansend(self.job_id, vim.json.encode(cmd) .. "\n")
end


---@param callback fun(text: string, duration_ms: number)
function Voice:on_chunk(callback)
	self.callbacks.chunk = callback
end

---@param callback fun(state: string, device: string?, backend: {status: string, error?: string})
function Voice:on_status(callback)
	self.callbacks.status = callback
end

---@param callback fun(speaking: boolean)
function Voice:on_vad(callback)
	self.callbacks.vad = callback
end

---@param callback fun(message: string)
function Voice:on_error(callback)
	self.callbacks.error = callback
end

---@param callback fun(devices: table[], default_device: string?)
function Voice:on_devices(callback)
	self.callbacks.devices = callback
end

--- Called when the daemon process exits for any reason (expected or not).
---@param callback fun(code: number)
function Voice:on_exit(callback)
	self.callbacks.exit = callback
end

---@return boolean
function Voice:is_running()
	return self.job_id ~= nil
end

M.Voice = Voice
return M
