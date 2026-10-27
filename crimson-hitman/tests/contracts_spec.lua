--- Contract lifecycle: creation gates, acceptance, the state machine and the
--- conflict rules that keep creator, target and hitman three distinct people.

local function baseReward()
    return { baseline = { cash = 5000 }, bonus = { cash = 2500 } }
end

describe('contract creation', function()
    it('creates a contract and escrows the reward', function()
        local s = newStack()
        local f = fixture(s)
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = CH.MODE.EXCLUSIVE, reward = baseReward(),
        })
        truthy(contract, 'expected a contract, got ' .. tostring(err))
        eq(contract.state, CH.STATE.ACTIVE)
        eq(Env.players[1].PlayerData.money.cash, 92500, 'baseline and bonus both escrowed')
    end)

    it('refuses a contract on yourself', function()
        local s = newStack()
        local f = fixture(s)
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'CREATOR1', reason = 'x', reward = baseReward(),
        })
        falsy(contract)
        eq(err, CH.ERR.SELF_TARGET)
    end)

    it('refuses a contract on another character of the same account', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2].PlayerData.license = 'license:aaa' -- same account as creator
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract, 'alt-account targeting must be blocked')
        eq(err, CH.ERR.SAME_ACCOUNT)
    end)

    it('refuses a target who has barely played', function()
        local s = newStack()
        local f = fixture(s)
        -- Playtime comes from the framework's own metadata, in minutes.
        Env.players[2].PlayerData.metadata.playtime = 60
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract)
        eq(err, CH.ERR.TARGET_TOO_NEW)
    end)

    it('refuses a target who only just connected', function()
        local s = newStack()
        local f = fixture(s)
        -- A session the resource watched begin, as the connection bridge
        -- records it.
        s.identity.endSession('TARGET01')
        s.identity.beginSession('TARGET01', false)
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(contract, 'someone who walked in a moment ago is not fair game')
        eq(err, CH.ERR.TARGET_JUST_ON)

        Env.advance((Config.Immunity.MinTargetSessionMinutes * 60) + 60)
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        }), 'and fair game once they have settled in')
    end)

    it('does not refuse everyone when playtime cannot be resolved', function()
        local s = newStack()
        local f = fixture(s)
        -- No provider, no metadata: the rule is skipped, not applied to all.
        Env.players[2].PlayerData.metadata.playtime = nil
        local contract, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        truthy(contract, 'a missing playtime source must not stop the resource: ' .. tostring(err))
    end)

    --- Another script's playtime, for a framework whose metadata has none.
    --- The shape and unit config.lua documents: an export called with the
    --- citizen id that answers total minutes played. Nothing set a provider
    --- before these, so the path an owner is told to configure never ran.
    local PROVIDER = { resource = 'my_playtime', export = 'GetMinutes' }

    local function createWithProvider(s, f, answer)
        local contract, err
        -- Set on the proxy itself and taken off again whatever happens: the
        -- harness's exports outlive every stack.
        rawset(exports, 'my_playtime', { GetMinutes = answer })
        local ok, failure = pcall(withConfig, {
            { Config.Immunity, 'PlaytimeProvider', PROVIDER },
            { Natives.resourceStates, 'my_playtime', 'started' },
        }, function()
            contract, err = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
            })
        end)
        rawset(exports, 'my_playtime', nil)
        if not ok then error(failure, 0) end
        return contract, err
    end

    it('reads playtime from a configured provider, in minutes', function()
        local s = newStack()
        local f = fixture(s)
        local asked = {}
        -- Metadata says a hundred hours; the provider says one, and wins.
        local contract, err = createWithProvider(s, f, function(_, cid)
            asked[#asked + 1] = cid
            return 60
        end)
        falsy(contract, 'one hour played is under the floor')
        eq(err, CH.ERR.TARGET_TOO_NEW)
        eq(asked[1], 'TARGET01', 'asked about the target, by citizen id')
    end)

    it('falls back to metadata when the provider cannot answer', function()
        for _, answer in ipairs({
            function() error('playtime database is down') end,
            function() return 'sixty' end,
        }) do
            local s = newStack()
            local f = fixture(s)
            -- And metadata, at a hundred hours, says they have played enough.
            local contract, err = createWithProvider(s, f, answer)
            truthy(contract, 'a provider that fails is not a target too new: ' .. tostring(err))
        end
    end)

    it('rejects a reason containing a link or a phone number', function()
        local s = newStack()
        local f = fixture(s)
        for _, bad in ipairs({ 'join discord.gg/abcd', 'call me 5551234567', 'visit https://x.com' }) do
            local contract = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = bad, reward = baseReward(),
            })
            falsy(contract, 'accepted a bad reason: ' .. bad)
        end
    end)

    it('takes nothing when creation fails', function()
        local s = newStack()
        local f = fixture(s)
        s.contracts.create(f.creator, { targetCid = 'CREATOR1', reason = 'x', reward = baseReward() })
        eq(Env.players[1].PlayerData.money.cash, 100000, 'creator was never charged')
    end)

    it('clamps the bailout premium to a multiple of the escrow', function()
        local s = newStack()
        local f = fixture(s)
        local contract = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
            bailoutAmount = 10000000,
        })
        truthy(contract)
        -- money escrow is 7500; ceiling is 3x
        eq(contract.bailout_amount, 22500, 'premium clamped to 3x escrow')
    end)

    it('enforces the per-creator contract cap', function()
        local s = newStack()
        local f = fixture(s)
        for i = 1, Config.Limits.MaxActiveContractsPerCreator do
            Env.addPlayer({ source = 10 + i, citizenid = 'TGT0000' .. i, license = 'license:t' .. i })
            local c = s.contracts.create(f.creator, {
                targetCid = 'TGT0000' .. i, reason = 'x', reward = { baseline = { cash = 1000 } },
            })
            truthy(c, 'contract ' .. i .. ' should be created')
        end
        Env.addPlayer({ source = 30, citizenid = 'TGT00009', license = 'license:t9' })
        local extra, err = s.contracts.create(f.creator, {
            targetCid = 'TGT00009', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(extra, 'cap must hold')
        eq(err, CH.ERR.LIMIT_REACHED)
    end)
end)

describe('acceptance', function()
    local function seeded(mode)
        local s = newStack()
        local f = fixture(s)
        local contract = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'Unpaid debt',
            mode = mode or CH.MODE.EXCLUSIVE, reward = baseReward(),
        })
        return s, f, contract
    end

    it('records the hitman and moves the contract to accepted', function()
        local s, f, c = seeded()
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        truthy(ok, tostring(err))
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)

    it('refuses the creator accepting their own contract', function()
        local s, f, c = seeded()
        local ok, err = s.contracts.accept(f.creator, c.id, false)
        falsy(ok)
        eq(err, CH.ERR.SELF_ACCEPT)
    end)

    it('refuses the target accepting a contract on themselves', function()
        local s, f, c = seeded()
        local ok, err = s.contracts.accept(f.target, c.id, false)
        falsy(ok)
        eq(err, CH.ERR.SELF_TARGET)
    end)

    it('refuses a hitman on the creators account', function()
        local s, f, c = seeded()
        Env.players[3].PlayerData.license = 'license:aaa'
        local hitman = s.identity.resolve(3)
        local ok, err = s.contracts.accept(hitman, c.id, false)
        falsy(ok)
        eq(err, CH.ERR.SAME_ACCOUNT)
    end)

    it('refuses the target\'s other character once the target has logged off', function()
        -- One character per licence is online at once, so the target's alt
        -- only ever asks while the target is away. Looked up online, the
        -- target was never found and the alt took the contract on them.
        -- (The board lists no contract whose target is away, so it is the
        -- accept itself, sent by id, that has to refuse.)
        local s, f, c = seeded()
        Env.removePlayer(2)
        Env.addPlayer({ source = 12, citizenid = 'TGTALT01', license = 'license:bbb',
            firstname = 'Alt', lastname = 'Reyes' })
        local alt = s.identity.resolve(12)
        local ok, err = s.contracts.accept(alt, c.id, false)
        falsy(ok, 'the target\'s own alt took the contract on them')
        eq(err, CH.ERR.SAME_ACCOUNT)
    end)

    it('allows exactly one hitman on an exclusive contract', function()
        local s, f, c = seeded(CH.MODE.EXCLUSIVE)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
        local ok, err = s.contracts.accept(s.identity.resolve(4), c.id, false)
        falsy(ok, 'exclusive means one')
        -- The same fact as a full competitive contract, so the same code the
        -- page has words for; BAD_STATE was "Not right now."
        eq(err, CH.ERR.CONTRACT_FULL)
    end)

    it('allows several hitmen on a competitive contract', function()
        local s, f, c = seeded(CH.MODE.COMPETITIVE)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
        truthy(s.contracts.accept(s.identity.resolve(4), c.id, false))
        eq(#s.storage.readHitmen(c.id), 2)
    end)

    it('refuses the same hitman twice', function()
        local s, f, c = seeded(CH.MODE.COMPETITIVE)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local ok = s.contracts.accept(f.hitman, c.id, false)
        falsy(ok)
    end)
end)

