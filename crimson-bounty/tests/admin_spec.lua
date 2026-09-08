--- Staff commands.
---
--- The audit log recorded everything and nothing surfaced it in game, so a
--- staff member handling "the script ate my gun" needed database access.
--- These cover the four things staff can now do — and, as importantly, what
--- someone without the ACE cannot.

local function seeded(opts)
    opts = opts or {}
    local s = newStack()
    local f = fixture(s)
    Env.players[3].PlayerData.money.bank = 50000
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
        anonymous = opts.anonymous,
    })
    if opts.accept then s.contracts.accept(f.hunter, c.id, opts.anonHunter) end
    return s, f, c
end

--- Run a registered command as a player would. The commands are registered
--- by bridges.install, which the harness's stack does not run, so they are
--- installed here against the same modules.
local function commands(s)
    Env.commands = {}
    require('crimson-bounty.server.bridges').installCommands(s)
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
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE, 'and nothing happened')
    end)

    it('separates reading a history from unmasking a person', function()
        local s, f, c = seeded({ accept = true, anonHunter = true })
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
        eq(#view.hunters, 1, 'the hunter who accepted')
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
        eq(s.storage.readContract(c.id).state, CB.STATE.CANCELLED)

        local after = Env.players[1].PlayerData.money.cash + Env.players[1].PlayerData.money.bank
        eq(after - before, 5000, 'the escrow comes back')
    end)

    it('returns a hunter their stake rather than forfeiting it', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))
        eq(Env.players[3].PlayerData.money.bank, 40000, 'staked')

        truthy(s.admin.void(0, c.id, 'staff'))
        eq(Env.players[3].PlayerData.money.bank, 50000,
            'a staff void is not the hunter failing')
    end)

    it('leaves nothing held', function()
        local s, f, c = seeded({ accept = true })
        truthy(s.admin.void(0, c.id, 'staff'))
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CB.ESCROW_STATE.SETTLED, 'every line settles')
        end
    end)

    it('refuses a contract that has already ended', function()
        local s, f, c = seeded({ accept = true })
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION))
        local ok, err = s.admin.void(0, c.id, 'too late')
        falsy(ok)
        eq(err, CB.ERR.ALREADY_SETTLED)
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

        truthy(s.storage.claimEscrowLine(line.id, CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING))
        -- Recovery's half: back to held, logged for review.
        truthy(s.storage.claimEscrowLine(line.id, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD))
        s.audit.financial('release_interrupted', 'HUNTER01', c.id,
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
        eq(rows[1].intended, 'HUNTER01', 'who it was being paid to')
    end)

    it('stops listing one that has since been settled', function()
        local s, f, c, line = stranded()
        truthy(s.admin.settleLine(0, line.id, 'return'))
        eq(#s.admin.interrupted(), 0, 'a resolved question is not a question')
    end)

    it('pays the intended recipient when staff say to', function()
        local s, f, c, line = stranded()
        local before = Env.players[3].PlayerData.money.cash

        -- The line records who the interrupted release was paying.
        line.releasing_to = 'HUNTER01'
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
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(s.contracts.accept(f.hunter, c.id, false))

        -- The hunter cannot be paid, so the release stalls exactly where a
        -- shutdown would leave it.
        Env.players[3]._inventoryFull = true
        Env.players[3].PlayerData.money._refuse = true

        local lineId = s.storage.readEscrow(c.id)[1].id
        truthy(s.storage.claimEscrowLine(lineId, CB.ESCROW_STATE.HELD, CB.ESCROW_STATE.RELEASING))
        -- Recovery's half.
        truthy(s.storage.claimEscrowLine(lineId, CB.ESCROW_STATE.RELEASING, CB.ESCROW_STATE.HELD))
        Env.players[3]._inventoryFull = false

        -- Now do it for real and check what the line remembers.
        s.escrow.release(c.id, 'HUNTER01', { portion = CB.PORTION.BASELINE }, 'payout')
        eq(s.storage.readEscrowLine(lineId).releasing_to, 'HUNTER01',
            'a line must name who it was going to, before the money moves')
    end)

    it('carries the intended recipient through storage in every backend', function()
        local Exec = require('crimson-bounty.tests.harness.mysql_exec')
        for _, name in ipairs({ 'memory', 'json', 'mysql' }) do
            local store
            if name == 'mysql' then
                Exec.install(Natives)
                package.loaded['crimson-bounty.server.storage.mysql'] = nil
                store = require('crimson-bounty.server.storage.mysql')
            else
                package.loaded['crimson-bounty.server.storage.' .. name] = nil
                Natives.files = {}
                store = require('crimson-bounty.server.storage.' .. name)
            end
            store.open()

            store.writeEscrow('ct1', { {
                id = 'ct1:1', contract_id = 'ct1', slot = 1, portion = 'baseline',
                source = 'cash', amount = 5000, state = CB.ESCROW_STATE.HELD,
                releasing_to = 'HUNTER01',
            } })
            eq(store.readEscrowLine('ct1:1').releasing_to, 'HUNTER01',
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
        eq(s.storage.readEscrowLine(lines[1].id).state, CB.ESCROW_STATE.SETTLED)
        eq(s.storage.readEscrowLine(lines[2].id).state, CB.ESCROW_STATE.HELD,
            'a named line must not release the whole contract')
    end)

    it('refuses a disposition it does not understand', function()
        local s, f, c, line = stranded()
        for _, bad in ipairs({ 'refund', 'PAY', '', 'delete' }) do
            local ok, err = s.admin.settleLine(0, line.id, bad)
            falsy(ok, 'must refuse ' .. bad)
            eq(err, CB.ERR.INVALID_INPUT)
        end
        eq(s.storage.readEscrowLine(line.id).state, CB.ESCROW_STATE.HELD, 'untouched')
    end)

    it('refuses to settle a line twice', function()
        local s, f, c, line = stranded()
        truthy(s.admin.settleLine(0, line.id, 'return'))
        local ok, err = s.admin.settleLine(0, line.id, 'return')
        falsy(ok)
        eq(err, CB.ERR.ALREADY_SETTLED)
    end)
end)

describe('identifying an anonymous party', function()
    it('names everyone behind a contract', function()
        local s, f, c = seeded({ accept = true, anonymous = true, anonHunter = true })
        local who, err = s.admin.identify(0, c.id)
        truthy(who, tostring(err))

        eq(who.creator.cid, 'CREATOR1')
        eq(who.creator.anonymous, true)
        eq(who.target.cid, 'TARGET01')
        eq(#who.hunters, 1)
        eq(who.hunters[1].cid, 'HUNTER01')
        eq(who.hunters[1].anonymous, true)
        truthy(who.hunters[1].alias, 'and the alias they were shown under')
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
        local bridges = require('crimson-bounty.server.bridges')
        bridges.installCommands(s)
        return out
    end

    it('does not call a piece of property "$0"', function()
        local describe = require('crimson-bounty.server.bridges').describeLine

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
        local describe = require('crimson-bounty.server.bridges').describeLine
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
            mode = CB.MODE.COMPETITIVE,
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
        require('crimson-bounty.server.bridges').installCommands(s)
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

        local hunter = s.storage.readHunter(c.id, f.hunter.cid)
        s.storage.updateHunter(hunter.id, { last_claim_at = now })
        for _ = 1, 200 do s.ratelimit.check(f.creator, 'create') end
        eq(s.ratelimit.check(f.creator, 'create'), false, 'the bucket is spent')

        Env.aces[3] = { ['crimson.admin'] = true }
        Env.chat = {}
        cmd(s)(3, {})

        eq(s.ratelimit.check(f.creator, 'create'), true, 'the bucket was refilled')
        local after = s.storage.readHunter(c.id, f.hunter.cid)
        truthy(now - after.last_claim_at > Config.Limits.SlotCooldownSeconds,
            'the slot cooldown was aged past its window')
        truthy(said(3):find('Timers refreshed'), said(3))
    end)

    it('ages a resolved contract past the re-list cooldown', function()
        local s, f, c = seeded()
        s.contracts.resolve(c.id, CB.STATE.EXPIRED, f.creator.cid, nil, 'expired')

        local relist = { targetCid = 'TARGET01', reason = 'Again',
                         reward = { baseline = { cash = 1000 } } }
        eq(select(2, s.contracts.create(f.creator, relist)),
            CB.ERR.TARGET_RECENTLY_ON, 'the re-list cooldown is running')

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
        eq(after.state, CB.STATE.ACTIVE,
            'refreshing must never resolve a contract, which would move money')
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
        eq(select(2, s.informant.buy(f.creator, c.id)), CB.ERR.LIMIT_REACHED,
            'the refresh must not hand a buyer the whole roster')
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
describe('bountyadmin from the console', function()
    local function run(s, args)
        Env.commands = {}
        require('crimson-bounty.server.bridges').installCommands(s)
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
        s.contracts.accept(f.hunter, c.id)

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
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED)
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
            CB.ERR.TARGET_JUST_ON, 'the new-player rule is running')

        Env.commands = {}
        require('crimson-bounty.server.bridges').installCommands(s)
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
