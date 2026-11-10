--- The roleplay features' shared helpers (Config.Roleplay, README, Optional
--- features): where the broker and the informant NPC stand now, whether a
--- player is beside one. Each feature's block is read and checked through
--- server/lib/feature.lua.
---
--- Where an NPC stands is worked out from the clock: its list of places
--- (Locations, each 'x, y, z, heading'), one at a time, the next every
--- RotateHours. Nothing is kept, so a restart, or a list changed from the
--- admin panel, never strands one somewhere old: every game is told to ask
--- again (crimson-hitman:rpPlacesChanged) and the server checks distance
--- against the place it works out now, from the player's ped, never from
--- anything the game says.

local Geo = CrimsonBoot.requireShared('geo')
local Feature = CrimsonBoot.require('server.lib.feature')
local Registry = CrimsonBoot.require('server.places')

local Places = {}

local deps

--- The two NPCs: which block each reads, and an offset so the two lists do
--- not move in step.
Places.NPCS = {
    broker = { block = 'Roleplay.Rumours', salt = 0 },
    informant = { block = 'Roleplay.InformantNpc', salt = 1 },
}

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
    local block = spec and Feature.active(spec.block)
    if not block then return nil end
    -- The places staff set in Locations, where Config.Roleplay.NpcPlaces
    -- says so and one is set; the config list otherwise (the defaults).
    local list = Places.panelPoints(npc)
    if not list then
        list = {}
        for _, text in ipairs(type(block.Locations) == 'table' and block.Locations or {}) do
            local point = Places.parsePoint(text)
            if point then list[#list + 1] = point end
        end
    end
    if #list == 0 then return nil end
    local hours = tonumber(block.RotateHours) or 1
    if hours < 1 then hours = 1 end
    local turn = math.floor((now or os.time()) / (hours * 3600))
    local index = ((turn + spec.salt) % #list) + 1
    return list[index], index
end

-- ============================================================================
--                              PLACES SET FROM THE PANEL
-- ============================================================================
-- Config.Roleplay.NpcPlaces (off as shipped): staff stand on a spot and
-- press Use my position in the admin panel's Locations, and the broker or
-- the informant stands there (one at a time, rotating as RotateHours says,
-- as the config list does). Kept in the one registry of map spots
-- (server/places.lua, kinds 'broker' and 'informant'), in every backend.
-- While none is set for an NPC, or the switch is off, its config Locations
-- are used: they are the defaults, and nothing set here is lost by turning
-- it off.

Places.MAX_PER_NPC = 20

local function panelOn()
    return Feature.on('Roleplay.NpcPlaces')
end

--- The enabled places set from the panel for one NPC, as points, or nil
--- (the switch off, the store unread, or none set: config's list is used).
---@param npc string
---@return table[]|nil
function Places.panelPoints(npc)
    if not panelOn() then return nil end
    local rows = Registry.rows(npc)
    if not rows then return nil end
    local list = {}
    for _, r in ipairs(rows) do
        if r.enabled ~= false then
            list[#list + 1] = { x = r.x + 0.0, y = r.y + 0.0, z = r.z + 0.0, h = (r.h or 0) + 0.0 }
        end
    end
    return #list > 0 and list or nil
end

local function defaultsOf(npc)
    local block = Feature.block(Places.NPCS[npc].block)
    local out = {}
    for _, text in ipairs(type(block.Locations) == 'table' and block.Locations or {}) do
        local point = Places.parsePoint(text)
        if point then out[#out + 1] = point end
    end
    return out
end

--- Both NPCs as kinds of the registry: staff only, at most MAX_PER_NPC
--- each, set only while Roleplay.NpcPlaces is on; audited rp_place_set /
--- rp_place_removed; every game told to ask again.
local function registerKinds()
    for _, npc in ipairs({ 'broker', 'informant' }) do
        local spec = Places.NPCS[npc]
        local name = npc == 'broker' and 'Broker' or 'Informant'
        Registry.kind(npc, {
            group = 'npc', label = name .. ' NPC', one = npc .. ' place', icon = 'user-secret',
            fields = { label = true, enabled = true }, labelMax = 40, defaultLabel = name, labelOptional = true,
            reset = true,
            max = function() return Places.MAX_PER_NPC end,
            ready = function() if not panelOn() then return 'feature_off' end end,
            says = {
                feature_off = 'Turn on Roleplay.NpcPlaces (Switches) to place the broker and informant from here.',
                invalid_input = 'Give the NPC (broker or informant), a point on the map and a short name.',
                limit_reached = ('At most %d places for one NPC.'):format(Places.MAX_PER_NPC),
            },
            after = function(who, row, existing)
                if deps.audit then
                    pcall(deps.audit.staff, 'rp_place_set', who.cid, nil, { npc = npc, id = row.id, x = row.x,
                        y = row.y, z = row.z, moved = existing ~= nil or nil })
                end
                Places.announce()
            end,
            removed = function(who, rows, all)
                if deps.audit then
                    pcall(deps.audit.staff, 'rp_place_removed', who.cid, nil, { npc = all and npc or nil,
                        id = not all and rows[1].id or nil, count = #rows })
                end
                Places.announce()
            end,
            view = function()
                return { on = Feature.on(spec.block), defaults = defaultsOf(npc), switch = 'Roleplay.NpcPlaces.Enabled',
                    using = Places.panelPoints(npc) and 'panel' or 'config', key = spec.block .. '.Locations' }
            end,
        })
    end
end

--- Whether a player stands within the NPC's radius, by where the server
--- sees their ped.
---@param npc string
---@param src integer
---@return boolean
function Places.near(npc, src)
    local point = Places.current(npc)
    if not point then return false end
    local coords = Geo.position(src)
    if not coords then return false end
    local radius = tonumber(Feature.block(Places.NPCS[npc].block).Radius) or 0
    return Geo.near(coords, point, radius)
end

--- What a player's game draws: each NPC on now, where, as what, and
--- whether it has a map blip. Nothing about any player.
---@return table { broker = {...} | nil, informant = {...} | nil }
function Places.forClient()
    local out = {}
    for npc, spec in pairs(Places.NPCS) do
        local point = Places.current(npc)
        if point then
            local block = Feature.block(spec.block)
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
    'Roleplay.NpcPlaces.Enabled',
}

---@param d table { settings, storage, audit }
function Places.init(d)
    deps = d or {}
    Registry.attach(deps.storage)
    registerKinds()
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

return Places
