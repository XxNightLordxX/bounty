--- Staff commands.
---
--- The audit log recorded everything and nothing surfaced it in game, so a
--- staff member handling "the script ate my gun" needed database access.
--- These cover the four things staff can now do — and, as importantly, what
--- someone without the ACE cannot.

local function money(src)
    local m = Env.players[src].PlayerData.money
    return m.cash + m.bank
end

local function seeded(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
        anonymous = opts.anonymous,
    })
    if opts.accept then s.contracts.accept(f.hitman, c.id, opts.anonHitman) end
    return s, f, c
end

--- Run a registered command as a player would. The commands are registered
--- by bridges.install, which the harness's stack does not run, so they are
--- installed here against the same modules.
local function commands(s)
    Env.commands = {}
    require('crimson-hitman.server.bridges').installCommands(s)
    return Env.commands
end

local function said(target)
    local out = {}
    for _, line in ipairs(Env.chat) do
        if line.target == target then out[#out + 1] = line.text end
    end
    return table.concat(out, '\n')
end

describe('staff permission', function()
    it('refuses every command to a player without the ace', function()
        local s, f, c = seeded()
        local cmd = commands(s)
        Env.chat = {}

        for name, handler in pairs(cmd) do
            handler(3, { c.id, 'pay' })
            local _ = name
        end

        truthy(said(3):find('Not authorised'), 'every command refuses: ' .. said(3))
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'and nothing happened')
    end)

    it('separates reading a history from unmasking a person', function()
        local s, f, c = seeded({ accept = true, anonHitman = true })
        local cmd = commands(s)

        -- A staff member with the ordinary ace, and not the identity one.
        Env.aces[3] = { ['crimson.admin'] = true }
        Env.chat = {}

        cmd[Config.Admin.Commands.timeline](3, { c.id })
        falsy(said(3):find('Not authorised'), 'the timeline is theirs to read')

        Env.chat = {}
        cmd[Config.Admin.Commands.whois](3, { c.id })
        truthy(said(3):find('Not authorised'),
            'unmasking is a different permission: ' .. said(3))
    end)

    it('always allows the server console', function()
        local s = newStack()
        truthy(s.admin.allowed(0, 'crimson.admin'),
            'an owner locked out of their own recovery tools has no way back in')
        falsy(s.admin.allowed(3, 'crimson.admin'))
    end)
end)

describe('contract timeline', function()
    it('reads a contract with its escrow and its history', function()
        local s, f, c = seeded({ accept = true })
        local view, err = s.admin.timeline(c.id)
        truthy(view, tostring(err))

        eq(view.contract.id, c.id)
        eq(view.contract.target, 'Dana Reyes')
        truthy(#view.escrow > 0, 'the escrow lines')
        eq(#view.hitmen, 1, 'the hitman who accepted')
        truthy(#view.events > 0, 'and what happened')
    end)

    it('does not name an anonymous creator', function()
        local s, f, c = seeded({ anonymous = true })
        local view = s.admin.timeline(c.id)
        eq(view.contract.creator, '(anonymous)',
            'the timeline is a history; unmasking is its own command')
        falsy(tostring(view.contract.creator):find('Vic'))
    end)

    it('refuses an id that is not one', function()
        local s = newStack()
        for _, bogus in ipairs({ '', 'ct nope', '../etc/passwd', 'ct99999999' }) do
            falsy(s.admin.timeline(bogus), 'must not resolve ' .. bogus)
        end
        falsy(s.admin.timeline(nil))
        falsy(s.admin.timeline({}))
    end)
end)

describe('voiding a contract', function()
    it('closes it and returns everything to the creator', function()
        local s, f, c = seeded({ accept = true })
        local before = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank

        truthy(s.admin.void(0, c.id, 'refunded a stuck handover'))
        eq(s.storage.readContract(c.id).state, CH.STATE.VOIDED,
            'the state the machine declares for an admin close, not the one '
            .. 'that means the creator changed their mind')

        local after = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        eq(after - before, 5000, 'the escrow comes back')
    end)

    it('returns a hitman their stake rather than forfeiting it', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))
        eq(Env.players[3].PlayerData.money.bank, 40000, 'staked')

        truthy(s.admin.void(0, c.id, 'staff'))
        eq(Env.players[3].PlayerData.money.bank, 50000,
            'a staff void is not the hitman failing')
    end)

    it('leaves nothing held', function()
        local s, f, c = seeded({ accept = true })
        truthy(s.admin.void(0, c.id, 'staff'))
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CH.ESCROW_STATE.SETTLED, 'every line settles')
        end
    end)

    it('refuses a contract that has already ended', function()
        local s, f, c = seeded({ accept = true })
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
        local ok, err = s.admin.void(0, c.id, 'too late')
        falsy(ok)
        eq(err, CH.ERR.ALREADY_SETTLED)
    end)

    it('writes who did it and why', function()
        local s, f, c = seeded()
        truthy(s.admin.void(0, c.id, 'duplicate contract'))
        s.audit.flush()

        local found = false
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'admin_void' then
                found = true
                truthy(tostring(row.detail.reason):find('duplicate'), 'the reason is recorded')
            end
        end
        truthy(found, 'a staff action nobody can review is not accountable')
    end)
end)

