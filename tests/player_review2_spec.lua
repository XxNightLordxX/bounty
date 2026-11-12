--- Player-journey review fixes, round 2 (the boss's and staff's journeys),
--- each driven through the real phone callbacks and the panel's ops:
---
---   * BOSS-1: a member fired (or out of the job) while a payout waits at
---     the dead drop is paid it, never left at a spot they cannot use nor
---     sent back to the placer under DeadDropUnclaimed = 'refund';
---   * BOSS-2: the hitman's receipt says the payout waits at the dead drop,
---     not "released to you ... make room";
---   * BOSS-3 / EXPLOITER-1: the armory's day limits, StrikesPerDay,
---     PromotionsPerDay and FireCooldownMinutes outlast a restart;
---   * BOSS-4: a role's power given by a boss who can no longer pass it on
---     reads as not in force on Roles;
---   * BOSS-5: a member is told when fired (with the reason), suspended or
---     lifted, and moved to another role; never who by name;
---   * BOSS-6: the refusals say what is wrong;
---   * STAFF-1: no catalogue setting is treated as a secret;
---   * STAFF-2: a save made from a stale read, or an Undo of an older row, is
---     refused rather than written over a newer change;
---   * STAFF-3: a name lookup says "N people match" or "nobody by that name";
---   * STAFF-4: Reassign's preview says when anonymous hitmen are off.

local W = require('tests.workflows.lib')
local F = require('tests.workflows.flows')
local Natives = require('tests.harness.natives')
local Env = Natives.env

local C = W.CAST
local BOSS, M1, M2, M3 = C.boss.source, C.hitman.source, C.hitman2.source, C.guard.source
local STAFF = C.staff.source

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

--- The handle the viewer's Members screen gives a member.
local function refOf(viewer, cid)
    local d = must(viewer, 'orgMembers', {})
    local m = W.s.org.current().members[cid]
    for _, r in ipairs(d.rows or {}) do
        if (r.realName and m and r.realName == m.name) or (m and r.name == (m.codename or m.name)) then return r.ref end
    end
    error('no row for ' .. cid)
end

local function lockpicks(src)
    local n = 0
    for _, e in ipairs(Env.players[src]._inventory or {}) do
        if e.name == 'lockpick' then n = n + (e.count or 0) end
    end
    return n
end

