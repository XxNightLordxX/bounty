--- Workflow tests (step 7): the shared driver.
---
--- Every workflow spec under tests/workflows/ drives the resource the way a
--- player or a member of staff does: through the net events the phone app
--- and the admin panel send (and, where a spec says so, through the real
--- client and its NUI callbacks), the commands, the engine events and the
--- maintenance tick of the real server/main.lua, booted on the memory, json
--- or executing mysql store. Never a real database.
---
--- What this file gives a spec:
---   * W.boot(mode, profile) / W.restart(mode, old) / W.crash(...)
---     — the real main.lua, its configuration chosen by a profile:
---     'shipped' (config.lua as the owner ships it), 'allon' (every switch
---     on, see W.ALL_ON_SKIPPED), or 'none:<Integration>' (shipped with one
---     integration set to 'none');
---   * the cast (W.cast) with sessions old enough for every floor;
---   * W.phone / W.op / W.cmd / W.net / W.event / W.tick — each records the
---     capability it drove for the coverage report (W.covered);
---   * W.client(src) and W.nui(name, payload) — the real client/main.lua and
---     client/admin.lua, bridged to the server in both directions;
---   * W.world() — every unit of money (purses, escrow, queued buyouts,
---     owed deliveries, the organisation's internal funds) for conservation;
---   * W.leaks(reply, cids) — a real name or citizen id where it must not be;
---   * W.it(name, fn, list) — a test that, when its name is on the spec's
---     EXPECTED_FAIL list, must fail (a known bug, step7-bugs.md) and is
---     reported as a failure if it starts passing (so the list is kept true).

local Exec = require('tests.harness.mysql_exec')
local Shipped = require('tests.harness.shipped')
local QbxJobs = require('tests.harness.qbx_jobs')

local W = { Exec = Exec, Shipped = Shipped, QbxJobs = QbxJobs }

W.MODES = { 'memory', 'json', 'mysql' }

--- Every integration a server may set to 'none' (Framework may not).
W.INTEGRATIONS = { 'Inventory', 'Target', 'Dispatch', 'Ambulance', 'Banking', 'Phone',
                   'Keys', 'Mugshot', 'Clothing', 'Progression' }

--- The configurations the matrix runs.
W.PROFILES = { 'shipped', 'allon' }
for _, name in ipairs(W.INTEGRATIONS) do W.PROFILES[#W.PROFILES + 1] = 'none:' .. name end

--------------------------------------------------------------------------
-- Coverage
--------------------------------------------------------------------------

--- [capability] = { test name, ... } (first few), across every workflow spec.
W.covered = W.covered or {}
--- Which specs ran, so the coverage spec knows whether it may judge.
W.ran = W.ran or {}
W.test = '(no test)'

function W.cover(item)
    local list = W.covered[item]
    if not list then
        list = {}
        W.covered[item] = list
    end
    if #list < 3 then
        for i = 1, #list do if list[i] == W.test then return end end
        list[#list + 1] = W.test
    end
end

--- A test, recorded under its full name. On the spec's expected-fail list
--- (name -> bug id) it must fail: a pass means the bug was fixed, and the
--- entry is to be removed.
---@param name string
---@param fn function
---@param expected table|nil [name] = 'BUG-n: ...'
function W.it(name, fn, expected)
    local full = ((Suite.current and (Suite.current .. ' > ')) or '') .. name
    local bug = expected and expected[name]
    -- Or a pattern the list gives for a family of tests: { pattern, bug }.
    if not bug and expected then
        for _, entry in ipairs(expected) do
            if full:find(entry[1]) then bug = entry[2] break end
        end
    end
    it(name, function()
        W.test = full
        if not bug then
            fn()
            truthy(true)
            return
        end
        local ok, err = pcall(fn)
        W.expectedFails = W.expectedFails or {}
        if ok then
            error(('%s now passes: remove it from the EXPECTED_FAIL list (%s)'):format(name, bug), 0)
        end
        W.expectedFails[#W.expectedFails + 1] = { test = full, bug = bug, err = tostring(err) }
        truthy(not ok, 'expected to fail: ' .. bug)
    end)
end

--------------------------------------------------------------------------
-- Profiles
--------------------------------------------------------------------------

--- Switches the all-on profile leaves as shipped, and why. Everything else
--- in the settings catalogue of kind 'switch' is turned on.
W.ALL_ON_SKIPPED = {
    ['Holds.AppPaused'] = 'not a feature: it stops the whole app (driven by the freeze workflow)',
    ['Admin.Enabled'] = 'read-only in the panel; on as shipped',
    ['Database.AllowModeSwitch'] = 'read-only; a store switch is not a workflow',
    ['Database.Json.SyncOnFinancialWrite'] = 'read-only; on as shipped',
    ['Completion.RejectLastStand'] = 'read-only; on as shipped',
    ['Debug'] = 'console noise only; driven by the console workflow',
    ['Organisation.AcceptApproval'] = 'holds every member accept for a boss: driven by org_extras_spec',
}

--- Every switch of the settings catalogue, by key.
function W.switches()
    local Settings = package.loaded['server.settings'] or require('server.settings')
    local out = {}
    for _, e in ipairs(Settings.CATALOGUE) do
        if e.kind == 'switch' then out[#out + 1] = e.key end
    end
    return out
end

local function setPath(path, value)
    local node = Config
    local parts = {}
    for part in path:gmatch('[^%.]+') do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
        if type(node[parts[i]]) ~= 'table' then node[parts[i]] = {} end
        node = node[parts[i]]
    end
    node[parts[#parts]] = value
end
W.setPath = setPath

function W.getPath(path)
    local node = Config
    for part in path:gmatch('[^%.]+') do
        if type(node) ~= 'table' then return nil end
        node = node[part]
    end
    return node
end

--- The places and lists the all-on features need to be usable at all: a
--- broker, an informant NPC, a burner item the cast carries, a quick pay day.
local SCENE = { x = 200.0, y = 200.0, z = 30.0 }
W.SCENE = SCENE

local function allOnExtras()
    local here = ('%.1f, %.1f, %.1f, 0'):format(SCENE.x, SCENE.y, SCENE.z)
    if Config.Intel and Config.Intel.Rumours then
        Config.Intel.Rumours.Locations = { here }
        Config.Intel.Rumours.BrokerJobs = { broker = true }
    end
    if Config.Intel and Config.Intel.InPerson then
        Config.Intel.InPerson.Locations = Config.Intel.InPerson.Locations or { here }
    end
end

--- Apply a profile to the live Config (after resetConfig, before a start).
---@param profile string
function W.configure(profile)
    profile = profile or 'shipped'
    -- 'test' keeps the runner's configuration (tests/run.lua CONFIG_DEFAULTS):
    -- kills, photos and anonymity allowed, as most specs are written.
    if profile ~= 'test' then Shipped.apply() end
    Config.Debug = false
    if profile == 'allon' then
        for _, key in ipairs(W.switches()) do
            if not W.ALL_ON_SKIPPED[key] then setPath(key, true) end
        end
        allOnExtras()
    elseif profile:sub(1, 5) == 'none:' then
        Config.Integrations[profile:sub(6)] = 'none'
    elseif profile ~= 'shipped' and profile ~= 'test' then
        error('unknown profile ' .. tostring(profile))
    end
    -- What a workflow is about is the rule, not the request budget.
    for _, bucket in pairs(Config.Cooldowns or {}) do
        if type(bucket) == 'table' and bucket.per then bucket.per, bucket.burst = 1, 100000 end
    end
    Config.Cooldowns.admin = { per = 1, burst = 100000 }
    Config.Cooldowns.adminWrite = { per = 1, burst = 100000 }
    Config.Cooldowns.org = { per = 1, burst = 100000 }
    Config.Cooldowns.orgWrite = { per = 1, burst = 100000 }
    W.profile = profile
end

--------------------------------------------------------------------------
-- Booting
--------------------------------------------------------------------------

local function forget()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

--- cid -> player record, kept after a drop, so their purse still counts.
W.everyone = {}

local function instrument(main, s)
    W.main, W.s = main, s
    if s and s.timing and s.timing.run and not s.timing.__wrapped then
        local run = s.timing.run
        s.timing.run = function(name, ...)
            W.cover('tick:' .. tostring(name))
            return run(name, ...)
        end
        s.timing.__wrapped = true
    end
    -- Every audit action a workflow made the resource write, for the report.
    if s and s.audit and not s.audit.__wrapped then
        for _, kind in ipairs({ 'financial', 'staff', 'action', 'rejected' }) do
            local fn = s.audit[kind]
            if fn then
                s.audit[kind] = function(action, ...)
                    if type(action) == 'string' then W.cover('audit:' .. action) end
                    return fn(action, ...)
                end
            end
        end
        s.audit.__wrapped = true
    end
    return main, s
end

--- A fresh server on an empty store, the profile applied.
---@param mode string 'memory' | 'json' | 'mysql'
---@param profile string|nil
---@param configure function|nil more config, after the profile
function W.boot(mode, profile, configure)
    forget()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    Natives.resetConvars()
    resetConfig()
    W.configure(profile)
    if configure then configure() end
    Config.Database.Mode = mode
    W.mode = mode
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    QbxJobs.install()
    Natives.convars['qbx:max_jobs_per_player'] = '3'
    Natives.resourceStates['Renewed-Banking'] = 'started'
    W.everyone = {}
    W.dropped = {}
    local main = require('server.main')
    return instrument(main, main.start())
end

--- The same server after the process stopped (graceful: onResourceStop ran
--- first, as a txAdmin restart does; otherwise a crash): module state,
--- threads and timers gone, the store and the players kept.
function W.restart(old, graceful)
    if graceful and Env.handlers['onResourceStop'] then
        W.cover('event:server:onResourceStop')
        pcall(Env.handlers['onResourceStop'], GetCurrentResourceName())
    end
    if old and old.storage then rawset(old.storage, '__rawFixture', true) end
    forget()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Env.parked = {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Config.Database.Mode = W.mode
    local main = require('server.main')
    -- The players stay in the city: qbx_core announces nobody again, and
    -- the start finds them itself.
    return instrument(main, main.start())
end

--------------------------------------------------------------------------
-- People
--------------------------------------------------------------------------

W.CAST = {
    creator  = { source = 1, cid = 'CREATOR1', first = 'Vic', last = 'Marlowe' },
    target   = { source = 2, cid = 'TARGET01', first = 'Dana', last = 'Reyes' },
    hitman   = { source = 3, cid = 'HITMAN01', first = 'Rook', last = 'Ash' },
    hitman2  = { source = 4, cid = 'HITMAN02', first = 'Sol', last = 'Vane' },
    guard    = { source = 5, cid = 'GUARD001', first = 'Kit', last = 'Moss' },
    staff    = { source = 6, cid = 'ADMIN001', first = 'Sam', last = 'Steward' },
    broker   = { source = 7, cid = 'BROKER01', first = 'Ora', last = 'Quill' },
    boss     = { source = 11, cid = 'BOSS0001', first = 'Bea', last = 'Holt' },
}

local BURNER = { name = 'burner_phone', count = 3 }

--- Add the cast and age their sessions past every floor.
---@return table actors by role
function W.cast(s)
    s = s or W.s
    for role, who in pairs(W.CAST) do
        local inv = {
            { name = 'black_money', count = role == 'creator' and 50000 or 0 },
            { name = 'lockpick', count = 2 },
        }
        if Config.Roleplay and Config.Roleplay.BurnerPhone and Config.Roleplay.BurnerPhone.Item then
            inv[#inv + 1] = { name = Config.Roleplay.BurnerPhone.Item, count = 3 }
        else
            inv[#inv + 1] = { name = BURNER.name, count = BURNER.count }
        end
        if role == 'creator' then
            inv[#inv + 1] = { name = 'WEAPON_PISTOL', count = 1, metadata = { serial = 'ABC123', ammo = 12 } }
        end
        local p = Env.addPlayer({ source = who.source, citizenid = who.cid, license = 'license:' .. who.cid,
            cash = 100000, bank = 400000, firstname = who.first, lastname = who.last, inventory = inv })
        W.everyone[who.cid] = p
    end
    Env.aces[W.CAST.staff.source] = { ['crimson.admin'] = true, ['crimson.identity'] = true,
                                     ['crimson.developer'] = true, ['crimson.moderator'] = true,
                                     command = true }
    for _, who in pairs(W.CAST) do
        W.loaded(who.source)
        if s.identity.confirmSession then pcall(s.identity.confirmSession, who.cid) end
    end
    Env.advance(3 * 3600)
    local out = {}
    for role, who in pairs(W.CAST) do out[role] = s.identity.resolve(who.source) end
    W.actors = out
    return out
end

--- qbx_core announcing a loaded character.
function W.loaded(src)
    local p = Env.players[src]
    local h = Env.handlers['QBCore:Server:PlayerLoaded']
    if p and h then
        W.cover('event:server:QBCore:Server:PlayerLoaded')
        pcall(h, p)
    end
end

--- A player leaving the city: playerDropped with them still resolvable,
--- then gone. Their record (and purse) is kept for W.rejoin and W.world.
function W.drop(src)
    local p = Env.players[src]
    if not p then return end
    W.dropped[src] = p
    local h = Env.handlers['playerDropped']
    if h then
        W.cover('event:server:playerDropped')
        local was = _G.source
        _G.source = src
        local ok, err = pcall(h, 'Exiting')
        _G.source = was
        if not ok then error('playerDropped raised: ' .. tostring(err), 0) end
    end
    Env.removePlayer(src)
end

--- And coming back, the same character, money and all.
function W.rejoin(src)
    local p = W.dropped[src]
    if not p then return end
    W.dropped[src] = nil
    Env.players[src] = p
    Env.byCitizen[p.PlayerData.citizenid] = src
    W.loaded(src)
end

function W.at(src, x, y, z)
    if Env.players[src] then Env.players[src]._coords = { x = x, y = y, z = z or 30.0 } end
end

function W.allAt(where)
    where = where or SCENE
    for _, who in pairs(W.CAST) do W.at(who.source, where.x, where.y, where.z) end
end

--------------------------------------------------------------------------
-- Driving
--------------------------------------------------------------------------

local function isHandler(name)
    local app = W.s and W.s.app
    return app and app.handlers and app.handlers[name] ~= nil
end

--- A phone request, as the app sends it: the reply { ok, err, data }.
function W.phone(src, name, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    if not fire then return { ok = false, err = 'NO SUCH HANDLER', missing = true } end
    W.cover('handler:' .. name)
    local from = #Env.clientEvents
    local was = _G.source
    _G.source = src
    local ok, err = pcall(fire, payload or {})
    _G.source = was
    if not ok then return { ok = false, err = 'THREW: ' .. tostring(err), threw = true } end
    for i = from + 1, #Env.clientEvents do
        local e = Env.clientEvents[i]
        if e.name == 'crimson-hitman:result' and e.target == src then
            local r = e.args[1]
            if type(r) == 'table' and not r.ok and type(r.err) == 'string' then W.cover('refusal:' .. r.err) end
            return r
        end
    end
    return nil
end

--- Must succeed: the reply's data.
function W.ok(src, name, payload, why)
    local r = W.phone(src, name, payload)
    if not (r and r.ok) then
        error(('%s by %s refused: %s (%s)'):format(name, tostring(src), tostring(r and r.err),
            tostring(why or '')), 2)
    end
    return r.data, r
end

--- An admin panel op, as the page sends it: the reply.
function W.op(src, op, data)
    local fire = Env.events['crimson-hitman:admin']
    if not fire then return { ok = false, err = 'NO PANEL EVENT' } end
    W.cover('op:' .. op)
    local from = #Env.clientEvents
    local was = _G.source
    _G.source = src
    local fired, err = pcall(fire, { op = op, data = data or {}, __rid = 7 })
    _G.source = was
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err), threw = true } end
    for i = from + 1, #Env.clientEvents do
        local e = Env.clientEvents[i]
        if e.name == 'crimson-hitman:adminResult' and e.target == src then return e.args[1] end
    end
    return nil
end

function W.opOk(src, op, data, why)
    local r = W.op(src, op, data)
    if not (r and r.ok) then
        error(('op %s refused: %s %s (%s)'):format(op, tostring(r and r.err), tostring(r and r.message),
            tostring(why or '')), 2)
    end
    return r.data, r
end

--- The Players lookup handle staff act from, for a citizen id.
function W.ref(cid, staffSrc)
    local data = W.opOk(staffSrc or W.CAST.staff.source, 'player', { subject = cid }, 'look up ' .. cid)
    return data.player and data.player.ref
end

--- A command typed by a player (src) or the console (0): what it printed.
function W.cmd(src, name, args)
    local h = Env.commands[name]
    if not h then return nil, 'no command ' .. tostring(name) end
    W.cover('command:' .. name)
    local chatFrom, consoleFrom = #Env.chat, #Env.consoleOut
    local ok, err = pcall(h, src, args or {}, name .. ' ' .. table.concat(args or {}, ' '))
    if not ok then return nil, 'THREW: ' .. tostring(err) end
    local lines = {}
    for i = chatFrom + 1, #Env.chat do lines[#lines + 1] = Env.chat[i].text end
    for i = consoleFrom + 1, #Env.consoleOut do lines[#lines + 1] = tostring(Env.consoleOut[i]) end
    return table.concat(lines, '\n'), lines
end

--- A server net event a client sends (not a phone request).
function W.net(src, name, ...)
    local fire = Env.events[name]
    if not fire then return false, 'no net event ' .. tostring(name) end
    local short = name:match('^crimson%-hitman:(.+)$')
    if short and isHandler(short) then W.cover('handler:' .. short) else W.cover('netevent.server:' .. name) end
    local was = _G.source
    _G.source = src
    local ok, err = pcall(fire, ...)
    _G.source = was
    return ok, err
end

--- A local server event the engine or another resource raises.
function W.event(name, ...)
    local h = Env.handlers[name]
    if not h then return false, 'no handler for ' .. tostring(name) end
    W.cover('event:server:' .. name)
    return pcall(h, ...)
end

--- One pass of the engine's own one-second loops the harness cannot run as
--- threads: the death sampler (Death.startSampler's pass), which keeps who
--- the damage events are watched for.
function W.sample()
    local s = W.s
    if not (s and s.death and s.death.watchTargets) then return end
    if s.projection and s.projection.liveSnapshot then
        local live, hitmen = s.projection.liveSnapshot()
        s.death.watchTargets(live, #live == 0 and {} or hitmen)
    else
        s.death.watchTargets(s.storage.liveContracts(), s.storage.liveHitmen and s.storage.liveHitmen() or nil)
    end
end

--- The maintenance tick, n times, the clock moved `step` seconds before each.
function W.tick(n, step)
    for _ = 1, n or 1 do
        if step and step > 0 then Env.advance(step) end
        W.sample()
        W.main.tick()
    end
end

--------------------------------------------------------------------------
-- A fault at one database await (mysql)
--------------------------------------------------------------------------

--- Run `fn` (a request, in a coroutine of its own as the engine runs a net
--- event) and stop it at its k-th database await, before the statement runs
--- ('pre') or after it ran and before the request saw the answer ('post').
--- There `fault()` runs: a player leaving (the request then carries on), or
--- the process dying (`dies` = true: the request never resumes).
--- Without k, the awaits are only counted.
---@return table rec { fired, depth, statement }
function W.atAwait(k, phase, fn, fault, dies)
    local s = W.s
    local rec = { fired = false, depth = 0 }
    if not (s.storage.timeWaitsWith and s.timing and s.timing.await) then
        fn()
        return rec
    end
    local inner = s.timing.await
    local co
    s.storage.timeWaitsWith(function(send, sql, ...)
        if coroutine.running() == co then
            rec.depth = rec.depth + 1
            if k and rec.depth == k and not rec.fired then
                rec.fired = true
                rec.statement = type(sql) == 'string' and sql:gsub('%s+', ' '):sub(1, 80) or 'TRANSACTION'
                if phase == 'pre' then
                    coroutine.yield('await')
                    return inner(send, sql, ...)
                end
                local out = table.pack(inner(send, sql, ...))
                coroutine.yield('await')
                return table.unpack(out, 1, out.n)
            end
        end
        return inner(send, sql, ...)
    end)
    co = coroutine.create(function() return fn() end)
    local ok, why = coroutine.resume(co)
    if not ok then error(why, 0) end
    if coroutine.status(co) == 'suspended' and rec.fired then
        if fault then fault() end
        if not dies then
            s.storage.timeWaitsWith(inner)
            while coroutine.status(co) == 'suspended' do
                local again, err = coroutine.resume(co)
                if not again then error(err, 0) end
            end
        end
    end
    if not dies then s.storage.timeWaitsWith(inner) end
    return rec
end

--------------------------------------------------------------------------
-- The real client, bridged
--------------------------------------------------------------------------

W.Client = nil

--- Load a client file the harness does not (client/org.lua, client/rp_npc.lua)
--- into the client's tables, chaining a handler a second file registers
--- under a name already taken, as the engine runs both.
local function loadClientFile(Client, module)
    local realNet, realAdd = _G.RegisterNetEvent, _G.AddEventHandler
    local function chain(tbl, name, fn)
        local before = tbl[name]
        if before then
            tbl[name] = function(...) before(...) return fn(...) end
        else
            tbl[name] = fn
        end
    end
    _G.RegisterNetEvent = function(name, fn) if fn then chain(Client.netEvents, name, fn) end end
    _G.AddEventHandler = function(name, fn) chain(Client.handlers, name, fn) end
    package.loaded[module] = nil
    local ok, err = pcall(require, module)
    _G.RegisterNetEvent, _G.AddEventHandler = realNet, realAdd
    return ok, err
end

--- Boot the real client as player `src`'s game, bridged to the server.
function W.client(src)
    local Client = require('tests.harness.client')
    -- The server's own threads (the handover's shared countdown, the death
    -- sampler) are not the client's: Client.runThreads runs whatever is
    -- queued, and would run them ten thousand passes.
    local serverThreads = Env.threads
    Env.threads = {}
    Client.boot()
    loadClientFile(Client, 'crimson-hitman.client.org')
    loadClientFile(Client, 'crimson-hitman.client.rp_npc')
    W.Client, W.clientSrc = Client, src
    W.clientCursor = #Env.clientEvents
    Client.runThreads()
    Env.threads = serverThreads
    -- The start-up thread asks who it is, and asks again after each wait
    -- with no answer. Here its waits are instant and the answer comes only
    -- once it has finished, so it asked many times over; on a server the
    -- first answer stops it. One question goes across.
    local seen, kept = {}, {}
    for _, m in ipairs(Client.toServer) do
        if m.name == 'crimson-hitman:whoAmI' then
            if not seen[m.name] then seen[m.name] = true kept[#kept + 1] = m end
        else
            kept[#kept + 1] = m
        end
    end
    Client.toServer = kept
    W.pump()
    return Client
end

--- Move every message across until nothing is left: the client's to the
--- server (as player W.clientSrc), the server's to that client.
function W.pump()
    local Client = W.Client
    if not Client then return end
    for _ = 1, 50 do
        local moved = false
        while #Client.toServer > 0 do
            local m = table.remove(Client.toServer, 1)
            moved = true
            local fire = Env.events[m.name]
            if fire then
                local short = m.name:match('^crimson%-hitman:(.+)$')
                if short and isHandler(short) then W.cover('handler:' .. short)
                else W.cover('netevent.server:' .. m.name) end
                local was = _G.source
                _G.source = W.clientSrc
                local ok, err = pcall(fire, table.unpack(m.args))
                _G.source = was
                if not ok then error(('server %s raised: %s'):format(m.name, tostring(err)), 0) end
            end
        end
        while W.clientCursor < #Env.clientEvents do
            W.clientCursor = W.clientCursor + 1
            local e = Env.clientEvents[W.clientCursor]
            if e.target == W.clientSrc or e.target == -1 then
                if Client.netEvents[e.name] then
                    moved = true
                    W.cover('netevent.client:' .. e.name)
                    -- The game's vector type, which the client's spots build
                    -- (client/org.lua), only while the client runs.
                    local hadVector = rawget(_G, 'vector3')
                    _G.vector3 = hadVector or function(x, y, z) return { x = x, y = y, z = z } end
                    local ok, err = Client.fire(e.name, table.unpack(e.args))
                    _G.vector3 = hadVector
                    if ok == false and err then error(('client %s raised: %s'):format(e.name, tostring(err)), 0) end
                end
            end
        end
        if not moved then break end
    end
end

--- An NUI callback as the page calls it: whether it answered, and what.
function W.nui(name, payload)
    W.cover('nui:' .. name)
    -- A second between taps, as a player taps: the per-source flood guard
    -- (App's floodCheck) is about scripts, not people.
    Env.advance(1)
    -- The one map native Set GPS calls, recorded, and only while the client
    -- runs (FXServer has none: a server spec must never see it).
    local had = rawget(_G, 'SetNewWaypoint')
    _G.SetNewWaypoint = function(x, y) W.waypoint = { x = x, y = y } end
    local answered, answer = W.Client.nuiCall(name, payload)
    W.pump()
    _G.SetNewWaypoint = had
    return W.Client.answer or answer, W.Client.answered or answered
end

--- A client engine event (gameEventTriggered, onClientResourceStart, ...).
function W.clientEvent(name, ...)
    W.cover('event:client:' .. name)
    local ok, err = W.Client.fire(name, ...)
    W.pump()
    return ok, err
end

--------------------------------------------------------------------------
-- What the world looks like
--------------------------------------------------------------------------

local function purse(p)
    local dirty = 0
    local item = Config.Sources and Config.Sources.dirty and Config.Sources.dirty.item or 'black_money'
    for _, e in ipairs(p._inventory or {}) do
        if e.name == item then dirty = dirty + (e.count or 0) end
    end
    return (p.PlayerData.money.cash or 0) + (p.PlayerData.money.bank or 0) + dirty
end
W.purse = purse

--- Every unit of money in the world, as the store holds it now.
function W.world(s)
    s = s or W.s
    local total = 0
    for _, p in pairs(W.everyone) do total = total + purse(p) end
    for _, l in ipairs(s.storage.unsettledEscrow() or {}) do
        if CH.MONEY_SOURCES[l.source] then
            total = total + (tonumber(l.amount) or 0) - (tonumber(l.deliver_arrived) or 0)
        end
    end
    for _, c in ipairs(s.storage.allContracts() or {}) do
        if c.bailout_queued_at and c.bailout_paid_amount then
            total = total + (tonumber(c.bailout_paid_amount) or 0)
        end
    end
    -- The organisation's money: Renewed-Banking's account (the harness's
    -- bank, counted whole), or the internal ledger.
    local Funds = package.loaded['server.org.funds']
    local org = s.org and s.org.current and s.org.current()
    if Funds and org and not Funds.usesBank() then
        total = total + (tonumber(Funds.balance(org)) or 0)
    end
    for _, amount in pairs(QbxJobs.bank or {}) do total = total + (tonumber(amount) or 0) end
    return total
end

--- The audit rows with this action, newest last.
function W.audit(action, s)
    s = s or W.s
    if s.audit and s.audit.flush then pcall(s.audit.flush) end
    local out = {}
    for _, row in ipairs(s.storage.readAudit() or {}) do
        if row.action == action then out[#out + 1] = row end
    end
    return out
end

--- Every notice a player's phone was given, as 'title | content'.
function W.notices(src)
    local out = {}
    for _, e in ipairs(Env.clientEvents) do
        if Natives.isNotice(e) and e.target == src then
            local a = e.args[1] or {}
            out[#out + 1] = tostring(a.title) .. ' | ' .. tostring(a.content)
        end
    end
    return out
end

function W.has(list, needle)
    for _, t in ipairs(list) do if tostring(t):find(needle, 1, true) then return true end end
    return false
end

--- Does any string inside `value` name one of the given words?
function W.leaks(value, words)
    local found
    local seen = {}
    local function walk(v)
        if found then return end
        if type(v) == 'string' then
            for _, w in ipairs(words) do
                if v:find(w, 1, true) then found = w return end
            end
        elseif type(v) == 'table' and not seen[v] then
            seen[v] = true
            for k, x in pairs(v) do walk(k) walk(x) end
        end
    end
    walk(value)
    return found
end

--- Every message any player was sent, for an anonymity scan.
function W.sentTo(src)
    local out = {}
    for _, e in ipairs(Env.clientEvents) do
        if e.target == src then out[#out + 1] = e end
    end
    return out
end

--- What a contract is now.
function W.contract(id, s)
    return (s or W.s).storage.readContract(id)
end

return W