describe('interrupted releases', function()
    --- Reproduce what a shutdown mid-release leaves behind: a line claimed
    --- but never settled, which recovery returns to `held` and logs.
    local function stranded()
        local s, f, c = seeded()
        local line = s.storage.readEscrow(c.id)[1]

        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        -- Recovery's half: back to held, logged for review.
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD))
        s.audit.financial('release_interrupted', 'HITMAN01', c.id,
            { line = line.id, amount = line.amount, review = true })
        s.audit.flush()

        return s, f, c, line
    end

    it('lists a line that was mid-release at a shutdown', function()
        local s, f, c, line = stranded()
        local rows = s.admin.interrupted()
        eq(#rows, 1)
        eq(rows[1].line, line.id)
        eq(rows[1].contract, c.id)
        eq(rows[1].intended, 'HITMAN01', 'who it was being paid to')
    end)

    it('stops listing one that has since been settled', function()
        local s, f, c, line = stranded()
        truthy(s.admin.settleLine(0, line.id, 'return'))
        eq(#s.admin.interrupted(), 0, 'a resolved question is not a question')
    end)

    it('returns an interrupted stake to the hitman who put it up', function()
        -- "Return" sent every line to the creator, including a hitman's own
        -- stake, which was never the creator's.
        local s, f, c = seeded()
        s.storage.writeContract((function()
            local row = s.storage.readContract(c.id); row.penalty_amount = 2000; return row
        end)())
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local stake
        for _, l in ipairs(s.storage.readEscrow(c.id)) do
            if l.portion == CH.PORTION.STAKE then stake = l end
        end
        truthy(stake, 'the hitman staked')
        truthy(s.storage.claimEscrowLine(stake.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        truthy(s.storage.claimEscrowLine(stake.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD))
        s.audit.financial('release_interrupted', 'HITMAN01', c.id, { line = stake.id, review = true })
        s.audit.flush()
        local creatorBefore, hitmanBefore = money(1), money(3)
        truthy(s.admin.settleLine(0, stake.id, 'return'))
        eq(money(3) - hitmanBefore, 2000, 'back to the hitman who staked it')
        eq(money(1), creatorBefore, 'and not to the creator')
    end)

    it('says a payment to somebody offline is queued, not failed', function()
        local s, f, c, line = stranded()
        Env.removePlayer(3)
        local ok, note = s.admin.settleLine(0, line.id, 'pay')
        truthy(ok, 'queued is settled as far as staff are concerned')
        eq(note, 'queued')
    end)

    it('pays whom the interrupted release was paying, after a return was queued', function()
        -- A 'return' queued for an offline creator rewrote who the line was
        -- owed to, and a 'pay' after it then went to the creator as well.
        local s, f, c, line = stranded()
        Env.removePlayer(1)
        local ok = s.admin.settleLine(0, line.id, 'return')
        truthy(ok)
        local again, err = s.admin.settleLine(0, line.id, 'pay')
        falsy(again, 'queued for the creator already, so not paid again elsewhere')
        eq(err, CH.ERR.LOCKED)
    end)

    it('hides who it was paying from staff without the identity permission', function()
        local s, f, c, line = stranded()
        Env.aces[7] = { command = true }
        Env.addPlayer({ source = 7, citizenid = 'STAFF001', license = 'license:st' })
        local rows = s.admin.interrupted(7)
        eq(#rows, 1)
        eq(rows[1].intended, 'an operative', 'a citizen id behind an anonymous party')
        Env.aces[7] = { command = true, ['crimson.identity'] = true }
        eq(s.admin.interrupted(7)[1].intended, 'HITMAN01', 'shown to staff who may see it')
    end)

    it('pays the intended recipient when staff say to', function()
        local s, f, c, line = stranded()
        local before = Env.players[3].PlayerData.money.cash

        -- The line records who the interrupted release was paying.
        line.releasing_to = 'HITMAN01'
        s.storage.writeEscrow(c.id, { line })

        truthy(s.admin.settleLine(0, line.id, 'pay'))
        eq(Env.players[3].PlayerData.money.cash - before, 5000)
    end)

    --- The real path: a release that actually starts and is interrupted.
    --- The stranded() helper above fakes the states; this drives Escrow
    --- itself, which is where the recipient has to be recorded.
    it('remembers who a genuinely interrupted release was paying', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hitman, c.id, false))

        -- The hitman cannot be paid, so the release stalls exactly where a
        -- shutdown would leave it.
        Env.players[3]._inventoryFull = true
        Env.players[3].PlayerData.money._refuse = true

        local lineId = s.storage.readEscrow(c.id)[1].id
        truthy(s.storage.claimEscrowLine(lineId, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        -- Recovery's half.
        truthy(s.storage.claimEscrowLine(lineId, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD))
        Env.players[3]._inventoryFull = false

        -- Now do it for real and check what the line remembers.
        s.escrow.release(c.id, 'HITMAN01', { portion = CH.PORTION.BASELINE }, 'payout')
        eq(s.storage.readEscrowLine(lineId).releasing_to, 'HITMAN01',
            'a line must name who it was going to, before the money moves')
    end)

    it('carries the intended recipient through storage in every backend', function()
        local Exec = require('crimson-hitman.tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-hitman.server.storage.mysql'] = nil
                store = require('crimson-hitman.server.storage.mysql')
            else
                package.loaded['crimson-hitman.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-hitman.server.storage.' .. name)
            end
            store.open()

            store.writeEscrow('ct1', { {
                id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = 'cash', amount = 5000, state = CH.ESCROW_STATE.HELD,
                releasing_to = 'HITMAN01',
            } })
            eq(store.readEscrowLine('ct1:1').releasing_to, 'HITMAN01',
                name .. ': without this, staff cannot pay the person it was for')
        end
    end)

    it('returns it to the creator when staff say to', function()
        local s, f, c, line = stranded()
        local before = Env.players[1].PlayerData.money.cash

        truthy(s.admin.settleLine(0, line.id, 'return'))
        eq(Env.players[1].PlayerData.money.cash - before, 5000)
    end)

    it('settles only the line it was given', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { slots = {
                { baseline = { cash = 5000 } },
                { baseline = { cash = 3000 } },
            } },
        })
        local lines = s.storage.readEscrow(c.id)
        eq(#lines, 2)

        truthy(s.admin.settleLine(0, lines[1].id, 'return'))
        eq(s.storage.readEscrowLine(lines[1].id).state, CH.ESCROW_STATE.SETTLED)
        eq(s.storage.readEscrowLine(lines[2].id).state, CH.ESCROW_STATE.HELD,
            'a named line must not release the whole contract')
    end)

    it('refuses a disposition it does not understand', function()
        local s, f, c, line = stranded()
        for _, bad in ipairs({ 'refund', 'PAY', '', 'delete' }) do
            local ok, err = s.admin.settleLine(0, line.id, bad)
            falsy(ok, 'must refuse ' .. bad)
            eq(err, CH.ERR.INVALID_INPUT)
        end
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.HELD, 'untouched')
    end)

    it('refuses to settle a line twice', function()
        local s, f, c, line = stranded()
        truthy(s.admin.settleLine(0, line.id, 'return'))
        local ok, err = s.admin.settleLine(0, line.id, 'return')
        falsy(ok)
        eq(err, CH.ERR.ALREADY_SETTLED)
    end)
end)

describe('identifying an anonymous party', function()
    it('names everyone behind a contract', function()
        local s, f, c = seeded({ accept = true, anonymous = true, anonHitman = true })
        local who, err = s.admin.identify(0, c.id)
        truthy(who, tostring(err))

        eq(who.creator.cid, 'CREATOR1')
        eq(who.creator.anonymous, true)
        eq(who.target.cid, 'TARGET01')
        eq(#who.hitmen, 1)
        eq(who.hitmen[1].cid, 'HITMAN01')
        eq(who.hitmen[1].anonymous, true)
        truthy(who.hitmen[1].alias, 'and the alias they were shown under')
    end)

    it('records the lookup itself', function()
        local s, f, c = seeded({ anonymous = true })
        truthy(s.admin.identify(0, c.id))
        s.audit.flush()

        local found = false
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'admin_identify' then found = true end
        end
        truthy(found, 'the point of anonymity is that looking is exceptional')
    end)
end)

describe('what a staff command calls a line of escrow', function()
    --- Decided by the line's source, not by whether it happens to carry an
    --- amount. The MySQL schema declares `amount INT DEFAULT 0`, so an item
    --- or weapon line reads back with an amount of 0 rather than nothing —
    --- and 0 is truthy in Lua, so every piece of escrowed property was
    --- reported to staff as "$0". In the recovery tool that is the one place
    --- it must not happen: somebody settling an interrupted release needs to
    --- know what the property was in order to hand it back.
    local function said(s)
        local out = {}
        local bridges = require('crimson-hitman.server.bridges')
        bridges.installCommands(s)
        return out
    end

    it('does not call a piece of property "$0"', function()
        local describe = require('crimson-hitman.server.bridges').describeLine

        -- Exactly what MySQL hands back for a line that is not money: the
        -- column default, not nil. And 0 is truthy in Lua.
        eq(describe({ source = 'item', item = 'lockpick', quantity = 2, amount = 0 }),
            'lockpick x2',
            'every escrowed item was reported to staff as $0, in the one tool '
            .. 'that exists for handing property back')
        eq(describe({ source = 'weapon', item = 'WEAPON_PISTOL', quantity = 1, amount = 0 }),
            'WEAPON_PISTOL')
    end)

    it('still says what money is, and which kind', function()
        local describe = require('crimson-hitman.server.bridges').describeLine
        eq(describe({ source = 'cash', amount = 5000 }), '$5000')
        eq(describe({ source = 'bank', amount = 3000 }), '$3000 bank')
        eq(describe({ source = 'dirty', amount = 1000 }), '$1000 dirty',
            'a staff member settling this by hand needs to know which currency')
    end)

    it('names an item that the database read back with an amount of zero', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000,
                items = { { name = 'lockpick', count = 2 } } } },
        })
        truthy(c)

        -- Exactly what MySQL hands back: a column default rather than nil.
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'item' then line.amount = 0 end
        end

        local view = s.admin.timeline(c.id)
        truthy(view, 'the timeline should be readable')

        local item
        for _, line in ipairs(view.escrow) do
            if line.source == 'item' then item = line end
        end
        truthy(item, 'the item line should be in the timeline')
        eq(item.item, 'lockpick',
            'the timeline has to carry what the property actually is, or no '
            .. 'wording of it can be right')
        eq(item.quantity, 2)
    end)
