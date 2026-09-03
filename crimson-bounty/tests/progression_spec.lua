--- Reputation and the hook into the server's criminal progression.

local function seeded()
    local s = newStack()
    local f = fixture(s)
    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 }, bonus = { cash = 2500 } },
        bailoutAmount = 10000,
    })
    s.contracts.accept(f.hunter, c.id, false)
    return s, f, c
end

describe('reputation', function()
    it('starts everyone at nothing', function()
        local s = newStack()
        fixture(s)
        local record = s.progression.record('HUNTER01')
        eq(record.completed, 0)
        eq(record.standing, 'Unproven')
        falsy(record.rate, 'a rate with no history would be meaningless')
    end)

    it('counts a completed contract', function()
        local s, f, c = seeded()
        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        eq(s.progression.record('HUNTER01').completed, 1)
    end)

    it('counts a contract placed', function()
        local s, f, c = seeded()
        eq(s.progression.record('CREATOR1').placed, 1)
    end)

    it('counts abandoning as a failure', function()
        local s, f, c = seeded()
        s.contracts.abandon(f.hunter, c.id)
        eq(s.progression.record('HUNTER01').failed, 1)
    end)

    it('credits a target who buys their way out', function()
        local s, f, c = seeded()
        Env.players[2].PlayerData.money.bank = 100000
        s.bailout.buy(f.target, c.id)
        Env.advance(Config.Bailout.ProcessingDelaySeconds + 1)
        s.bailout.processQueue()
        eq(s.progression.record('TARGET01').survived, 1)
    end)

    it('withholds a success rate until there is enough history', function()
        local s = newStack()
        fixture(s)
        s.storage.bumpStat('HUNTER01', 'completed', 2)
        falsy(s.progression.record('HUNTER01').rate, 'two contracts is not a record')

        s.storage.bumpStat('HUNTER01', 'failed', 1)
        eq(s.progression.record('HUNTER01').rate, 66)
    end)

    it('moves through standings as the record grows', function()
        local s = newStack()
        fixture(s)
        eq(s.progression.standing(0, 0), 'Unproven')
        eq(s.progression.standing(5, 0), 'Known')
        eq(s.progression.standing(20, 0), 'Established')
        eq(s.progression.standing(50, 0), 'Notorious')
    end)

    it('shows the creator a record without an identity', function()
        local s, f, c = seeded()
        local row = s.projection.contract(s.storage.readContract(c.id), 'CREATOR1')
        truthy(row.hunters[1].record, 'the creator can judge who took it')
        falsy(row.hunters[1].cid, 'without learning who they are')
        falsy(row.hunters[1].citizenid)
    end)
end)

describe('criminal progression hook', function()
    it('awards trust on a completed contract', function()
        local s, f, c = seeded()
        local awarded = {}
        local realExports = _G.exports
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                if resource ~= 'sc-blackmarket' then return realExports[resource] end
                return { AddTrust = function(_, cid, amount)
                    awarded[#awarded + 1] = { cid = cid, amount = amount }
                end }
            end,
        })

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.KIDNAPPING)
        _G.exports = realExports

        eq(#awarded, 1)
        eq(awarded[1].cid, 'HUNTER01')
        eq(awarded[1].amount, Config.Progression.TrustPerKidnapping,
            'a live delivery is worth more than a kill')
    end)

    it('still pays out when the progression resource errors', function()
        local s, f, c = seeded()
        local realExports = _G.exports
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                if resource ~= 'sc-blackmarket' then return realExports[resource] end
                return { AddTrust = function() error('blackmarket exploded') end }
            end,
        })

        local ok = s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        _G.exports = realExports

        truthy(ok, 'a progression failure must never cost the hunter their payout')
        eq(Env.players[3].PlayerData.money.cash, 10000, 'and the money still moved')
    end)

    it('does nothing when progression is disabled', function()
        local s, f, c = seeded()
        Config.Progression.Enabled = false
        local touched = false
        local realExports = _G.exports
        _G.exports = setmetatable({}, {
            __index = function(_, resource)
                if resource ~= 'sc-blackmarket' then return realExports[resource] end
                return { AddTrust = function() touched = true end }
            end,
        })

        s.contracts.claimSlot(c.id, 'HUNTER01', CB.FULFILMENT.ELIMINATION)
        _G.exports = realExports
        Config.Progression.Enabled = true

        falsy(touched)
    end)
end)

describe('staff webhook', function()
    it('sends nothing when no webhook is configured', function()
        local s = newStack()
        fixture(s)
        Natives.calls.http = {}
        s.audit.financial('test_event', 'CREATOR1', 'ct1', { amount = 100 })
        s.audit.flush()
        eq(#Natives.calls.http, 0)
    end)

    it('mirrors financial and rejected lines when one is configured', function()
        local s = newStack()
        fixture(s)
        Config.Audit.Webhook = 'https://discord.example/hook'
        Natives.calls.http = {}

        s.audit.financial('payout', 'HUNTER01', 'ct1', { amount = 5000 })
        s.audit.rejected('photo_forged', 'HUNTER01', 'ct1', {})
        s.audit.action('contract_created', 'CREATOR1', 'ct1', {})
        s.audit.flush()

        Config.Audit.Webhook = false
        eq(#Natives.calls.http, 2, 'financial and rejected, not routine conduct')
    end)

    it('never puts a citizen id in the webhook body', function()
        local s = newStack()
        fixture(s)
        Config.Audit.Webhook = 'https://discord.example/hook'
        Natives.calls.http = {}

        s.audit.financial('payout', 'HUNTER01', 'ct1', { amount = 5000 })
        s.audit.flush()
        Config.Audit.Webhook = false

        truthy(#Natives.calls.http > 0)
        falsy(tostring(Natives.calls.http[1].body):find('HUNTER01'),
            'identity must not leave the server')
    end)
end)
