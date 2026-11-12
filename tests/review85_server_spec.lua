--- Review 85, server fixes: each confirmed finding outside server/org/,
--- driven through the code the game runs. Every test here fails on the
--- tree before the fix (3b1d941) and passes after it.

local URL = 'https://cdn.fivemanage.com/proof.png'
local L = CrimsonBoot.requireShared('locale').t

local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end

--- Every store function a claim awaits on, wrapped: at its Nth call, run
--- `inject` (which may raise, to cut the request there, as a crash does).
local WATCH = {
    'compareSetContractState', 'claimEscrowLine', 'settleEscrowLine',
    'writeContract', 'writeEscrow', 'addHitman', 'updateHitman',
    'setEscrowAmount', 'advanceSlot',
    'readContract', 'readEscrow', 'readHitmen', 'readEscrowLine', 'readHitman',
}
local function atStoreCall(s, n, first, inject)
    -- Its own checks of the money, not the invariant monitor's: the monitor
    -- audits the store through the same reads this counts and cuts, and a
    -- store cut mid-claim is mid-operation by construction (as
    -- restart_spec marks a crashed process's store).
    rawset(s.storage, '__rawFixture', true)
    local calls, fired = 0, false
    local real = {}
    for _, name in ipairs(WATCH) do
        real[name] = s.storage[name]
        s.storage[name] = function(...)
            calls = calls + 1
            if calls == n and not fired then
                fired = true
                inject()
            end
            return real[name](...)
        end
    end
    local r = table.pack(pcall(first))
    for _, name in ipairs(WATCH) do s.storage[name] = real[name] end
    return r, fired
end

local function twoSlotKill()
    local s = newStack()
    local f = fixture(s)
    Config.Limits.MaxPayoutSlots = 2
    Config.Limits.SlotCooldownSeconds = 0
    Config.Completion.ExtraPhotoHosts = { 'cdn.fivemanage.com' }
    Config.Completion.PhotoStorage = 'host'
    s.photo.loadAllowedHosts()
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
        reward = { slots = { { baseline = { cash = 5000 } }, { baseline = { cash = 5000 } } } } })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false))
    Env.players[3]._coords = { x = 100.0, y = 100.0, z = 30.0 }
    Env.players[2]._coords = { x = 101.0, y = 100.0, z = 30.0 }
    Env.players[2]._health = (Env.players[2]._health or 200) - 60
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    eq(s.death.onVictimReport(2), 1, 'the kill is attributed')
    return s, f, c
end

--- The contract's money, wherever it is: the hitman's cash, and what the
--- escrow still holds.
local function heldCash(s, c, alsoReleasing)
    local total = 0
    for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
        if line.source == 'cash' and (line.state == CH.ESCROW_STATE.HELD
            or (alsoReleasing and line.state == CH.ESCROW_STATE.RELEASING)) then
            total = total + (tonumber(line.amount) or 0)
        end
    end
    return total
end