describe('state machine', function()
    it('rejects any transition not declared', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        falsy(s.contracts.transition(c.id, CH.STATE.ACTIVE, CH.STATE.COMPLETED, 'illegal'),
            'active cannot jump straight to completed')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'state unchanged')
    end)

    it('never transitions out of a terminal state', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        falsy(s.contracts.transition(c.id, CH.STATE.CANCELLED, CH.STATE.ACTIVE, 'revive'))
    end)

    it('releases escrow exactly once across repeated resolutions', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = baseReward(),
        })
        eq(Env.players[1].PlayerData.money.cash, 92500)
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'refunded in full')
        local ok, err = s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled again')
        falsy(ok)
        eq(err, CH.ERR.ALREADY_SETTLED)
        eq(Env.players[1].PlayerData.money.cash, 100000, 'no second refund')
    end)
end)

describe('failure penalty', function()
    local function withPenalty(amount)
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
            penaltyAmount = amount,
        })
        return s, f, c
    end

    it('stakes the penalty from the hitman at acceptance', function()
        local s, f, c = withPenalty(10000)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        eq(Env.players[3].PlayerData.money.bank, 40000, 'staked up front, not merely promised')
    end)

    it('refuses acceptance from a hitman who cannot cover the stake', function()
        local s, f, c = withPenalty(10000)
        Env.players[3].PlayerData.money.bank = 100
        Env.players[3].PlayerData.money.cash = 100
        local ok, err = s.contracts.accept(f.hitman, c.id, false)
        falsy(ok)
        eq(err, CH.ERR.INSUFFICIENT)
        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'and the contract stays open')
    end)

    it('forfeits the stake to the creator when the hitman walks away', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hitman, c.id, false)
        local creatorBefore = Env.players[1].PlayerData.money.bank

        truthy(s.contracts.abandon(f.hitman, c.id))
        eq(Env.players[1].PlayerData.money.bank, creatorBefore + 10000, 'creator keeps the penalty')
        eq(Env.players[3].PlayerData.money.bank, 40000, 'hitman does not get it back')
    end)

    --- "Their stake is yours" only once it is: paid to the client, or owed
    --- to one who is away. A release that moved nothing (another release
    --- held the line) gave them nothing, and said it had.
    it('tells the client of a stake only when it reached them', function()
        local s, f, c = withPenalty(10000)
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local claim = s.storage.claimEscrowLine
        s.storage.claimEscrowLine = function() return false end
        Natives.calls.notifications = {}
        local ok, err = s.contracts.abandon(f.hitman, c.id)
        s.storage.claimEscrowLine = claim
        truthy(ok, tostring(err))

        local said = ''
        for _, note in ipairs(Natives.calls.notifications or {}) do
            if note.title == 'Operative walked away' then said = said .. tostring(note.content) end
        end
        truthy(said:find('An operative left your contract', 1, true), 'the client is told: ' .. said)
        falsy(said:find('stake is yours', 1, true), 'of a stake that never reached them: ' .. said)
        s.audit.flush()
        for _, row in ipairs(s.storage.readAudit()) do
            truthy(row.action ~= 'stake_forfeited', 'a forfeit recorded that moved nothing')
        end
    end)

    it('returns the stake when the hitman delivers', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(Env.players[3].PlayerData.money.bank, 50000, 'stake returned in full')
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and the reward paid')
    end)

    it('forfeits the stake when the contract expires under them', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hitman, c.id, false)
        local creatorBefore = Env.players[1].PlayerData.money.bank

        s.contracts.resolve(c.id, CH.STATE.EXPIRED, 'CREATOR1', nil, 'expired')
        eq(Env.players[1].PlayerData.money.bank, creatorBefore + 10000, 'the penalty is the point')
    end)

    it('returns the stake when the creator cancels instead', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        eq(Env.players[3].PlayerData.money.bank, 50000, 'not the hitman\'s fault, not their loss')
    end)

    it('never counts a stake as part of the contract reward', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hitman, c.id, false)
        eq(s.escrow.moneyValue(c.id), 5000, 'the board shows the reward, not the hitman\'s stake')
        local row = s.projection.contract(s.storage.readContract(c.id), 'HITMAN01')
        eq(row.reward.baseline, 5000)
    end)

    it('does not sweep a stake into a general refund', function()
        local s, f, c = withPenalty(10000)
        s.contracts.accept(f.hitman, c.id, false)
        local creatorBefore = Env.players[1].PlayerData.money.cash

        s.contracts.resolve(c.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')
        eq(Env.players[1].PlayerData.money.cash, creatorBefore + 5000,
            'the creator gets their escrow back and nothing of the stake')
        eq(Env.players[3].PlayerData.money.bank, 50000)
    end)
end)

describe('one request at a time on a key', function()
    --- A key held for seconds is a request waiting on a slow database, and
    --- the page words that apart from a moment's clash (failText).
    it('answers busy with how long the key has been held', function()
        local s = newStack()
        local long, short
        truthy(s.contracts.serialized({ 'contract:ctheld01' }, function()
            Env.gameTimer = Env.gameTimer + 2000
            short = table.pack(s.contracts.serialized({ 'contract:ctheld01' }, function()
                return true
            end))
            Env.gameTimer = Env.gameTimer + 10000
            long = table.pack(s.contracts.serialized({ 'settle:ctheld01', 'contract:ctheld01' },
                function() return true end))
            return true
        end))
        eq(short[1], false)
        eq(short[2], CH.ERR.BUSY)
        eq(type(short[3]), 'table', 'the refusal says how long')
        truthy(short[3].heldMs >= 2000 and short[3].heldMs < 10000, tostring(short[3].heldMs))
        eq(long[2], CH.ERR.BUSY)
        truthy(long[3].heldMs >= 10000, 'held 12 s: ' .. tostring(long[3].heldMs))
        truthy(s.contracts.serialized({ 'settle:ctheld01' }, function() return true end),
            'and a key the refusal named but never took is free')
    end)
end)

