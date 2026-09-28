--- In-process storage. The reference implementation of the storage interface:
--- the mysql and json backends must behave identically to this one.
---
--- Holds no durable escrow, so main.lua refunds everything on resource stop
--- and cancels a creator's contracts when they disconnect (§10.3).

local Memory = {}

local db

function Memory.open()
    db = {
        contracts = {}, escrow = {}, hunters = {}, amendments = {},
        messages = {}, ledger = {}, pending = {}, audit = {}, reveals = {}, seq = 0,
    }
    return true
end

function Memory.nextId(prefix)
    db.seq = db.seq + 1
    return string.format('%s%08d', prefix, db.seq)
end

--------------------------------------------------------------------------
-- Contracts
--------------------------------------------------------------------------

--- Persist a contract's fields. State is deliberately NOT written here:
--- it changes only through compareSetContractState, so a caller holding a
--- copy read before a transition cannot revert it (§9.7).
--- The buyout queue columns, which move ONLY through setBailoutQueue.
---
--- Any caller that reads a contract, works, and writes it back carries the
--- queue fields it read. Between that read and that write a target can pay for
--- a buyout — on mysql every read is an await, so another handler runs in the
--- gap — and the stale copy then lands on top of it: the premium charged, the
--- queue erased, nothing that will ever settle or refund it. Eight callers
--- have that read-work-write shape. The codebase had already found this hazard
--- twice and fixed it for one of them (advanceSlot, for claimSlot); the queue
--- itself got nothing. So these fields leave writeContract entirely, the way
--- `state` moves only through compareSetContractState.
local BAILOUT_QUEUE = {
    'bailout_queued_at', 'bailout_paid_by', 'bailout_paid_amount',
    'bailout_paid_account', 'bailout_attempts',
}

--- The payout counters, which move ONLY through advanceSlot. A copy read
--- before a claim and written after it would otherwise put the collection
--- just paid back on sale.
local SLOT_COUNTERS = { 'next_slot', 'slots_claimed', 'payout_slots' }

--- The clock: moves only through setDeadline, startPause, endPause and
--- resetClock, never through writeContract. Every other writer carries a
--- copy read before its own awaits, and writing these back undid a pause the
--- expiry pass had just started, or an extension the client had just made.
local CLOCK = { 'deadline_at', 'paused_ms', 'paused_since' }

function Memory.writeContract(contract)
    local existing = db.contracts[contract.id]
    if existing and existing ~= contract then
        contract.state = existing.state
        for i = 1, #BAILOUT_QUEUE do
            contract[BAILOUT_QUEUE[i]] = existing[BAILOUT_QUEUE[i]]
        end
        for i = 1, #SLOT_COUNTERS do
            contract[SLOT_COUNTERS[i]] = existing[SLOT_COUNTERS[i]]
        end
        for i = 1, #CLOCK do
            contract[CLOCK[i]] = existing[CLOCK[i]]
        end
    end
    db.contracts[contract.id] = contract
    return true
end

--- Take the last collection off a contract, guarded on the count still
--- being the one the caller read.
--- End a contract as expired only if it is still due: past its lifetime,
--- or past a deadline whose clock is running. The expiry pass decides on
--- a read, and a deadline the client extended in the await after it was
--- expired all the same, forfeiting the stake of the hunter it was
--- extended for.
function Memory.expireIfDue(id, expected, next_, now, byLifetime)
    local c = db.contracts[id]
    if not c or c.state ~= expected then return false end
    if byLifetime then
        if not (c.expires_at and now > c.expires_at) then return false end
    elseif c.paused_since ~= nil or not (c.deadline_at and now > c.deadline_at) then
        return false
    end
    c.state = next_
    return true
end

--- Take the last collection off sale, guarded on everything the decision
--- rested on: the count, that the collection is still unclaimed, and that
--- no claim holds the contract. On the count alone, a claim landing between
--- the decision and this write advanced onto the very collection being
--- removed, and the contract was left selling a collection past its end.
function Memory.reduceSlots(id, expected)
    local c = db.contracts[id]
    if not c or (c.payout_slots or 1) ~= expected or expected <= 1 then return false end
    if (c.next_slot or 1) >= expected then return false end
    if c.state ~= 'active' and c.state ~= 'accepted' then return false end
    c.payout_slots = expected - 1
    return true
