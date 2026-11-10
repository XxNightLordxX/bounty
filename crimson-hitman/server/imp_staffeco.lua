--- The staff and economy improvements' shared helpers (Config.Improvements,
--- README, Optional features): each feature's block read at use, and
--- the start-up check of each block, the way server/rp_places.lua checks
--- the roleplay blocks. Used by server/imp_proof.lua, imp_scrub.lua and
--- imp_weekly.lua, and for Config.Limits.TargetCooldownAfterCompletionSeconds.

local Util = CrimsonBoot.requireShared('util')

local Imp = {}

--- One feature's block of Config.Improvements, or an empty table.
---@param name string 'ProofItems' | 'SerialScrub' | 'WeeklyStats'
---@return table
function Imp.block(name)
    local root = type(Config) == 'table' and Config.Improvements
    local block = type(root) == 'table' and root[name]
    return type(block) == 'table' and block or {}
end

--- Whether a feature is on.
---@param name string
---@return boolean
function Imp.on(name)
    return Imp.block(name).Enabled == true
end

--- The days of the week, as os.date's wday counts them (1 = Sunday).
Imp.DAYS = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' }

--- A deep copy (Util.copy, the one shared copy).
local copyOf = Util.copy

local function describe(value)
    if type(value) == 'string' then return ("'%s'"):format(value) end
    return tostring(value)
end

--- Whether one value is what its rule takes. kinds: switch, number (min,
--- max, integer), text (a name of letters, digits, - and _), choice.
local function fits(rule, value)
    if rule.kind == 'switch' then return type(value) == 'boolean' end
    if rule.kind == 'number' then
        if type(value) ~= 'number' or value ~= value then return false end
        if rule.integer and math.floor(value) ~= value then return false end
        return value >= rule.min and value <= rule.max
    end
    if rule.kind == 'text' then
        return type(value) == 'string' and #value > 0 and #value <= 64 and value:match('^[%w_%-]+$') ~= nil
    end
    if rule.kind == 'choice' then
        for _, choice in ipairs(rule.choices) do if value == choice then return true end end
        return false
    end
    return false
end

local function says(rule)
    if rule.kind == 'switch' then return 'true or false' end
    if rule.kind == 'number' then
        return ('a %s from %s to %s'):format(rule.integer and 'whole number' or 'number',
            tostring(rule.min), tostring(rule.max))
    end
    if rule.kind == 'text' then return 'a name of letters, digits, - and _' end
    return 'one of ' .. table.concat(rule.choices, ', ')
end

--- Fill a feature's block where config.lua has none (one written before it
--- existed), then hold every field to its rule: one that does not fit is
--- put back to what ships, with a warning naming it. The admin panel's
--- check of a change runs this against a copy (main.lua's checkConfig), so
--- a value this would put back is refused there, in these words.
---@param name string the block's name under Config.Improvements
---@param rules table [field] = rule
---@param warn string[] where a problem is added
function Imp.checkBlock(name, rules, warn)
    if type(Config.Improvements) ~= 'table' then Config.Improvements = {} end
    local shippedRoot = type(ConfigDefaults) == 'table' and ConfigDefaults.Improvements or nil
    local shipped = type(shippedRoot) == 'table' and type(shippedRoot[name]) == 'table'
        and shippedRoot[name] or {}
    if type(Config.Improvements[name]) ~= 'table' then Config.Improvements[name] = copyOf(shipped) end
    local block = Config.Improvements[name]
    local fields = {}
    for field in pairs(rules) do fields[#fields + 1] = field end
    table.sort(fields)
    for _, field in ipairs(fields) do
        local rule = rules[field]
        if not fits(rule, block[field]) then
            local fallback = shipped[field]
            if fallback == nil then fallback = rule.default end
            if block[field] ~= nil then
                warn[#warn + 1] = ('Improvements.%s.%s is %s; it has to be %s. Using %s.'):format(
                    name, field, describe(block[field]), says(rule), describe(fallback))
            end
            block[field] = copyOf(fallback)
        end
    end
end

--- The completion cooldown (Config.Limits.TargetCooldownAfterCompletionSeconds):
--- 0 where a config.lua from before it has none, a whole number of seconds
--- up to thirty days otherwise.
Imp.COMPLETION_COOLDOWN_MAX = 2592000

---@param warn string[]
function Imp.checkCompletionCooldown(warn)
    if type(Config.Limits) ~= 'table' then return end
    local value = Config.Limits.TargetCooldownAfterCompletionSeconds
    if value == nil then
        Config.Limits.TargetCooldownAfterCompletionSeconds = 0
        return
    end
    if type(value) ~= 'number' or value ~= value or math.floor(value) ~= value
        or value < 0 or value > Imp.COMPLETION_COOLDOWN_MAX then
        warn[#warn + 1] = ('Limits.TargetCooldownAfterCompletionSeconds is %s; it has to be a whole '
            .. 'number from 0 to %d. Using 0 (off).'):format(describe(value), Imp.COMPLETION_COOLDOWN_MAX)
        Config.Limits.TargetCooldownAfterCompletionSeconds = 0
    end
end

--- How long after a completed contract nobody may place on its target, in
--- seconds: 0 while it is off.
---@return integer
function Imp.completionCooldown()
    local value = type(Config.Limits) == 'table' and tonumber(Config.Limits.TargetCooldownAfterCompletionSeconds)
    if not value or value <= 0 then return 0 end
    return math.floor(value)
end


return Imp