describe('spam and rollback', function()
    it('throttles create-and-cancel list spam', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(first)
        s.contracts.resolve(first.id, CH.STATE.CANCELLED, 'CREATOR1', nil, 'cancelled')

        -- A different target, so the cancel throttle is what is being
        -- measured rather than the per-target cooldown.
        Env.addPlayer({ source = 8, citizenid = 'TARGET02', license = 'license:t2' })
        local second, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET02', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        falsy(second, 'cancelling should not be a free way back onto the board')
        eq(err, CH.ERR.CANCELLED_TOO_SOON,
            'its own code, not the token bucket\'s. This is a policy wait of '
            .. 'minutes and the page words rate_limited as "Slow down." — and '
            .. 'reads it as a transient condition worth retrying, which this '
            .. 'is not')

        Env.advance(Config.Amendments.CancelCooldownSeconds + 10)
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET02', reason = 'x', reward = { baseline = { cash = 1000 } },
        }), 'allowed once the cooldown passes')
    end)

    it('leaves no contract behind when escrow cannot be taken', function()
        local s = newStack()
        local f = fixture(s)
        local before = #s.storage.allContracts()

        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000, items = { { name = 'lockpick', count = 99 } } } },
        })
        falsy(c)
        eq(err, CH.ERR.INSUFFICIENT)
        eq(#s.storage.allContracts(), before, 'no shell row was written')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'and nothing was charged')
    end)
end)

describe('stakes survive every ending', function()
    local function competitiveWithStakes()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd', bank = 50000 })
        local second = s.identity.resolve(4)

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
        })
        s.contracts.accept(f.hitman, c.id, false)
        s.contracts.accept(second, c.id, false)
        return s, f, c, second
    end

    it('returns the losing hitmen stake when the contract completes', function()
        local s, f, c, second = competitiveWithStakes()
        eq(Env.players[4].PlayerData.money.bank, 40000, 'hitman two staked')

        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)

        eq(Env.players[3].PlayerData.money.bank, 50000, 'the winner gets their stake back')
        eq(Env.players[4].PlayerData.money.bank, 50000,
            'and so does the hitman who simply lost the race')
    end)

    it('leaves nothing held on a completed contract', function()
        local s, f, c = competitiveWithStakes()
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            eq(line.state, CH.ESCROW_STATE.SETTLED,
                ('line %s (%s) stranded on a completed contract'):format(line.id, line.portion))
        end
    end)

    it('refuses an abandon on a contract that has already finished', function()
        local s, f, c, second = competitiveWithStakes()
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        local before = Env.players[1].PlayerData.money.bank

        local ok, err = s.contracts.abandon(second, c.id)
        falsy(ok, 'nothing to abandon once it is over')
        eq(err, CH.ERR.BAD_STATE)
        eq(Env.players[1].PlayerData.money.bank, before,
            'and the creator cannot be handed a stake that was already returned')
    end)

    it('conserves value across a completion with several stakes', function()
        local s, f, c, second = competitiveWithStakes()
        local function total()
            local money = 0
            for _, p in pairs(Env.players) do
                money = money + p.PlayerData.money.cash + p.PlayerData.money.bank
            end
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.state ~= CH.ESCROW_STATE.SETTLED and CH.MONEY_SOURCES[line.source] then
                    money = money + (line.amount or 0)
                end
            end
            return money
        end

        local opening = total()
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        eq(total(), opening, 'completion must neither create nor destroy value')
    end)
end)

describe('a stake stays at risk until the contract ends', function()
    local function multiSlotWithPenalty()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                -- Funded well enough to carry the stake below: §14.18 clamps
                -- the stake to a multiple of the money escrow, so a $2,000
                -- contract cannot ask a hitman for $10,000.
                { baseline = { cash = 5000 } },
                { baseline = { cash = 5000 } },
            } },
            penaltyAmount = 10000,
        })
        s.contracts.accept(f.hitman, c.id, false)
        return s, f, c
    end

    it('does not hand the stake back after the first of several payouts', function()
        local s, f, c = multiSlotWithPenalty()
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)

        eq(Env.players[3].PlayerData.money.bank, 40000,
            'the hitman is still on the hook for the remaining payout')
        eq(s.storage.readContract(c.id).state, CH.STATE.ACCEPTED)
    end)

    it('still forfeits the stake if they walk away after collecting once', function()
        local s, f, c = multiSlotWithPenalty()
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        local creatorBefore = Env.players[1].PlayerData.money.bank

        s.contracts.abandon(f.hitman, c.id)
        eq(Env.players[1].PlayerData.money.bank, creatorBefore + 10000,
            'collect-then-abandon must not be free')
        eq(Env.players[3].PlayerData.money.bank, 40000)
    end)

    it('returns the stake once the last payout is collected', function()
        local s, f, c = multiSlotWithPenalty()
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        Env.advance(Config.Limits.SlotCooldownSeconds + 1)
        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)

        eq(s.storage.readContract(c.id).state, CH.STATE.COMPLETED)
        eq(Env.players[3].PlayerData.money.bank, 50000, 'stake returned when the job is done')
        eq(Env.players[3].PlayerData.money.cash, 15000, 'plus both payouts')
    end)
end)

describe('money already promised to someone is not swept away', function()
    it('does not refund a forfeited stake to the hitman who forfeited it', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 2500 } }, penaltyAmount = 5000,
        })
        s.contracts.accept(f.hitman, c.id, false)

        -- The creator is offline, so the forfeited stake is owed to them
        -- rather than paid immediately.
        Env.removePlayer(1)
        s.contracts.abandon(f.hitman, c.id)
        eq(Env.players[3].PlayerData.money.bank, 45000, 'the hitman forfeited it')

        -- The creator returns and lowers the penalty for whoever comes next.
        Env.addPlayer({ source = 1, citizenid = 'CREATOR1', license = 'license:aaa',
            cash = 0, bank = 0 })
        s.amendments.improve(s.identity.resolve(1), c.id, CH.AMENDMENT.LOWER_PENALTY,
            { amount = 1 })

        eq(Env.players[3].PlayerData.money.bank, 45000,
            'an ordinary penalty reduction must not refund a stake already forfeited')
    end)

    it('keeps a bailout premium owed to an offline creator out of general refunds', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 5000,
        })

        Env.removePlayer(1)
        truthy(s.bailout.buy(f.target, c.id))

        local owed = s.storage.readPending('CREATOR1')
        truthy(#owed > 0, 'the premium is owed to the creator')

        -- Any later general release must not carry it off to someone else.
        s.escrow.release(c.id, 'HITMAN01', nil, 'a general sweep')

        local stillOwed = s.storage.readPending('CREATOR1')
        eq(#stillOwed, #owed, 'the premium is still the creator\'s')
        eq(Env.players[3].PlayerData.money.bank, 5000, 'and nobody else was paid it')
    end)
end)

