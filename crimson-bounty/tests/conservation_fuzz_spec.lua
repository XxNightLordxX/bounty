--- Randomised conservation: whatever sequence of actions a server sees, the
--- world total per money source must not change. Money only ever moves
--- between pockets and escrow.

local function purse(src)
    local p = Env.players[src]
    if not p then return { cash = 0, bank = 0, dirty = 0 } end
    local dirty = 0
    for _, e in ipairs(p._inventory or {}) do
        if e.name == Config.Sources.dirty.item then dirty = dirty + (e.count or 0) end
    end
    return { cash = p.PlayerData.money.cash or 0,
             bank = p.PlayerData.money.bank or 0, dirty = dirty }
end

local function world(s)
    local total = { cash = 0, bank = 0, dirty = 0 }
    for _, c in ipairs(s.storage.allContracts()) do
        for _, line in ipairs(s.storage.readEscrow(c.id)) do
            if CB.MONEY_SOURCES[line.source] and line.state ~= CB.ESCROW_STATE.SETTLED then
                total[line.source] = total[line.source] + (line.amount or 0)
            end
        end
    end
    for src in pairs(Env.players) do
        local p = purse(src)
        total.cash = total.cash + p.cash
        total.bank = total.bank + p.bank
        total.dirty = total.dirty + p.dirty
    end
    return total
end

describe('randomised conservation', function()
    it('holds across 200 random action sequences', function()
        local worst = nil
        for seed = 1, 200 do
            math.randomseed(seed)
            local s = newStack()
            local f = fixture(s)
            local before = world(s)
            local live = {}

            local function pick(t) return #t > 0 and t[math.random(#t)] or nil end

            for _ = 1, 12 do
                local action = math.random(9)

                if action <= 3 then
                    local reward = { baseline = {}, bonus = {} }
                    local any = false
                    for _, src in ipairs({ 'cash', 'bank', 'dirty' }) do
                        if math.random(2) == 1 then
                            reward.baseline[src] = math.random(1, 900)
                            any = true
                            if math.random(2) == 1 then reward.bonus[src] = math.random(1, 400) end
                        end
                    end
                    if not any then reward.baseline.cash = 500 end
                    local c = s.contracts.create(f.creator, {
                        targetCid = 'TARGET01', reason = 'Unpaid debt',
                        mode = CB.MODE.COMPETITIVE, reward = reward,
                        penaltyAmount = math.random(2) == 1 and math.random(1, 900) or 0,
                        bonusPercent = math.random(3) == 1 and math.random(1, 80) or nil,
                    })
                    if c then live[#live + 1] = c.id end

                elseif action == 4 then
                    local id = pick(live)
                    if id then s.contracts.accept(f.hunter, id, false) end

                elseif action == 5 then
                    local id = pick(live)
                    if id then
                        s.contracts.claimSlot(id, f.hunter.cid,
                            math.random(2) == 1 and CB.FULFILMENT.KIDNAPPING
                                or CB.FULFILMENT.ELIMINATION)
                    end

                elseif action == 6 then
                    local id = pick(live)
                    if id then s.contracts.cancel(f.creator, id) end

                elseif action == 7 then
                    local id = pick(live)
                    if id then s.contracts.abandon(f.hunter, id) end

                elseif action == 8 then
                    local id = pick(live)
                    if id then
                        s.contracts.resolve(id, CB.STATE.EXPIRED, f.creator.cid, nil, 'expired')
                    end

                else
                    local id = pick(live)
                    if id then
                        local ids = {}
                        for _, line in ipairs(s.storage.readEscrow(id)) do
                            if line.state == CB.ESCROW_STATE.HELD
                                and line.portion == CB.PORTION.BONUS then
                                ids[#ids + 1] = line.id
                            end
                        end
                        if #ids > 0 then s.contracts.withdrawReward(f.creator, id, ids) end
                    end
                end
            end

            -- Everyone comes back online and collects anything owed.
            for _, cid in ipairs({ 'CREATOR1', 'TARGET01', 'HUNTER01' }) do
                s.escrow.retryPending(cid)
            end

            local after = world(s)
            for _, source in ipairs({ 'cash', 'bank', 'dirty' }) do
                if after[source] ~= before[source] and not worst then
                    worst = ('seed %d: %s moved by %+d (before %d, after %d)')
                        :format(seed, source, after[source] - before[source],
                                before[source], after[source])
                end
            end
        end
        falsy(worst, 'the world total changed: ' .. tostring(worst))
    end)
end)
