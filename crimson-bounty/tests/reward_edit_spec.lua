--- Changing a reward after the contract is up.
---
--- Adding to one already existed. Taking value back out did not exist at
--- all: a creator who put up too much could only cancel and place again,
--- which costs them their place in every cooldown that keys on target and
--- creator — so the practical answer was to leave the money there.
---
--- Every test here is either the feature working or somebody trying to use
--- it to take property that is not theirs.

local function call(name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return nil, 'no handler registered for ' .. name end
    Env.clientEvents = {}
    _G.source = source
    fire(payload or {})
    _G.source = nil
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

local function placed(s, reward)
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = reward or { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
    })
    return f, c
end

--- The held lines of one portion, in storage order.
local function linesOf(s, contractId, portion)
    local out = {}
    for _, line in ipairs(s.storage.readEscrow(contractId)) do
        if line.portion == portion and line.state == CB.ESCROW_STATE.HELD then
            out[#out + 1] = line
        end
    end
    return out
end

describe('reducing a reward nobody has taken', function()
    it('hands back exactly the line named, and nothing else', function()
        local s = newStack()
        local f, c = placed(s)
        eq(Env.players[1].PlayerData.money.cash, 92500, 'escrow is out of pocket')

        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        eq(#bonus, 1, 'one bonus line to take back')

        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })
        truthy(ok, tostring(err))

        eq(Env.players[1].PlayerData.money.cash, 95000,
            'the bonus came back and the baseline did not')
        eq(#linesOf(s, c.id, CB.PORTION.BONUS), 0, 'the bonus line is gone from escrow')
        eq(#linesOf(s, c.id, CB.PORTION.BASELINE), 1, 'the baseline is untouched')
    end)

    it('leaves the contract on the board, worth less', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })

        local contract = s.storage.readContract(c.id)
        eq(contract.state, CB.STATE.ACTIVE, 'reducing a reward does not close a contract')
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 0)
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BASELINE }), 5000)
    end)

    it('gives goods back as the same goods, not a fresh copy', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })

        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        eq(#bonus, 1, 'the weapon is in escrow')

        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })
        truthy(ok, tostring(err))

        local returned
        for _, entry in ipairs(Env.players[1]._inventory or {}) do
            if entry.name == 'WEAPON_PISTOL' and entry.metadata
                and entry.metadata.serial == 'ABC123' then
                returned = entry
            end
        end
        truthy(returned, 'the weapon came back as a fresh clean one, laundering '
            .. 'its serial, or did not come back at all')
        eq(returned.metadata.ammo, 12, 'and with the rounds that were in it')
    end)

    it('takes several lines in one go', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000, bank = 3000 },
            bonus = { cash = 2500 },
        })
        local cashBefore = Env.players[1].PlayerData.money.cash
        local bankBefore = Env.players[1].PlayerData.money.bank

        -- The bank baseline and the whole bonus, at once. The cash baseline
        -- stays, so the slot is still funded.
        local ids, kept = {}, 0
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS
                or (line.portion == CB.PORTION.BASELINE and line.source == 'bank') then
                ids[#ids + 1] = line.id
            elseif line.portion == CB.PORTION.BASELINE then
                kept = kept + 1
            end
        end
        eq(#ids, 2, 'two lines to take back')
        eq(kept, 1, 'and one that keeps the slot funded')

        local ok, err = s.contracts.withdrawReward(f.creator, c.id, ids)
        truthy(ok, tostring(err))
        eq(Env.players[1].PlayerData.money.cash, cashBefore + 2500)
        eq(Env.players[1].PlayerData.money.bank, bankBefore + 3000)
    end)

    it('records one audit row for the whole change, not one per line', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000, bank = 3000 },
            bonus = { cash = 2500 },
        })
        local ids = {}
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS
                or (line.portion == CB.PORTION.BASELINE and line.source == 'bank') then
                ids[#ids + 1] = line.id
            end
        end

        s.audit.flush()
        s.contracts.withdrawReward(f.creator, c.id, ids)
        s.audit.flush()

        local reduced = 0
        for _, row in ipairs(s.storage.readAudit and s.storage.readAudit() or {}) do
            if row.action == 'reward_reduced' then reduced = reduced + 1 end
        end
        -- Storage backends that do not expose the audit table skip the
        -- count rather than asserting nothing.
        if s.storage.readAudit then
            eq(reduced, 1, 'one decision should be one row')
        end
    end)
