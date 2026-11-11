CrimsonBoot.define('server.lib.lock', function() --- One at a time per key: the one serialiser every module uses.
---
--- Every store call yields on mysql, and each request runs in its own
--- coroutine, so two requests about one thing run side by side unless
--- something stops them. Checking before writing cannot close that; only one
--- at a time can. The second is refused as busy rather than queued, and a
--- crash takes every key with it, so nothing is ever held across a restart.
---
--- Each module makes its own lock (Lock.new), so its keys are its own: a
--- freeze on a player and a sanction on the same player never wait on each
--- other. What a busy answer carries, and what a raise does, are the lock's
--- options:
---
---   busy(heldMs)  extra values after false, CH.ERR.BUSY (Contracts' { heldMs },
---                 the settings' sentence); none when it is not given
---   raised(err)   what a raise returns instead of raising again (the target
---                 limits log it and answer 'store_failed'); not given, the
---                 raise goes on to the caller, every key let go first

local Util = CrimsonBoot.requireShared('util')

local Lock = {}

---@class CrimsonLock
---@field run fun(keys: string|string[], fn: function, ...): any
---@field held fun(key: string): boolean
---@field reset fun()

--- A new lock with keys of its own.
---@param opts table|nil { busy = function(heldMs): ..., raised = function(err): ... }
---@return CrimsonLock
function Lock.new(opts)
    opts = opts or {}
    local busy, raised = opts.busy, opts.raised
    local holding = {}   -- [key] = Util.monotonicMs() when it was taken
    local lock = {}

    --- Run fn(...) holding every key, or refuse while any of them is held.
    ---@param keys string|string[]
    ---@param fn function
    ---@return any ... fn's own answers, or false, CH.ERR.BUSY[, busy(heldMs)]
    function lock.run(keys, fn, ...)
        if type(keys) ~= 'table' then keys = { keys } end
        local oldest
        for i = 1, #keys do
            local since = holding[keys[i]]
            if since and (not oldest or since < oldest) then oldest = since end
        end
        if oldest then
            if busy then return false, CH.ERR.BUSY, busy(math.max(0, Util.monotonicMs() - oldest)) end
            return false, CH.ERR.BUSY
        end
        local now = Util.monotonicMs()
        for i = 1, #keys do holding[keys[i]] = now end
        local out = table.pack(pcall(fn, ...))
        for i = 1, #keys do holding[keys[i]] = nil end
        if not out[1] then
            if raised then return raised(out[2]) end
            error(out[2], 0)
        end
        return table.unpack(out, 2, out.n)
    end

    --- Whether a key is held now.
    ---@param key string
    ---@return boolean
    function lock.held(key)
        return holding[key] ~= nil
    end

    --- Let go of every key (a module's init, for a fresh start).
    function lock.reset()
        holding = {}
    end

    return lock
end

return Lock
end)
