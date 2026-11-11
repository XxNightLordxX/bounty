--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                    crimson-hitman - server/places.lua                     ║
    ║       The one registry of the map spots staff (and bosses) set            ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Every spot set on the map from the admin panel's Locations (or, for the
--- organisation's own, from the boss menu) lives here: one row shape, one
--- store (crimson_rp_rows, kind 'map_place', in every backend), one reading
--- of where a staff member stands (Use my position), one check of what is
--- set (map bounds, NaN, heading, name, radius, how many), one list for the
--- panel. What each kind is for, and its own rules, stay with its feature,
--- which registers it here (Places.kind):
---
---   office, signup, meeting, npc, place   the hitman organisation's spots
---                                         (server/org/init.lua: who may set
---                                         each, the boss office's reach,
---                                         the cooldown, the safe zones)
---   broker, informant                     where the roleplay NPCs stand
---                                         (server/rp_places.lua; the config
---                                         Locations lists stay the defaults)
---   disposal_vehicle, disposal_drop       body disposal's two spots
---                                         (server/disposal.lua; config's
---                                         VehicleSpawn/DropOff the defaults)
---
--- The places that are settings (tip safe zones, the rumours' districts and
--- zone names, witness heat's areas, the prison zone, the NPCs' default
--- lists) stay settings: their catalogue entries carry `place`, and the
--- same Locations view edits them, with Use my position filling a line.
---
--- A row: { id, kind, owner, label, x, y, z, h, radius, blip, enabled,
--- anchor, by, at }. `owner` is the organisation's id for its spots and ''
--- for the others. Positions are metres to one decimal, h a heading 0-360.

local Util = CrimsonBoot.requireShared('util')
local Geo = CrimsonBoot.requireShared('geo')
local Text = CrimsonBoot.requireShared('text')
local L = CrimsonBoot.requireShared('locale').t

local Places = {}

Places.STORE_KIND = 'map_place'

--- The map, a little past its edges: a spot outside is a typo.
Places.BOUNDS = { minX = -4500.0, maxX = 6000.0, minY = -6500.0, maxY = 8500.0, minZ = -200.0, maxZ = 2000.0 }

--- [name] = spec, in the order registered (Order).
local Kinds = {}
local Order = {}
--- [id] = row, or nil while the store has not been read.
local Rows = nil
--- [owner][id] = row: live tables, never replaced, so a feature may keep one.
local ByOwner = {}
local Storage = nil
local Seq = 0

local SAYS = {
    invalid_input = L('places.check_the_place_a_point_on'),
    not_found = L('places.that_place_is_gone_refresh_locations'),
    limit_reached = L('places.at_the_most_places_of_this'),
    store_unreadable = L('places.the_store_did_not_take_it'),
    no_position = L('places.the_server_cannot_see_your_character'),
    feature_off = L('places.its_feature_is_off'),
}

local function owned(owner)
    owner = owner or ''
    ByOwner[owner] = ByOwner[owner] or {}
    return ByOwner[owner]
end

local function r1(n) return math.floor(n * 10 + 0.5) / 10 end

--- A stored row as a row here, or nil when it does not read.
local function fromStore(r)
    if type(r) ~= 'table' or type(r.id) ~= 'string' or type(r.place) ~= 'string' then return nil end
    local x, y, z = Geo.finite(r.x), Geo.finite(r.y), Geo.finite(r.z)
    if not x or not y or not z then return nil end
    return { id = r.id, kind = r.place, owner = type(r.owner) == 'string' and r.owner or '',
        label = type(r.label) == 'string' and r.label or r.place, x = x, y = y, z = z, h = Geo.finite(r.h) or 0.0,
        radius = Geo.finite(r.radius), blip = r.blip == true or nil, enabled = r.enabled ~= false,
        anchor = type(r.anchor) == 'table' and Geo.finite(r.anchor.x) and Geo.finite(r.anchor.y)
            and { x = Geo.finite(r.anchor.x), y = Geo.finite(r.anchor.y) } or nil,
        by = r.by, at = r.at }
end

local function toStore(row)
    local out = Util.copy(row)
    out.kind, out.place = Places.STORE_KIND, row.kind
    return out
