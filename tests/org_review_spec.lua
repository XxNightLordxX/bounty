--- The organisation review of 15200dc (H1-H3, M1-M6, L1-L5): each finding's
--- probe, kept as the regression it now is. Every one failed against that
--- commit; each `it` names its finding.

local W = require('tests.harness.org_world')
local QbxJobs = W.QbxJobs
local BOSS, LIEUT = W.boss(11, 'BOSS0001'), W.boss(12, 'LIEUT001')

local function world(opts)
    local s, f = W.world(opts)
    W.crew(s)
    return s, f, s.org.current()
end

local function moneyBoss(s)
    for _, code in ipairs({ 'C6', 'C7', 'C8', 'P2' }) do W.allow(s, 3, code) end
    W.office(s)
    W.at(11, 100.0, 100.0)
end

--- Run `inner` once, the first time storage[name] is called with a row the
--- filter takes, then let the call through: a second request landing inside
--- the first one's await.
local function during(s, name, filter, inner)
    local real = s.storage[name]
    local fired = false
    s.storage[name] = function(...)
        if not fired and filter(...) then
            fired = true
            inner()
        end
        return real(...)
    end
    return function() s.storage[name] = real end
end

describe('organisation review: the funds', function()
    it('H1 two withdrawals across the insert await never overdraw the ledger', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        truthy(s.org.staffDeposit(W.STAFF, 1000, 'seed', 's1'))
        local second
        local restore = during(s, 'insertOrgRowOnce', function(name, row) return name == 'funds' and row.kind == 'withdraw' end,
            function() second = table.pack(s.org.withdraw(BOSS, 800, 'b', 'n2')) end)
        local before = W.wealth(11)
        local ok1 = s.org.withdraw(BOSS, 800, 'a', 'n1')
        restore()
        truthy(ok1, 'the first is paid')
        falsy(second[1], 'the second is refused')
        eq(second[2], 'org_short')
        eq(s.org.Funds.balance(org), 200, 'balance never below zero')
        eq(W.wealth(11) - before, 800, 'the boss got one withdrawal')
    end)

    it('H1 a ledger debit whose row is not written gives its reservation back', function()
        local s, _, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        truthy(s.org.staffDeposit(W.STAFF, 1000, 'seed', 's1'))
        local real = s.storage.insertOrgRowOnce
        s.storage.insertOrgRowOnce = function(name, row)
            if name == 'funds' and row.kind == 'withdraw' then error('db down') end
            return real(name, row)
        end
        falsy(s.org.withdraw(BOSS, 300, 'a', 'n1'))
        s.storage.insertOrgRowOnce = real
        eq(s.org.Funds.balance(org), 1000)
    end)

    it('M4 two concurrent withdrawals never pass WithdrawPerDay', function()
        local s = world({ bank = true })
        moneyBoss(s)
        truthy(s.org.staffDeposit(W.STAFF, 100000, 'seed', 's1'))
        truthy(s.org.setLimits(W.STAFF, { WithdrawMax = 1000, WithdrawPerDay = 1000 }))
        local second
        local restore = during(s, 'insertOrgRowOnce', function(name, row) return name == 'funds' and row.kind == 'withdraw' end,
            function() second = table.pack(s.org.withdraw(BOSS, 1000, 'b', 'n2')) end)
        local before = W.wealth(11)
        truthy(s.org.withdraw(BOSS, 1000, 'a', 'n1'))
        restore()
        falsy(second[1])
        eq(second[2], 'org_limit')
        eq(W.wealth(11) - before, 1000, 'at most WithdrawPerDay in a day')
    end)

    it('M4 two concurrent bonuses never pass BonusPerDay', function()
        local s = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        moneyBoss(s)
        truthy(s.org.staffDeposit(W.STAFF, 100000, 'seed', 's1'))
        truthy(s.org.setLimits(W.STAFF, { BonusMax = 1000, BonusPerDay = 1000 }))
        local second
        local restore = during(s, 'insertOrgRowOnce', function(name, row) return name == 'funds' and row.kind == 'bonus' end,
            function() second = table.pack(s.org.bonus(BOSS, 'RECRUIT1', 1000, 'b', 'n2')) end)
        truthy(s.org.bonus(BOSS, 'RECRUIT1', 1000, 'a', 'n1'))
        restore()
        falsy(second[1])
        eq(second[2], 'org_limit')
    end)

    it('H2 the bank chosen and down: every movement refused, nothing paid from the ledger', function()
        local s, _, org = world({ bank = true })
        moneyBoss(s)
        truthy(s.org.deposit(BOSS, 2500, 'bank', 'd'))
        eq(QbxJobs.bank.hitman, 2500)
        -- A restart, then Renewed-Banking down.
        s.org.Funds.init({ storage = s.storage, audit = s.audit })
        s.org.Funds.load(org)
        Natives.resourceStates['Renewed-Banking'] = 'stopped'
        local before = W.wealth(11)
        local ok, err = s.org.withdraw(BOSS, 2000, 'x', 'w')
        falsy(ok, 'nothing paid out of an account it cannot see')
        eq(err, 'org_bank_down')
        eq(W.wealth(11), before)
        eq(s.org.Funds.balance(org), nil, 'the balance is not known')
        local dep, derr = s.org.deposit(BOSS, 100, 'bank', 'd2')
        falsy(dep, 'nor a deposit the bank never sees')
        eq(derr, 'org_bank_down')
        eq(W.wealth(11), before, 'nothing taken from the member')
        falsy(s.org.staffDeposit(W.STAFF, 100, 'x', 's9'))
        Natives.resourceStates['Renewed-Banking'] = 'started'
        truthy(s.org.withdraw(BOSS, 2000, 'x', 'w3'), 'back once it is started')
        eq(QbxJobs.bank.hitman, 500)
    end)

    it('H2 the backend is chosen once and kept: Config and the bank state do not move it', function()
        local s, _, org = world({ bank = true })
        moneyBoss(s)
        truthy(s.org.deposit(BOSS, 2500, 'bank', 'd'))
        eq(s.storage.readStaffMeta()[s.org.Funds.META], 2, 'kept by the store')
        Config.Organisation.Funds = 'internal'
        Natives.resourceStates['Renewed-Banking'] = 'missing'
        s.org.Funds.init({ storage = s.storage, audit = s.audit })
        s.org.Funds.load(org)
        eq(s.org.Funds.backend(), 'bank', 'still the bank')
        falsy(s.org.withdraw(BOSS, 100, 'x', 'w'), 'and refused while it is missing')
    end)

    it('H2 bank rows never count in the ledger, and the switch carries the balance explicitly', function()
        local s, _, org = world({ bank = true })
        moneyBoss(s)
        truthy(s.org.deposit(BOSS, 2500, 'bank', 'd'))
        -- Staff move the funds to the ledger: the bank emptied into it.
        local reply = W.ask(6, 'orgFundsBackend', { backend = 'internal' })
        eq(reply.ok, true, tostring(reply.message))
        eq(QbxJobs.bank.hitman, 0, 'the bank account emptied')
        eq(s.org.Funds.backend(), 'internal')
        eq(s.org.Funds.balance(org), 2500, 'the ledger holds what the bank did, once')
        -- A restart reads the same: the bank's own rows are not summed.
        s.org.Funds.init({ storage = s.storage, audit = s.audit })
        s.org.Funds.load(org)
        eq(s.org.Funds.backend(), 'internal')
        eq(s.org.Funds.balance(org), 2500)
        -- And back again.
        eq(W.ask(6, 'orgFundsBackend', { backend = 'bank' }).ok, true)
        eq(QbxJobs.bank.hitman, 2500)
        eq(s.org.Funds.balance(org), 2500)
        s.org.Funds.init({ storage = s.storage, audit = s.audit })
        s.org.Funds.load(org)
        eq(s.org.Funds.balance(org), 2500, 'one balance, whichever side')
        eq(W.ask(6, 'orgFundsBackend', { backend = 'bank' }).err, 'org_already')
        eq(W.ask(7, 'orgFundsBackend', { backend = 'internal' }).err, 'not_allowed', 'a reader may not')
        -- Leaving a bank that is down needs abandon, and carries nothing.
        Natives.resourceStates['Renewed-Banking'] = 'stopped'
        eq(W.ask(6, 'orgFundsBackend', { backend = 'internal' }).err, 'org_bank_down')
        eq(W.ask(6, 'orgFundsBackend', { backend = 'internal', abandon = true }).ok, true)
        eq(s.org.Funds.balance(org), 0, 'what the bank holds stays there')
    end)

    it('H2 a cut while the bank chosen is down: the member is paid whole, and it is on the record', function()
        local s, f, org = world({ bank = true })
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 20))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(s.identity.resolve(3), c.id))
        Natives.resourceStates['Renewed-Banking'] = 'stopped'
        local line = { id = c.id .. ':rb', contract_id = c.id, portion = CH.PORTION.BASELINE, source = 'cash', amount = 1000 }
        local before = W.wealth(3)
        truthy(s.escrow.deliver('HITMAN01', line))
        eq(W.wealth(3) - before, 1000, 'nothing is cut into a ledger the bank does not see')
        eq(s.storage.readOrgRow('funds', 'cut:' .. line.id), nil, 'and no row written')
        s.audit.flush()
        eq(#(s.storage.auditByAction('org_cut_unavailable', 10) or {}), 1)
        local _ = org
    end)

    it('M6 a cut taken, then a restart with the organisation off: the line is not paid whole', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        local hitman = s.identity.resolve(3)
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 20))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        local line = { id = c.id .. ':test', contract_id = c.id, portion = CH.PORTION.BASELINE, source = 'cash', amount = 1000 }
        Env.players[3]._refuseMoney = true
        falsy(s.escrow.deliver('HITMAN01', line))
        eq(s.org.Funds.balance(org), 200, 'cut taken')
        Env.players[3]._refuseMoney = nil
        Config.Organisation.Enabled = false
        s.org.Funds.init({ storage = s.storage, audit = s.audit })
        eq(s.escrow.stillOwed(line), 800, 'still owed less the cut')
        local before = W.wealth(3)
        truthy(s.escrow.deliver('HITMAN01', line))
        eq(W.wealth(3) - before, 800, 'escrowed = member + funds')
    end)

    it('L1 a cut taken as cash, then paid as a dirty item: the item is the line less the cut', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        local hitman = s.identity.resolve(3)
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 20))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        local line = { id = c.id .. ':test', contract_id = c.id, portion = CH.PORTION.BASELINE, source = 'cash', amount = 1000 }
        Env.players[3]._refuseMoney = true
        falsy(s.escrow.deliver('HITMAN01', line))
        Env.players[3]._refuseMoney = nil
        local real = s.escrow.payoutAs
        local count
        s.escrow.payoutAs = function() return { item = 'black_money', rate = 1 } end
        local realAdd = exports.ox_inventory.AddItem
        exports.ox_inventory.AddItem = function(self, src, name, n, ...)
            if name == 'black_money' then count = n end
            return realAdd(self, src, name, n, ...)
        end
        local delivered = s.escrow.deliver('HITMAN01', line)
        exports.ox_inventory.AddItem = realAdd
        s.escrow.payoutAs = real
        truthy(delivered)
        eq(count, 800, 'no more than escrow minus cut')
        eq(s.org.Funds.balance(org), 200)
    end)

    it('L1 with dirty payouts on from the start, the cut is still taken', function()
        local s, f, org = world({ configure = function() Config.Organisation.Funds = 'internal' end })
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 20))
        local c = W.place(s, f.creator)
        truthy(s.contracts.accept(s.identity.resolve(3), c.id))
        local line = { id = c.id .. ':d', contract_id = c.id, portion = CH.PORTION.BASELINE, source = 'cash', amount = 1000 }
        local real = s.escrow.payoutAs
        s.escrow.payoutAs = function() return { item = 'black_money', rate = 1 } end
        truthy(s.escrow.deliver('HITMAN01', line))
        s.escrow.payoutAs = real
        eq(s.org.Funds.balance(org), 200, 'the board said a cut is taken: it is')
    end)
