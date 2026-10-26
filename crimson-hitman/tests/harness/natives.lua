--- FiveM native + external resource stubs.
--- Installs globals so the real server modules load unmodified.

local Env = require('crimson-hitman.tests.harness.env')

local Natives = { env = Env }

--------------------------------------------------------------------------
-- Core runtime
--------------------------------------------------------------------------

function Natives.install()
    _G.GetGameTimer = function() return Env.gameTimer end
    _G.os_time_real = os.time
    _G.CreateThread = function(fn) table.insert(Env.threads, fn) end
    -- Runs at once, up to its first wait, then the caller carries on;
    -- nothing here waits, so it runs to the end. What Notify sends a
    -- notification in, so a settlement does not yield for the database
    -- lb-phone writes it to.
    _G.Citizen = { CreateThreadNow = function(fn) fn() end }
    _G.SetTimeout = function(ms, fn)
        -- Numbered as set, so timers due together run in the order they
        -- were set, as the engine runs them.
        Env.timerSeq = (Env.timerSeq or 0) + 1
        table.insert(Env.timers, { at = Env.gameTimer + ms, fn = fn, seq = Env.timerSeq })
    end
    _G.Wait = function() end
    _G.GetCurrentResourceName = function() return 'crimson-hitman' end

    -- Present in production, so the harness has to have it: the client reads
    -- the manifest version through this to stamp the phone page's URL, and a
    -- harness missing it made registration fail in a way no live server
    -- would. A harness that lacks what production has tests a different
    -- program.
    --
    -- Answers from the real manifest rather than a made-up string, so a
    -- version that goes missing from it is a test failure rather than
    -- something the harness papers over.
    _G.GetResourceMetadata = function(_, key, _)
        if key ~= 'version' then return nil end
        local fh = io.open('crimson-hitman/fxmanifest.lua', 'r')
        if not fh then return nil end
        local text = fh:read('*a')
        fh:close()
        return text:match("version%s+'([^']+)'")
    end
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
        if name == 'chat:addMessage' then
            local payload = ...
            local args = payload and payload.args or {}
            table.insert(Env.chat, { target = target, text = tostring(args[2] or ''), via = 'chat' })
        end
        -- A command's answer to a player, printed in their F8 console line
        -- by line (Bridges.runCommand). Kept with the chat lines, where the
        -- specs read what a command said back, marked so one can tell them
        -- apart: a staff command's answer never goes to chat.
        if name == 'crimson-hitman:commandOutput' then
            local lines = ...
            for _, line in ipairs(type(lines) == 'table' and lines or {}) do
                table.insert(Env.chat, { target = target, text = tostring(line), via = 'f8' })
            end
        end
        -- The popup the player's client raises, where lb-phone's server
        -- export could not take the notification (Notify's raise).
        if name == 'crimson-hitman:notify' then
            local payload = ...
            table.insert(Natives.calls.notifications, payload)
        end
    end
    _G.TriggerEvent = function(name, ...)
        local h = Env.events['local:' .. name]
        if h then h(...) end
    end
    -- The same event, sent in pieces at `bps` bytes a second. Recorded with
    -- the others, marked, so a test can tell a photo sent latent from one
    -- pushed through an ordinary event, which is the whole difference.
    _G.TriggerLatentClientEvent = function(name, target, bps, ...)
        table.insert(Env.clientEvents,
            { name = name, target = target, args = { ... }, latent = true, bps = bps })
    end

    -- Staff commands. Registered handlers are kept so a test can run one
    -- exactly as a console or a player would, and the ACE answer is a
    -- fixture rather than always-true: a command that is only ever tested
    -- with permission is a command whose gate is untested.
    _G.RegisterCommand = function(name, handler)
        Env.commands[name] = handler
    end
    -- Answers like FXServer does for a BOOL native without the fxv2 path:
    -- the integer 1 when granted, false otherwise. Never a Lua true, so a
    -- caller that compares with `== true` is refused here as it is in game.
    _G.IsPlayerAceAllowed = function(src, ace)
        local granted = Env.aces[tonumber(src)]
        return (granted and granted[ace] == true) and 1 or false
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
    -- What the nearby list reads about who is standing there: which routing
    -- bucket they are in (0, the shared world, unless a test puts them in
    -- an instance) and whether their ped is visible (noclip and spectating
    -- staff are not). A fixture sets _bucket and _invisible on the player.
    -- Not what they are wearing: GetPedDrawableVariation is a client
    -- native, nil on FXServer, and a stub of it here is how a nearby list
    -- that was always empty in game passed. Their client says whether they
    -- are masked (crimson-hitman:maskState).
    _G.GetPlayerRoutingBucket = function(src)
        local p = Env.players[tonumber(src)]
        return p and (p._bucket or 0) or 0
    end
    -- BOOL natives answer here as FXServer answers them without the fxv2
    -- path: the integer 1 for true, false for false, never a Lua true. A
    -- stub that answered true let a caller comparing with `== true` pass
    -- here and fail in game (IsPlayerAceAllowed, above, refused every staff
    -- command that way).
    _G.IsEntityVisible = function(ped)
        local p = Env.players[ped - 1000]
        return (p ~= nil and not p._invisible) and 1 or false
    end
    _G.GetEntityHealth = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._health or 0
    end
    -- Who the victim's game says last damaged them. nil — this server cannot
    -- say — unless a test names somebody, as it does where attribution
    -- between shooters is the point.
    _G.GetPedSourceOfDamage = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._damageSource or nil
    end
    _G.GetPedSourceOfDeath = function(ped)
        local p = Env.players[ped - 1000]
        return p and p._killerPed or 0
    end
    _G.IsPedAPlayer = function(ped) return Env.players[ped - 1000] ~= nil and 1 or false end
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
    -- What another resource's handler did to the event now being handled.
    _G.WasEventCanceled = function() return Env.eventCanceled == true and 1 or false end
    _G.GetPedInVehicleSeat = function(veh, seat)
        for src, p in pairs(Env.players) do
            if p._vehicle == veh and p._seat == seat then return 1000 + src end
        end
        return 0
    end
    _G.DoesEntityExist = function(entity) return (entity and entity ~= 0) and 1 or false end

    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        table.insert(Env.console, table.concat(parts, ' '))
    end

    -- Virtual resource filesystem for the json backend.
    Natives.files = {}
    _G.LoadResourceFile = function(_, file) return Natives.files[file] end

    -- The server's resource KVP store, which lives in FXServer's own
    -- database rather than in the resource folder. Kept per virtual disk:
    -- a test that starts a fresh disk (Natives.files = {}) is a fresh
    -- server, KVP and all, and one that restarts on the same disk keeps
    -- both. A test of the folder being replaced keeps the KVP and changes
    -- the disk: Natives.kvp[newFiles] = Natives.kvp[oldFiles].
    Natives.kvp = setmetatable({}, { __mode = 'k' })
    local function kvp()
        local store = Natives.kvp[Natives.files]
        if not store then
            store = {}
            Natives.kvp[Natives.files] = store
        end
        return store
    end
    _G.GetResourceKvpInt = function(key) return tonumber(kvp()[key]) or 0 end
    _G.SetResourceKvpInt = function(key, value) kvp()[key] = math.floor(tonumber(value) or 0) end
    _G.DeleteResourceKvp = function(key) kvp()[key] = nil end

    -- Env.reset is a fresh server, which is a fresh disk: the boots that
    -- call it model one, and a store another suite left in the files
    -- would otherwise be found by the start-up check for data held by
    -- another storage mode.
    local reset = Env.reset
    Env.reset = function(...)
        Natives.files = {}
        Natives.dirs = {}
        return reset(...)
    end
    _G.SaveResourceFile = function(_, file, data, length)
        -- A seam for asserting on which files a write actually touches,
        -- which is the whole claim the sharded store makes.
        if Natives.saveFile then Natives.saveFile(file, data) end
        -- A write into a directory that does not exist goes nowhere and
        -- says nothing, which is what FiveM does rather than raising. A BOOL
        -- native: 1 when written, false when not.
        --
        -- A file a test refuses is refused under the name the json store
        -- writes it through as well (<file>.new, renamed over <file>): what
        -- the test models is the store unable to write that file, and the
        -- copy is how it writes it.
        if Natives.blocked and (Natives.blocked[file]
            or (type(file) == 'string' and Natives.blocked[(file:gsub('%.new$', ''))])) then
            return false
        end
        -- The length, as FiveM reads it: -1 (or 0) is "up to the first NUL
        -- byte", which is right for JSON and cuts a picture short at its
        -- fifth byte. Ignoring it here let a photo written with -1 pass.
        if type(data) == 'string' then
            if not length or length <= 0 then
                local nul = data:find('\0', 1, true)
                if nul then data = data:sub(1, nul - 1) end
            else
                data = data:sub(1, length)
            end
        end
        Natives.files[file] = data
        return 1
    end

    -- The resource's own folder on disk, and the few things the server's
    -- Lua does with it directly: os.remove, os.createdir and io.readdir,
    -- which FiveM resolves to the resource when the path is inside it.
    -- Answered from the same virtual files as SaveResourceFile, so a file
    -- written there and removed here is gone from both. A path outside the
    -- resource is refused, as FiveM refuses one without a filesystem
    -- permission: no test has any business deleting a real file.
    _G.GetResourcePath = function() return Natives.RESOURCE_ROOT end
    local function inResource(path)
        local root = Natives.RESOURCE_ROOT .. '/'
        if type(path) ~= 'string' or path:sub(1, #root) ~= root then return nil end
        return path:sub(#root + 1)
    end
    os.remove = function(path)
        local file = inResource(path)
        if not file then return nil, tostring(path) .. ': Permission denied', 13 end
        Natives.calls.removed = Natives.calls.removed or {}
        table.insert(Natives.calls.removed, file)
        if Natives.files[file] == nil then return nil, tostring(path) .. ': Permission denied', 13 end
        Natives.files[file] = nil
        return true
    end
    -- A file moved to another name inside the resource. Refused, as the
    -- operating system refuses it, where there is no such file or the
    -- folder it is moving into does not exist: one os.createdir made, or
    -- one some file is already in. Natives.renameRefused models a server
    -- whose rename fails all the same. Natives.renameKeeps models Windows,
    -- whose rename refuses a name another file already has rather than
    -- replacing it, as Linux does.
    os.rename = function(from, to)
        local source, target = inResource(from), inResource(to)
        if not source or not target or Natives.renameRefused
            or Natives.files[source] == nil
            or (Natives.renameKeeps and Natives.files[target] ~= nil) then
            return nil, tostring(from) .. ' -> ' .. tostring(to) .. ': Permission denied', 13
        end
        local folder = target:match('^(.*)/[^/]+$') or ''
        local exists = Natives.dirs[folder] == true
        for file in pairs(Natives.files) do
            if not exists and file:match('^(.*)/[^/]+$') == folder then exists = true end
        end
        if not exists then
            return nil, tostring(from) .. ' -> ' .. tostring(to) .. ': Permission denied', 13
        end
        Natives.calls.renamed = Natives.calls.renamed or {}
        table.insert(Natives.calls.renamed, { from = source, to = target })
        Natives.files[target], Natives.files[source] = Natives.files[source], nil
        return true
    end
    os.createdir = function(path)
        local dir = inResource(path)
        if not dir then return nil, tostring(path) .. ': Failed to create directory', 1 end
        dir = dir:gsub('/+$', '')
        if Natives.dirs[dir] then return nil, path .. ': Directory already exists.', 1 end
        Natives.dirs[dir] = true
        return true
    end
    -- What FiveM hands back: an object whose lines() walks the names in
    -- the folder, sorted here so a test reads them in a fixed order.
    io.readdir = function(path)
        local dir = inResource(path)
        if not dir then return nil, tostring(path) end
        dir = dir:gsub('/+$', '') .. '/'
        local names = {}
        for file in pairs(Natives.files) do
            if file:sub(1, #dir) == dir and not file:sub(#dir + 1):find('/', 1, true) then
                names[#names + 1] = file:sub(#dir + 1)
            end
        end
        table.sort(names)
        return {
            lines = function()
                local i = 0
                return function()
                    i = i + 1
                    return names[i]
                end
            end,
            close = function() return true end,
        }
    end
    -- And io.open, which the json store's audit log uses to add to a file
    -- in that folder: refused, as it was before the folder had a path
    -- here, so the store writes the whole file instead. A test of the
    -- append puts its own in place (store_write_spec).
    local realOpen = io.open
    io.open = function(path, mode)
        if inResource(path) then return nil, tostring(path) .. ': not in the harness' end
        return realOpen(path, mode)
    end

    -- Server convars, as server.cfg's `set` lines leave them. Unset answers
    -- the default, as FiveM does; a test names one in Natives.convars.
    _G.GetConvar = function(name, default)
        local value = Natives.convars[name]
        if value == nil then return default end
        return value
    end

    -- The resource's one HTTP handler, kept so a test can send it a request
    -- the way FXServer does: a table with method and path, and a response
    -- that records what was written (Natives.httpRequest).
    _G.SetHttpHandler = function(handler) Natives.httpHandler = handler end

    -- bcrypt as FXServer's GetPasswordHash makes it: '$2a$11$', a 22
    -- character salt drawn at random from bcrypt's own alphabet (which has
    -- '.' and '/' in it), and 31 characters of hash. Different every call,
    -- as the real salt is. A test takes it away to model a build without it.
    local BCRYPT = './ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    _G.GetPasswordHash = function(password)
        Natives.calls.passwordHashes = (Natives.calls.passwordHashes or 0) + 1
        local out = {}
        for i = 1, 53 do
            local k = math.random(1, #BCRYPT)
            out[i] = BCRYPT:sub(k, k)
        end
        return '$2a$11$' .. table.concat(out)
    end

    Natives.calls.http = {}
    -- Answered at once, 204, unless a test says what is at the other end
    -- (Natives.httpAnswer(url, method) -> status, body, headers, error).
    _G.PerformHttpRequest = function(url, cb, method, body, headers)
        -- A stack resets Natives.calls without this list in it.
        Natives.calls.http = Natives.calls.http or {}
        table.insert(Natives.calls.http, { url = url, method = method, body = body })
        if not cb then return end
        if Natives.httpAnswer then return cb(Natives.httpAnswer(url, method, body, headers)) end
        cb(204, '', {})
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
                -- Not `a ~= nil and a or b`: a false under the key took the
                -- `or`, and a switch turned off was written as null, which no
                -- real encoder does.
                local value = v[keys[i]]
                if value == nil then value = v[tonumber(keys[i])] end
                encodeValue(value, out)
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

--- lb-phone's configuration, as GetConfig returns it: the media allowlist
--- keys it actually has (config/config.lua in lbphone/files), with its
--- shipped values. It once stood in an Upload table of URLs lb-phone does
--- not have, which is how a stock install refusing every kill photo passed
--- here.
Natives.phoneConfig = {
    UploadMethod = { Video = 'Fivemanage', Image = 'Fivemanage', Audio = 'Fivemanage' },
    UploadWhitelistedHostnames = { 'r2.qbox.re' },
    UploadWhitelistedDomains = { 'fivemanage.com', 'fmfile.com', 'amazonaws.com' },
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

--- Files a write must not land in, so a missing directory can be modelled.
Natives.blocked = {}

--- Where the resource lives on the fake disk, and the folders os.createdir
--- has made in it.
Natives.RESOURCE_ROOT = '/srv/resources/crimson-hitman'
Natives.dirs = {}

--- Send the resource's HTTP handler one request, as FXServer would, and
--- hand back what it answered: { status, headers, body, sent }.
---@param method string
---@param path string the part after /crimson-hitman, starting with '/'
function Natives.httpRequest(method, path)
    local answer = { sent = false }
    local res = {
        writeHead = function(status, headers)
            answer.status, answer.headers = status, headers or {}
        end,
        write = function(data) answer.body = (answer.body or '') .. tostring(data) end,
        send = function(data)
            if data ~= nil then answer.body = (answer.body or '') .. tostring(data) end
            answer.sent = true
        end,
    }
    if not Natives.httpHandler then return nil end
    Natives.httpHandler({ method = method, path = path, headers = {}, address = '127.0.0.1' }, res)
    return answer
end

--- Server convars by name. Empty, as a server.cfg that sets none leaves
--- them; cleared in place for every stack, like the resource states.
Natives.convars = {}

function Natives.resetConvars()
    for name in pairs(Natives.convars) do Natives.convars[name] = nil end
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

--- Whether a recorded client event is a phone notification reaching its
--- target: saved through lb-phone's server export, or the popup the
--- player's client raises where that could not be done. args[1] carries
--- the title and content either way.
function Natives.isNotice(event)
    return event.name == 'crimson-hitman:notify' or event.name == 'lb-phone:SendNotification'
end

function Natives.exportsProxy()
    local resources = {}

    resources['qbx_core'] = {
        GetPlayer = function(_, src) return Env.players[tonumber(src)] end,
        GetPlayerByCitizenId = function(_, cid)
            local src = Env.byCitizen[cid]
            return src and Env.players[src] or nil
        end,
        --- One field of a loaded character's metadata, by server id or
        --- citizen id as qbx_core's resolvePlayer takes either; nil when
        --- nobody is loaded there. Natives.noGetMetadata is a qbx_core
        --- build without the export.
        GetMetadata = function(_, identifier, key)
            if Natives.noGetMetadata then
                error('No such export GetMetadata in resource qbx_core', 0)
            end
            local src = type(identifier) == 'string' and Env.byCitizen[identifier]
                or tonumber(identifier)
            local p = src and Env.players[src]
            local meta = p and p.PlayerData and p.PlayerData.metadata
            return meta and meta[key]
        end,
        GetJob = function(_, name)
            Natives.calls.getJob = (Natives.calls.getJob or 0) + 1
            return Env.jobDefinitions and Env.jobDefinitions[name] or nil
        end,
        --- qbx_core's Save: the player's row written to the database now.
        --- Recorded with the balances it would write, so a test can tell
        --- what a crash right after it would have kept.
        Save = function(_, src)
            if Natives.saveThrows then error('qbx_core: database went away') end
            local p = Env.players[tonumber(src)]
            if not p then error('QBX.PLAYER.SAVE - PLAYERDATA IS EMPTY!') end
            Natives.calls.saves = Natives.calls.saves or {}
            table.insert(Natives.calls.saves, { source = tonumber(src),
                cash = p.PlayerData.money.cash, bank = p.PlayerData.money.bank })
        end,
    }

    --- The optional headshot renderer. Optional to the resource, but a test
    --- of the client half needs one that behaves: it is what turns a ped
    --- into the base64 image the server bounds and caches.
    resources['MugShotBase64'] = {
        GetMugShotBase64 = function(_, ped, transparent)
            if Natives.mugshotThrows then error('MugShotBase64: render failed') end
            if Natives.mugshotReturns ~= nil then return Natives.mugshotReturns end
            Natives.calls.mugshots = Natives.calls.mugshots or {}
            table.insert(Natives.calls.mugshots,
                { ped = ped, transparent = transparent })
            return 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='
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

            -- Keyed by SLOT NUMBER, which is what ox_inventory returns: this
            -- export hands back the inventory's own `items` table, and that
            -- is a sparse map rather than a list. Returning a dense array
            -- here let the resource assume an array it never gets on the
            -- primary read path.
            local out = {}
            for index, slot in ipairs(p._inventory) do
                -- Reported exactly as the fixture wrote it. Filling in a
                -- slot number the fixture did not set would be the harness
                -- inventing a field, and a slot is what identifies a weapon
                -- on submit — the one thing a test must not fabricate.
                out[slot.slot or index] = {
                    name = slot.name, count = slot.count, slot = slot.slot,
                    label = slot.label, metadata = slot.metadata,
                }
            end
            return out
        end,
        --- The older shape: one call returning the whole inventory.
        ---
        --- Its items are keyed by SLOT NUMBER, not listed. That is what
        --- ox_inventory actually returns, and a harness that handed back a
        --- plain array would let this resource assume an array it never
        --- gets — every read of the fallback path testing a shape that does
        --- not exist on a live server.
        GetInventory = function(_, src)
            if Natives.noGetInventory then
                error('ox_inventory: no such export GetInventory')
            end
            local p = Env.players[tonumber(src)]
            if not p then return nil end
            local items = {}
            for index, slot in ipairs(p._inventory) do
                items[slot.slot or index] = {
                    name = slot.name, count = slot.count, slot = slot.slot,
                    label = slot.label, metadata = slot.metadata,
                }
            end
            return { items = items }
        end,
        --- Metadata matched as ox_inventory matches it (ox_lib's
        --- table.contains): every value asked for is one of the slot's
        --- values, compared by value, so a nested table never matches.
        Search = function(_, src, query, name, metadata)
            local p = Env.players[tonumber(src)]
            if not p then return {} end
            local out = {}
            for _, slot in ipairs(p._inventory) do
                local held = true
                if type(metadata) == 'table' then
                    local values = {}
                    for _, v in pairs(slot.metadata or {}) do values[v] = true end
                    for _, v in pairs(metadata) do
                        if not values[v] then held = false end
                    end
                end
                if slot.name == name and held then out[#out + 1] = slot end
            end
            return out
        end,
        --- How many of an item, by name, in every slot: what ox_inventory's
        --- export answers without metadata.
        GetItemCount = function(_, src, name)
            local p = Env.players[tonumber(src)]
            if not p then return 0 end
            local count = 0
            for _, slot in ipairs(p._inventory) do
                if slot.name == name then count = count + (slot.count or 0) end
            end
            return count
        end,
    }

    resources['lb-phone'] = {
        --- lb-phone's server form: (phone number, data). Saved on that
        --- phone, and shown to whoever has it equipped. Recorded with the
        --- other notifications, and among the client events under its own
        --- name with the player it reached, so a test that asks "was this
        --- player told" sees either way (Natives.isNotice). A test takes it
        --- away (noServerNotification) or has it say no
        --- (notificationRefused) to model a build where it cannot.
        SendNotification = function(_, target, data)
            if Natives.noServerNotification then error('no such export') end
            if Natives.notificationRefused then return false end
            local src = tonumber(tostring(target):match('^555%-(%d+)$'))
            table.insert(Natives.calls.notifications, data)
            table.insert(Env.clientEvents, {
                name = 'lb-phone:SendNotification', target = src, number = target,
                args = { data },
            })
            return #Natives.calls.notifications
        end,
        --- Removable, for the same reason StartCall is absent by default:
        --- lb-phone ships its server code escrowed and its export surface
        --- has moved across releases, so whether any given export exists is
        --- exactly what cannot be assumed. This one was in the table
        --- unconditionally, with no way for a test to take it away — so the
        --- two server call sites that index it without a guard could not be
        --- caught here.
        ContainsBlacklistedWord = function(_, src, text)
            if Natives.noWordFilter then error('no such export') end
            return tostring(text):lower():find('slur') ~= nil
        end,
        --- By server id or by citizen id, as lb-phone takes either. A server
        --- id a test lists in Natives.unequipped has no phone equipped: none
        --- at all, or one the client has not loaded yet.
        GetEquippedPhoneNumber = function(_, who)
            if Natives.unequipped and Natives.unequipped[who] then return nil end
            return '555-' .. tostring(tonumber(who) or Env.byCitizen[who] or who)
        end,
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
        ClearNotification = function(_, uid, jobs)
            Natives.calls.dispatchCleared = Natives.calls.dispatchCleared or {}
            table.insert(Natives.calls.dispatchCleared, { uid = uid, jobs = jobs })
            return true
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

--- A method oxmysql's lib/MySQL.lua gives both ways: `.await(sql, params)`,
--- and called directly, `(sql, params, cb)`, which hands the statement to
--- oxmysql at once and answers later through cb, if there is one. Run at
--- once here, since nothing in the harness waits on a database.
--- The statement runs through the `.await` it was made with, not whatever
--- `.await` holds later: a test that makes awaiting hang (as it does at a
--- resource stop) leaves the direct call, which waits on nothing, working.
function Natives.mysqlMethod(method)
    local run = method.await
    return setmetatable(method, { __call = function(_, sql, params, cb)
        if type(params) == 'function' then params, cb = nil, params end
        local result = run(sql, params)
        if type(cb) == 'function' then cb(result) end
    end })
end

Natives.mysql.query = Natives.mysqlMethod({ await = function(sql, params) recordQuery(sql, params) return {} end })
Natives.mysql.insert = Natives.mysqlMethod({ await = function(sql, params) recordQuery(sql, params) return 1 end })
Natives.mysql.update = Natives.mysqlMethod({ await = function(sql, params) recordQuery(sql, params) return 1 end })
Natives.mysql.scalar = Natives.mysqlMethod({ await = function(sql, params) recordQuery(sql, params) return nil end })
Natives.mysql.prepare = Natives.mysqlMethod({ await = function(sql, params) recordQuery(sql, params) return {} end })
Natives.mysql.transaction = { await = function(queries)
    for _, q in ipairs(queries) do recordQuery(q.query or q[1], q.values or q[2]) end
    return true
end }

return Natives
