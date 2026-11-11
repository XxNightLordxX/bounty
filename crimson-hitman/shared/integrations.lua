--- Crimson Hitman System — the other scripts this resource can work with,
--- one adapter per kind (docs/dev/adapters.md).
---
--- Loaded on both sides: the server through CrimsonBoot.requireShared, the
--- client from client_scripts as CrimsonIntegrations. Each adapter is a
--- small table registered here under its kind and name (server: listed in
--- server/adapters/list.lua; client: client/adapters/<kind>/<name>.lua).
--- Config.Integrations.<Kind> picks which one answers:
---
---   'auto'    the first registered adapter whose resource is started now,
---             in the order they were registered
---   '<name>'  that adapter only, while its resource is started
---   'none'    no adapter: the features that need one are off, or use what
---             this resource does without (the kind's `without` below)
---
--- Every read is made at the moment of use, so an adapter whose resource
--- starts or stops later is picked up or let go on the next call. Nothing
--- here calls another resource; the adapters do, and their callers keep
--- the pcall (or Bridge.call) they always had.

local Integrations = {}

--- The kinds, in the order Config.Integrations lists them.
---   key      the Config.Integrations key
---   side     where its adapters live: 'server', 'client' or 'both'
---   without  what happens with no adapter, as the console line says it
---   needed   whether a feature that uses it is switched on (an adapter
---            missing for a feature that is off is only a Debug line)
---   required the resource cannot run without one (the framework)
Integrations.KINDS = {
    { kind = 'framework', key = 'Framework', side = 'server', required = true,
      without = 'players, jobs and money cannot be read: the resource waits for it and does nothing' },
    { kind = 'inventory', key = 'Inventory', side = 'server',
      without = 'item, weapon and dirty-money rewards, burner phones and proof items are off; '
          .. 'cash and bank rewards work',
      needed = function(c)
          local s = c.Sources or {}
          local on = function(t) return type(t) == 'table' and t.enabled == true end
          return on(s.item) or on(s.weapon) or on(s.dirty)
      end },
    { kind = 'target', key = 'Target', side = 'client',
      without = 'step markers and organisation spots have no third-eye option; the map markers still show',
      needed = function(c)
          return (type(c.StepMarkers) == 'table' and c.StepMarkers.Enabled == true)
              or (type(c.Organisation) == 'table' and c.Organisation.Enabled == true)
      end },
    { kind = 'dispatch', key = 'Dispatch', side = 'server',
      without = 'nothing is filed in the police MDT; officers\' phones are still told',
      needed = function(c)
          return type(c.Advisory) == 'table' and c.Advisory.Enabled == true and c.Advisory.UseDispatch ~= false
      end },
    { kind = 'ambulance', key = 'Ambulance', side = 'both',
      without = 'death and last stand are read from the framework\'s player metadata and the game',
      needed = function() return true end },
    { kind = 'banking', key = 'Banking', side = 'server',
      without = 'the organisation\'s funds are kept in this resource\'s own ledger',
      needed = function(c) return type(c.Organisation) == 'table' and c.Organisation.Enabled == true end },
    { kind = 'phone', key = 'Phone', side = 'both',
      without = 'there is no phone app; notices fall back to on-screen notifications',
      needed = function() return true end },
    { kind = 'keys', key = 'Keys', side = 'server',
      without = 'the disposal vehicle is left unlocked, with no keys given',
      needed = function(c) return type(c.Disposal) == 'table' and c.Disposal.Enabled == true end },
    { kind = 'mugshot', key = 'Mugshot', side = 'client',
      without = 'target headshots are off',
      needed = function(c) return type(c.Mugshot) == 'table' and c.Mugshot.Enabled == true end },
    { kind = 'clothing', key = 'Clothing', side = 'client',
      without = 'a change of clothes does not refresh the target\'s headshot until the next one is due',
      needed = function(c) return type(c.Mugshot) == 'table' and c.Mugshot.Enabled == true end },
    { kind = 'progression', key = 'Progression', side = 'server',
      without = 'completions earn no trust in a wider criminal progression',
      needed = function(c)
          local r = type(c.Record) == 'table' and c.Record.Progression
          return type(r) == 'table' and r.Enabled == true
      end },
}

local BY_KIND = {}
for i = 1, #Integrations.KINDS do BY_KIND[Integrations.KINDS[i].kind] = Integrations.KINDS[i] end
Integrations.BY_KIND = BY_KIND

--- [kind] = { order = string[], by = { [name] = adapter } }
local registry = {}

--- Add an adapter. Registering a name again replaces it in place.
---@param kind string one of Integrations.KINDS
---@param name string what Config.Integrations.<Kind> names it by
---@param adapter table { resource?, detect?, label?, source?, ... the kind's functions }
---@return table adapter
function Integrations.register(kind, name, adapter)
    assert(BY_KIND[kind], 'unknown integration kind: ' .. tostring(kind))
    assert(type(name) == 'string' and name ~= '' and name ~= 'auto' and name ~= 'none',
        'an adapter needs a name other than auto or none')
    adapter = type(adapter) == 'table' and adapter or {}
    adapter.name = name
    adapter.kind = kind
    if adapter.resource == nil then adapter.resource = name end
    local r = registry[kind]
    if not r then
        r = { order = {}, by = {} }
        registry[kind] = r
    end
    if not r.by[name] then r.order[#r.order + 1] = name end
    r.by[name] = adapter
    return adapter
end

--- The names registered for a kind, in order.
---@param kind string
---@return string[]
function Integrations.names(kind)
    local r = registry[kind]
    local out = {}
    if r then for i = 1, #r.order do out[i] = r.order[i] end end
    return out
end

--- The registered adapter by name, or nil.
function Integrations.adapter(kind, name)
    local r = registry[kind]
    return r and r.by[name] or nil
end

--- What Config.Integrations says for a kind: 'auto' when it says nothing.
---@param kind string
---@return string
function Integrations.choice(kind)
    local spec = BY_KIND[kind]
    local cfg = type(Config) == 'table' and type(Config.Integrations) == 'table' and Config.Integrations or nil
    local value = spec and cfg and cfg[spec.key]
    if type(value) ~= 'string' or value == '' then return 'auto' end
    return value
end

--- Whether a choice is one this build can follow: auto, none, or a
--- registered name.
---@param kind string
---@param value any
---@return boolean
function Integrations.valid(kind, value)
    if value == 'auto' or value == 'none' then return true end
    return type(value) == 'string' and Integrations.adapter(kind, value) ~= nil
end

--- Whether an adapter's resource is there to answer now.
---@param adapter table
---@return boolean
function Integrations.up(adapter)
    if type(adapter.detect) == 'function' then
        local ok, yes = pcall(adapter.detect)
        return ok and yes == true
    end
    return type(adapter.resource) == 'string' and GetResourceState(adapter.resource) == 'started'
end

--- The adapter answering for a kind now, or nil (none chosen, none
--- started, or a name that is not registered). The framework is a
--- dependency of the manifest, so its adapter is never asked whether it is
--- started: its calls go where they always went.
---@param kind string
---@return table|nil
function Integrations.get(kind)
    local r = registry[kind]
    if not r then return nil end
    local want = Integrations.choice(kind)
    if want == 'none' then return nil end
    local spec = BY_KIND[kind]
    if want ~= 'auto' then
        local adapter = r.by[want]
        if adapter and (spec.required or Integrations.up(adapter)) then return adapter end
        return nil
    end
    for i = 1, #r.order do
        local adapter = r.by[r.order[i]]
        if spec.required or Integrations.up(adapter) then return adapter end
    end
    return nil
end

--- Whether a kind has an adapter answering now.
---@param kind string
---@return boolean
function Integrations.has(kind)
    return Integrations.get(kind) ~= nil
end

--- Every adapter that may answer for a kind now, in order: all of the
--- started ones on 'auto' (the ambulance asks each in turn), the one named,
--- or none.
---@param kind string
---@return table[]
function Integrations.candidates(kind)
    local r = registry[kind]
    local out = {}
    if not r then return out end
    local want = Integrations.choice(kind)
    if want == 'none' then return out end
    if want ~= 'auto' then
        local adapter = r.by[want]
        if adapter and Integrations.up(adapter) then out[1] = adapter end
        return out
    end
    for i = 1, #r.order do
        local adapter = r.by[r.order[i]]
        if Integrations.up(adapter) then out[#out + 1] = adapter end
    end
    return out
end

--- One kind as the diagnosis and the first-start setup show it.
---@param kind string
---@return table { kind, key, side, choice, valid, active, names, detected, without, needed }
function Integrations.status(kind)
    local spec = BY_KIND[kind]
    local active = Integrations.get(kind)
    local detected = {}
    for _, name in ipairs(Integrations.names(kind)) do
        local adapter = Integrations.adapter(kind, name)
        detected[#detected + 1] = { name = name, resource = adapter.resource, up = Integrations.up(adapter) }
    end
    local needed = true
    if type(spec.needed) == 'function' then
        local ok, yes = pcall(spec.needed, type(Config) == 'table' and Config or {})
        needed = ok and yes == true
    end
    local choice = Integrations.choice(kind)
    return {
        kind = kind, key = spec.key, side = spec.side, choice = choice,
        valid = Integrations.valid(kind, choice),
        active = active and active.name or nil,
        names = Integrations.names(kind), detected = detected,
        without = spec.without, needed = needed, required = spec.required == true,
    }
end

--- Every kind's status, in order.
---@return table[]
function Integrations.statusAll()
    local out = {}
    for i = 1, #Integrations.KINDS do out[i] = Integrations.status(Integrations.KINDS[i].kind) end
    return out
end

--- The one line said for a kind with no adapter answering, or nil when one
--- answers.
---@param st table Integrations.status
---@return string|nil
function Integrations.offLine(st)
    if st.active then return nil end
    local why
    if not st.valid then
        why = ('Config.Integrations.%s = \'%s\' names no adapter this build has (%s)')
            :format(st.key, tostring(st.choice), table.concat(st.names, ', '))
    elseif st.choice == 'none' then
        why = ('Config.Integrations.%s is \'none\''):format(st.key)
    else
        local names = {}
        for i = 1, #st.detected do names[i] = st.detected[i].resource end
        why = (#names > 0 and (table.concat(names, ' / ') .. ' not started') or 'no adapter registered')
    end
    return ('integration %s off (%s): %s'):format(st.kind, why, st.without)
end

CrimsonIntegrations = Integrations

return Integrations