end)

describe('organisation review: staff locks and anonymity', function()
    it('M1 a boss never lifts a staff per-member deny, in one step or two', function()
        local s, _, org = world()
        W.allow(s, 3, 'D2'); W.allow(s, 3, 'M1')
        truthy(s.org.memberGrant(W.STAFF, 'LIEUT001', 'M1', 'deny'))
        eq(select(2, s.org.memberGrant(BOSS, 'LIEUT001', 'M1', 'grant')), 'org_locked', 'grant refused')
        eq(select(2, s.org.memberGrant(BOSS, 'LIEUT001', 'M1', 'deny')), 'org_locked', 'a deny over it refused')
        eq(select(2, s.org.memberGrant(BOSS, 'LIEUT001', 'M1', 'clear')), 'org_locked', 'clear refused')
        eq(org.members.LIEUT001.denies.M1.by, 'staff', 'staff deny stays staff\'s')
        falsy(s.org.Engine.holds(org, 'LIEUT001', 'M1'))
        truthy(s.org.memberGrant(W.STAFF, 'LIEUT001', 'M1', 'grant'))
        eq(select(2, s.org.memberGrant(BOSS, 'LIEUT001', 'M1', 'clear')), 'org_locked', 'nor a staff grant')
    end)

    it('M2 a boss never removes a staff-placed role power, in one step or two', function()
        local s, _, org = world()
        W.allow(s, 3, 'R4'); W.allow(s, 3, 'M1'); W.office(s); W.at(11, 100.0, 100.0)
        truthy(s.org.rolePower(W.STAFF, 2, 'M1', true))
        eq(select(2, s.org.rolePower(BOSS, 2, 'M1', false)), 'org_locked')
        eq(select(2, s.org.rolePower(BOSS, 2, 'M1', true)), 'org_locked', 'not written over')
        eq(org.roles[2].powers.M1.by, 'staff', 'staff grant stays')
    end)

    it('M3 a K2 pick answers the same for every member of an anonymous contract', function()
        local s, f = world()
        W.allow(s, 3, 'K2')
        truthy(s.org.hire(W.STAFF, { cid = 'CREATOR1', name = 'C', source = 1 }, 0))
        local c = W.place(s, f.creator, 'TARGET01', { anonymous = true })
        truthy(c, 'placed')
        local okA, errA = s.org.pick(BOSS, c.id, 'RECRUIT1')
        local okB, errB = s.org.pick(BOSS, c.id, 'CREATOR1')
        eq(okB, okA, 'the placer answers as any other member')
        eq(errB, errA)
        -- And picked, the placer still cannot take it.
        falsy(s.contracts.accept(f.creator, c.id))
    end)
end)