describe('anonymity fees', function()
    -- Set after the stack is built, not before: newStack restores the
    -- configuration as it ships, so an override applied first is wiped.
    local function withFees(creatorFee, hitmanFee)
        local s = newStack()
        Config.Anonymity.CreatorFee = creatorFee
        Config.Anonymity.HitmanFee = hitmanFee
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        return s, f
    end

    it('charges nothing by default', function()
        local s = newStack()
        local f = fixture(s)
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, anonymous = true,
        })
        eq(Env.players[1].PlayerData.money.bank, 100000, 'anonymity is free unless configured')
    end)

    it('charges the creator when a fee is configured', function()
        local s, f = withFees(5000, 0)
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, anonymous = true,
        })
        eq(Env.players[1].PlayerData.money.bank, 95000)
    end)

    it('does not charge a creator who chose to be seen', function()
        local s, f = withFees(5000, 0)
        s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000 } }, anonymous = false,
        })
        eq(Env.players[1].PlayerData.money.bank, 100000)
    end)

    it('refunds the fee when the contract cannot be created', function()
        local s, f = withFees(5000, 0)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { items = { { name = 'nonexistent', count = 5 } } } },
            anonymous = true,
        })
        falsy(c)
        eq(Env.players[1].PlayerData.money.bank, 100000, 'no half-charged creators')
    end)

    it('charges a hitman who accepts anonymously', function()
        local s, f = withFees(0, 2500)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        s.contracts.accept(f.hitman, c.id, true)
        eq(Env.players[3].PlayerData.money.bank, 47500)
    end)

    it('refuses an anonymous acceptance they cannot afford, rather than naming them', function()
        local s, f = withFees(0, 2500)
        Env.players[3].PlayerData.money.bank = 100
        Env.players[3].PlayerData.money.cash = 100
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })

        local ok, err = s.contracts.accept(f.hitman, c.id, true)

        -- They used to be accepted under their own name. The page only sees
        -- that the acceptance went through, so it told them "accepted,
        -- anonymously" while the creator was told who they were — and a
        -- name, once handed over, cannot be taken back.
        falsy(ok, 'asked to be anonymous and could not pay for it')
        eq(err, CH.ERR.INSUFFICIENT)
        falsy(s.storage.readHitman(c.id, 'HITMAN01'), 'no acceptance was recorded')
        eq(Env.players[3].PlayerData.money.bank, 100, 'charged nothing')

        -- Under their own name is still there for the asking.
        truthy(s.contracts.accept(f.hitman, c.id, false))
    end)

    it('never charges a hitman for an acceptance that fails', function()
        local s, f = withFees(0, 2500)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 50000 } }, penaltyAmount = 99999,
        })
        local ok, err = s.contracts.accept(f.hitman, c.id, true)

        falsy(ok, 'the stake is unaffordable')
        eq(err, CH.ERR.INSUFFICIENT)
        eq(Env.players[3].PlayerData.money.bank, 50000,
            'and no anonymity fee was taken for it')
    end)
end)

describe('post-respawn immunity', function()
    it('protects a target who has just got back up', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 1000 } }, { baseline = { cash = 1000 } },
            } },
        })
        s.contracts.accept(f.hitman, c.id, false)

        -- A second hitman, so the per-hitman slot cooldown is not what is
        -- being measured here.
        Env.addPlayer({ source = 4, citizenid = 'HITMAN02', license = 'license:ddd' })
        local second = s.identity.resolve(4)
        s.contracts.accept(second, c.id, false)

        s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)

        -- The target goes down, respawns, and the next hitman tries again
        -- straight away.
        s.death.onRevived('TARGET01')

        local ok, err = s.contracts.claimSlot(c.id, 'HITMAN02', CH.FULFILMENT.ELIMINATION)
        falsy(ok, 'a multi-slot contract must not become respawn camping')
        eq(err, CH.ERR.TARGET_JUST_UP)

        Env.advance(Config.Immunity.PostRespawnSeconds + 10)
        truthy(s.contracts.claimSlot(c.id, 'HITMAN02', CH.FULFILMENT.ELIMINATION),
            'and claimable again once they have had a moment on their feet')
    end)

    it('starts no wait for everyone when a contract nobody took up is withdrawn', function()
        -- A friend's $1 contract, withdrawn at once and refunded, shut every
        -- other creator out of the target for half an hour, as often as the
        -- friend liked.
        local s = newStack()
        local f = fixture(s)
        Env.addPlayer({ source = 5, citizenid = 'FRIEND02', license = 'license:eee',
            cash = 100 })
        local friend = s.identity.resolve(5)
        local shield = s.contracts.create(friend, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1 } },
        })
        truthy(shield)
        truthy(s.contracts.cancel(friend, shield.id))

        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        }), 'a withdrawal shielded the target from everybody')
        falsy(s.contracts.create(friend, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1 } },
        }), 'the one who withdrew still waits')
    end)

    it('gives a target who bought their way out a longer breather', function()
        local s = newStack()
        local f = fixture(s)
        Env.players[2].PlayerData.money.bank = 100000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(s.bailout.buy(f.target, c.id))
        eq(s.storage.readContract(c.id).state, CH.STATE.BAILED_OUT)

        Env.advance(Config.Limits.TargetCooldownAfterResolveSeconds + 10)
        local again, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 5000 } },
        })
        falsy(again, 'paying to be left alone should buy more than the usual cooldown')
        eq(err, CH.ERR.TARGET_RECENTLY_ON)
    end)
end)

describe('session tracking survives a restart', function()
    it('does not treat everyone as new when the resource starts mid-session', function()
        local s = newStack()
        local f = fixture(s)

        -- Identity.resolve has already noted the target, but only as
        -- observed: the resource did not watch them arrive.
        falsy(s.identity.sessionMinutes('TARGET01'),
            'an observed session length is unknown, not zero')

        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1000 } },
        })
        truthy(c, 'a restart must not make the whole server untargetable: ' .. tostring(err))
    end)

    it('measures a session it did watch begin', function()
        local s = newStack()
        fixture(s)
        s.identity.endSession('TARGET01')
        s.identity.beginSession('TARGET01', false)
        eq(s.identity.sessionMinutes('TARGET01'), 0)

        Env.advance(900)
        eq(s.identity.sessionMinutes('TARGET01'), 15)
    end)
end)


--- One place that knows a contract is over. A path that flipped a contract to
--- a terminal state without settling stranded a hitman's stake once already;
--- ending one now requires a capability only resolve and claimSlot hold.
describe('terminal transitions', function()
    it('refuses to end a contract from outside the settling paths', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })

        for _, terminal in ipairs({
            CH.STATE.COMPLETED, CH.STATE.BAILED_OUT,
            CH.STATE.EXPIRED, CH.STATE.CANCELLED,
        }) do
            falsy(s.contracts.transition(c.id, CH.STATE.ACTIVE, terminal, 'sneaky'),
                'a caller without the token must not reach ' .. terminal)
            -- Passing something that looks like the token does not help.
            falsy(s.contracts.transition(c.id, CH.STATE.ACTIVE, terminal, 'sneaky', true))
            falsy(s.contracts.transition(c.id, CH.STATE.ACTIVE, terminal, 'sneaky', {}))
        end

        eq(s.storage.readContract(c.id).state, CH.STATE.ACTIVE, 'still live')
    end)

    it('still allows the live transitions every path needs', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })

        truthy(s.contracts.transition(c.id, CH.STATE.ACTIVE, CH.STATE.ACCEPTED, 'accepted'))
        truthy(s.contracts.transition(c.id, CH.STATE.ACCEPTED, CH.STATE.ACTIVE, 'abandoned'))
    end)

    it('settles through the paths that do hold it', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } },
        })

        truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))
        eq(s.storage.readContract(c.id).state, CH.STATE.CANCELLED)
    end)

    it('leaves nothing held whichever path ends the contract', function()
        for _, ending in ipairs({ 'cancel', 'expire', 'complete' }) do
            local s = newStack()
            local f = fixture(s)
            local c = s.contracts.create(f.creator, {
                targetCid = 'TARGET01', reason = 'x',
                reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
                penaltyAmount = 10000,
            })

            if ending == 'complete' then
                Env.players[3].PlayerData.money.bank = 50000
                truthy(s.contracts.accept(f.hitman, c.id, false))
                truthy(s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION))
            elseif ending == 'expire' then
                Env.players[3].PlayerData.money.bank = 50000
                truthy(s.contracts.accept(f.hitman, c.id, false))
                truthy(s.contracts.resolve(c.id, CH.STATE.EXPIRED, f.creator.cid, nil, 'expired'))
            else
                truthy(s.contracts.resolve(c.id, CH.STATE.CANCELLED, f.creator.cid, nil, 'cancelled'))
            end

            -- Both terminal paths run the same finalise, so neither can
            -- leave escrow sitting on a contract nobody can act on.
            local held = 0
            for _, line in ipairs(s.storage.readEscrow(c.id)) do
                if line.state ~= CH.ESCROW_STATE.SETTLED then held = held + 1 end
            end
            eq(held, 0, 'escrow left held after ' .. ending)
        end
    end)
