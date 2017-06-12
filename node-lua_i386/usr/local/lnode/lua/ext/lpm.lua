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
local utils  	= require('utils')
local conf    	= require('ext/conf')
local app 		= require('app')

-------------------------------------------------------------------------------
-- meta

local meta = { }
meta.name        = "lpm"
meta.version     = "3.0.1"
meta.description = "Lua package manager (Node.lua command-line tool)."
meta.tags        = { "lpm", "package", "command-line" }

-------------------------------------------------------------------------------
-- exports

local exports = { meta = meta }

exports.rootPath = app.rootPath
exports.rootURL  = app.rootURL

-------------------------------------------------------------------------------
-- config

local config = {}

-- split "name:key" string
local function parseName(name) 
	local pos = name:find(':')
	if (pos) then
		return name:sub(1, pos - 1), name:sub(pos + 1)
	else
		return 'user', name
	end
end

function config.commit(name)

end

-- 删除指定名称的配置参数项的值
function config.del(name)
	if (not name) then
		print("Error: the '<key>' argument was not provided.")
		print('Usage: lpm del <key>')
		return
	end

	local file, key = parseName(name)

	local profile = conf(file or 'user')
	if (profile:get(key)) then
		profile:set(key, nil)
		profile:commit()
	end

	print('del `' .. tostring(name) .. '`')
end

-- 打印指定名称的配置参数项的值
function config.get(name)
	if (not name) then
		print("Error: the '<key>' argument was not provided.")
		print('Usage: lpm get <key>')
		return
	end

	local file, key = parseName(name)

	local profile = conf(file or 'user')
	console.log(profile:get(key))
end

function config.help()
	local text = [[

Manage the lpm configuration files

Usage: 
  lpm config del <key>         - Deletes the key from configuration files.
  lpm config get <key>         - Echo the config value to stdout.
  lpm config list              - Show all config files
  lpm config list <name>       - Show all the config settings.
  lpm config set <key> <value> - Sets the config key to the value.
  lpm get <key>                - Echo the config value to stdout.
  lpm set <key> <value>        - Sets the config key to the value.

key: "[filename:][root.]<name>", ex: "network:lan.mode"

Aliases: c, conf

]]

	print(console.colorful(text))
end

function config.list(name)
	if (not name) then
		local confPath = path.join(app.rootPath, 'conf')
		local files = fs.readdirSync(confPath)
		print(confPath .. ':')
		print(table.unpack(files))
		return
	end

	local profile = conf(name or 'user')

	print(profile.filename .. ': ')
	console.log(profile.settings)
end

-- 设置指定名称的配置参数项的值
function config.set(name, value)
	if (not name) or (not value) then
		print("Error: the '<key>' or '<value>' argument was not provided.")
		print('Usage: lpm set <key> <value>')
		return
	end

	local file, key = parseName(name)

	local profile = conf(file or 'user')
	local oldValue = profile:get(key)
	if (not oldValue) or (value ~= oldValue) then
		profile:set(key, value)
		profile:commit()
	end

	print('set `' .. tostring(name) .. '` = `' .. tostring(value) .. '`')
end

function exports.config(action, ...)
	local method = config[action or 'help']
	if (method) then
		return method(...)

	else
		config.help()
	end
end

exports.del  = config.del
exports.get  = config.get
exports.set  = config.set
exports.c    = exports.config
exports.conf = exports.config

-------------------------------------------------------------------------------
-- application

local _executeApplication = function (name, action, ...)
	--print(name, action, ...)
	if (not name) then
		print("Error: the '<name>' argument was not provided.")
		print("")
		return
	end

	local ret, err = app.execute(name, action, ...)	
	if (not ret) or (ret < 0) then
		print("Error: unknown command or application: '" .. tostring(name) .. "', see 'lpm help'")
		print("")
	end
end

local _sendMessage = function (method, params, callback)
	if (not method) then
		return
	end

	local rpc      = require('ext/rpc')
	local IPC_PORT = 53210
	rpc.call(IPC_PORT, method, params, function(err, result)
		if (err) then
			console.log(err) 
		else
			console.log(result)
		end
	end)
