--- Step 3k: one payout check. Whether a claim pays at all is one function,
--- Contracts.payoutRefusal, asked before the claim takes its lock and again
--- under it; what may hold a payout once the claim went through is one
--- ordered list, server/payout.lua (body disposal, then proof of intent),
--- over the escrow's one hold. Held here: the list and its order, the
--- escrow's gate and the claim's hooks pointing at it, a check that raises
--- holding nothing and stopping no other, and the one eligibility check's
--- answers. Money conservation is the money specs' (money_paths_spec,
--- conservation_spec, tests/invariants.lua).

local function read_file(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

local function placed(s, f)
    local c = s.contracts.create(f.creator, { targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CH.MODE.COMPETITIVE, reward = { baseline = { cash = 5000 } } })
    truthy(c, 'placed')
    truthy(s.contracts.accept(f.hitman, c.id, false), 'accepted')
    return c
end

describe('step 3k: one payout check', function()
    it('is one ordered list, wired once into the escrow and the claim', function()
        local s = newStack()
        local Payout = require('server.payout')
        eq(table.concat(Payout.ORDER, ','), 'disposal,intent', 'both checks, disposal first')
        eq(s.escrow.holdBack, Payout.holds, 'the escrow asks the list before every give')
        eq(s.escrow.holdUntil, Payout.releasesAt, 'and staff are told when from the list')
        eq(s.contracts.payoutOnClaim, Payout.onClaim, 'the claim tells the list')
        eq(s.contracts.payoutAfterClaim, Payout.afterClaim, 'and how it ended')
        eq(s.contracts.intentOnClaim, nil, 'the old hook')
        eq(s.contracts.intentAfterClaim, nil, 'the old hook')
    end)

    it('no feature patches the gate or the hooks of its own any more', function()
        for _, file in ipairs({ 'disposal', 'rp_intent' }) do
            local src = read_file('crimson-hitman/server/' .. file .. '.lua')
            falsy(src:find('holdBack%s*='), file .. ' sets the escrow\'s gate itself')
            falsy(src:find('OnClaim%s*='), file .. ' sets the claim\'s hook itself')
            falsy(src:find('AfterClaim%s*='), file .. ' sets the claim\'s hook itself')
            truthy(src:find("Payout.add('", 1, true), file .. ' adds its check to the list')
        end
    end)

    it('asks in order, and a check that raises holds nothing and stops no other', function()
        newStack()
        local Payout = require('server.payout')
        local line = { portion = CH.PORTION.BASELINE, contract_id = 'C1', slot = 1 }
        Payout.add('disposal', { holds = function() return true end })
        Payout.add('intent', { holds = function() return true end, releasesAt = function() return 1234 end })
        local held, by = Payout.holds('HITMAN01', line)
        truthy(held)
        eq(by, 'disposal', 'the first in the list answers')
        Payout.add('disposal', { holds = function() error('raised') end,
            onClaim = function() error('raised') end })
        held, by = Payout.holds('HITMAN01', line)
        truthy(held, 'the next check still asked')
        eq(by, 'intent')
        eq(Payout.releasesAt('HITMAN01', line), 1234)
        Payout.add('intent', { holds = function() return false end,
            onClaim = function() return { missing = 'messages' } end })
        falsy(Payout.holds('HITMAN01', line), 'nothing holds it')
        eq(Payout.onClaim({}, 'HITMAN01', CH.FULFILMENT.ELIMINATION).missing, 'messages',
            'the claim gets the hold past a check that raised')
        local ok = pcall(Payout.add, 'photo', {})
        falsy(ok, 'a check not in the order is refused')
    end)

    it('decides whether a claim pays with one check, before the lock and under it', function()
        local s = newStack()
        local f = fixture(s)
        local c = placed(s, f)
        local contract = s.storage.readContract(c.id)
        local row = s.storage.readHitman(c.id, 'HITMAN01')
        eq(s.contracts.payoutRefusal(contract, row), nil, 'eligible')
        eq(s.contracts.payoutRefusal(contract, nil), CH.ERR.NOT_PARTICIPANT)
        eq(s.contracts.payoutRefusal(contract, { state = 'withdrawn' }), CH.ERR.NOT_PARTICIPANT)
        eq(s.contracts.payoutRefusal(setmetatable({ next_slot = 2 }, { __index = contract }), row),
            CH.ERR.ALREADY_SETTLED, 'no slot left')
        local src = read_file('crimson-hitman/server/contracts.lua')
        local _, uses = src:gsub('Contracts%.payoutRefusal%(', '')
        local _, defined = src:gsub('function Contracts%.payoutRefusal%(', '')
        eq(defined, 1, 'defined once')
        eq(uses - defined, 2, 'asked twice in the claim: before its lock and under it')
        -- And the claim still pays, once.
        local paid, err = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        truthy(paid, tostring(err))
        local again, why = s.contracts.claimSlot(c.id, 'HITMAN01', CH.FULFILMENT.ELIMINATION)
        falsy(again)
        truthy(why == CH.ERR.BAD_STATE or why == CH.ERR.ALREADY_SETTLED, tostring(why))
    end)
end)