end)

describe('a withdrawal that could not be handed over', function()
    --- Escrow that cannot be delivered — pockets full, or the player gone —
    --- is owed, not lost: the line goes back to `held` marked for them and
    --- is retried on next login. On a contract that is still live, that
    --- leaves money sitting in escrow that belongs to one named person.

    local function fullPockets(s, fn)
        Env.players[1]._inventoryFull = true
        local ok, err = pcall(fn)
        Env.players[1]._inventoryFull = false
        if not ok then error(err, 0) end
    end

    it('owes it to the creator rather than destroying it', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { items = { { name = 'lockpick', count = 2 } } },
        })
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)[1]

        local ok, err, result
        fullPockets(s, function()
            ok, err, result = s.contracts.withdrawReward(f.creator, c.id, { bonus.id })
        end)

        truthy(ok, 'an undeliverable withdrawal is not a failure: ' .. tostring(err))
        eq(result.pending, 1, 'it should be queued for them')

        local after
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.id == bonus.id then after = line end
        end
        truthy(after, 'the line was destroyed rather than owed')
        eq(after.state, CB.ESCROW_STATE.HELD)
        eq(after.owed_to, f.creator.cid, 'and marked for the person it is going to')
    end)

    it('stops advertising it as part of what the contract pays', function()
        local s = newStack()
        -- Dirty money on purpose: it is money as far as the reward figure is
        -- concerned, but it lives in the inventory, so it is the one money
        -- source a full pocket can actually refuse. Cash and bank go to a
        -- wallet and always land.
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { dirty = 2500 },
        })
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)[1]
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500)

        fullPockets(s, function()
            s.contracts.withdrawReward(f.creator, c.id, { bonus.id })
        end)

        local after
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.id == bonus.id then after = line end
        end
        truthy(after and after.owed_to,
            'this measures nothing unless the delivery actually failed')

        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 0,
            'a hunter was shown a reward including money owed to somebody else')
    end)

    it('does not count owed goods in what a contract advertises', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { items = { { name = 'lockpick', count = 2 } } },
        })
        eq(s.escrow.goodsIn(c.id, { portion = CB.PORTION.BONUS }).items, 2)

        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)[1]
        fullPockets(s, function()
            s.contracts.withdrawReward(f.creator, c.id, { bonus.id })
        end)

        eq(s.escrow.goodsIn(c.id, { portion = CB.PORTION.BONUS }).items, 0,
            'goods owed to the creator were still advertised as the reward')
    end)

    it('and a hunter who collects is not paid what is owed to somebody else', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { items = { { name = 'lockpick', count = 2 } } },
        })
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)[1]
        fullPockets(s, function()
            s.contracts.withdrawReward(f.creator, c.id, { bonus.id })
        end)

        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING))

        local got = 0
        for _, entry in ipairs(Env.players[3]._inventory or {}) do
            if entry.name == 'lockpick' then got = got + (entry.count or 0) end
        end
        eq(got, 0, 'a hunter was paid goods already owed back to the creator')
    end)
end)

