--- Per-citizen token buckets (§9.5, §14.27).
--- Keyed on the resolved citizen id, never on anything from a payload, so
--- rotating a field in the request cannot buy extra attempts.

local Util = require_shared('util')

local RateLimit = {}

local buckets = {}

local function now() return Util.monotonicMs() end

--- The identity a bucket belongs to.
---
--- The account where one is known, the citizen id otherwise. A character
--- selector makes switching instant and free, so a cooldown keyed on the
--- citizen id alone is one switch away from being reset — and the spec asks
--- for account-level keying on exactly these counters (§14.27).
---
--- Accepts a resolved actor or a bare citizen id: the callers that hold an
--- actor get the stronger key, and the ones that only have an id still get
--- a working limit rather than none.
---@param who table|string
---@return string|nil
local function keyFor(who)
    if type(who) == 'table' then
        if Config.RateLimit.Key == 'license' and who.account then return who.account end
        return who.cid
    end
    if type(who) == 'string' then return who end
    return nil
end

--- What an action with no rule of its own gets.
---
--- An unknown action used to mean no limit at all, which is the wrong way
--- round: a bucket that was renamed, or one an operator's older config does
--- not have, silently became unlimited. Erring towards a limit costs a
--- caller a refusal; erring the other way costs the server.
RateLimit.FALLBACK = { per = 10, burst = 10 }

--- @param who table|string resolved actor, or a citizen id
--- @param action string key into Config.Cooldowns
--- @return boolean allowed
function RateLimit.check(who, action)
    local rule = Config.Cooldowns[action] or RateLimit.FALLBACK

    local cid = keyFor(who)
    -- No identity at all is not a licence to act; it is the one case where
    -- refusing is safer than allowing.
    if not cid then return false end

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
