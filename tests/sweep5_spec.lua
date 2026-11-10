--- Sweep 5 (at 3285750): the leftovers of the earlier sweeps, each held to
--- its fix. Every test here failed on the code before it, except the two
--- K10 asked for as missing coverage of behaviour that was already right.
---
---   K1  a freeze inside the app pause gave an open proposal nothing back.
---   K2  an idle release refused under the lock by a hold landing reset the
---       hold's idle clocks.
---   K3  a proof-item handover counted as a kill: EMS re-listing, the
---       witness report and a city news post of an attack.
---   K4  go dark wrote its row before the charge; a tip warning dropped its
---       row before the target was told.
---   K5  go-dark rows and decay rows nobody ever pruned.
---   K6  the placer's Ledger row for an expiry left out the stakes forfeited
---       to them.
---   K7  the client's /<panel>-close came from config.lua, not the name the
---       server registered.
---   K8  a scrubbed serial changed across a restart.
---   K9  the decay count lost the untaken stretch between a walk-away and a
---       freeze.
---   K10 coverage: lookup handles pruned across staff; a staff extension
---       pulled back when the lifetime ends lower than planned.

local IMP = require('tests.harness.improvements')
local Client = require('tests.harness.client')

local TARGET_AT = { x = 1200.0, y = -800.0, z = 30.0 }
local TIP = { cost = 25000, account = 'bank' }
local DARK = { cost = 50000, account = 'bank' }

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

--- Config.Improvements, Config.Roleplay, the tip, the amendments and the
--- app pause put back, whichever way the test ends.
local function it(name, fn)
    IMP.it(name, function(...)
        local tip = deepCopy(Config.Intel.LocationTip)
        local amendments = deepCopy(Config.Amendments)
        local paused = Config.Holds.AppPaused
        local panel = Config.Admin.Commands.panel
        local out = table.pack(pcall(fn, ...))
        Config.Intel.LocationTip = tip
        Config.Amendments = amendments
        Config.Holds.AppPaused = paused
        Config.Admin.Commands.panel = panel
        if not out[1] then error(out[2], 0) end
    end)
end

local function call(name, src, payload)
    local handler = Env.events['crimson-hitman:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
    end
    return nil
end

local function bank(src) return Env.players[src].PlayerData.money.bank end

local function place(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 10000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

--- A contract the hitman (source 3) holds, its target (source 2) at
--- TARGET_AT, everybody able to pay.
local function taken()
    local s = newStack()
    Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
    local f = fixture(s)
    local c = place(s, f, { reward = { baseline = { cash = 5000 } } })
    Env.players[1].PlayerData.money.bank = 200000
    Env.players[2].PlayerData.money.bank = 200000
    Env.players[3].PlayerData.money.bank = 200000
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    Env.players[2]._coords = { x = TARGET_AT.x, y = TARGET_AT.y, z = TARGET_AT.z }
    Env.advance(1)
    return s, f, c
end

local function restartTips(s)
    s.intelRules.init({ storage = s.storage, audit = s.audit, notify = s.notify,
        contracts = s.contracts, locationTip = s.locationTip, informant = s.informant,
        projection = s.projection, bailout = s.bailout })
end

--------------------------------------------------------------------------
-- K1: a proposal's time on hold
--------------------------------------------------------------------------

describe('sweep 5 K1: a proposal held by a freeze inside the app pause', function()
    local function proposed()
        local s = newStack()
        local f = fixture(s)
        Config.Amendments.ProposalExpirySeconds = 600
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        truthy(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'A better reason' }), 'proposed')
        local open = s.storage.readOpenAmendments(c.id)
        eq(#open, 1)
        return s, f, c, open[1]
    end

    it('gives the proposal the freeze back, though the app pause covered it all', function()
        local s, _, c, p = proposed()
        local due = p.expires_at
        Env.advance(60)
        Config.Holds.AppPaused = true
        eq(s.holds.syncAppPause(), 'paused')
        Env.advance(60)
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(900)
        eq(s.amendments.expire(), 0, 'nobody can answer it on hold: none runs out')
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        local after = s.storage.readOpenAmendments(c.id)[1]
        truthy(after, 'still open')
        eq(after.expires_at, due + 900, 'given back the 15 minutes the freeze held it')
        eq(s.amendments.expire(), 0, 'not run out the moment the freeze ends')
        Config.Holds.AppPaused = false
        eq(s.holds.syncAppPause(), 'resumed')
        eq(s.storage.readOpenAmendments(c.id)[1].expires_at, due + 900,
            'the app pause gives nothing more: a proposal can be answered under it')
    end)

    it('gives it the freeze back under the restart hold too', function()
        local s, _, c, p = proposed()
        local due = p.expires_at
        truthy(s.holds.scheduledRestart({ secondsRemaining = 600 }), 'restart hold on')
        Env.advance(30)
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(700)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        eq(s.storage.readOpenAmendments(c.id)[1].expires_at, due + 700)
    end)

    it('lets a proposal run out under the app pause alone: it can be answered meanwhile', function()
        local s, f, c = proposed()
        Config.Holds.AppPaused = true
        eq(s.holds.syncAppPause(), 'paused')
        local open = s.storage.readOpenAmendments(c.id)[1]
        truthy(s.amendments.respond(f.hitman, open.id, false), 'answered under the pause')
        truthy(s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'Another reason' }))
        Env.advance(Config.Amendments.ProposalExpirySeconds + 101)
        eq(s.amendments.expire(), 1, 'ran out as usual')
    end)
