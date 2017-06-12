local app       = require('app')
local utils     = require('utils')
local request   = require('http/request')
local fs        = require('fs')
local device    = require('device')
-- local URL       = 'http://nms.sae-sz.cn:3000'
local URL       = 'http://192.168.31.120:3000'
-------------------------------------------------------------------------------
-- exports

local cpu_info = {}

function getEth0Mac()
    local mac
    local network_info = os.networkInterfaces()
    if network_info == nil then return end
    for k, v in ipairs(network_info.eth0) do
        if v.family == 'inet' then 
            mac = string.upper(utils.bin2hex(v.mac))
        end
    end
    return mac
end

function getInfo()
    -- body
    --memony
    local data = fs.readFileSync('/proc/meminfo')
    local list = string.split(data, 'kB\n')
    local MemTotal ,MemFree
    for w in string.gmatch(list[1],"%d+") do
        MemTotal = w
    end
    for w in string.gmatch(list[2],"%d+") do
        MemFree = w
    end

    MemTotal = MemTotal - 0
    local MemUsed = (MemTotal-MemFree)
    MemTotal = math.floor(MemTotal)
    MemUsed = math.floor(MemUsed)

    -- console.log(os.freemem())
    -- console.log(os.totalmem())

    --cpu
    data = fs.readFileSync('/proc/stat')
    list = string.split(data, '\n')
    local d = string.gmatch(list[1],"%d+")

    local TotalCPUtime = 0;
    local x = {}
    local i = 1
    for w in d do
        TotalCPUtime = TotalCPUtime + w
        x[i] = w
        i = i +1
    end
    local TotalCPUusagetime = 0;
    TotalCPUusagetime = x[1]+x[2]+x[3]+x[6]+x[7]+x[8]+x[9]+x[10]
    local cpuUserPercent = TotalCPUusagetime/TotalCPUtime*100

    local delta_cpu_used_time = TotalCPUusagetime - cpu_info.used_time
    local delta_cpu_total_time = TotalCPUtime - cpu_info.total_time

    cpu_info.used_time = math.floor(TotalCPUusagetime) --record
    cpu_info.total_time = math.floor(TotalCPUtime) --record

    cpuUserPercent = math.floor(delta_cpu_used_time / delta_cpu_total_time * 100)
    -- console.log(cpuUserPercent)

    --MAC
    -- local Mac = string.upper(device.getMacAddress())
    local Mac = getEth0Mac()

    --uname
    -- local uname = 
    local str = io.popen('uname -a', "r")
    str = str:read("*a")
    local uname_info_list = {}
    local i = 1;
    for w in string.gmatch(str,"%a+") do
        uname_info_list[i] = w
        i = i + 1
    end
    local system = uname_info_list[1];
    local system_type = uname_info_list[2];
    local system_version = uname_info_list[3];
    
    --net type
    -- local str = io.popen("cat /proc/net/dev | awk '{if($2>0 && NR > 2) print substr($1, 0, index($1, \":\") - 1)}'", "r")
    -- str = str:read("*a")
    -- console.log(str)
    --Network Traffic

   
    return MemTotal,MemFree,MemUsed,cpuUserPercent,TotalCPUtime,TotalCPUusagetime,math.floor(os.uptime()),Mac,system_type
end

function monitor()
    -- body
    local mt,mf,mu,cu,tc,tcu,uptime,mac,target = getInfo()
    local version = '0.0.1'
    local net_type = 101
	local net_tx = 50
	local net_rx = 53
    local options = { form = { mac = mac, target = target, version = version, mem_total = mt, mem_used = mu, cpu_usage = cu, uptime = uptime, net_type = net_type, net_tx = net_tx, net_rx = net_rx}}
    request.post(URL .. '/monitor/push', options, function(err, response, body)
        console.log(response.statusCode, body)
    end)
end

local exports = {}

function exports.conf()

end

function exports.daemon()
    app.daemon()
end

function exports.help()
    app.usage(utils.dirname())
end



function exports.start()
    print('start')
    local options = { form = { status = 'on' }}
    print('post')
    cpu_info.used_time = 0;
    cpu_info.total_time = 0;
    setInterval(5000,monitor)
end

function exports.stop()
    os.execute('lpm kill mqtt')
end




app(exports)