--- The organisation as an owner turns it on: staff set it up, the boss
--- holds every power at the office, three members hired by invite.
local function org(mode, extra)
    W.boot(mode or 'memory', 'shipped', function()
        local O = Config.Organisation
        O.Enabled = true
        O.Armory = true
        O.ArmoryItems = { 'lockpick' }
        O.Discipline = true
        O.DeadDrops = true
        if extra then extra(O) end
    end)
    W.Client, W.clientSrc = nil, nil
    W.cast(W.s)
    W.allAt()
    W.opOk(STAFF, 'orgSetup', {}, 'set up')
    W.opOk(STAFF, 'orgMemberHire', { subject = C.boss.cid, grade = 3 }, 'hire the boss')
    local cells = {}
    for _, p in ipairs(require('server.org.powers').LIST) do
        cells[#cells + 1] = { subject = 'role', id = 3, power = p.code, state = 'allow' }
    end
    W.opOk(STAFF, 'bossPermsSet', { cells = cells }, 'boss role all powers')
    W.opOk(STAFF, 'placeSet', { kind = 'office', here = true, label = 'Back room' }, 'the office')
    W.tick(1)
    for _, src in ipairs({ M1, M2, M3 }) do
        must(BOSS, 'orgHire', { target = src, grade = 0 })
        local mine = must(src, 'orgMine', {})
        must(src, 'orgInviteAnswer', { id = mine.invite.id, accept = true })
    end
    return W.s.org.current()
end

--- A $5,000 handover by M1, paid at the dead drop 'Bin'.
local function dropWaiting()
    W.opOk(STAFF, 'placeSet', { kind = 'deaddrop', here = true, label = 'Bin' })
    must(BOSS, 'orgPayoutMethod', { method = 'deaddrop' })
    local ctx = { reward = 5000 }
    for _, step in ipairs({ F.stepPlace(), F.stepAccept('hitman'), F.stepHandover(), F.stepPayout() }) do
        step.run(ctx)
    end
    W.tick(1, 60)
    return ctx
end

describe('BOSS-1: a payout at the dead drop when the member leaves', function()
    for _, rule in ipairs({ 'refund', 'pay' }) do
        it('fired with DeadDropUnclaimed = ' .. rule .. ': paid at once, never back to the placer', function()
            local o = org('memory', function(O) O.DeadDropUnclaimed = rule end)
            local hitman0 = W.purse(W.everyone[C.hitman.cid])
            local placer0 = W.purse(W.everyone[C.creator.cid])
            local world0 = W.world()
            dropWaiting()
            eq(W.purse(W.everyone[C.hitman.cid]) - hitman0, 0, 'waiting at the drop')
            truthy(next(o.settings.drops), 'a drop waits')
            must(BOSS, 'orgFire', { member = refOf(BOSS, C.hitman.cid), reason = 'skimming' })
            W.tick(1, 60)
            eq(W.purse(W.everyone[C.hitman.cid]) - hitman0, 5000, 'paid on leaving')
            eq(next(o.settings.drops), nil, 'no drop left waiting')
            for _ = 1, 70 do W.tick(1, 60) end
            eq(W.purse(W.everyone[C.hitman.cid]) - hitman0, 5000, 'and kept')
            eq(W.purse(W.everyone[C.creator.cid]) - placer0, -5000, 'the placer paid for it')
            eq(W.world() - world0, 0, 'nothing made or lost')
            truthy(W.has(W.notices(M1), 'were handed over to you'), 'told')
            falsy(W.has(W.notices(M1), 'went back to the placer'), 'never told it went back')
            local left = W.audit('org_drop_expired')
            truthy(#left == 1 and tostring(left[1].detail and left[1].detail.why or left[1].detail):find('left'),
                'on the record as left')
        end)
    end

    it('taken out of the job by another script (adopted): paid too', function()
        local o = org('memory', function(O) O.DeadDropUnclaimed = 'refund' end)
        local hitman0 = W.purse(W.everyone[C.hitman.cid])
        dropWaiting()
        W.s.org.external(W.s.identity.resolve(M1), nil)
        W.tick(1, 60)
        eq(o.members[C.hitman.cid], nil, 'out')
        eq(W.purse(W.everyone[C.hitman.cid]) - hitman0, 5000)
    end)

    it('a drop still waiting for somebody no longer a member is paid, not refunded, when it runs out', function()
        local o = org('memory', function(O) O.DeadDropUnclaimed = 'refund' end)
        local hitman0 = W.purse(W.everyone[C.hitman.cid])
        dropWaiting()
        -- Gone without the hand-over (a crash between the two).
        o.members[C.hitman.cid] = nil
        for _ = 1, 70 do W.tick(1, 60) end
        eq(W.purse(W.everyone[C.hitman.cid]) - hitman0, 5000)
    end)
end)

describe('BOSS-2: the receipt of a payout held at the dead drop', function()
    it('says where it waits and for how long, never "released" or "make room"', function()
        org('memory')
        dropWaiting()
        local receipt
        for _, line in ipairs(W.notices(M1)) do
            if line:find('Handover paid', 1, true) then receipt = line end
        end
        truthy(receipt, 'a receipt')
        truthy(receipt:find('waits at the dead drop (Bin)', 1, true), receipt)
        truthy(receipt:find('within 60 minutes', 1, true), receipt)
        falsy(receipt:find('released to you', 1, true), receipt)
        falsy(receipt:find('make room', 1, true), receipt)
    end)
end)

describe('BOSS-3 / EXPLOITER-1: the per-day caps outlast a restart', function()
    for _, mode in ipairs({ 'json', 'mysql' }) do
        it('the armory role limit (' .. mode .. ')', function()
            org(mode)
            local _, av = tap(M2, 'orgArmory', {})
            must(M2, 'orgArmoryPut', { slot = av.own[1].slot, count = 2 })
            must(BOSS, 'orgArmoryLimit', { grade = 0, count = 1 })
            _, av = tap(M3, 'orgArmory', {})
            must(M3, 'orgArmoryTake', { slot = av.items[1].slot, count = 1 })
            local ok, err = tap(M3, 'orgArmoryTake', { slot = av.items[1].slot, count = 1 })
            eq(ok, false)
            eq(err, 'org_limit')
            local before = lockpicks(M3)
            Env.advance(6 * 3600)
            W.restart(W.s, true)
            W.tick(1)
            W.Client, W.clientSrc = nil, nil
            _, av = tap(M3, 'orgArmory', {})
            eq(av.left, 0, 'none left today after the restart')
            ok, err = tap(M3, 'orgArmoryTake', { slot = av.items[1].slot, count = 1 })
            eq(ok, false, 'refused after the restart')
            eq(err, 'org_limit')
            eq(lockpicks(M3), before)
            -- And a day after the take, the limit is back.
            Env.advance(18 * 3600 + 60)
            _, av = tap(M3, 'orgArmory', {})
            eq(av.left, 1, 'a new day')
        end)
    end

    it('StrikesPerDay, PromotionsPerDay and FireCooldownMinutes (json, a crash)', function()
        org('json')
        W.opOk(STAFF, 'bossLimits', { limits = { StrikesPerDay = 1, PromotionsPerDay = 1, FireCooldownMinutes = 600 } })
        must(BOSS, 'orgStrike', { member = refOf(BOSS, C.hitman.cid), kind = 'warning', reason = 'Late' })
        must(BOSS, 'orgSetRole', { member = refOf(BOSS, C.hitman.cid), grade = 1 })
        must(BOSS, 'orgFire', { member = refOf(BOSS, C.guard.cid), reason = 'gone' })
        Env.advance(3600)
        W.restart(W.s, false)
        W.tick(1)
        W.Client, W.clientSrc = nil, nil
        local ok, err = tap(BOSS, 'orgStrike', { member = refOf(BOSS, C.hitman2.cid), kind = 'warning', reason = 'Late' })
        eq(err, 'org_limit', 'one strike a day: ' .. tostring(ok))
        ok, err = tap(BOSS, 'orgSetRole', { member = refOf(BOSS, C.hitman2.cid), grade = 1 })
        eq(err, 'org_limit', 'one role move a day: ' .. tostring(ok))
        ok, err = tap(BOSS, 'orgFire', { member = refOf(BOSS, C.hitman2.cid), reason = 'again' })
        eq(err, 'org_cooldown', 'the fire cooldown: ' .. tostring(ok))
    end)
end)

describe('BOSS-4: a power given by a boss who can no longer pass it on', function()
    it('reads as not in force on Roles, and Give gives it again', function()
        local o = org('memory')
        must(BOSS, 'orgSetRole', { member = refOf(BOSS, C.hitman.cid), grade = 2 })
        must(BOSS, 'orgRolePowers', { grade = 2, power = 'M1', on = true })
        local function row2(src)
            local _, roles = tap(src, 'orgRoles', {})
            for _, r in ipairs(roles.rows or {}) do if r.grade == 2 then return r end end
        end
        eq(row2(BOSS).powers.M1.inactive, nil, 'in force while the boss holds it')
        W.opOk(STAFF, 'orgMemberRole', { subject = C.guard.cid, grade = 3 })
        W.opOk(STAFF, 'orgMemberFire', { subject = C.boss.cid, reason = 'gone' })
        local seen = row2(M3).powers.M1
        eq(seen.by, 'boss')
        eq(seen.inactive, 'granter_gone')
        must(M3, 'orgRolePowers', { grade = 2, power = 'M1', on = true })
        eq(row2(M3).powers.M1.inactive, nil, 'given again: in force')
        truthy(W.s.org.Engine.holds(o, C.hitman.cid, 'M1'))
    end)
end)

describe('BOSS-5: what a member is told', function()
    it('fired with the reason, suspended and lifted, moved to another role; never named', function()
        org('memory')
        must(BOSS, 'orgSuspend', { member = refOf(BOSS, C.hitman.cid), hours = 2, reason = 'late to the meet' })
        truthy(W.has(W.notices(M1), 'suspended from taking contracts for 2 hour(s). Reason: late to the meet'))
        must(BOSS, 'orgSuspend', { member = refOf(BOSS, C.hitman.cid), hours = 0 })
        truthy(W.has(W.notices(M1), 'Your suspension was lifted'))
        must(BOSS, 'orgSetRole', { member = refOf(BOSS, C.hitman2.cid), grade = 1 })
        truthy(W.has(W.notices(M2), 'Your role in the organisation is now'))
        must(BOSS, 'orgFire', { member = refOf(BOSS, C.guard.cid), reason = 'leak' })
        truthy(W.has(W.notices(M3), 'removed from the organisation by a boss. Reason: leak'))
        for _, src in ipairs({ M1, M2, M3 }) do
            falsy(W.has(W.notices(src), 'Bea'), 'the boss is never named')
        end
        W.opOk(STAFF, 'orgMemberFire', { subject = C.hitman2.cid, reason = 'staff call' })
        truthy(W.has(W.notices(M2), 'by staff. Reason: staff call'))
    end)
end)

describe('BOSS-6: refusals that say what is wrong', function()
    it('a role with members, and a deposit of more than you have', function()
        org('memory')
        local ok, err, says = tap(BOSS, 'orgRoleDelete', { grade = 0 })
        eq(ok, false)
        eq(err, 'org_rule')
        truthy(tostring(says):find('Only an empty role can be deleted', 1, true), says)
        ok, err, says = tap(BOSS, 'orgDeposit', { amount = 10000000, account = 'bank', nonce = 'n1' })
        eq(ok, false)
        eq(err, CH.ERR.INSUFFICIENT)
        truthy(tostring(says):find('You do not have that much', 1, true), says)
    end)
end)

describe('STAFF-1: no catalogue setting is a secret', function()
    it('every catalogue key reads as an ordinary setting; the deny list\'s webhooks stay secret', function()
        W.boot('memory', 'shipped')
        local Settings = W.s.settings
        local caught = {}
        for _, row in ipairs({ 'features', 'limits', 'readonly' }) do
            for _, entry in ipairs(Settings.view()[row] or {}) do
                if Settings.entry(entry.key) and Settings.secretKey(entry.key) then caught[#caught + 1] = entry.key end
            end
        end
        eq(table.concat(caught, ', '), '')
        truthy(Settings.secretKey('convar:crimson_hitman_webhook'))
        truthy(Settings.secretKey('Some.UnknownToken'), 'a name outside the catalogue still guards')
    end)

    it('the time to verify a kill has its values and Undo in Change history, and is exported', function()
        W.boot('memory', 'shipped')
        W.cast(W.s)
        W.opOk(STAFF, 'setSetting', { key = 'Completion.PhotoTokenLifetimeSeconds', value = 300 })
        local log = W.opOk(STAFF, 'logs', { area = 'settings' })
        local row
        for _, r in ipairs(log.rows or {}) do if r.key == 'Completion.PhotoTokenLifetimeSeconds' then row = r end end
        truthy(row, 'in the history')
        eq(row.new, 300)
        truthy(row.ref, 'with Undo')
        falsy(row.secret)
        local body = json.decode(W.s.settingsio.export().text)
        eq(body.settings['Completion.PhotoTokenLifetimeSeconds'], 300, 'exported')
    end)
end)

describe('STAFF-2: a save made from a stale read', function()
    local KEY = 'Advisory.RecipientJobNames'
    it('is refused, and the newer change kept', function()
        W.boot('memory', 'shipped')
        W.cast(W.s)
        local read = W.s.settings.valueOf(KEY)
        local a = {}
        for _, n in ipairs(read) do a[#a + 1] = n end
        a[#a + 1] = 'lspd'
        local reply = W.op(STAFF, 'setSetting', { key = KEY, value = a, basis = read })
        truthy(reply.ok, reply.message)
        local b = {}
        for _, n in ipairs(read) do b[#b + 1] = n end
        b[#b + 1] = 'doj'
        reply = W.op(STAFF, 'setSetting', { key = KEY, value = b, basis = read })
        eq(reply.ok, false, 'refused')
        eq(reply.err, 'changed_since')
        truthy(tostring(reply.message):find('another staff member changed', 1, true), reply.message)
        local now = W.s.settings.valueOf(KEY)
        local has = {}
        for _, n in ipairs(now) do has[n] = true end
        truthy(has.lspd, 'the first change kept')
        falsy(has.doj)
        -- From the read it has now, the same change goes through.
        reply = W.op(STAFF, 'setSetting', { key = KEY, value = b, basis = now })
        truthy(reply.ok, reply.message)
        -- And a write with no basis (the console, a preset) is as before.
        reply = W.op(STAFF, 'setSetting', { key = 'Limits.MinContractReward', value = 2000 })
        truthy(reply.ok, reply.message)
    end)

    it('an Undo of an older row after a newer change is refused', function()
        W.boot('memory', 'shipped')
        W.cast(W.s)
        local KEY2 = 'Limits.MinContractReward'
        W.opOk(STAFF, 'setSetting', { key = KEY2, value = 2000 })
        W.opOk(STAFF, 'setSetting', { key = KEY2, value = 3000 })
        local log = W.opOk(STAFF, 'logs', { area = 'settings' })
        local older
        for _, r in ipairs(log.rows or {}) do if r.key == KEY2 and r.new == 2000 then older = r end end
        truthy(older and older.ref, 'the older row')
        local reply = W.op(STAFF, 'undoSetting', { ref = older.ref })
        eq(reply.ok, false)
        eq(reply.err, 'changed_since')
        eq(W.s.settings.valueOf(KEY2), 3000, 'the newer change kept')
        -- The newest row's Undo still works.
        log = W.opOk(STAFF, 'logs', { area = 'settings' })
        local newest
        for _, r in ipairs(log.rows or {}) do if r.key == KEY2 and r.new == 3000 then newest = newest or r end end
        truthy(W.op(STAFF, 'undoSetting', { ref = newest.ref }).ok)
        eq(W.s.settings.valueOf(KEY2), 2000)
    end)
end)

describe('STAFF-3: a lookup by one name', function()
    it('says how many match, or that nobody by that name is here', function()
        W.boot('memory', 'shipped')
        W.cast(W.s)
        local p = Env.addPlayer({ source = 21, citizenid = 'OTHER021', license = 'license:OTHER021', cash = 0, bank = 0,
            firstname = 'Sol', lastname = 'Smith', inventory = {} })
        W.everyone.OTHER021 = p
        W.loaded(21)
        local reply = W.op(STAFF, 'player', { subject = 'Sol' })
        eq(reply.ok, false)
        truthy(tostring(reply.message):find('2 people match that name', 1, true), reply.message)
        reply = W.op(STAFF, 'player', { subject = 'Kitty' })
        eq(reply.ok, false)
        truthy(tostring(reply.message):find('Nobody by that name', 1, true), reply.message)
        reply = W.op(STAFF, 'player', { subject = 'Sol Vane' })
        truthy(reply.ok, reply.message)
        reply = W.op(STAFF, 'player', { subject = 'NOPE1234' })
        eq(reply.ok, false)
        truthy(tostring(reply.message):find('citizen id', 1, true), 'a typed id is still read as one: ' .. tostring(reply.message))
    end)
end)

describe('STAFF-4: Reassign when anonymous hitmen are off', function()
    it('the preview says so (shipped config)', function()
        W.boot('memory', 'shipped')
        W.cast(W.s)
        W.allAt()
        local ctx = { reward = 5000 }
        F.stepPlace().run(ctx)
        local ref = W.ref(C.hitman2.cid)
        local view = W.opOk(STAFF, 'reassignPreview', { id = ctx.id, ref = ref })
        eq(view.anonymousAllowed, false)
        eq(view.anonymous, false)
    end)
end)
