local class        = require "middleclass"
local plugin       = require "bunkerweb.plugin"
local utils        = require "bunkerweb.utils"
local datastore    = require "bunkerweb.datastore"
local clusterstore = require "bunkerweb.clusterstore"
local cjson        = require "cjson"

local limit        = class("limit", plugin)

function limit:initialize()
	-- Call parent initialize
	plugin.initialize(self, "limit")
	-- Load rules if needed
	if ngx.get_phase() ~= "init" and self:is_needed() then
		-- Get all rules from datastore
		local limited = false
		local all_rules, err = self.datastore:get("plugin_limit_rules", true)
		if not all_rules then
			self.logger:log(ngx.ERR, err)
			return
		end
		self.rules = {}
		-- Extract global rules
		if all_rules.global then
			for k, v in pairs(all_rules.global) do
				self.rules[k] = v
			end
		end
		-- Extract and overwrite if needed server rules
		if all_rules[self.ctx.bw.server_name] then
			for k, v in pairs(all_rules[self.ctx.bw.server_name]) do
				self.rules[k] = v
			end
		end
	end
end

function limit:is_needed()
	-- Loading case
	if self.is_loading then
		return false
	end
	-- Request phases (no default)
	if self.is_request and (self.ctx.bw.server_name ~= "_") then
		return self.variables["USE_LIMIT_REQ"] == "yes"
	end
	-- Other cases : at least one service uses it
	local is_needed, err = utils.has_variable("USE_LIMIT_REQ", "yes")
	if is_needed == nil then
		self.logger:log(ngx.ERR, "can't check USE_LIMIT_REQ variable : " .. err)
	end
	return is_needed
end

function limit:init()
	-- Check if init is needed
	if not self:is_needed() then
		return self:ret(true, "no service uses limit for requests, skipping init")
	end
	-- Get variables
	local variables, err = utils.get_multiple_variables({ "LIMIT_REQ_URL", "LIMIT_REQ_RATE" })
	if variables == nil then
		return self:ret(false, err)
	end
	-- Store URLs and rates
	local data = {}
	local i = 0
	for srv, vars in pairs(variables) do
		for var, value in pairs(vars) do
			if utils.regex_match(var, "LIMIT_REQ_URL") then
				local url = value
				local rate = vars[var:gsub("URL", "RATE")]
				if data[srv] == nil then
					data[srv] = {}
				end
				data[srv][url] = rate
				i = i + 1
			end
		end
	end
	local ok, err = self.datastore:set("plugin_limit_rules", data, nil, true)
	if not ok then
		return self:ret(false, err)
	end
	return self:ret(true, "successfully loaded " .. tostring(i) .. " limit rules for requests")
end

function limit:access()
	-- Check if we are whitelisted
	if self.ctx.bw.is_whitelisted == "yes" then
		return self:ret(true, "client is whitelisted")
	end
	-- Check if access is needed
	if not self:is_needed() then
		return self:ret(true, "limit request not enabled")
	end
	-- Check if URI is limited
	local rate = nil
	local uri = nil
	for k, v in pairs(self.rules) do
		if k ~= "/" and utils.regex_match(self.ctx.bw.uri, k) then
			rate = v
			uri = k
			break
		end
	end
	if not rate then
		if self.rules["/"] then
			rate = self.rules["/"]
			uri = "/"
		else
			return self:ret(true, "no rule for " .. self.ctx.bw.uri)
		end
	end
	-- Check if limit is reached
	local _, _, rate_max, rate_time = rate:find("(%d+)r/(.)")
	local limited, err, current_rate = self:limit_req(tonumber(rate_max), rate_time)
	if limited == nil then
		return self:ret(false, err)
	end
	-- Limit reached
	if limited then
		return self:ret(true,
			"client IP " ..
			self.ctx.bw.remote_addr ..
			" is limited for URL " ..
			self.ctx.bw.uri .. " (current rate = " .. current_rate .. "r/" .. rate_time .. " and max rate = " .. rate .. ")",
			ngx.HTTP_TOO_MANY_REQUESTS)
	end
	-- Limit not reached
	return self:ret(true,
		"client IP " ..
		self.ctx.bw.remote_addr ..
		" is not limited for URL " ..
		self.ctx.bw.uri .. " (current rate = " .. current_rate .. "r/" .. rate_time .. " and max rate = " .. rate .. ")")
end