end)

describe('refreshing every timer for testing', function()
    local function cmd(s)
        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        return Env.commands[Config.Admin.Commands.refresh]
    end

    it('is not opened by the extra aces that open every read-only tool', function()
        local s, f, c = seeded()
        local handler = cmd(s)
        truthy(handler, 'the command should be registered')

        -- `command` is the ace most admin groups already carry. It opens the
        -- diagnosis on purpose. It must not open a command that writes.
        Env.aces[3] = { ['command'] = true }
        Env.chat = {}
        handler(3, {})

        truthy(said(3):find('Not authorised'),
            'an ace every admin already has must not move the whole server\'s '
            .. 'clocks: ' .. said(3))
        eq(s.storage.readContract(c.id).deadline_at, c.deadline_at,
            'and nothing was refreshed')
    end)

    it('refills a rate-limit bucket and ages a spent slot cooldown', function()
        local s, f, c = seeded({ accept = true })
        local now = os.time()

        local hitman = s.storage.readHitman(c.id, f.hitman.cid)
        s.storage.updateHitman(hitman.id, { last_claim_at = now })
        for _ = 1, 200 do s.ratelimit.check(f.creator, 'create') end
        eq(s.ratelimit.check(f.creator, 'create'), false, 'the bucket is spent')

        Env.aces[3] = { ['crimson.admin'] = true }
        Env.chat = {}
        cmd(s)(3, {})

        eq(s.ratelimit.check(f.creator, 'create'), true, 'the bucket was refilled')
        local after = s.storage.readHitman(c.id, f.hitman.cid)
        truthy(now - after.last_claim_at > Config.Limits.SlotCooldownSeconds,
            'the slot cooldown was aged past its window')
        truthy(said(3):find('Timers refreshed'), said(3))
    end)

    it('ages a resolved contract past the re-list cooldown', function()
        local s, f, c = seeded()
        s.contracts.resolve(c.id, CH.STATE.EXPIRED, f.creator.cid, nil, 'expired')

        local relist = { targetCid = 'TARGET01', reason = 'Again',
                         reward = { baseline = { cash = 1000 } } }
        eq(select(2, s.contracts.create(f.creator, relist)),
            CH.ERR.TARGET_RECENTLY_ON, 'the re-list cooldown is running')

        Env.aces[3] = { ['crimson.admin'] = true }
        cmd(s)(3, {})

        truthy(s.contracts.create(f.creator, relist),
            'a test server cannot be tested if every target is locked out for '
            .. 'half an hour after each run')
    end)

    it('extends a live deadline and never brings one forward', function()
        local s, f, c = seeded()
        -- A contract with minutes left on a deadline the operator set to days.
        local contract = s.storage.readContract(c.id)
        contract.deadline_at = os.time() + 60
        contract.expires_at = os.time() + 120
        s.storage.writeContract(contract)

        Env.aces[3] = { ['crimson.admin'] = true }
        cmd(s)(3, {})

        local after = s.storage.readContract(c.id)
        truthy(after.deadline_at > os.time() + 60,
            'the point of the refresh is not having to wait out the deadline')
        truthy(after.deadline_at <= after.expires_at,
            'the deadline is still clamped to the lifetime')
        eq(after.state, CH.STATE.ACTIVE,
            'refreshing must never resolve a contract, which would move money')
    end)

    it('leaves a deadline the client extended where it is', function()
        -- Set to now plus the default, a forty-hour deadline came back to
        -- three hours, and the expiry after it forfeited the hitman's stake.
        local s, f, c = seeded()
        local contract = s.storage.readContract(c.id)
        contract.deadline_at = os.time() + 40 * 3600
        contract.expires_at = os.time() + 48 * 3600
        s.storage.writeContract(contract)

        Env.aces[3] = { ['crimson.admin'] = true }
        cmd(s)(3, {})

        local after = s.storage.readContract(c.id)
        truthy(after.deadline_at >= os.time() + 40 * 3600,
            'the refresh brought the deadline forward by '
            .. (os.time() + 40 * 3600 - after.deadline_at) .. 's')
        truthy(after.expires_at >= os.time() + 48 * 3600, 'nor the lifetime')
    end)

    it('counts a pause already banked when it clears it', function()
        local s, f, c = seeded()
        local contract = s.storage.readContract(c.id)
        contract.deadline_at = os.time() + 4 * 3600
        contract.paused_since = os.time() - 2 * 3600
        s.storage.writeContract(contract)

        Env.aces[3] = { ['crimson.admin'] = true }
        cmd(s)(3, {})

        local after = s.storage.readContract(c.id)
        falsy(after.paused_since)
        truthy(after.deadline_at >= os.time() + 6 * 3600,
            'two hours of pause were owed to the deadline and the refresh dropped them')
    end)

    it('leaves the counts that are limits rather than waits alone', function()
        local s, f, c = seeded({ accept = true })
        Config.Informant.MaxPurchasesPerContract = 1
        Env.players[3].PlayerData.money.bank = 50000

        local ok = s.informant.buy(f.creator, c.id)
        truthy(ok, 'the first purchase works')
        eq(select(2, s.informant.buy(f.creator, c.id)), nil,
            'a second inside the lock returns the same name rather than rolling')

        Env.aces[3] = { ['crimson.admin'] = true }
        cmd(s)(3, {})

        -- The lock is gone, so this is a fresh roll — and the purchase count
        -- is not, so it is refused.
        eq(select(2, s.informant.buy(f.creator, c.id)), CH.ERR.LIMIT_REACHED,
            'the refresh must not hand a buyer the whole roster')
    end)

    it('writes nothing back from the list it read at the start', function()
        -- Every store call is a yield on mysql. The pass wrote back the row
        -- it listed, putting back whatever a bonus raise or a re-price had
        -- changed while it waited.
        local s, f, c = seeded()
        local real = s.storage.allContracts
        s.storage.allContracts = function()
            local copies = {}
            for i, row in ipairs(real()) do
                local copy = {}
                for k, v in pairs(row) do copy[k] = v end
                copies[i] = copy
            end
            s.storage.setContractFields(c.id, { bonus_percent = 40, bailout_amount = 777 })
            return copies
        end
        Env.aces[3] = { ['crimson.admin'] = true }
        local ok, err = pcall(cmd(s), 3, {})
        s.storage.allContracts = real
        truthy(ok, tostring(err))

        local after = s.storage.readContract(c.id)
        eq(after.bonus_percent, 40, 'the raise was undone')
        eq(after.bailout_amount, 777, 'the re-price was undone')
        truthy(after.deadline_at > os.time(), 'and the refresh itself still happened')
    end)

    it('does not reopen a proposal answered while it worked', function()
        local s, f, c = seeded({ accept = true })
        local ok, err0 = s.amendments.propose(f.creator, c.id, CH.AMENDMENT.CHANGE_REASON,
            { reason = 'A better reason' })
        truthy(ok, 'a proposal to refresh: ' .. tostring(err0))
        local open = s.storage.readOpenAmendments(c.id)
        eq(#open, 1)

        local real = s.storage.readOpenAmendments
        s.storage.readOpenAmendments = function(id)
            local rows = {}
            for i, row in ipairs(real(id)) do
                local copy = {}
                for k, v in pairs(row) do copy[k] = v end
                rows[i] = copy
            end
            -- Declined in the moment the pass waited.
            local live = s.storage.readAmendment(open[1].id)
            live.outcome = 'declined'
            s.storage.writeAmendment(live)
            return rows
        end
        Env.aces[3] = { ['crimson.admin'] = true }
        local ran, err = pcall(cmd(s), 3, {})
        s.storage.readOpenAmendments = real
        truthy(ran, tostring(err))
        eq(s.storage.readAmendment(open[1].id).outcome, 'declined',
            'the refresh put an answered proposal back open')
    end)

    it('writes down that somebody did it', function()
        local s, f, c = seeded()
        Env.aces[3] = { ['crimson.admin'] = true }
        cmd(s)(3, {})

        local found = false
        for _, row in ipairs(s.storage.readAudit()) do
            if row.action == 'admin_timers_refreshed' then found = true end
        end
        truthy(found, 'a server whose cooldowns were quietly reset is a server '
            .. 'whose history stops explaining itself')
    end)
end)

--- Second, independent check: drive the command the way an operator does.
describe('hitmanadmin from the console', function()
    local function run(s, args)
        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        -- The console route replies through print, so it is captured here.
        local out, real = {}, print
        _G.print = function(...) out[#out + 1] = tostring((...)) end
        local ok, err = pcall(Env.commands[Config.Admin.Commands.refresh], 0, args or {})
        _G.print = real
        if not ok then error(err) end
        return table.concat(out, '\n')
    end

    it('the console is never refused and reports what it did', function()
        local s = newStack()
        local f = fixture(s)
        local out = run(s)
        truthy(not out:find('Not authorised'), out)
        truthy(out:find('Timers refreshed'), out)
        truthy(out:find('Purchase and slot COUNTS are untouched'), out)
        local _ = f
    end)

    it('refuses a subcommand it does not know rather than guessing', function()
        local s = newStack(); fixture(s)
        local out = run(s, { 'wipe' })
        truthy(out:find('Usage'), out)
        truthy(not out:find('Timers refreshed'), 'a typo must not fire it: ' .. out)
    end)

    it('clears a pause so the deadline granted is the deadline kept', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } })
        local contract = s.storage.readContract(c.id)
        contract.paused_since = os.time() - 100000
        s.storage.writeContract(contract)

        run(s)
        eq(s.storage.readContract(c.id).paused_since, nil,
            'a pause that began before the refresh would be paid out as an '
            .. 'extension on top of the deadline just granted')
    end)

    it('moves no money and resolves nothing', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } })
        s.contracts.accept(f.hitman, c.id)

        local before = {}
        for i = 1, 3 do
            before[i] = Env.players[i].PlayerData.money.cash
                      + Env.players[i].PlayerData.money.bank
        end
        local lines = #s.storage.readEscrow(c.id)

        run(s); run(s); run(s)

        for i = 1, 3 do
            eq(Env.players[i].PlayerData.money.cash
               + Env.players[i].PlayerData.money.bank, before[i],
               'player ' .. i .. ' balance moved')
        end
        eq(#s.storage.readEscrow(c.id), lines, 'escrow line count changed')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)

    it('is idempotent — running it ten times is running it once', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 100000
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } })
        run(s)
        local first = s.storage.readContract(c.id)
        local d, e = first.deadline_at, first.expires_at
        for _ = 1, 9 do run(s) end
        local after = s.storage.readContract(c.id)
        eq(after.deadline_at, d, 'deadline drifted')
        eq(after.expires_at, e, 'lifetime drifted')
    end)
