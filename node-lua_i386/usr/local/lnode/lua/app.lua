--[[

Copyright 2016 The Node.lua Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS-IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

--]]

local core   	= require('core')
local fs     	= require('fs')
local json   	= require('json')
local path   	= require('path')
local utils     = require('utils')
local conf      = require('ext/conf')
local ext   	= require('ext/utils')

local exports = {}

-------------------------------------------------------------------------------
-- misc

local getSystemInformation

local function getRootPath()
	return conf.rootPath
end

local function getAppPath()
	local rootPath = getRootPath()
	local appPath = path.join(rootPath, "app")
	if (not fs.existsSync(appPath)) then
		appPath = path.join(path.dirname(rootPath), "app")
	end

	return appPath

end

local function getRootURL()
	if (exports.rootURL) then
		return exports.rootURL
	end

	local systemInformation = getSystemInformation()
	if (systemInformation and systemInformation.registry) then
		local registry = systemInformation.registry
		if (registry) and (registry.url) then
			exports.rootURL = registry.url
		end

	else
		exports.rootURL = "http://node.sae-sz.com"
	end

	return exports.rootURL
end

local function getApplicationInfo(basePath)
	local filename = path.join(basePath, "package.json")
	local data = fs.readFileSync(filename)
	return data and json.parse(data)
end

-- 通过 cmdline 解析出相关的应用的名称
local function getApplicationName(cmdline)
	if (type(cmdline) ~= 'string') then
		return
	end

    local _, _, appName = cmdline:find('/([%w]+)/init.lua')

    if (not appName) then
        _, _, appName = cmdline:find('/lpm%S([%w]+)%Sstart')
    end

    if (not appName) then
        _, _, appName = cmdline:find('/lpm%Sstart%S([%w]+)')
    end    

    return appName
end

function getSystemInformation()
	if (exports.systemInformation) then
		return exports.systemInformation
	end

    local filename = getRootPath() .. '/package.json'
    exports.systemInformation = json.parse(fs.readFileSync(filename)) or {}
    return exports.systemInformation
end

local function executeApplication(basePath, ...)
	local filename = path.join(basePath, "init.lua")
	if (not fs.existsSync(filename)) then
		return -3, '"' .. basePath .. '/init.lua" not exists!'
	end

	local script, err = loadfile(filename)
	if (err) then
		error(err)
		return -4, err
	end

	_G.arg = table.pack(...)
	return 0, script(...)
end

-- 显示错误信息
local function printError(errorInfo, ...)
	print('Error:', console.color("err"), tostring(errorInfo), console.color(), ...)

end

-------------------------------------------------------------------------------
-- exports

exports.meta  = {}
setmetatable(exports, exports.meta)

--
exports.rootPath 		= getRootPath()
exports.rootURL 		= getRootURL()

--
exports.formatFloat 	= ext.formatFloat
exports.formatBytes 	= ext.formatBytes
exports.padding 		= ext.padding
exports.table 			= ext.table

-------------------------------------------------------------------------------
-- profile

local loadProfile = function()
    if (exports._profile) then
        return exports._profile
    end

	exports._profile = conf(exports.appName())
    return exports._profile
end

function exports.appName()
	return exports.name or 'user'
end

-- 删除指定名称的配置参数项的值
-- @param name {String}
function exports.del(name)
    if (not name) then
		print("get: the '<name>' argument was not provided")
        return
    end

	local profile = loadProfile()
	if (profile) and (profile:get(name)) then
		profile:set(name, nil)
		profile:commit()
	end
end

-- 打印指定名称的配置参数项的值
-- @param name {String}
function exports.get(name)
	if (not name) then
		print("get: the '<name>' argument was not provided")
        return
    end

	local profile = loadProfile()
    if (profile) then
		return profile:get(name)
	end
end

