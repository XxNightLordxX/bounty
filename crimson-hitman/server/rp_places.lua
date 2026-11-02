--- The roleplay features' shared helpers (Config.Roleplay, README "Roleplay
--- features"): where the broker and the informant NPC stand now, whether a
--- player is beside one, and the start-up check of each feature's block.
---
--- Where an NPC stands is worked out from the clock: its list of places
--- (Locations, each 'x, y, z, heading'), one at a time, the next every
--- RotateHours. Nothing is kept, so a restart, or a list changed from the
--- admin panel, never strands one somewhere old: every game is told to ask
--- again (crimson-hitman:rpPlacesChanged) and the server checks distance
--- against the place it works out now, from the player's ped, never from
--- anything the game says.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Places = {}

local deps

--- The two NPCs: which block each reads, and an offset so the two lists do
--- not move in step.
Places.NPCS = {
    broker = { block = 'Rumours', salt = 0 },
    informant = { block = 'InformantNpc', salt = 1 },
}

--- A deep copy (Util.copy, the one shared copy).
local copyOf = Util.copy

--- One feature's block of Config.Roleplay, or an empty table.
---@param name string 'Rumours' | 'BurnerPhone' | 'InformantNpc' | 'ReasonQuality'
---@return table
function Places.block(name)
    local roleplay = type(Config) == 'table' and Config.Roleplay
    local block = type(roleplay) == 'table' and roleplay[name]
    return type(block) == 'table' and block or {}
end

--- Whether a feature is on.
---@param name string
---@return boolean
function Places.on(name)
    return Places.block(name).Enabled == true
end

