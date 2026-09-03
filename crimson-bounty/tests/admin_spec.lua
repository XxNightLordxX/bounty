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