describe('what a reward reduction must refuse', function()
    it('refuses once somebody is actually hunting it', function()
        local s = newStack()
        local f, c = placed(s)
        truthy(s.contracts.accept(f.hunter, c.id, false), 'the hunter takes it')

        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })
        falsy(ok, 'a reward was pulled out from under a working hunter')
        eq(err, CB.ERR.BAD_STATE)
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500,
            'and nothing moved')
    end)

    it('refuses somebody who is not the creator', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)

        local ok, err = s.contracts.withdrawReward(f.hunter, c.id, { bonus[1].id })
        falsy(ok, 'a stranger emptied somebody elses escrow')
        eq(err, CB.ERR.NOT_PARTICIPANT)
        eq(Env.players[3].PlayerData.money.cash, 5000, 'and was not paid')
    end)

    it('refuses to empty the baseline of a slot', function()
        local s = newStack()
        local f, c = placed(s)
        local baseline = linesOf(s, c.id, CB.PORTION.BASELINE)

        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { baseline[1].id })
        falsy(ok, 'a contract was left advertising a collection that pays nothing')
        eq(err, CB.ERR.INVALID_REWARD)
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BASELINE }), 5000)
    end)

    it('refuses a hunters stake while they hold the contract', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
            penaltyAmount = 1000,
        })
        truthy(s.contracts.accept(f.hunter, c.id, false), 'the hunter stakes a penalty')

        local stake
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.STAKE then stake = line end
        end
        truthy(stake, 'the stake should be in escrow')
        eq(stake.amount, 1000)

        local ok = s.contracts.withdrawReward(f.creator, c.id, { stake.id })
        falsy(ok, 'a creator withdrew a hunters stake into their own pocket')

        local after
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.id == stake.id then after = line end
        end
        eq(after.state, CB.ESCROW_STATE.HELD, 'and the stake is still held')
    end)

    --- The rule above is enforced twice over: nobody may reduce a reward
    --- while a hunter holds the contract, and a stake is not a portion the
    --- creator may name even if they could. The first refuses the ordinary
    --- path before the second is ever reached, so the second is tested
    --- against a state built here rather than played into: a stake line left
    --- held on a contract with no active hunter.
    ---
    --- Whether that state is reachable in a live server is not the point. It
    --- is the guard that makes it not matter, and a guard nothing exercises
    --- is a guard the next refactor deletes.
    it('refuses a stake portion even with nobody hunting', function()
        local s = newStack()
        local f, c = placed(s)

        s.storage.writeEscrow(c.id, { {
            id = c.id .. ':900', contract_id = c.id, slot = 1,
            portion = CB.PORTION.STAKE, source = 'cash', amount = 1000,
            staker = 'HUNTER01', state = CB.ESCROW_STATE.HELD,
        } })

        local before = Env.players[1].PlayerData.money.cash
        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { c.id .. ':900' })
        falsy(ok, 'a stake was withdrawn by the creator on an unhunted contract')
        eq(err, CB.ERR.NOT_PARTICIPANT)
        eq(Env.players[1].PlayerData.money.cash, before, 'and no money moved')

        -- The same request, naming a line that IS theirs, still works: the
        -- refusal above is about the stake, not about the injected state.
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)[1]
        truthy(s.contracts.withdrawReward(f.creator, c.id, { bonus.id }),
            'the guard refused a legitimate withdrawal too')
    end)

    --- Same shape, for the other line a creator must not be able to take:
    --- one already promised to a named person. A refund owed to an offline
    --- target sits on a contract exactly like this.
    it('refuses a line already owed to somebody else', function()
        local s = newStack()
        local f, c = placed(s)

        s.storage.writeEscrow(c.id, { {
            id = c.id .. ':901', contract_id = c.id, slot = 1,
            portion = CB.PORTION.BONUS, source = 'cash', amount = 750,
            owed_to = 'HUNTER01', state = CB.ESCROW_STATE.HELD,
        } })

        local before = Env.players[1].PlayerData.money.cash
        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { c.id .. ':901' })
        falsy(ok, 'a creator took money already promised to somebody else')
        eq(err, CB.ERR.NOT_PARTICIPANT)
        eq(Env.players[1].PlayerData.money.cash, before, 'and no money moved')
    end)

    --- And a line that is not held: one caught mid-release is on its way to
    --- somebody already, and settling it twice is the one thing the whole
    --- compare-and-set design exists to prevent.
    it('refuses a line that is not held', function()
        local s = newStack()
        local f, c = placed(s)

        s.storage.writeEscrow(c.id, { {
            id = c.id .. ':902', contract_id = c.id, slot = 1,
            portion = CB.PORTION.BONUS, source = 'cash', amount = 750,
            state = CB.ESCROW_STATE.RELEASING, releasing_to = 'HUNTER01',
        } })

        local before = Env.players[1].PlayerData.money.cash
        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { c.id .. ':902' })
        falsy(ok, 'a line already on its way to somebody was withdrawn')
        eq(err, CB.ERR.BAD_STATE)
        eq(Env.players[1].PlayerData.money.cash, before, 'and no money moved')
    end)

    it('refuses a line belonging to another contract', function()
        local s = newStack()
        local f, first = placed(s)
        local second = s.contracts.create(f.creator, {
            targetCid = 'HUNTER01', reason = 'Another debt',
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 4000 }, bonus = { cash = 1000 } },
        })

        local theirs = linesOf(s, second.id, CB.PORTION.BONUS)
        local ok, err = s.contracts.withdrawReward(f.creator, first.id, { theirs[1].id })
        falsy(ok, 'a line was withdrawn through a contract that does not hold it')
        eq(err, CB.ERR.NOT_FOUND)
        eq(s.escrow.moneyValue(second.id, { portion = CB.PORTION.BONUS }), 1000,
            'and the other contract still holds it')
    end)

    it('refuses the whole request when one named line is not withdrawable', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000, bank = 3000 },
            bonus = { cash = 2500 },
        })
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        local cashBefore = Env.players[1].PlayerData.money.cash

        -- One real line and one that does not exist. Withdrawing the half it
        -- recognised would report success for a request it only part did.
        local ok, err = s.contracts.withdrawReward(f.creator, c.id,
            { bonus[1].id, 'esdeadbeef' })
        falsy(ok, 'a partly-unknown request must not partly succeed')
        eq(err, CB.ERR.NOT_FOUND)
        eq(Env.players[1].PlayerData.money.cash, cashBefore, 'and nothing moved')
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500)
    end)

    it('refuses a closed contract', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        truthy(s.contracts.cancel(f.creator, c.id))

        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })
        falsy(ok, 'escrow was withdrawn from a contract that had already paid out')
        eq(err, CB.ERR.ALREADY_SETTLED)
    end)

    it('refuses malformed input rather than using it', function()
        local s = newStack()
        local f, c = placed(s)
        for _, bad in ipairs({ {}, { '' }, { 42 }, { '../../etc/passwd' },
                               { string.rep('a', 400) } }) do
            local ok = s.contracts.withdrawReward(f.creator, c.id, bad)
            falsy(ok, 'accepted a malformed line list')
        end
        falsy(s.contracts.withdrawReward(f.creator, c.id, 'not a table'))
        falsy(s.contracts.withdrawReward(f.creator, c.id, nil))
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500,
            'and nothing moved through any of them')
    end)

    it('counts a line named twice once', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        local before = Env.players[1].PlayerData.money.cash

        local ok, err = s.contracts.withdrawReward(f.creator, c.id,
            { bonus[1].id, bonus[1].id, bonus[1].id })
        truthy(ok, tostring(err))
        eq(Env.players[1].PlayerData.money.cash, before + 2500,
            'a line named three times paid three times')
    end)
