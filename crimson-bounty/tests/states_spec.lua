--- Every contract state crossed with every action a player can take on it.
---
--- The authorisation matrix is (handler x role): who may act. This is
--- (state x action): whether the action makes sense AT ALL right now. They
--- are different questions and a contract can pass one while failing the
--- other — a hunter is the right role to submit a photo, and submitting one
--- against a contract that has already closed is still nonsense.
---
--- What this is looking for, specifically:
---
---   * An action that SUCCEEDS on a contract where it should not. That is
---     the dangerous direction: money moving on a closed contract, a second
---     payout on a slot already claimed, a stake taken for a contract
---     nobody can complete.
---   * An action that refuses with a code belonging to a different rule. A
---     refusal that says "you are not a participant" when the real reason is
---     "this contract ended two hours ago" sends the player looking for a
---     permission problem they do not have.
---   * Anything that THROWS. A handler's pcall turns a throw into
---     server_error, which tells the player nothing and tells the operator
---     only that something broke.
---
--- The grid is driven through the real net events, like the authorisation
--- matrix, because that is the only surface a player has.

local APP_SOURCE = read_file('crimson-bounty/server/app.lua')

--- Fire a net event as a given source and read the reply the client gets.
local function call(s, name, source, payload)
    local fire = Env.events['crimson-bounty:' .. name]
    if not fire then return { missing = true } end
    Env.clientEvents = {}
    _G.source = source
    local ok, err = pcall(fire, payload or {})
    _G.source = nil
    if not ok then return { threw = true, err = tostring(err) } end
    for _, event in ipairs(Env.clientEvents) do
        if event.name == 'crimson-bounty:result' then
            local reply = event.args[1]
            if reply and reply.event == name then return reply end
        end
    end
    local _ = s
    return { silent = true }
end

--- A contract in each state, with the parties still present.
---
--- Built through the resource rather than written into the store, so the
--- escrow, the hunter rows and the audit trail are all genuinely what that
--- state looks like. A hand-written row would let a cell pass against a
--- shape the resource cannot actually produce.
local function inState(state)
    local s = newStack()
    local f = fixture(s)
    Env.players[1].PlayerData.money.bank = 400000
    Env.players[2].PlayerData.money.bank = 400000
    Env.players[3].PlayerData.money.bank = 400000

    local c = s.contracts.create(f.creator, {
        targetCid = 'TARGET01', reason = 'Unpaid debt',
        mode = CB.MODE.COMPETITIVE,
        reward = { baseline = { cash = 5000 } },
        bailoutAmount = 9000,
    })
    truthy(c, 'the fixture has to produce a contract')

    if state == CB.STATE.ACTIVE then
        -- As created.
    elseif state == CB.STATE.ACCEPTED then
        truthy(s.contracts.accept(f.hunter, c.id), 'accept for the ACCEPTED fixture')
    elseif state == CB.STATE.COMPLETING then
        truthy(s.contracts.accept(f.hunter, c.id), 'accept first')
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED, CB.STATE.COMPLETING,
            'fixture'), 'the fixture has to reach COMPLETING')
    elseif state == CB.STATE.CANCELLED then
        truthy(s.contracts.resolve(c.id, CB.STATE.CANCELLED, f.creator.cid, nil,
            'fixture'), 'cancel for the CANCELLED fixture')
    elseif state == CB.STATE.EXPIRED then
        truthy(s.contracts.resolve(c.id, CB.STATE.EXPIRED, f.creator.cid, nil,
            'expired'), 'expire for the EXPIRED fixture')
    elseif state == CB.STATE.BAILED_OUT then
        truthy(s.contracts.resolve(c.id, CB.STATE.BAILED_OUT, f.creator.cid, nil,
            'bailed_out'), 'bail out for the BAILED_OUT fixture')
    elseif state == CB.STATE.VOIDED then
        truthy(s.admin.void(0, c.id, 'fixture'), 'void for the VOIDED fixture')
    elseif state == CB.STATE.COMPLETED then
        -- Through COMPLETING, which is the only route the transition table
        -- allows. Resolving straight from ACCEPTED is refused, correctly.
        truthy(s.contracts.accept(f.hunter, c.id), 'accept first')
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED,
            CB.STATE.COMPLETING, 'fixture'), 'reach COMPLETING first')
        truthy(s.contracts.resolve(c.id, CB.STATE.COMPLETED, f.hunter.cid, nil,
            'completed'), 'complete for the COMPLETED fixture')
    else
        error('no fixture for state ' .. tostring(state))
    end

    eq(s.storage.readContract(c.id).state, state,
        'the fixture did not reach ' .. tostring(state))
    return s, f, c
end

