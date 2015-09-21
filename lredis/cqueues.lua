local protocol = require "lredis.protocol"
local commands = require "lredis.commands"
local cs = require "cqueues.socket"
local cc = require "cqueues.condition"
local new_fifo = require "fifo"

local pack = table.pack or function(...) return {n = select("#", ...), ...} end

local methods = setmetatable({}, {__index = commands})
local mt = {
	__index = methods;
}

local function new(host, port)
	local socket = assert(cs.connect({
		host = host or "127.0.0.1";
		port = port or "6379";
		nodelay = true;
	}))
	socket:setmode("b", "b")
	socket:setvbuf("full", math.huge) -- 'infinite' buffering; no write locks needed
	assert(socket:connect())
	return setmetatable({
		socket = socket;
		fifo = new_fifo();
		subscribes_pending = 0;
		subscribed_to = 0;
	}, mt)
end

-- call with table arg/return
function methods:callt(arg, new_status, new_error, string_null, array_null)
	if self.subscribes_pending > 0 or self.subscribed_to > 0 then
		error("cannot 'call' while in subscribe mode")
	end
	local cond = cc.new()
	local req = protocol.encode_request(arg)
	assert(self.socket:write(req))
	assert(self.socket:flush())
	self.fifo:push(cond)
	if self.fifo:peek() ~= cond then
		cond:wait()
	end
	local resp = protocol.read_response(self.socket, new_status, new_error, string_null, array_null)
	assert(self.fifo:pop() == cond)
	-- signal next thing in pipeline
	local next, ok = self.fifo:peek()
	if ok then
		next:signal()
	end
	return resp
end

-- call in vararg style
function methods:call(...)
	return self:callt(pack(...), protocol.status_reply, protocol.error_reply, protocol.string_null, protocol.array_null)
end

-- need locking around sending subscribe, as you won't know
function methods:start_subscription_modet(arg)
	local req = protocol.encode_request(arg)
	assert(self.socket:write(req))
	assert(self.socket:flush())
	self.subscribes_pending = self.subscribes_pending + 1
end

function methods:start_subscription_mode(...)
	return self:start_subscription_modet(pack(...))
end

function methods:get_next(new_status, new_error, string_null, array_null)
	if self.subscribed_to == 0 and self.subscribes_pending == 0 then
		return nil, "not in subscribe mode"
	end
	local resp = protocol.read_response(self.socket, new_status, new_error, string_null, array_null)
	local kind = resp[1]
	if kind == "subscribe" or kind == "unsubscribe" or kind == "psubscribe" or kind == "punsubscribe" then
		self.subscribed_to = resp[3]
		self.subscribes_pending = self.subscribes_pending - 1
	end
	return resp
end

return {
	new = new;
}