end)

describe('the wait before a new character can be a target', function()
    it('is brought forward, because it is the wait before anything can be tested', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 100000

        -- A character who has just walked in, watched arriving.
        s.identity.endSession(f.target.cid)
        s.identity.beginSession(f.target.cid, false)
        Config.Immunity.MinTargetSessionMinutes = 10

        eq(select(2, s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } })),
            CH.ERR.TARGET_JUST_ON, 'the new-player rule is running')

        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        Env.commands[Config.Admin.Commands.refresh](0, {})

        -- The clock, not the flag. Marking the session unobserved would also
        -- let the contract through, by making the session length unknown —
        -- which is a lie about a session we did watch begin.
        local minutes = s.identity.sessionMinutes(f.target.cid)
        truthy(minutes ~= nil,
            'the session is still one this resource watched begin')
        truthy(minutes >= Config.Immunity.MinTargetSessionMinutes,
            'the session clock itself has to be the thing that moved, got '
            .. tostring(minutes))

        truthy(s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } }),
            'ten minutes per character is the whole afternoon on a test server')
    end)
end)

describe('what a staff command prints', function()
    --- The bodies below were never run.
    ---
    --- Every test in this file so far calls Admin.void, Admin.interrupted and
    --- Admin.identify directly and asserts on what they RETURN. Nothing ran
    --- the code that turns those returns into lines a staff member reads, so
    --- the format strings were unexecuted — which is where the last defect in
    --- this file lived: a piece of escrowed property reported as "$0", in the
    --- one tool that exists for handing property back.
    ---
    --- A staff command is used at the worst moment, by somebody already
    --- dealing with a problem. It throwing is not a cosmetic fault.
    local function commands(s)
        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        Env.chat = {}
        return Env.commands
    end

    local function said(target)
        local out = {}
        for _, line in ipairs(Env.chat) do
            if line.target == target then out[#out + 1] = line.text end
        end
        return table.concat(out, '\n')
    end

    it('prints a void, and a refused void, without throwing', function()
        local s, f, c = seeded()
        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }

        truthy(pcall(cmd[Config.Admin.Commands.void], 3, { c.id, 'duplicate', 'listing' }))
        truthy(said(3):find('voided'), said(3))
        eq(s.storage.readContract(c.id).state, CH.STATE.VOIDED)

        Env.chat = {}
        truthy(pcall(cmd[Config.Admin.Commands.void], 3, { 'ct-nope' }),
            'a void of a contract that is not there must not throw')
        truthy(said(3):find('Could not void it'), said(3))
    end)

    it('prints interrupted releases, including property and a missing timestamp', function()
        local s, f, c = seeded({ accept = true })

        -- Exactly what a shutdown mid-release leaves behind: lines claimed
        -- for release, and the audit row that records the interruption.
        -- The item line's amount is the MySQL column default, not nil.
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD,
                CH.ESCROW_STATE.RELEASING)
            local stored = s.storage.readEscrowLine(line.id)
            if stored and stored.source == 'item' then stored.amount = 0 end
            s.audit.financial('release_interrupted', f.hitman.cid, c.id,
                { line = line.id })
        end
        s.audit.flush()

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))

        local out = said(3)
        truthy(out:find('mid%-release'), out)
        truthy(not out:find('lockpick%s+%$0'),
            'the one tool for handing property back must not call it $0: ' .. out)
        truthy(out:find('Settle each with'), out)
    end)

    it('prints a line whose give kept raising, and tells staff to check before paying', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } } } })
        truthy(c, 'placed')
        local item
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'item' then item = line end
        end
        truthy(item, 'the seeded contract escrows an item')
        local real = exports.ox_inventory.AddItem
        exports.ox_inventory.AddItem = function() error('hook raised', 0) end
        local ok, err = pcall(function()
            for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
                s.escrow.release(c.id, f.hitman.cid, { line = item.id }, 'test')
            end
        end)
        exports.ox_inventory.AddItem = real
        truthy(ok, tostring(err))
        truthy(s.escrow.parked(s.storage.readEscrowLine(item.id)), 'left for staff')

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))
        local out = said(3)
        truthy(out:find(item.id, 1, true) and out:find('raised ' .. s.escrow.DELIVER_RAISE_LIMIT
            .. ' times', 1, true), out)
        truthy(out:find('check their inventory', 1, true), out)
        falsy(out:find('mid%-release'), 'not one a shutdown interrupted: ' .. out)
    end)

    --- /ch-stuck found parked lines through the log's escrow_deliver_parked
    --- rows, which go after Config.Audit.RetentionDays, and nothing else
    --- picks a parked line up again: held for ever, and seen by nobody.
    it('still lists a parked line once the log has let its rows go', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, items = { { name = 'lockpick', count = 2 } } } } })
        truthy(c, 'placed')
        local real = exports.ox_inventory.AddItem
        exports.ox_inventory.AddItem = function() error('hook raised', 0) end
        local ok, err = pcall(function()
            truthy(s.admin.void(0, c.id, 'test'), 'voided')
            for _ = 1, s.escrow.DELIVER_RAISE_LIMIT + 2 do s.escrow.retryPending('CREATOR1') end
        end)
        exports.ox_inventory.AddItem = real
        truthy(ok, tostring(err))
        local item
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'item' then item = line end
        end
        truthy(s.escrow.parked(item), 'left for staff')
        eq(item.owed_to, 'CREATOR1', 'owed back to the client')

        -- Past the log's retention, and the contract's.
        s.audit.flush()
        Env.time = Env.time + (math.max(Config.Audit.RetentionDays,
            Config.Audit.ContractRetentionDays) + 1) * 86400
        s.storage.prune()
        for _, row in ipairs(s.storage.readAudit(1000)) do
            falsy(row.action == 'escrow_deliver_parked', 'the log still has the row')
        end
        truthy(s.storage.readContract(c.id), 'the contract is kept while it holds the line')
        eq(s.storage.readEscrowLine(item.id).state, CH.ESCROW_STATE.HELD)
        eq(s.escrow.recoverOwed(s.storage.readEscrow(c.id)), 0, 'recovery leaves it for staff')

        local listed
        for _, row in ipairs(s.admin.interrupted(0)) do
            if row.line == item.id then listed = row end
        end
        truthy(listed, '/ch-stuck still shows it')
        eq(listed.intended, 'CREATOR1')
        eq(listed.raised, s.escrow.DELIVER_RAISE_LIMIT)

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        Env.chat = {}
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))
        truthy(said(3):find(item.id, 1, true), said(3))

        local function picks()
            local n = 0
            for _, slot in ipairs(Env.players[1]._inventory) do
                if slot.name == 'lockpick' then n = n + slot.count end
            end
            return n
        end
        local held = picks()
        truthy(s.admin.settleLine(0, item.id, 'pay'), 'staff can still pay it')
        eq(picks(), held + 2, 'given back once')
        eq(s.storage.readEscrowLine(item.id).state, CH.ESCROW_STATE.SETTLED)
    end)

    it('prints an empty interrupted list rather than a header with nothing under it', function()
        local s = newStack(); fixture(s)
        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))
        truthy(said(3):find('No interrupted releases'), said(3))
    end)

    it('prints a line that says nobody\'s name, and settles it to the citizen id given', function()
        local s = newStack(); fixture(s)
        s.storage.writeEscrow('ct00000099', { { id = 'ct00000099:1', contract_id = 'ct00000099',
            slot = 1, portion = CH.PORTION.BASELINE, source = 'bank', amount = 700,
            state = CH.ESCROW_STATE.HELD } })
        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))
        local out = said(3)
        truthy(out:find('ct00000099:1', 1, true) and out:find('return <citizenid>', 1, true), out)

        truthy(pcall(cmd[Config.Admin.Commands.settle], 3, { 'ct00000099:1', 'return', 'CREATOR1' }))
        eq(s.storage.readEscrowLine('ct00000099:1').state, CH.ESCROW_STATE.SETTLED, said(3))
    end)

    it('prints an unmasking whose parties the framework cannot name', function()
        local s, f, c = seeded({ accept = true, anonymous = true, anonHitman = true })

        -- A hitman and a creator the server has no current name for: they
        -- disconnected, or the framework never described them. The row keeps
        -- the id, which is the whole point of the tool.
        local contract = s.storage.readContract(c.id)
        contract.creator_name, contract.target_name = nil, nil
        s.storage.writeContract(contract)
        for _, h in ipairs(s.storage.readHitmen(c.id)) do
            s.storage.updateHitman(h.id, { hitman_name = nil, alias = nil })
        end

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.identity'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.whois], 3, { c.id }),
            'unmasking a party nobody can name must still print their id')

        local out = said(3)
        truthy(out:find('CREATOR1'), 'the creator id is the answer: ' .. out)
        truthy(out:find('HITMAN01'), 'and the hitman id: ' .. out)
    end)

    it('prints a timeline for a contract with property, a resolution and events', function()
        local s, f, c = seeded({ accept = true })
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'test')
        s.audit.flush()

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.timeline], 3, { c.id }))

        local out = said(3)
        truthy(out:find(c.id), out)
        truthy(out:find('escrow'), 'the escrow lines are the point: ' .. out)

        Env.chat = {}
        truthy(pcall(cmd[Config.Admin.Commands.timeline], 3, { 'ct-nope' }))
        truthy(said(3):find('No such contract'), said(3))
    end)
