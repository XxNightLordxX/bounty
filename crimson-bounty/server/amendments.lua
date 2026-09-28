--- Contract amendments (§12).
---
--- Additive changes apply immediately because they can only benefit the
--- hunter. Anything that could disadvantage the other side is a proposal
--- needing approval from the creator and every accepted hunter. The target of
--- a contract is never amendable.

local Util = require_shared('util')

local Amendments = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify

--- Contract ids known to carry an open proposal. Walking every contract ever
--- created on each tick means a query per contract, forever; proposals are
--- rare and short-lived, so tracking the few that exist gives the same
--- answer far more cheaply.
local openContracts = {}

function Amendments.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    openContracts = {}
end

--- Who has to agree: the client, and every hunter on the contract —
--- including one part-way through accepting (Contracts.holds). Counting only
--- active rows let a change be applied, as agreed by nobody else, under a
--- hunter who had already staked on the old terms.
local function participants(contract)
    local out = { [contract.creator_cid] = 'creator' }
    local hunters = Storage.readHunters(contract.id)
    for i = 1, #hunters do
        if Contracts.holds(hunters[i]) then out[hunters[i].hunter_cid] = 'hunter' end
    end
    return out
end

--- Move the open app of everyone on a contract but the one who acted.
---
--- A phone notification does not change a page that is already open; only
--- a push does, and nothing here sent one. A proposal never appeared on the
--- other party's open Mine tab, so it ran out unseen; a decline or an
--- expiry left the proposer's panel waiting on an answer that had come; an
--- improvement left a hunter's card showing the old terms. The target is
--- never among them: a push to them would say something had changed on a
--- contract they are not told exists.
local function pushOthers(contract, actorCid, reason)
    if not contract then return end
    for cid in pairs(participants(contract)) do
        if cid ~= actorCid then Notify.push(cid, reason) end
    end
end

--------------------------------------------------------------------------
-- Additive changes (§12.1)
--------------------------------------------------------------------------

--- How long a top-up waits on a claim part-way through paying, and how often
--- it looks. A claim is a handful of store calls.
local CLAIM_WAIT_MS, CLAIM_POLL_MS = 3000, 100

--- Hand back escrow this call has just taken, if the contract moved under
--- it while the take was in flight.
---
--- The contract is read at the top of the call and every store call after
--- that is a yield on mysql. A buyout, an expiry, a cancellation or the last
--- payout landing in one of them settles the contract's escrow before these
--- lines exist, so nothing would ever sweep them: the creator's top-up sat
--- `held` on a closed contract, owed to nobody. And a payout landing on the
--- very slot being topped up leaves the lines on a collection already paid,
--- which no claim will ever reach again.
---
--- Asked once the lines are written, which is what makes the answer binding:
--- an ending that has not started yet will find them when it returns the
--- remainder, and a claim that has not started yet will pay them out.
---@return boolean stillOpen
---@return string|nil err
local function keptOrReturned(actor, contractId, expectedSlot, ids)
    -- Only a line nobody else has been given can be handed back. A claim
    -- landing in the awaits can already have paid a new line to its hunter
    -- and, with their pockets full, queued it for them: still held, but
    -- owed to them. A named release overrides that, so handing it back gave
    -- the creator the hunter's money and cleared the hunter's queue entry.
    local function returnable(line)
        return line ~= nil and line.state == CB.ESCROW_STATE.HELD
            and (line.owed_to == nil or line.owed_to == actor.cid)
    end

    -- And asked again where it binds: after the release has taken the line
    -- out of `held`, when nothing else can pay it. The read above is a
    -- filter, not a promise; a claim landing in the awaits between it and
    -- the release could still queue the line for its hunter first.
    local function stillReturnable(line)
        local current = Storage.readEscrowLine(line.id)
        return current ~= nil
            and (current.owed_to == nil or current.owed_to == actor.cid)
    end

    -- Where a line went, when it is not back with the client: paid out or
    -- queued by a claim, which is where a top-up was meant to go.
    local function paidTo(id)
        local line = Storage.readEscrowLine(id)
        local to = line and (line.settled_to or line.releasing_to or line.owed_to)
        if to and to ~= actor.cid then return to end
        return nil
    end

    -- A claim part-way through paying is waited out, briefly. Which
    -- collection it is paying cannot be read off the row: it moves the slot
    -- on before it lets go, and it can yet be refused and pay nothing.
    -- Guessed from the slot, the next collection's top-up went back while
    -- the raise was reported applied, and a refused claim's collection lost
    -- its own. Read as closed, every top-up went back, the later ones too.
    -- A claim is a handful of store calls; one still going after this has
    -- stalled, and is answered below without guessing.
    local now = Storage.readContract(contractId)
    local waited = 0
    while now and now.state == CB.STATE.COMPLETING and waited < CLAIM_WAIT_MS do
        Wait(CLAIM_POLL_MS)
        waited = waited + CLAIM_POLL_MS
        now = Storage.readContract(contractId)
    end

    local state = now and now.state
    local open = state == CB.STATE.ACTIVE or state == CB.STATE.ACCEPTED
    if open and (expectedSlot == nil or (now.next_slot or 1) == expectedSlot) then
        return true
    end

    -- Still open, and a claim moved the slot on in the awaits. Only lines on
    -- a collection already paid are stranded; those on collections still to
    -- come are as good as ever, and a line the claim paid out went where it
    -- was meant to. Handing every line back and then reporting the top-up as
    -- made told a bonus raise it had applied — its percent stored and shown
    -- — while the collections after it went back to the old bonus.
    if open then
        local paying = now.next_slot or 1
        local back, kept = {}, false
        for id in pairs(ids or {}) do
            local line = Storage.readEscrowLine(id)
            if returnable(line) and (line.slot or 0) < paying then
                back[id] = true
            elseif line then
                kept = true
            end
        end
        if next(back) then
            Escrow.release(contractId, actor.cid, { lines = back }, 'escrow_added_to_moved',
                stillReturnable)
            -- One a claim took from under the release went to its hunter.
            for id in pairs(back) do
                if paidTo(id) then kept = true end
            end
        end
        if kept then return true end
        Audit.rejected('escrow_added_to_moved', actor.cid, contractId, { state = state })
        return false, CB.ERR.LOCKED
    end

    if ids and next(ids) then
        local back = {}
        for id in pairs(ids) do
            if returnable(Storage.readEscrowLine(id)) then back[id] = true end
        end
        if next(back) then
            Escrow.release(contractId, actor.cid, { lines = back }, 'escrow_added_to_moved',
                stillReturnable)
        end

        -- A claim that moved the slot after these lines were written paid
        -- them out with its collection, and there was nothing to hand back:
        -- the top-up went where it was meant to go. Answering "someone got
        -- there first" told the client it had not gone through, while a
        -- hunter had the money. That holds when the claim was the last one
        -- and closed the contract, too. A contract that closed any other way
        -- is told as closed: its ending returned the lines to the client.
        --
        -- A claim that stalled is still going, and only a top-up it took
        -- whole went through: with any of it back with the client, the rest
        -- of the raise was not made.
        local to, handedBack = nil, false
        for id in pairs(ids) do
            local paid = paidTo(id)
            if paid then to = to or paid else handedBack = true end
        end
        if to and (CB.TERMINAL[state] or not handedBack) then
            Audit.action('escrow_added_paid_out', actor.cid, contractId, { to = to })
            return true
        end
    end
    Audit.rejected('escrow_added_to_moved', actor.cid, contractId, { state = state })
    if CB.TERMINAL[state] then return false, CB.ERR.ALREADY_SETTLED end
    if state == CB.STATE.COMPLETING then return false, CB.ERR.BUSY end
    return false, CB.ERR.LOCKED