end)


--- An id that is already in use is not a free id.
---
--- The MySQL backend writes contracts and escrow with ON DUPLICATE KEY
--- UPDATE, so a repeated id does not fail — it overwrites. The id carries a
--- per-process counter and the clock modulo 100000, which repeats every
--- 27.7 hours and restarts at one on every boot, so two instances sharing a
--- database, or one restarting at the wrong moment, can mint the same id
--- twice. Escrow.take already reads back and confirms its own lines for
--- exactly this reason; nothing else did.
describe('minting an id that is already taken', function()
    it('does not overwrite an existing contract', function()
        local s = newStack()
        local f = fixture(s)

        local first = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'The original', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(first)

        -- The next id comes back the same, as a collision would produce.
        -- Contract ids are random (Util.randomId); this one comes back taken.
        local Util = CrimsonBoot.requireShared('util')
        local real = Util.randomId
        Util.randomId = function(prefix)
            if prefix == 'ct' then return first.id end
            return real(prefix)
        end

        Env.addPlayer({ source = 7, citizenid = 'CREATOR9', license = 'license:zzz',
                        cash = 100000, bank = 100000, firstname = 'Ann', lastname = 'Poe' })
        local second, err = s.contracts.create(s.identity.resolve(7), {
            targetCid = 'TARGET01', reason = 'The impostor', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        Util.randomId = real

        falsy(second, 'a contract must not be created onto an id already in use')
        truthy(err)

        local stored = s.storage.readContract(first.id)
        eq(stored.reason, 'The original', 'and the original is untouched')
        eq(stored.creator_cid, 'CREATOR1')
    end)

    it('does not charge the second creator for a contract it refused', function()
        local s = newStack()
        local f = fixture(s)
        local first = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        truthy(first)

        -- Contract ids are random (Util.randomId); this one comes back taken.
        local Util = CrimsonBoot.requireShared('util')
        local real = Util.randomId
        Util.randomId = function(prefix)
            if prefix == 'ct' then return first.id end
            return real(prefix)
        end

        Env.addPlayer({ source = 7, citizenid = 'CREATOR9', license = 'license:zzz',
                        cash = 100000, bank = 100000, firstname = 'Ann', lastname = 'Poe' })
        local before = Env.players[7].PlayerData.money.cash
        s.contracts.create(s.identity.resolve(7), {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } },
        })
        Util.randomId = real

        eq(Env.players[7].PlayerData.money.cash, before,
            'nothing was taken, because nothing was created')
    end)

    it('does not write an owed payout over an existing escrow line', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, bailoutAmount = 10000,
        })
        truthy(c)

        local existing = s.storage.readEscrow(c.id)[1]
        truthy(existing, 'a line to be overwritten')

        local real = s.storage.nextId
        s.storage.nextId = function(prefix)
            if prefix == 'owe' then return existing.id end
            return real(prefix)
        end
        local lineId = s.bailout.owe('CREATOR1', c.id, 7500, 'bank', 'test')
        s.storage.nextId = real

        local after = s.storage.readEscrowLine(existing.id)
        eq(after.amount, existing.amount,
            'the baseline line must not have been overwritten by an owed payout')
        eq(after.portion, existing.portion)
        falsy(lineId == existing.id and after.owed_to == 'CREATOR1',
            'and the owed money must not have landed on top of it')
    end)
end)


describe('minting a hitman id that is already taken', function()
    local function seeded()
        local s = newStack()
        local f = fixture(s)
        Env.players[3].PlayerData.money.bank = 50000
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { baseline = { cash = 5000 } }, penaltyAmount = 10000,
        })
        return s, f, c
    end

    it('lets a second hitman in when the id is free', function()
        -- The control: without this the refusals below could be the
        -- contract refusing a second hitman at all, which is what the
        -- first draft of these tests was actually measuring.
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        Env.addPlayer({ source = 8, citizenid = 'HITMAN08', license = 'license:h8',
                        cash = 50000, bank = 50000, firstname = 'Kit', lastname = 'Vale' })
        local ok, err = s.contracts.accept(s.identity.resolve(8), c.id, false)
        truthy(ok, 'a competitive contract takes more than one hitman: ' .. tostring(err))
        eq(#s.storage.readHitmen(c.id), 2)
    end)

    it('refuses the acceptance rather than throwing on a duplicate row', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local existing = s.storage.readHitmen(c.id)[1]
        truthy(existing)

        Env.addPlayer({ source = 8, citizenid = 'HITMAN08', license = 'license:h8',
                        cash = 50000, bank = 50000, firstname = 'Kit', lastname = 'Vale' })
        local real = s.storage.nextId
        s.storage.nextId = function(prefix)
            if prefix == 'hn' then return existing.id end
            return real(prefix)
        end
        local ok, err = s.contracts.accept(s.identity.resolve(8), c.id, false)
        s.storage.nextId = real

        falsy(ok, 'an acceptance must not be written onto another hitman row')
        truthy(err)
        eq(#s.storage.readHitmen(c.id), 1, 'and the first hitman still stands alone')
        eq(s.storage.readHitmanById(existing.id).hitman_cid, 'HITMAN01')
    end)

    it('gives the stake back when it refuses', function()
        local s, f, c = seeded()
        truthy(s.contracts.accept(f.hitman, c.id, false))
        local existing = s.storage.readHitmen(c.id)[1]

        Env.addPlayer({ source = 8, citizenid = 'HITMAN08', license = 'license:h8',
                        cash = 50000, bank = 50000, firstname = 'Kit', lastname = 'Vale' })
        local before = Env.players[8].PlayerData.money.bank
            + Env.players[8].PlayerData.money.cash

        local real = s.storage.nextId
        s.storage.nextId = function(prefix)
            if prefix == 'hn' then return existing.id end
            return real(prefix)
        end
        falsy(s.contracts.accept(s.identity.resolve(8), c.id, false))
        s.storage.nextId = real

        eq(Env.players[8].PlayerData.money.bank + Env.players[8].PlayerData.money.cash,
            before,
            'the stake is taken before the row is written, so a refusal must return it — '
            .. 'nothing else ever would, with no hitman row naming who staked it')
    end)
end)

describe('a reason over the length limit', function()
    --- Cut to the limit and placed, so the creator paid for a contract that
    --- said something other than what they wrote (§14.30: refused, not
    --- altered).
    it('is refused rather than cut', function()
        local s = newStack()
        local f = fixture(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = string.rep('a', Config.Reason.MaxLength + 1),
            reward = { baseline = { cash = 1000 } },
        })
        falsy(c, 'placed with its reason cut short')
        -- Said as the reason, too long (W010).
        eq(err, CH.ERR.REASON_REFUSED)
    end)

    it('is taken at exactly the limit, counted in characters', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = string.rep('\208\150', Config.Reason.MaxLength),
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c)
        eq(utf8.len(s.storage.readContract(c.id).reason), Config.Reason.MaxLength)
    end)
end)