end)

describe('a contract staff voided', function()
    it('does not cost the creator the cooldown for cancelling their own', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 100000
        Config.Amendments.CancelCooldownSeconds = 300

        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'a mistake staff will fix', reward = { baseline = { cash = 5000 } } })
        truthy(s.admin.void(0, c.id, 'placed on the wrong person'))

        -- The target cooldown is a separate rule and still applies, so this
        -- lists somebody else — the question here is only whether the
        -- CREATOR is being held back for a cancellation they did not make.
        Env.addPlayer({ source = 4, citizenid = 'TARGET09', license = 'license:ddd',
            cash = 100, bank = 100, firstname = 'Sam', lastname = 'Okonkwo' })
        local again, err = s.contracts.create(f.creator, { targetCid = 'TARGET09',
            reason = 'unrelated', reward = { baseline = { cash = 5000 } } })

        truthy(again, 'staff fixing a problem must not rate-limit the person '
            .. 'they were helping, got ' .. tostring(err))
    end)

    it('still returns the escrow in full, exactly as cancelling did', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 100000
        local before = Env.players[1].PlayerData.money.cash
                     + Env.players[1].PlayerData.money.bank

        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01',
            reason = 'x', reward = { baseline = { cash = 5000 } } })
        s.contracts.accept(f.hitman, c.id)
        truthy(s.admin.void(0, c.id, 'staff'))

        eq(Env.players[1].PlayerData.money.cash
           + Env.players[1].PlayerData.money.bank, before,
           'changing which terminal state this lands in must not change the money')
    end)
