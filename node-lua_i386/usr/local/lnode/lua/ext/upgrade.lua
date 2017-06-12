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

local core      = require('core')
local fs        = require('fs')
local http      = require('http')
local json      = require('json')
local miniz     = require('miniz')
local path      = require('path')
local thread    = require('thread')
local timer     = require('timer')
local url       = require('url')
local utils     = require('utils')
local qstring   = require('querystring')

local request  	= require('http/request')
local conf   	= require('ext/conf')
local ext   	= require('ext/utils')


--[[
Node.lua 系统更新程序
======

这个脚本用于自动在线更新 Node.lua SDK, 包含可执行主程序, 核心库, 以及核心应用等等

--]]

local exports = {}

local formatFloat 		= ext.formatFloat
local formatBytes 		= ext.formatBytes
local noop 		  		= ext.noop
local getSystemTarget 	= ext.getSystemTarget

local SSDP_WEB_PORT 	= 9100

local function getRootPath()
	return conf.rootPath
end

local function getRootURL()
	return require('app').rootURL
end

local function isDevelopmentPath(rootPath)
	local filename1 = path.join(rootPath, 'lua/lnode')
	local filename2 = path.join(rootPath, 'app/build')
	local filename3 = path.join(rootPath, 'src')
	if (fs.existsSync(filename1) or fs.existsSync(filename2) or fs.existsSync(filename3)) then
		print('The "' .. rootPath .. '" is a development path.')
		print('You can not update the system in development mode.\n')
		return true
	end

	return false
end

-- 检查是否有另一个进程正在更新系统
local function upgradeLock()
	local tmpdir = os.tmpdir or '/tmp'

	print("Try to lock upgrade...")

	local lockname = path.join(tmpdir, '/update.lock')
	local lockfd = fs.openSync(lockname, 'w+')
	local ret = fs.fileLock(lockfd, 'w')
	if (ret == -1) then
		print('The system update is already locked!')
		return nil
	end

	return lockfd
end

local function upgradeUnlock(lockfd)
	fs.fileLock(lockfd, 'u')
end

-------------------------------------------------------------------------------
-- BundleReader

local BundleReader = core.Emitter:extend()
exports.BundleReader = BundleReader

function BundleReader:initialize(basePath, files)
	self.basePath = basePath
	self.files    = files or {}
end

function BundleReader:locate_file(filename)
	for i = 1, #self.files do
		if (filename == self.files[i]) then
			return i
		end
	end
end

function BundleReader:extract(index)
	if (not self.files[index]) then
		return
	end

	local filename = path.join(self.basePath, self.files[index])

	--console.log(filename)
	return fs.readFileSync(filename)
end

function BundleReader:get_num_files()
	return #self.files
end

function BundleReader:get_filename(index)
	return self.files[index]
end

function BundleReader:stat(index)
	if (not self.files[index]) then
		return
	end

	local filename = path.join(self.basePath, self.files[index])
	local statInfo = fs.statSync(filename)
	statInfo.uncomp_size = statInfo.size
	return statInfo
end

function BundleReader:is_directory(index)
	local filename = self.files[index]
	if (not filename) then
		return
	end

	return filename:endsWith('/')
end