end

--- Add value to a live contract. Applies at once; escrow is taken through
--- the same path as creation, so the added value is as safe as the original.
---@return boolean ok
---@return string|nil err
local addEscrowUnlocked

--- One change to what a contract holds at a time: a top-up reads the value
--- and line counts it is checked against, and a bonus raise beside it read
--- the same ones.
function Amendments.addEscrow(actor, contractId, rewardSpec)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    return Contracts.serialized({ 'contract:' .. contractId },
        addEscrowUnlocked, actor, contractId, rewardSpec)
end

addEscrowUnlocked = function(actor, contractId, rewardSpec)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        return false, CB.ERR.BAD_STATE
    end

    -- Counted against what the contract still holds, so a creator cannot top
    -- up past the line ceiling in small increments — but settled lines are
    -- not held, and neither are hunters' stakes. Counting those refused a
    -- legitimate top-up on any contract that had already paid out.
    local held = 0
    for _, line in ipairs(Storage.readEscrow(contractId)) do
        if line.state ~= CB.ESCROW_STATE.SETTLED and line.portion ~= CB.PORTION.STAKE then
            held = held + 1
        end
    end

    -- What it is worth already, so the total ceiling bounds the contract
    -- rather than each top-up on its own.
    local worth = Escrow.moneyValue(contractId)

    local lines, err = Escrow.validate(actor, rewardSpec, nil, held, worth)
    if not lines then return false, err end

    -- Added value lands on the slot currently being competed for, so it is
    -- unambiguous which collection it sweetens.
    local slot = contract.next_slot or 1
    for i = 1, #lines do lines[i].slot = slot end

    local ok, ids
    ok, err, ids = Escrow.take(actor, contractId, lines)
    if not ok then return false, err end

    local open, movedErr = keptOrReturned(actor, contractId, slot, ids)
    if not open then return false, movedErr end

    Audit.financial('escrow_added', actor.cid, contractId, { lines = #lines, slot = slot })

    local people = participants(contract)
    for cid, role in pairs(people) do
        if role == 'hunter' then
            Notify.toCitizen(cid, 'Contract improved',
                'The client has increased the reward on a contract you hold.')
        end
    end
    pushOthers(contract, actor.cid, 'improved')

    return true
end

--- Improve a contract in a way that cannot disadvantage a hunter, applied
--- at once with no approval (§12.1). Reward increases go through
--- addEscrow; these are the non-monetary improvements.
---@return boolean ok
---@return string|nil err
local improveUnlocked

function Amendments.improve(actor, contractId, kind, payload)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if not CB.ADDITIVE[kind] then return false, CB.ERR.INVALID_INPUT end
    -- Lowering the penalty cuts stakes, and an acceptance stakes: one at a
    -- time per contract (Contracts.serialized). Two cuts side by side each
    -- wrote an owed line and only one lowered the stake, and a crash between
    -- them had boot pay both; a cut beside an acceptance skipped the stake
    -- it was taking and left it staked at the old figure.
    --
    -- Raising the bonus too. Each raise prices its top-up from the percent it
    -- read, and two at once both read the old one: a double tap of 10 to 20
    -- and 10 to 30 took both top-ups, 40 points of escrow, and showed
    -- whichever percent was written last.
    if kind == CB.AMENDMENT.LOWER_PENALTY or kind == CB.AMENDMENT.RAISE_BONUS then
        return Contracts.serialized({ 'contract:' .. contractId },
            improveUnlocked, actor, contractId, kind, payload)
    end
    return improveUnlocked(actor, contractId, kind, payload)
end

improveUnlocked = function(actor, contractId, kind, payload)
    -- What this call changes, and only that, is written (setContractFields).
    local fields = {}

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.BAD_STATE end

    payload = type(payload) == 'table' and payload or {}

    -- Raising the bonus TAKES ESCROW, so it answers to the same state rule
    -- as Amendments.addEscrow above, which refuses anything but ACTIVE and
    -- ACCEPTED. This function guarded only TERMINAL, so COMPLETING was
    -- permitted — and COMPLETING is a contract mid-settlement, with
    -- Escrow.release walking its lines right now. A bonus line appended into
    -- that walk is a line that may or may not be paid depending on where the
    -- loop had got to, which is the exact race addEscrow's guard exists to
    -- prevent. Two doors to the same room and only one of them locked.
    --
    -- Extending the deadline is not in this class and is still allowed:
    -- COMPLETING can roll back to ACCEPTED when a settlement fails, and a
    -- longer deadline is then a straightforward benefit to the hunter.
    if kind == CB.AMENDMENT.RAISE_BONUS
        and contract.state ~= CB.STATE.ACTIVE
        and contract.state ~= CB.STATE.ACCEPTED then
        return false, CB.ERR.BAD_STATE
    end

    if kind == CB.AMENDMENT.EXTEND_DEADLINE then
        local seconds = Util.toPositive(payload.seconds, Config.Limits.ContractLifetimeSeconds)
        if not seconds then return false, CB.ERR.INVALID_INPUT end
        -- Against the deadline as it stands when written, not as this call
        -- read it: the expiry pass may have ended a pause in the meantime.
        local moved, was = Contracts.moveDeadline(contractId, function(current)
            local deadline = (current.deadline_at or os.time()) + seconds
            -- The absolute lifetime is a ceiling, not a suggestion.
            if current.expires_at and deadline > current.expires_at then
                deadline = current.expires_at
            end
            -- But never below where it stands. A banked pause can carry a
            -- deadline past the lifetime, and clamping that to the ceiling
            -- brought it in, under a hunter's stake, before refusing the
            -- extension as already at its limit.
            return math.max(current.deadline_at or 0, deadline)
        end)
        if not moved then return false, CB.ERR.LOCKED end
        -- Already at the ceiling: nothing moved. It answered "Deadline
        -- extended." and told every hunter the terms had improved, and the
        -- page went on offering an extension that did nothing each time.
        if was ~= nil and moved <= was then return false, CB.ERR.DEADLINE_AT_LIMIT end
        contract.deadline_at = moved

    elseif kind == CB.AMENDMENT.RAISE_BONUS then
        local percent = Util.toPositive(payload.percent, Config.Bonus.maxPercent)
        local was = contract.bonus_percent or 0
        if not percent or percent <= was then
            return false, CB.ERR.INVALID_INPUT
        end

        -- The difference is escrowed now, out of the creator's pocket,
        -- exactly as the original bonus was at creation.
        --
        -- This used to store the number and nothing else. The payout
        -- releases bonus escrow LINES, and no line grew — so raising the
        -- bonus notified every hunter that the client had improved the
        -- terms, showed them a bigger percentage, and paid them precisely
        -- what it would have paid before. Of all the amendments this is the
        -- one that applies with no approval, on the stated grounds that it
        -- can only benefit the hunter.
        -- Copied now: on the in-process store `contract` is the stored row,
        -- so a payout landing during the take would move this underneath us.
        local slotAtRead = contract.next_slot or 1

        local extra = Escrow.bonusTopUp(contractId, was, percent, slotAtRead)

        -- The same ceiling the rest of the escrow answers to. This path
        -- builds its lines itself rather than going through validate, so
        -- nothing else would stop it.
        local adding = 0
        for i = 1, #extra do adding = adding + (extra[i].amount or 0) end
        if Escrow.moneyValue(contractId) + adding > Config.MaxContractValue then
            return false, CB.ERR.INVALID_REWARD
        end

        -- And the LINE ceiling, which this path applied to nothing. Only the
        -- value was bounded, and a top-up appends one fresh derived line per
        -- unsettled money baseline every time it runs — so raising the bonus
        -- one percentage point at a time walked a contract to hundreds of
        -- rows while its total stayed exactly where it started. Nobody's
        -- money moved, which is why conservation never noticed; the cost is
        -- that Projection.listing reads every one of those rows, for every
        -- player who opens the board, for as long as the contract lives.
        --
        -- Counted the way Amendments.addEscrow counts: settled lines are not
        -- held, and neither are hunters' stakes.
        local held = 0
        for _, line in ipairs(Storage.readEscrow(contractId)) do
            if line.state ~= CB.ESCROW_STATE.SETTLED and line.portion ~= CB.PORTION.STAKE then
                held = held + 1
            end
        end
        if held + #extra > Config.Limits.MaxEscrowLines then
            return false, CB.ERR.INVALID_REWARD
        end

        if #extra == 0 then
            -- Nothing to take means nothing to pay: either the bonus was the
            -- creator's own figure rather than a percentage, or there is no
            -- unsettled money baseline left to derive from. Refused, rather
            -- than recorded as an improvement that improves nothing.
            return false, CB.ERR.INVALID_REWARD
        end

        local took, takeErr, ids = Escrow.take(actor, contractId, extra)
        if not took then return false, takeErr end

        local open, movedErr = keptOrReturned(actor, contractId, slotAtRead, ids)
        if not open then return false, movedErr end

        contract.bonus_percent = percent
        fields.bonus_percent = percent

    elseif kind == CB.AMENDMENT.LOWER_PENALTY then
        local amount = Util.toCount(payload.amount, Config.MaxContractValue)
        if not amount or amount >= (contract.penalty_amount or 0) then
            return false, CB.ERR.INVALID_INPUT
        end

        -- The reduction is paid OUT OF THE STAKE, never minted. Crediting the
        -- difference directly while leaving the escrow line whole would let a
        -- creator and a hunter raise and lower the penalty in a loop and
        -- print money with nothing behind it.
        --
        -- Each hunter's own line is the source of truth for what they staked:
        -- successive reductions, and hunters who joined at different figures,
        -- all settle correctly because the amount comes from their line.
        local lines = Storage.readEscrow(contractId)
        for i = 1, #lines do
            local line = lines[i]
            -- A stake already owed to someone belongs to them: a stake
            -- forfeited to an offline creator is still `held`, and refunding
            -- its difference to the hunter who forfeited it hands the
            -- creator's money back to the person who walked away.
            local claimedByOther = line.owed_to ~= nil and line.owed_to ~= line.staker

            -- And only a hunter still on the contract has a live stake —
            -- one part-way through accepting included, whose stake is as
            -- real as anybody's.
            local hunter = line.staker and Storage.readHunter(contractId, line.staker)
            local stillActive = Contracts.holds(hunter)

            if line.portion == CB.PORTION.STAKE
                and line.state == CB.ESCROW_STATE.HELD
                and not claimedByOther
                and stillActive
                and (line.amount or 0) > amount then

                -- Read out of the line before anything is written. On the
                -- in-process backend `line` IS the stored row rather than a
                -- copy of it, so the reduction below changes line.amount
                -- underneath us and any later read of it is the new value.
                local original = line.amount
                local returned = original - amount

                -- Owed first and lowered second, guarded on the line being
                -- exactly as read (a settlement landing in between is not
                -- undone), then handed over: to their pocket now if they are
                -- here, queued for them if not. Crediting them straight after
                -- lowering the stake — or, offline, minting an owed line after
                -- it — lost the difference to a crash in between.
                --
                -- Offline or online, the difference is theirs rather than
                -- left in the stake. Left in the stake it was described as
                -- "they get it back in full when the contract resolves",
                -- which held only for the endings that return a stake:
                -- walking away or running out of clock forfeits the whole
                -- line, so a hunter who happened to be offline when the
                -- client lowered the penalty to 500 forfeited the 2,000 they
                -- had staked (§3.6).
                local owedId, delivered = Escrow.reduceStake(contractId, line, amount,
                    'stake_reduced')
                if owedId then
                    Audit.financial('stake_reduced', line.staker, contractId,
                        { returned = returned, remaining = amount, owed = not delivered or nil })
                else
                    Audit.action('stake_reduction_skipped', line.staker, contractId,
                        { returned = returned, reason = 'stake_moved' })
                end
            end
        end

        contract.penalty_amount = amount
        fields.penalty_amount = amount

    else
        return false, CB.ERR.INVALID_INPUT
    end

    if next(fields) then Storage.setContractFields(contractId, fields) end
    Audit.action('contract_improved', actor.cid, contractId, { kind = kind })

    local people = participants(contract)
    for cid, role in pairs(people) do
        if role == 'hunter' then
            Notify.toCitizen(cid, 'Contract improved',
                'The client has improved the terms of a contract you hold.')
        end
    end
    pushOthers(contract, actor.cid, 'improved')

    return true
end

--------------------------------------------------------------------------
-- Material changes (§12.2)
--------------------------------------------------------------------------

--- Proposals on a contract that can still be answered.
---
--- The store's idea of "open" is the outcome field, which only the expiry
--- sweep changes, and the sweep runs on the main tick — so for up to a tick
--- after its time was up a proposal was still counted against the one open
--- slot a contract has, refusing the next proposal, and still drawn with
--- Agree and Decline that could only be refused. respond() already asked the
--- clock; the other two readers now ask it too.
---@param contractId string
---@return table[]
function Amendments.answerable(contractId)
    local now = os.time()
    local out = {}
    for _, proposal in ipairs(Storage.readOpenAmendments(contractId) or {}) do
        if now <= (proposal.expires_at or 0) then out[#out + 1] = proposal end
    end
    return out
end

--- The part of a proposal's validity that depends on the contract as it is.
---
--- sanitize() checks the shape of a payload and has no contract to check it
--- against, so anything that did depend on the contract was found out when
--- the other party pressed Agree — the refusal landing on the person who had
--- done nothing wrong, about a proposal both of them had been shown as
--- waiting on an answer. Asked at propose time, and again at apply time,
--- because the contract can move in between.
---@return boolean ok
---@return string|nil err
local function checkAgainst(contract, kind, payload)
    if kind == CB.AMENDMENT.REDUCE_REWARD then
        -- Only the LAST collection, and only one nobody is competing for:
        -- see apply() for why.
        local slots = contract.payout_slots or 1
        local slot = payload.slot
        if not slot or slot <= (contract.next_slot or 1) or slot ~= slots then
            return false, CB.ERR.INVALID_INPUT
        end
    elseif kind == CB.AMENDMENT.SHORTEN_DEADLINE then
        -- There has to be a deadline, and cutting it by this much has to
        -- leave some of it: as much as a cut may ever leave, told now
        -- rather than when everybody has agreed. A stopped clock has what
        -- it had when it stopped.
        local left = contract.deadline_at
            and contract.deadline_at - (contract.paused_since or os.time())
        if not left or left - (payload.seconds or 0) < Contracts.MIN_LEFT_AFTER_CUT then
            return false, CB.ERR.INVALID_INPUT
        end
    end
    return true
end

--- Propose a change that needs agreement. Returns the proposal, which is
--- inert until every participant approves.
---@return table|nil proposal
---@return string|nil err
function Amendments.propose(actor, contractId, kind, payload)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CB.ERR.INVALID_INPUT end
    if not Config.Amendments.Enabled then return nil, CB.ERR.BAD_STATE end
    -- A kind is a string or nothing at all. kind:upper() below threw for a
    -- missing or numeric kind, which reached the player as a server fault,
    -- printed a line to the console, and handed the request's allowance
    -- back — so a client could repeat it as fast as the flood guard allows.
    if type(kind) ~= 'string' then return nil, CB.ERR.INVALID_INPUT end
    if CB.ADDITIVE[kind] then return nil, CB.ERR.INVALID_INPUT end
    if not CB.AMENDMENT[kind:upper()] and not Amendments.isKnown(kind) then
        return nil, CB.ERR.INVALID_INPUT
    end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CB.ERR.NOT_FOUND end

    local people = participants(contract)
    if not people[actor.cid] then return nil, CB.ERR.NOT_PARTICIPANT end
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        return nil, CB.ERR.BAD_STATE
    end

    -- The target is never amendable: retargeting is a new contract (§12.3).
    -- A payload is a table or nothing. Indexed as one when it was a boolean
    -- or a number, this threw, and a thrown handler refunds its own rate
    -- limit, so it could be repeated at the flood guard's pace.
    if payload ~= nil and type(payload) ~= 'table' then return nil, CB.ERR.INVALID_INPUT end
    if payload and (payload.targetCid or payload.target) then
        return nil, CB.ERR.INVALID_INPUT
    end

    if #Amendments.answerable(contractId) >= Config.Amendments.MaxOpenPerContract then
        return nil, CB.ERR.LIMIT_REACHED
    end

    -- Only the fields this amendment kind actually uses are kept, each
    -- coerced. Storing the client's table verbatim would persist unbounded
    -- attacker-chosen data in a row nothing ever deletes.
    local clean, payloadErr = Amendments.sanitize(kind, payload, actor)
    if not clean then return nil, payloadErr end

    local fits, fitErr = checkAgainst(contract, kind, clean)
    if not fits then return nil, fitErr end

    -- Only the proposer's answer is recorded here. The set of people who
    -- must agree is recomputed when someone responds, so a hunter who joins
    -- afterwards is not silently bound by a vote they never cast, and one
    -- who leaves does not keep a veto over a contract they abandoned.
    local approvals = { [actor.cid] = true }

    -- Neither the id nor the expiry says when this was proposed, to the
    -- second: both reach every participant, and a proposal from an anonymous
    -- client is a moment that client was online (§14.32). See Util.randomId.
    local proposalId = Util.mintId(Util.randomId, 'am', Storage.readAmendment)
    if not proposalId then return nil, CB.ERR.BAD_STATE end

    local proposal = {
        id          = proposalId,
        contract_id = contractId,
        proposer    = actor.cid,
        kind        = kind,
        payload     = clean,
        approvals   = approvals,
        expires_at  = Util.roundClock(os.time() + Config.Amendments.ProposalExpirySeconds),
        outcome     = 'open',
    }
    Storage.writeAmendment(proposal)
    openContracts[contractId] = true

    for cid in pairs(people) do
        if cid ~= actor.cid then
            Notify.toCitizen(cid, 'Contract change proposed',
                'The other party has proposed a change to a contract you hold.')
            Notify.push(cid, 'proposal')
        end
    end

    Audit.action('amendment_proposed', actor.cid, contractId, { kind = kind })

    -- Nobody else has to agree — the client, on a contract nobody holds —
    -- so it is applied now, in this request. The page used to follow the
    -- proposal with an answer of its own, which spent a second request from
    -- the same rate-limit bucket: two proposals a few seconds apart and the
    -- answer was refused, leaving an open proposal the page never drew and
    -- that blocked the next one until it lapsed.
    local everyone = true
    for cid in pairs(people) do
        if not approvals[cid] then everyone = false end
    end
    if everyone then
        local _, err, outcome = Amendments.respond(actor, proposal.id, true)
        proposal.outcome = outcome or proposal.outcome
        proposal.error = err
        -- Nobody else can answer it, so left open it would only block the
        -- next one until it lapsed: closed, and made again.
        if outcome == 'busy' then
            proposal.outcome = 'failed'
            Storage.writeAmendment(proposal)
        end
    end
    return proposal
end

--- Open proposals on a contract, projected for one viewer.
---
--- The proposer is named by role rather than by citizen id, and an
--- anonymous hunter is named by their alias — a proposal is not a hole in
--- anonymity just because it carries a name field.
---@param actor table
---@param contractId string
---@return table[]|nil proposals
---@return string|nil err
function Amendments.openFor(actor, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CB.ERR.NOT_FOUND end

    local people = participants(contract)
    if not people[actor.cid] then return nil, CB.ERR.NOT_PARTICIPANT end

    local out = {}
    for _, proposal in ipairs(Amendments.answerable(contractId)) do
        -- Who must still answer. Recomputed from the current participants
        -- for the same reason respond() recomputes it: a hunter who joined
        -- after the proposal is not bound by a vote they never cast.
        local waiting = 0
        for cid in pairs(people) do
            if not proposal.approvals[cid] then waiting = waiting + 1 end
        end

        local proposerName
        if proposal.proposer == contract.creator_cid then
            proposerName = contract.anon_creator and 'The client' or contract.creator_name
        else
            local hunter = Storage.readHunter(contractId, proposal.proposer)
            proposerName = hunter and hunter.alias or 'An operative'
        end

        out[#out + 1] = {
            id        = proposal.id,
            kind      = proposal.kind,
            -- Only the fields sanitize kept, which is already the narrow
            -- set this kind of amendment reads.
            payload   = proposal.payload,
            proposer  = proposerName,
            mine      = proposal.proposer == actor.cid,
            answered  = proposal.approvals[actor.cid] == true,
            waiting   = waiting,
            expires   = proposal.expires_at,
        }
    end

    return out
end

--- Build a payload containing only what `apply` reads for this kind.
---@param actor table|nil the proposer, whose phone's word list a reason answers to
---@return table|nil clean
---@return string|nil err
function Amendments.sanitize(kind, payload, actor)
    if payload ~= nil and type(payload) ~= 'table' then return nil, CB.ERR.INVALID_INPUT end
    payload = payload or {}
    local clean = {}

    if kind == CB.AMENDMENT.SHORTEN_DEADLINE or kind == CB.AMENDMENT.EXTEND_DEADLINE then
        clean.seconds = Util.toPositive(payload.seconds, Config.Limits.ContractLifetimeSeconds)
        if not clean.seconds then return nil, CB.ERR.INVALID_INPUT end

    elseif kind == CB.AMENDMENT.CHANGE_MODE then
        if payload.mode ~= CB.MODE.COMPETITIVE and payload.mode ~= CB.MODE.EXCLUSIVE then
            return nil, CB.ERR.INVALID_INPUT
        end
        clean.mode = payload.mode

    elseif kind == CB.AMENDMENT.CHANGE_REASON then
        -- Held to every rule a placed or edited reason answers to — the
        -- mode, the length, the digit cap, the banned patterns and the
        -- phone's own word list — by the same function. Length and digits
        -- alone let an agreed change put a link on the board, or free text
        -- on a server that only takes presets.
        --
        -- A server that shows no reason has none to change.
        if Config.Reason.Mode ~= 'freetext' and Config.Reason.Mode ~= 'preset' then
            return nil, CB.ERR.INVALID_INPUT
        end
        local reason, reasonErr = Contracts.reasonFor(actor or {}, {
            reason = payload.reason, reasonPreset = payload.reasonPreset,
        })
        if reasonErr or not reason or reason == '' then
            return nil, reasonErr or CB.ERR.INVALID_INPUT
        end
        clean.reason = reason

    elseif kind == CB.AMENDMENT.RAISE_PENALTY or kind == CB.AMENDMENT.LOWER_PENALTY then
        clean.amount = Util.toCount(payload.amount, Config.MaxContractValue)
        if not clean.amount then return nil, CB.ERR.INVALID_INPUT end
        clean.raise = (kind == CB.AMENDMENT.RAISE_PENALTY) or nil

    elseif kind == CB.AMENDMENT.REDUCE_REWARD then
        clean.slot = Util.toPositive(payload.slot, Config.Limits.MaxPayoutSlots)
        if not clean.slot then return nil, CB.ERR.INVALID_INPUT end

    elseif kind == CB.AMENDMENT.CANCEL or kind == CB.AMENDMENT.WITHDRAW then
        -- No parameters.

    else
        return nil, CB.ERR.INVALID_INPUT
    end

    return clean
end

function Amendments.isKnown(kind)
    for _, value in pairs(CB.AMENDMENT) do
        if value == kind then return true end
    end
    return false
end

--- Approve or decline. A single decline ends the proposal; the contract
--- continues on its original terms.
---@return boolean ok
---@return string|nil err
---@return string|nil outcome
local respondUnlocked

--- Proposals with an answer being recorded in this process.
---
--- An answer reads the proposal, waits on the contract and its hunters, and
--- writes the proposal back with its own approval added. Two hunters
--- agreeing in the same instant each wrote back a copy holding only their
--- own approval, so the second write erased the first: both were told the
--- change was waiting on the other, and it expired unapplied though
--- everybody had agreed. One answer per proposal at a time; the other is
--- told somebody got there first and can answer again.
local responding = {}

function Amendments.respond(actor, amendmentId, approve)
    amendmentId = Util.toId(amendmentId)
    if not amendmentId then return false, CB.ERR.INVALID_INPUT end
    if responding[amendmentId] then return false, CB.ERR.LOCKED end
    responding[amendmentId] = true
    local ok, a, b, c = pcall(respondUnlocked, actor, amendmentId, approve)
    responding[amendmentId] = nil
    if not ok then error(a, 0) end
    return a, b, c
end

respondUnlocked = function(actor, amendmentId, approve)

    local proposal = Storage.readAmendment(amendmentId)
    if not proposal or proposal.outcome ~= 'open' then return false, CB.ERR.NOT_FOUND end

    if os.time() > proposal.expires_at then
        proposal.outcome = 'expired'
        Storage.writeAmendment(proposal)
        return false, CB.ERR.BAD_STATE, 'expired'
    end

    local contract = Storage.readContract(proposal.contract_id)
    if not contract then return false, CB.ERR.NOT_FOUND end

    --- The contract has to still be live.
    ---
    --- This was not checked anywhere on the answering path: respond checked
    --- the PROPOSAL's expiry and apply checked only that the contract
    --- existed. So a proposal left open while the contract completed, was
    --- cancelled, expired or was bought out could then be agreed, and
    --- apply() ran on a finished contract — reporting "applied" to both
    --- parties and writing the change into the stored row. A shortened
    --- deadline landed on a cancelled contract; raise_penalty would set a
    --- stake figure on a closed one.
    ---
    --- No money moved, and the reason it did not is an accident rather than
    --- a rule: reduce_reward releases escrow, and the release found nothing
    --- because finalise had already settled every line. One ordering change
    --- away from paying out of a contract that had ended.
    ---
    --- Closed out rather than merely refused. The contract it belongs to
    --- will never be live again, so leaving the proposal open would leave
    --- both parties a button that can only ever fail.
    if CB.TERMINAL[contract.state] then
        proposal.outcome = 'stale'
        Storage.writeAmendment(proposal)
        Audit.action('amendment_stale', actor.cid, proposal.contract_id,
            { kind = proposal.kind, state = contract.state })
        return false, CB.ERR.ALREADY_SETTLED, 'stale'
    end

    -- Live participants, not the set captured when the proposal was made.
    local people = participants(contract)
    if not people[actor.cid] then return false, CB.ERR.NOT_PARTICIPANT end

    if not approve then
        proposal.outcome = 'declined'
        proposal.declined_by = actor.cid
        Storage.writeAmendment(proposal)
        Audit.action('amendment_declined', actor.cid, proposal.contract_id, { kind = proposal.kind })
        Notify.toCitizen(proposal.proposer, 'Change declined',
            'Your proposed contract change was declined. The original terms stand.')
        pushOthers(contract, actor.cid, 'proposal')
        return true, nil, 'declined'
    end

    proposal.approvals[actor.cid] = true

    for cid in pairs(people) do
        if not proposal.approvals[cid] then
            Storage.writeAmendment(proposal)
            -- Who is still to answer changed, and the panels say so.
            pushOthers(contract, actor.cid, 'proposal')
            return true, nil, 'pending'
        end
    end

    local ok, err = Amendments.apply(proposal)
    -- Busy is "not this instant", not "no": the proposal stays open and the
    -- answer can be given again.
    if not ok and err == CB.ERR.BUSY then return false, err, 'busy' end
    proposal.outcome = ok and 'applied' or 'failed'
    proposal.error = err
    Storage.writeAmendment(proposal)

    -- The proposer is told too. Only the person who pressed Agree saw the
    -- refusal, so the one who asked for the change was left believing it
    -- was still waiting on an answer.
    if not ok and proposal.proposer ~= actor.cid then
        Notify.toCitizen(proposal.proposer, 'Change not made',
            'Your proposed contract change was agreed, but the contract had '
            .. 'moved on and it no longer applies. The terms are unchanged.')
    end
    -- An applied change pushes from apply, with the contract as it now is.
    if not ok then pushOthers(contract, actor.cid, 'proposal') end

    return ok, err, proposal.outcome
end

local applyUnlocked

--- Apply an approved proposal. Each kind is handled explicitly; an unknown
--- kind fails rather than falling through to something permissive.
---
--- A change to the penalty or the mode waits for no acceptance in flight
--- on the contract (Contracts.serialized): who is on it decides whether it
--- may be applied at all.
function Amendments.apply(proposal)
    local kind = proposal.kind
    if kind == CB.AMENDMENT.RAISE_PENALTY or kind == CB.AMENDMENT.LOWER_PENALTY
        or kind == CB.AMENDMENT.CHANGE_MODE then
        return Contracts.serialized({ 'contract:' .. tostring(proposal.contract_id) },
            applyUnlocked, proposal)
    end
    return applyUnlocked(proposal)
end

applyUnlocked = function(proposal)
    local fields = {}
    local contract = Storage.readContract(proposal.contract_id)
    if not contract then return false, CB.ERR.NOT_FOUND end
    local kind, payload = proposal.kind, proposal.payload

    -- Set by any branch that takes escrow back out of the contract.
    local reclamp = false

    local fits, fitErr = checkAgainst(contract, kind, payload)
    if not fits then return false, fitErr end

    -- Only shortening. Extending is additive — it can only help whoever is
    -- hunting — so propose() refuses it and the creator applies it directly
    -- through improve(), which already moves the deadline by the amount and
    -- holds it to the contract's lifetime.
    if kind == CB.AMENDMENT.SHORTEN_DEADLINE then
        local seconds = Util.toPositive(payload.seconds, Config.Limits.ContractLifetimeSeconds)
        if not seconds then return false, CB.ERR.INVALID_INPUT end

        -- An amount of time to move the deadline BY, not the deadline to
        -- move it to. This set it to now + seconds, while everything either
        -- party is shown is relative — the box reads "Cut it short by", its
        -- hint says when it would then run out, and the other party is asked
        -- to agree to "Shorten the deadline by 30 minutes". Agreed on a
        -- contract with three hours left, that left thirty minutes in total.
        --
        -- checkAgainst() above has already refused a cut longer than what is
        -- left now, including time that passed while it waited for an answer.
        -- And not over anybody who did not agree to it: a hunter who took
        -- the contract while this was being decided is put back on the
        -- deadline they accepted (Contracts.bringDeadlineIn).
        local moved, moveErr = Contracts.bringDeadlineIn(proposal.contract_id, function(current)
            return (current.deadline_at or os.time()) - seconds
        end, proposal.approvals)
        if not moved then return false, moveErr end
        contract.deadline_at = moved

    elseif kind == CB.AMENDMENT.CHANGE_MODE then
        local mode = payload.mode == CB.MODE.COMPETITIVE and CB.MODE.COMPETITIVE or CB.MODE.EXCLUSIVE
        if mode == CB.MODE.EXCLUSIVE then
            -- Exclusive means one hunter. Switching while several hold it
            -- would leave a contract in a state its own rules forbid.
            local active = 0
            local hunters = Storage.readHunters(proposal.contract_id)
            for i = 1, #hunters do
                if Contracts.holds(hunters[i]) then active = active + 1 end
            end
            if active > 1 then return false, CB.ERR.BAD_STATE end
        end
        contract.mode = mode
        fields.mode = mode

    elseif kind == CB.AMENDMENT.CHANGE_REASON then
        local reason = Util.sanitizeText(payload.reason, Config.Reason.MaxLength)
        if not reason then return false, CB.ERR.INVALID_INPUT end
        contract.reason = reason
        fields.reason = reason

    elseif kind == CB.AMENDMENT.RAISE_PENALTY or kind == CB.AMENDMENT.LOWER_PENALTY then
        -- A penalty is only real if it was staked (§3.6). Raising the figure
        -- after a hunter has staked the old one would display a penalty
        -- nobody has put up, so it is only allowed while the contract is
        -- unheld — a hunter stakes whatever it says when they accept.
        local hunters = Storage.readHunters(proposal.contract_id)
        for i = 1, #hunters do
            if Contracts.holds(hunters[i]) then return false, CB.ERR.BAD_STATE end
        end
        -- Through the same clamp creation uses. An amendment that skipped
        -- it would be the way back to an uncapped stake: raise_penalty is
        -- only allowed on an unheld contract, so the figure it leaves is
        -- what the next hunter is asked to put up.
        contract.penalty_amount = Contracts.clampPenalty(payload.amount,
            Escrow.moneyValue(proposal.contract_id))
        fields.penalty_amount = contract.penalty_amount

    elseif kind == CB.AMENDMENT.CANCEL or kind == CB.AMENDMENT.WITHDRAW then
        -- Agreed cancellation: escrow returns to the creator in full.
        return Contracts.resolve(proposal.contract_id, CB.STATE.CANCELLED,
            contract.creator_cid, nil, 'cancelled_by_agreement')

    elseif kind == CB.AMENDMENT.REDUCE_REWARD then
        -- Reducing a reward means returning part of the escrow to the
        -- creator. Only an unclaimed slot may be given back.
        -- Only a slot nobody is competing for yet may be withdrawn. Emptying
        -- the live slot would leave a claimable payout funded with nothing.
        --
        -- checkAgainst() above holds all three rules — a later collection,
        -- the last one, and one that exists — so they are asked the same way
        -- at propose time and here.
        local slots = contract.payout_slots or 1
        local slot = payload.slot

        -- Only the LAST one may go, and the count comes down with it.
        --
        -- This released the escrow and left payout_slots where it was, so the
        -- emptied collection stayed one the contract sold: next_slot walks
        -- onto it, the board shows the contract at nothing for the current
        -- collection, and a hunter who eliminates the target for it is paid
        -- out of an empty slot. The app's own dialog already promised
        -- otherwise — "Collection N of M goes back to the client. M-1 would
        -- remain."
        --
        -- The last one, because the slots are a sequence next_slot walks:
        -- taking one out of the middle would renumber every slot after it and
        -- orphan the escrow filed against their old numbers.

        -- The count first, guarded on it still being what this read: every
        -- other writer carries a copy, and a count written back from one
        -- put the collection back on sale after its escrow had gone home.
        -- A crash between the two leaves that escrow on a collection the
        -- contract no longer sells, which its ending returns to the client.
        if not Storage.reduceSlots(proposal.contract_id, slots) then
            return false, CB.ERR.LOCKED
        end
        Escrow.release(proposal.contract_id, contract.creator_cid, { slot = slot }, 'reward_reduced')
        contract.payout_slots = slots - 1
        -- Applied after the write below, not here: on a durable backend the
        -- contract table this function is holding is a copy, so re-pricing
        -- it now and writing that copy afterwards would put the unclamped
        -- figures straight back on top. On the in-process store it is the
        -- stored row itself and either order works, which is exactly why
        -- getting it wrong would have gone unnoticed.
        reclamp = true

    else
        return false, CB.ERR.INVALID_INPUT
    end

    if next(fields) then Storage.setContractFields(proposal.contract_id, fields) end

    -- The buyout premium and the failure stake are both multiples of the
    -- escrow, and reduce_reward just took a slot out of it. Re-priced for
    -- the same reason withdrawReward does it: a clamp that holds only at
    -- the moment the figure is set is a clamp with a door beside it.
    if reclamp then Contracts.reclampToEscrow(proposal.contract_id, proposal.proposer) end

    Audit.action('amendment_applied', proposal.proposer, proposal.contract_id, { kind = kind })

    local people = participants(contract)
    for cid in pairs(people) do
        Notify.toCitizen(cid, 'Contract amended', 'A contract you hold has been changed by agreement.')
        Notify.push(cid, 'amended')
    end

    return true
end

--- Expire proposals nobody answered. Driven by the main tick.
function Amendments.expire()
    local expired = 0
    local now = os.time()

    for contractId in pairs(openContracts) do
        local open = Storage.readOpenAmendments(contractId)
        local remaining = 0
        local closed = false
        for j = 1, #open do
            if now > open[j].expires_at then
                open[j].outcome = 'expired'
                Storage.writeAmendment(open[j])
                expired = expired + 1
                closed = true
            else
                remaining = remaining + 1
            end
        end
        if remaining == 0 then openContracts[contractId] = nil end
        -- An expired proposal was still drawn as answerable on every page
        -- that had it open.
        if closed then pushOthers(Storage.readContract(contractId), nil, 'proposal') end
    end

    return expired
end

--- Rebuild the tracking set after a restart, when proposals may already
--- exist in storage that this process never saw created.
function Amendments.reindex()
    openContracts = {}
    local contracts = Storage.allContracts()
    for i = 1, #contracts do
        if #Storage.readOpenAmendments(contracts[i].id) > 0 then
            openContracts[contracts[i].id] = true
        end
    end
    return openContracts
end

return Amendments