--- Every state a contract can be in, and whether it is finished.
local STATES = {
    CB.STATE.ACTIVE, CB.STATE.ACCEPTED, CB.STATE.COMPLETING,
    CB.STATE.COMPLETED, CB.STATE.CANCELLED, CB.STATE.EXPIRED,
    CB.STATE.BAILED_OUT, CB.STATE.VOIDED,
}

--- What a player's money and the contract's escrow look like right now.
local function snapshot(s, c)
    local total = 0
    for i = 1, 3 do
        local p = Env.players[i]
        if p then
            total = total + p.PlayerData.money.cash + p.PlayerData.money.bank
        end
    end
    local held = 0
    for _, line in ipairs(s.storage.readEscrow(c.id)) do
        if line.state ~= CB.ESCROW_STATE.SETTLED then held = held + (line.amount or 0) end
    end
    return { money = total, held = held, state = s.storage.readContract(c.id).state }
end

--------------------------------------------------------------------------
-- The grid
--------------------------------------------------------------------------

--- Every action, who fires it, what it needs in its payload, and which
--- states it is allowed to succeed in.
---
--- `allowed` is a set of states. Anything outside it must refuse, and the
--- refusal must be one of `refusals` — a closed list per action, so a cell
--- that starts answering with a code from an unrelated rule is a failure
--- rather than a pass.
local ACTIONS = {
    { name = 'accept', source = 3,
      payload = function(c) return { id = c.id } end,
      allowed = { [CB.STATE.ACTIVE] = true, [CB.STATE.ACCEPTED] = true },
      refusals = { bad_state = true, already_settled = true, not_found = true,
                   contract_full = true, limit_reached = true },
      why = 'a contract that has ended cannot be taken' },

    { name = 'abandon', source = 3,
      payload = function(c) return { id = c.id } end,
      allowed = { [CB.STATE.ACCEPTED] = true, [CB.STATE.COMPLETING] = true },
      refusals = { bad_state = true, not_participant = true, already_settled = true },
      why = 'you can only walk away from something you are holding' },

    { name = 'cancel', source = 1,
      payload = function(c) return { id = c.id } end,
      allowed = { [CB.STATE.ACTIVE] = true, [CB.STATE.ACCEPTED] = true },
      refusals = { already_settled = true, bad_state = true, locked = true },
      why = 'a finished contract cannot be cancelled again' },

    { name = 'bailout', source = 2,
      payload = function(c) return { id = c.id } end,
      allowed = { [CB.STATE.ACTIVE] = true, [CB.STATE.ACCEPTED] = true },
      refusals = { already_settled = true, bad_state = true, bailout_off = true,
                   no_buyout_price = true, buyout_pending = true,
                   insufficient_funds = true, incapacitated = true,
                   handover_in_progress = true },
      why = 'buying out a contract that already ended would be paying for nothing' },

    { name = 'armKidnap', source = 3,
      payload = function(c) return { id = c.id } end,
      allowed = { [CB.STATE.ACCEPTED] = true },
      refusals = { bad_state = true, not_participant = true, already_settled = true,
                   invalid_input = true, not_coerced = true, limit_reached = true,
                   target_not_conscious = true, party_offline = true,
                   creator_too_far = true, target_too_far = true,
                   target_protected = true },
      why = 'a handover needs a live contract you are holding' },

    { name = 'requestPhotoToken', source = 3,
      payload = function(c) return { id = c.id } end,
      allowed = {},   -- needs an attributed kill, which no fixture here has
      refusals = { no_kill_to_verify = true, invalid_input = true,
                   not_participant = true },
      why = 'proof is for a kill the server saw, whatever state the contract is in' },

    { name = 'addEscrow', source = 1,
      payload = function(c) return { id = c.id, reward = { baseline = { cash = 1000 } } } end,
      allowed = { [CB.STATE.ACTIVE] = true, [CB.STATE.ACCEPTED] = true },
      refusals = { already_settled = true, bad_state = true, invalid_reward = true,
                   not_participant = true },
      why = 'money must not be added to a contract that can never pay out' },

    { name = 'improve', source = 1,
      payload = function(c) return { id = c.id, kind = 'extend_deadline',
                                      payload = { seconds = 600 } } end,
      -- COMPLETING included: a settlement that fails rolls back to ACCEPTED,
      -- and a longer deadline is then a plain benefit to the hunter. Raising
      -- the BONUS is a different matter and has its own test below, because
      -- that one takes escrow.
      allowed = { [CB.STATE.ACTIVE] = true, [CB.STATE.ACCEPTED] = true,
                  [CB.STATE.COMPLETING] = true },
      refusals = { already_settled = true, bad_state = true, invalid_input = true,
                   not_participant = true },
      why = 'improving the terms of a closed contract improves nothing' },

    { name = 'propose', source = 1,
      payload = function(c) return { id = c.id, kind = CB.AMENDMENT.LOWER_PENALTY,
                                      payload = { amount = 1 } } end,
      allowed = { [CB.STATE.ACCEPTED] = true },
      refusals = { bad_state = true, already_settled = true, invalid_input = true,
                   not_participant = true, limit_reached = true },
      why = 'there is nothing to renegotiate on a contract nobody is hunting' },

    { name = 'withdrawReward', source = 1,
      payload = function(c) return { id = c.id, slot = 1 } end,
      allowed = { [CB.STATE.ACTIVE] = true },
      refusals = { already_settled = true, bad_state = true, invalid_input = true,
                   not_participant = true, locked = true },
      why = 'taking a reward back out once a hunter is on it is not the creator\'s call' },

    -- Reads. These may answer on a finished contract — a party is allowed to
    -- look at what happened — so every state is permitted and the point of
    -- the row is that none of them throws or leaks.
    { name = 'rewardBreakdown', source = 1, read = true,
      payload = function(c) return { id = c.id } end,
      allowed = 'all',
      refusals = { not_participant = true, not_found = true, invalid_input = true },
      why = 'a party may read what a contract holds or held' },

    { name = 'amendments', source = 1, read = true,
      payload = function(c) return { id = c.id } end,
      allowed = 'all',
      refusals = { not_participant = true, not_found = true, invalid_input = true },
      why = 'a party may read the proposals on a contract' },

    { name = 'threads', source = 1, read = true,
      payload = function(c) return { id = c.id } end,
      allowed = 'all',
      refusals = { not_participant = true, not_found = true, invalid_input = true },
      why = 'a party may read who they can talk to' },

    { name = 'kidnapProgress', source = 3, read = true,
      payload = function(c) return { id = c.id } end,
      allowed = 'all',
      refusals = { not_participant = true, not_found = true, invalid_input = true,
                   bad_state = true, no_handover = true },
      why = 'asking about a countdown that is not running is a question, not a fault' },
}