local function createBundleReader(filename)

	local listFiles 

	listFiles = function(list, basePath, filename)
		--print(filename)

		local info = fs.statSync(path.join(basePath, filename))
		if (info.type == 'directory') then
			list[#list + 1] = filename .. "/"

			local files = fs.readdirSync(path.join(basePath, filename))
			if (not files) then
				return
			end

			for _, file in ipairs(files) do
				listFiles(list, basePath, path.join(filename, file))
			end

		else

			list[#list + 1] = filename
		end
	end


	local info = fs.statSync(filename)
	if (not info) then
		return
	end

	if (info.type == 'directory') then
		local filedata = fs.readFileSync(path.join(filename, "package.json"))
		local packageInfo = json.parse(filedata)
		if (not packageInfo) then
			return
		end

		local files = fs.readdirSync(filename)
		if (not files) then
			return
		end

		local list = {}

		for _, file in ipairs(files) do
			listFiles(list, filename, file)
		end

		--console.log(list)
		return BundleReader:new(filename, list)

	else
		return miniz.new_reader(filename)
	end
end

-------------------------------------------------------------------------------
-- BundleUpdater

local BundleUpdater = core.Emitter:extend()
exports.BundleUpdater = BundleUpdater

function BundleUpdater:initialize(options)
	self.filename = options.filename
	self.rootPath = options.rootPath

end

-- Check whether the specified file need to updated
-- @param checkInfo 需要的信息如下:
--  - rootPath 目标路径
--  - reader 
--  - index 源文件索引
-- @return 0: not need update; other: need updated
-- 
function BundleUpdater:checkFile(index)
	local join   	= path.join
	local rootPath  = self.rootPath
	local reader   	= self.reader
	local filename  = reader:get_filename(index)
	if (filename == 'install.sh') then
		return 0 -- ignore `install.sh
	end

	local destname 	= join(rootPath, filename)
	local srcInfo   = reader:stat(index)

	if (reader:is_directory(index)) then
		fs.mkdirpSync(destname)
		return 0
	end
	--console.log(srcInfo)

	self.totalBytes = (self.totalBytes or 0) + srcInfo.uncomp_size
	self.total      = (self.total or 0) + 1

	--thread.sleep(10) -- test only

	-- check file size
	local destInfo 	= fs.statSync(destname)
	if (destInfo == nil) then
		return 1

	elseif (srcInfo.uncomp_size ~= destInfo.size) then 
		return 2
	end

	-- check file hash
	local srcData  = reader:extract(index)
	local destData = fs.readFileSync(destname)
	if (srcData ~= destData) then
		return 3
	end

	return 0
end

-- Check for files that need to be updated
-- @param checkInfo
--  - reader 
--  - rootPath 目标路径
-- @return 
-- checkInfo 会被更新的值:
--  - list 需要更新的文件列表
--  - updated 需要更新的文件数
--  - total 总共检查的文件数
--  - totalBytes 总共占用的空间大小
function BundleUpdater:checkSystemFiles()
	local count = self.reader:get_num_files()
	for index = 1, count do
		self.index = index
		self:emit('check', index)

		local ret = self:checkFile(index)
		if (ret > 0) then
			self.updated = (self.updated or 0) + 1
			table.insert(self.list, index)
		end
	end

	self:emit('check')
end

-- 检查系统存储空间
-- 主要是为了检查是否有足够的剩余空间用来更新固件
function BundleUpdater:checkStorage()
	-- check storage size
	local lutils = require('lutils')
	local statInfo = lutils.os_statfs(self.rootPath)
	if (not statInfo) then
		return
	end

	local totalSize = statInfo.blocks * statInfo.bsize
	local freeSize  = statInfo.bfree  * statInfo.bsize
	if (totalSize > 0) then
		local percent = math.floor(freeSize * 100 / totalSize)
		print(string.format('storage: %s/%s percent: %d%%', 
			formatBytes(freeSize), 
			formatBytes(totalSize), percent))
	end
end

-- Update the specified file
-- @param rootPath 目标目录
-- @param reader 文件源
-- @param index 文件索引
-- 
function BundleUpdater:updateFile(rootPath, reader, index)
	local join 	 	= path.join

	--thread.sleep(10) -- test only

	if (not rootPath) or (not rootPath) then
		return -6, 'invalid parameters' 
	end

	local filename = reader:get_filename(index)
	if (not filename) then
		return -5, 'invalid source file name: ' .. index 
	end	

	-- read source file data
	local fileData 	= reader:extract(index)
	if (not fileData) then
		return -3, 'invalid source file data: ', filename 
	end

	-- write to a temporary file and check it
	local tempname = join(rootPath, filename .. ".tmp")
	local dirname = path.dirname(tempname)
	fs.mkdirpSync(dirname)

	local ret, err = fs.writeFileSync(tempname, fileData)
	if (not ret) then
		return -4, err, filename 
	end

	local destInfo = fs.statSync(tempname)
	if (destInfo == nil) then
		return -1, 'not found: ', filename 

	elseif (destInfo.size ~= #fileData) then
		return -2, 'invalid file size: ', filename 
	end

	-- rename to dest file
	local destname = join(rootPath, filename)
	os.remove(destname)
	local destInfo = fs.statSync(destname)
	if (destInfo ~= nil) then
		return -1, 'failed to remove old file: ' .. filename 
	end

	os.rename(tempname, destname)
	return 0, nil, filename
end

-- Update all Node.lua system files
-- 安装系统更新包
-- @param checkInfo 更新包
--  - reader 
--  - rootPath
-- @param files 要更新的文件列表, 保存的是文件在 reader 中的索引.
-- @param callback 更新完成后调用这个方法
-- @return 
-- checkInfo 会更新的属性:
--  - faileds 更新失败的文件数
function BundleUpdater:updateSystemFiles(callback)
	callback = callback or noop

	local rootPath = self.rootPath
	local files = self.list or {}
	print('Upgrading system "' .. rootPath .. '" (total ' 
		.. #files .. ' files need to update).')

	--console.log(self)

	local count = 1
	for _, index in ipairs(files) do

		local ret, err, filename = self:updateFile(rootPath, self.reader, index)
		if (ret ~= 0) then
			--print('ERROR.' .. index, err)
            self.faileds = (self.faileds or 0) + 1
		end

		self:emit('update', count, filename, ret, err)
		count = count + 1
	end

	self:emit('update')

	os.execute("chmod 777 " .. rootPath .. "/bin/*")

	callback(nil, self)
end

-- 安装系统更新包
-- @param checkInfo 更新包
--  - filename 
--  - rootPath
-- @param callback 更新完成后调用这个方法
-- @return
-- checkInfo 会更新的属性:
--  - list
--  - total
--  - updated
--  - totalBytes
--  - faileds
-- 
function BundleUpdater:upgradeSystemPackage(callback)
	callback = callback or noop

	local filename 	= self.filename
	if (not filename) or (filename == '') then
		callback("Upgrade error: invalid filename")
		return
	end

	--print('update file: ' .. tostring(filename))
	print('\nInstalling package (' .. filename .. ')')

	local reader = createBundleReader(filename)
	if (reader == nil) then
		callback("Upgrade error: bad package bundle file", filename)
		return
	end

    local filename = path.join('package.json')
	local index, err = reader:locate_file(filename)
    if (not index) then
		callback('Upgrade error: `package.json` not found!', filename)
        return
    end

    local filedata = reader:extract(index)
    if (not filedata) then
    	callback('Upgrade error: `package.json` not found!', filename)
    	return
    end

    local packageInfo = json.parse(filedata)
    if (not packageInfo) then
    	callback('Upgrade error: `package.json` is invalid JSON format', filedata)
    	return
    end

    -- 验证安装目标平台是否一致
    if (packageInfo.target) then
		local target = getSystemTarget()
		if (target ~= packageInfo.target) then
			callback('Upgrade error: Mismatched target: local is `' .. target .. 
				'`, but the update file is `' .. tostring(packageInfo.target) .. '`')
	    	return
		end

	elseif (packageInfo.name) then
		self.name     = packageInfo.name
		self.rootPath = path.join(self.rootPath, 'app', self.name)

	else
		callback("Upgrade error: bad package information file", filename)
		return
	end

	self.list 		= {}
	self.total 	 	= 0
    self.updated 	= 0
	self.totalBytes = 0
    self.faileds 	= 0
    self.version    = packageInfo.version
    self.target     = packageInfo.target
	self.reader	 	= reader

	self:checkSystemFiles()
	self:updateSystemFiles(callback)
end

function BundleUpdater:showUpgradeResult()
	if (self.faileds and self.faileds > 0) then
		print(string.format('Total (%d) error has occurred!', self.faileds))

	elseif (self.updated and self.updated > 0) then
		print(string.format('Total (%d) files has been updated!', self.updated))

	else
		print('\nFinished\n')
	end
end

-------------------------------------------------------------------------------
-- download

-- Download system patch file
local function downloadSystemPackage(options, callback)
	callback = callback or noop

	local rootPath  = getRootPath()
	local basePath  = path.join(rootPath, 'update')
	fs.mkdirpSync(basePath)

	local filename = path.join(basePath, '/update.zip')

	-- 检查 SDK 更新包是否已下载
	local packageInfo = options.packageInfo
	--print(packageInfo.size, packageInfo.md5sum)
	if (packageInfo and packageInfo.size) then
		local filedata = fs.readFileSync(filename)
		if (filedata and #filedata == packageInfo.size) then
			local md5sum = utils.bin2hex(utils.md5(filedata))
			--print('md5sum', md5sum)

			if (md5sum == packageInfo.md5sum) then
				print("The update file is up-to-date!", filename)
				callback(nil, filename)
				return
			end
		end
	end

	-- 下载最新的 SDK 更新包
	request.download(options.url, {}, function(err, percent, response)
		if (err) then 
			print(err)
			callback(err)
			return 
		end

		if (percent == 0 and response) then
			local contentLength = tonumber(response.headers['Content-Length']) or 0

			print('Downloading package (' .. ext.formatBytes(contentLength) .. ').')
		end

		if (percent <= 100) then
			console.write('\rDownloading package (' .. percent .. '%)...  ')
		end

		if (percent < 100) or (not response) then
			return
		end

		-- write to a temp file
		print('Done!')

		os.remove(filename)
		fs.writeFile(filename, response.body, function(err)
			if (err) then callback(err) end
			callback(nil, filename)
		end)
	end)
end

-- Download system 'package.json' file
local function downloadSystemInfo(options, callback)
	options = options or {}
	local printInfo = options.printInfo or function() end

	-- URL
	local arch      = os.arch()
	local target 	= getSystemTarget()
	local rootURL 	= getRootURL()
	local baseURL 	= rootURL .. '/download/dist/' .. target
	local url 		= baseURL .. '/nodelua-' .. target .. '-sdk.json'

	printInfo("System target: " .. arch .. '-' .. target)
	printInfo("Upgrade server: " .. rootURL)	
	printInfo('URL: ' .. url)

	request.download(url, {}, function(err, percent, response)
		if (err) then
			callback(err)
			return

		elseif (percent < 100) or (not response) then
			return
		end

		--console.log(response.body)
		local packageInfo = json.parse(response.body)
		if (not packageInfo) or (not packageInfo.version) then
			callback("Invalid system package information.")
			return
		end

		--console.log('latest version: ' .. tostring(packageInfo.version))
		local rootPath  = getRootPath()
		local basePath  = path.join(rootPath, 'update')
		fs.mkdirpSync(basePath)

		local filename 	= path.join(basePath, 'package.json')
		local filedata  = fs.readFileSync(filename)
		if (filedata == response.body) then
			print("The system information is up-to-date!")
			callback(nil, packageInfo)
			return
		end

		local tempname 	= path.join(basePath, 'package.json.tmp')
		os.remove(tempname)

		fs.writeFile(tempname, response.body, function(err)
			if (err) then callback(err) end

			os.remove(filename)
			os.rename(tempname, filename)

			print("System information saved to: " ..  filename)
			callback(nil, packageInfo)
		end)
	end)
end

-- download system 'package.json' and patch files
local function downloadUpdateFiles(options, callback)
	options = options or {}
	local printInfo = options.printInfo or function() end

	downloadSystemInfo(options, function(err, packageInfo)
		if (err) then 
			callback(err)
			return
		end

		-- System update filename
		if (not packageInfo) or (not packageInfo.filename) then
			callback("Bad package information format!")
			return
		end

		printInfo("Done.")

		-- System update URL
		local target 	= getSystemTarget()
		local rootURL 	= getRootURL()
		local baseURL 	= rootURL .. '/download/dist/' .. target
		local url 		= baseURL .. '/' .. packageInfo.filename
		printInfo('Package url: ' .. url)

		-- downloading
		local options = {}
		options.url 		= url
		options.packageInfo = packageInfo
		downloadSystemPackage(options, function(err, filename)
			printInfo("Done.")
			callback(err, filename, packageInfo)
		end)

	end)
end

-- Update system update file
local function updateUpdateFile(filename)
	local rootPath  = getRootPath()
	local basePath  = path.join(rootPath, 'update')
	local destFile  = path.join(basePath, 'update.zip')

	if (filename == destFile) then
		return filename
	end

	local statInfo1  = fs.statSync(filename) or {}
	if (statInfo1.type == 'directory') then
		return filename
	end
	local sourceSize = statInfo1.size or 0

	local statInfo2  = fs.statSync(destFile) or {}
	local destSize   = statInfo2.size or 0

	if (sourceSize == destSize) then
		print("The update file is up-to-date!")
		return destFile
	end

	fs.mkdirpSync(basePath)

	local fileData = fs.readFileSync(filename)
	if (fileData) then
		fs.writeFileSync(destFile, fileData)
		print("Copy update.zip to " .. destFile)
		return destFile
	end

	return filename
end

-------------------------------------------------------------------------------
-- exports

function exports.check()
	local target = getSystemTarget()
	local options = {
		printInfo = function(...)
			print(...)
		end
	}

	downloadSystemInfo(options, function(err, packageInfo)
		if (err) then 
			print(err)
			return
		end

		if (not packageInfo) or (not packageInfo.filename) then
			print("Bad package information format!")
			return
		end

		print('')
		local grid = ext.table({20, 50})
		grid.line()
		grid.title('System information')
		grid.line('=')
		grid.cell('target      ', tostring(packageInfo.target))
		grid.cell('arch        ', tostring(packageInfo.arch))
		grid.cell('description ', tostring(packageInfo.description))
		grid.cell('version     ', tostring(packageInfo.version))
		grid.cell('mtime       ', tostring(packageInfo.mtime))
		grid.cell('size        ', tostring(packageInfo.size))
		grid.cell('md5sum      ', tostring(packageInfo.md5sum))
		grid.cell('applications', json.stringify(packageInfo.applications))
		grid.cell('Update file ', packageInfo.filename)
		grid.line()

		print('')
		print("Done.")
	end)
end

function exports.connect(hostname, password)
	-- TODO: connect
	if (not hostname) or (not password) then
		print('\nUsage: lpm connect <hostname> <password>')

	end

	local grid = ext.table({20, 40})

	local deploy = conf('deploy')
	if (deploy) then

		if (hostname) then
			deploy:set('hostname', hostname)
		end

		if (password) then
			deploy:set('password', password)
		end

		deploy:commit()

		print('')
		print(' = Current settings:')
		print('')

		grid.cell('key', 'value')
		grid.line('=')
		grid.cell('hostname', (deploy:get('hostname') or '-'))
		grid.cell('password', (deploy:get('password') or '-'))
		grid.line()
		print('')

		hostname = deploy:get('hostname')
	end

	if (not hostname) then
		return
	end
		
	print("Reading device information...")
	local url = "http://" .. hostname .. ":" .. SSDP_WEB_PORT .. "/device"
    request(url, function(err, response, data)
        --console.log(err, data)

        if (err) then
            print(err)
            return
        end

        local data = json.parse(data) or {}
        local device = data.device or {}
        --console.log('device info:', device)

		print('')
		print(' = Device information:')
		print('')

		grid.cell('key', 'value')
        grid.line('=')
        for key, value in pairs(device) do
        	if (type(value) == 'table') then
        		value = '{}'
        	end
        	grid.cell(key, value)
        end

        grid.line()

        print('')

        print(' = Finish.')
    end)

end

function exports.sh(cmd, ...)
	if (not cmd) then
		print("Error: the '<cmd>' argument was not provided.")
		print("Usage: lpm sh <cmd> [args...]")
		return
	end

	local deploy = conf('deploy')
	local hostname = deploy:get('hostname')
	if (not hostname) then
		print("Error: the '<hostname>' argument was not provided.")
		print("Please use 'lpm connect' to provide a hostname.")
		return
	end

	local url = "http://" .. hostname .. ":" .. SSDP_WEB_PORT .. "/shell"
	local params = table.pack(...)
	if (#params > 0) then
		cmd = cmd .. ' ' .. table.concat(params, ' ')
	end

	url = url .. '?cmd=' .. qstring.escape(cmd)

	--console.log(url)
    request(url, function(err, response, data)
        --console.log(err, data)

        if (err) then
            print(err)
            return
        end

        local result = json.parse(data) or {}
        if (result.output) then
        	print(result.output)
        	return
        else 
        	print('device returned: ', result.error or result.ret)
        end
    end)
end

function exports.deploy(hostname, password)
	print("\nUsage: lpm deploy <hostname> <password>\n")

	if (not hostname) then
		local deploy = conf('deploy')
		hostname = deploy:get('hostname')
		password = password or deploy:get('password')

		if (not hostname) then
			print("Need hostname!")
			return
		end
	end

	local timerId

	local onDeployResponse = function(err, percent, response, body)
		clearInterval(timerId)

		if (err) then print(err) return end

		if (not response) then
			console.write('\rUploading (' .. percent .. '%)...')
			return
		end
		
		local result = json.parse(body) or {}
		if (result.ret ~= 0) then
			print('\nDeploy error: ' .. tostring(result.error))
			return
		end

		print('\nDeploy result:\n')

		local grid = ext.table({20, 40})
		grid.line()
		grid.cell('Key', 'Value')
		grid.line('=')
		for key, value in pairs(result.data) do 
			grid.cell(key, value)
		end
		grid.line()

		print('\nFinish.')
	end

	local onGetDeviceInfo = function(err, response, body)
		if (err) then print('\nConnect to server failed: ', err) return end

		local systemInfo = json.parse(body) or {}
		local device = systemInfo.device
		if (not device) then
			print('\nInvalid device info')
			return
		end

		local target  = device.target
		local version = device.version
		if (not target) then
			print('\nInvalid device target type')
			return
		end

		print('\rChecking "' .. hostname .. '"... [done]')
		print('Current device version: ' .. target .. '@' .. tostring(version))

		local filename = path.join(process.cwd(), 'build', 'nodelua-' .. target .. '-sdk.zip');
		console.write('Reading "' .. filename .. '"...')

		if (not fs.existsSync(filename)) then
			print('\nDeploy failed: Update file not found, please build it firist!')
			return
		end

		local filedata = fs.readFileSync(filename)
		if (not filedata) then
			print('\nDeploy failed: Invalid update file!')
			return
		end

		print('\rReading "' .. filename .. '"...  [' .. #filedata .. ' Bytes]')

		timerId = setInterval(500, function()
			console.write('.')
		end)

		local url = 'http://' .. hostname .. ':' .. SSDP_WEB_PORT .. '/upgrade'
		print('Uploading to "' .. url .. '"...')

		local options = { data = filedata }
		request.upload(url, options, onDeployResponse)
	end

	-- 
	console.write('Checking "' .. hostname .. '"...')
	local url = 'http://' .. hostname .. ':' .. SSDP_WEB_PORT .. '/device'
	request(url, onGetDeviceInfo)
end

function exports.disconnect()
	local deploy = conf('deploy')
	if (deploy) then
		deploy:set('hostname', nil)
		deploy:set('password', nil)
		deploy:commit()

		print("Disconnected!")
	end
end

function exports.help()
	print(console.colorful[[

${braces}Node.lua packages upgrade tools${normal}

Usage:
  lpm connect [hostname] [password] ${braces}Connect a device with password${normal}
  lpm deploy [hostname] [password]  ${braces}Update all packages on the device${normal}
  lpm disconnect                    ${braces}Disconnect the current device${normal}
  lpm install [name]                ${braces}Install a application to the device${normal}
  lpm remove [name]                 ${braces}Remove a application on the device${normal}
  lpm scan [timeout]                ${braces}Scan devices${normal}
  lpm upgrade [name] [rootPath]     ${braces}Update all packages${normal}

upgrade: 
  ${braces}This command will update all the packages listed to the latest version
  If the package <name> is "all", all packages in the specified location
  (global or local) will be updated.${normal}

deploy:
  ${braces}Update all packages on the device to the latest version.${normal}

]])

end

function exports.remove(name)
	if (not name) or (name == '') then
		print([[
Usage: lpm remove [options] <name>

options:
  -g remove from global path
]])		
		return
	end

	local appPath = path.join(path.dirname(os.tmpname()), 'app')
	local filename = path.join(appPath, name) or ''
	if (fs.existsSync(filename)) then
		os.execute("rm -rf " .. filename)
		print("removed: '" .. filename  .. "'")
	else
		print("not exists: '" .. filename  .. "'")
	end

end

function exports.installApplication(name)
	local dest = nil
	if (name == '-g') then
		dest = 'global'
		name = nil
	end

	if (not name) then
		print([[
Usage: lpm install [options] <name>

options:
  -g install to global
]])
	end

	-- application name
	local package = require('ext/package')

	if (name) then
		package.pack(name)

	else
		local info  = app.info(name)
		if (info) then
			name = info.name
			package.pack()
		end

		if (not name) or (name == '') then
			local filename = path.join(process.cwd(), 'packages.json') or ''
			print("Install: no such file, open '" .. filename .. "'")
			return
		end
	end

	-- update file
	local tmpdir = path.dirname(os.tmpname())
	local buildPath = path.join(tmpdir, 'packages')
	local filename = path.join(buildPath, "" .. name .. ".zip")
	print("Install: open '" .. filename .. "'")

	if (not fs.existsSync(filename)) then
		print('Install: no such application update file, please build it first!')
		return
	end

	-- hostname
	local deploy = conf('deploy')
	local hostname = deploy:get('hostname')
	password = password or deploy:get('password')

	-- update file content
	local filedata = fs.readFileSync(filename)
	if (not filedata) then
		print('Install failed:  Invalid update file content!')
		return
	end

	-- post file
	print('Install [' .. name .. '] to [' .. hostname .. ']')

	local options = {data = filedata}

	local url = 'http://' .. hostname .. ':' .. SSDP_WEB_PORT .. '/install'
	if (dest) then
		url = url .. "?dest=" .. dest
	end

	print('Install url:    ' .. url)
	local request = require('http/request')
	request.post(url, options, function(err, response, body)
		if (err) then print(err) return end

		local result = json.parse(body) or {}
		if (result.ret == 0) then
			console.log(result.data)
			print('Install finish!')
		else
			print('Install error: ' .. tostring(result.error))
		end
	end)
end

function exports.install(filename)
	return exports.upgrade(filename)
end

function exports.handleInstallPost(data, query, callback)
    print('Upload complete.')

    local filename = '/tmp/install.zip'
    if (not data) then
        callback({ ret = -1, error = 'Bad request' })
        return
    end

    print('file', filename, #data)

    query = query or {}
    local dest = query.dest

    os.remove(filename)
    fs.writeFileSync(filename, data)

    local options = {}
	options.filename   = filename or '/tmp/install.zip'
	options.rootPath   = getRootPath()

	local updater = BundleUpdater:new(options)
	updater:upgradeSystemPackage(function(err)
        local result = { ret = 0, error = err }

        if (updater.faileds and updater.faileds > 0) then
            result.ret = -1
            result.error = string.format('(%d) error has occurred in the upgrade!', updater.faileds)
        end

        local data = {}
        data.total      = updater.total
        data.totalBytes = updater.totalBytes
        data.updated    = updater.updated
        data.faileds    = updater.faileds
        data.rootPath   = updater.rootPath
        data.name       = updater.name
        result.data = data

        callback(result)
    end)
end

function exports.handleUpgradePost(data, query, callback)
    if (not data) then
        callback({ ret = -1, error = 'Bad request' })
        return
    end

    query = query or {}

    local filename = '/tmp/update.zip'
    print('file', filename, #data)

    os.remove(filename)
    fs.writeFileSync(filename, data)

    exports.upgrade(filename, function(err, updater)
        local result = { ret = 0, error = err }
        updater = updater or {}

        if (updater.faileds and updater.faileds > 0) then
            result.ret = -1
            result.error = string.format('(%d) error has occurred in the upgrade!', checkInfo.faileds)
        end

        local data = {}
        data.total      = updater.total
        data.totalBytes = updater.totalBytes
        data.updated    = updater.updated
        data.faileds    = updater.faileds
        data.rootPath   = updater.rootPath
        data.name       = updater.name
        result.data = data

        callback(result)
    end)
end

function exports.recovery()
	local destpath   = '/usr/local/lnode'
	local updatefile = path.join(destpath, 'update/update.zip')
	exports.install(updatefile, destpath)
end

function exports.update(callback)
	if (type(callback) == 'function') then
		downloadUpdateFiles(options, callback)
		return
	end

	local options = {}
	callback = function(err, filename, packageInfo)
		packageInfo = packageInfo or {}

		--console.log(err, filename, packageInfo)
		if (err) then
			print('err: ', err)

		else
			print('latest version: ' .. tostring(packageInfo.version))
		end
	end

	options.printInfo = function(...) print(...) end

	downloadUpdateFiles(options, callback)
end

--[[
更新系统

--]]
function exports.upgrade(source, callback)
	local rootPath = getRootPath()
	if (isDevelopmentPath(rootPath)) then
		rootPath = '/tmp/lnode'
		--return
	end

	if (type(callback) ~= 'function') then
		callback = nil
	end


	--console.log(source, rootPath)

	local lockfd = upgradeLock()
	if (not lockfd) then
		return
	end

	local onStartUpgrade = function(err, filename)
		if (err) then
			upgradeUnlock(lockfd)
			return
		end

		local options = {}
		options.filename 	= filename
		options.rootPath 	= rootPath

		local updater = BundleUpdater:new(options)
		if (not callback) then 
			updater:on('check', function(index)
				if (index) then
					console.write('\rChecking (' .. index .. ')...  ')
				else 
					print('')
				end
			end)

			updater:on('update', function(index, filename, ret, err)
				local total = updater.updated or 0
				if (index) then
					console.write('\rUpdating (' .. index .. '/' .. total .. ')...  ')
					if (ret == 0) then
						print(filename or '')
					end
				else
					print('')
				end
			end)
		end

		updater:upgradeSystemPackage(function(err)
			upgradeUnlock(lockfd)

			if (callback) then 
				callback(err, updater)
				return 
			end

			if (err) then print(err) end
			updater:showUpgradeResult()
		end)
	end

	print("Upgrade path: " .. rootPath)

	if source and (source:startsWith("/")) then
		-- 从本地文件升级
		-- function(filename, rootPath)

		local destFile = updateUpdateFile(source)
		onStartUpgrade(nil, destFile)

	elseif (source == "system") then
		-- Upgrade form network
		downloadUpdateFiles({}, onStartUpgrade)

	else
		upgradeUnlock(lockfd)
		print("Unknow upgrade source: " .. (source or 'nil'))
	end
end

return exports