end)

describe('the diagnosis and what the app itself reported', function()
    --- Everything else the diagnosis prints is the server's view of itself.
    --- The app runs in a browser on the player's machine, and from here that
    --- was invisible: a page throwing on every render looked exactly like a
    --- player who had stopped opening the app.
    local function diagnose(s)
        -- Naming a player: the console-only path stops before the
        -- server-wide section this is about.
        return table.concat(s.admin.diagnose(0, '3'), '\n')
    end

    it('says plainly when no page has reported anything', function()
        local s = newStack(); fixture(s)
        local out = diagnose(s)
        truthy(out:find('app faults: none'),
            'silence has to be reported as silence, or a reader cannot tell '
            .. 'it from a check that was never run: ' .. out)
    end)

    it('shows what a player\'s page reported, and which build it was', function()
        local s = newStack()
        local f = fixture(s)

        s.app.handlers.pageError(f.hitman, {
            what = 'contract.reward is undefined', where = 'app.js:512:8',
            stack = 'at card', build = '2026.09.1',
        })

        local out = diagnose(s)
        truthy(out:find('contract%.reward is undefined'),
            'the fault itself: ' .. out)
        truthy(out:find('app%.js:512'), 'and where it happened: ' .. out)
        truthy(out:find('2026%.09%.1'),
            'and which copy of the page they are running, which is the first '
            .. 'thing to check: ' .. out)
        truthy(out:find(f.hitman.cid), 'and who saw it: ' .. out)
    end)

    it('keeps the newest faults rather than the first twenty', function()
        local s = newStack()
        local f = fixture(s)
        for i = 1, 30 do
            s.app.handlers.pageError(f.hitman, { what = 'fault number ' .. i })
        end

        local kept = s.app.recentPageFaults()
        truthy(#kept <= 20, 'the ring has to be bounded, got ' .. #kept)
        eq(kept[1].what, 'fault number 30',
            'newest first: the one that just happened is the one being looked for')
    end)
end)

describe('the extra ACEs open only the read-only staff commands', function()
    it('refuses void, settle and whois to a player with only `command`', function()
        local s, _, c = seeded({ accept = true, anonHitman = true })
        local cmds = commands(s)
        Env.aces[3] = { command = true }
        Env.chat = {}
        cmds[Config.Admin.Commands.whois](3, { c.id })
        falsy(said(3):find('HITMAN01', 1, true), 'unmasked on the generic command ACE: ' .. said(3))
        cmds[Config.Admin.Commands.void](3, { c.id })
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED, 'voided on the generic command ACE')
        Env.chat = {}
        cmds[Config.Admin.Commands.diagnose](3, {})
        truthy(#said(3) > 0, 'the read-only diagnosis stays open to it')
    end)
end)

--- Lines left for staff (Escrow.parked): a give that raised, or one a
--- restart caught under way. Whether it arrived is for staff to check, and
--- settling one that did arrive used to mean giving it again: pay was the
--- only way to close it.
describe('lines left for staff', function()
    --- The seeded contract's line, paid to the hitman with AddMoney made to
    --- raise: before crediting (`part` nil, three times, to the limit), or
    --- after crediting `part` of it.
    local function leftForStaff(part)
        local s, f, c = seeded({ accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function(account, _, reason)
            if part then real(account, part, reason) end
            error('AddMoney hook raised', 0)
        end
        local ok, err = pcall(function()
            s.escrow.release(c.id, 'HITMAN01', { line = line.id }, 'test')
            for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do s.escrow.retryPending('HITMAN01') end
        end)
        p.Functions.AddMoney = real
        truthy(ok, tostring(err))
        line = s.storage.readEscrowLine(line.id)
        truthy(s.escrow.parked(line), 'left for staff')
        return s, f, c, line
    end

    it('settles one as delivered, giving nothing, and logs it', function()
        local s, _, c, line = leftForStaff()
        local before = money(3)
        local ok, err = s.admin.settleLine(0, line.id, 'delivered')
        truthy(ok, tostring(err))
        eq(money(3), before, 'nothing given')
        local stored = s.storage.readEscrowLine(line.id)
        eq(stored.state, CH.ESCROW_STATE.SETTLED)
        eq(stored.settled_to, 'HITMAN01', 'settled to whom it was going')
        eq(#s.admin.interrupted(), 0, 'no longer a question')

        s.audit.flush()
        local row
        for _, r in ipairs(s.storage.auditForContract(c.id, 200)) do
            if r.action == 'admin_settle_line' then row = r end
        end
        truthy(row, 'staff settling it is on the record')
        eq(row.detail.disposition, 'delivered')
        eq(row.detail.given, 0)

        local again, why = s.admin.settleLine(0, line.id, 'delivered')
        falsy(again)
        eq(why, CH.ERR.ALREADY_SETTLED)
    end)

    it('refuses delivered on a line that is not left for staff', function()
        local s, _, c = seeded({ accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        local ok, why = s.admin.settleLine(0, line.id, 'delivered')
        falsy(ok, 'a line the normal paths still give is not settled unpaid')
        eq(why, CH.ERR.INVALID_INPUT)
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.HELD)
    end)

    it('hands one back to whoever put it up, only what had not arrived', function()
        local s, _, _, line = leftForStaff(2000)
        eq(tonumber(line.deliver_arrived), 2000)
        local creator, hitman = money(1), money(3)
        local ok, err = s.admin.settleLine(0, line.id, 'return')
        truthy(ok, tostring(err))
        eq(money(1) - creator, 3000, 'the part still held goes back to the client')
        eq(money(3), hitman, 'and the hitman keeps what reached them')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
    end)

    it('prints what arrived, why it was left, and every way to settle it', function()
        local s, f, c, line = leftForStaff(2000)
        -- And one a restart caught under way, as the next start leaves it.
        local c2 = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 700 } } })
        local cut = s.storage.readEscrow(c2.id)[1]
        cut.releasing_to = 'CREATOR1'
        s.storage.writeEscrow(c2.id, { cut })
        truthy(s.escrow.parkInterrupted(cut))
        s.audit.flush()

        local listed = {}
        for _, row in ipairs(s.admin.interrupted(0)) do listed[row.line] = row end
        eq(listed[line.id].arrived, 2000)
        eq(listed[line.id].why, 'unknown')
        eq(listed[cut.id].why, 'interrupted')
        eq(listed[cut.id].intended, 'CREATOR1')

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        Env.chat = {}
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))
        local out = said(3)
        truthy(out:find('2000 of it arrived', 1, true), out)
        truthy(out:find('the server stopped while it was being given', 1, true), out)
        truthy(out:find(Config.Admin.Commands.settle .. ' <line> delivered', 1, true), out)
        truthy(out:find('gives only what has not arrived', 1, true), out)

        truthy(pcall(cmd[Config.Admin.Commands.settle], 3, { cut.id, 'delivered' }))
        truthy(said(3):find('Line settled.', 1, true), said(3))
        eq(s.storage.readEscrowLine(cut.id).state, CH.ESCROW_STATE.SETTLED)
        local _ = c
    end)
end)