local function numbers(text, want)
    local out = {}
    for part in (text .. ','):gmatch('([^,]*),') do out[#out + 1] = part:match('^%s*(.-)%s*$') end
    if #out < want then return nil end
    local nums = {}
    for i = 1, want do
        local n = tonumber(out[i])
        if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
        nums[i] = n
    end
    return nums, out
end

--- 'x, y, z, heading' (the heading may be left out) as a point, or nil.
---@param text any
---@return table|nil { x, y, z, h }
function Places.parsePoint(text)
    if type(text) ~= 'string' or #text > 60 then return nil end
    local nums, parts = numbers(text, 3)
    if not nums or #parts > 4 then return nil end
    local h = 0.0
    if parts[4] and parts[4] ~= '' then
        h = tonumber(parts[4])
        if not h or h ~= h or h < 0 or h > 360 then return nil end
    end
    if math.abs(nums[1]) > 10000 or math.abs(nums[2]) > 10000 or math.abs(nums[3]) > 3000 then
        return nil
    end
    return { x = nums[1] + 0.0, y = nums[2] + 0.0, z = nums[3] + 0.0, h = h + 0.0 }
end

--- A named spot, or nil: 'x, y, name' (the rumours' districts) or
--- 'Name@x,y' (witness heat's and city news' areas). One parser for both
--- lists, and one rule for both in the panel (settings.lua NAMES.area).
---@param text any
---@return table|nil { x, y, name }
function Places.parseArea(text)
    if type(text) ~= 'string' or #text > 60 then return nil end
    local named, ax, ay = text:match('^([^@]+)@%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*$')
    if named then
        local x, y = tonumber(ax), tonumber(ay)
        named = named:match('^%s*(.-)%s*$')
        if not x or not y or x ~= x or y ~= y or named == '' or #named > 40 or named:find('[%c<>]') then
            return nil
        end
        if math.abs(x) > 10000 or math.abs(y) > 10000 then return nil end
        return { x = x, y = y, name = named }
    end
    local nums, parts = numbers(text, 2)
    if not nums or #parts < 3 then return nil end
    local name = table.concat(parts, ', ', 3):match('^%s*(.-)%s*$')
    if name == '' or #name > 40 or name:find('[%c<>]') then return nil end
    if math.abs(nums[1]) > 10000 or math.abs(nums[2]) > 10000 then return nil end
    return { x = nums[1], y = nums[2], name = name }
end

--- Where an NPC stands now, or nil when its feature is off or it has no
--- place that reads.
---@param npc string 'broker' | 'informant'
---@param now integer|nil os.time()
---@return table|nil point { x, y, z, h }
---@return integer|nil index in its list
function Places.current(npc, now)
    local spec = Places.NPCS[npc]
    if not spec or not Places.on(spec.block) then return nil end
    local block = Places.block(spec.block)
    local list = {}
    for _, text in ipairs(type(block.Locations) == 'table' and block.Locations or {}) do
        local point = Places.parsePoint(text)
        if point then list[#list + 1] = point end
    end
    if #list == 0 then return nil end
    local hours = tonumber(block.RotateHours) or 1
    if hours < 1 then hours = 1 end
    local turn = math.floor((now or os.time()) / (hours * 3600))
    local index = ((turn + spec.salt) % #list) + 1
    return list[index], index
end

--- Where a player's ped is, read on the server.
---@param src integer
---@return table|nil coords
function Places.coordsOf(src)
    local ok, coords = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        return GetEntityCoords(ped)
    end)
    return ok and coords or nil
end

--- Whether a player stands within the NPC's radius, by where the server
--- sees their ped.
---@param npc string
---@param src integer
---@return boolean
function Places.near(npc, src)
    local point = Places.current(npc)
    if not point then return false end
    local coords = Places.coordsOf(src)
    if not coords then return false end
    local radius = tonumber(Places.block(Places.NPCS[npc].block).Radius) or 0
    return Util.dist2(coords, point) <= radius * radius
end

--- What a player's game draws: each NPC on now, where, as what, and
--- whether it has a map blip. Nothing about any player.
---@return table { broker = {...} | nil, informant = {...} | nil }
function Places.forClient()
    local out = {}
    for npc, spec in pairs(Places.NPCS) do
        local point = Places.current(npc)
        if point then
            local block = Places.block(spec.block)
            out[npc] = {
                x = point.x, y = point.y, z = point.z, h = point.h,
                model = tostring(block.Model or ''), scenario = tostring(block.Scenario or ''),
                blip = block.Blip == true,
            }
        end
    end
    return out
end

--- What the games were last told, as one string, to tell when it moves.
local said

local function fingerprint()
    local parts = {}
    for _, npc in ipairs({ 'broker', 'informant' }) do
        local p = Places.forClient()[npc]
        parts[#parts + 1] = p and ('%s:%.1f:%.1f:%.1f:%s:%s:%s'):format(npc, p.x, p.y, p.z, p.model,
            p.scenario, tostring(p.blip)) or (npc .. ':none')
    end
    return table.concat(parts, '|')
end

--- Tell every game to ask again when an NPC moved or changed. The event
--- carries nothing: each game asks through the app's gate (rpPlaces).
---@param force boolean|nil
function Places.announce(force)
    local now = fingerprint()
    if not force and now == said then return false end
    said = now
    pcall(TriggerClientEvent, 'crimson-hitman:rpPlacesChanged', -1)
    return true
end

--- The settings that move or change an NPC, watched so a change from the
--- admin panel reaches every game at once.
Places.WATCHED = {
    'Roleplay.Rumours.Enabled', 'Roleplay.Rumours.Locations', 'Roleplay.Rumours.RotateHours',
    'Roleplay.Rumours.Model', 'Roleplay.Rumours.Scenario', 'Roleplay.Rumours.Blip',
    'Roleplay.InformantNpc.Enabled', 'Roleplay.InformantNpc.Locations',
    'Roleplay.InformantNpc.RotateHours', 'Roleplay.InformantNpc.Model',
    'Roleplay.InformantNpc.Scenario', 'Roleplay.InformantNpc.Blip',
}

---@param d table { settings }
function Places.init(d)
    deps = d or {}
    said = fingerprint()
    if deps.settings and deps.settings.watch then
        for _, key in ipairs(Places.WATCHED) do
            deps.settings.watch(key, function() Places.announce() end)
        end
    end
end

-- A place moves on the clock: looked at once a minute by the maintenance
-- tick (main.lua, rp_places.announce, Places.announce above), not by a
-- thread of its own. Idle with both NPCs off, it compares two short strings.

--------------------------------------------------------------------------
-- The start-up check of a feature's block
--------------------------------------------------------------------------

local function describe(value)
    if type(value) == 'string' then return ("'%s'"):format(value) end
    return tostring(value)
end

--- Whether one value is what its rule takes. kinds: switch, number (min,
--- max, integer), text (pattern), choice (choices), points, areas,
--- phrases, set (job names).
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
    if type(value) ~= 'table' then return false end
    if rule.kind == 'set' then
        for k, v in pairs(value) do
            if type(k) ~= 'string' or v ~= true then return false end
        end
        return true
    end
    if #value > 50 then return false end
    for k in pairs(value) do
        if math.type(k) ~= 'integer' or k < 1 or k > #value then return false end
    end
    for _, entry in ipairs(value) do
        if rule.kind == 'points' and not Places.parsePoint(entry) then return false end
        if rule.kind == 'areas' and not Places.parseArea(entry) then return false end
        if rule.kind == 'phrases' and (type(entry) ~= 'string' or #entry == 0 or #entry > 60
            or entry:find('[%c<>]')) then
            return false
        end
    end
    return true
end

local function says(rule)
    if rule.kind == 'switch' then return 'true or false' end
    if rule.kind == 'number' then
        return ('a %s from %s to %s'):format(rule.integer and 'whole number' or 'number',
            tostring(rule.min), tostring(rule.max))
    end
    if rule.kind == 'text' then return 'a name of letters, digits, - and _' end
    if rule.kind == 'choice' then return 'one of ' .. table.concat(rule.choices, ', ') end
    if rule.kind == 'points' then return "a list of places, each 'x, y, z, heading'" end
    if rule.kind == 'areas' then return "a list of 'x, y, name'" end
    if rule.kind == 'phrases' then return 'a list of short phrases, no < or >' end
    return 'a set of job names, each = true'
end

--- Fill a feature's block where config.lua has none (one written before
--- it existed), then hold every field to its rule: one that does not fit
--- is put back to what ships, with a warning naming it. Every check reads
--- the block whole, so the admin panel's check of a change (run against a
--- copy, quiet) refuses a value this would put back, in these words.
---@param name string the block's name under Config.Roleplay
---@param rules table [field] = rule
---@param warn string[] where a problem is added
function Places.checkBlock(name, rules, warn)
    if type(Config.Roleplay) ~= 'table' then Config.Roleplay = {} end
    local shippedRoot = type(ConfigDefaults) == 'table' and ConfigDefaults.Roleplay or nil
    local shipped = type(shippedRoot) == 'table' and type(shippedRoot[name]) == 'table'
        and shippedRoot[name] or {}
    if type(Config.Roleplay[name]) ~= 'table' then Config.Roleplay[name] = copyOf(shipped) end
    local block = Config.Roleplay[name]
    local fields = {}
    for field in pairs(rules) do fields[#fields + 1] = field end
    table.sort(fields)
    for _, field in ipairs(fields) do
        local rule = rules[field]
        if not fits(rule, block[field]) then
            local fallback = shipped[field]
            if fallback == nil then fallback = rule.default end
            if block[field] ~= nil then
                warn[#warn + 1] = ('Roleplay.%s.%s is %s; it has to be %s. Using %s.'):format(name, field,
                    type(block[field]) == 'table' and 'a list with an entry that does not read'
                    or describe(block[field]), says(rule),
                    type(fallback) == 'table' and 'the shipped list' or describe(fallback))
            end
            block[field] = copyOf(fallback)
        end
    end
end

--- Log a third-party call that raised, once a minute per name.
local said_at = {}
function Places.raised(what, err)
    local now = os.time()
    if said_at[what] and now - said_at[what] < 60 then return end
    said_at[what] = now
    Log.problem(('%s raised: %s'):format(what, tostring(err)))
end

return Places
