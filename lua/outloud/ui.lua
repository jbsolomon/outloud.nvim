--- Status line component. All in-editor rendering lives in
--- `outloud.sidebar`; this only exposes the compact state string users embed
--- in lualine and friends.
local M = {}

---@type string
M._state = ""

---@type string?
M._device = nil

---@param state string
function M.set_state(state)
	M._state = state
end

---@param device? string
function M.set_device(device)
	M._device = device
end

---@return string
function M.statusline()
	if M._state == "" or M._state == "inactive" or M._state == "idle" then
		return ""
	elseif M._state == "listening" then
		local device = M._device
		if device and device ~= "" then
			return ("ls:mic [%s]"):format(device)
		end
		return "ls:mic"
	elseif M._state == "transcribing" then
		return "ls:..."
	else
		return ""
	end
end

return M
