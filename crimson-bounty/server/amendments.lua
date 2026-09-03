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

local function participants(contract)
    local out = { [contract.creator_cid] = 'creator' }
    local hunters = Storage.readHunters(contract.id)
    for i = 1, #hunters do
        if hunters[i].state == 'active' then out[hunters[i].hunter_cid] = 'hunter' end
    end
    return out
end

--------------------------------------------------------------------------
-- Additive changes (§12.1)
--------------------------------------------------------------------------

--- Add value to a live contract. Applies at once; escrow is taken through
--- the same path as creation, so the added value is as safe as the original.
---@return boolean ok
---@return string|nil err
function Amendments.addEscrow(actor, contractId, rewardSpec)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if contract.state ~= CB.STATE.ACTIVE and contract.state ~= CB.STATE.ACCEPTED then
        return false, CB.ERR.BAD_STATE
    end

    local lines, err = Escrow.validate(actor, rewardSpec)
    if not lines then return false, err end

    -- Added value lands on the slot currently being competed for, so it is
    -- unambiguous which collection it sweetens.
    local slot = contract.next_slot or 1
    for i = 1, #lines do lines[i].slot = slot end

    local ok
    ok, err = Escrow.take(actor, contractId, lines)
    if not ok then return false, err end

    Audit.financial('escrow_added', actor.cid, contractId, { lines = #lines, slot = slot })

    local people = participants(contract)
    for cid, role in pairs(people) do
        if role == 'hunter' then
            Notify.toCitizen(cid, 'Contract improved',
                'The client has increased the reward on a contract you hold.')
        end
    end

    return true
end

--- Improve a contract in a way that cannot disadvantage a hunter, applied
--- at once with no approval (§12.1). Reward increases go through
--- addEscrow; these are the non-monetary improvements.
---@return boolean ok
---@return string|nil err
function Amendments.improve(actor, contractId, kind, payload)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end
    if not CB.ADDITIVE[kind] then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if contract.creator_cid ~= actor.cid then return false, CB.ERR.NOT_PARTICIPANT end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.BAD_STATE end

    payload = type(payload) == 'table' and payload or {}

    if kind == CB.AMENDMENT.EXTEND_DEADLINE then
        local seconds = Util.toPositive(payload.seconds, Config.Limits.ContractLifetimeSeconds)
        if not seconds then return false, CB.ERR.INVALID_INPUT end
        contract.deadline_at = (contract.deadline_at or os.time()) + seconds
        -- The absolute lifetime is a ceiling, not a suggestion.
        if contract.expires_at and contract.deadline_at > contract.expires_at then
            contract.deadline_at = contract.expires_at
        end

    elseif kind == CB.AMENDMENT.RAISE_BONUS then
        local percent = Util.toPositive(payload.percent, Config.Bonus.maxPercent)
        if not percent or percent <= (contract.bonus_percent or 0) then
            return false, CB.ERR.INVALID_INPUT
        end
        contract.bonus_percent = percent

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

            -- And only a hunter still on the contract has a live stake.
            local hunter = line.staker and Storage.readHunter(contractId, line.staker)
            local stillActive = hunter and hunter.state == 'active'

            if line.portion == CB.PORTION.STAKE
                and line.state == CB.ESCROW_STATE.HELD
                and not claimedByOther
                and stillActive
                and (line.amount or 0) > amount then

                local returned = line.amount - amount
                local staker = Identity.byCitizenId(line.staker)

                if staker then
                    -- Guarded write: the line must still be exactly as it
                    -- was read. Writing a caller-held copy back would let a
                    -- settlement that landed in between be undone, putting a
                    -- settled line back on the board as claimable.
                    local reduced = Storage.setEscrowAmount(
                        line.id, CB.ESCROW_STATE.HELD, amount, line.amount)

                    if reduced then
                        -- Back to the account it came from, not always bank.
                        staker.player.Functions.AddMoney(line.source, returned)
                        Audit.financial('stake_reduced', line.staker, contractId,
                            { returned = returned, remaining = amount })
                    end
                else
                    -- The staker is offline: their stake stays as it is
                    -- rather than being reduced against a player who cannot
                    -- be paid. They keep the higher stake and get it back in
                    -- full when the contract resolves.
                    Audit.action('stake_reduction_deferred', line.staker, contractId, {})
                end
            end
        end

        contract.penalty_amount = amount

    else
        return false, CB.ERR.INVALID_INPUT
    end

    Storage.writeContract(contract)
    Audit.action('contract_improved', actor.cid, contractId, { kind = kind })

    local people = participants(contract)
    for cid, role in pairs(people) do
        if role == 'hunter' then
            Notify.toCitizen(cid, 'Contract improved',
                'The client has improved the terms of a contract you hold.')
        end
    end

    return true
end

--------------------------------------------------------------------------
-- Material changes (§12.2)
--------------------------------------------------------------------------

--- Propose a change that needs agreement. Returns the proposal, which is
--- inert until every participant approves.
---@return table|nil proposal
---@return string|nil err
function Amendments.propose(actor, contractId, kind, payload)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CB.ERR.INVALID_INPUT end
    if not Config.Amendments.Enabled then return nil, CB.ERR.BAD_STATE end
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
    if payload and (payload.targetCid or payload.target) then
        return nil, CB.ERR.INVALID_INPUT
    end

    if #Storage.readOpenAmendments(contractId) >= Config.Amendments.MaxOpenPerContract then
        return nil, CB.ERR.LIMIT_REACHED
    end

    -- Only the fields this amendment kind actually uses are kept, each
    -- coerced. Storing the client's table verbatim would persist unbounded
    -- attacker-chosen data in a row nothing ever deletes.
    local clean, payloadErr = Amendments.sanitize(kind, payload)
    if not clean then return nil, payloadErr end

    -- Only the proposer's answer is recorded here. The set of people who
    -- must agree is recomputed when someone responds, so a hunter who joins
    -- afterwards is not silently bound by a vote they never cast, and one
    -- who leaves does not keep a veto over a contract they abandoned.
    local approvals = { [actor.cid] = true }

    local proposal = {
        id          = Storage.nextId('am'),
        contract_id = contractId,
        proposer    = actor.cid,
        kind        = kind,
        payload     = clean,
        approvals   = approvals,
        expires_at  = os.time() + Config.Amendments.ProposalExpirySeconds,
        outcome     = 'open',
    }
    Storage.writeAmendment(proposal)
    openContracts[contractId] = true

    for cid in pairs(people) do
        if cid ~= actor.cid then
            Notify.toCitizen(cid, 'Contract change proposed',
                'The other party has proposed a change to a contract you hold.')
        end
    end

    Audit.action('amendment_proposed', actor.cid, contractId, { kind = kind })
    return proposal
end

--- Build a payload containing only what `apply` reads for this kind.
---@return table|nil clean
---@return string|nil err
function Amendments.sanitize(kind, payload)
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
        clean.reason = Util.sanitizeText(payload.reason, Config.Reason.MaxLength)
        if not clean.reason then return nil, CB.ERR.INVALID_INPUT end
        if Util.digitCount(clean.reason) > Config.Reason.MaxDigits then
            return nil, CB.ERR.INVALID_INPUT
        end

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
function Amendments.respond(actor, amendmentId, approve)
    amendmentId = Util.toId(amendmentId)
    if not amendmentId then return false, CB.ERR.INVALID_INPUT end

    local proposal = Storage.readAmendment(amendmentId)
    if not proposal or proposal.outcome ~= 'open' then return false, CB.ERR.NOT_FOUND end

    if os.time() > proposal.expires_at then
        proposal.outcome = 'expired'
        Storage.writeAmendment(proposal)
        return false, CB.ERR.BAD_STATE, 'expired'
    end

    local contract = Storage.readContract(proposal.contract_id)
    if not contract then return false, CB.ERR.NOT_FOUND end

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
        return true, nil, 'declined'
    end

    proposal.approvals[actor.cid] = true

    for cid in pairs(people) do
        if not proposal.approvals[cid] then
            Storage.writeAmendment(proposal)
            return true, nil, 'pending'
        end
    end

    local ok, err = Amendments.apply(proposal)
    proposal.outcome = ok and 'applied' or 'failed'
    proposal.error = err
    Storage.writeAmendment(proposal)

    return ok, err, proposal.outcome
end

--- Apply an approved proposal. Each kind is handled explicitly; an unknown
--- kind fails rather than falling through to something permissive.
function Amendments.apply(proposal)
    local contract = Storage.readContract(proposal.contract_id)
    if not contract then return false, CB.ERR.NOT_FOUND end
    local kind, payload = proposal.kind, proposal.payload

    if kind == CB.AMENDMENT.SHORTEN_DEADLINE or kind == CB.AMENDMENT.EXTEND_DEADLINE then
        local seconds = Util.toPositive(payload.seconds, Config.Limits.ContractLifetimeSeconds)
        if not seconds then return false, CB.ERR.INVALID_INPUT end
        contract.deadline_at = os.time() + seconds

    elseif kind == CB.AMENDMENT.CHANGE_MODE then
        local mode = payload.mode == CB.MODE.COMPETITIVE and CB.MODE.COMPETITIVE or CB.MODE.EXCLUSIVE
        if mode == CB.MODE.EXCLUSIVE then
            -- Exclusive means one hunter. Switching while several hold it
            -- would leave a contract in a state its own rules forbid.
            local active = 0
            local hunters = Storage.readHunters(proposal.contract_id)
            for i = 1, #hunters do
                if hunters[i].state == 'active' then active = active + 1 end
            end
            if active > 1 then return false, CB.ERR.BAD_STATE end
        end
        contract.mode = mode

    elseif kind == CB.AMENDMENT.CHANGE_REASON then
        local reason = Util.sanitizeText(payload.reason, Config.Reason.MaxLength)
        if not reason then return false, CB.ERR.INVALID_INPUT end
        contract.reason = reason

    elseif kind == CB.AMENDMENT.RAISE_PENALTY or kind == CB.AMENDMENT.LOWER_PENALTY then
        -- A penalty is only real if it was staked (§3.6). Raising the figure
        -- after a hunter has staked the old one would display a penalty
        -- nobody has put up, so it is only allowed while the contract is
        -- unheld — a hunter stakes whatever it says when they accept.
        local hunters = Storage.readHunters(proposal.contract_id)
        for i = 1, #hunters do
            if hunters[i].state == 'active' then return false, CB.ERR.BAD_STATE end
        end
        contract.penalty_amount = Util.toCount(payload.amount, Config.MaxContractValue) or 0

    elseif kind == CB.AMENDMENT.CANCEL or kind == CB.AMENDMENT.WITHDRAW then
        -- Agreed cancellation: escrow returns to the creator in full.
        return Contracts.resolve(proposal.contract_id, CB.STATE.CANCELLED,
            contract.creator_cid, nil, 'cancelled_by_agreement')

    elseif kind == CB.AMENDMENT.REDUCE_REWARD then
        -- Reducing a reward means returning part of the escrow to the
        -- creator. Only an unclaimed slot may be given back.
        -- Only a slot nobody is competing for yet may be withdrawn. Emptying
        -- the live slot would leave a claimable payout funded with nothing.
        local slot = Util.toPositive(payload.slot, Config.Limits.MaxPayoutSlots)
        if not slot or slot <= (contract.next_slot or 1) then return false, CB.ERR.INVALID_INPUT end
        if slot > (contract.payout_slots or 1) then return false, CB.ERR.INVALID_INPUT end
        Escrow.release(proposal.contract_id, contract.creator_cid, { slot = slot }, 'reward_reduced')

    else
        return false, CB.ERR.INVALID_INPUT
    end

    Storage.writeContract(contract)
    Audit.action('amendment_applied', proposal.proposer, proposal.contract_id, { kind = kind })

    local people = participants(contract)
    for cid in pairs(people) do
        Notify.toCitizen(cid, 'Contract amended', 'A contract you hold has been changed by agreement.')
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
        for j = 1, #open do
            if now > open[j].expires_at then
                open[j].outcome = 'expired'
                Storage.writeAmendment(open[j])
                expired = expired + 1
            else
                remaining = remaining + 1
            end
        end
        if remaining == 0 then openContracts[contractId] = nil end
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
