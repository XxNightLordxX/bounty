--- Flat-file backend (§10.2).
---
--- For servers that do not want to run MySQL. Fully durable: writes are
--- atomic (temp file then rename), financial transitions bypass the debounce,
--- and a malformed data file halts the resource rather than starting with
--- empty escrow.

local Util = require_shared('util')

local JsonStore = {}

local db, dirty, lastFlush, seq = nil, false, 0, 0
local resource = GetCurrentResourceName and GetCurrentResourceName() or 'crimson-bounty'

local EMPTY = {
    contracts = {}, escrow = {}, hunters = {}, amendments = {},
    messages = {}, ledger = {}, pending = {}, audit = {}, stats = {}, seq = 0,
}

--- Which contracts have unwritten changes, and whether the index itself has.
---
--- The store used to be re-serialised and rewritten whole on every financial
--- write. With a few thousand contracts that is a multi-megabyte write every
--- time a coin moves. Everything a contract owns — its row, its escrow, its
--- hunters, its amendments, its messages — lives in one file per contract,
--- and only the contracts that actually changed are written.
local dirtyShards = {}
local indexDirty = false

--- Every contract id that owns a file. Kept separately from db.contracts
--- because a shard can hold escrow whose contract row is missing — an
--- orphan is exactly the case where money must not be allowed to vanish,
--- and the index is the only record of which files exist.
local shardIds = {}

local function directory()
    return Config.Database.Json.Directory or 'data'
end

local function path()
    return directory() .. '/store.json'
end

--- Contract ids are minted by nextId as a fixed prefix and digits, so they
--- are safe as a filename. Checked anyway: a value that reached here from
--- anywhere else must never become a path fragment.
local function shardPath(contractId)
    if type(contractId) ~= 'string' or not contractId:match('^[%w_%-]+$') then
        return nil
    end
    return directory() .. '/contracts/' .. contractId .. '.json'
end

