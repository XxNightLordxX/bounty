--- FiveM native + external resource stubs.
--- Installs globals so the real server modules load unmodified.

local Env = require('crimson-bounty.tests.harness.env')

local Natives = { env = Env }

--------------------------------------------------------------------------
-- Core runtime
--------------------------------------------------------------------------

function Natives.install()
    _G.GetGameTimer = function() return Env.gameTimer end
    _G.os_time_real = os.time
    _G.CreateThread = function(fn) table.insert(Env.threads, fn) end
    _G.SetTimeout = function(ms, fn)
        table.insert(Env.timers, { at = Env.gameTimer + ms, fn = fn })
    end
    _G.Wait = function() end
    _G.GetCurrentResourceName = function() return 'crimson-bounty' end
    _G.GetResourceState = function(name) return Natives.resourceStates[name] or 'missing' end

    _G.RegisterNetEvent = function(name, handler)
        Env.events[name] = handler
    end
    _G.AddEventHandler = function(name, handler)
        Env.events['local:' .. name] = handler
        Env.handlers[name] = handler
    end
    _G.NetworkGetEntityFromNetworkId = function(netId) return netId end
    _G.NetworkGetEntityOwner = function(entity) return entity - 1000 end
    _G.TriggerClientEvent = function(name, target, ...)
        table.insert(Env.clientEvents, { name = name, target = target, args = { ... } })
        -- Phone notifications reach the player as a client event, since
        if name == 'chat:addMessage' then
            local payload = ...
            local args = payload and payload.args or {}
            table.insert(Env.chat, { target = target, text = tostring(args[2] or '') })
        end
        -- lb-phone's SendNotification export is client-side only.
        if name == 'crimson-bounty:notify' then
            local payload = ...
            table.insert(Natives.calls.notifications, payload)
        end
    end
    _G.TriggerEvent = function(name, ...)
        local h = Env.events['local:' .. name]
        if h then h(...) end
    end

    -- Staff commands. Registered handlers are kept so a test can run one
    -- exactly as a console or a player would, and the ACE answer is a
    -- fixture rather than always-true: a command that is only ever tested
    -- with permission is a command whose gate is untested.
    _G.RegisterCommand = function(name, handler)
        Env.commands[name] = handler
    end
    _G.IsPlayerAceAllowed = function(src, ace)
        local granted = Env.aces[tonumber(src)]
        return (granted and granted[ace]) == true
    end

    _G.GetPlayerIdentifiers = function(src)
        local p = Env.players[tonumber(src)]
        if not p then return {} end
        return { p.PlayerData.license, 'discord:' .. p.PlayerData.citizenid, 'ip:127.0.0.1' }
    end
    _G.GetPlayerName = function(src)
        local p = Env.players[tonumber(src)]
        return p and (p.PlayerData.charinfo.firstname .. ' ' .. p.PlayerData.charinfo.lastname) or 'Unknown'
    end
    _G.GetPlayers = function()
        local out = {}
        for src in pairs(Env.players) do out[#out + 1] = tostring(src) end
        table.sort(out)
        return out
    end
    _G.GetPlayerPed = function(src) return 1000 + tonumber(src) end
    _G.GetEntityCoords = function(ped)
        local src = ped - 1000
        local p = Env.players[src]
        if not p then return { x = 0.0, y = 0.0, z = 0.0 } end
        return p._coords
    end
    _G.GetEntityHealth = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._health or 0
    end
    _G.GetPedSourceOfDeath = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._killerPed or 0
    end
    _G.IsPedAPlayer = function(ped) return Env.players[ped - 1000] ~= nil end
    _G.NetworkGetPlayerIndexFromPed = function(ped) return ped - 1000 end
    _G.GetPlayerServerId = function(index) return index end
    _G.GetPedArmour = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._armour or 0
    end
    _G.GetVehiclePedIsIn = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._vehicle or 0
    end
    _G.GetPedInVehicleSeat = function(veh, seat)
        for src, p in pairs(Env.players) do
            if p._vehicle == veh and p._seat == seat then return 1000 + src end
        end
        return 0
    end
    _G.DoesEntityExist = function(entity) return entity and entity ~= 0 end

    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        table.insert(Env.console, table.concat(parts, ' '))
    end

    -- Virtual resource filesystem for the json backend.
    Natives.files = {}
    _G.LoadResourceFile = function(_, file) return Natives.files[file] end
    _G.SaveResourceFile = function(_, file, data)
        -- A seam for asserting on which files a write actually touches,
        -- which is the whole claim the sharded store makes.
        if Natives.saveFile then Natives.saveFile(file, data) end
        Natives.files[file] = data
        return true
    end

    Natives.calls.http = {}
    _G.PerformHttpRequest = function(url, cb, method, body, headers)
        table.insert(Natives.calls.http, { url = url, method = method, body = body })
        if cb then cb(204, '', {}) end
    end

    _G.json = Natives.json
    _G.exports = Natives.exportsProxy()
    _G.MySQL = Natives.mysql
end

--------------------------------------------------------------------------
-- Minimal JSON (round-trips the shapes this resource stores)
--------------------------------------------------------------------------

Natives.json = {}

local function encodeValue(v, out)
    local t = type(v)
    if t == 'nil' then out[#out + 1] = 'null'
    elseif t == 'boolean' or t == 'number' then out[#out + 1] = tostring(v)
    elseif t == 'string' then
        out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    elseif t == 'table' then
        local isArray, n = true, 0
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= 'number' then isArray = false end
        end
        if isArray and n == #v then
            out[#out + 1] = '['
            for i = 1, #v do
                if i > 1 then out[#out + 1] = ',' end
                encodeValue(v[i], out)
            end
            out[#out + 1] = ']'
        else
            out[#out + 1] = '{'
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for i = 1, #keys do
                if i > 1 then out[#out + 1] = ',' end
                encodeValue(keys[i], out)
                out[#out + 1] = ':'
                encodeValue(v[keys[i]] ~= nil and v[keys[i]] or v[tonumber(keys[i])], out)
            end
            out[#out + 1] = '}'
        end
    end
end

function Natives.json.encode(value)
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end

--- Decoder sufficient for our own encoder's output.
function Natives.json.decode(str)
    local pos = 1
    local function skip()
        while pos <= #str and str:sub(pos, pos):match('%s') do pos = pos + 1 end
    end
    local parseValue
    local function parseString()
        if str:sub(pos, pos) ~= '"' then error('malformed json: expected a string') end
        pos = pos + 1
        local buf = {}
        while true do
            if pos > #str then error('malformed json: unterminated string') end
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1 break end
            if c == '\\' then
                local nxt = str:sub(pos + 1, pos + 1)
                if nxt == 'u' then
                    buf[#buf + 1] = string.char(tonumber(str:sub(pos + 2, pos + 5), 16) % 256)
                    pos = pos + 6
                else
                    buf[#buf + 1] = nxt == 'n' and '\n' or nxt
                    pos = pos + 2
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end
    parseValue = function()
        skip()
        if pos > #str then error('malformed json: unexpected end of input') end
        local c = str:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            skip()
            if str:sub(pos, pos) == '}' then pos = pos + 1 return obj end
            while true do
                skip()
                local k = parseString()
                skip()
                if str:sub(pos, pos) ~= ':' then error('malformed json: expected a colon') end
                pos = pos + 1
                obj[k] = parseValue()
                skip()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == '}' then break end
                if d ~= ',' then error('malformed json: expected , or }') end
            end
            return obj
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skip()
            if str:sub(pos, pos) == ']' then pos = pos + 1 return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skip()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == ']' then break end
                if d ~= ',' then error('malformed json: expected , or ]') end
            end
            return arr
        elseif c == '"' then
            return parseString()
        elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
        elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
        elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
        else
            local numStr = str:match('^%-?%d+%.?%d*', pos)
            if not numStr or numStr == '' then error('malformed json: unexpected character') end
            pos = pos + #numStr
            return tonumber(numStr)
        end
    end
    return parseValue()
end

--------------------------------------------------------------------------
-- Resource states and exports
--------------------------------------------------------------------------

--- What a fully-equipped server looks like. A suite that changes one of
--- these must be able to hand it back, so the defaults are kept separately
--- and Natives.resetResourceStates puts them all back — a test that leaves
--- a resource missing silently changes the meaning of every later test.
local DEFAULT_RESOURCE_STATES = {
    ['qbx_core'] = 'started',
    ['ox_inventory'] = 'started',
    ['lb-phone'] = 'started',
    ['sc-ambulance'] = 'started',
    ['sc-dispatch'] = 'started',
    ['MugShotBase64'] = 'started',
    ['sc-blackmarket'] = 'started',
}

--- lb-phone's configuration, as GetConfig returns it. The shape here is the
--- real one: an Upload table whose values are URLs, sometimes nested.
Natives.phoneConfig = {
    Upload = {
        url = 'https://cdn.fivemanage.com/upload',
        images = { url = 'https://api.fivemanage.com/api/image' },
    },
}

--- ox_inventory matches a removal against slot metadata: nil means "any
--- slot of this name", and a table means the slot's metadata must equal it.
--- Two items with the same name and different metadata are different items —
--- a repair kit at 11% durability is not a fresh one, and a backpack holding
--- goods is not an empty one.
function Natives.metadataMatches(slotMeta, wanted)
    if wanted == nil then return true end
    if type(wanted) ~= 'table' then return false end

    local function same(a, b)
        if a == b then return true end
        if type(a) ~= 'table' or type(b) ~= 'table' then return false end
        for k, v in pairs(a) do if not same(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end

    -- An empty wanted table is how this resource records "no metadata", so
    -- it matches a slot that has none.
    if next(wanted) == nil then
        return slotMeta == nil or next(slotMeta) == nil
    end
    return same(slotMeta or {}, wanted)
end

Natives.resourceStates = {}

--- Restore the default set, in place. Assigning a fresh table would leave
--- anything holding the old one looking at stale state.
function Natives.resetResourceStates()
    for name in pairs(Natives.resourceStates) do Natives.resourceStates[name] = nil end
    for name, state in pairs(DEFAULT_RESOURCE_STATES) do Natives.resourceStates[name] = state end
end

Natives.resetResourceStates()

Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }

function Natives.exportsProxy()
    local resources = {}

    resources['qbx_core'] = {
        GetPlayer = function(_, src) return Env.players[tonumber(src)] end,
        GetPlayerByCitizenId = function(_, cid)
            local src = Env.byCitizen[cid]
            return src and Env.players[src] or nil
        end,
    }

    resources['ox_inventory'] = {
        GetItem = function(_, src, name, metadata, returnsCount)
            local p = Env.players[tonumber(src)]
            if not p then return returnsCount and 0 or nil end
            local count = 0
            for _, slot in ipairs(p._inventory) do
                if slot.name == name then count = count + slot.count end
            end
            return returnsCount and count or { count = count }
        end,
        --- Removes only from slots whose metadata matches, as ox_inventory
        --- does. Ignoring metadata here made a worn item and a pristine one
        --- indistinguishable, so a test could not see an escrow path that
        --- takes one and hands back the other.
        RemoveItem = function(_, src, name, count, metadata)
            local p = Env.players[tonumber(src)]
            if not p then return false end
            local remaining = count
            for _, slot in ipairs(p._inventory) do
                if slot.name == name and remaining > 0
                    and Natives.metadataMatches(slot.metadata, metadata) then
                    local take = math.min(slot.count, remaining)
                    slot.count = slot.count - take
                    remaining = remaining - take
                end
            end
            table.insert(Natives.calls.inventory,
                { op = 'remove', src = src, name = name, count = count, metadata = metadata })
            return remaining == 0
        end,
        AddItem = function(_, src, name, count, metadata)
            local p = Env.players[tonumber(src)]
            if not p then return false end
            if p._inventoryFull then return false end
            table.insert(p._inventory, { name = name, count = count, metadata = metadata })
            table.insert(Natives.calls.inventory, { op = 'add', src = src, name = name, count = count })
            return true
        end,
        CanCarryItem = function(_, src, name, count)
            local p = Env.players[tonumber(src)]
            return p and not p._inventoryFull or false
        end,
        GetInventoryItems = function(_, src)
            -- Builds without this export are why App.readInventory has a
            -- fallback chain. A test that cannot make this fail cannot
            -- exercise it.
            if Natives.noGetInventoryItems then
                error('ox_inventory: no such export GetInventoryItems')
            end
            local p = Env.players[tonumber(src)]
            if not p then return {} end
            local out = {}
            for _, slot in ipairs(p._inventory) do
                -- Reported exactly as the fixture wrote it. Filling in a
                -- slot number the fixture did not set would be the harness
                -- inventing a field, and a slot is what identifies a weapon
                -- on submit — the one thing a test must not fabricate.
                out[#out + 1] = {
                    name = slot.name, count = slot.count, slot = slot.slot,
                    label = slot.label, metadata = slot.metadata,
                }
            end
            return out
        end,
        --- The older shape: one call returning the whole inventory.
        GetInventory = function(_, src)
            if Natives.noGetInventory then
                error('ox_inventory: no such export GetInventory')
            end
            local p = Env.players[tonumber(src)]
            if not p then return nil end
            local items = {}
            for _, slot in ipairs(p._inventory) do
                items[#items + 1] = {
                    name = slot.name, count = slot.count, slot = slot.slot,
                    label = slot.label, metadata = slot.metadata,
                }
            end
            return { items = items }
        end,
        Search = function(_, src, query, name)
            local p = Env.players[tonumber(src)]
            if not p then return {} end
            local out = {}
            for _, slot in ipairs(p._inventory) do
                if slot.name == name then out[#out + 1] = slot end
            end
            return out
        end,
    }

    resources['lb-phone'] = {
        SendNotification = function(_, data)
            table.insert(Natives.calls.notifications, data)
            return true
        end,
        ContainsBlacklistedWord = function(_, src, text)
            return tostring(text):lower():find('slur') ~= nil
        end,
        GetEquippedPhoneNumber = function(_, src) return '555-' .. tostring(src) end,
        AddCustomApp = function() return true end,
        -- The photo host allowlist is derived from this. Without a stub the
        -- pcall around it always failed, so the half of the allowlist that
        -- comes from the phone was never once exercised by a test.
        GetConfig = function() return Natives.phoneConfig end,
        -- Only present when a test says this build has it: lb-phone ships
        -- its server code escrowed, so whether a call-placing export exists
        -- is exactly what cannot be assumed.
        StartCall = function(...)
            if not Natives.callExport then error('no such export') end
            return Natives.callExport(...)
        end,
    }

    resources['sc-ambulance'] = {
        IsDead = function(_, src)
            local p = Env.players[tonumber(src)]
            return p and p.PlayerData.metadata.isdead or false
        end,
        IsLaststand = function(_, src)
            local p = Env.players[tonumber(src)]
            return p and p.PlayerData.metadata.inlaststand or false
        end,
    }

    resources['sc-dispatch'] = {
        AddNotification = function(_, data)
            table.insert(Natives.calls.dispatch, data)
            return 1
        end,
    }

    return setmetatable({}, {
        __index = function(_, resource)
            return resources[resource] or setmetatable({}, {
                __index = function() return function() return nil end end,
            })
        end,
    })
end

--------------------------------------------------------------------------
-- MySQL stub — parameterized only. A query containing an interpolated
-- literal where a placeholder belongs fails the test suite loudly.
--------------------------------------------------------------------------

Natives.mysql = {
    queries = {},
}

local function recordQuery(sql, params)
    table.insert(Natives.mysql.queries, { sql = sql, params = params })
end

Natives.mysql.query = { await = function(sql, params) recordQuery(sql, params) return {} end }
Natives.mysql.insert = { await = function(sql, params) recordQuery(sql, params) return 1 end }
Natives.mysql.update = { await = function(sql, params) recordQuery(sql, params) return 1 end }
Natives.mysql.scalar = { await = function(sql, params) recordQuery(sql, params) return nil end }
Natives.mysql.prepare = { await = function(sql, params) recordQuery(sql, params) return {} end }
Natives.mysql.transaction = { await = function(queries)
    for _, q in ipairs(queries) do recordQuery(q.query or q[1], q.values or q[2]) end
    return true
end }

return Natives