end)

--------------------------------------------------------------------------
-- K2: an idle release refused by a hold landing under the lock
--------------------------------------------------------------------------

describe('sweep 5 K2: an idle release refused by a hold keeps its clocks', function()
    local function held()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { mode = CH.MODE.EXCLUSIVE, reward = { baseline = { cash = 50000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[3]._coords = { x = 5000.0, y = 5000.0, z = 0.0 }
        return s, f, c
    end

    local function run(s, minutes)
        for _ = 1, minutes do
            Env.advance(60)
            s.death.watchTargets(s.storage.allContracts())
            s.contracts.releaseIdleHolds()
        end
    end

    it('releases at once after the hold, with the idle time it had', function()
        local s, _, c = held()
        Config.Limits.ExclusiveAttemptWindowSeconds = 0
        local window = Config.Limits.ExclusiveIdleReleaseSeconds
        truthy(window and window > 120, 'an idle window')
        s.contracts.releaseIdleHolds()
        run(s, math.floor(window / 60) - 1)
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'not due yet')

        -- The freeze lands under the contract's lock, as the release reads.
        local readHitman, landed = s.storage.readHitman, false
        s.storage.readHitman = function(...)
            if not landed and debug.traceback():find('releaseIdleHold', 1, true) then
                landed = true
                s.holds.freeze('ADMIN001', 'TARGET01', 'probe')
            end
            return readHitman(...)
        end
        run(s, 2)
        s.storage.readHitman = readHitman
        truthy(landed, 'the freeze landed in the release')
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'active', 'refused on hold')

        run(s, 30)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        run(s, 1)
        eq(s.storage.readHitman(c.id, 'HITMAN01').state, 'released',
            'released on the first pass after: its idle time was kept through the hold')
    end)
end)

--------------------------------------------------------------------------
-- K3: a proof handover is not a kill
--------------------------------------------------------------------------

describe('sweep 5 K3: a proof-item handover is its own outcome', function()
    local function card(src, cid)
        local p = Env.players[src]
        p._inventory[#p._inventory + 1] = { name = 'id_card', count = 1, slot = 41,
            metadata = { citizenid = cid, firstname = 'Dana', lastname = 'Reyes' } }
    end

    it('re-lists no EMS hold, posts no attack, and says proof on the Ledger', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { reward = { baseline = { cash = 40000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        Config.Improvements.ProofItems.Enabled = true
        Config.Roleplay.EmsRelisting.Enabled = true
        Config.Roleplay.CityNews.Enabled = true
        Config.Roleplay.CityNews.AllTargets = true
        Config.Roleplay.CityNews.App = 'event'
        Config.Roleplay.WitnessHeat.Enabled = true
        Config.Roleplay.WitnessHeat.AlwaysAlert = true
        local posted
        Env.events['local:crimson-hitman:cityNews'] = function(data) posted = data end
        card(3, 'TARGET01')
        local reply = call('proofItem', 3, { id = c.id })
        Env.events['local:crimson-hitman:cityNews'] = nil
        truthy(reply and reply.ok, 'paid: ' .. tostring(reply and reply.err))
        eq(posted, nil, 'no news of an attack nobody saw')
        eq(#s.storage.readRpRows('ems'), 0, 'no EMS hold: nobody was seen killed')
        s.audit.flush()
        eq(#(s.storage.auditByAction('rp_witness_alert', 10) or {}), 0,
            'no witness report placing the hitman beside the placer')
        local target = s.storage.readLedger('TARGET01', 10)[1]
        eq(target and target.fulfilment, CH.FULFILMENT.PROOF, 'the Ledger says proof, not elimination')
        falsy(s.rpConsequences.relistHold(s.identity.resolve(2)),
            'a new contract on them is not held for EMS (the Ledger row says proof)')
    end)

    it('still re-lists after a kill (unchanged)', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.EmsRelisting.Enabled = true
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[2].PlayerData.metadata.isdead = true
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        eq(#s.storage.readRpRows('ems'), 1)
        truthy(s.rpConsequences.relistHold(s.identity.resolve(2)), 'held for EMS')
    end)
end)

--------------------------------------------------------------------------
-- K4: go dark's row after the charge; a tip warning sent before it goes
--------------------------------------------------------------------------

describe('sweep 5 K4: go dark and the tip warning in the right order', function()
    local function tipped()
        local s, f, c = taken()
        Config.Intel.GoDark.Enabled = true
        Config.Intel.GoDark.Cost = 50000
        Config.Intel.GoDark.Minutes = 30
        local r = call('locationTip', 3, { id = c.id, shown = TIP })
        truthy(r and r.ok, 'tipped: ' .. tostring(r and r.err))
        return s, f, c
    end

    --- The nth write of a go-dark row raises after it has landed, as a
    --- mysql write that timed out on the client and committed anyway.
    local function landsLate(s, nth)
        local write, n = s.storage.writeRpRow, 0
        s.storage.writeRpRow = function(row)
            local out = write(row)
            if row.kind == 'imp_dark' then
                n = n + 1
                if n == nth then error('lock wait timeout exceeded') end
            end
            return out
        end
        return function() s.storage.writeRpRow = write end
    end

    it('a row write that raises and lands late leaves nobody dark for free after a restart', function()
        local s, _, c = tipped()
        local before = bank(2)
        local undo = landsLate(s, 1)
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        undo()
        falsy(r and r.ok, 'refused')
        eq(bank(2), before, 'nothing charged')
        restartTips(s)
        falsy(s.intelRules.targetDark('TARGET01'), 'not dark for nothing after the restart')
    end)

    it('a write after the charge that raises gives the price back, and leaves nobody dark', function()
        local s, _, c = tipped()
        local before = bank(2)
        local undo = landsLate(s, 2)
        local r = call('goDark', 2, { id = c.id, shown = DARK })
        undo()
        falsy(r and r.ok, 'refused: ' .. tostring(r and r.err))
        eq(bank(2), before, 'the price given back')
        falsy(s.intelRules.targetDark('TARGET01'))
        restartTips(s)
        falsy(s.intelRules.targetDark('TARGET01'), 'nor after a restart')
    end)

    it('a purchase that stands is still kept across a restart', function()
        local s, _, c = tipped()
        local before = bank(2)
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        eq(bank(2), before - 50000)
        restartTips(s)
        truthy(s.intelRules.targetDark('TARGET01'), 'still dark after the restart')
    end)

    it('tells the target before the waiting warning leaves the store', function()
        local s, _, c = taken()
        Config.Intel.WarningDelay.Enabled = true
        Config.Intel.WarningDelay.MinSeconds = 60
        Config.Intel.WarningDelay.MaxSeconds = 60
        truthy(call('locationTip', 3, { id = c.id, shown = TIP }).ok)
        local order = {}
        local delete, tell = s.storage.deleteRpRow, s.notify.locationTipped
        s.storage.deleteRpRow = function(id, ...)
            if tostring(id):sub(1, 3) == 'iw:' then order[#order + 1] = 'deleted' end
            return delete(id, ...)
        end
        s.notify.locationTipped = function(...)
            order[#order + 1] = 'told'
            return tell(...)
        end
        Env.advance(61)
        s.storage.deleteRpRow, s.notify.locationTipped = delete, tell
        eq(table.concat(order, ','), 'told,deleted', 'a stop between the two never loses the warning')
    end)
end)

--------------------------------------------------------------------------
-- K5: rows nobody pruned
--------------------------------------------------------------------------

describe('sweep 5 K5: go-dark and decay rows are pruned', function()
    local function decayStack()
        local s = newStack()
        local f = fixture(s, { creatorCash = 500000, creatorBank = 200000 })
        Config.Limits.TargetCooldownAfterResolveSeconds = 0
        Config.Notifications.ParanoidAlert = false
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.Mode = 'rise'
        return s, f
    end

    it('drops the decay rows of ended contracts while decay is off, a few a pass', function()
        local s, f = decayStack()
        local a = place(s, f)
        local b = place(s, f, { targetCid = 'HITMAN01' })
        Env.addPlayer({ source = 5, citizenid = 'TARGET02', license = 'license:eee',
            firstname = 'Lee', lastname = 'Oak' })
        local paid = place(s, f, { targetCid = 'TARGET02' })
        s.impBoard.tick()
        eq(#s.storage.readRpRows('imp_decay'), 3)
        truthy(s.contracts.resolve(a.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled_by_creator'))
        truthy(s.contracts.resolve(b.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled_by_creator'))
        truthy(s.storage.compareSetContractState(paid.id, CH.STATE.ACTIVE, CH.STATE.COMPLETING))
        rawset(s.storage, '__rawFixture', true)
        Config.Improvements.ContractDecay.Enabled = false
        local Decay = require('server.imp_decay')
        local per = Decay.PRUNES_PER_PASS
        Decay.PRUNES_PER_PASS = 1
        local ok, err = pcall(function()
            Env.advance(60)
            s.impBoard.tick()
            eq(#s.storage.readRpRows('imp_decay'), 2, 'one a pass')
            Env.advance(60)
            s.impBoard.tick()
            Env.advance(60)
            s.impBoard.tick()
        end)
        Decay.PRUNES_PER_PASS = per
        truthy(ok, tostring(err))
        local left = s.storage.readRpRows('imp_decay')
        eq(#left, 1, 'both ended rows dropped')
        eq(left[1].contract_id, paid.id, 'the one being paid is kept')
    end)

    it('prunes rows from before a start whose first read raised', function()
        local s, _, c = taken()
        Config.Intel.GoDark.Enabled = true
        Config.Intel.GoDark.Cost = 50000
        Config.Intel.GoDark.Minutes = 30
        truthy(call('locationTip', 3, { id = c.id, shown = TIP }).ok)
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled_by_creator'))
        -- The restart: the store does not answer the start's read.
        local read = s.storage.readRpRows
        s.storage.readRpRows = function() error('lost connection') end
        restartTips(s)
        s.intelRules.resume()
        s.storage.readRpRows = read
        Env.advance(31 * 60)
        eq(s.intelRules.prune(), 1, 'read now, and the passed window pruned')
        eq(#s.storage.readRpRows('imp_dark'), 0)
    end)

    it('drops a go-dark row once its window has passed, though nobody asks again', function()
        local s, _, c = taken()
        Config.Intel.GoDark.Enabled = true
        Config.Intel.GoDark.Cost = 50000
        Config.Intel.GoDark.Minutes = 30
        truthy(call('locationTip', 3, { id = c.id, shown = TIP }).ok)
        truthy(call('goDark', 2, { id = c.id, shown = DARK }).ok)
        truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled_by_creator'))
        eq(#s.storage.readRpRows('imp_dark'), 1)
        Env.advance(600)
        s.intelRules.prune()
        eq(#s.storage.readRpRows('imp_dark'), 1, 'kept while the window it was paid for runs')
        Env.advance(30 * 60)
        s.intelRules.prune()
        eq(#s.storage.readRpRows('imp_dark'), 0, 'gone once it has passed')
    end)
end)

--------------------------------------------------------------------------
-- K6: the Ledger's refund on an expiry
--------------------------------------------------------------------------

describe('sweep 5 K6: an expiry\'s Ledger row counts the stakes forfeited', function()
    it('says what came back to the placer, the forfeited stake included and named', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000 })
        Env.players[3].PlayerData.money.bank = 50000
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken, staked')
        local before = Env.players[1].PlayerData.money.cash + bank(1)
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        local back = Env.players[1].PlayerData.money.cash + bank(1) - before
        eq(back, 7000, 'the reward and the stake came back')
        local row = s.ledger.entries('CREATOR1')[1]
        eq(row.kind, 'refunded')
        eq(row.amount, 7000, 'the Ledger says what came back')
        eq(row.stakes, 2000, 'and how much of it was stakes')
        eq(s.ledger.entries('HITMAN01')[1], nil, 'nothing on the hitman\'s Ledger')
    end)

    it('never lets the stakes read stop the ending: the row is skipped, the money still moves', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { reward = { baseline = { cash = 5000 } }, penaltyAmount = 2000 })
        Env.players[3].PlayerData.money.bank = 50000
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken, staked')
        local before = Env.players[1].PlayerData.money.cash + bank(1)
        local readEscrow, raised = s.storage.readEscrow, false
        s.storage.readEscrow = function(...)
            if debug.traceback():find('forfeitedStakes', 1, true) then
                raised = true
                error('lost connection')
            end
            return readEscrow(...)
        end
        local ran, ok = pcall(s.contracts.resolve, c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired')
        s.storage.readEscrow = readEscrow
        truthy(raised, 'the stakes read raised')
        truthy(ran and ok, 'the ending went through')
        eq(s.storage.readContract(c.id).state, CH.STATE.EXPIRED)
        eq(Env.players[1].PlayerData.money.cash + bank(1) - before, 7000, 'the money moved all the same')
    end)

    it('says no stakes on a contract nobody staked', function()
        local s = newStack()
        local f = fixture(s)
        local c = place(s, f, { reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired'))
        local row = s.ledger.entries('CREATOR1')[1]
        eq(row.amount, 5000)
        eq(row.stakes, nil)
    end)
end)

--------------------------------------------------------------------------
-- K7: the close command the server registered
--------------------------------------------------------------------------

describe('sweep 5 K7: /<panel>-close follows the name the server registered', function()
    it('sends the registered name with the open, and the client registers its close', function()
        local s = newStack()
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.aces[6] = { ['crimson.admin'] = true }
        -- The server started with a panel override; the client's config.lua
        -- still says the shipped name.
        Config.Admin.Commands.panel = 'opsadmin'
        s.bridges.install(s)
        Config.Admin.Commands.panel = 'hitmanadmin'
        truthy(Env.commands['opsadmin'], 'the server registered the override')
        Env.clientEvents = {}
        Env.commands['opsadmin'](6, {})
        local access
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminOpen' then access = event.args[1] end
        end
        truthy(access, 'opened')
        eq(access.command, 'opsadmin', 'the client is told the name in force')

        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:adminOpen', access)
        eq(Client.admin.isOpen(), true)
        local close = Env.commands['opsadmin-close']
        truthy(close, '/opsadmin-close beside the command that opened it')
        close(0, {})
        eq(Client.admin.isOpen(), false)
        eq(Client.focus[#Client.focus].focus, false, 'focus given back')
    end)

    it('registers nothing from a name that is not a command name', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:adminOpen', { canWrite = true, command = 'bad name; quit' })
        eq(Env.commands['bad name; quit-close'], nil)
        truthy(Env.commands['hitmanadmin-close'], 'the config one still closes it')
    end)
end)

--------------------------------------------------------------------------
-- K8: one serial a line, across a restart
--------------------------------------------------------------------------

describe('sweep 5 K8: a scrubbed serial survives a restart', function()
    it('gives the same line the same serial after a restart, and another line another', function()
        local s = newStack()
        Config.Improvements.SerialScrub.Enabled = true
        local line = { id = 'ln-k8', contract_id = 'ct-missing', source = CH.SOURCE.WEAPON,
            item = 'WEAPON_PISTOL', taken_from = 'CREATOR1' }
        local first = s.impScrub.scrub('HITMAN01', line, { serial = 'ORIG00001' })
        truthy(first and first.serial ~= 'ORIG00001', 'scrubbed')
        truthy(first.serial:match('^%d%d%d%d%d%d%u%u%u%d%d%d%d%d%d$'), 'in ox_inventory\'s form: '
            .. first.serial)
        s.impScrub.init({ storage = s.storage, audit = s.audit })
        local again = s.impScrub.scrub('HITMAN01', line, { serial = 'ORIG00001' })
        eq(again.serial, first.serial, 'the same serial after the restart')
        local other = s.impScrub.scrub('HITMAN01', { id = 'ln-k8b', contract_id = 'ct-missing',
            source = CH.SOURCE.WEAPON, item = 'WEAPON_PISTOL', taken_from = 'CREATOR1' },
            { serial = 'ORIG00001' })
        truthy(other.serial ~= first.serial, 'another line, another serial')
        falsy(first.serial:find('ln-k8', 1, true) or first.serial:find('ORIG', 1, true),
            'nothing of the line or the original in it')
    end)
end)

--------------------------------------------------------------------------
-- K9: the decay count across a walk-away and a freeze
--------------------------------------------------------------------------

describe('sweep 5 K9: the decay count keeps the untaken stretch before a freeze', function()
    it('counts the time untaken between the walk-away and the freeze', function()
        local s = newStack()
        local f = fixture(s, { creatorCash = 500000, creatorBank = 200000 })
        Config.Notifications.ParanoidAlert = false
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.Mode = 'rise'
        local c = place(s, f)
        s.impBoard.tick()
        Env.advance(600)                                       -- 10 min untaken
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        Env.advance(3000)
        s.impBoard.tick()                                      -- the count stands from the taking
        Env.advance(100)
        truthy(s.contracts.abandon(f.hitman, c.id), 'walked away')
        Env.advance(2400)                                      -- 40 min untaken
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'probe'))
        Env.advance(60)
        s.impBoard.tick()                                      -- held
        Env.advance(7200)
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01', 'done'))
        s.impBoard.tick()                                      -- runs again: 50 min counted
        local before = s.escrow.moneyValue(c.id)
        Env.advance(660)
        s.impBoard.tick()
        eq(s.escrow.moneyValue(c.id), before + 1000, 'the step once an hour untaken is up')
    end)
end)

--------------------------------------------------------------------------
-- K10: coverage
--------------------------------------------------------------------------

describe('sweep 5 K10: lookup handles and a pulled-back extension', function()
    local function ask(src, op, data)
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(Env.events['crimson-hitman:admin'], { op = op, data = data or {}, __rid = 9 })
        _G.source = nil
        truthy(fired, 'the net event must not raise: ' .. tostring(err))
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:adminResult' then return event.args[1] end
        end
        return nil
    end

    local function staffed()
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.addPlayer({ source = 8, citizenid = 'ADMIN002', license = 'license:ADMIN002',
            firstname = 'Ida', lastname = 'Hall' })
        Env.aces[6] = { ['crimson.admin'] = true }
        Env.aces[8] = { ['crimson.admin'] = true }
        Config.Cooldowns.admin = { per = 10, burst = 1000 }
        Config.Cooldowns.adminWrite = { per = 10, burst = 1000 }
        s.bridges.install(s)
        return s, f
    end

    it('prunes every staff member\'s expired lookup handles, not only the asker\'s', function()
        local s = staffed()
        truthy(ask(6, 'player', { subject = 2 }).ok)
        truthy(ask(6, 'player', { subject = 3 }).ok)
        eq(s.panel._heldRefs()[6], 2)
        Env.advance(5 * 60)
        truthy(ask(8, 'player', { subject = 2 }).ok)
        eq(s.panel._heldRefs()[6], 2, 'not yet run out: kept')
        Env.advance(6 * 60)
        truthy(ask(8, 'player', { subject = 3 }).ok)
        eq(s.panel._heldRefs()[6], nil, 'the other staff member\'s, run out, gone')
        eq(s.panel._heldRefs()[8], 2, 'the asker\'s own still in their time')
    end)

    it('pulls the deadline back to the lifetime when it ends lower than planned', function()
        local s, f = staffed()
        local c = place(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        local row = s.storage.readContract(c.id)
        s.storage.setContractFields(c.id, { expires_at = row.deadline_at + 100 })
        local expires = row.deadline_at + 100
        -- The lifetime is reached by less than planned: another change
        -- took the room under the ceiling first.
        local add = s.storage.addToExpires
        s.storage.addToExpires = function(id, _, ceiling) return add(id, 1000, ceiling) end
        local ok, err, detail = s.admin.adjustDeadline(0, c.id, 7200, 'ticket')
        s.storage.addToExpires = add
        truthy(ok, tostring(err))
        local after = s.storage.readContract(c.id)
        eq(after.expires_at, expires + 1000, 'the lifetime as it ended')
        eq(after.deadline_at, after.expires_at, 'the deadline held to it, not past it')
        eq(detail.lifetime, 'capped')
        eq(detail.new_deadline, after.deadline_at, 'the record says where it ended')
    end)
end)
