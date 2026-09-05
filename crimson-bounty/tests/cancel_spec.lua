--- Taking a contract back down.
---
--- A creator who put a contract up and thought better of it had no way to
--- get their escrow back. Cancelling existed only as an amendment both
--- sides had to agree to — and with nobody holding the contract there is
--- nobody to agree — or as a staff command. So the money sat there until
--- the deadline ran out, on a contract nobody had even accepted.

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

local function placed(s, opts)
    opts = opts or {}
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = opts.mode or CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        penaltyAmount = opts.penalty,
    })
    return f, c
end

describe('cancelling a contract nobody has taken', function()
    it('gives the creator every coin back', function()
        local s = newStack()
        local before = nil
        local f, c = placed(s)
        before = Env.players[1].PlayerData.money.cash
        eq(before, 92500, 'the escrow is out of their pocket')

        local ok, err = s.contracts.cancel(f.creator, c.id)
        truthy(ok, tostring(err))
        eq(Env.players[1].PlayerData.money.cash, 100000,
            'and comes back in full when nobody has taken it')
    end)

    it('closes the contract rather than leaving it on the board', function()
        local s = newStack()
        local f, c = placed(s)
        truthy(s.contracts.cancel(f.creator, c.id))
        eq(s.storage.readContract(c.id).state, CB.STATE.CANCELLED)
        eq(s.storage.readContract(c.id).resolution, 'cancelled_by_creator')
    end)

    it('leaves no escrow behind', function()
        local s = newStack()
        local f, c = placed(s)
        s.contracts.cancel(f.creator, c.id)
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CB.ESCROW_STATE.SETTLED,
                'a cancelled contract holds nothing: ' .. tostring(line.id))
        end
    end)

    it('is refused once a hunter is actually holding it', function()
        -- The whole point of escrow is that a hunter who has started work
        -- cannot have the reward pulled out from under them.
        local s = newStack()
        local f, c = placed(s)
        truthy(s.contracts.accept(f.hunter, c.id, false))

        local ok, err = s.contracts.cancel(f.creator, c.id)
        falsy(ok, 'a contract somebody is hunting is not the creator to take back')
        eq(err, CB.ERR.BAD_STATE)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACCEPTED, 'and it stands')
    end)

    it('is allowed again once the hunter walks away', function()
        local s = newStack()
        local f, c = placed(s)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.contracts.abandon(f.hunter, c.id))

        local ok, err = s.contracts.cancel(f.creator, c.id)
        truthy(ok, 'nobody is holding it now: ' .. tostring(err))
        eq(Env.players[1].PlayerData.money.cash, 100000, 'and the escrow comes home')
    end)

    it('is only for the creator', function()
        local s = newStack()
        local f, c = placed(s)
        local ok, err = s.contracts.cancel(f.hunter, c.id)
        falsy(ok, 'a stranger cannot close somebody else contract')
        eq(err, CB.ERR.NOT_PARTICIPANT)
        eq(s.storage.readContract(c.id).state, CB.STATE.ACTIVE)
    end)

    it('cannot be done twice', function()
        local s = newStack()
        local f, c = placed(s)
        truthy(s.contracts.cancel(f.creator, c.id))
        local ok = s.contracts.cancel(f.creator, c.id)
        falsy(ok, 'the escrow has already gone home once')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'and only once')
    end)

    it('refuses a contract that does not exist', function()
        local s = newStack()
        local f = fixture(s)
        local ok, err = s.contracts.cancel(f.creator, 'ct99999999')
        falsy(ok)
        eq(err, CB.ERR.NOT_FOUND)
    end)

    it('is reachable from the app, and rate limited like everything else', function()
        local s = newStack()
        local f, c = placed(s)
        local reply = call('cancel', 1, { id = c.id })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(s.storage.readContract(c.id).state, CB.STATE.CANCELLED)

        local refused = 0
        for _ = 1, 40 do
            local r = call('cancel', 1, { id = c.id })
            if r and r.err == CB.ERR.RATE_LIMITED then refused = refused + 1 end
        end
        truthy(refused > 0, 'it must not be free to hammer')
    end)

    it('is written to the audit log', function()
        local s = newStack()
        local f, c = placed(s)
        s.contracts.cancel(f.creator, c.id)
        s.audit.flush()
        local seen = false
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'contract_cancelled' then seen = true end
        end
        truthy(seen, 'money moving is always recorded')
    end)
end)

describe('editing a contract nobody has taken', function()
    it('changes the reason', function()
        local s = newStack()
        local f, c = placed(s)
        local ok, err = s.contracts.revise(f.creator, c.id, { reason = 'Actually, theft' })
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c.id).reason, 'Actually, theft')
    end)

    it('cleans the new reason the same way the first one was', function()
        local s = newStack()
        local f, c = placed(s)
        s.contracts.revise(f.creator, c.id, { reason = '  ' .. string.rep('x', 400) .. '  ' })
        local stored = s.storage.readContract(c.id).reason
        truthy(#stored <= 140, 'a reason is capped wherever it is set: ' .. #stored)
    end)

    it('moves the deadline in either direction', function()
        local s = newStack()
        local f, c = placed(s)
        local before = s.storage.readContract(c.id).deadline_at

        truthy(s.contracts.revise(f.creator, c.id, { deadlineSeconds = 7200 }))
        local after = s.storage.readContract(c.id).deadline_at
        falsy(after == before, 'the deadline must actually move')
        truthy(after <= s.storage.readContract(c.id).expires_at,
            'and never past the absolute lifetime')
    end)

    it('refuses a deadline in the past', function()
        local s = newStack()
        local f, c = placed(s)
        local ok, err = s.contracts.revise(f.creator, c.id, { deadlineSeconds = 0 })
        falsy(ok, 'a contract that has already expired is not an edit')
        eq(err, CB.ERR.INVALID_INPUT)
    end)

    it('is refused once a hunter is holding it', function()
        local s = newStack()
        local f, c = placed(s)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local ok, err = s.contracts.revise(f.creator, c.id, { reason = 'changed my mind' })
        falsy(ok, 'a hunter accepted the contract as written')
        eq(err, CB.ERR.BAD_STATE)
        eq(s.storage.readContract(c.id).reason, 'Unpaid debt')
    end)

    it('is only for the creator', function()
        local s = newStack()
        local f, c = placed(s)
        local ok, err = s.contracts.revise(f.hunter, c.id, { reason = 'nope' })
        falsy(ok)
        eq(err, CB.ERR.NOT_PARTICIPANT)
    end)

    it('refuses an edit that changes nothing', function()
        local s = newStack()
        local f, c = placed(s)
        local ok, err = s.contracts.revise(f.creator, c.id, {})
        falsy(ok, 'an empty edit is a mistake, not a no-op to be written back')
        eq(err, CB.ERR.INVALID_INPUT)
    end)

    it('is reachable from the app', function()
        local s = newStack()
        local f, c = placed(s)
        local reply = call('revise', 1, { id = c.id, reason = 'Through the app' })
        truthy(reply and reply.ok, tostring(reply and reply.err))
        eq(s.storage.readContract(c.id).reason, 'Through the app')
    end)

    it('is written to the audit log', function()
        local s = newStack()
        local f, c = placed(s)
        s.contracts.revise(f.creator, c.id, { reason = 'Recorded' })
        s.audit.flush()
        local seen = false
        for _, row in ipairs(s.storage.readAudit(200)) do
            if row.action == 'contract_revised' then seen = true end
        end
        truthy(seen)
    end)
end)
