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
        messages = {}, ledger = {}, pending = {}, audit = {}, seq = 0,
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

function Memory.writeContract(contract)
    db.contracts[contract.id] = contract
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

function Memory.writeEscrow(contractId, lines)
    for i = 1, #lines do db.escrow[lines[i].id] = lines[i] end
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

function Memory.settleEscrowLine(id, recipientCid)
    local line = db.escrow[id]
    if not line then return false end
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

function Memory.updateHunter(id, fields)
    local h = db.hunters[id]
    if not h then return false end
    for k, v in pairs(fields) do h[k] = v end
    return true
end

function Memory.countHunterContracts(cid, states)
    local n = 0
    for _, h in pairs(db.hunters) do
        if h.hunter_cid == cid and h.state == 'active' then
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
    return true
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

function Memory.writeAudit(entry)
    db.audit[#db.audit + 1] = entry
    return true
end
function Memory.readAudit() return db.audit end

function Memory.flush() return true end
function Memory.close() return true end

--- Test seam: expose the raw tables so suites can assert on stored state.
function Memory._raw() return db end

return Memory
