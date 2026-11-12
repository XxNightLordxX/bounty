--- Review 84, fixes 2: each confirmed finding, driven through the code the
--- game runs (the org functions, the panel's ops, the phone's requests).
---
---   * LINEREV-1: a dead drop per collection. A later collection on the same
---     contract gets its own drop, its own DeadDropMinutes and a receipt that
---     says it waits at the drop; the first drop's 'refund' returns only its
---     own collection. A drop saved before the change still holds and
---     refunds what it held, and nothing from the next collection on;
---   * VAR-1: the panel's funds ledger names no member nor contract to staff
---     without IdentityAce;
---   * VAR-2: a member is told "by staff" when staff send them off duty, mute
---     them, decide their accept or attach a dossier; "a boss" otherwise;
---   * VAR-3: moving a role with members, deleting the last role and a
---     refusal of Renewed-Banking's society account say what is wrong;
---   * VAR-4: an approved accept the contract refuses says why in words,
---     never the code;
---   * VAR-5: an armory put-in or take-out refused both ways says it is left
---     for staff, and opens a Review item;
---   * MUT-O9, MUT-O4, MUT-O5, MUT-F3, MUT-D3, MUT-I2D2: the gaps the
---     mutation run found in the organisation's cuts, its funds and the
---     payout holds. (VAR-6 is locale_spec's label scan.)

local OW = require('tests.harness.org_world')
local QbxJobs = OW.QbxJobs

local STAFF = { staff = true, cid = 'ADMIN001', source = 6 }
local BOSS = OW.boss(11, 'BOSS0001')

local function world(on, extra, opts)
    opts = opts or {}
    local s, f = OW.world({ bank = opts.bank, configure = function()
        if not opts.bank then Config.Integrations.Banking = 'none' end
        Config.Cooldowns.create = { per = 10, burst = 100 }
        for _, key in ipairs(on or {}) do Config.Organisation[key] = true end
        for k, v in pairs(extra or {}) do Config.Organisation[k] = v end
    end })
    if opts.crew ~= false then OW.crew(s) end
    return s, f, s.org.current()
end

local function spot(s, kind, x, y)
    OW.at(6, x, y, 30.0)
    local ok, err, row = s.org.placeSpot(STAFF, { kind = kind, here = true })
    assert(ok, kind .. ': ' .. tostring(err) .. ' ' .. tostring(row and row.message))
    return row
end

--- Every notice a citizen is sent from here on: [cid] = { text, ... }.
local function told(s)
    local said = {}
    local real = s.notify.toCitizen
    s.notify.toCitizen = function(cid, title, text, ...)
        said[cid] = said[cid] or {}
        table.insert(said[cid], tostring(text))
        return real(cid, title, text, ...)
    end
    return said
end

local function has(list, needle)
    for _, text in ipairs(list or {}) do if tostring(text):find(needle, 1, true) then return true end end
    return false
end

local function lineOf(s, contractId, slot, portion)
    for _, l in ipairs(s.storage.readEscrow(contractId)) do
        if tonumber(l.slot) == slot and l.portion == (portion or CH.PORTION.BASELINE) then return l end
    end
end

local function collect(s, drop)
    OW.at(13, 400.0, 400.0)
    Env.clientEvents = {}
    _G.source = 13
    Env.events['crimson-hitman:orgUse'](drop.id)
    _G.source = nil
end

--------------------------------------------------------------------------
-- LINEREV-1
--------------------------------------------------------------------------

describe('Review 84 LINEREV-1: one dead drop per collection', function()
    local function twoSlots()
        local s, f, org = world({ 'DeadDrops' }, { DeadDropUnclaimed = 'refund', DeadDropMinutes = 60 })
        Config.Limits.MaxPayoutSlots = 2
        Config.Limits.SlotCooldownSeconds = 1
        local drop = spot(s, 'deaddrop', 400.0, 400.0)
        truthy(s.org.setPayoutMethod(STAFF, 'deaddrop'))
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 5000 } }, { baseline = { cash = 5000 } } } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        return s, f, org, c, drop
    end

    it('gives a later collection its own drop, timer and receipt, and refunds only the first', function()
        local s, f, org, c, drop = twoSlots()
        local creator0, member0 = OW.wealth(1), OW.wealth(13)
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING), 'slot 1')
        local first = org.settings.drops[c.id .. ':RECRUIT1:1']
        truthy(first, 'the first collection\'s drop')
        eq(first.slot, 1)
        Env.advance(55 * 60)
        local ok, err, result = s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING)
        truthy(ok, 'slot 2: ' .. tostring(err))
        local second = org.settings.drops[c.id .. ':RECRUIT1:2']
        truthy(second, 'the second collection has a drop of its own')
        eq(second.expires - os.time(), 3600, 'with its own DeadDropMinutes')
        eq(first.expires - os.time(), 300, 'the first keeps its own time')
        truthy(type(result.dropHold) == 'table', 'the claim knows it waits at the drop')
        local _, body = s.notify.hitmanReceipt(s.storage.readContract(c.id), false, result)
        truthy(body:find('dead drop', 1, true), body)
        falsy(body:find('make room', 1, true), body)
        eq(OW.wealth(13), member0, 'both wait')
        -- The first runs out under 'refund': only its own collection goes back.
        Env.advance(6 * 60)
        s.org.extrasTick(os.time())
        eq(org.settings.drops[c.id .. ':RECRUIT1:1'], nil, 'the first ended')
        truthy(org.settings.drops[c.id .. ':RECRUIT1:2'], 'the second still waits')
        eq(OW.wealth(1) - creator0, 5000, 'only the first collection back to the placer')
        local two = lineOf(s, c.id, 2)
        eq(two.owed_to, 'RECRUIT1', 'the second is still the member\'s')
        eq(two.state, CH.ESCROW_STATE.HELD)
        eq(OW.wealth(13), member0)
        -- Collected at the drop: the member is paid the second.
        collect(s, drop)
        eq(OW.wealth(13) - member0, 5000, 'paid the second collection')
        eq(next(org.settings.drops), nil)
        eq((OW.wealth(1) - creator0) + (OW.wealth(13) - member0), 10000, 'all of the escrowed 10000 accounted for')
    end)

    it('keeps a drop saved before the change working, for what it held and nothing after', function()
        local s, f, org, c, drop = twoSlots()
        local creator0, member0 = OW.wealth(1), OW.wealth(13)
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING), 'slot 1')
        -- As the older build saved it: keyed by the contract and the member,
        -- no slot, read back at a start.
        local saved = org.settings.drops[c.id .. ':RECRUIT1:1']
        org.settings.drops[c.id .. ':RECRUIT1:1'] = nil
        saved.slot = nil
        org.settings.drops[c.id .. ':RECRUIT1'] = saved
        require('server.org.extras3').loaded()
        truthy(s.escrow.holdBack('RECRUIT1', lineOf(s, c.id, 1)), 'the saved drop still holds its payout')
        s.escrow.retryPending('RECRUIT1')
        eq(OW.wealth(13), member0, 'not paid around it')
        Env.advance(55 * 60)
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING), 'slot 2')
        truthy(org.settings.drops[c.id .. ':RECRUIT1:2'], 'the next collection gets its own drop')
        eq(saved.before, 2, 'and the saved one holds nothing from it on')
        Env.advance(6 * 60)
        s.org.extrasTick(os.time())
        eq(org.settings.drops[c.id .. ':RECRUIT1'], nil, 'the saved drop ran out')
        eq(OW.wealth(1) - creator0, 5000, 'its own collection refunded, not the next')
        eq(lineOf(s, c.id, 2).owed_to, 'RECRUIT1')
        collect(s, drop)
        eq(OW.wealth(13) - member0, 5000, 'the second paid at the drop')
    end)