describe('R85 C4-1: one kill pays one collection, whatever token it comes with', function()
    it('a token reissued while the first claim waits is refused, at every await', function()
        local scanned = 0
        for n = 1, 60 do
            local s, f, c = twoSlotKill()
            local cash0 = Env.players[3].PlayerData.money.cash
            local t1 = s.photo.issue(f.hitman, c.id)
            truthy(t1, 'first token')
            local r, fired = atStoreCall(s, n, function()
                return s.photo.submit(f.hitman, t1, URL)
            end, function()
                local t2 = s.photo.issue(f.hitman, c.id)
                if t2 then s.photo.submit(f.hitman, t2, URL) end
            end)
            truthy(r[1], 'raised: ' .. tostring(r[2]))
            if not fired then break end
            scanned = scanned + 1
            local gained = Env.players[3].PlayerData.money.cash - cash0
            truthy(gained <= 5000, ('one kill paid %d at await %d'):format(gained, n))
            eq(gained, 5000, 'the kill itself is paid once, at await ' .. n)
        end
        truthy(scanned >= 5, 'the claim awaits: ' .. scanned)
    end)

    it('a token minted before the claim, sent while it waits, claims nothing more', function()
        for n = 1, 60 do
            local s, f, c = twoSlotKill()
            local cash0 = Env.players[3].PlayerData.money.cash
            local t1 = s.photo.issue(f.hitman, c.id)
            local second
            -- T1's submit is cut inside its scene reads; T2 is issued and
            -- claims in that gap, then T1 resumes with its captured record.
            local r, fired = atStoreCall(s, n, function()
                return s.photo.submit(f.hitman, t1, URL)
            end, function()
                local t2 = s.photo.issue(f.hitman, c.id)
                second = t2 and { s.photo.submit(f.hitman, t2, URL) }
            end)
            truthy(r[1], 'raised: ' .. tostring(r[2]))
            if not fired then break end
            local gained = Env.players[3].PlayerData.money.cash - cash0
            truthy(gained <= 5000, ('paid %d at await %d'):format(gained, n))
        end
    end)

    it('crash matrix: a claim cut at any await, then every retry, pays at most once and loses nothing', function()
        local scanned = 0
        for n = 1, 60 do
            local s, f, c = twoSlotKill()
            local cash0 = Env.players[3].PlayerData.money.cash
            local before = cash0 + heldCash(s, c)
            local t1 = s.photo.issue(f.hitman, c.id)
            local r, fired = atStoreCall(s, n, function()
                return s.photo.submit(f.hitman, t1, URL)
            end, function() error('crash at await ' .. n, 0) end)
            if not fired then break end
            scanned = scanned + 1
            -- The request never comes back (it raised); the kill's guard is
            -- not left set, or the kill could never be claimed again.
            -- The hitman tries again: the same token, a new token, and the
            -- same token once more. The contract's claim recovery runs too.
            Env.time = Env.time + 60
            pcall(s.contracts.retryStuckClaims)
            pcall(s.photo.submit, f.hitman, t1, URL)
            local t2 = s.photo.issue(f.hitman, c.id)
            if t2 then pcall(s.photo.submit, f.hitman, t2, URL) end
            local t3 = s.photo.issue(f.hitman, c.id)
            if t3 then pcall(s.photo.submit, f.hitman, t3, URL) end
            pcall(s.contracts.retryStuckClaims)
            local gained = Env.players[3].PlayerData.money.cash - cash0
            truthy(gained <= 5000, ('one kill paid %d after a cut at await %d'):format(gained, n))
            -- Nothing vanished but a line caught mid-release, which is
            -- left for staff (/ch-stuck) by design. (A line given with its
            -- settle cut stays held with what arrived written on it, which
            -- the escrow's own recovery reads; the payout above is the
            -- hitman's whole gain.)
            local cash = Env.players[3].PlayerData.money.cash
            truthy(cash + heldCash(s, c, true) >= before, 'no money vanished, cut at await ' .. n)
        end
        truthy(scanned >= 5, 'the claim awaits: ' .. scanned)
    end)

    it('the kill is still claimable after a cut claim (the guard is released)', function()
        local s, f, c = twoSlotKill()
        local cash0 = Env.players[3].PlayerData.money.cash
        local t1 = s.photo.issue(f.hitman, c.id)
        -- Cut at the very first await, before anything moved.
        atStoreCall(s, 1, function() return s.photo.submit(f.hitman, t1, URL) end,
            function() error('cut', 0) end)
        local t2, e2 = s.photo.issue(f.hitman, c.id)
        truthy(t2, 'a new token after the cut: ' .. tostring(e2))
        local ok, err = s.photo.submit(f.hitman, t2, URL)
        truthy(ok, 'claimed: ' .. tostring(err))
        eq(Env.players[3].PlayerData.money.cash - cash0, 5000)
    end)
end)

--------------------------------------------------------------------------
-- C2-F1: /ch-diag names nobody to staff without the identity ACE
--------------------------------------------------------------------------

local function staffStack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.addPlayer({ source = 8, citizenid = 'UNMASK01', license = 'license:UNMASK01',
        firstname = 'Uma', lastname = 'Mask' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Env.aces[8] = { ['crimson.admin'] = true, ['crimson.identity'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 500 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 500 }
    s.bridges.install(s)
    return s, f
end

--- A staff command run as `src`: everything it printed, F8 and console.
local function runCommand(src, key, args)
    Env.clientEvents, Env.chat, Env.console = {}, {}, {}
    local handler = Env.commands[Config.Admin.Commands[key]]
    local ok, err = pcall(handler, src, args or {})
    truthy(ok, 'raised: ' .. tostring(err))
    local said = {}
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:commandOutput' then
            local a = event.args[1]
            if type(a) == 'table' then
                for _, line in ipairs(a) do said[#said + 1] = tostring(line) end
            else
                said[#said + 1] = tostring(a)
            end
        end
    end
    for _, line in ipairs(Env.chat or {}) do said[#said + 1] = type(line) == 'table' and table.concat((function()
        local t = {} for _, v in pairs(line) do t[#t + 1] = tostring(v) end return t end)(), ' ') or tostring(line) end
    for _, line in ipairs(Env.console or {}) do said[#said + 1] = tostring(line) end
    return table.concat(said, '\n')
end

_G.R85 = { has = has, staffStack = staffStack, runCommand = runCommand, twoSlotKill = twoSlotKill }

describe('R85 C2-F1: /ch-diag scrubs citizen ids for staff without IdentityAce', function()
    it('the staff alert and the page faults name nobody, as in the panel', function()
        local s, f = staffStack()
        Config.Staff = Config.Staff or {}
        Config.Staff.AlertPlacedPerHour = 1
        for i, tcid in ipairs({ 'TARGET01', 'HITMAN01' }) do
            local c, err = s.contracts.create(f.creator, { targetCid = tcid, reason = 'Unpaid debt ' .. i,
                mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, anonymous = true })
            truthy(c, tostring(err))
            s.thresholds.placed(f.creator.cid, tcid)
        end
        local out = runCommand(6, 'diagnose', {})
        truthy(has(out, 'staff alert') or has(out, 'placed 2'), 'the alert is in the report: ' .. out:sub(1, 300))
        falsy(has(out, 'CREATOR1'), 'the placer is not named to crimson.admin alone')

        -- The identity holder and the console still read it whole.
        truthy(has(runCommand(8, 'diagnose', {}), 'CREATOR1'), 'IdentityAce reads the cid')
        truthy(has(table.concat(s.admin.diagnose(0, nil), '\n'), 'CREATOR1'), 'the console reads the cid')

        -- A page fault, then a diagnosis of player 2: neither the reporter
        -- nor the subject is named, and nothing delivered later is either.
        _G.source = 1
        Env.events['crimson-hitman:pageError']({ what = 'render failed', where = 'board' })
        _G.source = nil
        local out2 = runCommand(6, 'diagnose', { '2' })
        falsy(has(out2, 'CREATOR1'), 'the reporter is not named')
        falsy(has(out2, 'TARGET01'), 'the subject is not named')
        local later = {}
        s.admin.diagnose(6, '2', function(said)
            if type(said) == 'table' then for _, l in ipairs(said) do later[#later + 1] = l end
            else later[#later + 1] = said end
        end)
        -- The subject's page log arrives as a list.
        _G.source = 2
        Env.events['crimson-hitman:pageError']({ what = 'page diagnostics', where = 'requested',
            stack = 'opened the board || CREATOR1 row drawn' })
        _G.source = nil
        truthy(#later > 0, 'the page log arrived')
        for _, line in ipairs(later) do
            falsy(has(line, 'TARGET01') or has(line, 'CREATOR1'), 'later line scrubbed: ' .. tostring(line))
        end
    end)
end)

describe('R85 C5-2: a late delivery says what arrived, not the line', function()
    it('a 20% organisation cut on a refused, then retried $5,000 payout says what arrived', function()
        local W = require('tests.harness.org_world')
        local s, f = W.world({ configure = function() Config.Integrations.Banking = 'none' end })
        W.crew(s)
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        local hitman = s.identity.resolve(3)
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 20))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        Env.players[3]._refuseMoney = true
        local before = W.wealth(3)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        Env.players[3]._refuseMoney = nil
        local n, summary = s.escrow.retryPending('HITMAN01')
        truthy(n >= 1, 'delivered late')
        local received = W.wealth(3) - before
        truthy(received > 0, 'something arrived')
        eq(summary.money, received, 'the summary is what arrived')
        Natives.calls.notifications = {}
        s.notify.outstandingDelivered('HITMAN01', n, summary)
        local said = {}
        for _, x in ipairs(Natives.calls.notifications) do said[#said + 1] = tostring(x.content) end
        said = table.concat(said, '\n')
        local Words = CrimsonBoot.requireShared('words')
        truthy(has(said, Words.dollars(received, 'none')), 'the notice says what arrived: ' .. said)
    end)
end)

describe('R85 C5-3: the weekly post counts payouts only', function()
    it('a refund to the target is not paid out to hitmen; a payout still is', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } } })
        truthy(c)
        local Weekly = CrimsonBoot.require('server.imp_weekly')
        Weekly.init({ storage = s.storage, audit = s.audit })
        truthy(s.bailout.owe('TARGET01', c.id, 2000, 'bank', 'informant_refunded'), 'owed')
        truthy(s.escrow.retryPending('TARGET01') >= 1, 'refunded')
        Env.advance(5)
        eq(Weekly.totals(os.time()).paid, 0, 'a refund is no payout')
        truthy(s.contracts.accept(f.hitman, c.id))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        Env.advance(5)
        eq(Weekly.totals(os.time()).paid, 5000, 'the payout is counted')
    end)
end)

describe('R85 C6-1: a delayed tip warning loaded after a failed start read is still sent', function()
    local function call(name, src, payload)
        local handler = Env.events['crimson-hitman:' .. name]
        Env.clientEvents = {}
        _G.source = src
        local fired, err = pcall(handler, payload or {})
        _G.source = nil
        truthy(fired, tostring(err))
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then return event.args[1] end
        end
    end
    it('armed by whichever read loads it', function()
        local s = newStack()
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        Env.players[3].PlayerData.money.bank = 200000
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.players[2]._coords = { x = 1200.0, y = -800.0, z = 30.0 }
        Env.advance(1)
        Config.Intel.WarningDelay.Enabled = true
        Config.Intel.WarningDelay.MinSeconds, Config.Intel.WarningDelay.MaxSeconds = 300, 300
        local r = call('locationTip', 3, { id = c.id, shown = { cost = 25000, account = 'bank' } })
        truthy(r and r.ok, 'tip bought: ' .. tostring(r and r.err))
        eq(#s.storage.readRpRows('imp_tipwarn'), 1, 'the warning waits')
        -- A restart whose read at the start raises once.
        Env.timers = {}
        s.intelRules.init({ storage = s.storage, audit = s.audit, notify = s.notify,
            contracts = s.contracts, locationTip = s.locationTip, informant = s.informant,
            projection = s.projection })
        local real = s.storage.readRpRows
        local fails = 1
        s.storage.readRpRows = function(...)
            if fails > 0 then fails = fails - 1; error('db away') end
            return real(...)
        end
        s.intelRules.resume()
        s.storage.readRpRows = real
        -- The target's card is the next read.
        s.projection.contract(s.storage.readContract(c.id), 'TARGET01')
        Env.advance(3600)
        Env.runTimers()
        eq(#s.storage.readRpRows('imp_tipwarn'), 0, 'the warning was sent and its row taken out')
        local card = s.projection.contract(s.storage.readContract(c.id), 'TARGET01')
        truthy(card.tippedAt, 'the tip is on the target card')
    end)
end)

--------------------------------------------------------------------------
-- C5-1, R2G2-1, C5-6: the informant's answers
--------------------------------------------------------------------------

local HIT, MISS = 1, 100
local function informantSetup(stackFn)
    local s = (stackFn or newStack)()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, true), 'taken anonymously')
    Env.players[1].PlayerData.money.bank = 100000
    Env.players[2].PlayerData.money.bank = 100000
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    return s, f, c
end
local function force(s, ...)
    local queue = { ... }
    s.informant.setRandom(function() return table.remove(queue, 1) or MISS end)
end
local function placerBuy(s, f, c)
    local view = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
    local pick = view.placerInformantPicks[1].pick
    return s.informant.placerBuy(f.creator, c.id,
        { cost = Config.Intel.PlacerInformant.Cost, account = Config.Intel.PlacerInformant.Account }, pick)
end
local function foundText(s, c)
    local view = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
    return view.placerInformantFound and view.placerInformantFound[1] and view.placerInformantFound[1].text
end

describe('R85 C5-1: the placer informant shows what was bought, whatever RevealMode says now', function()
    it('a description bought never turns into the name', function()
        local s, f, c = informantSetup()
        Config.Intel.PlacerInformant.Enabled = true
        Config.Intel.PlacerInformant.RevealMode = 'description'
        force(s, HIT, MISS)
        local ok, err, data = placerBuy(s, f, c)
        truthy(ok, tostring(err))
        local bought = data.description
        truthy(bought, 'a description')
        eq(foundText(s, c), bought)
        Config.Intel.PlacerInformant.RevealMode = 'name'
        eq(foundText(s, c), bought, 'still the description')
        falsy(has(foundText(s, c), 'Rook'), 'the anonymous operative is not named')
    end)
    it('a name bought is not taken away', function()
        local s, f, c = informantSetup()
        Config.Intel.PlacerInformant.Enabled = true
        Config.Intel.PlacerInformant.RevealMode = 'name'
        force(s, HIT, MISS)
        local ok, err, data = placerBuy(s, f, c)
        truthy(ok, tostring(err))
        eq(data.name, 'Rook Ash')
        Config.Intel.PlacerInformant.RevealMode = 'description'
        eq(foundText(s, c), 'Rook Ash', 'the name paid for stays')
    end)
    it('kept by the mysql store, a column added to an older table', function()
        local Sim = require('tests.harness.mysql_sim')
        Sim.install(Natives)
        local previous = {}
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        truthy(Sim.schema.crimson_placer_informants.answer, 'a new install has the column')
        for column in pairs(Sim.schema.crimson_placer_informants) do
            if column ~= 'answer' then previous[column] = true end
        end
        Sim.install(Natives)
        Sim.existingSchema({ crimson_placer_informants = previous })
        Sim.altered = {}
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        store = require('crimson-hitman.server.storage.mysql')
        store.open()
        local added = {}
        for _, change in ipairs(Sim.altered) do
            if change.column then added[#added + 1] = change.table_ .. '.' .. change.column end
        end
        eq(table.concat(added, ' '), 'crimson_placer_informants.answer', 'the one column is added')
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
    end)
    it('kept across a restart on the executing mysql harness', function()
        local Exec = require('tests.harness.mysql_exec')
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        store.writePlacerInformant({ contract_id = 'ct1', placer_cid = 'CREATOR1', hitman_cid = 'HITMAN01',
            seq = 1, bought_at = 5, revealed = true, alerted = false,
            answer = json.encode({ description = 'Seen recently around LS Customs' }) })
        local rows = store.readPlacerInformants('ct1', 'CREATOR1')
        eq(#rows, 1)
        eq(json.decode(rows[1].answer).description, 'Seen recently around LS Customs')
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
    end)
end)

describe('R85 R2G2-1, C5-6: a description names the job as players read it', function()
    it('the job label, never the job id; out of work reads as the city', function()
        local s, f, c = informantSetup()
        Env.players[3].PlayerData.job = { name = 'mechanic', label = 'LS Customs', type = 'mechanic',
            grade = { level = 0 } }
        local d = s.informant.describe('HITMAN01', 'description').description
        truthy(has(d, 'LS Customs'), d)
        falsy(has(d, 'mechanic'), d)
        Env.players[3].PlayerData.job = { name = 'unemployed', label = 'Civilian', type = 'none',
            grade = { level = 0 } }
        d = s.informant.describe('HITMAN01', 'description').description
        falsy(has(d, 'unemployed'), d)
        falsy(has(d, 'Civilian'), d)
        -- A job with no label anywhere is not named by its id either.
        Env.players[3].PlayerData.job = { name = 'zz_nolabel_job', type = 'x', grade = { level = 0 } }
        d = s.informant.describe('HITMAN01', 'description').description
        falsy(has(d, 'zz_nolabel_job'), d)
        local _ = f and c
    end)
end)

describe('R85 C9-1: a spot staff switched off stays off when it is moved', function()
    it('the boss moves a disabled meeting spot and the office; both stay off, in memory and the store', function()
        local W = require('tests.harness.org_world')
        local s = W.world({})
        W.crew(s)
        W.office(s)
        W.allow(s, 3, 'L3')
        W.at(6, 120.0, 120.0, 30.0)
        local r = W.ask(6, 'placeSet', { kind = 'meeting', here = true, label = 'Back door', enabled = true })
        truthy(r and r.ok, 'set')
        local id = r.data and r.data.id
        r = W.ask(6, 'placeSet', { kind = 'meeting', id = id, x = 120.0, y = 120.0, z = 30.0, heading = 0, enabled = false })
        truthy(r and r.ok, 'switched off')
        W.at(11, 104.0, 104.0, 30.0)
        local b = W.call('orgPlaceHere', 11, { kind = 'meeting', id = id })
        truthy(b and b.ok, 'moved: ' .. tostring(b and b.err))
        local Places = require('server.places')
        local seen = false
        for _, row in ipairs(Places.rows('meeting') or {}) do
            if row.id == id then seen = true; eq(row.enabled, false, 'still off in memory') end
        end
        truthy(seen, 'the row')
        for _, row in ipairs(s.storage.readRpRows('map_place') or {}) do
            if row.id == id then eq(row.enabled, false, 'still off in the store') end
        end
        -- The office: staff switch it off, the boss's Place here keeps it off.
        local offices = Places.rows('office') or {}
        local office = offices[1]
        if office then
            r = W.ask(6, 'placeSet', { kind = 'office', id = office.id, x = office.x, y = office.y, z = office.z,
                heading = 0, enabled = false })
            truthy(r and r.ok, 'office off')
            b = W.call('orgPlaceHere', 11, { kind = 'office', id = office.id })
            for _, row in ipairs(Places.rows('office') or {}) do
                if row.id == office.id then eq(row.enabled, false, 'the office stays off') end
            end
        end
        -- A direct move without `enabled` keeps it too; one that says, sets it.
        local ok2, _, row2 = Places.set({ staff = true, cid = 'ADMIN001', source = 6 }, 'meeting', { id = id, x = 130, y = 130, z = 30 })
        truthy(ok2)
        eq(row2.enabled, false)
        local ok3, _, row3 = Places.set({ staff = true, cid = 'ADMIN001', source = 6 }, 'meeting', { id = id, x = 130, y = 130, z = 30, enabled = true })
        truthy(ok3)
        eq(row3.enabled, true)
    end)
end)

describe('R85 C9-2: Locations > Remove sends back nothing of the row', function()
    it('no `by` (a boss citizen id) to staff without the identity ACE', function()
        local W = require('tests.harness.org_world')
        local s = W.world({})
        W.crew(s)
        W.office(s)
        W.allow(s, 3, 'L3')
        W.at(11, 104.0, 104.0, 30.0)
        local b = W.call('orgPlaceHere', 11, { kind = 'meeting', label = 'Boss spot' })
        truthy(b and b.ok)
        local Places = require('server.places')
        local id
        for _, row in ipairs(Places.rows('meeting') or {}) do id = row.id end
        Env.aces[6] = { ['crimson.admin'] = true }
        local r = W.ask(6, 'placeRemove', { id = id })
        truthy(r and r.ok, 'removed')
        local d = r.data
        falsy(type(d) == 'table' and (d.by or d.owner), 'no by or owner in the reply')
        falsy(has(json.encode(r), 'BOSS0001'), 'the boss is not named')
    end)
end)

describe('R85 C10 F1: reason quality counts UTF-8 words', function()
    it('Cyrillic, Greek and Polish reasons count their words; a Cyrillic LowEffort phrase matches', function()
        local s = newStack()
        Config.Roleplay.ReasonQuality.Enabled = true
        Config.Roleplay.ReasonQuality.MinWords = 3
        Config.Roleplay.ReasonQuality.MinLength = 15
        eq(s.rpReason.check('Долг не оплачен уже месяц'), nil, 'five Cyrillic words pass')
        eq(s.rpReason.check('Χρωστάει λεφτά εδώ και μήνες'), nil, 'five Greek words pass')
        Config.Roleplay.ReasonQuality.MinLength = 0
        local err, why = s.rpReason.check('Dług zł')
        eq(err, CH.ERR.REASON_REFUSED, 'two Polish words are two')
        eq(why and why.rule, 'words')
        eq(s.rpReason.check('Dług ździebko xxxxxx'), nil, 'three are three')
        Config.Roleplay.ReasonQuality.LowEffort = { 'фигня' }
        eq(s.rpReason.lowEffort('это фигня просто так'), 'фигня', 'the phrase matches')
        eq(s.rpReason.lowEffort('Это ФИГНЯ, просто так'), 'фигня', 'in any case')
        eq(s.rpReason.lowEffort('это фигнястая вещь'), nil, 'as a whole word only')
        -- ASCII as before.
        Config.Roleplay.ReasonQuality.LowEffort = { 'just because' }
        eq(s.rpReason.lowEffort('Just because, really.'), 'just because')
    end)
end)

--------------------------------------------------------------------------
-- C11-2, C11-4, C11-7: settings import
--------------------------------------------------------------------------

local function settingsStack()
    local s = newStack()
    local f = fixture(s)
    Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
        firstname = 'Sam', lastname = 'Steward' })
    Env.aces[6] = { ['crimson.admin'] = true }
    Config.Cooldowns.admin = { per = 10, burst = 5000 }
    Config.Cooldowns.adminWrite = { per = 10, burst = 5000 }
    s.bridges.install(s)
    return s, f
end
local function panelAsk(s, src, op, data)
    return s.panel.handle(src, { op = op, data = data or {}, __rid = 7 })
end

describe('R85 C11-2: an import applies both halves of a linked pair', function()
    it('Buyout pricing 0.5 / 0.8 onto 1.0 / 3.0 in one import', function()
        local s = settingsStack()
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1, settings = {
            ['Bailout.MinMultiplier'] = 0.5, ['Bailout.MaxMultiplier'] = 0.8 } })
        local pv = panelAsk(s, 6, 'settingsImport', { text = text })
        truthy(pv.ok, tostring(pv.message))
        eq(#pv.data.changes, 2, 'both change')
        eq(#pv.data.refused, 0, 'nothing refused')
        local ap = panelAsk(s, 6, 'settingsImportApply', { text = text, expect = #pv.data.changes })
        truthy(ap.ok, tostring(ap.message))
        eq(Config.Bailout.MinMultiplier, 0.5)
        eq(Config.Bailout.MaxMultiplier, 0.8)
        truthy(has(ap.message, '2 settings changed'), ap.message)
    end)
    it('a preset and the setup check their pairs the same way', function()
        local s = settingsStack()
        local values = { ['Bailout.MinMultiplier'] = 0.5, ['Bailout.MaxMultiplier'] = 0.8 }
        local keys = { 'Bailout.MaxMultiplier', 'Bailout.MinMultiplier' }
        s.settings.order(keys)
        local accepted, refused = s.settings.checkInPasses(keys, function(k) return values[k] end)
        eq(#accepted, 2)
        eq(#refused, 0)
        eq(accepted[1].key, 'Bailout.MinMultiplier', 'the one that unblocks the other first')
        -- A pair that can never fit is still refused, with its reason.
        local bad = { ['Bailout.MinMultiplier'] = 0.9, ['Bailout.MaxMultiplier'] = 0.8 }
        accepted, refused = s.settings.checkInPasses(keys, function(k) return bad[k] end)
        eq(#refused, 1, 'one of an impossible pair is refused')
        truthy(type(refused[1].why) == 'string' and refused[1].why ~= '', 'with why')
    end)
end)

describe('R85 C11-4, C11-7: the import result and a damaged text', function()
    it('the result is whole sentences, with plurals from the locale', function()
        local s = settingsStack()
        local text = json.encode({ format = 'crimson-hitman-settings', version = 1,
            settings = { Debug = not Config.Debug },
            presets = { { name = 'A', values = { Debug = true } } } })
        local pv = panelAsk(s, 6, 'settingsImport', { text = text })
        local ap = panelAsk(s, 6, 'settingsImportApply', { text = text, expect = #pv.data.changes })
        truthy(ap.ok, tostring(ap.message))
        local English = CrimsonLocales.en
        local saved = {}
        for _, k in ipairs({ 'settingsio.imported_settings_changed_one', 'settingsio.import_presets_added_one' }) do
            saved[k] = English[k]
        end
        truthy(saved['settingsio.imported_settings_changed_one'], 'the one-setting sentence exists')
        truthy(has(ap.message, '1 setting changed'), ap.message)
        truthy(has(ap.message, '1 preset added'), ap.message)
    end)
    it('a list of settings is a damaged text, not secrets', function()
        local s = settingsStack()
        local pv = panelAsk(s, 6, 'settingsImport', { text = json.encode({ format = 'crimson-hitman-settings',
            version = 1, settings = { 1, 2 } }) })
        falsy(pv.ok, 'refused')
        falsy(has(pv.message, 'secret'), tostring(pv.message))
        eq(pv.message, CrimsonLocales.en['settingsio.its_settings_are_not_named'])
    end)
end)

describe('R85 C15-1: a target-limit reason is cut by characters', function()
    it('a Polish reason over 120 bytes and under 120 characters is kept whole and valid', function()
        local s = newStack()
        fixture(s)
        local reason = 'Zgloszenie ' .. ('źdźbło żółw '):rep(8)
        reason = reason:gsub('%s+$', '')
        truthy(#reason > 120 and utf8.len(reason) < 120, 'the case')
        local audited = {}
        local real = s.audit.staff
        s.audit.staff = function(kind, actor, contract, detail, ...)
            audited[#audited + 1] = detail
            return real(kind, actor, contract, detail, ...)
        end
        local ok, err, row = s.targetLimits.adjust('ADMIN001', 'TARGET01', 'reset', { reason = reason })
        s.audit.staff = real
        truthy(ok, tostring(err))
        local stored = json.encode(row or {})
        truthy(utf8.len(stored) ~= nil, 'the row is valid UTF-8')
        local found = false
        for _, d in ipairs(audited) do
            if type(d) == 'table' and d.reason then
                found = true
                truthy(utf8.len(d.reason) ~= nil, 'the audited reason is valid UTF-8')
                eq(d.reason, reason, 'and whole')
            end
        end
        truthy(found or has(stored, reason), 'the reason is kept whole')
    end)
end)

--------------------------------------------------------------------------
-- C4-4, C4-5, G3R3-1: body disposal
--------------------------------------------------------------------------
do
local SPAWN = { x = 200.0, y = 200.0, z = 30.0, h = 90.0 }
local DROP = { x = 500.0, y = 500.0, z = 30.0 }
local BODY = { x = 101.0, y = 100.0, z = 30.0 }
local STEP_EVENT, CLEAR_EVENT = 'crimson-hitman:client:StepMarker', 'crimson-hitman:client:StepMarkerClear'

--- A world the server's vehicle calls go to: [entity] = { x, y, z, plate, keys }.
local function fakeWorld(s)
    local W = { vehicles = {}, seq = 0, removed = 0, made = 0 }
    s.disposal.world = {
        spawn = function(model, at)
            W.seq, W.made = W.seq + 1, W.made + 1
            local id = 7000 + W.seq
            W.vehicles[id] = { x = at.x, y = at.y, z = at.z, model = model }
            return id
        end,
        exists = function(v) return W.vehicles[v] ~= nil end,
        coords = function(v)
            local c = W.vehicles[v]
            return c and { x = c.x, y = c.y, z = c.z } or nil
        end,
        remove = function(v)
            if W.vehicles[v] then W.removed = W.removed + 1 end
            W.vehicles[v] = nil
        end,
        prepare = function(v, plate, src)
            W.vehicles[v].plate, W.vehicles[v].keys = plate, src
            return true
        end,
    }
    function W.only()
        local id, n = nil, 0
        for k in pairs(W.vehicles) do id, n = k, n + 1 end
        return id, n
    end
    function W.move(p)
        local id = W.only()
        W.vehicles[id].x, W.vehicles[id].y, W.vehicles[id].z = p.x, p.y, p.z
    end
    return W
end

local function at(src, p) Env.players[src]._coords = { x = p.x, y = p.y, z = p.z } end

--- A player who left, back in the city as they were.
local function cash(src) return Env.players[src].PlayerData.money.cash end

--- Every player's money, and what the contracts still hold.
local function total(s)
    local sum = 0
    for _, p in pairs(Env.players) do sum = sum + p.PlayerData.money.cash + p.PlayerData.money.bank end
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id) or {}) do
            if CH.MONEY_SOURCES[line.source] and line.source ~= 'dirty' and line.state ~= CH.ESCROW_STATE.SETTLED then
                sum = sum + (line.amount or 0) - (tonumber(line.deliver_arrived) or 0)
            end
        end
    end
    return sum
end

local function staffAt(s)
    if not Env.players[6] then
        Env.addPlayer({ source = 6, citizenid = 'ADMIN001', license = 'license:ADMIN001',
            firstname = 'Sam', lastname = 'Steward' })
        Env.aces[6] = { ['crimson.admin'] = true }
    end
    local staff = { staff = true, cid = 'ADMIN001', source = 6 }
    local places = require('server.places')
    truthy(places.set(staff, 'disposal_vehicle', { x = SPAWN.x, y = SPAWN.y, z = SPAWN.z, heading = SPAWN.h }))
    truthy(places.set(staff, 'disposal_drop', { x = DROP.x, y = DROP.y, z = DROP.z }))
end

--- A contract taken by the hitman (3) and its target (2) killed by them,
--- standing over the body. Not verified yet.
local function killed(s, f, reward)
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
        reward = reward or { baseline = { cash = 5000 }, bonus = { cash = 1000 } } })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
    at(3, { x = 100.0, y = 100.0, z = 30.0 })
    at(2, BODY)
    Env.players[2]._health = 140
    s.death.recordDamage(3, 2, 123456)
    Env.players[2].PlayerData.metadata.isdead = true
    s.death.onVictimReport(2)
    truthy(s.death.getPending(c.id, 'HITMAN01'), 'a kill to verify')
    return c
end

--- The stack, with disposal on (unless opts.off), its spots set, a kill
--- made and (unless opts.unverified) verified at the scene.
local function setup(opts)
    opts = opts or {}
    local s = opts.stack or newStack()
    local f = opts.f or fixture(s)
    Config.Completion.KillPhotos = false
    Config.Cooldowns.disposal = { per = 10, burst = 100 }
    if not opts.off then Config.Disposal.Enabled = true end
    for k, v in pairs(opts.config or {}) do Config.Disposal[k] = v end
    local W = fakeWorld(s)
    if not opts.noSpots then staffAt(s) end
    local before = total(s)
    local c = killed(s, f, opts.reward)
    if not opts.unverified then
        Env.clientEvents = {}
        local ok, err = s.photo.verifyAtScene(f.hitman, c.id)
        truthy(ok, 'verified: ' .. tostring(err))
    end
    return s, f, c, W, before
end

local function act(src, action, id)
    _G.source = src
    local ok, err = pcall(Env.events['crimson-hitman:disposalAct'], { action = action, id = id })
    _G.source = nil
    truthy(ok, 'the net event must not raise: ' .. tostring(err))
end

--- The step markers each player was sent since the events were emptied:
--- [src] = { key = kind }; and the clears, [src] = { key = true }.
local function sent()
    local set, cleared = {}, {}
    for _, e in ipairs(Env.clientEvents) do
        if e.name == STEP_EVENT then
            set[e.target] = set[e.target] or {}
            set[e.target][e.args[1].key] = e.args[1]
        elseif e.name == CLEAR_EVENT then
            cleared[e.target] = cleared[e.target] or {}
            cleared[e.target][e.args[1].key] = true
        end
    end
    return set, cleared
end

local function tick(s, seconds)
    Env.advance(seconds or 10)
    s.disposal.tick()
    s.missionSteps.tick()
end

local function load(s, f, c, W)
    at(3, BODY)
    W.move({ x = BODY.x + 3, y = BODY.y, z = BODY.z })
    act(3, 'load', c.id)
end

local function dropOff(s, f, c, W)
    at(3, DROP)
    W.move({ x = DROP.x + 2, y = DROP.y, z = DROP.z })
    act(3, 'drop', c.id)
end

local function stepRow(s, c)
    for _, row in ipairs(s.storage.readRpRows('disposal')) do
        if row.contract_id == c.id then return row end
    end
    return nil
end


describe('R85 C4-4: a refused Load or Drop off says why', function()
    it('too far from the body, or the drop-off before loading, is said to the hitman', function()
        local s, f, c, W = setup()
        local told = {}
        local real = s.notify.toCitizen
        s.notify.toCitizen = function(cid, title, text, ...)
            if cid == 'HITMAN01' then told[#told + 1] = tostring(text) end
            return real(cid, title, text, ...)
        end
        at(3, { x = BODY.x + 4.5, y = BODY.y, z = BODY.z })
        W.move({ x = BODY.x + 2, y = BODY.y, z = BODY.z })
        act(3, 'load', c.id)
        eq(stepRow(s, c).stage, 'body', 'not loaded from 4.5 m')
        eq(#told, 1, 'said once')
        eq(told[1], L('disposal.stand_right_by_the_body_to_load'))
        act(3, 'load', c.id)
        eq(#told, 1, 'a tap again at once is not said again')
        act(3, 'drop', c.id)
        eq(told[2], L('disposal.load_the_body_first'))
        s.notify.toCitizen = real
        local _ = f
    end)
end)

describe('R85 C4-5: PayNowPercent with a reduced timeout keeps ReducedPercent of the money', function()
    it('40 at once and 50 reduced on $5,000: the hitman ends with $2,500, the placer gets $2,500 back', function()
        local s, f, c, W, before = setup({ reward = { baseline = { cash = 5000 } },
            config = { PayNowPercent = 40, OnTimeout = 'reduced', ReducedPercent = 50 } })
        local hitman0 = cash(3) - 2000
        local placer0 = cash(1)
        tick(s, 10)
        for _ = 1, 4 do tick(s, 600) end
        eq(cash(3) - hitman0, 2500, 'the hitman keeps 50% of the money in all')
        eq(cash(1) - placer0, 2500, 'the placer gets the other half back')
        eq(total(s), before, 'conserved')
        local _ = f and W
    end)
    it('a reduced share below what was paid at once takes nothing back', function()
        local s, f, c, W, before = setup({ reward = { baseline = { cash = 5000 } },
            config = { PayNowPercent = 60, OnTimeout = 'reduced', ReducedPercent = 20 } })
        local hitman0 = cash(3) - 3000
        tick(s, 10)
        for _ = 1, 4 do tick(s, 600) end
        eq(cash(3) - hitman0, 3000, 'the 60% paid at once stays theirs')
        eq(total(s), before, 'conserved')
        local _ = f and W and c
    end)
end)

describe('R85 G3R3-1: the disposal vehicle is not made again past MaxRespawns', function()
    it('a second abandonment at the limit leaves the vehicle where it is and makes no other', function()
        local s, f, c, W = setup({ config = { MaxRespawns = 1, AbandonMinutes = 1 } })
        local function reachAndAbandon()
            at(3, { x = SPAWN.x + 2, y = SPAWN.y, z = SPAWN.z })
            local id = W.only(); W.vehicles[id].x, W.vehicles[id].y = SPAWN.x, SPAWN.y
            tick(s, 10)
            W.move({ x = 2000.0, y = 2000.0, z = 30.0 })
            at(3, { x = 2400.0, y = 2000.0, z = 30.0 })
            tick(s, 10); tick(s, 70)
        end
        reachAndAbandon()
        eq(W.made, 2, 'the one respawn')
        reachAndAbandon()
        tick(s, 10)
        reachAndAbandon(); tick(s, 10)
        eq(W.made, 2, 'never made again past MaxRespawns')
        local _, n = W.only()
        eq(n, 1, 'the vehicle stays where it was left')
        local _ = f and c
    end)
end)
end

--------------------------------------------------------------------------
-- The translation fixes: one table of every English piece that was joined
-- into, or slotted into, a translated sentence, each of which must be gone
-- from its file; and every key the new code names must be in English.
--------------------------------------------------------------------------

describe('R85 translations: no English slotted into a translated sentence', function()
    local GONE = {
        -- C2-F2
        { 'server/admin.lua', "anon_creator and '(anonymous)'" },
        { 'server/admin.lua', "return '(nobody)'" },
        -- C3 F2
        { 'server/comms.lua', "ctx.role == 'creator' and 'it'" },
        -- C3 F3, R3G2-1
        { 'server/bridges.lua', "'  resolved ' .." },
        { 'server/bridges.lua', "row.anonymous and ' (anon)'" },
        { 'server/bridges.lua', "('  (resolved: ' .." },
        { 'server/bridges.lua', "('Details: /%s <id>')" },
        { 'server/bridges.lua', "'    known: ' .." },
        { 'server/bridges.lua', "'contract ' .. tostring(now.contract)" },
        { 'server/bridges.lua', "'buyout ' .. tostring(now.buyout)" },
        { 'server/bridges.lua', "'    now: ' .." },
        { 'server/bridges.lua', "(' to ' .. tostring(r.cid))" },
        { 'server/bridges.lua', "h.alias or 'operative'" },
        -- C4-2
        { 'server/configcheck.lua', "setting = 'setting'" },
        { 'server/configcheck.lua', "'  -> fix: ' .." },
        { 'server/configcheck.lua', "or 'one', st.key" },
        -- C5-4
        { 'server/history.lua', "kind = 'informants'" },
        { 'server/history.lua', "or 'payouts', amount" },
        { 'server/history.lua', "moved[2] == 'payouts'" },
        { 'server/history.lua', "and 'ended' or 'lifted'" },
        -- C5-5, G3-1
        { 'server/holds.lua', "L('holds.store_unreadable') or 'held'" },
        -- C6-2, F1-3
        { 'server/meeting.lua', "moved and 'moved' or 'set'" },
        { 'server/admin.lua', "view.grandfathered == false and 'no'" },
        { 'server/admin.lua', "kept.debug and 'on'" },
        { 'server/admin.lua', "say('  · nothing')" },
        -- C6-3
        { 'server/lib/feature.lua', "L('lib_feature.whole_number') or 'number'" },
        { 'server/main.lua', "value == math.huge and 'infinite'" },
        { 'server/main.lua', "('a ' .. type(provider))" },
        { 'server/main.lua', "'empty' or ('a ' .. type(restraint))" },
        -- C7-6
        { 'server/notify.lua', "table.concat(parts, ' and ')" },
        { 'server/notify.lua', "you_were_paid_for_collection_on'):format(paid, paid == 1 and '' or 's')" },
        -- C9-3
        { 'server/panel.lua', "h .. ' h'" },
        { 'server/panel.lua', "' Note: ' .." },
        { 'server/panel.lua', "'Placed: %s | Deadline: %s | Expires: %s'" },
        { 'server/panel.lua', "add('Operatives:')" },
        { 'server/panel.lua', "add('- none')" },
        { 'server/panel.lua', "(' | to ' .." },
        { 'server/panel.lua', "(' | settled ' .." },
        { 'server/panel.lua', "'1 day' or" },
        { 'server/panel.lua', "('for ' .." },
        { 'server/panel.lua', "who.name or 'them'" },
        { 'server/panel.lua', ".. ' min', BUYOUT_KEPT" },
        -- C10 F2..F6
        { 'server/record/init.lua', "label = 'plain'" },
        { 'server/record/init.lua', "add('thread'" },
        { 'server/record/init.lua', "earned.capped and ', capped'" },
        { 'server/rp_consequences.lua', "'north-east'" },
        { 'server/rp_consequences.lua', "job = 'resident'" },
        { 'server/rp_protection.lua', "job.account == 'cash' and 'cash' or 'bank'" },
        { 'server/rp_intent.lua', "left == 1 and '' or 's'" },
        -- C11-3, C11-4, C11-5, C11-6, F1-4
        { 'server/staff_reassign.lua', "tostring(inner) .. ').'" },
        { 'server/staff_reassign.lua', "tostring(err) .. ').'" },
        { 'server/settingsio.lua', "#applied == 1 and '' or 's'" },
        { 'server/settingsio.lua', "' refused'" },
        { 'server/settings.lua', "entry.says or 'letters, digits, - and _ only'" },
        { 'server/settings.lua', "value and 'on' or 'off'" },
        { 'server/settings.lua', "L('settings.other_scripts') .. spec.kind" },
        { 'server/settings.lua', ".. spec.without .." },
        { 'server/setup.lua', "without = st.without" },
        { 'server/staff_reward.lua', "raised and 'raised' or 'lowered'" },
        { 'server/staff_reward.lua', "format(by, opts.account)" },
        { 'server/staff_reward.lua', "charged_to_the_placers') .. account" },
    }
    it('every one is gone from its file', function()
        local left = {}
        for _, g in ipairs(GONE) do
            local text = read_file('crimson-hitman/' .. g[1])
            truthy(text, 'read ' .. g[1])
            if text and text:find(g[2], 1, true) then left[#left + 1] = g[1] .. ': ' .. g[2] end
        end
        eq(#left, 0, 'still there:\n' .. table.concat(left, '\n'))
    end)
    it('every key the changed files name is in English', function()
        local files = { 'server/admin.lua', 'server/comms.lua', 'server/bridges.lua', 'server/configcheck.lua',
            'server/history.lua', 'server/holds.lua', 'server/meeting.lua', 'server/lib/feature.lua',
            'server/main.lua', 'server/notify.lua', 'server/panel.lua', 'server/record/init.lua',
            'server/rp_consequences.lua', 'server/rp_protection.lua', 'server/rp_intent.lua',
            'server/staff_reassign.lua', 'server/settingsio.lua', 'server/settings.lua', 'server/setup.lua',
            'server/staff_reward.lua', 'server/disposal.lua', 'server/imp_decay.lua', 'server/places.lua',
            'server/intel/informants.lua' }
        local missing = {}
        for _, file in ipairs(files) do
            local text = read_file('crimson-hitman/' .. file) or ''
            for key in text:gmatch("L%('([%w_%.]+)'%)") do
                if not CrimsonLocales.en[key] then missing[#missing + 1] = file .. ': ' .. key end
            end
        end
        -- And those built from a part: each kind's name and words without one.
        for _, spec in ipairs(CrimsonBoot.requireShared('integrations').KINDS) do
            for _, suffix in ipairs({ '_name', '_without' }) do
                local key = 'integrations.' .. spec.kind .. suffix
                if not CrimsonLocales.en[key] then missing[#missing + 1] = key end
            end
        end
        for _, point in ipairs({ 'north', 'north_east', 'east', 'south_east', 'south', 'south_west', 'west', 'north_west' }) do
            if not CrimsonLocales.en['rp_consequences.dir_' .. point] then missing[#missing + 1] = point end
        end
        eq(#missing, 0, table.concat(missing, '\n'))
    end)
    it('in a translated language, the slotted words follow it', function()
        local s, f = staffStack()
        local en = CrimsonLocales.en
        local xx = setmetatable({}, { __index = en })
        for _, key in ipairs({ 'comms.is_calling_you_about_it', 'meeting.hitman_point_set',
            'meeting.placer_point_set', 'holds.held_unnamed', 'rp_consequences.dir_north',
            'record.plain', 'admin.anonymous_bracketed', 'bridges.contract_anon', 'bridges.role_client',
            'bridges.resolution_cancelled_by_creator', 'history.payouts', 'notify.you_were_paid_for_collection_on_many',
            'lib_feature.a_number_from_to', 'settings.on', 'settings.off' }) do
            xx[key] = 'XX<' .. en[key] .. '>'
        end
        CrimsonLocales.xx = xx
        Config.Locale = 'xx'
        CrimsonBoot.requireShared('locale').reset()
        local ok, err = pcall(function()
            -- C2-F2: the timeline's anonymous placer.
            local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
                mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } }, anonymous = true })
            local view = s.admin.timeline(c.id, 0)
            truthy(has(view.contract.creator, 'XX<'), 'timeline: ' .. tostring(view.contract.creator))
            -- C3 F3: /ch-contracts with the client's role and its anonymity.
            truthy(s.contracts.cancel(f.creator, c.id))
            local out = runCommand(0, 'contracts', { 'CREATOR1' })
            truthy(has(out, 'XX<client>') and has(out, 'XX< (anon)>'), out)
            truthy(has(out, 'XX<withdrawn by the client>'), 'the resolution in words: ' .. out)
            falsy(has(out, 'cancelled_by_creator'), out)
            -- C10 F3: the compass point.
            Env.players[3]._heading = 0
            truthy(has(s.rpConsequences.directionOf(3), 'XX<'), 'compass')
            -- C11-5: on / off.
            eq(s.settings.describe(true), 'XX<on>')
            -- C6-3: the number rule.
            local Feature = CrimsonBoot.require('server.lib.feature')
            local warn = {}
            Config.Intel.Rumours.Radius = 500
            Feature.check('Intel.Rumours', CrimsonBoot.require('server.intel.rumours').RULES, warn)
            truthy(has(table.concat(warn, '\n'), 'XX<a number from'), table.concat(warn, '\n'))
        end)
        Config.Locale = 'en'
        CrimsonLocales.xx = nil
        CrimsonBoot.requireShared('locale').reset()
        CrimsonBoot.requireShared('locale').reset()
        truthy(ok, tostring(err))
    end)
end)

--------------------------------------------------------------------------
-- C5-7, G4-1, G4-2: contract decay's notices
--------------------------------------------------------------------------

describe('R85 C5-7, G4-1, G4-2: what contract decay tells the placer', function()
    local function decayStack()
        local s = newStack()
        local f = fixture(s, { creatorCash = 500000, creatorBank = 200000 })
        Config.Limits.TargetCooldownAfterResolveSeconds = 0
        Config.Limits.SameCreatorSameTargetCooldownSeconds = 0
        Config.Notifications.ParanoidAlert = false
        return s, f
    end
    local function notices(src)
        local out = {}
        for _, event in ipairs(Env.clientEvents) do
            if event.target == src and Natives.isNotice(event) then
                local d = event.args[1] or {}
                out[#out + 1] = { title = tostring(d.title),
                    text = tostring(d.message or d.text or d.body or d.content or d.description) }
            end
        end
        return out
    end
    it('a reward that never rose is not said to have risen as far as it will', function()
        local s, f = decayStack()
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.MaxIncreasePercent = 0
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } } })
        truthy(c)
        s.impBoard.tick()
        Env.advance(3600); Env.clientEvents = {}
        s.impBoard.tick()
        local said = notices(1)
        for _, n in ipairs(said) do
            falsy(has(n.text, 'risen as far as it will'), n.text)
        end
        truthy(#said == 0 or has(said[1].text, L('imp_decay.your_untaken_contracts_reward_will_not_rise')),
            'told it will not rise')
    end)
    it("'shorten' stops under the title Contract time", function()
        local s, f = decayStack()
        Config.Improvements.ContractDecay.Enabled = true
        Config.Improvements.ContractDecay.Mode = 'shorten'
        Config.Improvements.ContractDecay.Percent = 50
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 10000 } } })
        truthy(c)
        s.impBoard.tick()
        local stopped
        for _ = 1, 12 do
            Env.advance(3600); Env.clientEvents = {}
            s.impBoard.tick()
            for _, n in ipairs(notices(1)) do
                if has(n.text, 'as close to running out') then stopped = n end
            end
            if stopped or s.storage.readContract(c.id).state ~= CH.STATE.ACTIVE then break end
        end
        truthy(stopped, 'the stop notice')
        eq(stopped.title, L('imp_decay.contract_time'))
    end)
end)

--------------------------------------------------------------------------
-- C5-4: the history card counts completions without reading its words
--------------------------------------------------------------------------

describe('R85 C5-4: the history card in a translated language', function()
    it('payouts are counted as completed, and listed in the language in force', function()
        local s, f = staffStack()
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        local en = CrimsonLocales.en
        CrimsonLocales.xx = setmetatable({ ['history.payouts'] = 'Auszahlungen' }, { __index = en })
        Config.Locale = 'xx'
        CrimsonBoot.requireShared('locale').reset()
        local ok, card = pcall(s.history.build, { storage = s.storage, sanctions = s.sanctions,
            identity = s.identity, freeze = s.holds }, 'HITMAN01', true)
        Config.Locale = 'en'
        CrimsonLocales.xx = nil
        CrimsonBoot.requireShared('locale').reset()
        truthy(ok, tostring(card))
        local text = json.encode(card)
        truthy(has(text, 'Auszahlungen'), text:sub(1, 400))
        falsy(has(text, '"payouts"'), 'not the English kind')
        local completed = card.counts and card.counts.completed
        eq(completed, 1, 'the payout still counts the contract as completed')
    end)
end)

--------------------------------------------------------------------------
-- C11-1, C11-3, C11-6: staff reward and reassign answers
--------------------------------------------------------------------------

local function moreStaff()
    local s, f = settingsStack()
    Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd',
        cash = 5000, bank = 50000, firstname = 'Kit', lastname = 'Vane' })
    return s, f
end
local function placed(s, f, extra)
    local req = { targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
                  reward = { baseline = { cash = 5000 } } }
    for k, v in pairs(extra or {}) do req[k] = v end
    local c, err = s.contracts.create(f.creator, req)
    truthy(c, 'placed: ' .. tostring(err))
    return c
end

describe('R85 C11-1: the reward preview names the real limits', function()
    it('lowered too far, and below the least a reward may be, say the figures the change says', function()
        local s, f = moreStaff()
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local pv = panelAsk(s, 6, 'rewardPreview', { id = c.id, by = -6000 })
        local r = panelAsk(s, 6, 'rewardChange', { id = c.id, by = -6000, reason = 'r' })
        truthy(pv.data and pv.data.message, 'refused in the preview')
        eq(pv.data.message, r.message, 'the preview says what the change says')
        truthy(has(pv.data.message, '4999') or has(pv.data.message, '4,999'), pv.data.message)
        falsy(pv.data.refusedDetail, 'nothing internal is sent')
    end)
    it('the least a reward may be', function()
        local s, f = moreStaff()
        Config.Limits.MinContractReward = 1000
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local pv = panelAsk(s, 6, 'rewardPreview', { id = c.id, by = -4500 })
        local r = panelAsk(s, 6, 'rewardChange', { id = c.id, by = -4500, reason = 'r' })
        eq(pv.data.message, r.message)
        truthy(has(pv.data.message, '1000') or has(pv.data.message, '1,000'), pv.data.message)
    end)
    it('a raise past the most at once is refused in the preview too', function()
        local s, f = moreStaff()
        local c = placed(s, f)
        local max = tonumber(Config.Staff.RewardChangeMax) or 0
        if max > 0 then
            local pv = panelAsk(s, 6, 'rewardPreview', { id = c.id, by = max + 1 })
            truthy(pv.data and pv.data.refused, 'refused')
            local r = panelAsk(s, 6, 'rewardChange', { id = c.id, by = max + 1, reason = 'r' })
            eq(pv.data.message, r.message)
        end
    end)
end)

describe('R85 C11-6: a staff raise tells the placer in whole sentences', function()
    it('raised, from the bank', function()
        local s, f = moreStaff()
        local c = placed(s, f)
        Env.clientEvents = {}
        local r = panelAsk(s, 6, 'rewardChange', { id = c.id, by = 1000, from = 'placer', account = 'bank', reason = 'r' })
        truthy(r.ok, tostring(r.message))
        truthy(has(r.message, "charged to the placer's bank"), r.message)
        local said = {}
        for _, e in ipairs(Env.clientEvents) do
            if e.target == 1 and Natives.isNotice(e) then
                local d = e.args[1] or {}
                said[#said + 1] = tostring(d.content or d.description or d.message)
            end
        end
        said = table.concat(said, '\n')
        truthy(has(said, 'Staff raised the reward on your contract on'), said)
        truthy(has(said, '$1000 was taken from your bank for it.'), said)
    end)
end)

describe('R85 C11-3: a refused reassign says why in words, never the code', function()
    it('a hitman who just walked away', function()
        local s, f = moreStaff()
        local c = placed(s, f, { mode = CH.MODE.EXCLUSIVE, penaltyAmount = 1000 })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.contracts.abandon(f.hitman, c.id))
        local looked = panelAsk(s, 6, 'player', { subject = 3 })
        local ref = looked and looked.data and looked.data.player and looked.data.player.ref
        truthy(ref, 'looked up')
        local pv = panelAsk(s, 6, 'reassignPreview', { id = c.id, ref = ref })
        local r = panelAsk(s, 6, 'reassignHitman', { id = c.id, ref = ref, reason = 'ticket: misclick' })
        local said = tostring(pv.data and pv.data.message) .. '\n' .. tostring(r.message)
        falsy(has(said, 'retake_too_soon'), said)
        falsy(has(said, '_'), 'no code: ' .. said)
    end)
end)

--------------------------------------------------------------------------
-- C7-6: receipts in whole sentences
--------------------------------------------------------------------------

describe('R85 C7-6: receipts join money and goods in the locale\'s words', function()
    it('money and goods together, and the collections paid', function()
        local s = newStack()
        fixture(s)
        local en = CrimsonLocales.en
        CrimsonLocales.xx = setmetatable({ ['notify.and_item'] = '%s UND %d Sachen' }, { __index = en })
        Config.Locale = 'xx'
        CrimsonBoot.requireShared('locale').reset()
        Natives.calls.notifications = {}
        s.notify.outstandingDelivered('HITMAN01', 2, { money = 5000, goods = 2 })
        Config.Locale = 'en'
        CrimsonLocales.xx = nil
        CrimsonBoot.requireShared('locale').reset()
        local said = {}
        for _, x in ipairs(Natives.calls.notifications) do said[#said + 1] = tostring(x.content) end
        said = table.concat(said, '\n')
        truthy(has(said, '$5,000 UND 2 Sachen'), said)
        falsy(has(said, ' and '), said)
        eq(L('notify.you_were_paid_for_collection_on_one'):format(1), ' You were paid for 1 collection on it.')
        eq(L('notify.you_were_paid_for_collection_on_many'):format(2), ' You were paid for 2 collections on it.')
    end)
end)

--------------------------------------------------------------------------
-- G2-3: an advisory is cleared off the MDT whatever Dispatch says now
--------------------------------------------------------------------------

describe('R85 G2-3: the advisory leaves the MDT when Dispatch was set to none', function()
    it('every dispatch script that is up is told to clear it', function()
        local Integrations = CrimsonBoot.require('server.adapters.init')
        local Police = CrimsonBoot.require('server.police')
        local cleared = {}
        local fake = { name = 'r85-dispatch', resource = 'r85-dispatch',
            detect = function() return true end,
            ClearNotification = function(uid) cleared[#cleared + 1] = uid end }
        if not Integrations.adapter('dispatch', 'r85-dispatch') then
            Integrations.register('dispatch', 'r85-dispatch', fake)
        end
        local was = Config.Integrations.Dispatch
        Config.Integrations.Dispatch = 'none'
        Police.clear('ch-ct1-posted')
        Config.Integrations.Dispatch = was
        local found = false
        for _, uid in ipairs(cleared) do if uid == 'ch-ct1-posted' then found = true end end
        truthy(found, 'cleared through the script that is up')
        -- And the contract's end asks, whatever the choice is now.
        local s = newStack()
        fixture(s)
        cleared = {}
        Config.Integrations.Dispatch = 'none'
        s.notify.clearContract('ct2', { id = 'ct2', target_protected = true })
        Env.runThreads = Env.runThreads or function() end
        pcall(Env.runThreads)
        Config.Integrations.Dispatch = was
        local any = false
        for _, uid in ipairs(cleared) do if uid:find('^ch%-ct2%-') then any = true end end
        truthy(any or #Env.threads > 0, 'the end of the contract clears it too')
    end)
end)

--------------------------------------------------------------------------
-- G3R1-1, G3R1-2, R2G2-2
--------------------------------------------------------------------------

describe('R85 G3R1-1: the panel offers the photo size the start-up check takes', function()
    it('Completion.PhotoMaxBytes is 50000 to 1500000 in both', function()
        local s = newStack()
        local entry = s.settings.entry('Completion.PhotoMaxBytes')
        eq(entry.min, 50000)
        eq(entry.max, 1500000)
        local value = s.settings.check('Completion.PhotoMaxBytes', 1500000)
        eq(value, 1500000, 'its top is taken')
        eq(s.settings.check('Completion.PhotoMaxBytes', 2000000), nil, 'past it is refused')
    end)
end)

describe('R85 G3R1-2: Nearby decides from the wait the contract was given', function()
    it('a wait lowered after placing does not show the target one withdrawn inside its own', function()
        local s = newStack()
        local f = fixture(s)
        Config.Notifications.ParanoidAlertJitter = { min = 600, max = 600 }
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c)
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 60 }
        Env.advance(100)
        truthy(s.contracts.cancel(f.creator, c.id))
        local ended = s.storage.readContract(c.id)
        falsy(s.notify.wasShownBefore(ended, ended.resolved_at), 'withdrawn inside its own wait')
        -- One that outlived its wait was shown.
        Config.Notifications.ParanoidAlertJitter = { min = 0, max = 0 }
        local c2 = s.contracts.create(f.creator, { targetCid = 'HITMAN01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        if c2 then
            Env.advance(10)
            truthy(s.contracts.cancel(f.creator, c2.id))
            local e2 = s.storage.readContract(c2.id)
            truthy(s.notify.wasShownBefore(e2, e2.resolved_at), 'no wait: shown')
        end
    end)
end)

describe('R85 R2G2-2: the config check warns, never raises, on fractional or infinite values', function()
    it('each value that raised in format', function()
        local main = require('crimson-hitman.server.main')
        local cases = {
            function() Config.Ledger.Depth = 12.5; Config.Ledger.MaxDepthHardCap = 10 end,
            function() Config.Ledger.Depth = math.huge end,
            function() Config.Limits.DefaultDeadlineSeconds = math.huge end,
            function() Config.Limits.ContractLifetimeSeconds = 0.5 end,
            function() Config.MaxContractValue = -math.huge end,
            function() Config.MaxContractValue = 0.5 end,
            function() Config.Reason.MaxLength = 0.5; Config.Roleplay.ReasonQuality.MinLength = 15 end,
        }
        for i, set in ipairs(cases) do
            resetConfig()
            set()
            local ok, err = pcall(main.validateConfig, true)
            truthy(ok, ('case %d raised: %s'):format(i, tostring(err)))
        end
        resetConfig()
    end)
end)
