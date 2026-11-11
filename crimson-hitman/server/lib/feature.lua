--- One way to read and check an optional feature's block of config
--- (Config.Intel.Rumours, Config.Improvements.ProofItems,
--- Config.Organisation, ...): whether it is on, the block itself, and the
--- start-up check that holds every field to its rule.
---
--- Every read goes to the live Config at the moment of the call, so a
--- switch changed from the admin panel applies at once. A path is the key
--- path under Config, dot separated ('Intel.Rumours'); a path to a plain
--- switch ('Kidnap.MeetingPoint') is on when that switch is true.
---
--- The check (Feature.check) is the one validator every feature block uses:
--- a block config.lua does not have (one written before the feature) is
--- copied from what ships (config/defaults.lua), a field missing is filled
--- from what ships, and a field that breaks its rule is put back to what
--- ships, with a warning naming it. The admin panel runs the same checks
--- against a copy with a change in it (main.lua's checkConfig), so a value
--- this would put back is refused there, in these words. Each rule checked
--- is kept in Feature.RULES by its key, for the settings catalogue's own
--- check (tests/feature_spec.lua holds the two to agree).

local Util = CrimsonBoot.requireShared('util')
local L = CrimsonBoot.requireShared('locale').t

local Feature = {}

--- Every rule checked so far: ['Intel.Rumours.Radius'] = rule.
Feature.RULES = {}

--- Each path split once: these are read on every request, and a split per
--- read would be garbage per request. [path] = { part, ... }
local Parts = {}

local function partsOf(path)
    local parts = Parts[path]
    if parts then return parts end
    parts = {}
    for part in tostring(path):gmatch('[^%.]+') do parts[#parts + 1] = part end
    Parts[path] = parts
    return parts
end

local function walk(root, path)
    local node = root
    local parts = partsOf(path)
    for i = 1, #parts do
        if type(node) ~= 'table' then return nil end
        node = node[parts[i]]
    end
    return node
end

--- The block at a path of Config, or an empty table when there is none.
---@param path string e.g. 'Intel.Rumours'
---@return table
function Feature.block(path)
    local node = walk(Config, path)
    return type(node) == 'table' and node or {}
end

--- Whether a feature is on: its block's Enabled is true, or, for a path to
--- a switch, the switch is true.
---@param path string
---@return boolean
function Feature.on(path)
    local node = walk(Config, path)
    if type(node) == 'table' then return node.Enabled == true end
    return node == true
end

--- The block while its feature is on, nil while it is off or missing.
---@param path string
---@return table|nil
function Feature.active(path)
    local node = walk(Config, path)
    if type(node) == 'table' and node.Enabled == true then return node end
    return nil
end

-- ============================================================================
--                              RULES
-- ============================================================================
-- A rule is a table with a kind:
--   switch                         true or false
--   number   min, max, integer     a number in range (whole with integer)
--   text     pattern, max          a string (letters, digits, - and _, up
--                                  to 64, unless said otherwise)
--   choice   choices               one of a list of values
--   set                            a set of names, each = true
--   list     each | pattern, max,  a list of up to `most` (50) entries,
--            most, says            each read by `each` (a parser: nil is
--                                  refused) or held to pattern and length
-- and an optional default, used where defaults.lua has no value either.

local function fits(rule, value)
    local kind = rule.kind
    if kind == 'switch' then return type(value) == 'boolean' end
    if kind == 'number' then
        if type(value) ~= 'number' or value ~= value then return false end
        if rule.integer and math.floor(value) ~= value then return false end
        return value >= rule.min and value <= rule.max
    end
    if kind == 'text' then
        return type(value) == 'string' and #value > 0 and #value <= (rule.max or 64)
            and value:match(rule.pattern or '^[%w_%-]+$') ~= nil
    end
    if kind == 'choice' then
        for _, choice in ipairs(rule.choices) do if value == choice then return true end end
        return false
    end
    if type(value) ~= 'table' then return false end
    if kind == 'set' then
        for k, v in pairs(value) do
            if type(k) ~= 'string' or v ~= true then return false end
        end
        return true
    end
    if kind ~= 'list' or #value > (rule.most or 50) then return false end
    for k in pairs(value) do
        if math.type(k) ~= 'integer' or k < 1 or k > #value then return false end
    end
    for _, entry in ipairs(value) do
        if rule.each then
            if not rule.each(entry) then return false end
        elseif type(entry) ~= 'string' or #entry == 0 or #entry > (rule.max or 60)
            or not entry:match(rule.pattern or '^[^%c<>]+$') then
            return false
        end
    end
    return true
end
Feature.fits = fits

local function says(rule)
    if rule.says then return rule.says end
    local kind = rule.kind
    if kind == 'switch' then return L('lib_feature.true_or_false') end
    if kind == 'number' then
        return (L('lib_feature.a_from_to')):format(rule.integer and L('lib_feature.whole_number') or 'number',
            tostring(rule.min), tostring(rule.max))
    end
    if kind == 'text' then return L('lib_feature.a_name_of_letters_digits_and') end
    if kind == 'choice' then
        local names = {}
        for i, choice in ipairs(rule.choices) do names[i] = tostring(choice) end
        return L('lib_feature.one_of') .. table.concat(names, ', ')
    end
    if kind == 'set' then return L('lib_feature.a_set_of_job_names_each') end
    return L('lib_feature.a_list_of_short_phrases_no')
end

local function describe(value)
    if type(value) == 'string' then return ("'%s'"):format(value) end
    if type(value) == 'table' then return L('lib_feature.a_list_with_an_entry_that') end
    return tostring(value)
end

--- What a field falls back to: what ships, else the rule's default, else
--- the least its kind takes.
local function fallbackOf(rule, shipped)
    if shipped ~= nil then return shipped end
    if rule.default ~= nil then return rule.default end
    if rule.kind == 'switch' then return false end
    if rule.kind == 'number' then return rule.min end
    if rule.kind == 'choice' then return rule.choices[1] end
    if rule.kind == 'list' or rule.kind == 'set' then return {} end
    return nil
end

--- Fill a feature's block where config.lua has none, then hold every field
--- to its rule: one missing is filled from what ships (and named in
--- `filled`, when given), one that does not fit is put back to what ships
--- (and said in `warn`). A feature that cannot work is never refused a
--- start: it is off.
---@param path string the block's key path under Config, e.g. 'Intel.Rumours'
---@param rules table [field] = rule
---@param warn string[] where each correction is said
---@param filled string[]|nil where each setting filled in is named
---@return table block the block, as checked
function Feature.check(path, rules, warn, filled)
    local parent, name = Config, nil
    local parts = partsOf(path)
    for i = 1, #parts - 1 do
        if type(parent[parts[i]]) ~= 'table' then parent[parts[i]] = {} end
        parent = parent[parts[i]]
    end
    name = parts[#parts]
    local shippedBlock = walk(type(ConfigDefaults) == 'table' and ConfigDefaults or {}, path)
    local shipped = type(shippedBlock) == 'table' and shippedBlock or {}
    if type(parent[name]) ~= 'table' then
        parent[name] = Util.copy(shipped)
        if filled then filled[#filled + 1] = path .. L('lib_feature.whole_block') end
    end
    local block = parent[name]
    local fields = {}
    for field in pairs(rules) do fields[#fields + 1] = field end
    table.sort(fields)
    for _, field in ipairs(fields) do
        local rule = rules[field]
        Feature.RULES[path .. '.' .. field] = rule
        local value = block[field]
        if not fits(rule, value) then
            local fallback = fallbackOf(rule, shipped[field])
            if value == nil then
                if filled then filled[#filled + 1] = path .. '.' .. field end
            else
                warn[#warn + 1] = (L('lib_feature.is_it_has_to_be_using')):format(path, field,
                    describe(value), says(rule),
                    type(fallback) == 'table' and L('lib_feature.the_shipped_list') or describe(fallback))
            end
            block[field] = Util.copy(fallback)
        end
    end
    return block
end

return Feature