end

--- Set the deadline, guarded on it still being `expected` (nil: unguarded).
function Memory.setDeadline(id, expected, deadline)
    local c = db.contracts[id]
    if not c then return false end
    if expected ~= nil and c.deadline_at ~= expected then return false end
    c.deadline_at = deadline
    return true
end

--- Set a contract's reason and nothing else. An edit writing back the whole
--- row it read would put back every column somebody else changed meanwhile.
--- Write only the named fields of a contract. Every other writer used to
--- read the row, await, and write the whole copy back, undoing whatever
--- changed in between: a re-clamp of the buyout and stake, a bonus raise,
--- an ending's resolution. Only these columns, and never the state, the
--- slot counters, the clock or the buyout queue, which have their own.
local SETTABLE = { reason = true, mode = true, bonus_percent = true, bailout_amount = true,
    penalty_amount = true, resolved_at = true, resolution = true }
function Memory.setContractFields(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for k, v in pairs(fields) do
        if not SETTABLE[k] then error('setContractFields: not a settable field: ' .. tostring(k)) end
        c[k] = v
    end
    return true
end

function Memory.setReason(id, reason)
    local c = db.contracts[id]
    if not c then return false end
    c.reason = reason
    return true
end

--- Start a pause, unless one is already running.
function Memory.startPause(id, at)
    local c = db.contracts[id]
    if not c or c.paused_since ~= nil then return false end
    c.paused_since = at
    return true
end

--- End the pause that began at `since`, moving the deadline on by how long
--- it lasted. Relative, so it composes with a deadline changed meanwhile.
function Memory.endPause(id, since, seconds)
    local c = db.contracts[id]
    if not c or c.paused_since ~= since then return false end
    c.deadline_at = (c.deadline_at or 0) + seconds
    c.paused_ms = (c.paused_ms or 0) + seconds * 1000
    c.paused_since = nil
    return true
end

--- Staff: a new deadline and no pause.
function Memory.resetClock(id, deadline)
    local c = db.contracts[id]
    if not c then return false end
    c.deadline_at, c.paused_since = deadline, nil
    return true
end

--- Set or clear the buyout queue on one contract. nil clears it.
function Memory.setBailoutQueue(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for i = 1, #BAILOUT_QUEUE do
        c[BAILOUT_QUEUE[i]] = fields and fields[BAILOUT_QUEUE[i]] or nil
    end
    return true
end

function Memory.readContract(id)
    return db.contracts[id]
end

function Memory.allContracts()
    local out = {}
    for _, c in pairs(db.contracts) do out[#out + 1] = c end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts this player is involved in, as creator, target or hunter.
--- Callers used to fetch every contract and filter in Lua, which on a real
--- database is a full table scan per app request.
function Memory.contractsInvolving(cid)
    local seen, out = {}, {}

    for _, c in pairs(db.contracts) do
        if c.creator_cid == cid or c.target_cid == cid then
            seen[c.id] = true
            out[#out + 1] = c
        end
    end

    for _, h in pairs(db.hunters) do
        if h.hunter_cid == cid and not seen[h.contract_id] then
            local c = db.contracts[h.contract_id]
            if c then
                seen[c.id] = true
                out[#out + 1] = c
            end
        end
    end

    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts naming this player as target, whatever their state.
function Memory.contractsNaming(cid)
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.target_cid == cid then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts with a buyout waiting out its delay.
function Memory.queuedBailouts()
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.bailout_queued_at then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts created by this player.
function Memory.contractsBy(cid)
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.creator_cid == cid then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts created by any character on this account. The creator-side
--- limits belong to the player, not to whichever character they are on.
function Memory.contractsByAccount(account)
    local out = {}
    if account == nil then return out end
    for _, c in pairs(db.contracts) do
        if c.creator_account == account then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Advance the payout slot, only if it is still the one the caller acted on.
---
--- claimSlot used to write back the whole contract it had read at the top,
--- after several yielding reads. Anything written in between — a bailout
--- queuing, which is the target's money — was erased by that stale copy.
--- Only the two fields that actually change move here.
function Memory.advanceSlot(id, expectedSlot)
    local c = db.contracts[id]
    if not c or (c.next_slot or 1) ~= expectedSlot then return false end
    c.next_slot = expectedSlot + 1
    c.slots_claimed = (c.slots_claimed or 0) + 1
    return true
end

--- Conditional state write. Returns false when the contract is not in the
--- expected state, which is how two simultaneous actions are serialised
--- without either of them silently winning (§9.7).
function Memory.compareSetContractState(id, expected, next_)
    local c = db.contracts[id]
    if not c or c.state ~= expected then return false end
    c.state = next_
    return true
end

--------------------------------------------------------------------------
-- Escrow
--------------------------------------------------------------------------

--- Insert new lines, or update the mutable fields of existing ones. State
--- and amount are preserved from the stored row: they move only through the
--- guarded helpers, so a caller writing back a copy it read earlier cannot
--- undo a settlement that happened in between.
function Memory.writeEscrow(contractId, lines)
    for i = 1, #lines do
        local incoming = lines[i]
        local existing = db.escrow[incoming.id]
        if existing and existing ~= incoming then
            -- A separate copy of a line we already hold: take only the
            -- fields a caller is allowed to change.
            existing.owed_to = incoming.owed_to
            existing.releasing_to = incoming.releasing_to
        else
            db.escrow[incoming.id] = incoming
        end
    end
    return true
end

function Memory.readEscrow(contractId)
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.contract_id == contractId then out[#out + 1] = line end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function Memory.readEscrowLine(id)
    return db.escrow[id]
end

--- The compare-and-set that makes double release impossible (§14.3).
function Memory.claimEscrowLine(id, expected, next_)
    local line = db.escrow[id]
    if not line or line.state ~= expected then return false end
    line.state = next_
    return true
end

--- Change a line's amount only if it is still in the expected state and
--- still holds the amount the caller read. State is never written here:
--- it moves through claimEscrowLine alone.
function Memory.setEscrowAmount(id, expectedState, amount, expectedAmount)
    local line = db.escrow[id]
    if not line or line.state ~= expectedState then return false end
    if expectedAmount ~= nil and line.amount ~= expectedAmount then return false end
    line.amount = amount
    return true
end

--- Settle a line this caller holds.
---
--- Guarded on `releasing`, because both callers settle only after claiming
--- held -> releasing. Without the guard the write was `WHERE id = ?`: it
--- would settle a line something else had taken back — restart recovery
--- returning a stuck `releasing` line to `held`, or a second server
--- instance on the same database — which is a line paid twice and recorded
--- once.
function Memory.settleEscrowLine(id, recipientCid)
    local line = db.escrow[id]
    if not line or line.state ~= CB.ESCROW_STATE.RELEASING then return false end
    line.state = CB.ESCROW_STATE.SETTLED
    line.settled_to = recipientCid
    line.settled_at = os.time()
    return true
end

--------------------------------------------------------------------------
-- Hunters
--------------------------------------------------------------------------

function Memory.addHunter(record)
    db.hunters[record.id] = record
    return true
end

function Memory.readHunters(contractId)
    local out = {}
    for _, h in pairs(db.hunters) do
        if h.contract_id == contractId then out[#out + 1] = h end
    end
    table.sort(out, function(a, b) return a.accepted_at == b.accepted_at and a.id < b.id or a.accepted_at < b.accepted_at end)
    return out
end

function Memory.readHunter(contractId, cid)
    for _, h in pairs(db.hunters) do
        if h.contract_id == contractId and h.hunter_cid == cid then return h end
    end
    return nil
end

--- One hunter row by its own id.
---
--- Used to confirm an id is free before minting onto it: the stake is taken
--- before the row is written, so an id already in use is a duplicate-key
--- error with the money already gone and no record naming who staked it.
function Memory.readHunterById(id)
    return db.hunters[id]
end

function Memory.updateHunter(id, fields)
    local h = db.hunters[id]
    if not h then return false end
    for k, v in pairs(fields) do h[k] = v end
    return true
end

--- Confirm an acceptance: the row goes active only if it is still the
--- acceptance that wrote it. Anything that moved it off joining since — boot
--- recovery, a throw's unwind — is not reversed.
function Memory.confirmHunter(id, anon, acceptedAt)
    local h = db.hunters[id]
    if not h or (h.state ~= 'joining' and h.state ~= 'rejoining') then return false end
    h.state, h.anon, h.accepted_at = 'active', anon == true, acceptedAt
    return true
end

--- Contracts a player is on, mid-acceptance included: two acceptances in
--- flight must each see the other against the cap.
function Memory.countHunterContracts(cid, states)
    local n = 0
    for _, h in pairs(db.hunters) do
        if h.hunter_cid == cid and (h.state == 'active' or h.state == 'joining' or h.state == 'rejoining') then
            local c = db.contracts[h.contract_id]
            if c and states[c.state] then n = n + 1 end
        end
    end
    return n
end

--------------------------------------------------------------------------
-- Amendments, messages, ledger, pending, audit
--------------------------------------------------------------------------

function Memory.writeAmendment(a) db.amendments[a.id] = a return true end
function Memory.readAmendment(id) return db.amendments[id] end
function Memory.readOpenAmendments(contractId)
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.contract_id == contractId and a.outcome == 'open' then out[#out + 1] = a end
    end
    return out
end

function Memory.writeMessage(m)
    db.messages[#db.messages + 1] = m
    return true
end
function Memory.readMessages(contractId, threadId)
    local out = {}
    for _, m in ipairs(db.messages) do
        if m.contract_id == contractId and m.thread_id == threadId then out[#out + 1] = m end
    end
    return out
end

function Memory.writeLedger(entry)
    db.ledger[#db.ledger + 1] = entry

    -- Prune past the configured depth, as the other backends do. Without
    -- this the table grows for the life of the process.
    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    local seen = 0
    for i = #db.ledger, 1, -1 do
        if db.ledger[i].cid == entry.cid then
            seen = seen + 1
            if seen > depth then table.remove(db.ledger, i) end
        end
    end

    return true
end
--- Drop the photo reference from rows older than the cutoff (§14.43).
--- The row stays; the image reference does not.
function Memory.forgetLedgerPhotos(cutoff)
    local forgotten = 0
    for i = 1, #db.ledger do
        local row = db.ledger[i]
        if row.photo_ref and (row.resolved_at or 0) < cutoff then
            row.photo_ref = nil
            forgotten = forgotten + 1
        end
    end
    return forgotten
end

function Memory.readLedger(cid, depth)
    local out = {}
    for i = #db.ledger, 1, -1 do
        local e = db.ledger[i]
        if e.cid == cid then
            out[#out + 1] = e
            if #out >= depth then break end
        end
    end
    return out
end

function Memory.queuePending(cid, contractId, lineId)
    local id = Memory.nextId('pnd')
    db.pending[id] = { id = id, cid = cid, contract_id = contractId, line_id = lineId, queued_at = os.time() }
    return true
end
function Memory.readPending(cid)
    local out = {}
    for _, p in pairs(db.pending) do
        if p.cid == cid then out[#out + 1] = p end
    end
    return out
end
function Memory.clearPending(id) db.pending[id] = nil return true end

--- Per-player counters. Kept separate from the ledger, which is capped at
--- ten rows and so cannot answer "how many contracts has this operative
--- finished".
function Memory.bumpStat(cid, field, amount)
    db.stats = db.stats or {}
    local row = db.stats[cid]
    if not row then
        row = { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
        db.stats[cid] = row
    end
    row[field] = (row[field] or 0) + (amount or 1)
    return row[field]
end

function Memory.readStats(cid)
    db.stats = db.stats or {}
    return db.stats[cid] or { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
end

function Memory.writeAudit(entry)
    db.audit[#db.audit + 1] = entry
    return true
end
function Memory.readAudit() return db.audit end

--- Every audit row with one action, oldest first, the newest `limit` of
--- them. One pass over the log, where asking per contract was one each.
function Memory.auditByAction(action, limit)
    local out = {}
    for i = 1, #db.audit do
        if db.audit[i].action == action then out[#out + 1] = db.audit[i] end
    end
    if limit and #out > limit then
        local trimmed = {}
        for i = #out - limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
        return trimmed
    end
    return out
end

--- Every audit row naming one contract, oldest first. The admin timeline
--- reads this; walking the whole log per lookup is a full scan on mysql.
function Memory.auditForContract(contractId, limit)
    local out = {}
    for i = 1, #db.audit do
        if db.audit[i].contract_id == contractId then out[#out + 1] = db.audit[i] end
    end
    if limit and #out > limit then
        local trimmed = {}
        for i = #out - limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
        return trimmed
    end
    return out
end

--- Finished contracts past the retention age that hold nobody's money.
---
--- Nothing pruned contracts, so every full scan in the resource walked the
--- server's whole history rather than its live board and grew without bound
--- for the life of the database.
---
--- Four conditions, and the last two are the ones that matter: terminal,
--- older than the cutoff, holding no escrow line that is not settled, and
--- owing nobody anything on their next login. A contract whose creator was
--- offline when it closed holds their money in a `held` OWED line with a
--- pending row pointing at it, and removing either would take that money
--- with it.
local function prunableContracts(cutoff, limit)
    local holding, owing = {}, {}
    for _, line in pairs(db.escrow) do
        if line.state ~= 'settled' then holding[line.contract_id] = true end
    end
    for _, p in pairs(db.pending) do
        if p.contract_id then owing[p.contract_id] = true end
    end

    local TERMINAL = {
        completed = true, bailed_out = true, expired = true,
        cancelled = true, voided = true,
    }

    local out = {}
    for id, c in pairs(db.contracts) do
        if TERMINAL[c.state] and c.resolved_at and c.resolved_at < cutoff
            and not holding[id] and not owing[id] then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    if limit and #out > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = out[i] end
        return trimmed
    end
    return out
end

function Memory.prune()
    local days = Config.Audit.ContractRetentionDays or 0
    if days <= 0 then return true end

    local ids = prunableContracts(os.time() - (days * 86400),
        Config.Audit.ContractsPrunedPerTick or 200)
    for i = 1, #ids do
        local id = ids[i]
        for lineId, line in pairs(db.escrow) do
            if line.contract_id == id then db.escrow[lineId] = nil end
        end
        for hunterId, hunter in pairs(db.hunters) do
            if hunter.contract_id == id then db.hunters[hunterId] = nil end
        end
        for amendmentId, amendment in pairs(db.amendments) do
            if amendment.contract_id == id then db.amendments[amendmentId] = nil end
        end
        for j = #db.messages, 1, -1 do
            if db.messages[j].contract_id == id then table.remove(db.messages, j) end
        end
        for key, row in pairs(db.reveals) do
            if row.contract_id == id then db.reveals[key] = nil end
        end
        db.contracts[id] = nil
    end
    return true
end

--- What one buyer's informant purchases on one contract have bought.
---
--- Kept in the store, not only in the informant's memory: the record holds
--- the reroll lock and the purchase count, and a restart that forgot them
--- charged the fee again for the same name and counted the ceiling from
--- zero, on the one purchase in the resource that is never refunded.
function Memory.readReveal(contractId, buyerCid)
    return db.reveals[contractId .. ':' .. buyerCid]
end

function Memory.writeReveal(contractId, buyerCid, record)
    local row = {}
    for k, v in pairs(record) do row[k] = v end
    row.contract_id, row.buyer_cid = contractId, buyerCid
    db.reveals[contractId .. ':' .. buyerCid] = row
    return true
end

function Memory.clearReveals(contractId)
    for key, row in pairs(db.reveals) do
        if row.contract_id == contractId then db.reveals[key] = nil end
    end
    return true
end

--- When this process was last known to be running. See main.lua's Recover:
--- the time between the last heartbeat and a boot is time nobody could play.
function Memory.heartbeat(at)
    db.heartbeat = at
    return true
end

function Memory.lastHeartbeat()
    return db.heartbeat
end

function Memory.flush() return true end
function Memory.close() return true end

--- Test seam: expose the raw tables so suites can assert on stored state.
function Memory._raw() return db end

return Memory
