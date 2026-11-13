CrimsonBoot.define('shared.integrations', function() --- Crimson Hitman System — the other scripts this resource can work with,
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
---   without  what happens with no adapter, as the console line and the
---            panel say it: read from the language file when it is read
---            (`withoutKey`, integrations.without_<kind> in locales/en.lua)
---   needed   whether a feature that uses it is switched on (an adapter
---            missing for a feature that is off is only a Debug line)
---   required the resource cannot run without one (the framework)
Integrations.KINDS = {
    { kind = 'framework', key = 'Framework', side = 'server', required = true,
      withoutKey = 'integrations.without_framework' },
    { kind = 'inventory', key = 'Inventory', side = 'server',
      withoutKey = 'integrations.without_inventory',
      needed = function(c)
          local s = c.Sources or {}
          local on = function(t) return type(t) == 'table' and t.enabled == true end
          local org = type(c.Organisation) == 'table' and c.Organisation or {}
          local rp = type(c.Roleplay) == 'table' and c.Roleplay or {}
          local imp = type(c.Improvements) == 'table' and c.Improvements or {}
          return on(s.item) or on(s.weapon) or on(s.dirty) or (org.Enabled == true and org.Armory == true)
              -- Burner phones and proof items are inventory items too
              -- (docs/dev/adapters.md).
              or (type(rp.BurnerPhone) == 'table' and rp.BurnerPhone.Enabled == true)
              or (type(imp.ProofItems) == 'table' and imp.ProofItems.Enabled == true)
      end },
    { kind = 'target', key = 'Target', side = 'client',
      withoutKey = 'integrations.without_target',
      needed = function(c)
          return (type(c.StepMarkers) == 'table' and c.StepMarkers.Enabled == true)
              or (type(c.Organisation) == 'table' and c.Organisation.Enabled == true)
      end },
    { kind = 'dispatch', key = 'Dispatch', side = 'server',
      withoutKey = 'integrations.without_dispatch',
      needed = function(c)
          return type(c.Advisory) == 'table' and c.Advisory.Enabled == true and c.Advisory.UseDispatch ~= false
      end },
    { kind = 'ambulance', key = 'Ambulance', side = 'both',
      withoutKey = 'integrations.without_ambulance',
      needed = function() return true end },
    { kind = 'banking', key = 'Banking', side = 'server',
      withoutKey = 'integrations.without_banking',
      needed = function(c) return type(c.Organisation) == 'table' and c.Organisation.Enabled == true end },
    { kind = 'phone', key = 'Phone', side = 'both',
      withoutKey = 'integrations.without_phone',
      needed = function() return true end },
    { kind = 'keys', key = 'Keys', side = 'server',
      withoutKey = 'integrations.without_keys',
      needed = function(c)
          local org = type(c.Organisation) == 'table' and c.Organisation or {}
          return (type(c.Disposal) == 'table' and c.Disposal.Enabled == true)
              or (org.Enabled == true and org.Garage == true)
      end },
    { kind = 'garage', key = 'Garage', side = 'server',
      withoutKey = 'integrations.without_garage',
      needed = function(c)
          local org = type(c.Organisation) == 'table' and c.Organisation or {}
          return org.Enabled == true and org.Garage == true
      end },
    { kind = 'mugshot', key = 'Mugshot', side = 'client',
      withoutKey = 'integrations.without_mugshot',
      needed = function(c) return type(c.Mugshot) == 'table' and c.Mugshot.Enabled == true end },
    { kind = 'clothing', key = 'Clothing', side = 'client',
      withoutKey = 'integrations.without_clothing',
      needed = function(c) return type(c.Mugshot) == 'table' and c.Mugshot.Enabled == true end },
    { kind = 'progression', key = 'Progression', side = 'server',
      withoutKey = 'integrations.without_progression',
      needed = function(c)
          local r = type(c.Record) == 'table' and c.Record.Progression
          return type(r) == 'table' and r.Enabled == true
      end },
}

--- The words, looked up as they are read: shared/locale.lua is loaded on
--- both sides before this file (fxmanifest.lua). The game has none of the
--- server's words, and never reads these.
local function L(key)
    local Locale = rawget(_G, 'CrimsonLocale')
    if not Locale then
        local boot = rawget(_G, 'CrimsonBoot')
        Locale = boot and boot.requireShared and boot.requireShared('locale') or nil
    end
    return Locale and Locale.t(key) or key
end

--- A kind's `without`, in the language in force.
local SPEC = { __index = function(spec, field)
    if field == 'without' then return L(rawget(spec, 'withoutKey')) end
end }

local BY_KIND = {}
for i = 1, #Integrations.KINDS do
    setmetatable(Integrations.KINDS[i], SPEC)
    BY_KIND[Integrations.KINDS[i].kind] = Integrations.KINDS[i]
end
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

--- Whether `resource` is the resource behind one of a kind's adapters: an
--- onClientResourceStart/Stop for it means that kind came or went (a
--- restarted ox_target has forgotten every zone it was given).
---@param kind string
---@param resource string
---@return boolean
function Integrations.isResourceOf(kind, resource)
    local r = registry[kind]
    if not r or type(resource) ~= 'string' then return false end
    for i = 1, #r.order do
        if r.by[r.order[i]].resource == resource then return true end
    end
    return false
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

--- The scripts to name as not started for a kind with no adapter
--- answering: the one Config.Integrations names, when it names one, else
--- every adapter's not started. And one of the others that is started, if
--- any (the setting points past it).
---@param st table Integrations.status
---@return string[] names
---@return string|nil started an adapter's name whose script is started
---@return string|nil startedResource its script
function Integrations.notStarted(st)
    local names, started, startedResource = {}, nil, nil
    for i = 1, #st.detected do
        local d = st.detected[i]
        if st.choice == 'auto' or st.choice == d.name then
            names[#names + 1] = d.resource
        elseif d.up and not started then
            started, startedResource = d.name, d.resource
        end
    end
    return names, started, startedResource
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
        why = (L('integrations.names_no_adapter'))
            :format(st.key, tostring(st.choice), table.concat(st.names, ', '))
    elseif st.choice == 'none' then
        why = (L('integrations.is_none')):format(st.key)
    else
        local names = Integrations.notStarted(st)
        why = #names > 0 and (L('integrations.not_started')):format(table.concat(names, ' / '))
            or L('integrations.no_adapter_registered')
    end
    return (L('integrations.off_line')):format(st.kind, why, st.without)
end

CrimsonIntegrations = Integrations

return Integrations
end)
