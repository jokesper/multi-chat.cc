local args = { ... }

local version = '0.2.x'
local meta_protocol = 'update-multi-chat' -- ('multi-chat-%s'):format(version)
local function run_on_src(mode, method, ...)
	local file = fs.open(shell.getRunningProgram(), mode)
	--- @cast file -nil -- since it should always exist
	local ok, res
	if type(method) == 'function' then
		ok, res = pcall(method, file, ...)
	else
		ok, res = pcall(file[method], ...)
	end
	file.close()
	if not ok then
		error(res)
	else
		return res
	end
end
local function get_hash() return run_on_src('r', 'readLine') end
local function update_from_source()
	print 'Trying remote source'
	local response, err, errResponse = http.get(
		('https://api.github.com/repos/%s/%s/contents/%s?ref=%s')
		:format('jkeDev', 'multi-chat.cc', 'client.lua', version))
	--- @cast errResponse -nil when response is null
	if response == nil then error(('[%s] %s'):format(errResponse.getResponseCode(), err)) end
	local json = textutils.unserializeJSON(response.readAll() or '', { parse_empty_array = false }) or {}
	if type(json.sha) ~= 'string' or type(json.content) ~= 'string' then
		error 'Mailformed response from github'
	end
	if get_hash() == json.sha then return true end
	if json.encoding ~= 'base64' then error(('Upstream is in non base64 encoding: %s'):format(json.encoding)) end
	run_on_src('w', function(file)
		file.write(('-- %s\n'):format(json.sha))
		local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
		local raw = json.content:gsub('\n', '')
		local buf = 0
		for i = 1, #raw do
			local char = raw:sub(i, i)
			if char == '=' then
				if i % 4 == 0 then -- one padding byte
					file.write(string.char(bit32.extract(buf, 10, 8), bit32.extract(buf, 2, 8)))
				else -- two padding bytes
					file.write(string.char(bit32.extract(buf, 4, 8)))
				end
				break
			end
			local n = b:find(char) - 1
			buf = bit32.lshift(buf, 6) + n
			if i % 4 == 0 then
				file.write(string.char(
					bit32.extract(buf, 16, 8),
					bit32.extract(buf, 8, 8),
					bit32.extract(buf, 0, 8)))
				buf = 0
			end
		end
	end)
	return true
end
local function update()
	print 'Checking for updates'
	rednet.broadcast('get-hash', meta_protocol)
	local from, hash = rednet.receive(meta_protocol, 5)
	if from == nil then return http ~= nil and update_from_source() end
	if hash == get_hash() then return false end
	rednet.send(from, 'get', meta_protocol)
	local t0 = os.clock()
	repeat
		local from2, src = rednet.receive(meta_protocol, 5)
		if from2 == from then
			run_on_src('w', 'write', src)
			return false
		end
	until os.clock() - t0 > 5
	print 'Did not get update'
	return false
end

local shellEnv = { shell = shell, multishell = multishell }
if #args <= 0 then
	peripheral.find('modem', rednet.open)
	os.run(shellEnv, shell.getRunningProgram(), 'run', update())
elseif args[1] == 'run' then
	print 'Major update installed...'
	os.reboot()
	term.clear()
	for name, protocol in pairs {
		chat = 'rednet-chat',
	} do
		local pid = multishell.launch(shellEnv, shell.getRunningProgram(), 'rednet', protocol, name)
		multishell.setTitle(pid, name)
	end
	term.setCursorPos(1, 1)
	parallel.waitForAll(
		function() os.run(shellEnv, 'rom/programs/shell.lua') end,
		args[2] and function()
			local hash = get_hash()
			local src = run_on_src('r', 'readAll')
			while true do
				local from, cmd = rednet.receive(meta_protocol)
				--- @cast from -nil -- since there is no timeout
				if cmd == 'get-hash' then
					rednet.send(from, hash, meta_protocol)
				elseif cmd == 'get' then
					rednet.send(from, src, meta_protocol)
				end
			end
		end or function() end
	)
elseif args[1] == 'rednet' then
	local protocol = args[2]
	if protocol == nil then
	else
		local parent = term.current()
		local w, h = parent.getSize()
		local messageScreen = window.create(parent, 1, 1, w, h - 1)
		local inputField = window.create(parent, 1, h, w, 1)
		local nw, nh = term.native().getSize()
		local nx, ny = nw / 2, nh * 4 / 5
		nw, nh = nw - nx + 1, nh - ny + 1
		local notifyTimer = nil
		local notifyTerm = window.create(term.native(), nx, ny, nw, nh, false)
		notifyTerm.setBackgroundColor(colors.gray)
		local function withTerm(redirect, func, ...)
			local old = term.current()
			term.redirect(redirect)
			local val = { func(...) }
			term.redirect(old)
			return table.unpack(val)
		end
		parallel.waitForAny(
			function()
				while true do
					local from, message = rednet.receive(protocol)
					if multishell.getFocus() ~= multishell.getCurrent() then
						notifyTerm.clear()
						if notifyTimer ~= nil then os.cancelTimer(notifyTimer) end
						notifyTimer = os.startTimer(5)
						notifyTerm.setVisible(true)
						withTerm(notifyTerm,
							print, ('%s\n%d: %s'):format(args[3], from, message))
					end
					withTerm(messageScreen,
						print, ('%5d: %s'):format(from, message))
				end
			end,
			function()
				while true do
					local _, id = os.pullEvent 'timer'
					if id == notifyTimer then notifyTerm.setVisible(false) end
				end
			end,
			function()
				while true do
					inputField.write '> '
					local message = withTerm(inputField, read)
					rednet.broadcast(message, protocol)
					withTerm(messageScreen, print, ('You: %s'):format(message))
				end
			end
		)
	end
end
