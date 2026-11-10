--- The roleplay features' shared helpers (Config.Roleplay, README, Optional
--- features): where the broker and the informant NPC stand now, whether a
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
local Geo = CrimsonBoot.requireShared('geo')
local Text = CrimsonBoot.requireShared('text')

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
-- as the config list does). Kept by the store with the other spots staff
-- set (Storage.writeRpRow, kind 'rp_place'), in every backend. While none
-- is set for an NPC, or the switch is off, its config Locations are used:
-- they are the defaults, and nothing set here is lost by turning it off.

Places.ROW_KIND = 'rp_place'
Places.MAX_PER_NPC = 20

--- The rows set from the panel, read once: { broker = { row }, informant = { row } },
--- or nil while the store could not be read (config is used meanwhile).
local Custom, CustomSeq = nil, 0

local function panelOn()
    return Places.on('NpcPlaces')
end

local function loadCustom()
    if Custom then return Custom end
    local storage = deps and deps.storage
    if not (storage and storage.readRpRows) then return nil end
    local ok, rows = pcall(storage.readRpRows, Places.ROW_KIND)
    if not ok or type(rows) ~= 'table' then return nil end
    local out = {}
    for npc in pairs(Places.NPCS) do out[npc] = {} end
    for _, r in ipairs(rows) do
        if type(r) == 'table' and type(r.id) == 'string' and out[r.npc] and tonumber(r.x) and tonumber(r.y)
            and tonumber(r.z) then
            out[r.npc][#out[r.npc] + 1] = r
        end
    end
    for _, list in pairs(out) do table.sort(list, function(a, b) return a.id < b.id end) end
    Custom = out
    return Custom
end

--- The enabled places set from the panel for one NPC, as points, or nil
--- (the switch off, the store unread, or none set: config's list is used).
---@param npc string
---@return table[]|nil
function Places.panelPoints(npc)
    if not panelOn() then return nil end
    local custom = loadCustom()
    local rows = custom and custom[npc]
    if not rows then return nil end
    local list = {}
    for _, r in ipairs(rows) do
        if r.enabled ~= false then
            list[#list + 1] = { x = tonumber(r.x) + 0.0, y = tonumber(r.y) + 0.0, z = tonumber(r.z) + 0.0,
                h = (tonumber(r.h) or 0) + 0.0 }
        end
    end
    return #list > 0 and list or nil
end

local SPOT_BOUNDS = { minX = -4500.0, maxX = 6000.0, minY = -6500.0, maxY = 8500.0, minZ = -200.0, maxZ = 2000.0 }

local function cleanLabel(v)
    if v == nil then return nil, true end
    if type(v) ~= 'string' then return nil, false end
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or #v > 40 or v:find('[%c<>]') then return nil, false end
    return v, true
end

--- What Locations shows for each NPC: the places set here and the config
--- defaults, and which of the two is in use.
---@return table
function Places.panelView()
    local custom = loadCustom()
    local out = { enabled = panelOn(), readable = custom ~= nil, npcs = {} }
    for _, npc in ipairs({ 'broker', 'informant' }) do
        local spec = Places.NPCS[npc]
        local block = Places.block(spec.block)
        local defaults = {}
        for _, text in ipairs(type(block.Locations) == 'table' and block.Locations or {}) do
            local point = Places.parsePoint(text)
            if point then defaults[#defaults + 1] = point end
        end
        local rows = {}
        for _, r in ipairs(custom and custom[npc] or {}) do
            rows[#rows + 1] = { id = r.id, label = r.label, x = tonumber(r.x), y = tonumber(r.y), z = tonumber(r.z),
                heading = tonumber(r.h) or 0, enabled = r.enabled ~= false }
        end
        out.npcs[npc] = { on = Places.on(spec.block), rows = rows, defaults = defaults,
            using = Places.panelPoints(npc) and 'panel' or 'config', key = 'Roleplay.' .. spec.block .. '.Locations' }
    end
    return out
end

--- Set (or move) one place from the panel: typed figures, or `at` read by
--- the server where the staff member stands.
---@param staffCid string
---@param spec table { npc, id?, label?, enabled?, at = { x, y, z, h } }
---@return boolean ok
---@return string|nil err
---@return table|nil row
function Places.setPanelPlace(staffCid, spec)
    if not panelOn() then return false, 'feature_off' end
    if type(spec) ~= 'table' or not Places.NPCS[spec.npc] then return false, 'invalid_input' end
    local custom = loadCustom()
    if not custom then return false, 'store_unreadable' end
    local at = type(spec.at) == 'table' and spec.at or nil
    local x, y, z = at and tonumber(at.x), at and tonumber(at.y), at and tonumber(at.z)
    local h = at and tonumber(at.h) or 0
    if not x or not y or not z or x ~= x or y ~= y or z ~= z or h ~= h or h < 0 or h > 360
        or x < SPOT_BOUNDS.minX or x > SPOT_BOUNDS.maxX or y < SPOT_BOUNDS.minY or y > SPOT_BOUNDS.maxY
        or z < SPOT_BOUNDS.minZ or z > SPOT_BOUNDS.maxZ then
        return false, 'invalid_input'
    end
    local label, labelOk = cleanLabel(spec.label)
    if not labelOk then return false, 'invalid_input' end
    if spec.enabled ~= nil and type(spec.enabled) ~= 'boolean' then return false, 'invalid_input' end
    local list = custom[spec.npc]
    local existing
    if spec.id ~= nil then
        for _, r in ipairs(list) do if r.id == spec.id then existing = r end end
        if not existing then return false, 'not_found' end
    elseif #list >= Places.MAX_PER_NPC then
        return false, 'limit_reached'
    end
    local id = existing and existing.id
    if not id then
        CustomSeq = CustomSeq + 1
        id = ('%s:%s:%d_%d'):format(Places.ROW_KIND, spec.npc, os.time(), CustomSeq)
    end
    local function r1(n) return math.floor(n * 10 + 0.5) / 10 end
    local row = { id = id, kind = Places.ROW_KIND, npc = spec.npc,
        label = label or (existing and existing.label) or (spec.npc == 'broker' and 'Broker' or 'Informant'),
        x = r1(x), y = r1(y), z = r1(z), h = r1(h),
        enabled = spec.enabled == nil and (existing == nil or existing.enabled ~= false) or spec.enabled,
        by = staffCid, at = os.time() }
    local ok = pcall(deps.storage.writeRpRow, row)
    if not ok then return false, 'store_unreadable' end
    if existing then
        for i, r in ipairs(list) do if r.id == id then list[i] = row end end
    else
        list[#list + 1] = row
        table.sort(list, function(a, b) return a.id < b.id end)
    end
    if deps.audit then
        pcall(deps.audit.staff, 'rp_place_set', staffCid, nil, { npc = spec.npc, id = id, x = row.x, y = row.y,
            z = row.z, moved = existing ~= nil or nil })
    end
    Places.announce()
    return true, nil, row
end

--- Remove one place set from the panel, or (npc given, id nil) every one of
--- that NPC's: its config list applies again.
---@return boolean ok
---@return string|nil err
---@return integer|nil removed
function Places.removePanelPlace(staffCid, id, npc)
    if not panelOn() then return false, 'feature_off' end
    local custom = loadCustom()
    if not custom then return false, 'store_unreadable' end
    local removed = 0
    for name, list in pairs(custom) do
        for i = #list, 1, -1 do
            local r = list[i]
            if (id ~= nil and r.id == id) or (id == nil and npc ~= nil and name == npc) then
                if not pcall(deps.storage.deleteRpRow, r.id) then return false, 'store_unreadable' end
                table.remove(list, i)
                removed = removed + 1
            end
        end
    end
    if removed == 0 then return false, 'not_found' end
    if deps.audit then
        pcall(deps.audit.staff, 'rp_place_removed', staffCid, nil, { npc = npc, id = id, count = removed })
    end
    Places.announce()
    return true, nil, removed
end

--- The admin panel's requests for these places (Locations): the list, a
--- set (here = true: where the staff member stands, read by the server),
--- a removal, and a reset to the config list. Off, each write says so.
Places.OPS = {}
---@param panel table
function Places.addOps(panel)
    if not (panel and panel.extend and panel.LEVELS) then return end
    local READ, WRITE = panel.LEVELS.READ, panel.LEVELS.WRITE
    local function staffCid(src) return panel.staffOf and panel.staffOf(src) or ('player ' .. tostring(src)) end
    local SAYS = {
        feature_off = 'Turn on Roleplay.NpcPlaces (Switches) to place the broker and informant from here.',
        invalid_input = 'Give the NPC (broker or informant), a point on the map and a short name.',
        not_found = 'That place is gone. Refresh Locations.',
        limit_reached = ('At most %d places for one NPC.'):format(Places.MAX_PER_NPC),
        store_unreadable = 'The store did not take it; nothing was changed. Try again.',
    }
    Places.OPS = { rpPlaceList = READ, rpPlaceSet = WRITE, rpPlaceRemove = WRITE, rpPlaceReset = WRITE }
    panel.extend('rpPlaceList', READ, function()
        return true, nil, nil, Places.panelView()
    end)
    panel.extend('rpPlaceSet', WRITE, function(src, data)
        local at
        if data.here == true then
            local coords = Geo.position(src)
            if not coords then return false, 'not_found', 'The server cannot see your character right now.' end
            local okH, heading = pcall(function() return GetEntityHeading(GetPlayerPed(src)) end)
            at = { x = coords.x, y = coords.y, z = coords.z, h = okH and tonumber(heading) or 0 }
        else
            at = { x = data.x, y = data.y, z = data.z, h = data.heading }
        end
        local ok, err, row = Places.setPanelPlace(staffCid(src), { npc = Text.field(data.npc, 16),
            id = Text.field(data.id, 64), label = data.label, enabled = data.enabled, at = at })
        if not ok then return false, err, SAYS[err] or SAYS.invalid_input end
        return true, nil, 'Place saved.', row
    end)
    panel.extend('rpPlaceRemove', WRITE, function(src, data)
        local id = Text.field(data.id, 64)
        if not id then return false, 'invalid_input', SAYS.not_found end
        local ok, err = Places.removePanelPlace(staffCid(src), id, nil)
        if not ok then return false, err, SAYS[err] or SAYS.not_found end
        return true, nil, 'Place removed.'
    end)
    panel.extend('rpPlaceReset', WRITE, function(src, data)
        local npc = Text.field(data.npc, 16)
        if not Places.NPCS[npc or ''] then return false, 'invalid_input', SAYS.invalid_input end
        local ok, err, removed = Places.removePanelPlace(staffCid(src), nil, npc)
        if not ok then
            return false, err, err == 'not_found' and 'None set: it already uses the config list.' or SAYS[err]
        end
        return true, nil, ('%d place(s) removed: the config list applies again.'):format(removed)
    end)
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
    local radius = tonumber(Places.block(Places.NPCS[npc].block).Radius) or 0
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
    'Roleplay.NpcPlaces.Enabled',
}

---@param d table { settings, storage, audit }
function Places.init(d)
    deps = d or {}
    Custom, CustomSeq = nil, 0
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


return Places