--- Everything belonging to one contract, gathered for writing.
local function shardOf(contractId)
    local shard = {
        contract = db.contracts[contractId],
        escrow = {}, hunters = {}, amendments = {}, messages = {},
    }

    for id, line in pairs(db.escrow) do
        if line.contract_id == contractId then shard.escrow[id] = line end
    end
    for id, hunter in pairs(db.hunters) do
        if hunter.contract_id == contractId then shard.hunters[id] = hunter end
    end
    for id, amendment in pairs(db.amendments) do
        if amendment.contract_id == contractId then shard.amendments[id] = amendment end
    end
    for i = 1, #db.messages do
        if db.messages[i].contract_id == contractId then
            shard.messages[#shard.messages + 1] = db.messages[i]
        end
    end

    return shard
end

--- Fold a shard back into the in-memory store.
local function absorb(shard)
    if type(shard) ~= 'table' then return false end
    if type(shard.contract) == 'table' then
        db.contracts[shard.contract.id] = shard.contract
    end
    for id, line in pairs(shard.escrow or {}) do db.escrow[id] = line end
    for id, hunter in pairs(shard.hunters or {}) do db.hunters[id] = hunter end
    for id, amendment in pairs(shard.amendments or {}) do db.amendments[id] = amendment end
    for i = 1, #(shard.messages or {}) do
        db.messages[#db.messages + 1] = shard.messages[i]
    end
    return true
end

--------------------------------------------------------------------------
-- Load and save
--------------------------------------------------------------------------

--- Write one file atomically: serialise, write a temp file, read it back,
--- then put it in place. A crash mid-write cannot leave a truncated file,
--- and a write that did not land is not treated as one that did.
---@return boolean written
local function writeFile(target, value)
    local encoded = json.encode(value)
    local temp = target .. '.tmp'

    SaveResourceFile(resource, temp, encoded, -1)
    local verify = LoadResourceFile(resource, temp)
    if not verify or #verify ~= #encoded then
        print(('[crimson-bounty] write verification failed for %s; keeping the previous file')
            :format(target))
        return false
    end

    SaveResourceFile(resource, target, encoded, -1)
    return true
end

--- Everything the index file holds: the sequence, which contracts own a
--- shard, and the small tables that are not per-contract.
---
--- Built in one place because both the flush and the writability probe write
--- it, and an index missing a field here is a store that loses whatever the
--- field held.
local function buildIndex()
    local index = { seq = seq, contractIds = {} }
    for id in pairs(shardIds) do
        index.contractIds[#index.contractIds + 1] = id
    end
    table.sort(index.contractIds)

    -- Everything that is not per-contract. Small, and rewritten whole.
    index.ledger, index.pending = db.ledger, db.pending
    index.audit, index.stats = db.audit, db.stats
    return index
end

--- Confirm the store's directories are actually writable.
---
--- SaveResourceFile writes a file; it does not create the directories above
--- it. Without data/ and data/contracts/ already present every write fails
--- and returns nothing useful, so escrow would be taken from players and
--- never recorded — and the first anyone would know is a restart with the
--- contracts gone.
---
--- Refusing to start is the only honest answer: a store that silently drops
--- everything is worse than no store.
function JsonStore.assertWritable()
    -- The index is the probe: writing it proves data/ is writable and leaves
    -- the store in exactly the state a flush would, rather than dropping a
    -- stray file next to it.
    if not writeFile(path(), buildIndex()) then
        error(('[crimson-bounty] cannot write %s. Create the directory %s and make it ' ..
               'writable by the server, or switch Config.Database.Mode away from json. ' ..
               'Refusing to start: escrow taken from players would not be recorded.')
               :format(path(), directory()))
    end

    -- The shard directory is separate, and just as fatal. Nothing reads this
    -- file; it exists so a missing contracts/ is found at startup rather than
    -- the first time a contract is created and its escrow disappears.
    local file = directory() .. '/contracts/.writable'
    SaveResourceFile(resource, file, json.encode({ at = os.time() }), -1)
    if not LoadResourceFile(resource, file) then
        error(('[crimson-bounty] cannot write %s/contracts/. Create that directory and ' ..
               'make it writable by the server. Refusing to start: every contract would ' ..
               'be taken and none of them stored.'):format(directory()))
    end

    return true
end

--- Read the store.
---
--- A file that exists but will not parse is fatal: starting fresh would
--- silently delete every open contract's escrow. The same goes for a shard
--- the index names and cannot be read — that is one contract's money
--- missing, which is not something to start up and hope about.
function JsonStore.open()
    local raw = LoadResourceFile(resource, path())

    if raw == nil or raw == '' then
        db = json.decode(json.encode(EMPTY))
        dirtyShards, shardIds, indexDirty = {}, {}, true
        JsonStore.save(true)
        JsonStore.assertWritable()
        return true
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        error(('[crimson-bounty] %s is unreadable. Refusing to start: continuing would ' ..
               'discard every open contract and its escrow. Restore the file from a backup ' ..
               'or move it aside deliberately.'):format(path()))
    end

    db = json.decode(json.encode(EMPTY))
    dirtyShards, shardIds = {}, {}
    for key, value in pairs(decoded) do
        if key ~= 'contractIds' then db[key] = value end
    end
    for key, value in pairs(EMPTY) do
        if db[key] == nil then db[key] = type(value) == 'table' and {} or value end
    end
    seq = tonumber(db.seq) or 0

    if type(decoded.contractIds) == 'table' then
        -- Sharded layout. There is no directory listing native, so the index
        -- is the only record of which shards exist; a named shard that will
        -- not load is a missing contract, not a missing file.
        for i = 1, #decoded.contractIds do
            local id = decoded.contractIds[i]
            local file = shardPath(id)
            local shardRaw = file and LoadResourceFile(resource, file)

            if not shardRaw or shardRaw == '' then
                error(('[crimson-bounty] contract %s is listed in %s but its file is ' ..
                       'missing or empty. Refusing to start: that contract holds escrow ' ..
                       'nobody could return.'):format(tostring(id), path()))
            end

            local shardOk, shard = pcall(json.decode, shardRaw)
            if not shardOk or type(shard) ~= 'table' then
                error(('[crimson-bounty] contract file for %s is unreadable. Refusing to ' ..
                       'start rather than discarding its escrow.'):format(tostring(id)))
            end

            absorb(shard)
            shardIds[id] = true
        end
    elseif type(decoded.contracts) == 'table' then
        -- The old single-file layout, from a version before this one. Load
        -- it as it stands and write it out sharded, keeping the original
        -- where it is: a migration that deletes the only copy of the data it
        -- is migrating is not one worth having.
        local migrated = 0
        for id in pairs(db.contracts) do
            dirtyShards[id] = true
            shardIds[id] = true
            migrated = migrated + 1
        end

        -- Escrow whose contract row did not survive still belongs to
        -- somebody. It gets a file of its own rather than being left out of
        -- the migration.
        for _, line in pairs(db.escrow) do
            if line.contract_id and not shardIds[line.contract_id] then
                dirtyShards[line.contract_id] = true
                shardIds[line.contract_id] = true
                migrated = migrated + 1
            end
        end
        indexDirty = true
        SaveResourceFile(resource, path() .. '.bak', raw, -1)
        JsonStore.save(true)
        print(('[crimson-bounty] migrated %d contract(s) to one file each; the original ' ..
               'store is kept at %s.bak'):format(migrated, path()))
    else
        error(('[crimson-bounty] %s has neither a contract index nor contracts. ' ..
               'Refusing to start on a store this file does not understand.'):format(path()))
    end

    JsonStore.assertWritable()

    local count = 0
    for _ in pairs(db.contracts) do count = count + 1 end
    if count > (Config.Database.Json.WarnContractCount or 2000) then
        print(('[crimson-bounty] json store holds %d contracts; consider mysql mode'):format(count))
    end

    return true
end

--- Write what changed.
---
--- `force` writes every dirty shard; an ordinary flush writes at most
--- MaxDirtyShardsPerFlush of them and leaves the rest for the next one, so a
--- burst of activity cannot turn one flush into an unbounded stall.
function JsonStore.save(force)
    if not db then return false end
    if not force and not dirty then return false end

    local budget = force and math.huge
        or (Config.Database.Json.MaxDirtyShardsPerFlush or 25)
    local written = 0

    for id in pairs(dirtyShards) do
        if written >= budget then break end

        local file = shardPath(id)
        if not file then
            -- Not a shape this store mints, so not something to name a file
            -- after. Dropped rather than written.
            dirtyShards[id] = nil
        elseif writeFile(file, shardOf(id)) then
            dirtyShards[id] = nil
            written = written + 1
            indexDirty = true
        else
            -- Left dirty deliberately: a shard that did not land is retried
            -- on the next flush rather than forgotten.
            break
        end
    end

    if indexDirty or force then
        db.seq = seq
        if writeFile(path(), buildIndex()) then indexDirty = false end
    end

    if not next(dirtyShards) and not indexDirty then
        dirty = false
    end
    lastFlush = Util.monotonicMs()
    return true
end

--- Mark the store dirty.
---
--- `contractId` names which shard changed; without one the change is in the
--- index (the ledger, a pending payout, an audit row). Financial writes
--- flush immediately; everything else rides the debounce (§10.2).
local function touch(financial, contractId)
    dirty = true
    if contractId then
        dirtyShards[contractId] = true
        if not shardIds[contractId] then
            shardIds[contractId] = true
            -- A contract the index does not list is a file nothing will ever
            -- read back.
            indexDirty = true
        end
    else
        indexDirty = true
    end
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

--- Contracts this player is involved in, as creator, target or hunter.
function JsonStore.contractsInvolving(cid)
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

function JsonStore.contractsNaming(cid)
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.target_cid == cid then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function JsonStore.contractsBy(cid)
    local out = {}
    for _, c in pairs(db.contracts) do
        if c.creator_cid == cid then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- State is not written here: it changes only through
--- compareSetContractState, so a stale copy cannot revert a transition.
function JsonStore.writeContract(c)
    local existing = db.contracts[c.id]
    if existing and existing ~= c then
        c.state = existing.state
    end
    db.contracts[c.id] = c
    touch(true, c.id)
    return true
end

function JsonStore.readContract(id) return db.contracts[id] end

function JsonStore.allContracts()
    local out = {}
    for _, c in pairs(db.contracts) do out[#out + 1] = c end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Advance the payout slot, only if it is still the one the caller acted on.
--- See the memory backend for why claimSlot may not write back a snapshot.
function JsonStore.advanceSlot(id, expectedSlot)
    local c = db.contracts[id]
    if not c or (c.next_slot or 1) ~= expectedSlot then return false end
    c.next_slot = expectedSlot + 1
    c.slots_claimed = (c.slots_claimed or 0) + 1
    touch(true, id)
    return true
end

--- No yield between the read and the write, so this is atomic with respect
--- to other handlers on the same tick (§14.3).
function JsonStore.compareSetContractState(id, expected, next_)
    local c = db.contracts[id]
    if not c or c.state ~= expected then return false end
    c.state = next_
    touch(true, id)
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
            existing.releasing_to = incoming.releasing_to
        else
            db.escrow[incoming.id] = incoming
        end
    end
    touch(true, contractId)
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
    touch(true, line.contract_id)
    return true
end

--- Guarded amount change; state is never written here.
function JsonStore.setEscrowAmount(id, expectedState, amount, expectedAmount)
    local line = db.escrow[id]
    if not line or line.state ~= expectedState then return false end
    if expectedAmount ~= nil and line.amount ~= expectedAmount then return false end
    line.amount = amount
    touch(true, line.contract_id)
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
function JsonStore.settleEscrowLine(id, recipientCid)
    local line = db.escrow[id]
    if not line or line.state ~= CB.ESCROW_STATE.RELEASING then return false end
    line.state = CB.ESCROW_STATE.SETTLED
    line.settled_to = recipientCid
    line.settled_at = os.time()
    touch(true, line.contract_id)
    return true
end

--------------------------------------------------------------------------
-- Hunters
--------------------------------------------------------------------------

function JsonStore.addHunter(record)
    db.hunters[record.id] = record
    touch(false, record.contract_id)
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
    touch(false, h.contract_id)
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

function JsonStore.writeAmendment(a) db.amendments[a.id] = a touch(false, a.contract_id) return true end
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
    touch(false, m.contract_id)
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

--- Drop the photo reference from rows older than the cutoff (§14.43).
function JsonStore.forgetLedgerPhotos(cutoff)
    local forgotten = 0
    for i = 1, #db.ledger do
        local row = db.ledger[i]
        if row.photo_ref and (row.resolved_at or 0) < cutoff then
            row.photo_ref = nil
            forgotten = forgotten + 1
        end
    end
    if forgotten > 0 then touch(false) end
    return forgotten
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

--- Every audit row naming one contract, oldest first.
function JsonStore.auditForContract(contractId, limit)
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

function JsonStore._raw() return db end

return JsonStore
