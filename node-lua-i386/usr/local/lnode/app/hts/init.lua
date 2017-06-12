local app 		= require('app')
local http 		= require('http')
local json 		= require('json')
local net  		= require('net')
local tunnel	= require('tunnel')
local url 		= require('url')

local HT_SERVER_PORT 	= 8083
local HT_SERVER_HOST 	= '127.0.0.1'

--/////////////////////////////////////////////////////////////

local exports = {}

function exports.start(port, ...)
	local options = { port = port or HT_SERVER_PORT}
	exports.server = tunnel.createServer(options)
end

app(exports)
