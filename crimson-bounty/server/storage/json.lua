--- Flat-file backend (§10.2).
---
--- For servers that do not want to run MySQL. Fully durable: writes are
--- atomic (temp file then rename), financial transitions bypass the debounce,
--- and a malformed data file halts the resource rather than starting with
--- empty escrow.

local JsonStore = {}

local db, dirty, lastFlush, seq = nil, false, 0, 0
local resource = GetCurrentResourceName and GetCurrentResourceName() or 'crimson-bounty'

local EMPTY = {
    contracts = {}, escrow = {}, hunters = {}, amendments = {},
    messages = {}, ledger = {}, pending = {}, audit = {}, stats = {}, seq = 0,
}

local function path()
    return (Config.Database.Json.Directory or 'data') .. '/store.json'
end

--------------------------------------------------------------------------
-- Load and save
--------------------------------------------------------------------------

--- Read the store. A file that exists but will not parse is fatal: starting
--- fresh would silently delete every open contract's escrow.
function JsonStore.open()
    local raw = LoadResourceFile(resource, path())

    if raw == nil or raw == '' then
        db = json.decode(json.encode(EMPTY))
        JsonStore.save(true)
        return true
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' or type(decoded.contracts) ~= 'table' then
        error(('[crimson-bounty] %s is unreadable. Refusing to start: continuing would ' ..
               'discard every open contract and its escrow. Restore the file from a backup ' ..
               'or move it aside deliberately.'):format(path()))
    end

    db = decoded
    for key, value in pairs(EMPTY) do
        if db[key] == nil then db[key] = type(value) == 'table' and {} or value end
    end
    seq = tonumber(db.seq) or 0

    local count = 0
    for _ in pairs(db.contracts) do count = count + 1 end
    if count > (Config.Database.Json.WarnContractCount or 2000) then
        print(('[crimson-bounty] json store holds %d contracts; consider mysql mode'):format(count))
    end

    return true
end

--- Atomic write: serialise to a temp file, then rename over the target, so a
--- crash mid-write cannot leave a truncated escrow file.
function JsonStore.save(force)
    if not force and not dirty then return false end

    db.seq = seq
    local encoded = json.encode(db)
    local temp = path() .. '.tmp'

    SaveResourceFile(resource, temp, encoded, -1)
    local verify = LoadResourceFile(resource, temp)
    if not verify or #verify ~= #encoded then
        print('[crimson-bounty] json write verification failed; keeping the previous store')
        return false
    end

    SaveResourceFile(resource, path(), encoded, -1)
    dirty, lastFlush = false, GetGameTimer()
    return true
end

--- Mark the store dirty. Financial writes flush immediately; everything else
--- rides the debounce (§10.2).
local function touch(financial)
    dirty = true
    if financial and Config.Database.Json.SyncOnFinancialWrite then
        JsonStore.save(true)
    end
end

function JsonStore.flush() return JsonStore.save(false) end
function JsonStore.close() return JsonStore.save(true) end

function JsonStore.nextId(prefix)
    seq = seq + 1
    touch(false)
    return string.format('%s%08d', prefix, seq)
end

--------------------------------------------------------------------------
-- Contracts
--------------------------------------------------------------------------

--- State is not written here: it changes only through
--- compareSetContractState, so a stale copy cannot revert a transition.
function JsonStore.writeContract(c)
    local existing = db.contracts[c.id]
    if existing and existing ~= c then
        c.state = existing.state
    end
    db.contracts[c.id] = c
    touch(true)
    return true
end

function JsonStore.readContract(id) return db.contracts[id] end

