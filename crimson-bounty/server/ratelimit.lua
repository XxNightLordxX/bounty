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

--- Buckets are NOT cleared on disconnect: reconnecting would then reset
--- every limit, which turns a rejoin into a way to bypass them. They are
--- swept once they have been idle long enough to have refilled anyway.
function RateLimit.clear(cid)
    return false
end

--- Drop buckets nobody has touched for a while. A refilled bucket holds no
--- information, so removing it changes nothing except memory.
function RateLimit.sweep()
    local ms = now()
    local removed = 0
    for key, bucket in pairs(buckets) do
        if ms - bucket.last > 600000 then
            buckets[key] = nil
            removed = removed + 1
        end
    end
    return removed
end

function RateLimit.count()
    local n = 0
    for _ in pairs(buckets) do n = n + 1 end
    return n
end

return RateLimit
