local _M = {}

-- alternatively: local lrucache = require "resty.lrucache.pureffi"
local lrucache = require "resty.lrucache"
local resty_lock = require "resty.lock"
local redis = require "resty.redis"
--
-- -- we need to initialize the cache on the lua module level so that
-- -- it can be shared by all the requests served by each nginx worker process:
local c = lrucache.new(200)  -- allow up to 200 items in the cache
if not c then
    return error("failed to create the cache: " .. (err or "unknown"))
end
--
function _M.getId(name)
    local service_ids, stale_v = c:get(name)

    if (service_ids and (table.getn(service_ids)~=0)) then
        local id = table.remove(service_ids, 1)
        c:set(name, service_ids)
        return id, false
    end

    local lock = resty_lock:new("my_locks")
    local elapsed, err = lock:lock(name)
    if not elapsed then
        return 0, "failed to accquire the lock"
    end
    service_ids, stale_v = c:get(name)
    if (service_ids and (table.getn(service_ids)~=0)) then
        local ok, err = lock:unlock()
        if not ok then
            return 0, "failed to unlock"
        end
        local id = table.remove(service_ids, 1)
        c:set(name, service_ids)
        return id, false
    end

    local cacheKeys, err = _M.fetch_redis(name)
    if err then
        local ok, err1 = lock:unlock()
        if not ok then
            ngx.say("Internal Error: " .. (err1 or "unknown"))
            return
        end
        ngx.say("Internal Error: " .. (err or "unknown"))
        return
    end

    local id = table.remove(cacheKeys, 1)
    c:set(name, cacheKeys)
    local ok, err = lock:unlock()
    if not ok then
        ngx.say("Internal Error: " .. (err or "unknown"))
        return
    end
    return id, false
end
--a
function _M.fetch_redis(name)
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect("127.0.0.1", 6379)
    if not ok then
        return 0, "failed to connnet redis"
    end

    local id, err = red:incrby(name, 100)
    if err then
        return 0, "failed to get service key"
    end
    local ok, err = red:set_keepalive(50000, 5)
    if not ok then
        return 0, "failed to set keepalive"
    end
    local Ids = {}
    for i = id-99, id, 1 do
        Ids[#Ids+1] = i
    end
    return Ids, false
end


return _M