--- A give the server stopped part-way left more with the player than the
--- line records (the process died before afterRaise wrote what arrived), and
--- the next start left it for staff knowing nothing of that part. `pay`
--- gave the whole line less only what it recorded: 2,000 of a 5,000 payout
--- there, and 5,000 more on top. Balances across a restart cannot say what
--- arrived, so staff check, and give exactly what is missing.
describe('paying a line left for staff a set amount', function()
    local function commands(s)
        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        Env.chat = {}
        return Env.commands
    end

    local function said(target)
        local out = {}
        for _, line in ipairs(Env.chat) do
            if line.target == target then out[#out + 1] = line.text end
        end
        return table.concat(out, '\n')
    end

    local function picks(src)
        local n = 0
        for _, slot in ipairs(Env.players[src]._inventory or {}) do
            if slot.name == 'lockpick' then n = n + slot.count end
        end
        return n
    end

    --- The seeded payout to the hitman, `part` of it credited as the give
    --- began and the process died: left for staff at the next start
    --- (Escrow.parkInterrupted), with nothing recorded as arrived.
    local function interruptedAfter(part)
        local s, f, c = seeded({ accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        Env.players[3].PlayerData.money.cash = Env.players[3].PlayerData.money.cash + part
        line.releasing_to = 'HITMAN01'
        s.storage.writeEscrow(c.id, { line })
        truthy(s.escrow.parkInterrupted(line))
        line = s.storage.readEscrowLine(line.id)
        eq(line.deliver_arrived, nil, 'the line does not know what arrived')
        return s, f, c, line
    end

    local function settleRow(s, contractId)
        s.audit.flush()
        local row
        for _, r in ipairs(s.storage.auditForContract(contractId, 200)) do
            if r.action == 'admin_settle_line' then row = r end
        end
        return row
    end

    it('gives exactly the amount staff name, and counts the rest as arrived', function()
        local s, _, c, line = interruptedAfter(2000)
        local hitman = money(3)
        local cmd = commands(s)
        Env.aces[7] = { ['crimson.admin'] = true }
        Env.addPlayer({ source = 7, citizenid = 'STAFF001', license = 'license:st' })
        truthy(pcall(cmd[Config.Admin.Commands.settle], 7, { line.id, 'pay', '3000' }))
        truthy(said(7):find('Line settled.', 1, true), said(7))
        eq(money(3) - hitman, 3000, 'what staff found missing, and no more')

        local stored = s.storage.readEscrowLine(line.id)
        eq(stored.state, CH.ESCROW_STATE.SETTLED)
        eq(stored.settled_to, 'HITMAN01')
        eq(tonumber(stored.deliver_arrived), 2000, 'the rest is on the line as already with them')
        local row = settleRow(s, c.id)
        truthy(row, 'on the record')
        eq(row.actor_cid, 'STAFF001')
        eq(row.detail.amount, 3000, 'with the amount staff gave')
        eq(row.detail.owed, 5000, 'and what the line said it still owed')

        eq(select(2, s.admin.settleLine(0, line.id, 'pay', '1')), CH.ERR.ALREADY_SETTLED)
        eq(money(3) - hitman, 3000, 'and never again')
    end)

    it('refuses an amount that is not a whole number of at least one, or over what is owed', function()
        local s, f, c, line = interruptedAfter(0)
        local hitman = money(3)
        for _, bad in ipairs({ '0', '-5', '1.5', '1e3', '0x10', 'abc', '', ' 10', '5001',
                               '99999999999999999999', 0, -1, 2.5, 5001, 0 / 0, math.huge }) do
            local ok, err = s.admin.settleLine(0, line.id, 'pay', bad)
            falsy(ok, 'must refuse ' .. tostring(bad))
            eq(err, CH.ERR.INVALID_INPUT, tostring(bad))
        end
        eq(money(3), hitman, 'nothing given')
        local stored = s.storage.readEscrowLine(line.id)
        eq(stored.state, CH.ESCROW_STATE.HELD)
        truthy(s.escrow.parked(stored), 'and still left for staff')

        -- Only on a line left for staff: on any other, the normal paths give
        -- it, and settling it short would lose the rest.
        local c2 = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 700 } } })
        local owed = s.storage.readEscrow(c2.id)[1]
        owed.owed_to = 'HITMAN01'
        s.storage.writeEscrow(c2.id, { owed })
        s.storage.queuePending('HITMAN01', c2.id, owed.id)
        eq(select(2, s.admin.settleLine(0, owed.id, 'pay', '700')), CH.ERR.INVALID_INPUT)
        eq(s.storage.readEscrowLine(owed.id).state, CH.ESCROW_STATE.HELD)

        -- All that it owes is an amount like any other.
        truthy(s.admin.settleLine(0, line.id, 'pay', 5000))
        eq(money(3) - hitman, 5000)
        local _ = c
    end)

    it('counts an item line by the piece', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000, items = { { name = 'lockpick', count = 4 } } } } })
        truthy(c, 'placed')
        local item
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'item' then item = line end
        end
        -- One of the four reached the hitman as the server stopped.
        table.insert(Env.players[3]._inventory, { name = 'lockpick', count = 1 })
        item.releasing_to = 'HITMAN01'
        s.storage.writeEscrow(c.id, { item })
        truthy(s.escrow.parkInterrupted(item))
        local held = picks(3)

        eq(select(2, s.admin.settleLine(0, item.id, 'pay', '5')), CH.ERR.INVALID_INPUT,
            'more than the line holds')
        truthy(s.admin.settleLine(0, item.id, 'pay', '3'))
        eq(picks(3) - held, 3, 'the three that were missing')
        local stored = s.storage.readEscrowLine(item.id)
        eq(stored.state, CH.ESCROW_STATE.SETTLED)
        eq(tonumber(stored.deliver_arrived), 1)
    end)

    it('gives a player who is away exactly that amount at their next login', function()
        local s, _, _, line = interruptedAfter(2000)
        local hitman = money(3)
        local away = Env.players[3]
        Env.removePlayer(3)
        local ok, note = s.admin.settleLine(0, line.id, 'pay', '3000')
        truthy(ok)
        eq(note, 'queued')
        Env.players[3], Env.byCitizen.HITMAN01 = away, 3
        for _ = 1, 3 do s.escrow.retryPending('HITMAN01') end
        eq(money(3) - hitman, 3000, 'the amount, not the whole line')
        eq(s.storage.readEscrowLine(line.id).state, CH.ESCROW_STATE.SETTLED)
    end)

    it('flags each line whose arrival is unknown, with the amount to pay', function()
        local s, f, _, line = interruptedAfter(2000)
        -- And one whose give raised with nothing arriving, which is known.
        local c2 = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 700 } } })
        local raised = s.storage.readEscrow(c2.id)[1]
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        local ok, err = pcall(function()
            for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
                s.escrow.release(c2.id, 'HITMAN01', { line = raised.id }, 'test')
            end
        end)
        p.Functions.AddMoney = real
        truthy(ok, tostring(err))
        truthy(s.escrow.parked(s.storage.readEscrowLine(raised.id)))
        s.audit.flush()

        local cmd = commands(s)
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(cmd[Config.Admin.Commands.stuck], 3, {}))
        local out = said(3)
        local hint = ('check what they received, then pay the rest with /%s %s pay <amount>, '
            .. 'or delivered'):format(Config.Admin.Commands.settle, line.id)
        truthy(out:find(hint, 1, true), out)
        falsy(out:find(('/%s %s pay <amount>'):format(Config.Admin.Commands.settle, raised.id),
            1, true), 'nothing arrived of the one that raised: ' .. out)
    end)