function limit:limit_req(rate_max, rate_time)
	local timestamps = nil
	-- Redis case
	if self.use_redis then
		local redis_timestamps, err = self:limit_req_redis(rate_max, rate_time)
		if redis_timestamps == nil then
			self.logger:log(ngx.ERR, "limit_req_redis failed, falling back to local : " .. err)
		else
			timestamps = redis_timestamps
			-- Save the new timestamps
			local ok, err = self.datastore:set(
				"plugin_limit_" .. self.ctx.bw.server_name .. self.ctx.bw.remote_addr .. self.ctx.bw.uri,
				cjson.encode(timestamps), delay)
			if not ok then
				return nil, "can't update timestamps : " .. err
			end
		end
	end
	-- Local case (or fallback)
	if timestamps == nil then
		local local_timestamps, err = self:limit_req_local(rate_max, rate_time)
		if local_timestamps == nil then
			return nil, "limit_req_local failed : " .. err
		end
		timestamps = local_timestamps
	end
	if #timestamps > rate_max then
		return true, "success - limited", #timestamps
	end
	return false, "success - not limited", #timestamps
end

function limit:limit_req_local(rate_max, rate_time)
	-- Get timestamps
	local timestamps, err = self.datastore:get("plugin_limit_" ..
		self.ctx.bw.server_name .. self.ctx.bw.remote_addr .. self.ctx.bw.uri)
	if not timestamps and err ~= "not found" then
		return nil, err
	elseif err == "not found" then
		timestamps = "{}"
	end
	timestamps = cjson.decode(timestamps)
	-- Compute new timestamps
	local updated, new_timestamps, delay = self:limit_req_timestamps(rate_max, rate_time, timestamps)
	-- Save new timestamps if needed
	if updated then
		local ok, err = self.datastore:set(
			"plugin_limit_" .. self.ctx.bw.server_name .. self.ctx.bw.remote_addr .. self.ctx.bw.uri,
			cjson.encode(new_timestamps), delay)
		if not ok then
			return nil, err
		end
	end
	return new_timestamps, "success"
end

function limit:limit_req_redis(rate_max, rate_time)
	-- Redis atomic script
	local redis_script = [[
		local ret_get = redis.pcall("GET", KEYS[1])
		if type(ret_get) == "table" and ret_get["err"] ~= nil then
			redis.log(redis.LOG_WARNING, "limit GET error : " .. ret_get["err"])
			return ret_get
		end
		local timestamps = {}
		if ret_get then
			timestamps = cjson.decode(ret_get)
		end
		-- Keep only timestamps within the delay
		local updated = false
		local new_timestamps = {}
		local rate_max = tonumber(ARGV[1])
		local rate_time = ARGV[2]
		local current_timestamp = tonumber(ARGV[3])
		local delay = 0
		if rate_time == "s" then
			delay = 1
		elseif rate_time == "m" then
			delay = 60
		elseif rate_time == "h" then
			delay = 3600
		elseif rate_time == "d" then
			delay = 86400
		end
		for i, timestamp in ipairs(timestamps) do
			if current_timestamp - timestamp <= delay then
				table.insert(new_timestamps, timestamp)
			else
				updated = true
			end
		end
		-- Only insert the new timestamp if client is not limited already to avoid infinite insert
		if #new_timestamps <= rate_max then
			table.insert(new_timestamps, current_timestamp)
			updated = true
		end
		-- Save new timestamps if needed
		if updated then
			local ret_set = redis.pcall("SET", KEYS[1], cjson.encode(new_timestamps), "EX", delay)
			if type(ret_set) == "table" and ret_set["err"] ~= nil then
				redis.log(redis.LOG_WARNING, "limit SET error : " .. ret_set["err"])
				return ret_set
			end
		end
		return new_timestamps
	]]
	-- Connect
	local ok, err = self.clusterstore:connect()
	if not ok then
		return nil, err
	end
	-- Execute script
	local timestamps, err = self.clusterstore:call("eval", redis_script, 1,
		"plugin_limit_" .. self.ctx.bw.server_name .. self.ctx.bw.remote_addr .. self.ctx.bw.uri, rate_max, rate_time,
		os.time(os.date("!*t")))
	if not timestamps then
		self.clusterstore:close()
		return nil, err
	end
	-- Return timestamps
	self.clusterstore:close()
	return timestamps, "success"
end

function limit:limit_req_timestamps(rate_max, rate_time, timestamps)
	-- Compute new timestamps
	local updated = false
	local new_timestamps = {}
	local current_timestamp = os.time(os.date("!*t"))
	local delay = 0
	if rate_time == "s" then
		delay = 1
	elseif rate_time == "m" then
		delay = 60
	elseif rate_time == "h" then
		delay = 3600
	elseif rate_time == "d" then
		delay = 86400
	end
	-- Keep only timestamp within the delay
	for i, timestamp in ipairs(timestamps) do
		if current_timestamp - timestamp <= delay then
			table.insert(new_timestamps, timestamp)
		else
			updated = true
		end
	end
	-- Only insert the new timestamp if client is not limited already to avoid infinite insert
	if #new_timestamps <= rate_max then
		table.insert(new_timestamps, current_timestamp)
		updated = true
	end
	return updated, new_timestamps, delay
end

return limit