describe('every action against every contract state', function()
    for _, action in ipairs(ACTIONS) do
        for _, state in ipairs(STATES) do
            local permitted = action.allowed == 'all'
                or (action.allowed ~= nil and action.allowed[state] == true)

            it(('%s on a %s contract'):format(action.name, state), function()
                local s, f, c = inState(state)
                local before = snapshot(s, c)
                local reply = call(s, action.name, action.source, action.payload(c))

                falsy(reply.missing, 'no such net event is registered')
                falsy(reply.threw,
                    'the handler threw, which reaches the player as '
                    .. 'server_error and tells them nothing: '
                    .. tostring(reply.err))
                falsy(reply.silent, 'the handler answered nobody; the page waits 15s')

                if permitted then
                    -- Allowed to succeed OR to refuse for a reason of its
                    -- own — several of these have preconditions this fixture
                    -- does not set up (a restrained target, enough money).
                    -- What it may not do is refuse with a code from another
                    -- rule, which is what the closed list is for.
                    if not reply.ok then
                        truthy(action.refusals[reply.err],
                            ('refused with %s, which is not one of this '
                            .. 'action\'s reasons — %s'):format(
                                tostring(reply.err), action.why))
                    end
                else
                    falsy(reply.ok,
                        ('succeeded on a %s contract, and it should not have: %s')
                            :format(state, action.why))
                    truthy(action.refusals[reply.err],
                        ('refused with %s, which belongs to a different rule. '
                        .. 'The player is sent looking for the wrong problem — %s')
                            :format(tostring(reply.err), action.why))
                end

                -- Nothing a refused action touches may have moved.
                local after = snapshot(s, c)
                if not reply.ok then
                    eq(after.money, before.money,
                        'a refused ' .. action.name .. ' moved money')
                    eq(after.held, before.held,
                        'a refused ' .. action.name .. ' changed the escrow')
                    eq(after.state, before.state,
                        'a refused ' .. action.name .. ' changed the contract state')
                end
                local _ = f
            end)
        end
    end
end)

