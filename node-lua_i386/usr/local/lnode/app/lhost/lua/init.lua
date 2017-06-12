local app       = require('app')
local utils     = require('utils')
local path      = require('path')
local fs        = require('fs')

local exports = {}

-------------------------------------------------------------------------------
-- 

-- 通过 cmdline 解析出相关的应用的名称
function exports.name(cmdline)
    local _, _, appName = cmdline:find('lnode.+/([%w]+)/init.lua')

    if (not appName) then
        _, _, appName = cmdline:find('lnode.+/lpm%S([%w]+)%Sstart')
    end

    if (not appName) then
        _, _, appName = cmdline:find('lnode.+/lpm%Sstart%S([%w]+)')
    end    

    return appName
end

local LHOST_LIST_FILE = '/tmp/lhost.list'

function exports.settings()
    local filedata = fs.readFileSync(LHOST_LIST_FILE)
    local names = {}
    local count = 0

    if (not filedata) then
        return names, count, filedata
    end

    local list = filedata:split("\n")
    for _, item in ipairs(list) do
        if (#item > 0) then
            local filename = path.join(app.rootPath, 'app', item)
            --print(filename, app.rootPath)
            if fs.existsSync(filename) then
                names[item] = item
                count = count + 1
            end
        end
    end
    
    return names, count, filedata
end

-- 返回包含所有正在运行中的应用进程信息的数组
-- @return {Array} 返回 [{ name = '...', pid = ... }, ... ]
function exports.list()
    local list = {}
    local count = 0

    local files = fs.readdirSync('/proc') or {}
    if (not files) or (#files <= 0) then
        print('This command only support Linux!')
        return
    end

    for _, file in ipairs(files) do
        local pid = tonumber(file)
        if (not pid) then
            goto continue
        end

        local filename = path.join('/proc', file, 'cmdline')
        if not fs.existsSync(filename) then
            goto continue
        end

        local cmdline = fs.readFileSync(filename) or ''
        local name = exports.name(cmdline)
        if (name) then
            table.insert(list, {name = name, pid = pid})
            count = count + 1
        end

        ::continue::
    end

    return list, count
end

function exports.enable(newNames, enable)
    local names, count, oldData = exports.settings()

    for _, name in ipairs(newNames) do
        if (enable) then
            local filename = path.join(app.rootPath, 'app', name)
            if (fs.existsSync(filename)) then
                names[name] = name
            end

        else
            names[name] = nil
        end
    end
    
    -- save to file
    local list = {}
    for _, item in pairs(names) do
        list[#list + 1] = item
    end

    table.sort(list, function(a, b)
        return tostring(a) < tostring(b)
    end)

    list[#list + 1] = ''

    local fileData = table.concat(list, "\n")
    if (oldData == fileData) then
        return fileData
    end

    print("Updating services table...")
    print("  " .. table.concat(list, " ") .. "\n")

    local tempname = LHOST_LIST_FILE .. ".tmp"
    if fs.writeFileSync(tempname, fileData) then
        os.remove(LHOST_LIST_FILE)
        os.rename(tempname, LHOST_LIST_FILE)
    end

    return fileData
end

return exports