-- 设置指定名称的配置参数项的值
-- @param name {String|Object}
-- @param value {String|Number|Boolean}
function exports.set(name, value)
	if (not name) then
		print("set: the '<name>' argument was not provided")
		return
	end

	local profile = loadProfile()
    if (not profile) then
        return
    end

    if (type(name) == 'table') then
        local count = 0
        for k, v in pairs(name) do
            local oldValue = profile:get(k)
            --print(k, v, oldValue)

            if (not oldValue) or (v ~= oldValue) then
                profile:set(k, v)

                count = count + 1
            end
        end

        if (count > 0) then
            profile:commit()
        end

    else 
    	if (not name) or (not value) then
    		print("set: the '<value>' argument was not provided")
            return
        end

        local oldValue = profile:get(name)
        if (not oldValue) or (value ~= oldValue) then
            profile:set(name, value)
            profile:commit()
        end
    end
end

-------------------------------------------------------------------------------
-- methods

function exports.daemon(name)
	if (not name) or (name == '') then
		print("daemon: the '<name>' argument was not provided")
		return -1
	end

	local filename = path.join(getAppPath(), name, 'init.lua')
	if (not fs.existsSync(filename)) then
		print('"' .. filename .. '" not exists!')
		return -3
	end

    local cmdline  = "lnode -d " .. filename .. " start"
	print('start as daemon: ' .. name)
	os.execute(cmdline)
end

function exports.execute(name, ...)
	local basePath
	if (not name) then
		basePath = process.cwd()
	else
		basePath = path.join(getAppPath(), name)
	end

	return executeApplication(basePath, ...)
end

function exports.info(name)
	local filename = path.join(getAppPath(), name)
	return getApplicationInfo(filename)
end

function exports.list()
	local appPath = getAppPath()
	local list = {}

	local files = fs.readdirSync(appPath)
	if (not files) then
		return list
	end

	for i = 1, #files do
		local file 		= files[i]
		local filename  = path.join(appPath, file)
		local name 		= path.basename(file)
		local info 		= getApplicationInfo(filename)
		if (info) then
			info.name = info.name or name
			list[#list + 1] = info
		end
	end

	return list
end

function exports.main(handler, action, ...)
    local method = handler[action]
    if (not method) then
        method = handler.help
    end

    if (not exports.name) then
    	exports.name = getApplicationName(utils.filename(4))
    end

    if (method) then
        method(...)
	end
end

function exports.printList()
	local appPath = path.join(getAppPath())

	local apps = exports.list()
	if (not apps) or (#apps <= 0) then
		print("No applications are installed yet.", appPath)
		return
	end

	local grid = ext.table({ 12, 12, 48 })
	grid.line()
	grid.cell('Name', 'Version', 'Description')
	grid.line('=')

	for _, app in ipairs(apps) do
		grid.cell(app.name, app.version, app.description)
	end

	grid.line()
    print(string.format("+ total %s applications (%s).", 
        #apps, appPath))
end

-- 返回当前系统目标平台名称, 一般是开发板的型号或 PC 操作系统的名称
-- 因为不同平台的可执行二进制文件格式是不一样的, 所有必须严格匹配
function exports.target()
	local platform = os.platform()
	local arch = os.arch()

	if (platform == 'win32') then
        return 'win'

    elseif (platform == 'darwin') then
		return 'macos'
    end

    local systemInformation = getSystemInformation()
    local target = systemInformation.target or 'linux'
    target = target:trim()
    return target
end


-- 解析 exports 的 package.json 文件, 并显示相关的使用说明信息. 
function exports.usage(dirname)
    local fs    = require('fs')
    local json  = require('json')

    local data      = fs.readFileSync(dirname .. '/package.json')
    local package   = json.parse(data) or {}

    local color  = console.color
	local quotes = color('quotes')
	local desc 	 = color('braces')
	local normal = color()

    -- Name
    print(quotes, '\nusage: lpm ' .. tostring(package.name) .. ' <command> [args]\n', normal)

    -- Description
    if (package.description) then
        print(package.description, '\n')
    end

	local printList = function(name, list)
		if (not list) then
			return
		end

        print(name .. ':\n')
		for _, item in ipairs(list) do
			print('- ' ..  exports.padding(tostring(item.name), 24), 
				desc .. tostring(item.desc), normal)
		end

		print('')
	end

    printList('Settings', 			package.settings)
    printList('IPC command', 		package.rpc)
    printList('available command', 	package.commands)
end

exports.meta.__call = function(self, handler)
    exports.main(handler, table.unpack(arg))
end

return exports