--- S26: in mysql mode the reason is kept in VARCHAR(255) columns, and a
--- Reason.MaxLength above that let the reason rules take a reason the store
--- then refused: the contract was taken, rolled back and answered bad_state.
describe('a reason past what mysql mode\'s column holds', function()
    local function onMysql()
        local s = newStack()
        local Exec = require('crimson-hitman.tests.harness.mysql_exec')
        Exec.install(Natives)
        package.loaded['crimson-hitman.server.storage.mysql'] = nil
        local store = require('crimson-hitman.server.storage.mysql')
        store.open()
        s.audit.init(store)
        s.review.init({ storage = store, escrow = s.escrow, audit = s.audit })
        s.escrow.init(store, s.audit, s.review)
        s.contracts.init({ storage = store, escrow = s.escrow, identity = s.identity,
                           audit = s.audit, notify = s.notify, progression = s.progression,
                           death = s.death, review = s.review })
        s.storage = store
        return s
    end

    it('is refused by the reason rules, not by the store, on the strict executor', function()
        local s = onMysql()
        local f = fixture(s)
        Config.Database.Mode = 'mysql'
        Config.Reason.MaxLength = 300
        require('crimson-hitman.server.main').validateConfig(true)
        eq(Config.Reason.MaxLength, 255, 'held to the column')

        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = string.rep('\208\150', 300),
            reward = { baseline = { cash = 1000 } },
        })
        falsy(c)
        eq(err, CH.ERR.REASON_REFUSED, 'the reason rules\' answer, not the store\'s bad_state')
        eq(Env.players[1].PlayerData.money.cash, 100000, 'nothing was taken')

        c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = string.rep('\208\150', 255),
            reward = { baseline = { cash = 1000 } },
        })
        truthy(c, 'and 255 characters are stored: ' .. tostring(err))
        eq(utf8.len(s.storage.readContract(c.id).reason), 255)
    end)
end)

--- Config.Limits.MinContractReward: the least a contract's reward may be
--- worth in money. Two one-dollar contracts filled a target's
--- MaxActiveContractsPerTarget, and nobody else could list them until both
--- closed. The harness runs with none; these set the shipped figure.
describe('the least a contract may be worth', function()
    local SHIPPED = ConfigDefaults.Limits.MinContractReward

    --- Fire a net event the way a client does, and return the reply.
    local function call(name, src, payload)
        local fire = Env.events['crimson-hitman:' .. name]
        Env.clientEvents = {}
        _G.source = src
        fire(payload or {})
        _G.source = nil
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then return event.args[1] end
        end
        return nil
    end

    local function withMinimum(s)
        Config.Limits.MinContractReward = SHIPPED
        return fixture(s)
    end

    it('ships at 1000', function()
        eq(SHIPPED, 1000)
    end)

    it('refuses a reward worth less, takes nothing, and says the minimum', function()
        local s = newStack()
        local f = withMinimum(s)
        local cash, bank = Env.players[1].PlayerData.money.cash, Env.players[1].PlayerData.money.bank
        local c, err, refusal = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 999 } },
        })
        falsy(c, 'placed under the minimum')
        eq(err, CH.ERR.REWARD_TOO_SMALL)
        eq(refusal and refusal.min, 1000, 'the figure goes with the refusal')
        eq(Env.players[1].PlayerData.money.cash, cash, 'nothing was taken')
        eq(Env.players[1].PlayerData.money.bank, bank)
        eq(#s.storage.allContracts(), 0, 'and nothing is on the board')
    end)

    it('counts cash, bank and dirty money across every payout', function()
        local s = newStack()
        local f = withMinimum(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = {
                { baseline = { cash = 400 } },
                { baseline = { bank = 300, dirty = 300 } },
            } },
        })
        truthy(c, 'exactly the minimum, split three ways over two payouts: ' .. tostring(err))
    end)

    it('does not count items or weapons', function()
        local s = newStack()
        local f = withMinimum(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 500,
                items = { { name = 'lockpick', count = 5 } },
                weapons = { { name = 'WEAPON_PISTOL', slot = 3 } } } },
        })
        falsy(c, 'goods cannot be priced, so they cannot make up the difference')
        eq(err, CH.ERR.REWARD_TOO_SMALL)
    end)

    it('counts a kidnapping bonus, which is escrowed with the rest', function()
        local s = newStack()
        local f = withMinimum(s)
        local c, err = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', bonusPercent = 100,
            reward = { baseline = { cash = 500 } },
        })
        truthy(c, 'five hundred and its hundred percent: ' .. tostring(err))
    end)

    it('is off at 0', function()
        local s = newStack()
        local f = fixture(s)
        Config.Limits.MinContractReward = 0
        truthy(s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', reward = { baseline = { cash = 1 } },
        }))
    end)

    it('tells the page the code and the figure', function()
        local s = newStack()
        withMinimum(s)
        local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = 'Reyes' })
        local target = found and found[1] and found[1].handle
        truthy(target, 'a handle for the target')
        local reply = call('create', 1, { target = target, reason = 'x',
            reward = { slots = { { baseline = { cash = 10 } } } } })
        eq(reply and reply.err, 'reward_too_small')
        eq(reply.data and reply.data.min, 1000)
    end)

    it('says the minimum on the Place form before anything is typed', function()
        local s = newStack()
        local f = withMinimum(s)
        local wallet = s.app.handlers.rewardOptions(f.creator, {})
        eq(wallet.caps.minValue, 1000)
        Config.Limits.MinContractReward = 0
        eq(s.app.handlers.rewardOptions(f.creator, {}).caps.minValue, 0, 'and none when off')
    end)

    --- Placed at the minimum and emptied straight back down, it was the
    --- contract the minimum is there to stop.
    it('cannot be withdrawn below it', function()
        local s = newStack()
        local f = withMinimum(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 1000, bank = 500,
                items = { { name = 'lockpick', count = 5 } } } },
        })
        truthy(c)
        local cash, bank, item
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if line.source == 'cash' then cash = line.id end
            if line.source == 'bank' then bank = line.id end
            if line.source == 'item' then item = line.id end
        end

        local ok, err, refusal = s.contracts.withdrawReward(f.creator, c.id, { cash })
        falsy(ok, 'left at 500')
        eq(err, CH.ERR.REWARD_TOO_SMALL)
        eq(refusal and refusal.min, 1000)

        local reply = call('withdrawReward', 1, { id = c.id, lines = { cash } })
        eq(reply and reply.err, 'reward_too_small')
        eq(reply.data and reply.data.min, 1000, 'the page is told the figure here too')

        truthy(s.contracts.withdrawReward(f.creator, c.id, { bank }), 'left at exactly 1000')
        Env.advance(60)
        truthy(s.contracts.withdrawReward(f.creator, c.id, { item }),
            'goods never counted towards it, so they can always come back')
        eq(s.escrow.moneyValue(c.id), 1000)
    end)

    it('cannot be given back a payout at a time below it', function()
        local s = newStack()
        local f = withMinimum(s)
        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CH.MODE.COMPETITIVE,
            reward = { slots = { { baseline = { cash = 600 } }, { baseline = { cash = 600 } } } },
        })
        truthy(c)
        local proposal, err, refusal = s.amendments.propose(f.creator, c.id,
            CH.AMENDMENT.REDUCE_REWARD, { slot = 2 })
        falsy(proposal, 'one payout of 600 would be left')
        eq(err, CH.ERR.REWARD_TOO_SMALL)
        eq(refusal and refusal.min, 1000)
        eq(s.storage.readContract(c.id).payout_slots, 2, 'nothing given back')

        Env.advance(60)
        local reply = call('propose', 1, { id = c.id, kind = 'reduce_reward', payload = { slot = 2 } })
        eq(reply and reply.err, 'reward_too_small')
        eq(reply.data and reply.data.min, 1000)
    end)