end)

describe('a hunter accepting while the reward is being reduced', function()
    --- The check for "is anybody hunting this" happens before the money
    --- moves, and every storage read in between is a yield on a real
    --- database. An acceptance landing in one of those windows would take a
    --- contract whose reward then shrank underneath them.
    ---
    --- Simulated by accepting from inside the release itself, which is
    --- exactly where the real one would land.
    local function acceptDuringRelease(s, f, c)
        local realClaim = s.storage.claimEscrowLine
        local accepted = false
        s.storage.claimEscrowLine = function(id, expected, next_)
            local out = realClaim(id, expected, next_)
            -- Once, on the way out of `held`: the instant the withdrawal has
            -- taken a line and is about to hand it over.
            if out and not accepted and expected == CB.ESCROW_STATE.HELD then
                accepted = true
                s.contracts.accept(f.hunter, c.id, false)
            end
            return out
        end
        return function() s.storage.claimEscrowLine = realClaim end
    end

    it('does not shrink the reward under the hunter who just took it', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)
        local before = Env.players[1].PlayerData.money.cash

        local restore = acceptDuringRelease(s, f, c)
        local ok, err = s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })
        restore()

        falsy(ok, 'the withdrawal went through on a contract somebody had just taken')
        eq(err, CB.ERR.BAD_STATE)
        eq(Env.players[1].PlayerData.money.cash, before, 'and no money moved')
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500,
            'the hunter still has the reward they accepted')
    end)

    it('tells the hunter when part of it got out before the guard bit', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { cash = 2500, dirty = 1000 },
        })

        local ids = {}
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.portion == CB.PORTION.BONUS then ids[#ids + 1] = line.id end
        end
        eq(#ids, 2, 'two bonus lines, so the guard can bite between them')

        -- The accept lands after the first line is already out, which is the
        -- one case the guard cannot undo.
        local realClaim = s.storage.claimEscrowLine
        local seen = 0
        s.storage.claimEscrowLine = function(id, expected, next_)
            local out = realClaim(id, expected, next_)
            if out and expected == CB.ESCROW_STATE.HELD then
                seen = seen + 1
                if seen == 2 then s.contracts.accept(f.hunter, c.id, false) end
            end
            return out
        end
        Natives.calls.notifications = {}
        local ok = s.contracts.withdrawReward(f.creator, c.id, ids)
        s.storage.claimEscrowLine = realClaim

        truthy(ok, 'the lines that got out really did get out')

        local told = false
        for _, note in ipairs(Natives.calls.notifications or {}) do
            local text = tostring(note.title or '') .. ' ' .. tostring(note.content or note.message or '')
            if text:find('Reward changed', 1, true) then told = true end
        end
        truthy(told,
            'a hunter whose contract shrank as they accepted it was told nothing')
    end)

    it('puts the line back rather than leaving it stranded mid-release', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)

        local restore = acceptDuringRelease(s, f, c)
        s.contracts.withdrawReward(f.creator, c.id, { bonus[1].id })
        restore()

        local after
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.id == bonus[1].id then after = line end
        end
        truthy(after, 'the line vanished')
        eq(after.state, CB.ESCROW_STATE.HELD,
            'a refused line must go back to held, not sit in releasing forever')

        -- And the contract still pays what it says it pays.
        truthy(s.contracts.claimSlot(c.id, f.hunter.cid, CB.FULFILMENT.KIDNAPPING),
            'the hunter should still be able to collect')
        eq(Env.players[3].PlayerData.money.cash, 5000 + 5000 + 2500,
            'the hunter was paid the whole reward they accepted')
    end)