end

--- Use the store a feature was wired with, and read it (again): each
--- feature's start reads what is kept now, into the same live tables.
---@param storage table|nil
function Places.attach(storage)
    if storage == nil then return end
    if storage ~= Storage then Seq = 0 end
    Storage, Rows = storage, nil
    for _, list in pairs(ByOwner) do
        for id in pairs(list) do list[id] = nil end
    end
    Places.load()
end

--- Read the store once: true when it is read.
---@return boolean
function Places.load()
    if Rows then return true end
    if not (Storage and Storage.readRpRows) then return false end
    local ok, rows = pcall(Storage.readRpRows, Places.STORE_KIND)
    if not ok or type(rows) ~= 'table' then return false end
    Rows = {}
    for _, list in pairs(ByOwner) do
        for id in pairs(list) do list[id] = nil end
    end
    for _, r in ipairs(rows) do
        local row = fromStore(r)
        if row then
            Rows[row.id] = row
            owned(row.owner)[row.id] = row
        end
    end
    return true
end

-- ============================================================================
--                              KINDS
-- ============================================================================

--- Register a kind of spot. spec:
---   group, label, one, icon     how Locations shows it ('org' | 'npc' | 'disposal')
---   fields = { label, radius, blip, enabled }   what may be set beside the point
---   labelMax, defaultLabel, labelOptional (the panel may leave the name out),
---   radius = { min, max, default }
---   single                      one per owner (a new save moves it)
---   reset                       Reset takes every one of this kind off
---   max(who)                    how many there may be, for this actor
---   owner()                     whose they are now ('' for nobody's), nil: none now
---   ready(who)                  nil, or err[, extra]: the kind cannot be set now
---   allow(who, existing)        nil, or err: this actor may not set it (before the position is read)
---   rules(who, at, existing)    nil, or err[, extra]: the kind's own rules on where
---   anchor(who, at, existing)   the anchor kept with the row, or nil
---   after(who, row, existing)   audit and tell whoever draws it
---   mayRemove(who, row)         nil, or err
---   removed(who, rows, all)     audit and tell, after a removal (all: a reset)
---   says = { [err] = text }     its own words for a refusal
---   view()                      extra fields for the panel (defaults, using, note, off, switch)
---@param name string
---@param spec table
function Places.kind(name, spec)
    if type(name) ~= 'string' or type(spec) ~= 'table' then return end
    if not Kinds[name] then Order[#Order + 1] = name end
    spec.name = name
    spec.fields = spec.fields or {}
    Kinds[name] = spec
end

local function ownerOf(kind)
    if not kind.owner then return '' end
    return kind.owner()
end

--- Every row of a kind (of its current owner, or `owner`), by id; nil
--- while the store cannot be read.
---@param name string
---@param owner string|nil
---@return table[]|nil
function Places.rows(name, owner)
    if not Places.load() then return nil end
    local kind = Kinds[name]
    owner = owner or (kind and ownerOf(kind))
    if owner == nil then return {} end
    local out = {}
    for _, row in pairs(owned(owner)) do
        if row.kind == name then out[#out + 1] = row end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- The live [id] = row table of one owner's spots (the organisation keeps
--- it as its locations).
---@param owner string
---@return table
function Places.owned(owner)
    Places.load()
    return owned(owner)
end

--- How many of a kind its owner has.
function Places.count(name, owner)
    local n = 0
    for _, row in pairs(owned(owner or '')) do
        if row.kind == name then n = n + 1 end
    end
    return n
end

-- ============================================================================
--                              THE ONE CHECK
-- ============================================================================

--- Where the server sees a player's character, with its heading, or nil.
---@param src integer
---@return table|nil { x, y, z, h }
function Places.positionOf(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local at = Geo.position(src)
    if type(at) ~= 'table' and type(at) ~= 'vector3' and type(at) ~= 'userdata' then return nil end
    local _, h = pcall(function() return GetEntityHeading(GetPlayerPed(src)) end)
    local x, y, z = Geo.finite(at.x), Geo.finite(at.y), Geo.finite(at.z)
    if not x or not y or not z or (x == 0 and y == 0 and z == 0) then return nil end
    return { x = x, y = y, z = z, h = Geo.finite(h) or 0 }
end

--- A point on the map: finite, inside the bounds, its heading a number
--- (kept as 0-360). nil when it is not one.
---@param at table|nil { x, y, z, h }
---@return table|nil { x, y, z, h }
function Places.point(at)
    if type(at) ~= 'table' then return nil end
    local x, y, z = Geo.finite(at.x), Geo.finite(at.y), Geo.finite(at.z)
    local h = at.h == nil and 0 or Geo.finite(at.h)
    if not x or not y or not z or not h then return nil end
    local b = Places.BOUNDS
    if x < b.minX or x > b.maxX or y < b.minY or y > b.maxY or z < b.minZ or z > b.maxZ then return nil end
    if h < -360 or h > 360 then return nil end
    return { x = x, y = y, z = z, h = h % 360 }
end

--- A spot's name: trimmed, 1 to `max` long, no control characters or < >.
---@return string|nil
function Places.label(v, max)
    if type(v) ~= 'string' then return nil end
    v = Util.toValidUtf8(v):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' or #v > (max or 40) or v:find('[%c<>]') then return nil end
    return v
end

local function refuse(kind, err, extra)
    local text = (type(extra) == 'table' and extra.message) or (kind and kind.says and kind.says[err]) or SAYS[err]
    return false, err, text or L('places.not_done'), extra
end

-- ============================================================================
--                              SET, REMOVE, RESET
-- ============================================================================

--- Set (or move) a spot. `who` = { staff = true, cid, source } from the
--- panel, or a boss actor for the organisation's own. At `here` (or always
--- for anybody but staff) where the server sees them, else the figures.
---@param who table
---@param name string
---@param spec table { id?, label?, radius?, blip?, enabled?, here?, x?, y?, z?, heading? }
---@return boolean ok
---@return string|nil err
---@return table|string row, or the refusal's words
---@return table|nil extra
function Places.set(who, name, spec)
    local kind = Kinds[name]
    if type(who) ~= 'table' or not kind or type(spec) ~= 'table' then return refuse(kind, 'invalid_input') end
    if not who.staff and not kind.allow then return refuse(kind, 'invalid_input') end
    if kind.ready then
        local err, extra = kind.ready(who)
        if err then return refuse(kind, err, extra) end
    end
    if kind.allow then
        local err = kind.allow(who)
        if err then return refuse(kind, err) end
    end
    if not Places.load() then return refuse(kind, 'store_unreadable') end
    local owner = ownerOf(kind)
    if owner == nil then return refuse(kind, 'feature_off') end
    local existing
    if spec.id ~= nil then
        existing = type(spec.id) == 'string' and Rows[spec.id] or nil
        if not existing or existing.kind ~= name or existing.owner ~= owner then return refuse(kind, 'not_found') end
    elseif kind.single then
        existing = Places.rows(name, owner)[1]
    end
    local at
    if spec.here or not who.staff then
        at = Places.positionOf(who.source)
        if not at then return refuse(kind, 'no_position') end
    else
        at = { x = spec.x, y = spec.y, z = spec.z, h = spec.heading }
    end
    at = Places.point(at)
    if not at then return refuse(kind, 'invalid_input') end
    local f = kind.fields
    local label = existing and existing.label or kind.defaultLabel or kind.label or name
    if f.label and spec.label ~= nil then
        label = Places.label(spec.label, kind.labelMax)
        if not label then return refuse(kind, 'invalid_input') end
    end
    local radius
    if f.radius then
        local r = kind.radius or {}
        radius = spec.radius == nil and (existing and existing.radius or r.default or 2.0) or Geo.finite(spec.radius)
        if not radius or radius < (r.min or 0.5) or radius > (r.max or 50) then return refuse(kind, 'invalid_input') end
    end
    for _, key in ipairs({ 'blip', 'enabled' }) do
        if spec[key] ~= nil and type(spec[key]) ~= 'boolean' then return refuse(kind, 'invalid_input') end
    end
    if kind.rules then
        local err, extra = kind.rules(who, at, existing)
        if err then return refuse(kind, err, extra) end
    end
    if not existing and kind.max and Places.count(name, owner) >= kind.max(who) then
        return refuse(kind, 'limit_reached')
    end
    local id = existing and existing.id
    if not id then
        -- Random, with the counter so two in one run never meet: a time
        -- and a sequence let a player who is sent one spot's id guess the
        -- id of a spot they are not sent (a territory).
        Seq = Seq + 1
        id = ('%s:%s:%s%d'):format(owner ~= '' and owner or 'place', name, Util.randomId(''), Seq):sub(1, 48)
    end
    local row = {
        id = id, kind = name, owner = owner, label = label,
        x = r1(at.x), y = r1(at.y), z = r1(at.z), h = r1(at.h) % 360,
        radius = radius and r1(radius) or nil,
        blip = f.blip and (spec.blip == nil and (existing and existing.blip) or spec.blip == true) or nil,
        enabled = spec.enabled == nil and (existing == nil or existing.enabled ~= false) or spec.enabled,
        anchor = (kind.anchor and kind.anchor(who, at, existing)) or (existing and existing.anchor) or nil,
        by = who.cid, at = os.time(),
    }
    if row.blip == false then row.blip = nil end
    if not pcall(Storage.writeRpRow, toStore(row)) then return refuse(kind, 'store_unreadable') end
    Rows[id] = row
    owned(owner)[id] = row
    if kind.after then pcall(kind.after, who, row, existing) end
    return true, nil, row
end

local function drop(row)
    if not pcall(Storage.deleteRpRow, row.id) then return false end
    Rows[row.id] = nil
    owned(row.owner)[row.id] = nil
    return true
end

--- Remove one spot by id (`only`: the kinds it may be, for a caller that
--- speaks for one feature).
---@return boolean ok
---@return string|nil err
---@return table|string row, or the refusal's words
function Places.remove(who, id, only)
    if type(who) ~= 'table' or type(id) ~= 'string' then return refuse(nil, 'not_found') end
    if not Places.load() then return refuse(nil, 'store_unreadable') end
    local row = Rows[id]
    local kind = row and Kinds[row.kind]
    if not kind or (only and not only[row.kind]) then return refuse(nil, 'not_found') end
    if kind.ready then
        local err, extra = kind.ready(who)
        if err then return refuse(kind, err, extra) end
    end
    if row.owner ~= ownerOf(kind) then return refuse(kind, 'not_found') end
    if not who.staff and not kind.mayRemove then return refuse(kind, 'not_found') end
    if kind.mayRemove then
        local err = kind.mayRemove(who, row)
        if err then return refuse(kind, err) end
    end
    if not drop(row) then return refuse(kind, 'store_unreadable') end
    if kind.removed then pcall(kind.removed, who, { row }, false) end
    return true, nil, row
end

--- Remove every spot of a kind (Reset: its config defaults apply again).
---@return boolean ok
---@return string|nil err
---@return integer|string removed, or the refusal's words
function Places.reset(who, name)
    local kind = Kinds[name]
    if type(who) ~= 'table' or not who.staff or not kind or not kind.reset then return refuse(kind, 'invalid_input') end
    if kind.ready then
        local err, extra = kind.ready(who)
        if err then return refuse(kind, err, extra) end
    end
    local rows = Places.rows(name)
    if not rows then return refuse(kind, 'store_unreadable') end
    if #rows == 0 then return refuse(kind, 'not_found') end
    local gone = {}
    for _, row in ipairs(rows) do
        if not drop(row) then return refuse(kind, 'store_unreadable') end
        gone[#gone + 1] = row
    end
    if kind.removed then pcall(kind.removed, who, gone, true) end
    return true, nil, #gone
end

-- ============================================================================
--                              THE PANEL
-- ============================================================================

local function rowView(row)
    return { id = row.id, kind = row.kind, label = row.label, x = row.x, y = row.y, z = row.z, heading = row.h,
        radius = row.radius, blip = row.blip == true, enabled = row.enabled ~= false }
end

--- What Locations shows: every kind, in order, with its rows.
---@return table { readable, kinds = { ... } }
function Places.view()
    local readable = Places.load()
    local out = { readable = readable, kinds = {} }
    for _, name in ipairs(Order) do
        local kind = Kinds[name]
        local off
        if kind.ready then
            local okR, err, extra = pcall(kind.ready, { staff = true })
            if okR and err then
                off = (type(extra) == 'table' and extra.message) or (kind.says and kind.says[err]) or SAYS[err] or err
            end
        end
        local rows = {}
        local owner = ownerOf(kind)
        if readable and owner ~= nil then
            for _, row in ipairs(Places.rows(name, owner) or {}) do rows[#rows + 1] = rowView(row) end
        end
        local entry = {
            id = name, group = kind.group, label = kind.label, one = kind.one, icon = kind.icon,
            fields = Util.copy(kind.fields), labelMax = kind.labelMax, single = kind.single == true,
            labelOptional = kind.labelOptional == true,
            reset = kind.reset == true, radius = kind.radius and Util.copy(kind.radius) or nil,
            max = kind.max and kind.max({ staff = true }) or nil, off = off, rows = rows,
        }
        if kind.view then
            local okV, extra = pcall(kind.view)
            if okV and type(extra) == 'table' then
                for k, v in pairs(extra) do entry[k] = v end
            end
        end
        out.kinds[#out.kinds + 1] = entry
    end
    return out
end

--- The panel's requests: the list, Use my position, a set (here = true:
--- where the staff member stands, read by the server), a removal and a
--- reset. Each through the panel's one gate (the ACE, the buckets).
Places.OPS = {}
---@param panel table
function Places.addOps(panel)
    if not (panel and panel.extend and panel.LEVELS) then return end
    local READ, WRITE = panel.LEVELS.READ, panel.LEVELS.WRITE
    local function staff(src)
        return { staff = true, cid = panel.staffOf and panel.staffOf(src) or ('player ' .. tostring(src)), source = src }
    end
    local function said(ok, err, what, extra, done)
        if not ok then return false, err, what, extra end
        return true, nil, done, what
    end
    Places.OPS = { placeList = READ, placeMyPosition = READ, placeSet = WRITE, placeRemove = WRITE,
        placeReset = WRITE }
    -- Several organisations: an op on the one data.org names (Places.scope,
    -- set by server/org/init.lua); the first where none is named.
    local extend = panel.extend
    local function scoped(name, level, fn)
        extend(name, level, function(src, data)
            if Places.scope then return Places.scope(data, function() return fn(src, data) end) end
            return fn(src, data)
        end)
    end
    panel = setmetatable({ extend = scoped }, { __index = panel })
    panel.extend('placeList', READ, function()
        return true, nil, nil, Places.view()
    end)
    panel.extend('placeMyPosition', READ, function(src)
        local at = Places.positionOf(src)
        if not at then return false, 'not_found', SAYS.no_position end
        return true, nil, nil, { x = at.x, y = at.y, z = at.z, heading = at.h }
    end)
    panel.extend('placeSet', WRITE, function(src, data)
        local name = Text.field(data.kind, 24)
        if not name or not Kinds[name] then return false, 'invalid_input', SAYS.invalid_input end
        local ok, err, row, extra = Places.set(staff(src), name, {
            id = Text.field(data.id, 48), label = Text.field(data.label, 128), radius = data.radius,
            blip = data.blip, enabled = data.enabled, here = data.here == true,
            x = data.x, y = data.y, z = data.z, heading = data.heading })
        return said(ok, err, ok and rowView(row) or row, extra, L('places.place_saved'))
    end)
    panel.extend('placeRemove', WRITE, function(src, data)
        local id = Text.field(data.id, 48)
        if not id then return false, 'invalid_input', SAYS.not_found end
        local ok, err, what = Places.remove(staff(src), id)
        return said(ok, err, ok and nil or what, nil, L('places.place_removed'))
    end)
    panel.extend('placeReset', WRITE, function(src, data)
        local name = Text.field(data.kind, 24)
        local ok, err, what = Places.reset(staff(src), name or '')
        if not ok then
            return false, err, err == 'not_found' and L('places.none_set_it_already_uses_the') or what
        end
        return true, nil, (L('places.place_removed_the_config_list_applies')):format(what)
    end)
end

return Places