function JsonStore.allContracts()
    local out = {}
    for _, c in pairs(db.contracts) do out[#out + 1] = c end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- No yield between the read and the write, so this is atomic with respect
--- to other handlers on the same tick (§14.3).
function JsonStore.compareSetContractState(id, expected, next_)
    local c = db.contracts[id]
    if not c or c.state ~= expected then return false end
    c.state = next_
    touch(true)
    return true
end

--------------------------------------------------------------------------
-- Escrow
--------------------------------------------------------------------------

--- State and amount are preserved from the stored row; see the memory
--- backend for why.
function JsonStore.writeEscrow(contractId, lines)
    for i = 1, #lines do
        local incoming = lines[i]
        local existing = db.escrow[incoming.id]
        if existing and existing ~= incoming then
            existing.owed_to = incoming.owed_to
        else
            db.escrow[incoming.id] = incoming
        end
    end
    touch(true)
    return true
end

function JsonStore.readEscrow(contractId)
    local out = {}
    for _, line in pairs(db.escrow) do
        if line.contract_id == contractId then out[#out + 1] = line end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function JsonStore.readEscrowLine(id) return db.escrow[id] end

function JsonStore.claimEscrowLine(id, expected, next_)
    local line = db.escrow[id]
    if not line or line.state ~= expected then return false end
    line.state = next_
    touch(true)
    return true
end

--- Guarded amount change; state is never written here.
function JsonStore.setEscrowAmount(id, expectedState, amount, expectedAmount)
    local line = db.escrow[id]
    if not line or line.state ~= expectedState then return false end
    if expectedAmount ~= nil and line.amount ~= expectedAmount then return false end
    line.amount = amount
    touch(true)
    return true
end

function JsonStore.settleEscrowLine(id, recipientCid)
    local line = db.escrow[id]
    if not line then return false end
    line.state = CB.ESCROW_STATE.SETTLED
    line.settled_to = recipientCid
    line.settled_at = os.time()
    touch(true)
    return true
end

--------------------------------------------------------------------------
-- Hunters
--------------------------------------------------------------------------

function JsonStore.addHunter(record)
    db.hunters[record.id] = record
    touch(false)
    return true
end

function JsonStore.readHunters(contractId)
    local out = {}
    for _, h in pairs(db.hunters) do
        if h.contract_id == contractId then out[#out + 1] = h end
    end
    table.sort(out, function(a, b)
        if a.accepted_at == b.accepted_at then return a.id < b.id end
        return a.accepted_at < b.accepted_at
    end)
    return out
end

function JsonStore.readHunter(contractId, cid)
    for _, h in pairs(db.hunters) do
        if h.contract_id == contractId and h.hunter_cid == cid then return h end
    end
    return nil
end

function JsonStore.updateHunter(id, fields)
    local h = db.hunters[id]
    if not h then return false end
    for k, v in pairs(fields) do h[k] = v end
    touch(false)
    return true
end

function JsonStore.countHunterContracts(cid, states)
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

function JsonStore.writeAmendment(a) db.amendments[a.id] = a touch(false) return true end
function JsonStore.readAmendment(id) return db.amendments[id] end

function JsonStore.readOpenAmendments(contractId)
    local out = {}
    for _, a in pairs(db.amendments) do
        if a.contract_id == contractId and a.outcome == 'open' then out[#out + 1] = a end
    end
    return out
end

function JsonStore.writeMessage(m)
    db.messages[#db.messages + 1] = m
    touch(false)
    return true
end

function JsonStore.readMessages(contractId, threadId)
    local out = {}
    for _, m in ipairs(db.messages) do
        if m.contract_id == contractId and m.thread_id == threadId then out[#out + 1] = m end
    end
    return out
end

function JsonStore.writeLedger(entry)
    db.ledger[#db.ledger + 1] = entry
    -- Prune to the configured depth per player so the file stays small.
    local depth = math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap)
    local seen = 0
    for i = #db.ledger, 1, -1 do
        if db.ledger[i].cid == entry.cid then
            seen = seen + 1
            if seen > depth then table.remove(db.ledger, i) end
        end
    end
    touch(false)
    return true
end

function JsonStore.readLedger(cid, depth)
    local out = {}
    for i = #db.ledger, 1, -1 do
        if db.ledger[i].cid == cid then
            out[#out + 1] = db.ledger[i]
            if #out >= depth then break end
        end
    end
    return out
end

function JsonStore.queuePending(cid, contractId, lineId)
    local id = JsonStore.nextId('pnd')
    db.pending[id] = {
        id = id, cid = cid, contract_id = contractId,
        line_id = lineId, queued_at = os.time(),
    }
    touch(true)
    return true
end

function JsonStore.readPending(cid)
    local out = {}
    for _, p in pairs(db.pending) do
        if p.cid == cid then out[#out + 1] = p end
    end
    return out
end

function JsonStore.clearPending(id)
    db.pending[id] = nil
    touch(true)
    return true
end

function JsonStore.bumpStat(cid, field, amount)
    db.stats = db.stats or {}
    local row = db.stats[cid]
    if not row then
        row = { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
        db.stats[cid] = row
    end
    row[field] = (row[field] or 0) + (amount or 1)
    touch(false)
    return row[field]
end

function JsonStore.readStats(cid)
    db.stats = db.stats or {}
    return db.stats[cid] or { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
end

function JsonStore.writeAudit(entry)
    db.audit[#db.audit + 1] = entry
    local cutoff = os.time() - (Config.Audit.RetentionDays * 86400)
    while db.audit[1] and db.audit[1].ts < cutoff do table.remove(db.audit, 1) end
    touch(false)
    return true
end

function JsonStore.readAudit() return db.audit end

function JsonStore._raw() return db end

return JsonStore
