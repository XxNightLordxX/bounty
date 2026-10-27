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

    --- Kill photos are the panel's switch too, kept across restarts. The
    --- photo address was checked before the panel's value was applied, so
    --- config.lua saying on and the panel saying off still counted it.
    it('counts no photo address problem at a start where the panel has kill photos off', function()
        local function photosInConfig()
            Config.Completion.KillPhotos = true
            Config.Completion.Fulfilment = 'either'
            Config.Completion.PhotoPublicUrl = 'http://not-https.example'
        end
        local _, s = boot('json', photosInConfig)
        eq(console(), SUMMARY:format(1), 'with photos on, the address is a problem')
        truthy(table.concat(s.admin.diagnose(0), '\n'):find('Completion.PhotoPublicUrl', 1, true))

        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001' })
        Env.aces[6] = { ['crimson.admin'] = true }
        local reply = panel(6, 'setSetting', { key = 'Completion.KillPhotos', value = false })
        truthy(reply and reply.ok, tostring(reply and reply.message))

        Env.console = {}
        local _, again = restart('json', photosInConfig)
        eq(Config.Completion.KillPhotos, false, 'the panel\'s value is in force')
        eq(console(), '', 'nothing needs attention: ' .. console())
        local report = table.concat(again.admin.diagnose(0), '\n')
        truthy(report:find('settings that need attention: none', 1, true), report)
        falsy(report:find('PhotoPublicUrl', 1, true), report)
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

    --- A maintenance job that moves money, failing on every tick: a buyout
    --- the target has paid, escrow past its deadline, payouts owed. Printed
    --- before the quiet console whatever Debug said, and then not at all.
    it('still prints a money job that fails, once every few minutes while it keeps failing', function()
        local main, s = boot('memory')
        local f = fixture(s)
        Config.Bailout.ProcessingDelaySeconds = 60
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, bailoutAmount = 12000 })
        truthy(c)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.bailout.buy(f.target, c.id), 'the buyout is paid and queued')
        eq(console(), '')

        local realQueued = s.storage.queuedBailouts
        s.storage.queuedBailouts = function() error('MySQL server has gone away') end
        local function said()
            local n = 0
            for _, line in ipairs(Env.console) do
                if line:find('maintenance job "bailout.processQueue" failed: ', 1, true)
                    and line:find('MySQL server has gone away', 1, true) then n = n + 1 end
            end
            return n
        end
        for _ = 1, 5 do
            main.tick()
            Env.advance(55)
        end
        eq(said(), 1, 'said once, not on every tick: ' .. console())
        Env.advance(60)
        main.tick()
        eq(said(), 2, 'and again once the few minutes are up: ' .. console())
        s.storage.queuedBailouts = realQueued
    end)

    it('prints each money job that fails, whatever Debug says', function()
        local jobs = {
            { 'bailout.processQueue', function(s) s.bailout.processQueue = function() error('x') end end },
            { 'escrow.retryWaiting', function(s) s.escrow.retryWaiting = function() error('x') end end },
            { 'expireContracts', function(s, main)
                s.storage.liveContracts = function() error('x') end
                main.markPresenceChanged()
                main.markContractsChanged()
            end },
            { 'contracts.finishEndings', function(s) s.contracts.finishEndings = function() error('x') end end },
            { 'contracts.retryStuckCreates', function(s)
                s.contracts.retryStuckCreates = function() error('x') end end },
            { 'contracts.retryStuckJoins', function(s)
                s.contracts.retryStuckJoins = function() error('x') end end },
            { 'contracts.releaseIdleHolds', function(s)
                s.contracts.releaseIdleHolds = function() error('x') end end },
        }
        for _, case in ipairs(jobs) do
            local main, s = boot('memory')
            fixture(s)
            Env.advance(60)
            case[2](s, main)
            main.tick()
            truthy(console():find(('[crimson-hitman] maintenance job %q failed: '):format(case[1]), 1, true),
                case[1] .. ' failing printed nothing: ' .. console())
        end
    end)

    --- Everything in a page fault report was written by a browser any
    --- player can script. Its stack went to the console as lines of their
    --- own, colour codes and all, which could read as this resource's own.
    it('prints a page\'s fault report marked as the page\'s, with its colour codes taken out', function()
        local _, s = boot('memory', function() Config.Debug = true end)
        fixture(s)
        Env.console = {}
        _G.source = 2
        pcall(Env.events['crimson-hitman:pageError'], { what = 'render', where = 'board',
            stack = 'at x || ^1escrow line C1:1 was mid-release at shutdown; paid to HITMAN01',
            build = 'test' })
        _G.source = nil
        local said = console()
        falsy(said:find('%^%d'), 'a colour code reached the console: ' .. said)
        for _, line in ipairs(Env.console) do
            if line:find('escrow line C1:1', 1, true) then
                truthy(line:find('[crimson-hitman]   page stack from TARGET01: ', 1, true),
                    'not marked as the page\'s: ' .. line)
            end
        end
    end)

    it('keeps a money line in the diagnosis however many fault reports a player sends', function()
        local _, s = boot('memory')
        fixture(s)
        s.review.open({ kind = 'escrow_settle_lost', contract_id = 'ct00000001',
            cids = { recipient = 'HITMAN01' } })
        for i = 1, 45 do
            _G.source = 2
            pcall(Env.events['crimson-hitman:pageError'], { what = 'fault ' .. i, where = 'board',
                build = 'test' })
            _G.source = nil
            Env.advance(7)
        end
        local report = table.concat(s.admin.diagnose(0), '\n')
        truthy(report:find('left for staff: review ', 1, true), 'pushed out: ' .. report)
        local faults = 0
        for line in report:gmatch('[^\n]+') do
            if line:find('the app reported a fault: ', 1, true) and line:find('·', 1, true) then
                faults = faults + 1
            end
        end
        eq(faults, 1, 'the reports are one counted entry: ' .. report)
        truthy(report:find('the app reported a fault: fault 45', 1, true), report)
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

--- A request, a staff command or the buyout command that raised part-way
--- through moving money. The admin panel's writes printed it whatever Debug
--- said; the same raise from the app, from F8 or from /cleanse was a debug
--- line, the console quiet over an ending left half done.
describe('a raise in something that moves money, with Config.Debug off', function()
    local function said(needle)
        local n = 0
        for _, line in ipairs(Env.console) do
            if line:find(needle, 1, true) then n = n + 1 end
        end
        return n
    end

    --- One request as the page sends it.
    local function request(name, src, payload)
        _G.source = src
        local ok, err = pcall(Env.events['crimson-hitman:' .. name], payload)
        _G.source = nil
        truthy(ok, name .. ' raised past its handler: ' .. tostring(err))
    end

    local function placed(s, f)
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, bailoutAmount = 12000 })
        truthy(c, 'placing it: ' .. tostring(err))
        return c
    end

    it('is printed from an app request: a cancel whose ending raised', function()
        local _, s = boot('memory')
        local f = fixture(s)
        local c = placed(s, f)
        Env.console = {}
        local release = s.escrow.release
        local raises = 1
        s.escrow.release = function(...)
            if raises > 0 then
                raises = raises - 1
                error('database went away')
            end
            return release(...)
        end
        request('cancel', 1, { id = c.id, __rid = 1 })
        s.escrow.release = release
        eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED, 'the ending had begun')
        eq(said('[crimson-hitman] the cancel handler threw: '), 1, 'said once: ' .. console())
        truthy(console():find('database went away', 1, true), console())

        -- And the maintenance pass finishes the ending, as it always did.
        truthy(s.contracts.finishEndings() >= 1, 'the ending is finished')
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            falsy(line.state == CH.ESCROW_STATE.HELD and not line.owed_to,
                'nothing is left held for nobody: ' .. tostring(line.id))
        end
    end)

    it('is printed once every few minutes for the same request, and kept every time', function()
        local _, s = boot('memory')
        local f = fixture(s)
        local c = placed(s, f)
        Env.console = {}
        s.contracts.abandon = function() error('store went away') end
        local function abandon()
            Env.advance(10)
            request('abandon', 3, { id = c.id, __rid = 1 })
        end
        abandon()
        abandon()
        eq(said('the abandon handler threw: '), 1, 'not every time: ' .. console())
        local report = table.concat(s.admin.diagnose(0), '\n')
        truthy(report:find('the abandon handler threw: ', 1, true), 'but kept: ' .. report)
        Env.advance(Log.RAISED_EVERY)
        abandon()
        eq(said('the abandon handler threw: '), 2, 'and again once the few minutes are up')
    end)

    --- Held back by name alone, a second ending that raised inside the few
    --- minutes, on another contract and by another player, reached the
    --- console as nothing at all.
    it('says, once the few minutes are up, how many more it held back', function()
        local _, s = boot('memory')
        local f = fixture(s)
        Env.addPlayer({ source = 4, citizenid = 'CREATOR2', license = 'license:ddd',
            cash = 100000, bank = 100000, firstname = 'Ida', lastname = 'Moss' })
        local first = placed(s, f)
        local second = placed(s, { creator = s.identity.resolve(4) })
        Env.console = {}
        local release, raised = s.escrow.release, 0
        s.escrow.release = function() raised = raised + 1 error('release failed #' .. raised) end
        request('cancel', 1, { id = first.id, __rid = 1 })
        Env.advance(60)
        request('cancel', 4, { id = second.id, __rid = 2 })
        s.escrow.release = release
        eq(raised, 2, 'both endings raised')
        eq(said('the cancel handler threw: '), 1, 'the first printed, the second held: ' .. console())
        eq(said('more time'), 0, 'nothing to count yet')
        Env.advance(Log.RAISED_EVERY)
        eq(said('request cancel raised 1 more time(s)'), 1, 'counted once they are up: ' .. console())
        truthy(console():find('run ch-diag', 1, true), 'and where to read it: ' .. console())
        local report = table.concat(s.admin.diagnose(0), '\n')
        truthy(report:find('release failed #2', 1, true), 'which lists it: ' .. report)
        Env.advance(Log.RAISED_EVERY * 2)
        eq(said('more time'), 1, 'and said once')

        -- And the maintenance pass finishes both endings, as it always did.
        truthy(s.contracts.finishEndings() >= 2, 'the endings are finished')
        for _, c in ipairs({ first, second }) do
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                falsy(line.state == CH.ESCROW_STATE.HELD and not line.owed_to,
                    'nothing is left held for nobody: ' .. tostring(line.id))
            end
        end
    end)

    it('is not printed from a read, which is kept for the diagnosis', function()
        local _, s = boot('memory')
        fixture(s)
        Env.console = {}
        s.projection.listing = function() error('read went wrong') end
        request('list', 2, { page = 1, __rid = 1 })
        eq(console(), '', 'a read that raised moved nothing')
        truthy(table.concat(s.admin.diagnose(0), '\n'):find('the list handler threw: ', 1, true))
    end)

    it('is printed from a staff command that moves money, run in F8, and not from a read', function()
        local _, s = boot('memory')
        local f = fixture(s)
        local c = placed(s, f)
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.console = {}
        s.admin.void = function() error('void went wrong') end
        Env.commands[Config.Admin.Commands.void](6, { c.id, 'test' })
        eq(said(('[crimson-hitman] /%s run by player 6 raised: '):format(Config.Admin.Commands.void)), 1,
            console())
        Env.console = {}
        s.admin.timeline = function() error('timeline went wrong') end
        Env.commands[Config.Admin.Commands.timeline](6, { c.id })
        eq(console(), '', 'a read command that raised moved nothing')
    end)

    it('is printed from the buyout command', function()
        local _, s = boot('memory')
        local f = fixture(s)
        placed(s, f)
        Env.console = {}
        s.bailout.available = function() error('buyout went wrong') end
        Env.commands[Config.Bailout.Command](2, {})
        eq(said(('[crimson-hitman] /%s run by player 2 raised: '):format(Config.Bailout.Command)), 1,
            console())
    end)

    it('names only requests there are', function()
        boot('memory')
        local App = require('server.app')
        local source = read_file('crimson-hitman/server/app.lua')
        local block = source:match('local MONEY_REQUESTS = (%b{})')
        truthy(block, 'the list')
        for name in block:gmatch('([%a]+) = true') do
            truthy(App.handlers[name], name .. ' is not a request')
        end
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

    it('takes colour codes out of every line, nested ones included', function()
        eq(Log.plain('^^11escrow ^^^222line'), 'escrow line')
        Log.beginStart()
        Log.started()
        Env.console = {}
        Config.Debug = true
        Log.debug('^^11fake')
        Log.always('^1also')
        Config.Debug = false
        eq(table.concat(Env.console, '|'), '[crimson-hitman] fake|[crimson-hitman] also')
        Log.beginStart()
    end)

    --- Money left for staff is printed and kept for the diagnosis; a line
    --- a player can cause at will (a page fault report, worded by the page)
    --- pushed it out of what the diagnosis lists.
    it('keeps money lines however many other lines come after them', function()
        Log.beginStart()
        Log.started()
        Log.always('escrow line C9:1 was left for staff')
        for i = 1, Log.KEPT * 3 do Log.debug('fault ' .. i) end
        local found = false
        for _, entry in ipairs(Log.view().recent) do
            if entry.text == 'escrow line C9:1 was left for staff' then found = true end
        end
        truthy(found, 'the money line was pushed out')
        -- Keyed lines are one counted entry, the newest text on it.
        Log.beginStart()
        Log.started()
        for i = 1, 5 do Log.debug('page said ' .. i, 'page-fault') end
        local recent = Log.view().recent
        eq(#recent, 1)
        eq(recent[1].text, 'page said 5')
        eq(recent[1].times, 5)
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

describe('the diagnosis after players have filled what is kept (G3)', function()
    local function report(src, payload)
        _G.source = src
        local ok, err = pcall(Env.events['crimson-hitman:pageError'], payload)
        _G.source = nil
        truthy(ok, 'the report raised: ' .. tostring(err))
    end

    --- W123: the log staff asked for was kept as a fault, and five
    --- diagnoses of one player pushed their real fault out of the report.
    it('keeps the log it asked for out of the faults, the named player\'s first', function()
        local _, s = boot('memory')
        fixture(s)
        report(3, { what = 'REAL FAULT of hitman', where = 'board', build = 'b' })
        report(1, { what = 'a fault of the client', where = 'mine', build = 'b' })
        for _ = 1, 5 do
            s.admin.diagnose(0, 3)
            report(3, { what = 'page diagnostics', where = 'requested', stack = 'a || b', build = 'b' })
            Env.advance(1)
        end
        local out = table.concat(s.admin.diagnose(0, 3), '\n')
        truthy(out:find('app faults: 2 reported by players\' pages, 1 by this player\'s', 1, true), out)
        local own = out:find('REAL FAULT of hitman', 1, true)
        local other = out:find('a fault of the client', 1, true)
        truthy(own and other and own < other, 'theirs first: ' .. out)
        truthy(out:find('a fault of the client  (another player\'s)', 1, true), out)
        falsy(out:find('build b  page diagnostics', 1, true), 'the asked-for log is no fault: ' .. out)
    end)

    --- W128: a page that had spent its report allowance was refused the
    --- log staff asked for, after the promise that it would follow.
    it('takes the log it asked for from a page that has spent its allowance', function()
        local _, s = boot('memory')
        fixture(s)
        for i = 1, Config.Cooldowns.diagnostic.burst + 1 do
            report(3, { what = 'fault ' .. i, where = 'board', build = 'b' })
        end
        s.audit.flush()
        truthy(#s.storage.auditByAction('ratelimit_pageError', 5) > 0, 'the allowance is spent')
        Env.console = {}
        s.admin.diagnose(0, 3)
        report(3, { what = 'page diagnostics', where = 'requested', stack = 'newest event', build = 'b' })
        truthy(console():find('player 3\'s app sent its log', 1, true), console())
        truthy(console():find('page: newest event', 1, true), console())
    end)

    --- W204: one report of a long stack printed some 145 console lines.
    it('prints a few lines of a long stack with Debug on, and says how many more', function()
        local _, s = boot('memory', function() Config.Debug = true end)
        fixture(s)
        local pieces = {}
        for i = 1, 145 do pieces[i] = tostring(i) end
        Env.console = {}
        report(2, { what = 'render', where = 'board', stack = table.concat(pieces, ' || '), build = 'b' })
        local printed = 0
        for _, line in ipairs(Env.console) do
            if line:find('page stack from', 1, true) then printed = printed + 1 end
        end
        truthy(printed <= 9, 'printed ' .. printed .. ' stack lines')
        truthy(console():find('page stack from TARGET01: %(%d+ more in the audit row%)'), console())
    end)

    --- W205: the no-host warning stayed after kill photos went off.
    it('takes the no upload host warning back once kill photos are off', function()
        local _, s = boot('memory', function()
            Config.Completion.KillPhotos = true
            Config.Completion.Fulfilment = 'either'
            Config.Completion.PhotoStorage = 'host'
            Config.Completion.ExtraPhotoHosts = {}
        end)
        local phone = Natives.phoneConfig
        Natives.phoneConfig = {}
        s.photo.loadAllowedHosts()
        truthy(table.concat(s.admin.diagnose(0), '\n'):find('no photo upload host is allowed', 1, true),
            'listed while photos come from a host')
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001' })
        Env.aces[6] = { ['crimson.admin'] = true }
        truthy(panel(6, 'setSetting', { key = 'Completion.KillPhotos', value = false }).ok)
        local out = table.concat(s.admin.diagnose(0), '\n')
        Natives.phoneConfig = phone
        falsy(out:find('no photo upload host is allowed', 1, true), out)
    end)

    --- W206/W207: renamed commands, and every kept line spells them so.
    it('names renamed commands in every line it keeps', function()
        local _, s = boot('memory', function()
            Config.Admin.Commands.stuck = 'hm-stuck'
            Config.Admin.Commands.settle = 'hm-settle'
            Config.Admin.Commands.diagnose = 'hm-diag'
            Config.Admin.Commands.review = 'hm-review'
        end)
        local f = fixture(s)
        s.review.open({ kind = 'escrow_settle_lost', contract_id = 'ct00000001',
            cids = { recipient = 'HITMAN01' } })
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local line = s.storage.readEscrow(c.id)[1]
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
            pcall(s.escrow.release, c.id, 'HITMAN01', { line = line.id }, 'test')
        end
        p.Functions.AddMoney = real
        local kept = Log.view()
        local all = table.concat(kept.problems, '\n') .. '\n' .. table.concat(kept.boot, '\n')
        for _, entry in ipairs(kept.recent) do all = all .. '\n' .. entry.text end
        truthy(all:find('hm-stuck', 1, true), 'a line names the renamed command: ' .. all)
        falsy(all:find('/ch-', 1, true), all)
    end)

    --- W207: a start past what is kept of it lost the rest without a word.
    it('says how many lines of a long start were not kept', function()
        local s = newStack()
        for i = 1, Log.BOOT_KEPT + 7 do Log.debug('start line ' .. i) end
        Log.started()
        local out = table.concat(s.admin.diagnose(0), '\n')
        truthy(out:find('(and 7 more line(s) the start said, not kept)', 1, true), out)
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