describe('organisation review: applications and hires', function()
    it('H3 a stale application never demotes a member: closed instead', function()
        local s, _, org = world({ configure = function() Config.Organisation.ApplyAtSignupOnly = false end })
        W.allow(s, 2, 'N2')
        W.player(20, 'NEWBOSS1')
        local actor = s.identity.resolve(20)
        truthy(s.org.apply(actor, 'let me in'))
        local id
        for k in pairs(org.applications) do id = k end
        -- An application read before the hire, kept by a page.
        local stale = org.applications[id]
        truthy(s.org.hire(W.STAFF, { cid = 'NEWBOSS1', name = 'X', source = 20 }, 3))
        eq(org.applications[id], nil, 'the hire closes it')
        eq(s.storage.readOrgRow('applications', id).state, 'superseded')
        truthy(s.org.fire(W.STAFF, 'BOSS0001', 'left'))
        local ok, err = s.org.decide(LIEUT, id, true)
        falsy(ok)
        eq(err, 'org_not_found')
        -- Even an open row naming a member is closed, not accepted.
        org.applications[id] = stale
        stale.state = 'open'
        ok, err = s.org.decide(LIEUT, id, true)
        falsy(ok)
        eq(err, 'org_already')
        eq(org.members.NEWBOSS1.grade, 3, 'the top boss keeps their rank')
        eq(QbxJobs.groups.NEWBOSS1.hitman, 3)
        eq(org.applications[id], nil)
    end)

    it('H3 a job adopted from elsewhere closes the application too', function()
        local s, _, org = world({ configure = function() Config.Organisation.ApplyAtSignupOnly = false end })
        W.player(20, 'NEWBOSS1')
        truthy(s.org.apply(s.identity.resolve(20), 'hi'))
        exports.qbx_core:AddPlayerToJob('NEWBOSS1', 'hitman', 1)
        eq(org.members.NEWBOSS1.grade, 1, 'adopted')
        eq(next(org.applications), nil, 'and its application closed')
    end)

    it('L2 a boss\'s hire is an invite the player accepts: no job, no primary until then', function()
        local s, _, org = world()
        W.allow(s, 3, 'M2'); W.office(s); W.at(11, 100.0, 100.0)
        W.player(30, 'COPCOP01')
        W.at(30, 101.0, 100.0)
        QbxJobs.calls = {}
        local reply = W.call('orgHire', 11, { target = 30 })
        eq(reply.ok, true)
        eq(reply.data.invited, true, 'an invite')
        eq(org.members.COPCOP01, nil, 'not a member yet')
        eq(QbxJobs.groups.COPCOP01, nil, 'qbx_core not told')
        eq(QbxJobs.count('SetPlayerPrimaryJob'), 0, 'their primary job untouched')
        eq(W.call('orgHire', 11, { target = 30 }).err, 'org_already', 'one invite at a time')
        -- The player sees it: on the board and in orgMine, never who sent it.
        local mine = W.call('orgMine', 30, {}).data
        truthy(mine.invite, 'shown in orgMine')
        eq(mine.invite.role, 'Recruit')
        eq(mine.invite.by, nil)
        local board = W.call('list', 30, {}).data
        eq(board.orgInvite.id, mine.invite.id, 'and on the board')
        eq(W.call('list', 13, {}).data.orgInvite, nil, 'nobody else\'s')
        -- Only the invited player answers it.
        eq(W.call('orgInviteAnswer', 13, { id = mine.invite.id, accept = true }).err, 'org_not_found')
        -- Declined: gone, nothing changed.
        eq(W.call('orgInviteAnswer', 30, { id = mine.invite.id, accept = false }).ok, true)
        eq(W.call('orgMine', 30, {}).data.invite, nil)
        eq(org.members.COPCOP01, nil)
        -- Asked again and accepted: hired, primary job and all.
        eq(W.call('orgHire', 11, { target = 30 }).ok, true)
        local again = W.call('orgMine', 30, {}).data.invite
        local yes = W.call('orgInviteAnswer', 30, { id = again.id, accept = true })
        eq(yes.ok, true, tostring(yes.data and yes.data.message))
        eq(org.members.COPCOP01.grade, 0)
        eq(QbxJobs.groups.COPCOP01.hitman, 0)
        eq(QbxJobs.count('SetPlayerPrimaryJob'), 1, 'SetPrimaryOnHire after acceptance')
    end)

    it('L2 an invite runs out, and is checked again as it is accepted', function()
        local s, _, org = world()
        W.allow(s, 3, 'M2'); W.office(s); W.at(11, 100.0, 100.0)
        W.player(30, 'COPCOP01')
        W.at(30, 101.0, 100.0)
        eq(W.call('orgHire', 11, { target = 30 }).ok, true)
        local invite = W.call('orgMine', 30, {}).data.invite
        Env.time = Env.time + 11 * 60
        eq(W.call('orgInviteAnswer', 30, { id = invite.id, accept = true }).err, 'org_not_found', 'run out')
        eq(W.call('list', 30, {}).data.orgInvite, nil)
        -- Staff revoke Hire before the player answers: refused.
        eq(W.call('orgHire', 11, { target = 30 }).ok, true)
        invite = W.call('orgMine', 30, {}).data.invite
        truthy(s.org.setCeiling(W.STAFF, 'role', 3, 'M2', 'off'))
        eq(W.call('orgInviteAnswer', 30, { id = invite.id, accept = true }).err, 'org_rule')
        eq(org.members.COPCOP01, nil)
    end)

    it('L2 a staff hire makes no primary job, an accepted application does', function()
        local s = world({ configure = function() Config.Organisation.ApplyAtSignupOnly = false end })
        QbxJobs.calls = {}
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        eq(QbxJobs.count('SetPlayerPrimaryJob'), 0)
        W.player(20, 'NEWBIE01')
        truthy(s.org.apply(s.identity.resolve(20), 'hi'))
        local id = next(s.org.current().applications)
        truthy(s.org.decide(W.STAFF, id, true))
        eq(QbxJobs.count('SetPlayerPrimaryJob'), 1, 'they asked to join')
    end)
end)

