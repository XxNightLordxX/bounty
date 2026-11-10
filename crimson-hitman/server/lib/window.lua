--- Counts inside a sliding window (the last hour, the last day): the one
--- per-day counter every cap and alert uses.
---
--- Each count is read and written in one go, with no yield in between, so
--- two requests landing together can never both read "one left" and both
--- take it: `take` checks and counts as one step. Times are os.time()
--- seconds. A key holds only the times still inside the window (and, with
--- `add`'s `keep`, no more than that many of them), so the memory is bounded
--- by who did something lately, and `sweep` forgets the rest.

local Window = {}

---@class CrimsonWindow
---@field seconds integer
---@field add fun(key: any, now: integer|nil, keep: integer|nil): integer
---@field take fun(key: any, limit: integer, now: integer|nil): boolean, integer
---@field count fun(key: any, now: integer|nil): integer
---@field get fun(key: any): table|nil
---@field sweep fun(now: integer|nil, keepIf: function|nil): integer
---@field clear fun(key: any)
---@field reset fun()

--- A new window of `seconds`.
---@param seconds integer
---@return CrimsonWindow
function Window.new(seconds)
    local span = math.max(1, math.floor(tonumber(seconds) or 0))
    local book = {}   -- [key] = { times = integer[] (oldest first), ... }
    local w = { seconds = span }

    --- The key's times still inside the window, the rest dropped.
    local function trimmed(key, now)
        local entry = book[key]
        if not entry then return nil end
        local kept = {}
        for i = 1, #entry.times do
            if now - entry.times[i] < span then kept[#kept + 1] = entry.times[i] end
        end
        entry.times = kept
        return entry
    end

    --- Count one now, and say how many are inside the window with it.
    ---@param key any
    ---@param now integer|nil default os.time()
    ---@param keep integer|nil keep at most this many of the newest
    ---@return integer
    function w.add(key, now, keep)
        now = now or os.time()
        local entry = trimmed(key, now)
        if not entry then
            entry = { times = {} }
            book[key] = entry
        end
        entry.times[#entry.times + 1] = now
        if keep then
            while #entry.times > keep do table.remove(entry.times, 1) end
        end
        return #entry.times
    end

    --- Count one now if fewer than `limit` are inside the window: the check
    --- and the count as one step.
    ---@param key any
    ---@param limit integer
    ---@param now integer|nil default os.time()
    ---@return boolean taken
    ---@return integer count inside the window after it
    function w.take(key, limit, now)
        now = now or os.time()
        local n = w.count(key, now)
        if n >= limit then return false, n end
        return true, w.add(key, now)
    end

    --- How many are inside the window now.
    ---@param key any
    ---@param now integer|nil default os.time()
    ---@return integer
    function w.count(key, now)
        local entry = trimmed(key, now or os.time())
        return entry and #entry.times or 0
    end

    --- The key's entry, for what a caller keeps beside the times (when it
    --- last alerted). nil before its first count.
    ---@param key any
    ---@return table|nil
    function w.get(key)
        return book[key]
    end

    --- Forget every key with nothing inside the window, unless keepIf(entry,
    --- now) says to keep it.
    ---@param now integer|nil default os.time()
    ---@param keepIf function|nil
    ---@return integer dropped
    function w.sweep(now, keepIf)
        now = now or os.time()
        local dropped = 0
        for key, entry in pairs(book) do
            local newest = entry.times[#entry.times]
            if (not newest or now - newest >= span) and not (keepIf and keepIf(entry, now)) then
                book[key] = nil
                dropped = dropped + 1
            end
        end
        return dropped
    end

    --- Forget one key.
    function w.clear(key)
        book[key] = nil
    end

    --- Forget every key.
    function w.reset()
        book = {}
    end

    return w
end

return Window
