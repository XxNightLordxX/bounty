--- Per-citizen token buckets (§9.5, §14.27).
--- Keyed on the resolved citizen id, never on anything from a payload, so
--- rotating a field in the request cannot buy extra attempts.

local RateLimit = {}

local buckets = {}

local function now() return GetGameTimer() end

--- @param cid string resolved citizen id
--- @param action string key into Config.Cooldowns
--- @return boolean allowed
function RateLimit.check(cid, action)
    local rule = Config.Cooldowns[action]
    if not rule then return true end

    local key = cid .. ':' .. action
    local bucket = buckets[key]
    local ms = now()

    if not bucket then
        buckets[key] = { tokens = rule.burst - 1, last = ms }
        return true
    end

    -- Refill at burst/per per second, capped at burst.
    local elapsed = (ms - bucket.last) / 1000
    local refill = elapsed * (rule.burst / rule.per)
    bucket.tokens = math.min(rule.burst, bucket.tokens + refill)
    bucket.last = ms

    if bucket.tokens < 1 then return false end
    bucket.tokens = bucket.tokens - 1
    return true
end

--- Drop a player's buckets on disconnect so the table cannot grow without
--- bound across a long uptime.
function RateLimit.clear(cid)
    for key in pairs(buckets) do
        if key:sub(1, #cid + 1) == cid .. ':' then buckets[key] = nil end
    end
end

function RateLimit.count()
    local n = 0
    for _ in pairs(buckets) do n = n + 1 end
    return n
end

return RateLimit
