--- In-process storage. The reference implementation of the storage interface:
--- the mysql and json backends must behave identically to this one.
---
--- Holds no durable escrow, so main.lua refunds everything on resource stop
--- and cancels a creator's contracts when they disconnect (§10.3).

local Util = CrimsonBoot.requireShared('util')

local Memory = {}

local db

--- Escrow lines and hitman rows by contract: [contract_id][id] = row.
---
--- readEscrow and readHitmen walked every row in the store for the one
--- contract asked about, and both are asked once per contract: by the
--- board for every contract it prices, by the sampler every second, by
--- recovery for every contract kept. So each of those was contracts times
--- every line the store holds. A row is checked against db before it is
--- used, so an entry this has not caught up with is never read as live.
local escrowBy, hitmenBy = {}, {}

--- Under the key db holds the row by, which is its id wherever this store
--- wrote it; a row read from an older file is indexed by its key all the
--- same, so nothing db holds is left out of a read.
local function indexRow(index, row, key)
    if type(row) ~= 'table' or row.contract_id == nil or key == nil then return end
    local rows = index[row.contract_id]
    if not rows then
        rows = {}
        index[row.contract_id] = rows
    end
    rows[key] = row
end

local function unindexRow(index, row, key)
    local rows = type(row) == 'table' and row.contract_id ~= nil and index[row.contract_id]
    if rows and rows[key] == row then
        rows[key] = nil
        if next(rows) == nil then index[row.contract_id] = nil end
    end
end