end)

--------------------------------------------------------------------------
-- VAR-1
--------------------------------------------------------------------------

describe('Review 84 VAR-1: the funds ledger without IdentityAce', function()
    it('names neither the member nor the contract of a row to staff without it', function()
        local s, _, org = world()
        truthy(s.org.Funds.credit(org, 500, { ref = 'cut:test1', kind = 'cut', actor = 'RECRUIT1',
            contract = 'CONTRACTX', reason = 'payout' }))
        local reply = OW.ask(6, 'orgFunds', { limit = 10 })
        truthy(reply and reply.ok, 'read')
        local row = reply.data.rows[1]
        eq(row.kind, 'cut')
        eq(row.amount, 500)
        eq(row.actor, nil, 'no member')
        eq(row.contract, nil, 'no contract')
        Env.aces[6]['crimson.identity'] = true
        row = OW.ask(6, 'orgFunds', { limit = 10 }).data.rows[1]
        eq(row.actor, 'RECRUIT1', 'with IdentityAce, who')
        eq(row.contract, 'CONTRACTX', 'and the contract')
    end)
end)

--------------------------------------------------------------------------
-- VAR-2
--------------------------------------------------------------------------

describe('Review 84 VAR-2: a member is told staff did it, never "a boss"', function()
    it('off duty, muted, an accept decided and a dossier attached, by staff and by a boss', function()
        local s, f = world({ 'Duty', 'Channel', 'AcceptApproval', 'Dossiers', 'OrgContracts' },
            { ApprovalAbove = 1000, DutyAtOffice = false })
        local said = told(s)
        local recruit = s.identity.resolve(13)
        truthy(s.org.setDuty({ cid = 'RECRUIT1', source = 13 }, true))
        truthy(s.org.forceOffDuty(STAFF, 'RECRUIT1'))
        truthy(has(said.RECRUIT1, 'You were sent off duty by staff.'), table.concat(said.RECRUIT1 or {}, ' / '))
        truthy(s.org.channelMute(STAFF, 'RECRUIT1', 1))
        truthy(has(said.RECRUIT1, 'You were muted in the organisation channel by staff for 1 hour.'))
        truthy(s.org.channelMute(STAFF, 'RECRUIT1', 2))
        truthy(has(said.RECRUIT1, 'You were muted in the organisation channel by staff for 2 hours.'))
        OW.allow(s, 3, 'N3')
        truthy(s.org.channelMute(BOSS, 'RECRUIT1', 1))
        truthy(has(said.RECRUIT1, 'A boss muted you in the organisation channel for 1 hour.'))
        -- An accept waiting for approval, refused and then approved by staff.
        OW.allow(s, 2, 'K6')
        truthy(s.org.setDuty({ cid = 'RECRUIT1', source = 13 }, true), 'back on duty')
        truthy(s.org.setDuty({ cid = 'LIEUT001', source = 12 }, true))
        local c = OW.place(s, f.creator)
        eq(select(2, s.contracts.accept(recruit, c.id)), 'org_approval')
        local waiting = OW.call('orgWork', 12, {}).data.approvals[1]
        truthy(s.org.decideAccept(STAFF, waiting.id, false))
        truthy(has(said.RECRUIT1, 'Your accept was refused by staff. Nothing was taken.'))
        eq(select(2, s.contracts.accept(recruit, c.id)), 'org_approval')
        waiting = OW.call('orgWork', 12, {}).data.approvals[1]
        truthy(s.org.decideAccept(STAFF, waiting.id, true))
        truthy(has(said.RECRUIT1, 'Your accept was approved by staff: the contract is yours.'))
        -- A dossier staff attach.
        -- On somebody outside the organisation: one on its own member is
        -- never held for it (Review 85 C7-2).
        local c2 = OW.place(s, f.creator, 'READER01')
        truthy(s.org.receiveContract(c2.id, 'BOSS0001'))
        truthy(s.org.assignContract(STAFF, c2.id, 'RECRUIT1'))
        truthy(s.org.writeDossier(STAFF, c2.id, { notes = 'Quiet job' }))
        truthy(has(said.RECRUIT1, 'A dossier was attached by staff to a contract assigned to you.'))
        falsy(has(said.RECRUIT1, 'A boss sent you'), 'never "a boss" for staff')
        falsy(has(said.RECRUIT1, 'A boss refused'))
        falsy(has(said.RECRUIT1, 'A boss approved'))
        falsy(has(said.RECRUIT1, 'A boss attached'))
        falsy(has(said.RECRUIT1, 'hour(s)'), 'a proper plural')
    end)
end)