end)

--- W152, W008, W014: the creator's anonymity fee was charged before the
--- escrow and the contract were written, so a process that died between
--- them lost it with no record, and a refunded one left only its charge in
--- the log. It is charged last now, once the contract exists.
describe('the creator\'s anonymity fee, charged once the contract is placed', function()
    local function bank() return Env.players[1].PlayerData.money.bank end
    local function rows(s, action)
        s.audit.flush()
        return s.storage.auditByAction(action, 20) or {}
    end

    it('refuses a creator who cannot cover the reward and the fee, before anything is taken', function()
        local s = newStack()
        local f = fixture(s, { creatorBank = 5200 })
        Config.Anonymity.CreatorFee = 500
        local c, err = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            anonymous = true, reward = { baseline = { bank = 5000 } } })
        falsy(c)
        eq(err, CH.ERR.INSUFFICIENT)
        eq(bank(), 5200, 'nothing taken')
        eq(#rows(s, 'anonymity_fee'), 0, 'and no fee charged to be handed back')
    end)

    it('charges it once, with the amount and the account on its row', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.CreatorFee = 500
        local before = bank()
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            anonymous = true, reward = { baseline = { cash = 5000 } } })
        truthy(c)
        eq(before - bank(), 500)
        local charged = rows(s, 'anonymity_fee')
        eq(#charged, 1)
        eq(charged[1].contract_id, c.id, 'for a contract that exists')
        eq(charged[1].detail.amount, 500)
        eq(charged[1].detail.account, 'bank')
    end)

    it('leaves the contract placed, anonymous and unpaid when the balance went in the moment since', function()
        local s = newStack()
        local f = fixture(s)
        Config.Anonymity.CreatorFee = 500
        local realInsert = s.storage.insertContract
        s.storage.insertContract = function(contract)
            Env.players[1].PlayerData.money.bank = 0
            return realInsert(contract)
        end
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            anonymous = true, reward = { baseline = { cash = 5000 } } })
        s.storage.insertContract = realInsert
        truthy(c, 'placed')
        local stored = s.storage.readContract(c.id)
        eq(stored.state, CH.STATE.ACTIVE)
        truthy(stored.anon_creator, 'and anonymous')
        eq(bank(), 0, 'nobody overdrawn for it')
        eq(#rows(s, 'anonymity_fee'), 0)
        local unpaid = rows(s, 'anonymity_fee_unpaid')
        eq(#unpaid, 1, 'the fee not charged is on the record')
        eq(unpaid[1].detail.amount, 500)
        eq(unpaid[1].detail.account, 'bank')
    end)
end)

--- W143, W018: the anonymity fee a page showed is the fee charged, on
--- placing and on accepting, as the stake already is (§14.18). A fee raised
--- from the admin panel while the form or the dialog was open was charged
--- without ever being shown. Refused before anything is taken, with the
--- figure now; with the figure shown, charged once and named in the reply.
describe('the anonymity fee a page showed', function()
    local function call(name, src, payload)
        local fire = Env.events['crimson-hitman:' .. name]
        Env.clientEvents = {}
        _G.source = src
        fire(payload or {})
        _G.source = nil
        for _, event in ipairs(Env.clientEvents) do
            if event.name == 'crimson-hitman:result' then return event.args[1] end
        end
        return nil
    end
    local function bank(src) return Env.players[src].PlayerData.money.bank end
    local function handle(s)
        local found = s.app.handlers.searchTargets(s.identity.resolve(1), { query = 'Reyes' })
        return found and found[1] and found[1].handle
    end
    local function placing(target, shown)
        return { target = target, reason = 'x', anonymous = true, shown = shown,
                 reward = { slots = { { baseline = { cash = 5000 } } } } }
    end

    it('refuses a creator fee that moved since the form showed it, and takes nothing', function()
        local s = newStack()
        fixture(s)
        Config.Anonymity.CreatorFee, Config.Anonymity.FeeAccount = 2500, 'bank'
        local before = bank(1)
        local reply = call('create', 1, placing(handle(s), { creatorFee = 0, feeAccount = 'bank' }))
        eq(reply and reply.err, CH.ERR.TERMS_CHANGED)
        eq(reply.data and reply.data.creatorFee, 2500, 'with the fee now')
        eq(reply.data.feeAccount, 'bank')
        eq(bank(1), before, 'nothing taken')
        eq(#s.storage.liveContracts(), 0, 'nothing placed')

        Env.advance(61)
        local placed = call('create', 1, placing(handle(s), { creatorFee = 2500, feeAccount = 'bank' }))
        truthy(placed and placed.ok, tostring(placed and placed.err))
        eq(before - bank(1), 2500, 'the fee shown, once')
        eq(placed.data.charged and placed.data.charged.fee, 2500, 'and named in the reply')
    end)

    it('needs no echo where placing anonymously is free', function()
        local s = newStack()
        fixture(s)
        Config.Anonymity.CreatorFee = 0
        local reply = call('create', 1, placing(handle(s), nil))
        truthy(reply and reply.ok, tostring(reply and reply.err))
        falsy(reply.data.charged, 'nothing charged, nothing named')
    end)

    it('refuses a hitman fee that moved since the dialog showed it, and takes nothing', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
        truthy(c)
        Config.Anonymity.HitmanFee, Config.Anonymity.FeeAccount = 1000, 'bank'
        local before = bank(3)
        local reply = call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 0,
            shown = { hitmanFee = 0, feeAccount = 'bank' } })
        eq(reply and reply.err, CH.ERR.TERMS_CHANGED)
        eq(reply.data and reply.data.fee, 1000, 'with the fee now')
        eq(bank(3), before, 'nothing taken')
        eq(#s.storage.readHitmen(c.id), 0, 'and no row written')

        local taken = call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 0,
            shown = { hitmanFee = 1000, feeAccount = 'bank' } })
        truthy(taken and taken.ok, tostring(taken and taken.err))
        eq(before - bank(3), 1000, 'the fee shown, once')
        eq(taken.data.charged and taken.data.charged.fee, 1000, 'and named in the reply')
    end)

    it('needs no echo where taking one anonymously is free', function()
        local s = newStack()
        local f = fixture(s)
        local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'x',
            reward = { baseline = { cash = 5000 } } })
        Config.Anonymity.HitmanFee = 0
        local reply = call('accept', 3, { id = c.id, anonymous = true, penaltyAmount = 0 })
        truthy(reply and reply.ok, tostring(reply and reply.err))
    end)
end)