describe('organisation review: keeping qbx_core in step', function()
    it('L3 a removal made while away is adopted at login, as one made online is', function()
        local s, _, org = world()
        -- Taken out of the job while they were away (an admin, offline).
        QbxJobs.groups.LIEUT001 = nil
        Env.players[12].PlayerData.jobs = {}
        Env.events['local:QBCore:Server:PlayerLoaded'](Env.players[12])
        eq(org.members.LIEUT001, nil, 'adopted: no longer a member')
        eq(QbxJobs.groups.LIEUT001, nil, 'and not put back')
    end)

    it('L3 a grade changed while away is adopted at login', function()
        local s, _, org = world()
        QbxJobs.groups.RECRUIT1 = { hitman = 1 }
        Env.players[13].PlayerData.jobs = { hitman = 1 }
        Env.events['local:QBCore:Server:PlayerLoaded'](Env.players[13])
        eq(org.members.RECRUIT1.grade, 1)
        local _ = s
    end)

    it('L3 with ExternalChanges = revert, the same removal is put back', function()
        local _, _, org = world({ configure = function() Config.Organisation.ExternalChanges = 'revert' end })
        QbxJobs.groups.LIEUT001 = nil
        Env.players[12].PlayerData.jobs = {}
        Env.events['local:QBCore:Server:PlayerLoaded'](Env.players[12])
        eq(org.members.LIEUT001.grade, 2)
        eq(QbxJobs.groups.LIEUT001.hitman, 2)
    end)

    it('L3 a removal qbx_core cannot be believed about is put back: cleanPlayerGroups, or a late start', function()
        local s, _, org = world()
        Natives.convars['qbx:cleanPlayerGroups'] = 'true'
        QbxJobs.groups.LIEUT001 = nil
        Env.players[12].PlayerData.jobs = {}
        Env.events['local:QBCore:Server:PlayerLoaded'](Env.players[12])
        eq(QbxJobs.groups.LIEUT001.hitman, 2, 'cleanPlayerGroups emptied it, not anybody')
        Natives.convars['qbx:cleanPlayerGroups'] = 'false'
        -- Online before the job was registered: the start's own resync.
        QbxJobs.groups.RECRUIT1 = nil
        Env.players[13].PlayerData.jobs = {}
        s.org.boot()
        eq(org.members.RECRUIT1 ~= nil or s.org.current().members.RECRUIT1 ~= nil, true)
        eq(QbxJobs.groups.RECRUIT1.hitman, 0, 'put back after a late start')
    end)
end)