function Memory.open()
    escrowBy, hitmenBy = {}, {}
    db = {
        contracts = {}, escrow = {}, hitmen = {}, amendments = {},
        messages = {}, ledger = {}, pending = {}, audit = {}, reveals = {}, mutes = {},
        photos = {}, reviews = {}, settings = {}, alerts = {}, seq = 0,
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

--- The clock: moves only through setDeadline, startPause and endPause,
--- never through writeContract. Every other writer carries a
--- copy read before its own awaits, and writing these back undid a pause the
--- expiry pass had just started, or an extension the client had just made.
local CLOCK = { 'deadline_at', 'paused_ms', 'paused_since' }

--- The terms a contract was placed under and that never change after:
--- how it may be completed (CH.FULFILMENT_RULE). A copy written back keeps
--- what is stored, as the mysql upsert does, so a row written before the
--- term existed is not handed one by a later write.
local TERMS = { 'fulfilment_rule' }

--- What the law enforcement advisory said of a contract, kept as each
--- bulletin goes out (Notify.advisory): when the posting one went, and the
--- count the latest acceptance one carried. Moves only through setAdvised,
--- so a copy read before a bulletin and written after it cannot take back
--- what the bulletin said.
local ADVISED = { 'advised_posted_at', 'advised_hitmen' }

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
        for i = 1, #TERMS do
            contract[TERMS[i]] = existing[TERMS[i]]
        end
        for i = 1, #ADVISED do
            contract[ADVISED[i]] = existing[ADVISED[i]]
        end
    end
    db.contracts[contract.id] = contract
    return true
end

--- Store a new contract, and never write over one already there.
---
--- A create's row is written once. Asked again by the server for a create
--- whose write was not confirmed (server/review.lua's deciders), an upsert
--- put back the penalty, the buyout price and the resolution from the
--- creation copy over a contract changed or withdrawn since; this leaves it
--- as it is. Stored as writeContract stores a new one.
function Memory.insertContract(contract)
    if db.contracts[contract.id] then return true end
    return Memory.writeContract(contract)
end

--- Take the last collection off a contract, guarded on the count still
--- being the one the caller read.
--- End a contract as expired only if it is still due: past its lifetime,
--- or past a deadline whose clock is running. The expiry pass decides on
--- a read, and a deadline the client extended in the await after it was
--- expired all the same, forfeiting the stake of the hitman it was
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
    penalty_amount = true, resolved_at = true, resolution = true, expires_at = true }
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

--- Set or clear the buyout queue on one contract. nil clears it.
function Memory.setBailoutQueue(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for i = 1, #BAILOUT_QUEUE do
        c[BAILOUT_QUEUE[i]] = fields and fields[BAILOUT_QUEUE[i]] or nil
    end
    return true
end

--- Record a paid buyout, only on a contract still running whose queue is
--- free or already holds this very buyout (the same moment and payer).
---
--- A compare-and-set, so a record written again by the server after its
--- first write went unanswered (server/review.lua's deciders) can never
--- land on a contract another buyout has queued, or one that has closed:
--- true when it is recorded, or was already; false when it was refused.
---@param fields table { bailout_queued_at, bailout_paid_by, bailout_paid_amount, bailout_paid_account }
---@return boolean recorded
function Memory.recordBailout(id, fields)
    local c = db.contracts[id]
    if not c or (c.state ~= 'active' and c.state ~= 'accepted') then return false end
    if c.bailout_queued_at ~= nil and (c.bailout_queued_at ~= fields.bailout_queued_at
        or c.bailout_paid_by ~= fields.bailout_paid_by) then
        return false
    end
    return Memory.setBailoutQueue(id, {
        bailout_queued_at = fields.bailout_queued_at, bailout_paid_by = fields.bailout_paid_by,
        bailout_paid_amount = fields.bailout_paid_amount,
        bailout_paid_account = fields.bailout_paid_account, bailout_attempts = 0,
    })
end

--- Clear the buyout queue, only while it still holds the buyout recorded at
--- `queuedAt`: a clear that lands late never clears a later buyout.
---@return boolean cleared
function Memory.clearBailout(id, queuedAt)
    local c = db.contracts[id]
    if not c or c.bailout_queued_at == nil or c.bailout_queued_at ~= queuedAt then return false end
    return Memory.setBailoutQueue(id, nil)
end

--- Keep what an advisory bulletin said of one contract: any of the ADVISED
--- fields, the others left as they are.
local ADVISED_FIELD = { advised_posted_at = true, advised_hitmen = true }
function Memory.setAdvised(id, fields)
    local c = db.contracts[id]
    if not c then return false end
    for k, v in pairs(fields) do
        if not ADVISED_FIELD[k] then error('setAdvised: not an advisory field: ' .. tostring(k)) end
        c[k] = v
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

--- How many contracts the store keeps in each state, for the admin panel's
--- overview, which needs nothing else of them. Counted where they lie, with
--- nothing copied; mysql counts them with one GROUP BY on idx_state rather
--- than bringing every row of the table into Lua every few seconds.
---@return table [state] = count
function Memory.countContractsByState()
    local out = {}
    for _, c in pairs(db.contracts) do out[c.state] = (out[c.state] or 0) + 1 end
    return out
end

--- Contracts still running: active or accepted, by id.
---
--- The only ones the death sampler, the expiry pass and the board act on.
--- They read allContracts, every contract the retention keeps, and threw
--- nearly all of it away: once a second for the sampler, and on mysql that
--- was every row of the table brought into Lua. Recovery and the memory-mode
--- stop still read the whole table; they act on finished contracts too.
function Memory.liveContracts()
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.state == 'active' or c.state == 'accepted' then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Contracts this player is involved in, as creator, target or hitman.
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

    for _, h in pairs(db.hitmen) do
        if h.hitman_cid == cid and not seen[h.contract_id] then
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
            -- How often its give has raised (Escrow.deliver), what they held
            -- before the last one, and how much of it has reached them. A
            -- copy that does not carry one leaves it as it is, as COALESCE
            -- does on mysql: a part that arrived is never forgotten, and so
            -- never given again.
            if incoming.deliver_raises ~= nil then
                existing.deliver_raises = incoming.deliver_raises
            end
            if incoming.deliver_before ~= nil then
                existing.deliver_before = incoming.deliver_before
            end
            if incoming.deliver_arrived ~= nil then
                existing.deliver_arrived = incoming.deliver_arrived
            end
        else
            if existing then unindexRow(escrowBy, existing, incoming.id) end
            db.escrow[incoming.id] = incoming
            indexRow(escrowBy, incoming, incoming.id)
        end
    end
    return true
end

--- Store the lines a take confirms, each only where its id is not there yet.
---
--- A take's line ids are new, so this stores what writeEscrow would. Written
--- again by the server after its first write went unanswered (server/
--- review.lua's deciders), or landing late, it leaves a line already there
--- exactly as it is: writeEscrow put back whom it was owed and going to from
--- the take's copy, over a line that had moved since.
function Memory.insertEscrow(contractId, lines)
    local fresh = {}
    for i = 1, #lines do
        if db.escrow[lines[i].id] == nil then fresh[#fresh + 1] = lines[i] end
    end
    if #fresh == 0 then return true end
    return Memory.writeEscrow(contractId, fresh)
end

function Memory.readEscrow(contractId)
    local out = {}
    for id, line in pairs(escrowBy[contractId] or {}) do
        if db.escrow[id] == line then out[#out + 1] = line end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function Memory.readEscrowLine(id)
    return db.escrow[id]
end

--- Escrow not yet settled whose contract does not exist.
---
--- A new contract's escrow is written before its row, so a crash, or a
--- write that failed, between the two leaves lines no contract owns. Read
--- once at boot (Contracts.recoverNeverPlaced); everything else reaches
--- escrow through its contract and never sees these.
function Memory.orphanEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state ~= CH.ESCROW_STATE.SETTLED and not db.contracts[line.contract_id] then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Escrow not yet settled whose give has raised `limit` times or more
--- (Escrow.parked): owed to somebody, and given to nobody until staff settle
--- it. Read from the lines themselves for /ch-stuck, so a line is listed for
--- as long as it is held, whatever the audit log has kept of how it came to
--- be there.
---@param limit integer Escrow.DELIVER_RAISE_LIMIT
function Memory.parkedEscrow(limit)
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state ~= CH.ESCROW_STATE.SETTLED
            and (tonumber(line.deliver_raises) or 0) >= limit then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Held escrow owed to somebody, whatever it says of a give. Read for
--- /ch-stuck, which lists those of them that are neither left for staff
--- (Escrow.parked) nor queued for their player: a give that stopped
--- part-way, a queue entry that was never written or that a retry cleared,
--- given by nothing until the next start queues them (Escrow.recoverOwed).
function Memory.owedHeldEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.HELD and line.owed_to ~= nil then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Escrow `releasing`: claimed by a release and not yet settled or put
--- back. Read for /ch-stuck, which lists those no call in this process
--- holds (Escrow.inFlight): left there by a call that raised, and settled
--- or put back by nothing until the next start (Recover).
function Memory.releasingEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.RELEASING then out[#out + 1] = line end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Every escrow line not settled yet, held or mid-release, by id: what the
--- admin panel's overview adds up as money held. One read, where asking
--- each contract for its lines was a query per contract on mysql.
function Memory.unsettledEscrow()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.HELD or line.state == CH.ESCROW_STATE.RELEASING then
            out[#out + 1] = line
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Every contract holding an escrow line that is not settled, as a set.
---
--- Read once at boot. Recovery acts on nothing else of a finished
--- contract, and asking each contract for its lines was a query per
--- contract on mysql, thirty days of them, before the app answered anyone.
function Memory.unsettledEscrowContracts()
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state ~= CH.ESCROW_STATE.SETTLED and line.contract_id ~= nil then
            out[line.contract_id] = true
        end
    end
    return out
end

--- Held escrow owed to nobody and naming no give, of a closed contract: what
--- an ending hands over as it closes, left there by one that raised part-way
--- (Contracts.finishEndings, which the maintenance tick runs, and /ch-stuck).
--- At most `limit` lines, by id.
---@param limit integer
function Memory.strandedEscrow(limit)
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.state == CH.ESCROW_STATE.HELD and line.owed_to == nil
            and line.releasing_to == nil then
            local contract = db.contracts[line.contract_id]
            if contract and CH.TERMINAL[contract.state] then out[#out + 1] = line end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    for i = #out, (tonumber(limit) or #out) + 1, -1 do out[i] = nil end
    return out
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
---
--- `staff` when staff settled it without giving anything (/ch-settle
--- delivered): { disposition = 'delivered', by = who }, kept on the line in
--- the same write, so it is never settled without a record of why.
function Memory.settleEscrowLine(id, recipientCid, staff)
    local line = db.escrow[id]
    if not line or line.state ~= CH.ESCROW_STATE.RELEASING then return false end
    line.state = CH.ESCROW_STATE.SETTLED
    line.settled_to = recipientCid
    line.settled_at = os.time()
    if staff then
        line.settled_by_staff = staff.disposition
        line.settled_staff = staff.by
    end
    return true
end

--------------------------------------------------------------------------
-- Hitmen
--------------------------------------------------------------------------

function Memory.addHitman(record)
    local existing = db.hitmen[record.id]
    if existing then unindexRow(hitmenBy, existing, record.id) end
    db.hitmen[record.id] = record
    indexRow(hitmenBy, record, record.id)
    return true
end

function Memory.readHitmen(contractId)
    local out = {}
    for id, h in pairs(hitmenBy[contractId] or {}) do
        if db.hitmen[id] == h then out[#out + 1] = h end
    end
    table.sort(out, function(a, b) return a.accepted_at == b.accepted_at and a.id < b.id or a.accepted_at < b.accepted_at end)
    return out
end

--- Every running contract's hitmen, by contract id. See the mysql backend:
--- one read for the death sampler's pass instead of one per contract.
function Memory.liveHitmen()
    local out = {}
    for id, c in pairs(db.contracts) do
        if c.state == 'active' or c.state == 'accepted' then
            local list = {}
            for hid, h in pairs(hitmenBy[id] or {}) do
                if db.hitmen[hid] == h then list[#list + 1] = h end
            end
            table.sort(list, function(a, b)
                if a.accepted_at == b.accepted_at then return a.id < b.id end
                return a.accepted_at < b.accepted_at
            end)
            out[id] = list
        end
    end
    return out
end

function Memory.readHitman(contractId, cid)
    for id, h in pairs(hitmenBy[contractId] or {}) do
        if db.hitmen[id] == h and h.hitman_cid == cid then return h end
    end
    return nil
end

--- One hitman row by its own id.
---
--- Used to confirm an id is free before minting onto it: the stake is taken
--- before the row is written, so an id already in use is a duplicate-key
--- error with the money already gone and no record naming who staked it.
function Memory.readHitmanById(id)
    return db.hitmen[id]
end

function Memory.updateHitman(id, fields)
    local h = db.hitmen[id]
    if not h then return false end
    for k, v in pairs(fields) do h[k] = v end
    return true
end

--- Confirm an acceptance: the row goes active only if it is still the
--- acceptance that wrote it. Anything that moved it off joining since — boot
--- recovery, a throw's unwind — is not reversed.
function Memory.confirmHitman(id, anon, acceptedAt)
    local h = db.hitmen[id]
    if not h or (h.state ~= 'joining' and h.state ~= 'rejoining') then return false end
    h.state, h.anon, h.accepted_at = 'active', anon == true, acceptedAt
    return true
end

--- A hitman walks away: the row goes abandoned only while it is active, on
--- this contract, and the contract is still open (MySQLStore.abandonHitman).
function Memory.abandonHitman(id, contractId, leftAt)
    local h = db.hitmen[id]
    if not h or h.state ~= 'active' or h.contract_id ~= contractId then return false end
    local c = db.contracts[contractId]
    if not c or (c.state ~= CH.STATE.ACTIVE and c.state ~= CH.STATE.ACCEPTED) then return false end
    h.state, h.left_at = 'abandoned', leftAt
    return true
end

--- Contracts a player is on, mid-acceptance included: two acceptances in
--- flight must each see the other against the cap.
function Memory.countHitmanContracts(cid, states)
    local n = 0
    for _, h in pairs(db.hitmen) do
        if h.hitman_cid == cid and (h.state == 'active' or h.state == 'joining' or h.state == 'rejoining') then
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
--- Every contract with a proposal still open, as a set: the amendment
--- expiry's index after a restart, in one read rather than one per contract.
function Memory.openAmendmentContracts()
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.outcome == 'open' and a.contract_id ~= nil then out[a.contract_id] = true end
    end
    return out
end

function Memory.readOpenAmendments(contractId)
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.contract_id == contractId and a.outcome == 'open' then out[#out + 1] = a end
    end
    return out
end

--- Proposals a start finds still being applied: everybody had agreed and
--- the change was going in when the last process stopped
--- (Amendments.recoverApplying). Read once, at start.
function Memory.applyingAmendments()
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.outcome == 'applying' then out[#out + 1] = a end
    end
    return out
end

--- Drop a thread's oldest messages past Config.Relay.MaxMessagesPerThread,
--- as the other backends do.
local function pruneThread(m)
    local keep = tonumber(Config.Relay.MaxMessagesPerThread) or 0
    if keep <= 0 then return end
    local seen = 0
    for i = #db.messages, 1, -1 do
        local row = db.messages[i]
        if row.contract_id == m.contract_id and row.thread_id == m.thread_id then
            seen = seen + 1
            if seen > keep then table.remove(db.messages, i) end
        end
    end
end

function Memory.writeMessage(m)
    db.messages[#db.messages + 1] = m
    pruneThread(m)
    return true
end
function Memory.readMessages(contractId, threadId)
    local out = {}
    for _, m in ipairs(db.messages) do
        if m.contract_id == contractId and m.thread_id == threadId then out[#out + 1] = m end
    end
    return out
end

--- Threads somebody has muted (§11.4), one row per thread and participant:
--- a row is a mute and unmuting removes it. In the store with the thread it
--- silences, so a restart does not start a phone ringing again for a
--- conversation its owner muted days ago, and it goes when the contract's
--- messages do.
function Memory.readMute(threadId, cid)
    return db.mutes[threadId .. ':' .. cid] ~= nil
end

function Memory.setMute(contractId, threadId, cid, muted, at)
    local key = threadId .. ':' .. cid
    if muted then
        db.mutes[key] = { contract_id = contractId, thread_id = threadId, cid = cid, muted_at = at }
    else
        db.mutes[key] = nil
    end
    return true
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

--------------------------------------------------------------------------
-- Kill photos kept for a contract's client (§14.43)
--------------------------------------------------------------------------
--
-- One record per photo, by its handle. What the client may do with one is
-- Photos's business. The store's part is that a record's state moves
-- only from the state the caller expected, so two requests racing to open
-- the same photo cannot both be shown it, and a photo saved in the same
-- instant it timed out is one or the other, never both.

function Memory.writePhoto(record)
    local row = {}
    for k, v in pairs(record) do row[k] = v end
    db.photos[row.id] = row
    return true
end

function Memory.readPhoto(id)
    return db.photos[id]
end

--- Whether any photo record is kept at all, in any state (Photos.anyStored).
function Memory.anyPhoto()
    return next(db.photos) ~= nil
end

--- Records matching `keep`, oldest first, at most `limit` of them.
local function photosWhere(keep, limit)
    local out = {}
    for _, row in pairs(db.photos) do
        if keep(row) then out[#out + 1] = row end
    end
    table.sort(out, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then
            return (a.created_at or 0) < (b.created_at or 0)
        end
        return a.id < b.id
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

function Memory.photosOf(ownerCid)
    return photosWhere(function(row) return row.owner_cid == ownerCid end)
end

function Memory.photosForContract(contractId)
    return photosWhere(function(row) return row.contract_id == contractId end)
end

--- Opened before the cutoff and still in `state`: open by default, which
--- is a photo still waiting for Save or Delete; kept, for the photos kept
--- in the app longer than Config.Completion.KeptPhotoDays.
function Memory.photosOpenedBefore(cutoff, limit, state)
    state = state or CH.PHOTO.OPEN
    return photosWhere(function(row)
        return row.state == state and (row.opened_at or 0) < cutoff
    end, limit)
end

--- The photo a link this server serves names, by the unguessable name in
--- the link (Photos.publish).
function Memory.readPhotoByPublic(publicId)
    if type(publicId) ~= 'string' then return nil end
    for _, row in pairs(db.photos) do
        if row.public_id == publicId then return row end
    end
    return nil
end

--- How many photos each state holds a file for, and how many bytes: what
--- /ch-diag tells an owner about the disk these take.
function Memory.photoTotals()
    local out = {}
    for _, row in pairs(db.photos) do
        if row.file then
            local total = out[row.state] or { count = 0, bytes = 0 }
            total.count = total.count + 1
            total.bytes = total.bytes + (tonumber(row.size) or 0)
            out[row.state] = total
        end
    end
    return out
end

--- Kept before the cutoff, and the retention's to forget: not kept in the
--- app, and not served to a phone's Photos (Photos.forgetBefore).
function Memory.photosCreatedBefore(cutoff, limit)
    return photosWhere(function(row)
        return (row.created_at or 0) < cutoff and row.state ~= CH.PHOTO.KEPT
            and row.public_id == nil
    end, limit)
end

--- Pending to open, once.
function Memory.openPhoto(id, at)
    local row = db.photos[id]
    if not row or row.state ~= CH.PHOTO.PENDING then return false end
    row.state, row.opened_at = CH.PHOTO.OPEN, at
    return true
end

--- From the expected state to a closed one, keeping no image: the link,
--- the file name and any link this server served it under go with the
--- state change, in the same step.
function Memory.closePhoto(id, expected, next_, savedLink)
    local row = db.photos[id]
    if not row or row.state ~= expected then return false end
    row.state, row.url, row.file, row.saved_link = next_, nil, nil, savedLink
    row.public_id, row.saved_phone = nil, nil
    return true
end

--- Give a photo kept on this server a link it is served under, without
--- moving its state: the client's phone is still to save it.
function Memory.publishPhoto(id, expected, publicId, link, phone)
    local row = db.photos[id]
    if not row or row.state ~= expected or not row.file then return false end
    row.public_id, row.saved_link, row.saved_phone = publicId, link, phone
    return true
end

--- From the expected state to the next, and nothing else changed: a photo
--- saved to the phone through the link this server serves keeps its file.
function Memory.movePhoto(id, expected, next_)
    local row = db.photos[id]
    if not row or row.state ~= expected then return false end
    row.state = next_
    return true
end

--- Kept in the app: its file where it now lives (nil for a link, which
--- stays), and no link served for it any more.
function Memory.keepPhoto(id, expected, file)
    local row = db.photos[id]
    if not row or row.state ~= expected then return false end
    row.state, row.public_id, row.saved_link, row.saved_phone = CH.PHOTO.KEPT, nil, nil, nil
    if file then row.file = file end
    return true
end

function Memory.deletePhoto(id)
    db.photos[id] = nil
    return true
end

--- Every record not open right now, in any other state, oldest first, at
--- most `limit`: what staff's removal of the photos kept from before kill
--- photos were turned off takes (Photos.removeAll). One open is left to the
--- view that has it.
function Memory.photosNotOpen(limit)
    return photosWhere(function(row) return row.state ~= CH.PHOTO.OPEN end, limit)
end

--- Delete each of `list` ({ id, state }) only while it is still in that
--- state: one opened since it was read is left. The ids deleted.
---@return table<string, boolean>
function Memory.deletePhotosIn(list)
    local gone = {}
    for _, wanted in ipairs(list or {}) do
        local row = db.photos[wanted.id]
        if row and row.state == wanted.state then
            db.photos[wanted.id] = nil
            gone[wanted.id] = true
        end
    end
    return gone
end

--- How many records there are, how many are open right now, how many are
--- on lb-phone's image host (a link) and how many still hold a file here.
---@return table { total, open, links, files }
function Memory.photoCounts()
    local out = { total = 0, open = 0, links = 0, files = 0 }
    for _, row in pairs(db.photos) do
        out.total = out.total + 1
        if row.state == CH.PHOTO.OPEN then out.open = out.open + 1 end
        if row.kind == 'url' then out.links = out.links + 1 end
        if row.file then out.files = out.files + 1 end
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

--- How many rows the retention age has dropped from the front of the log
--- since it was this table: what a page's cursor counts from
--- (Memory.queryAudit). Kept against the table itself, so a store opened
--- again starts counting again.
local auditDropped = { log = nil, rows = 0 }

local function droppedFrom(log)
    if auditDropped.log ~= log then auditDropped.log, auditDropped.rows = log, 0 end
    return auditDropped.rows
end

--- Drop the rows older than the cutoff. They are at the front, in the order
--- they were written, so they go in one move: removing them one at a time
--- from the front shifted the whole log once per row.
---@return integer dropped
local function trimAudit(cutoff)
    local log = db.audit
    local n, aged = #log, 0
    while aged < n and log[aged + 1].ts < cutoff do aged = aged + 1 end
    if aged == 0 then return 0 end
    table.move(log, aged + 1, n, 1)
    for i = n - aged + 1, n do log[i] = nil end
    auditDropped.rows = droppedFrom(log) + aged
    return aged
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

--- A page of the audit log for the admin panel, newest first: at most
--- `limit` rows passing the filters (Util.auditMatches), from `cursor` back,
--- and the cursor the next page starts from, nil on the last. The cursor is
--- opaque to callers: here it is a position in the log counted from the
--- first row written to it, aged rows included (droppedFrom), the row it
--- names included. Counted from what was left of the log, every row the
--- retention age dropped between two pages moved every position down, and
--- the next page started that many rows too new and showed rows again.
---@param filter table|nil { kind, action, contract, actor, from, to }
---@param cursor integer|nil
---@param limit integer
---@return table[] rows
---@return integer|nil next
function Memory.queryAudit(filter, cursor, limit)
    local log = db.audit
    local base = droppedFrom(log)
    local at = math.tointeger(tonumber(cursor))
    local start = at and (at - base) or #log
    -- Everything from there back has aged out since.
    if start < 1 then return {}, nil end
    local out = {}
    for i = math.min(start, #log), 1, -1 do
        if Util.auditMatches(log[i], filter) then
            if #out >= limit then return out, base + i end
            out[#out + 1] = log[i]
        end
    end
    return out, nil
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
--- Five conditions, and the last three are the ones that matter: terminal,
--- older than the cutoff, holding no escrow line that is not settled, owing
--- nobody anything on their next login, and named by no review item staff
--- have not resolved. A contract whose creator was offline when it closed
--- holds their money in a `held` OWED line with a pending row pointing at
--- it, and removing either would take that money with it.
---
--- A pending row owes something only while the line it names is held or
--- mid-release: a payout handed over at once leaves its row behind until
--- the player's next login, and it is not money. An open review item reads
--- its advice against the contract, so the contract stays until the item
--- is resolved. See the json backend.
local function prunableContracts(cutoff, limit)
    local TERMINAL = {
        completed = true, bailed_out = true, expired = true,
        cancelled = true, voided = true,
    }

    -- The old enough ones first. Nearly every tick there are none, and the
    -- escrow and pending walks below were done before finding that out.
    local aged = {}
    for id, c in pairs(db.contracts) do
        if TERMINAL[c.state] and c.resolved_at and c.resolved_at < cutoff then
            aged[id] = true
        end
    end
    if next(aged) == nil then return {} end

    local holding, owing = {}, {}
    for id in pairs(aged) do
        for lineId, line in pairs(escrowBy[id] or {}) do
            if db.escrow[lineId] == line and line.state ~= 'settled' then holding[id] = true end
        end
    end
    for _, p in pairs(db.pending) do
        if p.contract_id and aged[p.contract_id] then
            local line = db.escrow[p.line_id]
            if line and line.state ~= 'settled' then owing[p.contract_id] = true end
        end
    end
    for _, item in pairs(db.reviews) do
        if item.contract_id and aged[item.contract_id]
            and (item.state == 'open' or item.state == 'resolving') then
            owing[item.contract_id] = true
        end
    end

    local out = {}
    for id in pairs(aged) do
        if not holding[id] and not owing[id] then
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
    -- The audit log, by Config.Audit.RetentionDays, as the other backends
    -- keep theirs. It was only ever appended to here, for the life of the
    -- process. 0 keeps it.
    local auditDays = tonumber(Config.Audit.RetentionDays) or 0
    if auditDays > 0 then trimAudit(os.time() - (auditDays * 86400)) end

    local days = Config.Audit.ContractRetentionDays or 0
    if days <= 0 then return true end

    local ids = prunableContracts(os.time() - (days * 86400),
        Config.Audit.ContractsPrunedPerTick or 200)
    if #ids == 0 then return true end

    -- One walk of each table that is not indexed by contract, for all of
    -- them, rather than one per contract: see the json backend.
    local gone = {}
    for i = 1, #ids do
        local id = ids[i]
        gone[id] = true
        for lineId, line in pairs(escrowBy[id] or {}) do
            if db.escrow[lineId] == line then db.escrow[lineId] = nil end
        end
        escrowBy[id] = nil
        for hitmanId, hitman in pairs(hitmenBy[id] or {}) do
            if db.hitmen[hitmanId] == hitman then db.hitmen[hitmanId] = nil end
        end
        hitmenBy[id] = nil
        db.contracts[id] = nil
    end
    for amendmentId, amendment in pairs(db.amendments) do
        if gone[amendment.contract_id] then db.amendments[amendmentId] = nil end
    end
    local messages, kept = db.messages, 0
    for j = 1, #messages do
        local m = messages[j]
        if not gone[m.contract_id] then
            kept = kept + 1
            messages[kept] = m
        end
    end
    for j = #messages, kept + 1, -1 do messages[j] = nil end
    for key, row in pairs(db.reveals) do
        if gone[row.contract_id] then db.reveals[key] = nil end
    end
    for key, row in pairs(db.mutes) do
        if gone[row.contract_id] then db.mutes[key] = nil end
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

--------------------------------------------------------------------------
-- The review queue
--------------------------------------------------------------------------

--- Money events no rule here can settle by itself, kept until staff resolve
--- them (server/review.lua), by id.
---
--- Written once and never over: a write the store reported as failed may
--- have landed, and the queue tries it again, so a second write of the
--- same item finds it there and leaves it — resolved meanwhile, it stays
--- resolved, and nobody is paid for it twice.
function Memory.writeReview(item)
    if db.reviews[item.id] then return true end
    local row = {}
    for k, v in pairs(item) do row[k] = v end
    db.reviews[row.id] = row
    return true
end

function Memory.readReview(id)
    return db.reviews[id]
end

--- Open ones (and any left part-way resolved) oldest first, or every one
--- newest first, at most `limit`.
---@param open boolean
---@param limit integer|nil
function Memory.reviewItems(open, limit)
    local out = {}
    for _, row in pairs(db.reviews) do
        if not open or row.state == 'open' or row.state == 'resolving' then
            out[#out + 1] = row
        end
    end
    table.sort(out, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then
            if open then return (a.created_at or 0) < (b.created_at or 0) end
            return (a.created_at or 0) > (b.created_at or 0)
        end
        return a.id < b.id
    end)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

--- Move an item from `expected` to `next_`, writing how it was resolved, by
--- whom and when in the same step. Compare-and-set, so two resolutions of
--- one item cannot both begin.
---@param fields table { resolution, resolved_by, resolved_at }
---@return boolean moved
function Memory.setReviewState(id, expected, next_, fields)
    local row = db.reviews[id]
    if not row or row.state ~= expected then return false end
    row.state = next_
    row.resolution, row.resolved_by, row.resolved_at =
        fields.resolution, fields.resolved_by, fields.resolved_at
    return true
end

--------------------------------------------------------------------------
-- Settings changed from the admin panel
--------------------------------------------------------------------------

--- What staff changed from the admin panel (server/settings.lua), by
--- config key ('Bailout.Enabled'): { value, by, at }. Applied over
--- config.lua at every start, so they outlive a restart in the two stores
--- that do; this one keeps them as long as it keeps anything, which is
--- until the resource stops.
---@return table [key] = { value, by, at }
function Memory.readSettings()
    local out = {}
    for key, row in pairs(db.settings) do
        out[key] = { value = Util.copy(row.value), by = row.by, at = row.at }
    end
    return out
end

---@param key string
---@param value any a boolean, a number, a string or a list of strings
---@param by string|nil who changed it
---@param at integer os.time
function Memory.writeSetting(key, value, by, at)
    db.settings[key] = { value = Util.copy(value), by = by, at = at }
    return true
end

--- One back to what config.lua says.
function Memory.deleteSetting(key)
    db.settings[key] = nil
    return true
end

--- Every one back to what config.lua says.
function Memory.clearSettings()
    db.settings = {}
    return true
end

--------------------------------------------------------------------------
-- The admin panel's alerts
--------------------------------------------------------------------------

--- Every line the console printed whatever Config.Debug said, kept as an
--- alert (server/alerts.lua), by id: { id, level, text, contract_id,
--- first_at, last_at, count, acknowledged_by, acknowledged_at }. Alerts
--- keeps them all in memory and writes each one whole when it changes, so
--- the store only keeps, hands back at start and forgets them.
---@return table[] rows
function Memory.readAlerts()
    local out = {}
    for _, row in pairs(db.alerts) do out[#out + 1] = Util.copy(row) end
    return out
end

---@param row table one alert, whole
function Memory.writeAlert(row)
    db.alerts[row.id] = Util.copy(row)
    return true
end

--- One pruned (Alerts.MAX).
function Memory.deleteAlert(id)
    db.alerts[id] = nil
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
