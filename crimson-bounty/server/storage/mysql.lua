--- MySQL backend (§10).
---
--- Every statement is parameterized. There is no string concatenation into
--- SQL anywhere in this file, and no table or column name comes from config
--- or from a player — they are literals in this source.

local MySQLStore = {}

local seq = 0

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS crimson_contracts (
        id VARCHAR(32) PRIMARY KEY,
        creator_cid VARCHAR(32) NOT NULL,
        creator_account VARCHAR(64),
        creator_name VARCHAR(64),
        target_cid VARCHAR(32) NOT NULL,
        target_name VARCHAR(64),
        target_protected TINYINT(1) DEFAULT 0,
        target_job VARCHAR(32),
        reason VARCHAR(255),
        mode VARCHAR(16) NOT NULL,
        state VARCHAR(16) NOT NULL,
        anon_creator TINYINT(1) DEFAULT 0,
        bonus_percent INT DEFAULT 0,
        bailout_amount INT DEFAULT 0,
        penalty_amount INT DEFAULT 0,
        payout_slots INT DEFAULT 1,
        slots_claimed INT DEFAULT 0,
        next_slot INT DEFAULT 1,
        created_at INT NOT NULL,
        deadline_at INT,
        expires_at INT,
        paused_ms INT DEFAULT 0,
        paused_since INT,
        bailout_queued_at INT,
        bailout_paid_by VARCHAR(32),
        bailout_paid_amount INT,
        bailout_paid_account VARCHAR(8),
        resolved_at INT,
        resolution VARCHAR(32),
        INDEX idx_state (state),
        INDEX idx_target (target_cid),
        INDEX idx_creator (creator_cid)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_escrow (
        id VARCHAR(64) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        slot INT DEFAULT 1,
        portion VARCHAR(16) NOT NULL,
        source VARCHAR(16) NOT NULL,
        amount INT DEFAULT 0,
        item VARCHAR(64),
        quantity INT DEFAULT 0,
        metadata TEXT,
        staker VARCHAR(32),
        inv_slot INT,
        owed_to VARCHAR(32),
        state VARCHAR(16) NOT NULL,
        settled_to VARCHAR(32),
        settled_at INT,
        INDEX idx_contract (contract_id),
        INDEX idx_state (state)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_hunters (
        id VARCHAR(32) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        hunter_cid VARCHAR(32) NOT NULL,
        hunter_account VARCHAR(64),
        hunter_name VARCHAR(64),
        alias VARCHAR(32),
        anon TINYINT(1) DEFAULT 0,
        accepted_at INT NOT NULL,
        left_at INT,
        last_claim_at INT,
        claims INT DEFAULT 0,
        stake_amount INT DEFAULT 0,
        state VARCHAR(16) NOT NULL,
        INDEX idx_contract (contract_id),
        INDEX idx_hunter (hunter_cid)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_amendments (
        id VARCHAR(32) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        proposer VARCHAR(32) NOT NULL,
        kind VARCHAR(32) NOT NULL,
        payload TEXT,
        approvals TEXT,
        expires_at INT,
        outcome VARCHAR(16) NOT NULL,
        declined_by VARCHAR(32),
        INDEX idx_contract (contract_id)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_messages (
        id INT AUTO_INCREMENT PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        thread_id VARCHAR(80) NOT NULL,
        from_cid VARCHAR(32) NOT NULL,
        from_alias VARCHAR(32) NOT NULL,
        body VARCHAR(255) NOT NULL,
        sent_at INT NOT NULL,
        INDEX idx_thread (thread_id)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_ledger (
        id INT AUTO_INCREMENT PRIMARY KEY,
        cid VARCHAR(32) NOT NULL,
        contract_id VARCHAR(32) NOT NULL,
        role VARCHAR(16) NOT NULL,
        target_name VARCHAR(64),
        reason VARCHAR(255),
        fulfilment VARCHAR(16),
        slot INT DEFAULT 1,
        photo_ref VARCHAR(512),
        resolved_at INT NOT NULL,
        INDEX idx_cid (cid, resolved_at)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_pending (
        id VARCHAR(32) PRIMARY KEY,
        cid VARCHAR(32) NOT NULL,
        contract_id VARCHAR(32),
        line_id VARCHAR(64) NOT NULL,
        queued_at INT NOT NULL,
        INDEX idx_cid (cid)
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_stats (
        cid VARCHAR(32) PRIMARY KEY,
        completed INT DEFAULT 0,
        failed INT DEFAULT 0,
        placed INT DEFAULT 0,
        survived INT DEFAULT 0
    )]],
    [[CREATE TABLE IF NOT EXISTS crimson_audit (
        id INT AUTO_INCREMENT PRIMARY KEY,
        ts INT NOT NULL,
        kind VARCHAR(16) NOT NULL,
        action VARCHAR(48) NOT NULL,
        actor_cid VARCHAR(32),
        contract_id VARCHAR(32),
        detail TEXT,
        INDEX idx_ts (ts),
        INDEX idx_actor (actor_cid)
    )]],
}

function MySQLStore.open()
    for i = 1, #SCHEMA do
        MySQL.query.await(SCHEMA[i])
    end
    local highest = MySQL.scalar.await('SELECT COUNT(*) FROM crimson_contracts') or 0
    seq = tonumber(highest) or 0
    return true
end

function MySQLStore.nextId(prefix)
    seq = seq + 1
    return string.format('%s%d%04d', prefix, os.time() % 100000, seq % 10000)
end

--------------------------------------------------------------------------
-- Contracts
--------------------------------------------------------------------------

--- Persist a contract's fields. `state` is intentionally absent from the
--- UPDATE clause: it changes only through compareSetContractState, so a
--- caller writing a copy it read before a transition cannot revert it. This
--- matters more here than in the other backends, because reads return fresh
--- rows rather than shared tables.
function MySQLStore.writeContract(c)
    MySQL.query.await([[
        INSERT INTO crimson_contracts
            (id, creator_cid, creator_account, creator_name, target_cid, target_name,
             target_protected, target_job, reason, mode, state, anon_creator, bonus_percent,
             bailout_amount, penalty_amount, payout_slots, slots_claimed, next_slot,
             created_at, deadline_at, expires_at, paused_ms, paused_since,
             bailout_queued_at, bailout_paid_by, bailout_paid_amount, bailout_paid_account,
             resolved_at, resolution)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            reason = VALUES(reason), mode = VALUES(mode),
            bailout_amount = VALUES(bailout_amount), penalty_amount = VALUES(penalty_amount),
            slots_claimed = VALUES(slots_claimed), next_slot = VALUES(next_slot),
            deadline_at = VALUES(deadline_at), paused_ms = VALUES(paused_ms),
            paused_since = VALUES(paused_since),
            bailout_queued_at = VALUES(bailout_queued_at),
            bailout_paid_by = VALUES(bailout_paid_by),
            bailout_paid_amount = VALUES(bailout_paid_amount),
            bailout_paid_account = VALUES(bailout_paid_account),
            resolved_at = VALUES(resolved_at), resolution = VALUES(resolution)
    ]], {
        c.id, c.creator_cid, c.creator_account, c.creator_name, c.target_cid, c.target_name,
        c.target_protected and 1 or 0, c.target_job, c.reason, c.mode, c.state,
        c.anon_creator and 1 or 0, c.bonus_percent or 0, c.bailout_amount or 0,
        c.penalty_amount or 0, c.payout_slots or 1, c.slots_claimed or 0, c.next_slot or 1,
        c.created_at, c.deadline_at, c.expires_at, c.paused_ms or 0, c.paused_since,
        c.bailout_queued_at, c.bailout_paid_by, c.bailout_paid_amount, c.bailout_paid_account,
        c.resolved_at, c.resolution,
    })
    return true
end

local function hydrateContract(row)
    if not row then return nil end
    row.target_protected = row.target_protected == 1
    row.anon_creator = row.anon_creator == 1
    return row
end

function MySQLStore.readContract(id)
    local rows = MySQL.query.await('SELECT * FROM crimson_contracts WHERE id = ?', { id })
    return hydrateContract(rows and rows[1])
end

function MySQLStore.allContracts()
    local rows = MySQL.query.await('SELECT * FROM crimson_contracts ORDER BY id') or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

--- Conditional state write, done in one statement so it is atomic at the
--- database rather than in Lua (§9.7).
function MySQLStore.compareSetContractState(id, expected, next_)
    local affected = MySQL.update.await(
        'UPDATE crimson_contracts SET state = ? WHERE id = ? AND state = ?',
        { next_, id, expected })
    return (tonumber(affected) or 0) > 0
end

--------------------------------------------------------------------------
-- Escrow
--------------------------------------------------------------------------

function MySQLStore.writeEscrow(contractId, lines)
    for i = 1, #lines do
        local l = lines[i]
        MySQL.query.await([[
            INSERT INTO crimson_escrow
                (id, contract_id, slot, portion, source, amount, item, quantity, metadata,
                 staker, inv_slot, owed_to, state)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON DUPLICATE KEY UPDATE
                state = VALUES(state), amount = VALUES(amount), owed_to = VALUES(owed_to)
        ]], {
            l.id, contractId, l.slot or 1, l.portion, l.source, l.amount or 0,
            l.item, l.quantity or 0, l.metadata and json.encode(l.metadata) or nil,
            l.staker, l.inv_slot, l.owed_to, l.state,
        })
    end
    return true
end

local function hydrateEscrow(row)
    if row and row.metadata and type(row.metadata) == 'string' then
        local ok, decoded = pcall(json.decode, row.metadata)
        row.metadata = ok and decoded or nil
    end
    return row
end

function MySQLStore.readEscrow(contractId)
    local rows = MySQL.query.await(
        'SELECT * FROM crimson_escrow WHERE contract_id = ? ORDER BY id', { contractId }) or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

function MySQLStore.readEscrowLine(id)
    local rows = MySQL.query.await('SELECT * FROM crimson_escrow WHERE id = ?', { id })
    return hydrateEscrow(rows and rows[1])
end

--- The compare-and-set that makes double release impossible (§14.3).
--- One statement, so the check and the write cannot be interleaved.
function MySQLStore.claimEscrowLine(id, expected, next_)
    local affected = MySQL.update.await(
        'UPDATE crimson_escrow SET state = ? WHERE id = ? AND state = ?',
        { next_, id, expected })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.settleEscrowLine(id, recipientCid)
    MySQL.update.await(
        'UPDATE crimson_escrow SET state = ?, settled_to = ?, settled_at = ? WHERE id = ?',
        { CB.ESCROW_STATE.SETTLED, recipientCid, os.time(), id })
    return true
end

--------------------------------------------------------------------------
-- Hunters
--------------------------------------------------------------------------

function MySQLStore.addHunter(h)
    MySQL.query.await([[
        INSERT INTO crimson_hunters
            (id, contract_id, hunter_cid, hunter_account, hunter_name, alias, anon,
             accepted_at, state, claims)
        VALUES (?,?,?,?,?,?,?,?,?,?)
    ]], {
        h.id, h.contract_id, h.hunter_cid, h.hunter_account, h.hunter_name, h.alias,
        h.anon and 1 or 0, h.accepted_at, h.state, h.claims or 0,
    })
    return true
end

local function hydrateHunter(row)
    if row then row.anon = row.anon == 1 end
    return row
end

function MySQLStore.readHunters(contractId)
    local rows = MySQL.query.await(
        'SELECT * FROM crimson_hunters WHERE contract_id = ? ORDER BY accepted_at, id',
        { contractId }) or {}
    for i = 1, #rows do hydrateHunter(rows[i]) end
    return rows
end

function MySQLStore.readHunter(contractId, cid)
    local rows = MySQL.query.await(
        'SELECT * FROM crimson_hunters WHERE contract_id = ? AND hunter_cid = ?',
        { contractId, cid })
    return hydrateHunter(rows and rows[1])
end

function MySQLStore.updateHunter(id, fields)
    -- Column names are literals here, never interpolated from the caller.
    if fields.state ~= nil then
        MySQL.update.await('UPDATE crimson_hunters SET state = ? WHERE id = ?', { fields.state, id })
    end
    if fields.left_at ~= nil then
        MySQL.update.await('UPDATE crimson_hunters SET left_at = ? WHERE id = ?', { fields.left_at, id })
    end
    if fields.last_claim_at ~= nil then
        MySQL.update.await('UPDATE crimson_hunters SET last_claim_at = ? WHERE id = ?', { fields.last_claim_at, id })
    end
    if fields.claims ~= nil then
        MySQL.update.await('UPDATE crimson_hunters SET claims = ? WHERE id = ?', { fields.claims, id })
    end
    return true
end

function MySQLStore.countHunterContracts(cid, states)
    local rows = MySQL.query.await([[
        SELECT c.state AS state FROM crimson_hunters h
        JOIN crimson_contracts c ON c.id = h.contract_id
        WHERE h.hunter_cid = ? AND h.state = 'active'
    ]], { cid }) or {}
    local n = 0
    for i = 1, #rows do
        if states[rows[i].state] then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------
-- Amendments, messages, ledger, pending, audit
--------------------------------------------------------------------------

function MySQLStore.writeAmendment(a)
    MySQL.query.await([[
        INSERT INTO crimson_amendments
            (id, contract_id, proposer, kind, payload, approvals, expires_at, outcome, declined_by)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            approvals = VALUES(approvals), outcome = VALUES(outcome), declined_by = VALUES(declined_by)
    ]], {
        a.id, a.contract_id, a.proposer, a.kind, json.encode(a.payload or {}),
        json.encode(a.approvals or {}), a.expires_at, a.outcome, a.declined_by,
    })
    return true
end

local function hydrateAmendment(row)
    if not row then return nil end
    if type(row.payload) == 'string' then
        local ok, decoded = pcall(json.decode, row.payload)
        row.payload = ok and decoded or {}
    end
    if type(row.approvals) == 'string' then
        local ok, decoded = pcall(json.decode, row.approvals)
        row.approvals = ok and decoded or {}
    end
    return row
end

function MySQLStore.readAmendment(id)
    local rows = MySQL.query.await('SELECT * FROM crimson_amendments WHERE id = ?', { id })
    return hydrateAmendment(rows and rows[1])
end

function MySQLStore.readOpenAmendments(contractId)
    local rows = MySQL.query.await(
        "SELECT * FROM crimson_amendments WHERE contract_id = ? AND outcome = 'open'",
        { contractId }) or {}
    for i = 1, #rows do hydrateAmendment(rows[i]) end
    return rows
end

function MySQLStore.writeMessage(m)
    MySQL.query.await([[
        INSERT INTO crimson_messages (contract_id, thread_id, from_cid, from_alias, body, sent_at)
        VALUES (?,?,?,?,?,?)
    ]], { m.contract_id, m.thread_id, m.from_cid, m.from_alias, m.body, m.sent_at })
    return true
end

function MySQLStore.readMessages(contractId, threadId)
    return MySQL.query.await(
        'SELECT * FROM crimson_messages WHERE contract_id = ? AND thread_id = ? ORDER BY id',
        { contractId, threadId }) or {}
end

function MySQLStore.writeLedger(entry)
    MySQL.query.await([[
        INSERT INTO crimson_ledger
            (cid, contract_id, role, target_name, reason, fulfilment, slot, photo_ref, resolved_at)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], {
        entry.cid, entry.contract_id, entry.role, entry.target_name, entry.reason,
        entry.fulfilment, entry.slot or 1, entry.photo_ref, entry.resolved_at,
    })
    -- Keep the footprint small: prune anything past the configured depth.
    MySQL.query.await([[
        DELETE FROM crimson_ledger WHERE cid = ? AND id NOT IN (
            SELECT id FROM (
                SELECT id FROM crimson_ledger WHERE cid = ? ORDER BY resolved_at DESC LIMIT ?
            ) keep
        )
    ]], { entry.cid, entry.cid, math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap) })
    return true
end

function MySQLStore.readLedger(cid, depth)
    return MySQL.query.await(
        'SELECT * FROM crimson_ledger WHERE cid = ? ORDER BY resolved_at DESC LIMIT ?',
        { cid, depth }) or {}
end

function MySQLStore.queuePending(cid, contractId, lineId)
    MySQLStore.pendingSeq = (MySQLStore.pendingSeq or 0) + 1
    MySQL.query.await([[
        INSERT INTO crimson_pending (id, cid, contract_id, line_id, queued_at)
        VALUES (?,?,?,?,?)
        ON DUPLICATE KEY UPDATE queued_at = VALUES(queued_at)
    ]], {
        ('pnd%d%04d'):format(os.time() % 100000, MySQLStore.pendingSeq % 10000),
        cid, contractId, lineId, os.time(),
    })
    return true
end

function MySQLStore.readPending(cid)
    return MySQL.query.await(
        'SELECT * FROM crimson_pending WHERE cid = ? ORDER BY queued_at', { cid }) or {}
end

function MySQLStore.clearPending(id)
    MySQL.query.await('DELETE FROM crimson_pending WHERE id = ?', { id })
    return true
end

--- Counter names are literals chosen from a fixed set, never interpolated
--- from a caller: this is the one place a column name is selected at
--- runtime, and it stays a whitelist rather than a string built from input.
local STAT_COLUMNS = { completed = true, failed = true, placed = true, survived = true }

function MySQLStore.bumpStat(cid, field, amount)
    if not STAT_COLUMNS[field] then return 0 end
    amount = amount or 1

    if field == 'completed' then
        MySQL.query.await([[INSERT INTO crimson_stats (cid, completed) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE completed = completed + VALUES(completed)]], { cid, amount })
    elseif field == 'failed' then
        MySQL.query.await([[INSERT INTO crimson_stats (cid, failed) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE failed = failed + VALUES(failed)]], { cid, amount })
    elseif field == 'placed' then
        MySQL.query.await([[INSERT INTO crimson_stats (cid, placed) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE placed = placed + VALUES(placed)]], { cid, amount })
    else
        MySQL.query.await([[INSERT INTO crimson_stats (cid, survived) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE survived = survived + VALUES(survived)]], { cid, amount })
    end

    return amount
end

function MySQLStore.readStats(cid)
    local rows = MySQL.query.await('SELECT * FROM crimson_stats WHERE cid = ?', { cid })
    return (rows and rows[1])
        or { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
end

function MySQLStore.writeAudit(entry)
    MySQL.query.await([[
        INSERT INTO crimson_audit (ts, kind, action, actor_cid, contract_id, detail)
        VALUES (?,?,?,?,?,?)
    ]], { entry.ts, entry.kind, entry.action, entry.actor_cid, entry.contract_id,
          json.encode(entry.detail or {}) })
    return true
end

function MySQLStore.readAudit(limit)
    return MySQL.query.await('SELECT * FROM crimson_audit ORDER BY id DESC LIMIT ?',
        { limit or 100 }) or {}
end

function MySQLStore.prune()
    MySQL.query.await('DELETE FROM crimson_audit WHERE ts < ?',
        { os.time() - (Config.Audit.RetentionDays * 86400) })
    return true
end

function MySQLStore.flush() return true end
function MySQLStore.close() return true end

return MySQLStore