end

-- Display lpm bin path
function exports.bin()
	print(path.join(exports.rootPath, 'bin'))
end

-- Kill the application process
function exports.kill(name, ...)
	if (not name) then
		_executeApplication('lhost', 'help')
		return
	end

	_executeApplication('lhost', 'kill', name, ...)
end

-- Display the installed applications
function exports.list(name)
	app.printList(name)
end

-- Display the running application
function exports.ps(...)
	_executeApplication('lhost', 'list', ...)
end

-- Restart the application
function exports.restart(name, ...)
	if (not name) then
		_executeApplication('lhost', 'help')
		return
	end

	_executeApplication('lhost', 'restart', name, ...)
end

-- Display lpm root path
function exports.root()
	print(exports.rootPath)
end

-- Start a application
function exports.start(...)
	local list = table.pack(...)
	if (not list) or (#list <= 0) then
		_executeApplication('lhost', 'help')
		return
	end

	_executeApplication('lhost', 'enable', ...)

	for _, name in ipairs(list) do
		app.daemon(name)
	end
end

-- Stop the application
function exports.stop(name, ...)
	if (not name) then
		_executeApplication('lhost', 'help')
		return
	end

	_executeApplication('lhost', 'stop', name, ...)
end

-------------------------------------------------------------------------------
-- package & upgrade

function exports.check(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.check(...)
end

function exports.colors(...)
	console.colors(...)
end

function exports.connect(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.connect(...)
end

function exports.deploy(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.deploy(...)
end

function exports.disconnect(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.disconnect(...)
end

-- Install new packages
function exports.install(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.install(...)
end

-- Remove packages
function exports.remove(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.remove(...)
end

-- Retrieve new lists of packages
function exports.update(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.update(...)
end

function exports.sh(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.sh(...)
end

-- Perform an upgrade
function exports.upgrade(...)
	local upgrade 	= require('ext/upgrade')
	upgrade.upgrade(...)
end

function exports.try(command, action, ...)
	_executeApplication(command, action or 'start', ...)
end

-------------------------------------------------------------------------------
-- misc

-- Scanning for nearby devices
function exports.scan(...)
	_executeApplication('ssdp', 'scan', ...)
end

function exports.info(...)
	local path = package.path
	local list = path:split(';')
	print(console.colorful('${string}package.path:${normal}'))
	for i = 1, #list do
		print(list[i])
	end

	print(console.colorful('${string}package.cpath:${normal}'))
	local path = package.cpath
	local list = path:split(';')
	for i = 1, #list do
		print(list[i])
	end	

	print(console.colorful('${string}app.rootURL:  ${normal}') .. app.rootURL)
	print(console.colorful('${string}app.rootPath: ${normal}') .. app.rootPath)
	print(console.colorful('${string}app.target:   ${normal}') .. app.target())
	print(console.colorful('${string}os.arch:      ${normal}') .. os.arch())
	print(console.colorful('${string}os.time:      ${normal}') .. os.time())
	print(console.colorful('${string}os.uptime:    ${normal}') .. os.uptime())
	print(console.colorful('${string}os.clock:     ${normal}') .. os.clock())

end

-- Display the version information
function exports.version()
	local printVersion = function(name, version) 
		print(" - " .. (name or '') .. console.color('braces') .. 
			" v" .. (version or ''), console.color('normal'))
	end

	print("Node.lua v" .. tostring(process.version) .. ' with:')
	for k, v in pairs(process.versions) do
		printVersion(k, v)
	end

	local info = require('cjson')
	if (info and info.VERSION) then
		printVersion("cjson", info.VERSION)
	end

	local ret, info = pcall(require, 'lmbedtls.md')
	if (info and info._VERSION) then	
		printVersion("mbedtls", info.VERSION)
	end

	local ret, info = pcall(require, 'lsqlite')
	if (info and info.VERSION) then	
		printVersion("sqlite", info.VERSION)
	end

	local ret, info = pcall(require, 'miniz')
	if (info and info.VERSION) then	
		printVersion("miniz", info.VERSION)
	end

	local ret, info = pcall(require, 'lmedia')
	if (info and info.version) then	
		printVersion("lmedia", info.version())
	end	

	local ret, info = pcall(require, 'lhttp_parser')
	if (info and info.VERSION_MAJOR) then
		local version = math.floor(info.VERSION_MAJOR) .. "." .. info.VERSION_MINOR
		printVersion("http_parser", version)
	end	

	local filename = path.join(exports.rootPath, 'package.json')
	local packageInfo = json.parse(fs.readFileSync(filename))
	if (not packageInfo) then
		return
	end

	--console.log(packageInfo)
	print(string.format([[

System information:
- target: %s
- version: %s
	]], packageInfo.target, packageInfo.version))
end

function exports.usage()
	local fmt = [[

This is the CLI for Node.lua.

Usage: ${highlight}lpm <command> [args]${normal}

${braces}
where <command> is one of:
    config, connect, deploy, get, help, info, install, kill, list, ps, remove
    restart, root, scan, set, start, stop, update, upgrade${normal}

   or: ${highlight}lpm <name> <command> [args]${normal}

${braces}
where <name> is the name of the application, located in 
    ']] .. app.rootPath .. [[/app/', the supported values of <command>
    depend on the invoked application.${normal}

   or: ${highlight}lpm help - ${braces}involved overview${normal}

Start with 'lpm list' to see installed applications.
	]]

	print(console.colorful(fmt))
	print('lpm@' .. process.version)

end

-- Display the help information
function exports.help()
	local fmt = [[

lpm - lnode package manager.

${braces}This is the CLI for Node.lua, Node.lua is a 'universal' platform work across 
many different systems, enabling install, configure, running and remove 
applications and utilities for Internet of Things.${normal}

${highlight}usage: lpm <command> [args]${normal}

where <command> is one of:

${string}Developer Commands:${normal}

- connect <host>    ${braces}Connect to a device that support SSDP.${normal}
- deploy <host>     ${braces}Deploy the latest SDK to the device.${normal}
- install <name>    ${braces}Install a new application to the device.${normal}
- remove <name>     ${braces}Remove a application from the device.${normal}
- scan <timeout>    ${braces}Scan all devices that support SSDP.${normal}

${string}Configuration Commands:${normal}

- config <args>     ${braces}Manager Node.lua configuration options.${normal}
- get <key>         ${braces}Prints configuration options.${normal}
- set <key> <value> ${braces}Changes configuration options.${normal}

${string}Application Commands:${normal}

- kill <name>       ${braces}Kill a running application${normal}
- list <name>       ${braces}List all installed applications${normal}
- ps                ${braces}List all running applications${normal}
- restart <name>    ${braces}Restart a application in daemon mode${normal}
- start <name>      ${braces}Start a application in daemon mode${normal}
- stop <name>       ${braces}Stop the specified application to run in daemon mode${normal}
- try <name>        ${braces}Try to start a application without daemon mode${normal}

${string}Other Commands:${normal}

- help              ${braces}Get help on lpm${normal}
- root              ${braces}Display Node.lua root path${normal}
- update            ${braces}Retrieve new lists and packages of applications${normal}
- upgrade system    ${braces}Perform an system upgrade${normal}
- version           ${braces}Prints version informations${normal}
- info              ${braces}Prints system informations${normal}

]]

	print(console.colorful(fmt))
	print('lpm@' .. process.version .. ' at ' .. app.rootPath)

--[[
- clean             Clean old downloaded archive files
- publish           Publish for source packages
--]]

end

-------------------------------------------------------------------------------
-- call

function exports.call(args)
	local command = args[1]
	table.remove(args, 1)

	local func = exports[command or 'usage']
	if (type(func) == 'function') then
		local status, ret = pcall(func, table.unpack(args))
		run_loop()

		if (not status) then
			print(ret)
		end

		return ret

	else
		_executeApplication(command, table.unpack(args))
	end
end

setmetatable(exports, {
	__call = function(self, ...) 
		self.call(...)
	end
})

return exports