end)

describe('a staff pay whose give raises again', function()
    it('says it is left for staff again, not queued for a login that gives nothing', function()
        local s, _, c = seeded({ accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        line.releasing_to = 'HITMAN01'
        s.storage.writeEscrow(c.id, { line })
        truthy(s.escrow.parkInterrupted(line))
        local hitman = money(3)

        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function(account, _, reason)
            real(account, 1000, reason)
            error('AddMoney hook raised', 0)
        end
        local ok, note = s.admin.settleLine(0, line.id, 'pay')
        p.Functions.AddMoney = real
        falsy(ok, 'not settled')
        eq(note, 'parked')
        truthy(s.escrow.parked(s.storage.readEscrowLine(line.id)), 'left for staff again')
        eq(money(3) - hitman, 1000)

        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        Env.chat = {}
        p.Functions.AddMoney = function(account, _, reason)
            real(account, 500, reason)
            error('AddMoney hook raised', 0)
        end
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(Env.commands[Config.Admin.Commands.settle], 3, { line.id, 'pay' }))
        p.Functions.AddMoney = real
        truthy(said(3):find('left for staff again', 1, true), said(3))
        truthy(said(3):find('/' .. Config.Admin.Commands.stuck, 1, true), said(3))
        falsy(said(3):find('Queued', 1, true), said(3))

        -- Paid the rest, once.
        truthy(s.admin.settleLine(0, line.id, 'pay'))
        eq(money(3) - hitman, 5000)
    end)
end)

--- Settling a line left for staff reset its raise count before the release
--- claimed it. A raise in between (a dropped database connection) left it
--- held, owed, queued for nobody and no longer left for staff: no login gave
--- it, and /ch-stuck listed nothing until the next restart.
describe('a staff settle that raises before its release claims the line', function()
    local function parkedLine()
        local s, _, c = seeded({ accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        local p = Env.players[3]
        local real = p.Functions.AddMoney
        p.Functions.AddMoney = function() error('AddMoney hook raised', 0) end
        local ok, err = pcall(function()
            for _ = 1, s.escrow.DELIVER_RAISE_LIMIT do
                s.escrow.release(c.id, 'HITMAN01', { line = line.id }, 'test')
            end
        end)
        p.Functions.AddMoney = real
        truthy(ok, tostring(err))
        truthy(s.escrow.parked(s.storage.readEscrowLine(line.id)), 'left for staff')
        return s, c, line
    end

    for _, disposition in ipairs({ 'pay', 'return' }) do
        it(disposition .. ': leaves it left for staff, and listed', function()
            local s, _, line = parkedLine()
            local hitman, creator = money(3), money(1)
            local claim = s.storage.claimEscrowLine
            s.storage.claimEscrowLine = function() error('connection lost', 0) end
            falsy(pcall(s.admin.settleLine, 0, line.id, disposition))
            s.storage.claimEscrowLine = claim

            truthy(s.escrow.parked(s.storage.readEscrowLine(line.id)), 'still left for staff')
            local listed
            for _, row in ipairs(s.admin.interrupted(0)) do
                if row.line == line.id then listed = row end
            end
            truthy(listed, '/ch-stuck shows it')
            for _ = 1, 3 do s.escrow.retryPending('HITMAN01') end
            eq(money(3), hitman, 'nothing gave it meanwhile')

            truthy(s.admin.settleLine(0, line.id, disposition))
            eq(money(3) - hitman + money(1) - creator, 5000, 'settled once')
        end)
    end
end)

--- Whatever else leaves a line held, owed, still naming whom its give was
--- going to, and neither left for staff nor queued, is given by nothing
--- until the next start, and was listed by nothing either.
describe('a held line a give stopped part-way on the running server', function()
    local function stalledLine()
        local s, f, c = seeded({ accept = true })
        local line = s.storage.readEscrow(c.id)[1]
        line.owed_to, line.releasing_to = 'HITMAN01', 'HITMAN01'
        s.storage.writeEscrow(c.id, { line })
        return s, f, c, s.storage.readEscrowLine(line.id)
    end

    it('is listed for staff from the escrow itself, with the hint', function()
        local s, _, c, line = stalledLine()
        falsy(s.escrow.parked(line))
        local rows = s.admin.interrupted(0)
        eq(#rows, 1, 'listed')
        eq(rows[1].line, line.id)
        eq(rows[1].contract, c.id)
        eq(rows[1].intended, 'HITMAN01')
        eq(rows[1].why, 'stalled')

        Env.aces[7] = { command = true }
        Env.addPlayer({ source = 7, citizenid = 'STAFF001', license = 'license:st' })
        eq(s.admin.interrupted(7)[1].intended, 'an operative', 'a role to staff who may not see who')

        Env.commands = {}
        require('crimson-hitman.server.bridges').installCommands(s)
        Env.chat = {}
        Env.aces[3] = { ['crimson.admin'] = true }
        truthy(pcall(Env.commands[Config.Admin.Commands.stuck], 3, {}))
        local out = said(3)
        truthy(out:find(line.id, 1, true), out)
        truthy(out:find(('/%s %s pay <amount>, or delivered'):format(
            Config.Admin.Commands.settle, line.id), 1, true), out)
    end)

    it('is not listed once it is queued for its player', function()
        local s, _, c, line = stalledLine()
        eq(#s.admin.interrupted(0), 1, 'listed while nothing gives it')
        s.storage.queuePending('HITMAN01', c.id, line.id)
        eq(#s.admin.interrupted(0), 0, 'a login gives it now')
    end)

    it('is settled as a line left for staff', function()
        local s, _, _, line = stalledLine()
        local hitman = money(3)
        local ok, err = s.admin.settleLine(0, line.id, 'delivered')
        truthy(ok, tostring(err))
        eq(money(3), hitman, 'nothing given')
        eq(s.storage.readEscrowLine(line.id).settled_by_staff, 'delivered')

        local s2, _, _, line2 = stalledLine()
        hitman = money(3)
        truthy(s2.admin.settleLine(0, line2.id, 'pay', '1500'))
        eq(money(3) - hitman, 1500)
    end)
end)

--- /ch-stuck named the party for a line caught mid-release from the log's
--- release_interrupted row. A return queued for the client since owes it to
--- the client, while the row still names the hitman.
describe('the party /ch-stuck names for an interrupted line', function()
    it('is whom the line is owed to now, not whom the log row named', function()
        local s, _, c = seeded()
        local line = s.storage.readEscrow(c.id)[1]
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.HELD, CH.ESCROW_STATE.RELEASING))
        truthy(s.storage.claimEscrowLine(line.id, CH.ESCROW_STATE.RELEASING, CH.ESCROW_STATE.HELD))
        s.audit.financial('release_interrupted', 'HITMAN01', c.id,
            { line = line.id, amount = line.amount, review = true })
        s.audit.flush()
        eq(s.admin.interrupted(0)[1].intended, 'HITMAN01', 'whom the row names, while the line names nobody')

        Env.removePlayer(1)
        local ok, note = s.admin.settleLine(0, line.id, 'return')
        truthy(ok)
        eq(note, 'queued')
        eq(s.storage.readEscrowLine(line.id).owed_to, 'CREATOR1')
        local rows = s.admin.interrupted(0)
        eq(#rows, 1)
        eq(rows[1].intended, 'CREATOR1', 'owed to the client now')
    end)
end)