--- The built-in playtime tracker (server/playtime.lua), the new-player
--- rule's answer on a server whose framework keeps no playtime: qbx_core
--- 1.24 keeps none in its metadata, so the floor did nothing at all there.
describe('the built-in playtime tracker', function()
    local Exec = require('crimson-hitman.tests.harness.mysql_exec')

    --- qbx_core's players table as the tracker reads it, through oxmysql:
    --- each character's number, which only grows.
    local function qbxPlayers(numbers)
        Exec.install(Natives)
        Natives.resourceStates.oxmysql = 'started'
        if numbers then
            Exec.run('CREATE TABLE IF NOT EXISTS players (citizenid VARCHAR(50) PRIMARY KEY, id INT NOT NULL)')
            for cid, id in pairs(numbers) do
                Exec.run('INSERT INTO players (citizenid, id) VALUES (?, ?)', { cid, id })
            end
        end
    end

    --- The usual three, on a server whose metadata carries no playtime, with
    --- the tracker's first pass run: everybody here numbered at or under
    --- `top` in qbx_core's table was here before it.
    local function tracked(numbers)
        local s = newStack()
        local f = fixture(s)
        for src = 1, 3 do Env.players[src].PlayerData.metadata.playtime = nil end
        qbxPlayers(numbers)
        s.playtime.pass()
        return s, f
    end

    --- A character made after the tracker first started.
    local function newcomer(s, number)
        Env.addPlayer({ source = 4, citizenid = 'NEWBIE01', license = 'license:ddd',
            cash = 100, bank = 100, firstname = 'Nell', lastname = 'Newer' })
        Env.players[4].PlayerData.metadata.playtime = nil
        if number then Exec.run('INSERT INTO players (citizenid, id) VALUES (?, ?)', { 'NEWBIE01', number }) end
        return s.identity.resolve(4)
    end

    local function place(s, f, target)
        return s.contracts.create(f.creator, { targetCid = target, reason = 'x', reward = baseReward() })
    end

    it('counts each character\'s time on every pass, and refuses a new one under the floor until it is reached', function()
        local s, f = tracked({ CREATOR1 = 1, TARGET01 = 2, HITMAN01 = 3 })
        newcomer(s, 4)
        Env.advance(60)
        s.playtime.pass()
        local view = s.playtime.view('NEWBIE01')
        eq(view.grandfathered, false, 'numbered after the first start: new')
        eq(view.hours, 0, 'first seen at this pass, counted from it')

        local contract, err = place(s, f, 'NEWBIE01')
        falsy(contract, 'a character with no time played is not fair game')
        eq(err, CH.ERR.TARGET_TOO_NEW, 'with the refusal the floor has always given')

        -- Four passes an hour apart, and half an hour more: counted on each.
        for _ = 1, 4 do
            Env.advance(3600)
            s.playtime.pass()
        end
        eq(s.storage.readPlaytime('NEWBIE01').played_seconds, 4 * 3600, 'written on every pass')
        eq(select(2, place(s, f, 'NEWBIE01')), CH.ERR.TARGET_TOO_NEW, 'four hours is under five')

        Env.advance(1800)
        s.playtime.pass()
        Env.advance(1799)
        eq(s.playtime.view('NEWBIE01').hours, 5, 'the stretch since the last pass is read too')
        falsy(place(s, f, 'NEWBIE01'), 'one second short of five hours')
        Env.advance(2)
        truthy(place(s, f, 'NEWBIE01'), 'and fair game once the count reaches the floor')
    end)

    it('counts a pass that comes late, and a drop between passes, each second once', function()
        local s = tracked({ CREATOR1 = 1, TARGET01 = 2, HITMAN01 = 3 })
        newcomer(s, 4)
        Env.advance(20)
        s.playtime.arrive('NEWBIE01')
        s.playtime.arrive('NEWBIE01')
        Env.advance(40)
        s.playtime.pass()
        eq(s.storage.readPlaytime('NEWBIE01').played_seconds, 40, 'from their login, not from the next pass')
        Env.advance(45)
        eq(s.playtime.pass(), 0, 'no second pass inside the minute')
        Env.advance(20)
        s.playtime.leave('NEWBIE01')
        s.playtime.leave('NEWBIE01')
        Env.removePlayer(4)
        Env.advance(600)
        s.playtime.pass()
        eq(s.storage.readPlaytime('NEWBIE01').played_seconds, 105, 'up to the drop, once, and nothing after it')
    end)

    it('grandfathers every character numbered before its first start, and nobody after', function()
        local s, f = tracked({ CREATOR1 = 1, TARGET01 = 2, HITMAN01 = 3 })
        eq(s.playtime.view('TARGET01').grandfathered, true)
        eq(s.playtime.view('TARGET01').hours, 0, 'nothing counted for them yet')
        truthy(place(s, f, 'TARGET01'), 'a player from before is not suddenly protected')
        eq(s.storage.readPlaytimeInstall().players_id, 3, 'the highest number, recorded once')

        Exec.run('INSERT INTO players (citizenid, id) VALUES (?, ?)', { 'LATER001', 9 })
        newcomer(s, 7)
        Env.advance(60)
        s.playtime.pass()
        eq(s.playtime.view('NEWBIE01').grandfathered, false, 'numbered after it')
        eq(select(2, place(s, f, 'NEWBIE01')), CH.ERR.TARGET_TOO_NEW)
        eq(s.storage.readPlaytimeInstall().players_id, 3, 'and never recorded again')
    end)

    it('takes a character qbx_core has not saved yet for a new one', function()
        local s, f = tracked({ CREATOR1 = 1, TARGET01 = 2, HITMAN01 = 3 })
        newcomer(s, nil)
        Env.advance(60)
        s.playtime.pass()
        eq(s.playtime.view('NEWBIE01').grandfathered, false)
        eq(select(2, place(s, f, 'NEWBIE01')), CH.ERR.TARGET_TOO_NEW)
    end)

    it('grandfathers by the days after its first start where qbx_core\'s table cannot be read', function()
        local s, f = tracked(nil)
        eq(s.storage.readPlaytimeInstall().players_id, nil, 'no number to go by')
        eq(s.playtime.view('TARGET01').grandfathered, true, 'seen in the first days')
        truthy(place(s, f, 'TARGET01'))
        local said = table.concat(require('crimson-hitman.shared.log').view().problems, ' | ')
        truthy(said:find('a brand-new one among them', 1, true), 'said, as a setting to look at: ' .. said)
        truthy(s.playtime.state().grace, 'and the diagnosis can say so')

        Env.advance(Config.Immunity.GrandfatherDays * 86400 + 60)
        newcomer(s, nil)
        s.playtime.pass()
        eq(s.playtime.view('NEWBIE01').grandfathered, false, 'first seen after them')
        eq(select(2, place(s, f, 'NEWBIE01')), CH.ERR.TARGET_TOO_NEW)
    end)

    it('has no answer, and skips the rule, until it can decide', function()
        local s, f = tracked({ CREATOR1 = 1, TARGET01 = 2, HITMAN01 = 3 })
        newcomer(s, 4)
        local contract, err = place(s, f, 'NEWBIE01')
        truthy(contract, 'not decided before the next pass: unknown, not too new: ' .. tostring(err))
        eq(select(2, s.identity.playtimeHours(s.identity.resolve(4))), nil, 'nothing answered')
    end)

    it('lets a configured export win over its own count', function()
        local s, f = tracked({ CREATOR1 = 1, TARGET01 = 2, HITMAN01 = 3 })
        newcomer(s, 4)
        Env.advance(60)
        s.playtime.pass()
        eq(select(2, place(s, f, 'NEWBIE01')), CH.ERR.TARGET_TOO_NEW, 'the count says new')

        rawset(exports, 'my_playtime', { GetMinutes = function(_, cid)
            return cid == 'NEWBIE01' and 600 or 60
        end })
        local ok, failure = pcall(withConfig, {
            { Config.Immunity, 'PlaytimeProvider', { resource = 'my_playtime', export = 'GetMinutes' } },
            { Natives.resourceStates, 'my_playtime', 'started' },
        }, function()
            local hours, from = s.identity.playtimeHours(s.identity.resolve(4))
            eq(hours, 10)
            eq(from, 'provider')
            truthy(place(s, f, 'NEWBIE01'), 'ten hours by the export')
            local contract, err = place(s, f, 'TARGET01')
            falsy(contract, 'grandfathered by the count, one hour by the export: the export wins')
            eq(err, CH.ERR.TARGET_TOO_NEW)
        end)
        rawset(exports, 'my_playtime', nil)
        if not ok then error(failure, 0) end
    end)
end)