--------------------------------------------------------------------------
-- VAR-3 and VAR-4
--------------------------------------------------------------------------

describe('Review 84 VAR-3: the refusals say what is wrong', function()
    it('moving a role with members, and deleting the last role', function()
        local s = world()
        local ok, err, _, says = s.org.roleEdit(STAFF, 0, { newGrade = 7 })
        falsy(ok)
        eq(err, 'org_rule', 'no limit staff set is involved')
        eq(says, 'Only an empty role can be moved to another grade: move its members first.')
        local s2, _, org = world(nil, nil, { crew = false })
        local grades = {}
        for g in pairs(org.roles) do grades[#grades + 1] = g end
        table.sort(grades)
        for i = 1, #grades - 1 do truthy(s2.org.roleDelete(STAFF, grades[i]), 'role ' .. grades[i]) end
        ok, err, _, says = s2.org.roleDelete(STAFF, grades[#grades])
        falsy(ok)
        eq(err, 'org_rule')
        eq(says, 'The organisation needs at least one role.')
    end)

    it('words a refusal of Renewed-Banking\'s society account as its own', function()
        local s = world(nil, nil, { bank = true })
        QbxJobs.refuse.add = true
        local ok, err, _, says = s.org.staffDeposit(STAFF, 500, 'Opening float')
        QbxJobs.refuse.add = nil
        falsy(ok)
        eq(err, 'org_bank_refused', says)
        falsy(tostring(says):find('qbx_core', 1, true), says)
    end)
end)

describe('Review 84 VAR-4: an approved accept the contract refuses', function()
    it('says why in words, never the code', function()
        local s, f = world({ 'AcceptApproval' }, { ApprovalAbove = 1000 })
        OW.allow(s, 2, 'K6')
        local c = OW.place(s, f.creator)
        eq(select(2, s.contracts.accept(s.identity.resolve(13), c.id, false)), 'org_approval')
        local waiting = OW.call('orgWork', 12, {}).data.approvals[1]
        truthy(s.org.suspend(STAFF, 'RECRUIT1', 2, 'Late'))
        local r = OW.call('orgApprove', 12, { id = waiting.id, approve = true })
        falsy(r.ok)
        local says = tostring(r.data and r.data.message)
        truthy(says:find('Approved, but the contract would not take it now: ', 1, true), says)
        truthy(says:find('Nothing was taken.', 1, true), says)
        falsy(says:find('(', 1, true), 'no code in brackets: ' .. says)
        falsy(says:find('suspended)', 1, true), says)
        falsy(says:find('_', 1, true), 'no code: ' .. says)
    end)
end)

--------------------------------------------------------------------------
-- VAR-5 (the phone and the inventory as the game has them)
--------------------------------------------------------------------------

local W = require('tests.workflows.lib')
local Natives = require('tests.harness.natives')
local C = W.CAST
local WBOSS, M2, M3 = C.boss.source, C.hitman2.source, C.guard.source
local WSTAFF = C.staff.source

local function tap(src, name, payload)
    if W.clientSrc ~= src then W.client(src) end
    local a, answered = W.nui('crimson:' .. name, payload or {})
    truthy(answered, name .. ' never answered')
    if type(a) == 'table' and a.ok then return true, a.data end
    return false, a and a.err, a and a.data and a.data.message
end

local function must(src, name, payload)
    local ok, d, m = tap(src, name, payload)
    if not ok then error(('%s by %s refused: %s / %s'):format(name, src, tostring(d), tostring(m)), 2) end
    return d
end

local function lockpicks(src)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == 'lockpick' then n = n + (e.count or 0) end
    end
    return n
end

local function armoryOrg()
    W.boot('memory', 'shipped', function()
        local O = Config.Organisation
        O.Enabled = true
        O.Armory = true
        O.ArmoryItems = { 'lockpick' }
    end)
    W.Client, W.clientSrc = nil, nil
    W.cast(W.s)
    W.allAt()
    W.opOk(WSTAFF, 'orgSetup', {}, 'set up')
    W.opOk(WSTAFF, 'orgMemberHire', { subject = C.boss.cid, grade = 3 }, 'hire the boss')
    local cells = {}
    for _, p in ipairs(require('server.org.powers').LIST) do
        cells[#cells + 1] = { subject = 'role', id = 3, power = p.code, state = 'allow' }
    end
    W.opOk(WSTAFF, 'bossPermsSet', { cells = cells }, 'boss role all powers')
    W.opOk(WSTAFF, 'placeSet', { kind = 'office', here = true, label = 'Back room' }, 'the office')
    W.tick(1)
    for _, src in ipairs({ M2, M3 }) do
        must(WBOSS, 'orgHire', { target = src, grade = 0 })
        local mine = must(src, 'orgMine', {})
        must(src, 'orgInviteAnswer', { id = mine.invite.id, accept = true })
    end
    return W.s.org.current()
end

local function reviews(kind)
    local out = {}
    for _, r in ipairs(W.s.storage.reviewItems(true, 100) or {}) do
        if r.kind == kind then out[#out + 1] = r end
    end
    return out
end

describe('Review 84 VAR-5: the armory refused both ways', function()
    it('says a put-in is left for staff, and opens a Review item for it', function()
        armoryOrg()
        local _, av = tap(M2, 'orgArmory', {})
        local before = lockpicks(M2)
        local ox = Natives.exportTables.ox_inventory
        local realAdd = ox.AddItem
        ox.AddItem = function() return false end
        local ok, err, says = tap(M2, 'orgArmoryPut', { slot = av.own[1].slot, count = 2 })
        ox.AddItem = realAdd
        falsy(ok)
        eq(err, 'org_left_for_staff')
        falsy(tostring(says):find('back with you', 1, true), says)
        truthy(tostring(says):find('left for staff', 1, true), says)
        eq(lockpicks(M2), before - 2, 'gone from the member, as the game would have it')
        local items = reviews('org_armory_refund_failed')
        eq(#items, 1, 'one Review item for staff')
        local item = items[1]
        local cids = type(item.cids) == 'table' and item.cids or {}
        eq(cids.member, C.hitman2.cid)
        eq(item.items[1].item, 'lockpick')
        eq(item.items[1].quantity, 2)
        eq(item.known.dir, 'in')
    end)

    it('says a take-out is left for staff, and opens a Review item for it', function()
        armoryOrg()
        local _, av = tap(M2, 'orgArmory', {})
        must(M2, 'orgArmoryPut', { slot = av.own[1].slot, count = 2 })
        must(WBOSS, 'orgArmoryLimit', { grade = 0, count = 1 })
        _, av = tap(M3, 'orgArmory', {})
        local ox = Natives.exportTables.ox_inventory
        local realAdd = ox.AddItem
        ox.AddItem = function() return false end
        local ok, err, says = tap(M3, 'orgArmoryTake', { slot = av.items[1].slot, count = 1 })
        ox.AddItem = realAdd
        falsy(ok)
        eq(err, 'org_left_for_staff')
        falsy(tostring(says):find('it is back in the armory', 1, true), says)
        truthy(tostring(says):find('left for staff', 1, true), says)
        local items = reviews('org_armory_refund_failed')
        eq(#items, 1)
        eq(items[1].known.dir, 'out')
        eq(items[1].cids.member, C.guard.cid)
    end)

    it('still says it is back with you when it is', function()
        armoryOrg()
        local _, av = tap(M2, 'orgArmory', {})
        local before = lockpicks(M2)
        local ox = Natives.exportTables.ox_inventory
        local realAdd = ox.AddItem
        local first = true
        ox.AddItem = function(...)
            if first then first = false return false end
            return realAdd(...)
        end
        local ok, err, says = tap(M2, 'orgArmoryPut', { slot = av.own[1].slot, count = 2 })
        ox.AddItem = realAdd
        falsy(ok)
        eq(err, 'org_refused')
        eq(says, 'The armory would not take it; it is back with you.')
        eq(lockpicks(M2), before, 'back with them')
        eq(#reviews('org_armory_refund_failed'), 0, 'nothing for staff')
    end)
end)

--------------------------------------------------------------------------
-- The mutation run's gaps
--------------------------------------------------------------------------

describe('Review 84 MUT-O9, MUT-O4, MUT-O5: the organisation\'s cut', function()
    local function member(s, grade)
        truthy(s.org.hire(OW.STAFF, { cid = 'HITMAN01', name = 'Rook', source = 3 }, grade or 0))
        return s.identity.resolve(3)
    end

    it('O9: holds a cut set before staff lowered TotalCutCapPercent to the new cap, and pays by it', function()
        local s, f, org = world()
        local hitman = member(s)
        truthy(s.org.setCut(STAFF, 'payout', nil, 40))
        org.settings.limits = org.settings.limits or {}
        org.settings.limits.TotalCutCapPercent = 20
        eq(s.org.payoutPercent(org, org.members.HITMAN01), 20, 'the organisation\'s, held to the cap')
        eq(s.org.termsFor('HITMAN01').orgPercent, 20, 'and the accept page says so')
        org.settings.limits.TotalCutCapPercent = 40
        truthy(s.org.setCut(STAFF, 'role', 0, 35))
        truthy(s.org.setCut(STAFF, 'member', 'HITMAN01', 30))
        org.settings.limits.TotalCutCapPercent = 20
        eq(s.org.payoutPercent(org, org.members.HITMAN01), 20, 'the member\'s own, held to it')
        truthy(s.org.setCut(STAFF, 'member', 'HITMAN01', false))
        eq(s.org.payoutPercent(org, org.members.HITMAN01), 20, 'the role\'s, held to it')
        local before = OW.wealth(3)
        local c = OW.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(s.org.Funds.balance(org), 1000, 'the funds took 20%')
        eq(OW.wealth(3) - before, 4000, 'the member kept 80%')
    end)

    it('O4: rounds a cut of an amount that does not divide evenly down, for the member', function()
        local s, f, org = world()
        local hitman = member(s)
        truthy(s.org.setCut(STAFF, 'payout', nil, 25))
        local before = OW.wealth(3)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5001 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(hitman, c.id))
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.KIDNAPPING))
        eq(s.org.Funds.balance(org), 1250, 'floor(5001 * 25%)')
        eq(OW.wealth(3) - before, 3751, 'the odd dollar is the member\'s')
    end)

    it('O5: takes no cut on a retry after part of the payout already arrived', function()
        local s, f, org = world()
        local hitman = member(s)
        truthy(s.org.setCut(STAFF, 'payout', nil, 20))
        local c = OW.place(s, f.creator)
        truthy(s.contracts.accept(hitman, c.id))
        local line = { id = c.id .. ':part', contract_id = c.id, portion = CH.PORTION.BASELINE, slot = 1,
            source = 'cash', amount = 1000, deliver_arrived = 400 }
        local before = OW.wealth(3)
        truthy(s.escrow.deliver('HITMAN01', line), 'the rest given')
        eq(OW.wealth(3) - before, 600, 'exactly the rest')
        eq(s.org.Funds.balance(org), 0, 'the funds take nothing the member never got from escrow')
    end)
end)

describe('Review 84 MUT-F3: Renewed-Banking\'s exact balance', function()
    it('lets a boss take the whole society balance, leaving 0', function()
        local s, _, org = world(nil, nil, { bank = true })
        for _, code in ipairs({ 'C6', 'C7', 'C8' }) do OW.allow(s, 3, code) end
        OW.office(s)
        OW.at(11, 100.0, 100.0)
        truthy(s.org.staffDeposit(STAFF, 1000, 'Float'))
        eq(QbxJobs.bank.hitman, 1000)
        local ok, err = s.org.withdraw(BOSS, 1000, 'Rent', 'all')
        truthy(ok, 'the whole balance: ' .. tostring(err))
        eq(QbxJobs.bank.hitman, 0)
        eq(s.org.Funds.balance(org), 0)
    end)
end)

describe('Review 84 MUT-D3: a drop whose organisation is no longer loaded', function()
    it('holds nothing: the member is paid in full and the funds take nothing', function()
        local s, f, org = world({ 'DeadDrops' })
        spot(s, 'deaddrop', 400.0, 400.0)
        truthy(s.org.setPayoutMethod(STAFF, 'deaddrop'))
        truthy(s.org.setCut(STAFF, 'payout', nil, 10))
        local before = OW.wealth(13)
        local c = OW.place(s, f.creator)
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        truthy(next(org.settings.drops), 'waiting at the drop')
        eq(OW.wealth(13), before)
        -- Read again live, and the store will not give the organisation back.
        local read = s.storage.readOrgRow
        s.storage.readOrgRow = function() error('the store is down') end
        s.org.boot(true)
        s.storage.readOrgRow = read
        eq(s.org.current(), nil, 'not loaded')
        s.escrow.retryPending('RECRUIT1')
        eq(OW.wealth(13) - before, 5000, 'paid in full, no drop left to wait on')
    end)
end)

describe('Review 84 MUT-I2D2: holds leave the hitman\'s other lines alone', function()
    local function lines(contractId, cid)
        return {
            stake = { id = contractId .. ':stake-back', contract_id = contractId, slot = 0, portion = CH.PORTION.STAKE,
                staker = cid, source = 'cash', amount = 300 },
            refund = { id = contractId .. ':owed-back', contract_id = contractId, slot = 0, portion = CH.PORTION.OWED,
                owed_to = cid, source = 'cash', amount = 200, metadata = {} },
            payout = { id = contractId .. ':extra-pay', contract_id = contractId, slot = 1, portion = CH.PORTION.BASELINE,
                source = 'cash', amount = 100 },
        }
    end

    it('a dead drop holds the payout and not a stake or a refund on the same contract', function()
        local s, f, org = world({ 'DeadDrops' })
        spot(s, 'deaddrop', 400.0, 400.0)
        truthy(s.org.setPayoutMethod(STAFF, 'deaddrop'))
        local c = OW.place(s, f.creator)
        truthy(s.contracts.accept(s.identity.resolve(13), c.id))
        truthy(s.contracts.claimSlot(c.id, 'RECRUIT1', CH.FULFILMENT.KIDNAPPING))
        truthy(next(org.settings.drops), 'a drop waits')
        local l = lines(c.id, 'RECRUIT1')
        local before = OW.wealth(13)
        truthy(s.escrow.deliver('RECRUIT1', l.stake), 'the stake back at once')
        truthy(s.escrow.deliver('RECRUIT1', l.refund), 'the refund at once')
        eq(OW.wealth(13) - before, 500)
        falsy(s.escrow.deliver('RECRUIT1', l.payout), 'the payout waits at the drop')
        eq(OW.wealth(13) - before, 500)
    end)

    it('proof of intent holds the payout and not a stake or a refund on the same contract', function()
        local s = newStack()
        local f = fixture(s)
        Config.Roleplay.ProofOfIntent.Enabled = true
        Config.Roleplay.ProofOfIntent.MinMessages = 3
        Config.Roleplay.ProofOfIntent.HoldMaxMinutes = 60
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c, 'placed')
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local ok, err, result = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(ok, tostring(err))
        truthy(result.intentHold, 'held for intent')
        local l = lines(c.id, 'HITMAN01')
        local before = OW.wealth(3)
        truthy(s.escrow.deliver('HITMAN01', l.stake), 'the stake back at once')
        truthy(s.escrow.deliver('HITMAN01', l.refund), 'the refund at once')
        eq(OW.wealth(3) - before, 500)
        falsy(s.escrow.deliver('HITMAN01', l.payout), 'the payout waits for intent')
        eq(OW.wealth(3) - before, 500)
    end)
end)
