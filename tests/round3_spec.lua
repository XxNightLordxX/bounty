--- Round 3: each decided fix, held to it.
---
---   D1  the escrow memo is per coroutine: two reads overlapping on mysql
---       leave no memo open for a later read;
---   F1  players in different routing buckets are never together, never
---       witnesses, never a medic or a killer in range;
---   F2  the shipped death provider asks qbx_medical's server export;
---   F3  money moves through the qbx_core exports, and only while the
---       character is still the one that was asked about;
---   L1-L9 the leftovers; P7 and P8 the client loops.

local Exec = require('tests.harness.mysql_exec')

--------------------------------------------------------------------------
-- D1: the escrow memo
--------------------------------------------------------------------------

local function forgetServer()
    for name in pairs(package.loaded) do
        if type(name) == 'string' and (name:sub(1, 7) == 'server.' or name == 'server') then
            package.loaded[name] = nil
        end
    end
end

local function bootMysql()
    forgetServer()
    Env.reset()
    Natives.calls = { notifications = {}, dispatch = {}, inventory = {} }
    Natives.resetResourceStates()
    resetConfig()
    Config.Database.Mode = 'mysql'
    Exec.install(Natives)
    Config.Immunity.MinTargetSessionMinutes = 0
    Config.Immunity.MinTargetPlaytimeHours = 0
    local main = require('server.main')
    return main.start()
end

local ours = setmetatable({}, { __mode = 'k' })

local function memoSetup()
    local m = bootMysql()
    Env.addPlayer({ source = 1, citizenid = 'CRE1', license = 'license:a', cash = 900000, bank = 900000, firstname = 'A', lastname = 'B' })
    Env.addPlayer({ source = 2, citizenid = 'TGT1', license = 'license:b', cash = 100, bank = 100, firstname = 'C', lastname = 'D' })
    Env.addPlayer({ source = 3, citizenid = 'VIEW1', license = 'license:c', cash = 100, bank = 100, firstname = 'E', lastname = 'F' })
    Env.addPlayer({ source = 4, citizenid = 'VIEW2', license = 'license:d', cash = 100, bank = 100, firstname = 'G', lastname = 'H' })
    Env.advance(3 * 3600)
    local row = m.contracts.create(m.identity.resolve(1), { targetCid = 'TGT1', reason = 'probe',
        reward = { baseline = { cash = 5000 } } })
    truthy(row, 'placed')
    m.storage.timeWaitsWith(function(fn, ...)
        local co = coroutine.running()
        if ours[co] and coroutine.isyieldable() then coroutine.yield('await') end
        return fn(...)
    end)
    return m, row.id
end

local function spawn(fn)
    local co = coroutine.create(fn)
    ours[co] = true
    return co
end

local function runToEnd(co)
    while coroutine.status(co) == 'suspended' do
        local ok, err = coroutine.resume(co)
        if not ok then error(err, 0) end
    end
end

local function probeLine(m, id)
    m.storage.writeEscrow(id, { { id = 'r3probe', contract_id = id, slot = 1,
        portion = CH.PORTION.BASELINE, source = 'cash', amount = 777,
        state = CH.ESCROW_STATE.HELD } })
end

describe('round 3 D1: the escrow memo is per coroutine', function()
    it('two board reads overlapping on mysql leave no memo open for a later read', function()
        local m, id = memoSetup()
        local before = m.escrow.moneyValue(id)
        local A = spawn(function() return m.projection.listing('VIEW1', 1) end)
        local B = spawn(function() return m.projection.listing('VIEW2', 1) end)
        coroutine.resume(A)
        coroutine.resume(B)
        runToEnd(A)
        runToEnd(B)
        m.storage.timeWaitsWith(nil)
        probeLine(m, id)
        eq(m.escrow.moneyValue(id), before + 777, 'a read outside any request sees the new line')
    end)

    it('a memo is the caller\'s own: another request\'s prime is not read', function()
        local m, id = memoSetup()
        m.storage.timeWaitsWith(nil)
        local before = m.escrow.moneyValue(id)
        local seen
        local A = coroutine.create(function()
            return m.escrow.cached(function()
                m.escrow.prime({ id })
                coroutine.yield()
                return m.escrow.moneyValue(id)
            end)
        end)
        coroutine.resume(A)
        probeLine(m, id)
        -- Outside A: no memo, so the new line is read.
        eq(m.escrow.moneyValue(id), before + 777, 'the main thread reads the store')
        -- And another request's own memo starts empty.
        m.escrow.cached(function() seen = m.escrow.moneyValue(id) end)
        eq(seen, before + 777, 'a second request reads its own')
        runToEnd(A)
    end)

    it('an error inside still closes the memo', function()
        local m, id = memoSetup()
        m.storage.timeWaitsWith(nil)
        local before = m.escrow.moneyValue(id)
        pcall(m.escrow.cached, function()
            m.escrow.moneyValue(id)
            error('boom')
        end)
        probeLine(m, id)
        eq(m.escrow.moneyValue(id), before + 777, 'nothing left open')
    end)
end)