describe('organisation review: the accept gate', function()
    local function setup(configure)
        local s, f = W.world({ configure = configure })
        W.crew(s)
        truthy(s.org.hire(W.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, 0))
        return s, f, s.org.current()
    end

    it('M5 the page must echo the cut it showed, and the board card shows it', function()
        local s, f = setup()
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 10))
        local c = W.place(s, f.creator)
        local board = W.call('list', 3, {}).data
        eq(board.orgTerms.orgPercent, 10, 'the card has the cut to show')
        local refused = W.call('accept', 3, { id = c.id, penaltyAmount = 0, shown = {} })
        eq(refused.ok, false)
        eq(refused.err, CH.ERR.TERMS_CHANGED, 'a page that showed no cut is refused')
        local ok = W.call('accept', 3, { id = c.id, penaltyAmount = 0, shown = { orgCut = 10 } })
        eq(ok.ok, true, tostring(ok.err))
    end)

    it('M5 the cut frozen is the one the gate checked, whatever changes during the accept', function()
        local s, f = setup()
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 10))
        local c = W.place(s, f.creator)
        local restore = during(s, 'confirmHitman', function() return true end,
            function() assert(s.org.setCut(W.STAFF, 'payout', nil, 40)) end)
        truthy(s.contracts.accept(s.identity.resolve(3), c.id, false, { checkDisclosure = true, shown = { orgCut = 10 } }))
        restore()
        eq(s.storage.readOrgRow('splits', c.id .. ':HITMAN01').payout_pct, 10, 'the cut shown and checked')
    end)

    it('L4 a gate that raises refuses the acceptance', function()
        local s, f = setup(function() Config.Organisation.RequireJobToAccept = true end)
        local c = W.place(s, f.creator)
        local real = s.contracts.acceptGate
        s.contracts.acceptGate = function() error('store down') end
        local ok, err = s.contracts.accept(s.identity.resolve(3), c.id)
        s.contracts.acceptGate = real
        falsy(ok)
        eq(err, CH.ERR.SERVER_ERROR)
    end)

    it('a staff assignment (Contracts.acceptHeld) freezes the cut the gate checked, as Accept does', function()
        local s, f = setup()
        truthy(s.org.setCut(W.STAFF, 'payout', nil, 10))
        local c = W.place(s, f.creator)
        local restore = during(s, 'confirmHitman', function() return true end,
            function() assert(s.org.setCut(W.STAFF, 'payout', nil, 40)) end)
        local ok, err = s.contracts.serialized({ 'contract:' .. c.id }, s.contracts.acceptHeld,
            s.identity.resolve(3), c.id, false, { staffAssigned = true, waiveStake = true })
        restore()
        truthy(ok, tostring(err))
        eq(s.storage.readOrgRow('splits', c.id .. ':HITMAN01').payout_pct, 10, 'the cut the gate checked')
    end)

    it('a staff assignment refuses when the gate raises, as Accept does', function()
        local s, f = setup(function() Config.Organisation.RequireJobToAccept = true end)
        local c = W.place(s, f.creator)
        local real = s.contracts.acceptGate
        s.contracts.acceptGate = function() error('store down') end
        local ok, err = s.contracts.serialized({ 'contract:' .. c.id }, s.contracts.acceptHeld,
            s.identity.resolve(3), c.id, false, { staffAssigned = true, waiveStake = true })
        s.contracts.acceptGate = real
        falsy(ok)
        eq(err, CH.ERR.SERVER_ERROR)
        eq(s.storage.readHitman(c.id, 'HITMAN01'), nil, 'nobody put on it')
    end)

    it('L5 a member\'s second acceptance counts the first one\'s cooldown, however close', function()
        local s, f = setup()
        truthy(s.org.memberLimits(W.STAFF, 'HITMAN01', 5, 30))
        W.player(21, 'TARGET02')
        local c1 = W.place(s, f.creator, 'TARGET01')
        local c2, why = W.place(s, f.creator, 'TARGET02')
        truthy(c1 and c2, 'two contracts: ' .. tostring(why))
        local hitman = s.identity.resolve(3)
        local second
        local real = s.contracts.onAccepted
        s.contracts.onAccepted = function(...)
            if not second then second = table.pack(s.contracts.accept(hitman, c2.id)) end
            if real then return real(...) end
        end
        truthy(s.contracts.accept(hitman, c1.id))
        s.contracts.onAccepted = real
        falsy(second[1], 'the second waits out the cooldown')
        eq(second[2], 'org_cooldown')
    end)
end)
