local app 		= require('app')
local http 		= require('http')
local json 		= require('json')
local net  		= require('net')
local tunnel	= require('tunnel')
local url 		= require('url')


local HT_CLIENT_UUID 	= '7031:3a69:3dba:4111:ad75:a8a4:ae7b:5c0f'
local HT_SERVER_PORT 	= 8083
local HT_SERVER_HOST 	= '127.0.0.1'

--HT_SERVER_HOST = '10.10.38.60'
HT_SERVER_HOST = '112.74.210.14'

--/////////////////////////////////////////////////////////////

local exports = {}

function exports.start(host, port, uuid)
	local options = {}
	options.uuid = uuid or app.get('uuid') or HT_CLIENT_UUID
	options.port = port or app.get('server.port') or HT_SERVER_PORT
	options.host = host or app.get('server.host') or HT_SERVER_HOST

	local hosts = { 
		live = '127.0.0.1:8001'
	}
	exports.client = tunnel.connect(options, hosts)
end

app(exports)
