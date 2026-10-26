--- A quiet console (shared/log.lua).
---
--- With Config.Debug = false, as shipped, a normal start on a sound config
--- and normal play print nothing at all to the server console, and the
--- client prints nothing to F8 but a staff command's own answer. What is
--- printed whatever Debug says is only refusing to start, money at risk or
--- left for staff, and a write that failed or read back wrong. The
--- configuration problems a start finds collapse into one line. Everything
--- else is said with Debug on and kept for the diagnosis either way.

local Exec = require('crimson-hitman.tests.harness.mysql_exec')
local Client = require('crimson-hitman.tests.harness.client')
local Log = require('crimson-hitman.shared.log')

local SUMMARY = '[crimson-hitman] %d setting(s) need attention; run ch-diag (F8 or the '
    .. 'server console) or open /hitmanadmin to see them'

local function forgetServerModules()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

--- The config as this resource ships it, for what the runner changes for
--- the other specs' sake: live transfer only, no kill photos, the least
--- reward, collected once. And Config.Debug off, as shipped.
local function shipped()
    Config.Completion.Fulfilment = 'alive'
    Config.Completion.KillPhotos = false
    Config.Completion.PhotoStorage = 'server'
    Config.Limits.MinContractReward = 1000
    Config.Limits.MaxPayoutSlots = 1
    Config.Debug = false
end

--- A fresh server on an empty store, started for real (server/main.lua).
---@param mode string 'memory' | 'json' | 'mysql'
---@param age function|nil changes to the config before it starts
local function boot(mode, age)
    forgetServerModules()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    shipped()
    Config.Database.Mode = mode
    if mode == 'mysql' then Exec.install(Natives) end
    if mode == 'json' then Natives.files = {} end
    if age then age() end
    local main = require('server.main')
    return main, main.start()
end

--- The same server started again on the same disk, as after a restart.
local function restart(mode, age)
    forgetServerModules()
    Env.events, Env.clientEvents, Env.notifications = {}, {}, {}
    Env.handlers, Env.threads, Env.timers, Env.commands = {}, {}, {}, {}
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    resetConfig()
    shipped()
    Config.Database.Mode = mode
    if age then age() end
    local main = require('server.main')
    return main, main.start()
end

local function console() return table.concat(Env.console, '\n') end

--- One request from the admin panel's page, as its client sends it.
local function panel(src, op, data)
    _G.source = src
    local ok, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 7 })
    _G.source = nil
    truthy(ok, 'the panel request raised: ' .. tostring(err))
    for i = #Env.clientEvents, 1, -1 do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
    end
    return nil
end

--- All three together, the target restrained, beside the person who placed it.
local function inHand()
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = 200.0, y = 200.0, z = 30.0 }
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true
end

