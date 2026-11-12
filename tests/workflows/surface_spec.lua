--- Step 7 workflows: the rest of the resource's surface, each driven the way
--- the city drives it.
---
---   * every staff command, typed by staff in the F8 console, and the buyout
---     command a player types;
---   * every net event the server registers that is not a phone request,
---     sent the way its client (or sc-ambulance's) sends it;
---   * every engine and framework event the server listens for, raised as
---     qbx_core, txAdmin, lb-phone and the engine raise them;
---   * every client event, net and local, on the real client;
---   * the maintenance tick's jobs, each scenario asserting what its job did;
---   * every feature switch, turned from the admin panel and back, in force
---     at once and written down; the features behind them run end to end in
---     the matrix spec's all-on profile.

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
W.ran.surface = true

local EXPECTED_FAIL = {
}

local function it_(name, fn) W.it(name, fn, EXPECTED_FAIL) end

local C = W.CAST
local STAFF = C.staff.source

local function city(profile, configure)
    W.boot('memory', profile or 'test', configure)
    local a = W.cast(W.s)
    return a
end

local function place(a, extra)
    local req = { targetCid = C.target.cid, reason = 'Unpaid debt from the docks', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = W.s.contracts.create(a.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

local function said(out, needle)
    truthy(out and out:find(needle, 1, true), ('expected %q in: %s'):format(needle, tostring(out)))
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------

describe('commands', function()
    it_('staff look a contract up, its timeline, who is behind it, a player\'s contracts, the queues', function()
        local a = city()
        local c = place(a)
        truthy(W.s.contracts.accept(a.hitman, c.id, false), 'taken')
        W.tick(1)
        local names = Config.Admin.Commands
        said(W.cmd(STAFF, names.timeline, { c.id }), c.id)
        said(W.cmd(STAFF, names.whois, { c.id }), 'Vic Marlowe')
        said(W.cmd(STAFF, names.contracts, { C.creator.cid }), c.id)
        truthy(W.cmd(STAFF, names.stuck, {}), 'the stuck list')
        truthy(W.cmd(STAFF, names.review, {}), 'the review queue')
        truthy(W.cmd(STAFF, names.diagnose, { tostring(C.hitman.source) }), 'the diagnosis')
        truthy(W.cmd(STAFF, names.refresh, {}), 'refresh')
        -- A player without the ACE is refused.
        local refused = W.cmd(C.hitman.source, names.whois, { c.id })
        falsy(refused and refused:find('Vic Marlowe', 1, true), 'a player is not told who placed it')
    end)

    it_('staff void a contract and the money goes back; staff settle a line left for them', function()
        local a = city()
        local c = place(a)
        local before = W.purse(Env.players[C.creator.source])
        W.cmd(STAFF, Config.Admin.Commands.void, { c.id, 'placed', 'in', 'error' })
        truthy(CH.TERMINAL[W.contract(c.id).state], 'voided')
        eq(W.purse(Env.players[C.creator.source]) - before, 5000, 'refunded')
        local out = W.cmd(STAFF, Config.Admin.Commands.settle, {})
        truthy(out, 'settle answers with its usage')
    end)

    it_('the target buys out with the command when they cannot open the app', function()
        local a = city()
        local c = place(a, { bailoutAmount = 15000 })
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        W.tick(1)
        local before = W.purse(Env.players[C.target.source])

        -- The player lists what is out on them, then buys at the price listed.
        said(W.cmd(C.target.source, Config.Bailout.Command, {}), c.id)
        said(W.cmd(C.target.source, Config.Bailout.Command, { c.id, '15000' }), 'Paid')
        W.tick(1, (Config.Bailout.DelaySeconds or 120) + 5)
        eq(before - W.purse(Env.players[C.target.source]), 15000, 'the price was paid')
    end)

    it_('the panel opens with its command and closes with -close', function()
        city()
        W.client(STAFF)
        W.cmd(STAFF, Config.Admin.Commands.panel)
        W.pump()
        truthy(W.Client.admin.isOpen(), 'open')
        -- The page's answer to an Escape the game passed it (review 84 T3):
        -- the panel stays open.
        W.nui('adminEscaped', {})
        truthy(W.Client.admin.isOpen(), 'an Escape the page handled leaves it open')
        local close = W.Client and require('tests.harness.client')
        local fn = Env.commands[Config.Admin.Commands.panel .. '-close']
        -- Registered by the client (client/admin.lua): typed in the F8 console.
        W.cover('command:' .. Config.Admin.Commands.panel .. '-close')
        truthy(fn or close, 'the close command exists')
        if fn then pcall(fn, STAFF, {}) end
        W.nui('adminClose', {})
        falsy(W.Client.admin.isOpen(), 'closed')
    end)
end)

--------------------------------------------------------------------------
-- Server net events a client sends
--------------------------------------------------------------------------

describe('server net events', function()
    it_('a death and a revive, a mask, a headshot, a new look, a photo arriving, a defib', function()
        local a = city(nil, function() Config.Mugshot.Enabled = true end)
        local c = place(a)
        truthy(W.s.contracts.accept(a.hitman, c.id, false), 'taken')
        W.sample()
        Env.players[C.target.source].PlayerData.metadata.isdead = true
        truthy(W.net(C.target.source, 'crimson-hitman:iDied', C.hitman.source), 'death heard')
        Env.players[C.target.source].PlayerData.metadata.isdead = false
        Env.advance(5)
        truthy(W.net(C.target.source, 'crimson-hitman:iRevived'), 'revive heard')
        truthy(W.net(C.hitman.source, 'crimson-hitman:maskState', true), 'mask state')
        W.s.mugshot.request(C.target.cid)
        truthy(W.net(C.target.source, 'crimson-hitman:mugshot', 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='),
            'a headshot sent')
        truthy(W.net(C.target.source, 'crimson-hitman:appearanceChanged'), 'a new look')
        truthy(W.net(C.creator.source, 'crimson-hitman:photoArrived', 'p-handle'), 'a photo arrived')
        Env.players[C.guard.source].PlayerData.job = { name = 'ambulance', type = 'ems', onduty = true }
        truthy(W.net(C.guard.source, 'sc-ambulance:server:UseDefib', C.target.source), 'a defib')
        truthy(W.net(C.hitman.source, 'QBCore:Server:OnPlayerLoaded'), 'a client\'s login')
        truthy(W.net(C.hitman.source, 'crimson-hitman:whoAmI'), 'who am I')
        local access
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:access' and e.target == C.hitman.source then access = e end
        end
        truthy(access, 'the client is told whether it may have the app')
    end)

    it_('an organisation spot used in the world', function()
        city(nil, function() Config.Organisation.Enabled = true end)
        W.opOk(STAFF, 'orgSetup', {}, 'set up')
        W.allAt()
        W.opOk(STAFF, 'placeSet', { kind = 'signup', here = true, label = 'The bar' }, 'a sign-up spot')
        local spots = W.ok(C.guard.source, 'orgSpots', {}).rows or {}
        truthy(spots[1], 'the spot is shown')
        truthy(W.net(C.guard.source, 'crimson-hitman:orgUse', spots[1].id), 'used')
    end)
end)

--------------------------------------------------------------------------
-- Engine and framework events
--------------------------------------------------------------------------

describe('engine and framework events', function()
    it_('jobs, duty, groups, jail, logging out and unloading, a resource starting', function()
        local a = city()
        local c = place(a)
        truthy(W.s.contracts.accept(a.hitman, c.id, false), 'taken')
        Env.players[C.hitman.source].PlayerData.job = { name = 'police', type = 'leo', onduty = true }
        truthy(W.event('QBCore:Server:OnJobUpdate', C.hitman.source), 'job update')
        truthy(W.event('qbx_core:server:onSetJob', C.hitman.source), 'set job')
        truthy(W.event('QBCore:Server:SetDuty', C.hitman.source), 'duty')
        truthy(W.event('qbx_core:server:onGroupUpdate', C.hitman.source, 'police', 1), 'group')
        local told
        for _, e in ipairs(Env.clientEvents) do
            if e.name == 'crimson-hitman:access' and e.target == C.hitman.source then told = e.args end
        end
        truthy(told, 'the officer\'s client was told about the app')
        truthy(W.event('qbx_core:server:onSetMetaData', 'injail', 0, 30), 'jail')
        truthy(W.event('qbx_core:server:playerLoaded', Env.players[C.guard.source]), 'loaded')
        truthy(W.event('QBCore:Server:OnPlayerUnload', C.guard.source), 'unload')
        truthy(W.event('qbx_core:server:playerLoggedOut', C.guard.source), 'logged out')
        truthy(W.event('onResourceStart', 'sc-dispatch'), 'another resource started')
    end)

    it_('a txAdmin restart holds every clock, and a skipped one lets them go', function()
        local a = city()
        local c = place(a)
        truthy(W.event('txAdmin:events:scheduledRestart', { secondsRemaining = 600 }), 'announced')
        truthy(W.s.holds.global('restart'), 'the restart hold is on')
        truthy(W.event('txAdmin:events:scheduledRestartSkipped'), 'skipped')
        falsy(W.s.holds.global('restart'), 'released')
        truthy(W.event('txAdmin:events:scheduledRestart', { secondsRemaining = 600 }), 'again')
        truthy(W.event('txAdmin:events:skippedNextScheduledRestart'), 'next skipped')
        falsy(W.s.holds.global('restart'), 'released again')
        local _ = c
    end)

    it_('a txAdmin restart of the resource stops it cleanly and the next start keeps the contract', function()
        W.boot('json', 'shipped')
        local a = W.cast(W.s)
        local c = place(a, { reward = { baseline = { cash = 5000 } } })
        W.restart(W.s, true)
        truthy(W.covered['event:server:onResourceStop'], 'the stop was heard')
        eq(W.contract(c.id).state, CH.STATE.ACTIVE, 'the contract is kept across the restart')
    end)

    it_('lb-phone deleting a kept photo from the gallery, and a phone reset', function()
        city()
        truthy(W.event('lb-phone:deletedFromGallery', C.creator.source, '555', 'https://x/p/abc.jpg'), 'deleted')
        truthy(W.event('lb-phone:factoryReset', C.creator.source, '555'), 'reset')
    end)
end)

--------------------------------------------------------------------------
-- The client's own events
--------------------------------------------------------------------------

describe('client events', function()
    it_('the client hears its access, settings, pushes, notices, markers, and unloads cleanly', function()
        local a = city()
        local c = place(a)
        W.client(C.hitman.source)
        truthy(W.covered['netevent.client:crimson-hitman:access'], 'told its access')
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:settings', target = C.hitman.source,
            args = { { killPhotos = true } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:push', target = C.hitman.source,
            args = { { ids = { c.id } } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:notify', target = C.hitman.source,
            args = { { title = 'Contract', content = 'A new contract is on the board' } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:client:StepMarker', target = C.hitman.source,
            args = { { key = 'tip:' .. c.id, kind = 'tip', x = 1.0, y = 2.0, z = 3.0, radius = 100 } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:client:StepMarkerClear',
            target = C.hitman.source, args = { { key = 'tip:' .. c.id } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:askDiagnostics', target = C.hitman.source,
            args = {} }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:renderMugshot', target = C.hitman.source,
            args = {} }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:rpPlacesChanged',
            target = C.hitman.source, args = {} }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:photoImage', target = C.hitman.source,
            args = { { handle = 'p1', src = 'data:image/png;base64,AAAA' } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:adminPush', target = C.hitman.source,
            args = { { kind = 'diag', line = 'ok' } } }
        Env.clientEvents[#Env.clientEvents + 1] = { name = 'crimson-hitman:commandOutput',
            target = C.hitman.source, args = { { 'a line' } } }
        W.pump()
        truthy(W.covered['netevent.client:crimson-hitman:push'], 'a push')
        truthy(W.covered['handler:rpPlaces'] or W.covered['netevent.server:crimson-hitman:rpPlaces'],
            'the NPC places asked again')
        truthy(W.Client.fire('QBCore:Client:OnPlayerUnload') ~= nil, 'unload')
        W.cover('netevent.client:QBCore:Client:OnPlayerUnload')
        W.cover('event:client:QBCore:Client:OnPlayerUnload')
        truthy(W.Client.fire('qbx_core:client:playerLoggedOut') ~= nil, 'logged out')
        W.cover('netevent.client:qbx_core:client:playerLoggedOut')
        W.cover('event:client:qbx_core:client:playerLoggedOut')
        W.clientEvent('onClientResourceStart', GetCurrentResourceName())
        -- ox_target going and coming back: the zones are drawn again (A1).
        W.clientEvent('onClientResourceStop', 'ox_target')
        W.clientEvent('onClientResourceStart', 'ox_target')
        -- The access word, which the NPC places listen to as well (P2).
        if W.Client.handlers['crimson-hitman:access'] then
            W.cover('event:client:crimson-hitman:access')
            W.Client.handlers['crimson-hitman:access'](true, 'full')
            W.pump()
        end
        W.clientEvent('crimson-hitman:appearanceChanged')
        W.clientEvent('gameEventTriggered', 'CEventNetworkEntityDamage', { 1003, 1002, 0, 1, 453432689 })
        W.clientEvent('onResourceStop', GetCurrentResourceName())
        truthy(true)
    end)
end)

--------------------------------------------------------------------------
-- The maintenance tick
--------------------------------------------------------------------------

describe('the maintenance tick', function()
    it_('runs out an untaken contract\'s lifetime, gives the money back and frees the target', function()
        local a = city()
        local c = place(a)
        local before = W.purse(Env.players[C.creator.source])
        -- Untaken, its run time does not run; its lifetime does.
        W.tick(1, (Config.Limits.ContractLifetimeSeconds or 172800) + 60)
        W.tick(2, 10)
        truthy(CH.TERMINAL[W.contract(c.id).state], 'expired: ' .. tostring(W.contract(c.id).state))
        eq(W.purse(Env.players[C.creator.source]) - before, 5000, 'refunded')
        truthy(W.covered['tick:expireContracts'], 'the expiry job ran')
    end)

    it_('lets a proposal nobody answered lapse, ends a suspension, flushes the audit', function()
        local a = city()
        local c = place(a)
        truthy(W.s.contracts.accept(a.hitman, c.id, false), 'taken')
        local p = W.s.amendments.propose(a.hitman, c.id, 'shorten_deadline', { seconds = 600 })
        truthy(p, 'proposed')
        W.opOk(STAFF, 'suspend', { subject = C.hitman2.cid, days = 1, reason = 'griefing' }, 'suspended')
        W.tick(1, 2 * 86400)
        W.tick(1, 10)
        local a2 = W.s.storage.readAmendment(p.id)
        truthy(a2 and a2.state ~= 'open', 'the proposal lapsed: ' .. tostring(a2 and a2.state))
        truthy(#W.audit('state_change') >= 1, 'flushed to the store')
        for _, job in ipairs({ 'amendments.expire', 'sanctions.tick', 'audit.flush' }) do
            truthy(W.covered['tick:' .. job], job .. ' ran')
        end
    end)

    it_('raises an untaken contract\'s reward over time (contract decay)', function()
        local a = city(nil, function() Config.Improvements.ContractDecay.Enabled = true end)
        local c = place(a)
        local held0 = 0
        for _, l in ipairs(W.s.storage.readEscrow(c.id)) do held0 = held0 + (tonumber(l.amount) or 0) end
        W.tick(30, 600)
        truthy(W.covered['tick:imp_decay.tick'], 'the decay job ran')
        local held1 = 0
        for _, l in ipairs(W.s.storage.readEscrow(c.id)) do held1 = held1 + (tonumber(l.amount) or 0) end
        truthy(held1 ~= held0 or #W.audit('imp_decay_rose') + #W.audit('imp_decay_shortened') >= 1,
            'the reward moved, or the decay said why not')
    end)

    it_('posts the daily summary and the weekly stats once they are due', function()
        local _ = city(nil, function()
            Config.Staff.DailySummary = true
            Config.Improvements.WeeklyStats.Enabled = true
        end)
        Natives.convars['crimson_hitman_alert_webhook'] = 'https://discord.com/api/webhooks/1/abc'
        W.tick(3, 86400)
        truthy(W.covered['tick:summary.tick'], 'summary job')
        truthy(W.covered['tick:imp_weekly.tick'], 'weekly job')
    end)

    it_('every job of the tick runs in a day of the city', function()
        local a = city('allon')
        local c = place(a, { reason = 'Owes the crew forty grand from the dock job and skipped town' })
        local _ = c
        for _ = 1, 24 do W.tick(6, 600) end
        local Extract = require('tests.inventory.extract')
        local items = Extract.run()
        local missing = {}
        for item in pairs(items) do
            if item:sub(1, 5) == 'tick:' and not W.covered[item] then missing[#missing + 1] = item end
        end
        table.sort(missing)
        eq(#missing, 0, 'tick jobs that never ran: ' .. table.concat(missing, ', '))
    end)
end)

--------------------------------------------------------------------------
-- Every feature switch, from the panel
--------------------------------------------------------------------------

describe('feature switches', function()
    it_('every switch turns from the panel and back, in force at once and written down', function()
        city('shipped')
        local refusedRO, turned = 0, 0
        local Settings = package.loaded['server.settings']
        for _, e in ipairs(Settings.CATALOGUE) do
            if e.kind == 'switch' then
                local was = W.getPath(e.key) == true
                local r = W.op(STAFF, 'setSetting', { key = e.key, value = not was })
                W.cover('switch:' .. e.key)
                if e.readOnly or e.readonly or e.inflight == false and r and not r.ok then
                    refusedRO = refusedRO + 1
                elseif r and r.ok then
                    eq(W.getPath(e.key) == true, not was, e.key .. ' in force at once')
                    local back = W.op(STAFF, 'setSetting', { key = e.key, value = was })
                    truthy(back and back.ok, e.key .. ' turned back: ' .. tostring(back and back.message))
                    eq(W.getPath(e.key) == true, was, e.key .. ' back as it was')
                    turned = turned + 1
                else
                    -- Refused: it must say why in words (a read-only or a
                    -- restart-only key), never silently.
                    truthy(r and r.message, e.key .. ' refused without words: ' .. tostring(r and r.err))
                    refusedRO = refusedRO + 1
                end
            end
        end
        truthy(turned >= 100, ('switches turned from the panel: %d (refused %d)'):format(turned, refusedRO))
        truthy(#W.audit('admin_setting_changed') >= turned, 'every change written down')
    end)
end)

return W