end)

describe('the breakdown a creator edits from', function()
    it('names every line of their own reward', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } },
            bonus = { cash = 2500 },
        })
        local view = s.projection.rewardLines(c.id, f.creator.cid)
        truthy(view, 'the creator must be able to see their own reward')
        truthy(view.editable, 'nobody is hunting it, so it is editable')

        local ids, kinds = 0, {}
        for _, row in ipairs(view.lines) do
            if row.id then ids = ids + 1 end
            kinds[row.item or row.source] = true
        end
        eq(ids, #view.lines, 'every withdrawable line needs an id to name it')
        truthy(kinds.cash, 'cash should be listed')
        truthy(kinds.lockpick, 'the item should be listed by name')
    end)

    it('shows nothing to anybody else', function()
        local s = newStack()
        local f, c = placed(s)
        falsy(s.projection.rewardLines(c.id, f.hunter.cid),
            'a hunter could read the creators escrow line ids')
        falsy(s.projection.rewardLines(c.id, f.target.cid),
            'a target could read the creators escrow line ids')
        falsy(s.projection.rewardLines('esdeadbeef', f.creator.cid),
            'a contract that does not exist must answer the same way as one that is not yours')
    end)

    it('never names a stake, whoever asks', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CB.MODE.EXCLUSIVE,
            reward = { baseline = { cash = 5000 } },
            penaltyAmount = 1000,
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

        local view = s.projection.rewardLines(c.id, f.creator.cid)
        truthy(view, 'the creator still sees their own reward')
        falsy(view.editable, 'but cannot change it while somebody holds the contract')
        truthy(view.reason and #view.reason > 0, 'and is told why')

        for _, row in ipairs(view.lines) do
            falsy(row.portion == CB.PORTION.STAKE, 'a stake was listed as the creators')
            falsy(row.id, 'a line was named as withdrawable on a held contract')
        end
    end)

    it('does not leak a weapon serial to the client', function()
        local s = newStack()
        local f, c = placed(s, {
            baseline = { cash = 5000 },
            bonus = { weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } },
        })
        local view = s.projection.rewardLines(c.id, f.creator.cid)

        -- Walked rather than spot-checked: a serial must not reach the
        -- client under any key, including one added later.
        local function scan(value, path)
            if type(value) == 'string' then
                falsy(value:find('ABC123', 1, true),
                    'the weapon serial reached the payload at ' .. path)
            elseif type(value) == 'table' then
                for k, v in pairs(value) do scan(v, path .. '.' .. tostring(k)) end
            end
        end
        scan(view, 'breakdown')

        for _, row in ipairs(view.lines) do
            falsy(row.metadata, 'metadata crossed to the client')
            falsy(row.serial, 'a serial crossed to the client')
        end
    end)
