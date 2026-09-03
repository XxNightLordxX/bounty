--- Contract amendments (§12).
---
--- Additive changes apply immediately because they can only benefit the
--- hunter. Anything that could disadvantage the other side is a proposal
--- needing approval from the creator and every accepted hunter. The target of
--- a contract is never amendable.

local Util = require_shared('util')

local Amendments = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify

function Amendments.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
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

    local approvals = {}
    for cid in pairs(people) do approvals[cid] = false end
    approvals[actor.cid] = true  -- proposing is approving

    local proposal = {
        id          = Storage.nextId('am'),
        contract_id = contractId,
        proposer    = actor.cid,
        kind        = kind,
        payload     = Util.copy(payload) or {},
        approvals   = approvals,
        expires_at  = os.time() + Config.Amendments.ProposalExpirySeconds,
        outcome     = 'open',
    }
    Storage.writeAmendment(proposal)

    for cid in pairs(people) do
        if cid ~= actor.cid then
            Notify.toCitizen(cid, 'Contract change proposed',
                'The other party has proposed a change to a contract you hold.')
        end
    end

    Audit.action('amendment_proposed', actor.cid, contractId, { kind = kind })
    return proposal
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

    if proposal.approvals[actor.cid] == nil then return false, CB.ERR.NOT_PARTICIPANT end

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

    for _, approved in pairs(proposal.approvals) do
        if not approved then
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
        contract.mode = mode

    elseif kind == CB.AMENDMENT.CHANGE_REASON then
        local reason = Util.sanitizeText(payload.reason, Config.Reason.MaxLength)
        if not reason then return false, CB.ERR.INVALID_INPUT end
        contract.reason = reason

    elseif kind == CB.AMENDMENT.RAISE_PENALTY or kind == CB.AMENDMENT.LOWER_PENALTY then
        contract.penalty_amount = Util.toCount(payload.amount, Config.MaxContractValue) or 0

    elseif kind == CB.AMENDMENT.CANCEL or kind == CB.AMENDMENT.WITHDRAW then
        -- Agreed cancellation: escrow returns to the creator in full.
        return Contracts.resolve(proposal.contract_id, CB.STATE.CANCELLED,
            contract.creator_cid, nil, 'cancelled_by_agreement')

    elseif kind == CB.AMENDMENT.REDUCE_REWARD then
        -- Reducing a reward means returning part of the escrow to the
        -- creator. Only an unclaimed slot may be given back.
        local slot = Util.toPositive(payload.slot, Config.Limits.MaxPayoutSlots)
        if not slot or slot < (contract.next_slot or 1) then return false, CB.ERR.INVALID_INPUT end
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
    local contracts = Storage.allContracts()
    for i = 1, #contracts do
        local open = Storage.readOpenAmendments(contracts[i].id)
        for j = 1, #open do
            if os.time() > open[j].expires_at then
                open[j].outcome = 'expired'
                Storage.writeAmendment(open[j])
                expired = expired + 1
            end
        end
    end
    return expired
end

return Amendments
