--- What the server tells the phone page, found by walking the page as each
--- role. Each of these is a reply the page drew wrongly or could only
--- misread, and the fix is on the server's side of the wire.

local AT = { x = 200.0, y = 200.0, z = 30.0 }

--- Fire a net event the way a client does, rate limits and all, and return
--- the reply the page would receive.
local function call(name, src, payload)
    local handler = Env.events['crimson-bounty:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then return event.args[1] end
    end
    return nil
end

local function placed(s, f, extra)
    local spec = {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        reward = { baseline = { cash = 5000 } },
    }
    for k, v in pairs(extra or {}) do spec[k] = v end
    local c = s.contracts.create(f.creator, spec)
    truthy(c, 'a contract')
    return c
end

describe('a change proposed on a contract nobody holds', function()
    --- A proposal applies on the last answer it needs. With nobody holding
    --- the contract, that answer is the creator's own — raise_penalty is
    --- only allowed there, and relies on it. The page drew such a proposal
    --- as "Waiting to be applied." with nothing to press, so it lapsed, held
    --- the one open slot, and was put to the next hunter to accept. The page
    --- now gives that answer; these pin what it relies on.
    --- Applied in the propose itself now: the page's own answer was a
    --- second request from the same rate-limit bucket, and two proposals a
    --- few seconds apart left one open that the card never drew.
    it('is applied in the one request, waiting on nobody', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, { reward = { slots = {
            { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
            mode = CB.MODE.COMPETITIVE })
        local reply = call('propose', 1, { id = c.id, kind = 'reduce_reward', payload = { slot = 2 } })
        truthy(reply.ok, tostring(reply.err))
        eq(reply.data.outcome, 'applied')
        eq(#s.amendments.openFor(f.creator, c.id), 0, 'nothing left open')
        eq(s.storage.readContract(c.id).payout_slots, 1,
            'the collection went back, which the reward editor cannot do')
    end)

    it('does not run out of requests on the second change', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, { reward = { slots = {
            { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } },
            { baseline = { cash = 3000 } } } }, mode = CB.MODE.COMPETITIVE })
        local first = call('propose', 1, { id = c.id, kind = 'reduce_reward', payload = { slot = 3 } })
        Env.advance(5)
        local second = call('propose', 1, { id = c.id, kind = 'reduce_reward', payload = { slot = 2 } })
        eq(first.data and first.data.outcome, 'applied')
        eq(second.data and second.data.outcome, 'applied', tostring(second.err))
        eq(s.storage.readContract(c.id).payout_slots, 1)
    end)

    it('tells the page whether proposals exist on this server at all', function()
        local s = newStack()
        local f = fixture(s)
        eq(s.projection.listing('HUNTER01').settings.amendments, true)
        Config.Amendments.Enabled = false
        eq(s.projection.listing('HUNTER01').settings.amendments, false,
            'the page drew Propose change on every card of a server that '
            .. 'refuses every proposal')
        local _ = f
    end)
end)

describe('placing a contract on somebody who can no longer be named', function()
    --- A target handle lapses after ten minutes and dies with the target's
    --- session. The page keeps the list it read and never re-reads it, so
    --- picking the same person again sent the same dead handle — and the
    --- refusal was INVALID_INPUT, "Check what you entered.", on a form with
    --- nothing wrong in it.
    local function attempt(s, f, handle)
        return s.app.handlers.create(f.creator, {
            target = handle, reason = 'x', mode = 'exclusive',
            reward = { slots = { { baseline = { cash = 5000 } } } },
        })
    end

    it('answers not_found for a handle that has lapsed', function()
        local s = newStack()
        local f = fixture(s)
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        Env.advance(601)
        local ok, err = attempt(s, f, handle)
        falsy(ok)
        eq(err, CB.ERR.NOT_FOUND)
    end)

    it('answers not_found once the target has relogged', function()
        local s = newStack()
        local f = fixture(s)
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        s.app.clearPlayerHandles('TARGET01')
        local ok, err = attempt(s, f, handle)
        falsy(ok)
        eq(err, CB.ERR.NOT_FOUND)
    end)

    it('still answers invalid_input when no target was sent at all', function()
        local s = newStack()
        local f = fixture(s)
        local ok, err = attempt(s, f, nil)
        falsy(ok)
        eq(err, CB.ERR.INVALID_INPUT)
    end)

    it('takes nothing from the creator either way', function()
        local s = newStack()
        local f = fixture(s)
        local before = Env.players[1].PlayerData.money.cash
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        Env.advance(601)
        attempt(s, f, handle)
        eq(Env.players[1].PlayerData.money.cash, before)
    end)
end)

describe('what the withdraw reply says came back', function()
    --- The phone notification said some of it was waiting; the page, reading
    --- a reply that carried only the id, said everything had been returned.
    it('carries how much could not be handed over yet', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, {
            mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 }, bonus = { dirty = 1000 } },
        })
        Env.players[1]._inventoryFull = true
        local reply = s.app.handlers.cancel(f.creator, { id = c.id })
        Env.players[1]._inventoryFull = false
        truthy(reply, 'withdrawn')
        truthy((reply.queued or 0) > 0,
            'the page was told nothing was waiting, and said everything came back')
    end)

    it('says nothing is waiting when nothing is', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        local reply = s.app.handlers.cancel(f.creator, { id = c.id })
        truthy(reply)
        eq(reply.queued, 0)
    end)