end)

describe('the reward-edit handlers', function()
    it('answer the creator and refuse everyone else', function()
        local s = newStack()
        local f, c = placed(s)

        local mine = call('rewardBreakdown', 1, { id = c.id })
        truthy(mine and mine.ok, 'the creator should get their own breakdown')
        truthy(#mine.data.lines > 0)

        local theirs = call('rewardBreakdown', 3, { id = c.id })
        truthy(theirs, 'the handler must answer')
        falsy(theirs.ok, 'a hunter read the creators escrow ids through the handler')
        eq(theirs.err, CB.ERR.NOT_FOUND)
    end)

    it('withdraw through the handler and report what moved', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)

        local answer = call('withdrawReward', 1, { id = c.id, lines = { bonus[1].id } })
        truthy(answer and answer.ok, 'the withdrawal should be accepted: '
            .. tostring(answer and answer.err))
        eq(answer.data.returned, 1, 'one line came back')
        eq(answer.data.queued, 0, 'and none had to be queued')
        eq(Env.players[1].PlayerData.money.cash, 95000)
    end)

    it('refuse a payload that is not a list of ids', function()
        local s = newStack()
        local f, c = placed(s)
        for _, bad in ipairs({ 'lines', 42, { 1, 2, 3 }, { { id = 'x' } } }) do
            local answer = call('withdrawReward', 1, { id = c.id, lines = bad })
            truthy(answer, 'the handler must answer')
            falsy(answer.ok, 'accepted a malformed payload: ' .. type(bad))
        end
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500)
    end)

    it('refuse a list far longer than any contract can hold', function()
        local s = newStack()
        local f, c = placed(s)

        -- Refused twice over: the handler stops flattening once the list
        -- passes the ceiling, and withdrawReward re-checks the length it
        -- was handed. Only the second is observable from here — the first
        -- is about what the refusal costs, not whether it happens — so this
        -- asserts the refusal and leaves the cost to the comment on it.
        local huge = {}
        for i = 1, 5000 do huge[i] = 'ct00000001:' .. i end

        local answer = call('withdrawReward', 1, { id = c.id, lines = huge })
        truthy(answer, 'the handler must answer')
        falsy(answer.ok, 'a five thousand line request was accepted')
        eq(answer.err, CB.ERR.INVALID_INPUT)
        eq(s.escrow.moneyValue(c.id, { portion = CB.PORTION.BONUS }), 2500,
            'and nothing moved')
    end)

    it('accept a map, which is what an array crosses as when it has holes', function()
        local s = newStack()
        local f, c = placed(s)
        local bonus = linesOf(s, c.id, CB.PORTION.BONUS)

        -- msgpack turns a sparse client array into a map, and #map is 0.
        local answer = call('withdrawReward', 1,
            { id = c.id, lines = { ['1'] = bonus[1].id } })
        truthy(answer and answer.ok,
            'a map-shaped list was refused: ' .. tostring(answer and answer.err))
        eq(Env.players[1].PlayerData.money.cash, 95000)
    end)
end)
