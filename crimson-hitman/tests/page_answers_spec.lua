--- What the server tells the phone page, found by walking the page as each
--- role. Each of these is a reply the page drew wrongly or could only
--- misread, and the fix is on the server's side of the wire.

local AT = { x = 200.0, y = 200.0, z = 30.0 }

--- Fire a net event the way a client does, rate limits and all, and return
--- the reply the page would receive.
local function call(name, src, payload)
    local handler = Env.events['crimson-hitman:' .. name]
    if not handler then return { ok = false, err = 'NO SUCH HANDLER' } end
    Env.clientEvents = {}
    _G.source = src
    local fired, err = pcall(handler, payload or {})
    _G.source = nil
    if not fired then return { ok = false, err = 'THREW: ' .. tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-hitman:result' then return event.args[1] end
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
    --- the one open slot, and was put to the next hitman to accept. The page
    --- now gives that answer; these pin what it relies on.
    --- Applied in the propose itself now: the page's own answer was a
    --- second request from the same rate-limit bucket, and two proposals a
    --- few seconds apart left one open that the card never drew.
    it('is applied in the one request, waiting on nobody', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, { reward = { slots = {
            { baseline = { cash = 1000 } }, { baseline = { cash = 2000 } } } },
            mode = CH.MODE.COMPETITIVE })
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
            { baseline = { cash = 3000 } } } }, mode = CH.MODE.COMPETITIVE })
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
        eq(s.projection.listing('HITMAN01').settings.amendments, true)
        Config.Amendments.Enabled = false
        eq(s.projection.listing('HITMAN01').settings.amendments, false,
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
        eq(err, CH.ERR.NOT_FOUND)
    end)

    it('answers not_found once the target has relogged', function()
        local s = newStack()
        local f = fixture(s)
        local handle = s.app.mintTargetHandle('CREATOR1', 'TARGET01')
        s.app.clearPlayerHandles('TARGET01')
        local ok, err = attempt(s, f, handle)
        falsy(ok)
        eq(err, CH.ERR.NOT_FOUND)
    end)

    it('still answers invalid_input when no target was sent at all', function()
        local s = newStack()
        local f = fixture(s)
        local ok, err = attempt(s, f, nil)
        falsy(ok)
        eq(err, CH.ERR.INVALID_INPUT)
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
            mode = CH.MODE.COMPETITIVE,
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
    --- A hitman's row stays active when a contract ends and only the
    --- creator's thread handles are dropped. So a hitman could go on writing
    --- to the client of a finished contract — each message a notification
    --- on their phone — while the client, who could no longer answer, was
    --- told "That is not yours" about the conversation.
    local function closed()
        local s = newStack()
        s.bridges.install(s)
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION, {}))
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        return s, f, c, handle
    end

    it('refuses the hitman a message, and rings nobody', function()
        local s, f, c = closed()
        Natives.calls.notifications = {}
        local ok, err = s.comms.send(f.hitman, c.id, nil, 'still here')
        falsy(ok, 'a finished contract was still a way to reach its client')
        eq(err, CH.ERR.ALREADY_SETTLED)
        for _, note in ipairs(Natives.calls.notifications) do
            falsy(note.title == 'Contract message', 'the client was notified anyway')
        end
    end)

    it('tells both parties the contract closed, not that it is not theirs', function()
        local s, f, c, handle = closed()
        local _, creatorErr = s.comms.read(f.creator, c.id, handle)
        eq(creatorErr, CH.ERR.ALREADY_SETTLED)
        local _, hitmanErr = s.comms.read(f.hitman, c.id, nil)
        eq(hitmanErr, CH.ERR.ALREADY_SETTLED)
    end)

    it('lists no threads for it', function()
        local s, f, c = closed()
        eq(#s.comms.threads(f.hitman, c.id), 0)
        eq(#s.comms.threads(f.creator, c.id), 0)
    end)

    it('leaves a live contract talking', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        truthy(s.comms.send(f.hitman, c.id, nil, 'on my way'))
        local handle = s.comms.threads(f.creator, c.id)[1].handle
        eq(#s.comms.read(f.creator, c.id, handle), 1)
    end)
end)

describe('asking about a handover while it is being paid', function()
    --- The countdown is dropped before the payout runs, and the outcome is
    --- written after it — on mysql every step between waits on the database.
    --- A poll landing there found neither and answered no_handover, which
    --- the page reads out as "The handover ended. Get them back to the
    --- client and try again." to a hitman who was being paid.
    it('answers settling rather than no_handover, then how it ended', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        for _, src in ipairs({ 1, 2, 3 }) do
            Env.players[src]._coords = { x = AT.x, y = AT.y, z = AT.z }
        end
        Env.players[2].PlayerData.metadata.ishandcuffed = true
        truthy(s.kidnap.arm(c.id, 'HITMAN01'))

        local during, duringErr
        local real = s.storage.claimEscrowLine
        s.storage.claimEscrowLine = function(...)
            if during == nil and duringErr == nil then
                during, duringErr = s.app.handlers.kidnapProgress(f.hitman, { id = c.id })
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

        local after = s.app.handlers.kidnapProgress(f.hitman, { id = c.id })
        truthy(after and after.done)
        eq(after.outcome, 'paid')
    end)
end)

describe('a refusal that says what was missing', function()
    --- "You do not have that." named neither the amount nor the account
    --- (§14.18: "naming the shortfall"), and a limit said "too many" with no
    --- number. The reply carries both now, and the page words them.
    local function staked(s, f, stake)
        local c = placed(s, f, { mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, penaltyAmount = stake })
        eq(c.penalty_amount, stake, 'the stake must survive the clamp')
        return c
    end

    it('names the stake, taken whole from one account', function()
        local s = newStack()
        local f = fixture(s)
        local c = staked(s, f, 2000)
        local money = Env.players[3].PlayerData.money
        money.bank, money.cash = 1500, 1500
        local reply = call('accept', 3, { id = c.id, anonymous = false, penaltyAmount = 2000 })
        falsy(reply.ok)
        eq(reply.err, CH.ERR.INSUFFICIENT)
        eq(reply.data and reply.data.part, 'stake')
        eq(reply.data.need, 2000)
        eq(reply.data.account, 'bank_or_cash')
    end)

    it('names the anonymity fee and its account when that is what is short', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.HitmanFee = 1000
        Config.Anonymity.FeeAccount = 'bank'
        local c = staked(s, f, 2000)
        local money = Env.players[3].PlayerData.money
        money.bank, money.cash = 500, 5000
        local reply = call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 2000 })
        eq(reply.err, CH.ERR.INSUFFICIENT)
        eq(reply.data and reply.data.part, 'fee')
        eq(reply.data.need, 1000)
        eq(reply.data.account, 'bank')
    end)

    it('says what fee a stake refusal would also have charged, and 0 where none is owed', function()
        -- The page added the fee setting to every anonymous stake refusal,
        -- and a hitman back on a contract they had already paid anonymity
        -- on was told to find $1,000 that would never have been taken.
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.HitmanFee = 1000
        Config.Anonymity.FeeAccount = 'bank'
        local c = staked(s, f, 2000)
        local money = Env.players[3].PlayerData.money
        money.bank, money.cash = 1500, 1500
        local first = call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 2000 })
        eq(first.data and first.data.part, 'stake')
        eq(first.data.fee, 1000)
        eq(first.data.feeAccount, 'bank')

        money.bank, money.cash = 3000, 0
        Env.advance(30)
        truthy(call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 2000 }).ok)
        truthy(s.contracts.abandon(f.hitman, c.id))

        money.bank, money.cash = 1500, 1500
        Env.advance(30)
        local again = call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 2000 })
        eq(again.err, CH.ERR.INSUFFICIENT)
        eq(again.data and again.data.part, 'stake')
        eq(again.data.fee, 0, 'anonymity here was paid for on the first stint')
        eq(again.data.feeAccount, nil)
    end)

    it('names the buyout price', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f, { bailoutAmount = 15000 })
        local price = s.storage.readContract(c.id).bailout_amount
        truthy(price > 1, 'a buyout to be short of')
        local money = Env.players[2].PlayerData.money
        money.bank, money.cash = price - 1, price - 1
        local reply = call('bailout', 2, { id = c.id })
        eq(reply.err, CH.ERR.INSUFFICIENT)
        eq(reply.data and reply.data.part, 'buyout')
        eq(reply.data.need, price)
        eq(reply.data.account, 'bank_or_cash')
        eq(money.bank + money.cash, 2 * (price - 1), 'and nothing was taken')
    end)

    it('says how many contracts a hitman may hold', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.MaxAcceptedPerHitman = 1
        Env.addPlayer({ source = 11, citizenid = 'TGT00001', license = 'license:t1' })
        local first = placed(s, f, { mode = CH.MODE.COMPETITIVE })
        local second = placed(s, f, { targetCid = 'TGT00001', mode = CH.MODE.COMPETITIVE })
        truthy(call('accept', 3, { id = first.id, anonymous = false, penaltyAmount = 0 }).ok)
        Env.advance(30)
        local reply = call('accept', 3, { id = second.id, anonymous = false, penaltyAmount = 0 })
        eq(reply.err, CH.ERR.LIMIT_REACHED)
        eq(reply.data and reply.data.max, 1)
    end)

    it('says how many contracts a client may have out', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.MaxActiveContractsPerCreator = 1
        Env.addPlayer({ source = 11, citizenid = 'TGT00001', license = 'license:t1' })
        placed(s, f)
        local none, err, refusal = s.contracts.create(f.creator, {
            targetCid = 'TGT00001', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(none)
        eq(err, CH.ERR.LIMIT_REACHED)
        eq(refusal and refusal.max, 1, 'the create handler passes this on as the reply data')
    end)
end)

--- S14: a request the database did not answer (mysql) was told
--- "Something broke on the server", or nothing at all, while a payment it
--- was recording could still go through.
describe('a request the database did not answer', function()
    it('is told so, and an SQL error is still a server error', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        s.storage.timedOut = require('crimson-hitman.server.storage.mysql').timedOut
        local real = s.storage.readContract
        s.storage.readContract = function()
            error('crimson-hitman: the database did not answer within 10 s (SELECT); it may still run', 0)
        end
        local reply = call('accept', 3, { id = c.id })
        eq(reply.err, CH.ERR.DB_TIMEOUT)
        s.storage.readContract = function()
            error('crimson-hitman was unable to execute a query!\nQuery: SELECT\n[]\nUnknown column', 0)
        end
        Env.advance(5)
        reply = call('accept', 3, { id = c.id })
        s.storage.readContract = real
        eq(reply.err, CH.ERR.SERVER_ERROR)
    end)
end)