end)

describe('a thread once its contract has closed', function()
    --- A hunter's row stays active when a contract ends and only the
    --- creator's thread handles are dropped. So a hunter could go on writing
    --- to the client of a finished contract — each message a notification
    --- on their phone — while the client, who could no longer answer, was
    --- told "That is not yours" about the conversation.
    local function closed()
        local s = newStack()
        s.bridges.install(s)
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        truthy(s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION, {}))
        eq(s.storage.readContract(c.id).state, CB.STATE.COMPLETED)
        return s, f, c, handle
    end

    it('refuses the hunter a message, and rings nobody', function()
        local s, f, c = closed()
        Natives.calls.notifications = {}
        local ok, err = s.comms.send(f.hunter, c.id, nil, 'still here')
        falsy(ok, 'a finished contract was still a way to reach its client')
        eq(err, CB.ERR.ALREADY_SETTLED)
        for _, note in ipairs(Natives.calls.notifications) do
            falsy(note.title == 'Contract message', 'the client was notified anyway')
        end
    end)

    it('tells both parties the contract closed, not that it is not theirs', function()
        local s, f, c, handle = closed()
        local _, creatorErr = s.comms.read(f.creator, c.id, handle)
        eq(creatorErr, CB.ERR.ALREADY_SETTLED)
        local _, hunterErr = s.comms.read(f.hunter, c.id, nil)
        eq(hunterErr, CB.ERR.ALREADY_SETTLED)
    end)

    it('lists no threads for it', function()
        local s, f, c = closed()
        eq(#s.comms.threads(f.hunter, c.id), 0)
        eq(#s.comms.threads(f.creator, c.id), 0)
    end)

    it('leaves a live contract talking', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        truthy(s.comms.send(f.hunter, c.id, nil, 'on my way'))
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        eq(#s.comms.read(f.creator, c.id, handle), 1)
    end)
end)

describe('asking about a handover while it is being paid', function()
    --- The countdown is dropped before the payout runs, and the outcome is
    --- written after it — on mysql every step between waits on the database.
    --- A poll landing there found neither and answered no_handover, which
    --- the page reads out as "The handover ended. Get them back to the
    --- client and try again." to a hunter who was being paid.
    it('answers settling rather than no_handover, then how it ended', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hunter, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HUNTER01'))

        local during, duringErr
        local real = s.storage.claimEscrowLine
        s.storage.claimEscrowLine = function(...)
            if during == nil and duringErr == nil then
                during, duringErr = s.app.handlers.kidnapProgress(f.hunter, { id = c.id })
            end
            return real(...)
        end
        local ticks = math.floor((Config.Kidnap.CountdownSeconds * 1000) / Config.Kidnap.TickMs)
        for _ = 1, ticks + 1 do s.kidnap.tick(Config.Kidnap.TickMs) end
        s.storage.claimEscrowLine = real

        truthy(during, 'a poll during the payout was refused: ' .. tostring(duringErr))
        eq(during.settling, true)
        eq(during.elapsed, during.required, 'drawn as a full bar')
        falsy(during.done, 'and not as an ending')

        local after = s.app.handlers.kidnapProgress(f.hunter, { id = c.id })
        truthy(after and after.done)
        eq(after.outcome, 'paid')
    end)
end)