describe('round 3 D1 cheap: the kept board and the latent line', function()
    it('idle ticks keep the board: the prune and an unchanged roleplay row are not writes to it', function()
        local m = memoSetup()
        m.storage.timeWaitsWith(nil)
        local main = require('server.main')
        local function tick()
            Env.time = Env.time + 10
            Env.gameTimer = Env.gameTimer + 10000
            main.tick()
        end
        for _ = 1, 3 do tick() end
        local reads, live = 0, m.storage.liveContracts
        m.storage.liveContracts = function(...) reads = reads + 1; return live(...) end
        m.projection.listing('VIEW1', 1)
        local built = reads
        truthy(built > 0, 'the first listing built the board')
        for _ = 1, 6 do tick() end
        m.storage.writeRpRow({ id = 'r3:row', kind = 'r3', contract_id = 'none' })
        reads = 0
        m.projection.listing('VIEW1', 1)
        eq(reads, 0, 'the board kept across six idle ticks is reused')
        m.storage.liveContracts = live
    end)

    it('an expiry that found nothing due does not end the kept board, one that expired does', function()
        local m, id = memoSetup()
        m.storage.timeWaitsWith(nil)
        local reads, live = 0, m.storage.liveContracts
        m.storage.liveContracts = function(...) reads = reads + 1; return live(...) end
        m.projection.listing('VIEW1', 1)
        reads = 0
        local c = m.storage.readContract(id)
        falsy(m.storage.expireIfDue(id, c.state, CH.STATE.EXPIRED, 0, true), 'not due')
        m.projection.listing('VIEW1', 1)
        eq(reads, 0, 'kept')
        truthy(m.storage.expireIfDue(id, c.state, CH.STATE.EXPIRED, os.time() + 10 * 86400 * 365, true), 'due')
        -- Ended by writing the state straight to the store, its escrow left
        -- held: a fixture no release produced, so not the resource's output
        -- for the invariant run (tests/invariants.lua).
        rawset(m.storage, '__rawFixture', true)
        m.projection.listing('VIEW1', 1)
        truthy(reads > 0, 'rebuilt after a real expiry')
        m.storage.liveContracts = live
    end)

    it('Panel.over counts JSON escapes', function()
        local s = newStack()
        local quotes = string.rep('"', 1000)
        truthy(s.panel.over({ quotes }, 1500), 'a thousand quotes are two thousand bytes')
        truthy(s.panel.over({ string.rep('\1', 300) }, 1500), 'control characters are six each')
        falsy(s.panel.over({ string.rep('a', 1000) }, 1500), 'plain text is its length')
    end)
end)

--------------------------------------------------------------------------
-- F1: routing buckets
--------------------------------------------------------------------------

local HERE = { x = 200.0, y = 200.0, z = 30.0 }

local function audited(s, action)
    s.audit.flush()
    local out = {}
    for _, row in ipairs(s.storage.readAudit(400) or {}) do
        if row.action == action then out[#out + 1] = row end
    end
    return out
end

local function kidnapSeeded()
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
        reward = { baseline = { cash = 5000 } } })
    s.contracts.accept(f.hitman, c.id, false)
    for _, src in ipairs({ 1, 2, 3 }) do
        Env.players[src]._coords = { x = HERE.x, y = HERE.y, z = HERE.z }
    end
    Env.players[2].PlayerData.metadata.ishandcuffed = true
    return s, f, c
end