describe('a quiet console, with Config.Debug off as shipped', function()
    for _, mode in ipairs({ 'memory', 'json', 'mysql' }) do
        it(mode .. ': a normal start, a whole live delivery and the admin panel print nothing', function()
            local main, s = boot(mode)
            truthy(s, 'started')
            eq(console(), '', 'the start printed')

            -- Normal play: a contract placed, taken, and the target brought
            -- alive to the person who placed it.
            local f = fixture(s)
            Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
                firstname = 'Sam', lastname = 'Steward' })
            Env.aces[6] = { ['crimson.admin'] = true }
            local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
            truthy(c, 'placing it: ' .. tostring(err))
            truthy(s.contracts.accept(f.hitman, c.id, false), 'taking it')
            inHand()
            truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'the handover arms')
            for _ = 1, math.floor(Config.Kidnap.CountdownSeconds * 1000 / Config.Kidnap.TickMs) + 1 do
                s.kidnap.tick(Config.Kidnap.TickMs)
            end
            eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED, 'delivered alive')
            for _ = 1, 3 do
                Env.advance(10)
                main.tick()
            end

            -- And staff in the admin panel, reading and changing things.
            for _, op in ipairs({ 'overview', 'contracts', 'stuck', 'reviews', 'logs', 'settings', 'diag' }) do
                local reply = panel(6, op, {})
                truthy(reply and reply.ok, op .. ': ' .. tostring(reply and reply.message))
            end
            truthy(panel(6, 'contract', { id = c.id }).ok)
            truthy(panel(6, 'setSetting', { key = 'Informant.Enabled', value = false }).ok)
            truthy(panel(6, 'resetSetting', { key = 'Informant.Enabled' }).ok)
            truthy(panel(6, 'flush', {}).ok)

            eq(console(), '', 'a quiet console printed')
        end)
    end

    it('says the start\'s configuration problems in exactly one line', function()
        boot('memory', function()
            -- A setting the start warns about, and corrects nothing of.
            Config.Targeting.AllowNearby = true
        end)
        eq(#Env.console, 1, console())
        eq(Env.console[1], SUMMARY:format(1))
    end)

    it('counts every problem in that one line, a drifted config by each setting it lacks', function()
        boot('memory', function()
            Config.Targeting.AllowNearby = true
            Config.Limits.MinContractReward = nil
            Config.Penalty.MinWindowMinutes = nil
        end)
        eq(#Env.console, 1, console())
        eq(Env.console[1], SUMMARY:format(3), 'one for the nearby list, one for each setting filled in')
    end)

    it('lists every problem in full in the diagnosis, which that line sends staff to', function()
        local _, s = boot('memory', function() Config.Targeting.AllowNearby = true end)
        local report = table.concat(s.admin.diagnose(0), '\n')
        truthy(report:find('settings that need attention: 1', 1, true), report)
        truthy(report:find('-> Targeting.AllowNearby is on', 1, true), report)
        -- And what the start said, which a quiet console left out.
        truthy(report:find('· integration sc-dispatch', 1, true), report)
        truthy(report:find('· started in memory mode', 1, true), report)
        local panelOverview = s.panel.handle
        truthy(panelOverview, 'the panel')
    end)

    it('says nothing about problems on a sound config', function()
        local _, s = boot('memory')
        eq(console(), '')
        truthy(table.concat(s.admin.diagnose(0), '\n'):find('settings that need attention: none', 1, true))
    end)

    it('still prints a write that failed', function()
        local _, s = boot('json')
        eq(console(), '')
        local f = fixture(s)
        -- The disk refuses every write from here on.
        Natives.blocked = setmetatable({}, { __index = function() return true end })
        pcall(s.contracts.create, f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        pcall(s.storage.flush)
        Natives.blocked = {}
        truthy(console():find('[crimson-hitman] could not write ', 1, true),
            'a write that failed is said whatever Config.Debug says: ' .. console())
    end)

    it('still prints money left for staff', function()
        local _, s = boot('memory')
        s.review.open({ kind = 'escrow_settle_lost', contract_id = 'ct00000001',
            cids = { recipient = 'HITMAN01' } })
        truthy(console():find('[crimson-hitman] left for staff: review ', 1, true), console())
    end)

    it('still refuses to start out loud, with the problems it found', function()
        forgetServerModules()
        Env.reset()
        Natives.resetResourceStates()
        resetConfig()
        shipped()
        Config.Database.Mode = 'memory'
        Config.Targeting.AllowNearby = true
        Config.Bailout.MinMultiplier, Config.Bailout.MaxMultiplier = 5, 2
        local ok = pcall(require('server.main').start)
        falsy(ok, 'it must refuse')
        truthy(console():find('FATAL: Bailout MinMultiplier is above MaxMultiplier', 1, true), console())
        truthy(console():find('warning: Targeting.AllowNearby is on', 1, true),
            'in full, since no diagnosis can be run to read it: ' .. console())
        falsy(console():find('need attention', 1, true), console())
        resetConfig()
    end)
end)

describe('the console with Config.Debug on', function()
    it('says what a start says, as it did before', function()
        boot('memory', function() Config.Debug = true end)
        for _, line in ipairs({ 'integration sc-dispatch', 'target browsing:', 'started in memory mode' }) do
            truthy(console():find('[crimson-hitman] ' .. line, 1, true), line .. ': ' .. console())
        end
    end)

    it('says each problem in full, and no summary line', function()
        boot('memory', function()
            Config.Debug = true
            Config.Targeting.AllowNearby = true
        end)
        truthy(console():find('[crimson-hitman] warning: Targeting.AllowNearby is on', 1, true), console())
        falsy(console():find('need attention', 1, true), console())
    end)

    it('says a slow job and a failing one', function()
        local main, s = boot('memory', function() Config.Debug = true end)
        Env.console = {}
        s.photos.inUse = function() return true end
        s.photos.expire = function() error('boom') end
        main.tick()
        truthy(console():find('maintenance job "photos.expire" failed: ', 1, true), console())
    end)

    it('is the admin panel\'s Debug output switch, kept across a restart', function()
        local _, s = boot('json')
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001' })
        Env.aces[6] = { ['crimson.admin'] = true }
        local entry = s.settings.entry('Debug')
        truthy(entry, 'in the catalogue')
        eq(entry.section, 'features')
        eq(entry.label, 'Debug output in the server console')
        local reply = panel(6, 'setSetting', { key = 'Debug', value = true })
        truthy(reply.ok, tostring(reply.message))
        eq(Config.Debug, true, 'in force at once')

        -- Started again on the same disk: the panel's value is applied
        -- before the start says its problems, so they are said in full.
        Env.console = {}
        restart('json', function() Config.Targeting.AllowNearby = true end)
        eq(Config.Debug, true, 'kept across the restart')
        truthy(console():find('warning: Targeting.AllowNearby is on', 1, true), console())
        falsy(console():find('need attention', 1, true), console())
        truthy(console():find('started in json mode', 1, true), console())
    end)
end)

describe('the logger itself', function()
    it('keeps the newest lines, a repeated one counted once', function()
        Log.beginStart()
        Log.started()
        for _ = 1, 3 do Log.debug('the same thing') end
        for i = 1, Log.KEPT + 5 do Log.debug('line ' .. i) end
        Log.debug('the same thing')
        local recent = Log.view().recent
        eq(#recent, Log.KEPT, 'bounded')
        eq(recent[#recent].text, 'the same thing', 'newest last')
        eq(recent[#recent].times, 1, 'the earlier ones fell out of the window first')
        Log.beginStart()
    end)

    it('counts a problem found twice once', function()
        Log.beginStart()
        Log.problem('warning: x')
        Log.problem('warning: x')
        eq(Log.view().count, 1)
        Log.dropProblem('warning: x')
        eq(Log.view().count, 0, 'and one that went away is not counted')
        Log.beginStart()
    end)
end)

describe('the client with Config.Debug off', function()
    it('prints nothing to F8 in normal play, even when lb-phone refuses it', function()
        Env.reset()
        resetConfig()
        Config.Debug = false
        Client.boot({ refuseRegistration = true })
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        Client.fire('crimson-hitman:notify', { title = 'Paid', content = '5000' })
        Client.fire('crimson-hitman:access', false)
        eq(table.concat(Client.console, '\n'), '', 'the client printed')
    end)

    it('prints a staff command\'s answer, line by line, whatever Debug says', function()
        Env.reset()
        resetConfig()
        Config.Debug = false
        Client.boot()
        Client.fire('crimson-hitman:commandOutput', { 'first line', 'second line', 42 })
        eq(table.concat(Client.console, '|'), 'first line|second line', 'text only, in order')
        Client.console = {}
        Client.fire('crimson-hitman:commandOutput', 'not a list')
        eq(#Client.console, 0)
    end)
end)
