local app       = require('app')
local utils     = require('utils')
local path      = require('path')
local fs        = require('fs')
local lhost     = require('lhost')

-------------------------------------------------------------------------------
-- exports

local exports = {}

app.name = 'lhost'

-- 检查应用进程，自动重启意外退出的应用程序
function exports.check()
    local names = lhost.settings()
    local procs = lhost.list()

    for _, proc in ipairs(procs) do
        names[proc.name] = nil
    end

    for name, pid in pairs(names) do
        console.log('restart:', name)
        os.execute("lpm start " .. name)
    end
end

-- 不允许指定名称的应用在后台一直运行
function exports.disable(...)
    local names = table.pack(...)
    if (#names < 1) then
        exports.help()
        return
    end

    lhost.enable(names, false)
end

-- 允许指定名称的应用在后台一直运行
function exports.enable(...)
    local names = table.pack(...)
    if (#names < 1) then
        exports.help()
        return
    end

    lhost.enable(names, true)
end

function exports.help()
    print([[
        
usage: lpm lhost <command> [args]

Node.lua application daemon manager

running file:
    
- /tmp/lhost.list

Available command:

- check              Check all application daemon status
- disable [name...]  Disable application daemon
- enable [name...]   Enable application daemon
- help               Display help information
- start [interval]   Start lhost
- status             Show status

Available top command:

- lpm start [name]   Start the application
- lpm stop [name]    Stop the application
- lpm restart all    Restart all application
- lpm restart [name] Restart the application
- lpm kill [name]    Kill the application only
- lpm ps             List all running application

Settings:
- lhost:start        Start applications list

]])
end

-- 杀掉指定名称的应用的所有进程
function exports.kill(name)
    if (not name) then
        print('APP name expected!')
        exports.help()
        return
    end

    local found = nil

    local list = lhost.list()
    if (not list) or (#list < 1) then
        return
    end

    for _, proc in ipairs(list) do
        if (proc.name == name) then
            local cmd = "kill " .. proc.pid
            print("kill (" .. name .. ") " .. proc.pid)
            os.execute(cmd)

            found = pid
        end
    end
end

-- 列出所有正在运行的应用程序
function exports.list()
    local names = lhost.settings()
    local list  = lhost.list()
    if (not list) or (#list < 1) then
        print('No matching application process were found!')
        return
    end

    local services = {}
    for name, value in pairs(names) do
        services[name] = { name = name }
    end

    for _, proc in ipairs(list) do
        local service = services[proc.name]
        if (not service) then
            service = { name = proc.name }
            services[proc.name] = service
        end

        if (not service.pids) then
            service.pids = {}
        end

        service.pids[#service.pids + 1] = tostring(proc.pid)
    end

    list = {}
    for name, service in pairs(services) do
        list[#list + 1] = service
    end 

    table.sort(list, function(a, b) 
        return tostring(a.name) < tostring(b.name) 
    end) 

    local grid = app.table({ 10, 16, 24 })
    grid.line()
    grid.cell("status", "name", "pids")
    grid.line()
    for _, proc in ipairs(list) do
        local status = '[   ]'
        if (proc.pids) then status = '[ + ]' end
        local pids = proc.pids or {}
        grid.cell(status, proc.name, table.concat(pids, ","))
    end
    grid.line()
end

-- 重启指定的名称的应用程序
function exports.restart(name)
    if (not name) then
        print('APP name expected!')
        exports.help()

    elseif (name == 'all') then
        print('Restarting all applications...')
        os.execute('killall lnode; lpm start lhost')

    else
        print('Restarting...')
        exports.kill(name)
        os.execute('lpm start ' .. name)

        print("\27[1ARestarting...     [done]")
    end
end

-- 启动应用进程守护程序
function exports.start(interval, ...)
    print("Start lhost...")

    local tmpdir = os.tmpdir or '/tmp'

    -- 检查是否有另一个进程正在更新系统
    local lockname = path.join(tmpdir, '/lhost.lock')
    local lockfd = fs.openSync(lockname, 'w+')
    local ret = fs.fileLock(lockfd, 'w')
    if (ret == -1) then
        print('The lhost is lock!')
        return
    end

    local list = app.get('start')
    if (list) then
        list = list:split(',')
        console.log('start', list)
        lhost.enable(list, true)
    end

    interval = interval or 3
    setInterval(interval * 1000, function()
        exports.check()
    end)

    process:on("exit", function()
        fs.fileLock(lockfd, 'u')
    end)
end

-- 杀掉指定名称的进程，并阻止其在后台继续运行
function exports.stop(...)
    local list = table.pack(...)
    if (not list) or (#list <= 0) then
        exports.kill('lhost')
        return
    end

    lhost.enable(list, false)

    for _, name in ipairs(list) do
        exports.kill(name)   
    end
end

app(exports)
