local fs      = require("fs")
local conf    = require('ext/conf')
local json    = require('json')
local lpm     = require('ext/lpm')
local path    = require('path')
local sscp    = require('sscp/server')
local utils   = require('utils')
local thread  = require('thread')
local qstring = require('querystring')
local net     = require('net')
local uv      = require('uv')
local httpd   = require('httpd')


local fs     = require('fs')
local app    = require('app')


local formdata      = require('express/formdata')
local querystring   = require('querystring')
local upgrade       = require('ext/upgrade')

local uploadCounter = 1


local spawn   = require('child_process').spawn
local exec    = require('child_process').exec

-- methods
local methods  = {}
local hostname = 'inode'
local session  = {}

local JSON_RPC_VERSION  = "2.0"
local SHELL_RUN_TIMEOUT = 2000

session.token  = 'test'

local isWindows = (os.platform() == 'win32')

local function getEnvironment()
    return { hostname = hostname, path = process.cwd() }
end

local function formatMACAddress(address)
    local result = {}

    for i = 1, 6 do
        result[#result + 1] = address:sub(i * 2 - 1, i * 2)
    end

    return table.concat(result, ':')
end

function getRootPath()
    return conf.rootPath
end


function get_network_interfaces(mode)
	local addresses = {}
	local interfaces = os.networkInterfaces()
	if (not interfaces) then
		return 
	end

	local _getIPv4Number = function(ip)
		local tokens = ip:split('.')
		local ret = (tokens[1] << 24) + (tokens[2] << 16) + (tokens[3] << 8) + (tokens[4])
		return math.floor(ret)
	end

	local family = mode or 'inet'

	for _, interface in pairs(interfaces) do
		if (type(interface) ~= 'table') then
			break
		end

		for _, item in pairs(interface) do
			if (not item) then
				break
			end

			if (item.family == family and not item.internal) then
                item.name = 'eth0'
                item.mac = formatMACAddress(utils.bin2hex(item.mac))
				table.insert(addresses, item)
			end
		end
	end

	return addresses
end

-- 配置信息都保存在 user.conf 文件中
local function get_settings_profile()
    local profile = nil
    if (not profile) then
        profile = conf('user')
    end

    return profile
end

function get_system_target()
	local platform = os.platform()
	local arch = os.arch()

    local target = nil
	if (platform == 'win32') then
        target = 'win'

    elseif (platform == 'darwin') then
		target =  'macos'
    end

    local filename = conf.rootPath .. '/package.json'
    local packageInfo = json.parse(fs.readFileSync(filename)) or {}
    target = target or packageInfo.target or 'linux'
    target = target:trim()
    return target, (process.version or '')
end

-- 在提交的表单中，附带一个 action=edit 的参数表示保存参数。
local function is_edit_action(request)
    local params = request.params
    local action = params['action']
    return (action == 'edit')
end

function methods.completion(response, id, token, env, pattern, command)
    local result = {}
    local completion = {}

    local scanPath = path.dirname(pattern)
    local filename = path.basename(pattern)

    local basePath = scanPath or ''

    if (scanPath == '.') then 
        scanPath = process.cwd() 
        basePath = ''
    end

    if (#basePath > 0) and (not basePath:endsWith('/')) then
        basePath = basePath .. '/'
    end

    if (pattern:endsWith('/')) then
        scanPath = pattern
        filename = ''
        basePath = scanPath
    end

    --console.log('scan', scanPath, basePath, filename)

    local files = fs.readdirSync(scanPath)
    --console.log(files)

    local index = 0
    for _, file in ipairs(files) do
        if (file:startsWith(filename)) then
            completion[#completion + 1] = basePath .. file
        end

        index = index + 1
        if (index > 100) then
            break
        end
    end

    --console.log(completion)
    --console.log(pattern, command)

    result.completion = completion

    local ret = { jsonrpc = JSON_RPC_VERSION, id = id, result = result }
    response:json(ret)
end

function methods.login(response, id, username, password)
	local result = {}

    --print(username, password)

    if (username ~= 'admin' and username ~= 'root') then
        result.falsy = "Invalid username."

    elseif (password ~= 'admin' and password ~= 'root' and password ~= '888888') then
        result.falsy = "Invalid password."

    else
	   result.token = session.token
	   result.environment = getEnvironment()
    end

	local ret = { jsonrpc = JSON_RPC_VERSION, id = id, result = result }
	response:json(ret)
end

function methods.run(response, id, token, env, cmd, ...)
	local result = {}

    if (not isWindows) then
        -- 重定向 stderr(2) 输出到 stdout(1)
        cmd = cmd .. " 2>&1"
    end

    -- [[
    local options = { timeout = SHELL_RUN_TIMEOUT, env = process.env }

    exec(cmd, options, function(err, stdout, stderr) 
        --console.log(err, stdout, stderr)
        if (not stdout) or (stdout == '') then
            stdout = stderr
        end

        if (err and err.message) then
            stdout = err.message .. ': \n\n' .. stdout
        end

        result.output = stdout
        result.environment = getEnvironment()

        local ret = { jsonrpc = JSON_RPC_VERSION, id = id, result = result }
        response:json(ret)
    end)
    --]]
end

function methods.status(response, id, token, env, dir)
    local result = {}

    local lpm = conf('lpm')

    local device = {}
    local status = { device = device }
    --status.lpm  = lpm.options
    --status.sscp = sscp.options
    status.interfaces = get_network_interfaces()

    if (lpm) then
        local cpu = os.cpus() or {}
        cpu = cpu[1] or {}
        cpu = cpu.model or ''

        local stat = fs.statfs('/') or {}
        local storage_total = (stat.blocks or 0) * (stat.bsize or 0)
        local storage_free  = (stat.bfree or 0) * (stat.bsize or 0)

        local memmory_total = os.totalmem()
        local memmory_free  = os.freemem()

        local memmory = app.formatBytes(memmory_free) .. " / " .. app.formatBytes(memmory_total) .. 
            " (" .. math.floor(memmory_free * 100 / memmory_total) .. "%)"

        local storage = app.formatBytes(storage_free) .. " / " .. app.formatBytes(storage_total) .. 
            " (" .. math.floor(storage_free * 100 / storage_total) .. "%)"

        local model = get_system_target() .. " (" .. os.arch() .. ")"

        device.device_name      = lpm:get('device.id')
        device.device_model     = model
        device.device_version   = process.version
        device.device_memmory   = memmory
        device.device_cpu       = cpu
        device.device_root      = app.rootPath
        device.device_url       = app.rootURL        
        device.device_storage   = storage
        device.device_time      = os.date('%Y-%m-%dT%H:%M:%S')
        device.device_uptime    = os.uptime()

    end

    result.environment = getEnvironment()
    result.status = status

    local ret = { jsonrpc = JSON_RPC_VERSION, id = id, result = result }
    response:json(ret)
end

function methods.cd(response, id, token, env, dir)
    local result = {}

    if (type(dir) == 'string') and (#dir > 0) then
        local cwd = process.cwd()
        local newPath = dir
        if (not dir:startsWith('/')) then
            newPath = path.join(cwd, dir)
        end
        --console.log(dir, newPath)

        if newPath and (newPath ~= cwd) then
            local ret, err = process.chdir(newPath)
            --console.log(dir, newPath, ret, err)
            if (not ret) then
                result.output = err or 'Unable to change directory'
            end
        end
    end

    result.environment = getEnvironment()

    local ret = { jsonrpc = JSON_RPC_VERSION, id = id, result = result }
    response:json(ret)
end
-- call API methods
local function do_rpc(request, response)
    local rpc = request.body
    if (type(rpc) ~= 'table') then
    	response:sendStatus(400, "Invalid JSON-RPC request format")
    	return
    end

    local method = methods[rpc.method]
    if (not method) then
    	response:sendStatus(400, "Method not found: " .. tostring(rpc.method))
    	return
    end

    --[[
    if (not httpd.isLogin(request)) then
        response:sendStatus(401, "User not login")
        return
    end--]]

    method(response, rpc.id, table.unpack(rpc.params))
end

request.params = qstring.parse(request.uri.query) or {}
request:readBody(function()
    do_rpc(request, response)
end)

return true