describe('round 3 F1: another routing bucket is somewhere else', function()
    it('refuses to arm a handover across three instances at the same coordinates', function()
        local s, f, c = kidnapSeeded()
        Env.players[1]._bucket, Env.players[2]._bucket, Env.players[3]._bucket = 101, 102, 103
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok, 'not together')
        eq(reason, 'not_together')
    end)

    it('says a placer in another instance is not here, as an absent one is', function()
        local s, f, c = kidnapSeeded()
        Env.players[1]._bucket = 7
        local ok, reason = s.kidnap.arm(c.id, 'HITMAN01')
        falsy(ok)
        eq(reason, 'creator_too_far')
    end)

    it('still arms with all three in one instance', function()
        local s, f, c = kidnapSeeded()
        Env.players[1]._bucket, Env.players[2]._bucket, Env.players[3]._bucket = 9, 9, 9
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed inside')
    end)

    it('breaks a running countdown when the target is moved into another instance', function()
        local s, f, c = kidnapSeeded()
        truthy(s.kidnap.arm(c.id, 'HITMAN01'), 'armed')
        Env.players[2]._bucket = 55
        s.kidnap.tick(Config.Kidnap.TickMs)
        local p = s.kidnap.progress(c.id, 'HITMAN01')
        eq(p and p.breaking, 'not_together', 'the countdown says why it is slipping')
    end)

    it('does not take a defibrillator from another instance', function()
        local s = newStack()
        fixture(s)
        Env.addPlayer({ source = 5, citizenid = 'MEDIC001', license = 'license:m',
            job = { name = 'ambulance', type = 'ems', onduty = true },
            inventory = { { name = 'defibrillator', count = 1 } },
            coords = { x = 100.0, y = 100.0, z = 30.0 } })
        Env.players[2]._coords = { x = 100.0, y = 100.0, z = 30.0 }
        Env.players[2].PlayerData.metadata.isdead = true
        Env.players[5]._bucket = 4
        falsy(s.death.noteDefib(5, 2), 'a medic in another instance is not over the patient')
        Env.players[5]._bucket = 0
        truthy(s.death.noteDefib(5, 2), 'the same medic in the same one is')
    end)

    it('does not credit a named killer in another instance', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        s.contracts.accept(f.hitman, c.id, false)
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.players[2]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        Env.players[3]._bucket = 12
        Env.players[2].PlayerData.metadata.isdead = true
        s.death.onVictimReport(2, 3)
        eq(#audited(s, 'killer_out_of_range'), 1, 'refused as out of range')
        Env.players[3]._bucket = 0
        s.death.onVictimReport(2, 3)
        eq(#audited(s, 'killer_out_of_range'), 1, 'and in the same instance, in range')
    end)

    it('counts no witness from another instance', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        Env.players[1]._coords = { x = 900.0, y = 900.0, z = 30.0 }
        Env.players[2]._coords = { x = 900.0, y = 900.0, z = 30.0 }
        Env.players[3]._coords = { x = 10.0, y = 10.0, z = 30.0 }
        Env.addPlayer({ source = 8, citizenid = 'WITNESS1', license = 'license:w',
            coords = { x = 11.0, y = 10.0, z = 30.0 } })
        Env.players[8]._coords = { x = 11.0, y = 10.0, z = 30.0 }
        falsy(s.rpReputation.witnessFree(c, 'HITMAN01'), 'a bystander beside them is a witness')
        Env.players[8]._bucket = 3
        truthy(s.rpReputation.witnessFree(c, 'HITMAN01'), 'one in an apartment shell is not')
    end)
end)

--------------------------------------------------------------------------
-- F2: qbx_medical has no server death exports
--------------------------------------------------------------------------

describe('round 3 F2: the shipped death providers ask no client export on the server', function()
    it('ships qbx_medical listed for the client, with no server exports named', function()
        local entry
        for _, p in ipairs(Config.Completion.DeathStateProviders) do
            if p.resource == 'qbx_medical' then entry = p end
        end
        truthy(entry, 'still listed: the client reads the list')
        eq(entry.dead, nil, 'IsDead is a client export')
        eq(entry.lastStand, nil, 'IsLaststand is a client export')
        for _, p in ipairs(ConfigDefaults.Completion.DeathStateProviders) do
            if p.resource == 'qbx_medical' then eq(p.dead, nil, 'the defaults agree') end
        end
    end)

    it('never looks an export up on qbx_medical, and answers from the metadata', function()
        local s = newStack()
        fixture(s)
        Natives.resourceStates['sc-ambulance'] = 'missing'
        Natives.resourceStates['qbx_medical'] = 'started'
        local looked, real = 0, _G.exports
        _G.exports = setmetatable({}, { __index = function(_, resource)
            if resource ~= 'qbx_medical' then return real[resource] end
            looked = looked + 1
            return setmetatable({}, { __index = function(_, method)
                error('No such export ' .. method .. ' in resource qbx_medical', 2)
            end })
        end })
        local ok, err = pcall(function()
            Env.players[2].PlayerData.metadata.inlaststand = true
            local dead, last, resolved, by = s.identity.deathState(2)
            eq(dead, false)
            eq(last, true, 'the metadata qbx_medical writes')
            eq(resolved, true)
            eq(by, 'metadata')
        end)
        _G.exports = real
        Natives.resetResourceStates()
        truthy(ok, tostring(err))
        eq(looked, 0, 'not one lookup of an export it does not have')
    end)
end)

--------------------------------------------------------------------------
-- F3: money through the qbx_core exports
--------------------------------------------------------------------------

describe('round 3 F3: Util.charge and Util.credit', function()
    local Util = require('crimson-hitman.shared.util')

    it('move money through qbx_core\'s exports', function()
        newStack()
        local p = Env.addPlayer({ source = 7, citizenid = 'PAYER007', cash = 500, bank = 500 })
        Natives.calls.moneyExports = 0
        truthy(Util.charge(p, 'bank', 200), 'charged')
        truthy(Util.credit(p, 'cash', 50), 'credited')
        eq(Natives.calls.moneyExports, 2, 'both by export')
        eq(p.PlayerData.money.bank, 300)
        eq(p.PlayerData.money.cash, 550)
    end)

    it('refuse a player object whose character has left that server id', function()
        newStack()
        local stale = Env.addPlayer({ source = 7, citizenid = 'PAYER007', cash = 500, bank = 500 })
        Env.removePlayer(7)
        local now = Env.addPlayer({ source = 7, citizenid = 'OTHER007', cash = 900, bank = 900 })
        falsy(Util.charge(stale, 'bank', 200), 'not charged: another character is at 7 now')
        falsy(Util.credit(stale, 'bank', 200), 'not credited either')
        eq(now.PlayerData.money.bank, 900, 'the character now at 7 is untouched')
        eq(stale.PlayerData.money.bank, 500, 'and so is the record read before')
    end)

    it('let no raise out of a balance read', function()
        newStack()
        local p = Env.addPlayer({ source = 7, citizenid = 'PAYER007', cash = 500, bank = 500 })
        p.Functions.GetMoney = function() error('qbx_core: hook raised') end
        local ok, paid = pcall(Util.charge, p, 'bank', 100)
        truthy(ok, 'nothing raised out of charge')
        falsy(paid, 'and nothing was taken')
        local ok2, credited = pcall(Util.credit, p, 'bank', 100)
        truthy(ok2, 'nothing raised out of credit')
        falsy(credited)
        eq(p.PlayerData.money.bank, 500)
    end)
end)

--------------------------------------------------------------------------
-- Cheap hardening: the client
--------------------------------------------------------------------------

local Client = require('tests.harness.client')

local function phoneCalls(name)
    local n = 0
    for _, call in ipairs(Client.phone) do
        if call.call == name then n = n + 1 end
    end
    return n
end

describe('round 3 hardening: the app comes off the phone when the resource stops', function()
    it('removes it on its own stop, and not on another resource\'s', function()
        Env.reset()
        Client.boot()
        Natives.resourceStates = { ['lb-phone'] = 'started' }
        Client.fire('crimson-hitman:access', true)
        Client.runThreads()
        eq(phoneCalls('AddCustomApp'), 1, 'registered')
        Client.fire('onResourceStop', 'some-other-resource')
        eq(phoneCalls('RemoveCustomApp'), 0, 'not ours')
        Client.fire('onResourceStop', 'crimson-hitman')
        eq(phoneCalls('RemoveCustomApp'), 1, 'taken off the phone')
        Natives.resetResourceStates()
    end)
end)

describe('round 3 hardening: a stuck staff panel can be closed from the console', function()
    it('/hitmanadmin-close closes the page and gives the focus back', function()
        Env.reset()
        Client.boot()
        Client.fire('crimson-hitman:adminOpen', { canWrite = true })
        eq(Client.admin.isOpen(), true)
        local close = Env.commands['hitmanadmin-close']
        truthy(close, 'the command is registered beside the panel\'s')
        close(0, {})
        eq(Client.admin.isOpen(), false, 'closed')
        local last = Client.focus[#Client.focus]
        eq(last.focus, false, 'focus given back')
        eq(last.cursor, false, 'cursor given back')
    end)
end)

describe('round 3 hardening: a hit whose damage the game works out is still a hit', function()
    it('counts a weaponDamageEvent without overrideDefaultDamage, whatever weaponDamage says', function()
        local s = newStack()
        s.bridges.install(s)
        fixture(s)
        Env.players[3]._coords = { x = 50.0, y = 50.0, z = 30.0 }
        Env.players[2]._coords = { x = 51.0, y = 50.0, z = 30.0 }
        eq(s.bridges.onWeaponDamage(s, 3, { overrideDefaultDamage = false, weaponDamage = 0,
            weaponType = 123456, hitGlobalIds = { 1002 } }), 1, 'kept for attribution')
        eq(s.bridges.onWeaponDamage(s, 3, { overrideDefaultDamage = true, weaponDamage = 0,
            weaponType = 123456, hitGlobalIds = { 1002 } }), 0, 'an override of no damage is none')
    end)
end)

describe('round 3 hardening: /ch-diag tries the photo folder with a binary file', function()
    it('says the write and read-back worked, and leaves no file behind', function()
        local s = newStack()
        fixture(s)
        Config.Completion.PhotoStorage = 'server'
        local said = table.concat(s.admin.diagnose(1) or {}, '\n')
        truthy(said:find('data/photos write and read-back: ok', 1, true), said)
        eq(Natives.files['data/photos/.selftest.bin'], nil, 'the test file is removed')
    end)

    it('says so when the folder cannot be written', function()
        local s = newStack()
        fixture(s)
        Config.Completion.PhotoStorage = 'server'
        Natives.blocked = { ['data/photos/.selftest.bin'] = true }
        local said = table.concat(s.admin.diagnose(1) or {}, '\n')
        Natives.blocked = {}
        truthy(said:find('data/photos write and read-back FAILED', 1, true), said)
    end)

    it('and when binary comes back cut at its first NUL', function()
        local s = newStack()
        local ok, detail = s.photos.selfTest()
        truthy(ok, detail)
        local save = _G.SaveResourceFile
        _G.SaveResourceFile = function(res, file, data) return save(res, file, data, -1) end
        ok, detail = s.photos.selfTest()
        _G.SaveResourceFile = save
        falsy(ok, 'a cut picture is not kept')
        truthy(tostring(detail):find('not the same', 1, true), detail)
    end)
end)

describe('round 3 P7: the death watch outlives a pass that raised', function()
    it('keeps watching, and still reports the death that follows', function()
        Env.reset()
        Natives.resetResourceStates()
        require('crimson-hitman.shared.util').resetMonotonic()
        Env.addPlayer({ source = 3, citizenid = 'HITMAN01', license = 'license:ccc',
            firstname = 'Rook', lastname = 'Ash' })
        Client.boot()
        Client.ped = 1003
        Client.dead = false
        local real, calls = _G.IsEntityDead, 0
        _G.IsEntityDead = function(...)
            calls = calls + 1
            if calls <= 2 then error('a native raised') end
            return real(...)
        end
        local ok, err = pcall(Client.ticks, 2)
        truthy(ok, 'a raise in one pass ended the watch: ' .. tostring(err))
        Client.dead = true
        Client.ticks(2)
        _G.IsEntityDead = real
        local died = 0
        for _, call in ipairs(Client.toServer) do
            if call.name == 'crimson-hitman:iDied' then died = died + 1 end
        end
        eq(died, 1, 'the death after it is reported')
    end)
end)

--------------------------------------------------------------------------
-- The leftovers
--------------------------------------------------------------------------

local rpIt = require('tests.harness.roleplay').it

--- A contract on Dana Reyes (2), placed by Vic Marlowe (1), taken by Rook
--- Ash (3) unless `accept` is false.
local function rpSetup(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt', mode = CH.MODE.COMPETITIVE,
        reward = opts.slots and { slots = { { baseline = { cash = 2000 } }, { baseline = { cash = 2000 } } } }
            or { baseline = { cash = 5000 } },
    })
    truthy(c, 'placed')
    if opts.accept ~= false then truthy(s.contracts.accept(f.hitman, c.id, true), 'taken') end
    Env.players[2].PlayerData.money.bank = 100000
    Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
    Env.runTimers()
    return s, f, c
end

local function netCall(name, src, payload)
    local fire = Env.events['crimson-hitman:' .. name]
    truthy(fire, 'no handler registered for ' .. name)
    local from = #Env.clientEvents
    _G.source = src
    fire(payload or {})
    _G.source = nil
    for i = from + 1, #Env.clientEvents do
        local event = Env.clientEvents[i]
        if event.name == 'crimson-hitman:result' and event.target == src then return event.args[1] end
    end
    return nil
end

describe('round 3 L1: a bodyguard job charged and not recorded', function()
    rpIt('says the money is coming back, and posts no second job while it is', function()
        local s, f, c = rpSetup()
        Config.Roleplay.Protection.Enabled = true
        s.bridges.install(s)
        local write, writes, failing = s.storage.writeRpRow, 0, false
        s.storage.writeRpRow = function(row)
            writes = writes + 1
            if failing or writes > 1 then failing = true; error('the database went away') end
            return write(row)
        end
        local function post()
            return netCall('protectionPost', 2, { id = c.id, amount = 2000,
                account = Config.Roleplay.Protection.Account })
        end
        local before = Env.players[2].PlayerData.money.bank
        local r = post()
        falsy(r.ok)
        eq(r.err, CH.ERR.PROTECTION_NOT_RECORDED, 'not "busy": the money was taken')
        eq(Env.players[2].PlayerData.money.bank, before - 2000, 'taken, and owed back')
        local again = post()
        eq(again.err, CH.ERR.PROTECTION_REFUND_PENDING, 'no second job while the first refund is owed')
        eq(Env.players[2].PlayerData.money.bank, before - 2000, 'not charged twice')
        -- The store answers again: the refund goes out, and a job may be posted.
        s.storage.writeRpRow = write
        s.rpProtection.sweep()
        eq(Env.players[2].PlayerData.money.bank, before, 'handed back')
        truthy(post().ok, 'posted once nothing is owed')
    end)
end)

local function intentOn()
    Config.Roleplay.ProofOfIntent.Enabled = true
    Config.Roleplay.ProofOfIntent.MinMessages = 3
    Config.Roleplay.ProofOfIntent.HoldMaxMinutes = 60
end

local function heldLine(s, c)
    for _, line in ipairs(s.storage.readEscrow(c.id)) do
        if line.owed_to == 'HITMAN01' and line.state == CH.ESCROW_STATE.HELD then return line end
    end
    return nil
end

describe('round 3 L2: staff settling a payout held for proof of intent are told so', function()
    rpIt('says held for proof of intent, and when it releases', function()
        local s, f, c = rpSetup()
        intentOn()
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        truthy(result.intentHold, 'held')
        local line = heldLine(s, c)
        truthy(line, 'owed in escrow')
        local done, why, detail = s.admin.settleLine(0, line.id, 'pay')
        local said = s.admin.settleAnswer(done, why, detail, true)
        truthy(said:find('held for proof of intent (releases at ', 1, true), said)
        eq(Env.players[3].PlayerData.money.cash, 5000, 'nothing given while it holds')
    end)
end)

describe('round 3 L3: a proof-of-intent hold is written once the claim has gone through', function()
    rpIt('writes the row after the claim, not in the middle of it', function()
        local s, f, c = rpSetup()
        intentOn()
        local write, seen = s.storage.writeRpRow, {}
        s.storage.writeRpRow = function(row)
            if row.kind == 'intent' then seen[#seen + 1] = s.storage.readContract(c.id).state end
            return write(row)
        end
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        s.storage.writeRpRow = write
        truthy(ok, tostring(err))
        truthy(result.intentHold, 'held')
        eq(#seen, 1, 'written once')
        truthy(seen[1] ~= CH.STATE.COMPLETING, 'not while the claim held the contract: ' .. tostring(seen[1]))
        eq(#s.storage.readRpRows('intent'), 1)
        eq(Env.players[3].PlayerData.money.cash, 5000, 'and the payout still waits')
    end)

    rpIt('writes nothing, and holds nothing, for a claim that was refused', function()
        local s, f, c = rpSetup()
        intentOn()
        local hold = s.rpIntent.onClaim(s.storage.readContract(c.id), 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(hold, 'a hold started')
        s.rpIntent.afterClaim(c.id, 'HITMAN01', false)
        eq(#s.storage.readRpRows('intent'), 0, 'no row')
        eq(s.rpIntent.count(), 0, 'no hold')
    end)
end)

describe('round 3 L4: an informant purchase the store would not take is written on the tick', function()
    local function informantSetup()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
        Env.players[1].PlayerData.money.bank = 100000
        Env.players[2].PlayerData.money.bank = 100000
        Env.advance(Config.Notifications.ParanoidAlertJitter.max + 1)
        s.informant.setRandom(function() return 100 end)
        return s, f, c
    end

    local function view(s, c, cid)
        return s.projection.contract(s.storage.readContract(c.id), cid)
    end

    it('the placer\'s purchase: kept, and written once the store answers', function()
        local s, f, c = informantSetup()
        local pick = view(s, c, 'CREATOR1').placerInformantPicks[1].pick
        local real = s.storage.writePlacerInformant
        s.storage.writePlacerInformant = function() error('the connection dropped', 0) end
        local ok, err = s.informant.placerBuy(f.creator, c.id,
            { cost = Config.Intel.PlacerInformant.Cost, account = Config.Intel.PlacerInformant.Account }, pick)
        truthy(ok, tostring(err))
        eq(#(s.storage.readPlacerInformants(c.id, 'CREATOR1') or {}), 0, 'not in the store yet')
        eq(s.informant.retryUnsaved(), 0, 'still refused')
        s.storage.writePlacerInformant = real
        eq(s.informant.retryUnsaved(), 1, 'written on the next try')
        eq(#s.storage.readPlacerInformants(c.id, 'CREATOR1'), 1, 'in the store, for a restart to read')
        eq(s.informant.retryUnsaved(), 0, 'nothing left to write')
    end)

    it('the target\'s purchase too', function()
        local s, f, c = informantSetup()
        local pick
        for _, p in ipairs(view(s, c, 'TARGET01').informantPicks or {}) do
            if p.pick ~= 'placer' then pick = p.pick end
        end
        local real = s.storage.writeReveal
        s.storage.writeReveal = function() error('the connection dropped', 0) end
        local ok, err = s.informant.buy(f.target, c.id, nil, pick)
        truthy(ok, tostring(err))
        eq(s.storage.readReveal(c.id, 'TARGET01'), nil, 'not in the store yet')
        s.storage.writeReveal = real
        eq(s.informant.retryUnsaved(), 1)
        truthy(s.storage.readReveal(c.id, 'TARGET01'), 'in the store')
    end)

    it('runs on the maintenance tick', function()
        local main = read_file('crimson-hitman/server/main.lua')
        truthy(main:find("job('informant.retryUnsaved'", 1, true), 'a tick job')
    end)
end)

describe('round 3 L5: the roleplay rows of settled jobs go once their contract is pruned', function()
    rpIt('removes a settled job\'s row after its contract is pruned, and only then', function()
        local s, f, c = rpSetup()
        Config.Roleplay.Protection.Enabled = true
        s.bridges.install(s)
        local job = netCall('protectionPost', 2, { id = c.id, amount = 2000,
            account = Config.Roleplay.Protection.Account }).data.job
        truthy(netCall('protectionCancel', 2, { job = job }).ok, 'cancelled, refunded')
        eq(s.rpProtection.all()[1].state, 'settled')
        s.contracts.abandon(f.hitman, c.id)
        truthy(s.contracts.cancel(f.creator, c.id), 'the contract ends')
        Env.advance(601)
        s.rpProtection.sweep()
        eq(#s.storage.readRpRows('protection'), 1, 'kept while its contract is in the store')
        Config.Audit.ContractRetentionDays = 1
        Env.advance(2 * 86400)
        s.storage.prune()
        eq(s.storage.readContract(c.id), nil, 'the contract was pruned')
        s.rpProtection.sweep()
        eq(#s.storage.readRpRows('protection'), 0, 'its row goes')
        eq(#s.rpProtection.all(), 0, 'and from memory')
    end)
end)

describe('round 3 L6: a proposal does not run out while staff hold the contract', function()
    it('keeps it open through the hold, and gives it the hold back on release', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        local ok, err = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'A better reason' })
        truthy(ok, tostring(err))
        local proposal = s.storage.readOpenAmendments(c.id)[1]
        local left = proposal.expires_at - os.time()
        truthy(left > 0, 'open')
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'a staff situation'), 'held')
        local held = Config.Amendments.ProposalExpirySeconds + 3600
        Env.advance(held)
        s.amendments.expire()
        eq(#s.storage.readOpenAmendments(c.id), 1, 'not run out while it could not be answered')
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01'), 'released')
        local after = s.storage.readOpenAmendments(c.id)[1]
        truthy(after, 'still open')
        eq(after.expires_at - os.time(), left, 'the same time left to answer as when the hold began')
        Env.advance(left + 1)
        eq(s.amendments.expire(), 1, 'and runs out after that')
    end)
end)

describe('round 3 L8: a give-back adds to the lifetime as it is when it writes', function()
    it('keeps a staff lifetime change that landed while the release was under way', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } } })
        truthy(s.contracts.accept(f.hitman, c.id, false), 'taken')
        -- Copies from every read, as mysql answers: the memory store hands
        -- out the stored row, which a stale read cannot be told from.
        local copying = require('tests.harness.copying_store')(s.storage)
        s.holds.init({ storage = copying, audit = s.audit, notify = s.notify, kidnap = s.kidnap,
                        contracts = s.contracts })
        truthy(s.holds.freeze('ADMIN001', 'TARGET01', 'a staff situation'), 'held')
        Env.advance(600)
        -- The placer frozen too: the release then asks who else holds the
        -- contract, which reads its roster (an await on mysql).
        truthy(s.holds.freeze('ADMIN001', 'CREATOR1', 'another'), 'held by the placer as well')
        Env.advance(300)
        local before = s.storage.readContract(c.id).expires_at
        -- A staff lifetime change, landing in one of the release's awaits.
        local read, landed = copying.readHitmen, false
        copying.readHitmen = function(...)
            if not landed then
                landed = true
                s.storage.setContractFields(c.id, { expires_at = s.storage.readContract(c.id).expires_at + 1000 })
            end
            return read(...)
        end
        truthy(s.holds.unfreeze('ADMIN001', 'TARGET01'), 'released')
        copying.readHitmen = read
        truthy(landed, 'the change landed mid-release')
        eq(s.storage.readContract(c.id).expires_at, before + 1000 + 600,
            'the staff change kept, and the part of the hold no other covers given back on top')
    end)
end)

describe('round 3 L9: a named placer\'s messages are signed with their name in the thread', function()
    local function talking(anonCreator)
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            reward = { baseline = { cash = 5000 } }, anonymous = anonCreator == true })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, true), 'taken')
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        truthy(s.comms.send(f.creator, c.id, handle, 'Bring them to the docks'), 'sent')
        return s, f, c, handle
    end

    it('names a named placer to the hitman, as the inbox does', function()
        local s, f, c = talking(false)
        local read = s.comms.read(f.hitman, c.id)
        eq(read[1].alias, 'Vic Marlowe')
    end)

    it('keeps an anonymous placer by role', function()
        local s, f, c = talking(true)
        local read = s.comms.read(f.hitman, c.id)
        eq(read[1].alias, 'The person who placed it')
    end)

    it('and the placer\'s own view as it was', function()
        local s, f, c, handle = talking(false)
        local read = s.comms.read(f.creator, c.id, handle)
        eq(read[1].alias, 'The person who placed it')
        eq(read[1].mine, true)
    end)
end)