describe('the grid covers the whole action surface', function()
    --- A handler that gains a state rule and no row here is a handler whose
    --- state rule nothing checks.
    local COVERED_ELSEWHERE = {
        list = true, mine = true, ledger = true, searchTargets = true,
        browseTargets = true, mugshotImage = true, rewardOptions = true,
        create = true, pageError = true,
        -- These act on something other than a contract's state.
        revise = true,            -- reward_edit_spec, keyed on lines not state
        submitPhoto = true,       -- needs a token, which needs a kill
        informant = true,         -- interaction_spec
        respondAmendment = true,  -- needs an open proposal
        readThread = true, sendMessage = true, requestCall = true,
    }

    it('has a row for every contract action app.lua registers', function()
        local rows = {}
        for _, action in ipairs(ACTIONS) do rows[action.name] = true end

        local missing = {}
        for name in APP_SOURCE:gmatch("handler%('([%w]+)'") do
            if not rows[name] and not COVERED_ELSEWHERE[name] then
                missing[#missing + 1] = name
            end
        end
        table.sort(missing)
        eq(#missing, 0,
            'these actions have no state rule checked anywhere: '
            .. table.concat(missing, ', '))
    end)

    it('is actually a grid, not a handful of cells', function()
        truthy(#ACTIONS * #STATES >= 100,
            'the grid is ' .. (#ACTIONS * #STATES) .. ' cells')
    end)
end)

describe('raising the bonus answers to the same state rule as adding escrow', function()
    --- Two doors to the same room, and only one of them was locked.
    ---
    --- Amendments.addEscrow refuses anything but ACTIVE and ACCEPTED, because
    --- a contract in COMPLETING is mid-settlement with Escrow.release walking
    --- its lines right now: a line appended into that walk may or may not be
    --- paid depending on where the loop had got to.
    ---
    --- Amendments.improve guarded only CB.TERMINAL, and raise_bonus under
    --- improve TAKES ESCROW — so the creator could do through one door
    --- exactly what the other refused.
    local function completing()
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, bonusPercent = 10,
        })
        truthy(s.contracts.accept(f.hunter, c.id))
        truthy(s.contracts.transition(c.id, CB.STATE.ACCEPTED,
            CB.STATE.COMPLETING, 'fixture'))
        return s, f, c
    end

    local function heldLines(s, id)
        local n = 0
        for _, line in ipairs(s.storage.readEscrow(id)) do
            if line.state ~= CB.ESCROW_STATE.SETTLED then n = n + 1 end
        end
        return n
    end

    it('refuses a bonus raise on a contract that is settling', function()
        local s, f, c = completing()
        local before = heldLines(s, c.id)
        local wallet = Env.players[1].PlayerData.money.cash
                     + Env.players[1].PlayerData.money.bank

        local ok, err = s.amendments.improve(f.creator, c.id,
            CB.AMENDMENT.RAISE_BONUS, { percent = 50 })

        falsy(ok, 'a bonus raise mid-settlement appends escrow lines into a '
            .. 'release that is already walking them')
        eq(err, CB.ERR.BAD_STATE)
        eq(heldLines(s, c.id), before, 'no line was added')
        eq(Env.players[1].PlayerData.money.cash
           + Env.players[1].PlayerData.money.bank, wallet,
           'and nothing was charged for it')
    end)

    it('refuses it in exactly the states adding escrow refuses', function()
        -- The rule, not two rules that happen to agree today.
        for _, state in ipairs({ CB.STATE.COMPLETING, CB.STATE.COMPLETED,
                                 CB.STATE.CANCELLED, CB.STATE.EXPIRED,
                                 CB.STATE.BAILED_OUT, CB.STATE.VOIDED }) do
            local s, f, c = inState(state)
            Env.players[1].PlayerData.money.bank = 400000

            local addOk, addErr = s.amendments.addEscrow(f.creator, c.id,
                { baseline = { cash = 1000 } })
            local bonusOk, bonusErr = s.amendments.improve(f.creator, c.id,
                CB.AMENDMENT.RAISE_BONUS, { percent = 80 })

            falsy(addOk, state .. ': addEscrow should refuse')
            falsy(bonusOk, state .. ': raising the bonus should refuse too')
            eq(bonusErr, addErr,
                state .. ': the two doors to the same room must give the same '
                .. 'answer, got ' .. tostring(bonusErr) .. ' and '
                .. tostring(addErr))
        end
    end)

    it('still allows a bonus raise while the contract is live', function()
        -- The guard must not have closed the door it was not about.
        local s = newStack()
        local f = fixture(s)
        Env.players[1].PlayerData.money.bank = 400000
        Env.players[3].PlayerData.money.bank = 400000

        local c = s.contracts.create(f.creator, {
            targetCid = 'TARGET01', reason = 'x', mode = CB.MODE.COMPETITIVE,
            reward = { baseline = { cash = 10000 } }, bonusPercent = 10,
        })
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS,
            { percent = 40 }), 'on an ACTIVE contract this is the whole point')

        truthy(s.contracts.accept(f.hunter, c.id))
        truthy(s.amendments.improve(f.creator, c.id, CB.AMENDMENT.RAISE_BONUS,
            { percent = 60 }), 'and on an ACCEPTED one')
    end)

    it('still allows extending the deadline while a contract settles', function()
        -- COMPLETING can roll back to ACCEPTED when a settlement fails, and a
        -- longer deadline is then a plain benefit to the hunter. This is the
        -- case the guard deliberately leaves open.
        local s, f, c = completing()
        truthy(s.amendments.improve(f.creator, c.id,
            CB.AMENDMENT.EXTEND_DEADLINE, { seconds = 600 }),
            'extending a deadline takes no money and helps the hunter')
    end)
end)
