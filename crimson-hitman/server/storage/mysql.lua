--- MySQL backend (§10).
---
--- Every statement is parameterized. There is no string concatenation into
--- SQL anywhere in this file, and no table or column name comes from config
--- or from a player — they are literals in this source.

local Util = require_shared('util')
local MySQLStore = {}

local seq = 0

--- Every oxmysql await this file makes goes through `db`, so the time spent
--- waiting on the database can be told from the time spent working
--- (MySQLStore.timeWaitsWith, which main points at Timing.await). Without
--- it a maintenance job was charged for everything the server did while it
--- waited. Looked up at call time, as oxmysql's own table is.
local awaitVia = function(fn, ...) return fn(...) end
local db = {}
for _, kind in ipairs({ 'query', 'update', 'insert', 'scalar', 'transaction' }) do
    db[kind] = function(...) return awaitVia(MySQL[kind].await, ...) end
end

--- Hand every await to `wrapper(fn, ...)`, which must call fn(...) and
--- return what it returns.
---@param wrapper function|nil nil puts the plain call back
function MySQLStore.timeWaitsWith(wrapper)
    awaitVia = wrapper or function(fn, ...) return fn(...) end
end

--- Every table says utf8mb4, as qbx_core's own tables do, rather than taking
--- whatever the database defaults to. txAdmin's recipe makes the database
--- utf8 (utf8mb3), which has no four-byte characters, and older MariaDB and
--- XAMPP make it latin1. Inherited, an emoji in a contract reason or a relay
--- message was refused with error 1366, and on latin1 so was a Polish or
--- Cyrillic character name: those players could neither place a contract nor
--- be named in one. migrate() converts a table an older version made.
local CHARSET, COLLATION = 'utf8mb4', 'utf8mb4_unicode_ci'

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS crimson_contracts (
        id VARCHAR(32) PRIMARY KEY,
        creator_cid VARCHAR(32) NOT NULL,
        creator_account VARCHAR(64),
        creator_name VARCHAR(64),
        target_cid VARCHAR(32) NOT NULL,
        -- Added to existing databases by migrate; NULL on older rows, which
        -- are checked against the target online instead.
        target_account VARCHAR(64),
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
        bailout_attempts INT DEFAULT 0,
        resolved_at INT,
        resolution VARCHAR(32),
        INDEX idx_state (state),
        INDEX idx_target (target_cid),
        INDEX idx_creator (creator_cid),
        -- Asked on every creation. Added to existing databases by migrate.
        INDEX idx_creator_account (creator_account),
        -- Read on every maintenance tick, and almost always empty. Added
        -- to existing databases by MySQLStore.migrate.
        INDEX idx_bailout_queued (bailout_queued_at)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_escrow (
        id VARCHAR(64) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        slot INT DEFAULT 1,
        -- Baseline, bonus, stake or owed, which is the portion field of a
        -- line everywhere else in this resource. Not named that here, because
        -- PORTION is a reserved word on MariaDB (10.4 on, for FOR PORTION OF)
        -- and a CREATE TABLE naming it was a syntax error, so mysql mode
        -- never started there. RENAMED below moves the column an older
        -- version made under the old name, and hydrateEscrow reads it back.
        line_portion VARCHAR(16) NOT NULL,
        source VARCHAR(16) NOT NULL,
        amount INT DEFAULT 0,
        item VARCHAR(64),
        quantity INT DEFAULT 0,
        metadata TEXT,
        staker VARCHAR(32),
        inv_slot INT,
        owed_to VARCHAR(32),
        releasing_to VARCHAR(32),
        state VARCHAR(16) NOT NULL,
        settled_to VARCHAR(32),
        settled_at INT,
        derived TINYINT(1) DEFAULT 0,
        -- Who the line was taken from. Added to existing databases by
        -- migrate; NULL on older rows.
        taken_from VARCHAR(32),
        INDEX idx_contract (contract_id),
        INDEX idx_state (state)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_hitmen (
        id VARCHAR(32) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        hitman_cid VARCHAR(32) NOT NULL,
        hitman_account VARCHAR(64),
        hitman_name VARCHAR(64),
        alias VARCHAR(32),
        anon TINYINT(1) DEFAULT 0,
        accepted_at INT NOT NULL,
        left_at INT,
        last_claim_at INT,
        claims INT DEFAULT 0,
        stake_amount INT DEFAULT 0,
        state VARCHAR(16) NOT NULL,
        INDEX idx_contract (contract_id),
        INDEX idx_hitman (hitman_cid)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_messages (
        id INT AUTO_INCREMENT PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        thread_id VARCHAR(80) NOT NULL,
        from_cid VARCHAR(32) NOT NULL,
        from_alias VARCHAR(32) NOT NULL,
        body VARCHAR(255) NOT NULL,
        sent_at INT NOT NULL,
        INDEX idx_thread (thread_id)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_pending (
        id VARCHAR(32) PRIMARY KEY,
        cid VARCHAR(32) NOT NULL,
        contract_id VARCHAR(32),
        line_id VARCHAR(64) NOT NULL,
        queued_at INT NOT NULL,
        INDEX idx_cid (cid)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_stats (
        cid VARCHAR(32) PRIMARY KEY,
        completed INT DEFAULT 0,
        failed INT DEFAULT 0,
        placed INT DEFAULT 0,
        survived INT DEFAULT 0
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_audit (
        id INT AUTO_INCREMENT PRIMARY KEY,
        ts INT NOT NULL,
        kind VARCHAR(16) NOT NULL,
        action VARCHAR(48) NOT NULL,
        actor_cid VARCHAR(32),
        contract_id VARCHAR(32),
        detail TEXT,
        INDEX idx_ts (ts),
        INDEX idx_actor (actor_cid),
        -- The admin timeline reads every row for one contract. Without this
        -- that is a scan of the whole log, which is the largest table here.
        INDEX idx_audit_contract (contract_id)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- What one buyer's informant purchases on one contract have bought: the
    -- reroll lock and the purchase count. Kept here rather than only in
    -- memory, because a restart that forgot them charged the fee again for
    -- the same name and counted the ceiling from zero.
    [[CREATE TABLE IF NOT EXISTS crimson_reveals (
        id VARCHAR(80) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        buyer_cid VARCHAR(32) NOT NULL,
        hitman_cid VARCHAR(32),
        revealed_at INT NOT NULL,
        purchases INT DEFAULT 0,
        seed INT,
        answer TEXT,
        INDEX idx_reveal_contract (contract_id)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Threads somebody has muted (§11.4): a row is a mute, and unmuting
    -- deletes it. Created on an existing database by the CREATE TABLE IF
    -- NOT EXISTS below at the next start, like any table added since.
    [[CREATE TABLE IF NOT EXISTS crimson_mutes (
        id VARCHAR(120) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        thread_id VARCHAR(80) NOT NULL,
        cid VARCHAR(32) NOT NULL,
        muted_at INT NOT NULL,
        INDEX idx_mute_contract (contract_id)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Kill photos kept for a contract's client (§14.43), by handle: the
    -- ledger row the client is shown carries the handle and never the
    -- link. No hitman column, on purpose: the record goes to nobody but
    -- the client. `url` is a link on an image host ('host' storage); `file`,
    -- `mime` and `size` describe a photo kept on this server. `public_id`
    -- is the unguessable name a photo kept on this server is served under
    -- once its client saves it to their phone's Photos, `saved_link` the
    -- link that makes, and `saved_phone` the phone number it was saved
    -- from, so a factory reset of that phone lets it go. Created on an
    -- existing database by the CREATE TABLE IF NOT EXISTS at the next start;
    -- a column added since is added by migrate().
    [[CREATE TABLE IF NOT EXISTS crimson_photos (
        id VARCHAR(32) PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        slot INT DEFAULT 1,
        owner_cid VARCHAR(32) NOT NULL,
        kind VARCHAR(8) NOT NULL,
        url VARCHAR(512),
        file VARCHAR(96),
        mime VARCHAR(32),
        size INT,
        state VARCHAR(16) NOT NULL,
        created_at INT NOT NULL,
        opened_at INT,
        saved_link VARCHAR(512),
        public_id VARCHAR(48),
        saved_phone VARCHAR(32),
        INDEX idx_photo_owner (owner_cid),
        INDEX idx_photo_contract (contract_id),
        INDEX idx_photo_open (state, opened_at),
        INDEX idx_photo_created (created_at),
        INDEX idx_photo_public (public_id)
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Small facts about the store itself. Holds the heartbeat: when this
    -- process was last known to be running, so a boot can tell how long
    -- nobody could play.
    [[CREATE TABLE IF NOT EXISTS crimson_meta (
        meta_key VARCHAR(32) PRIMARY KEY,
        meta_value INT NOT NULL
    ) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
}

--------------------------------------------------------------------------
-- Migration
--------------------------------------------------------------------------
--
-- CREATE TABLE IF NOT EXISTS creates a table and then never touches it
-- again, so a server that ran an earlier version keeps its old columns and
-- silently drops every field added since. The columns added during this
-- build — staker, owed_to, paused_since, the bailout queue — would all have
-- gone that way.
--
-- The declarations above are the single source of truth: what a table should
-- have is read out of them, compared against what the database reports, and
-- anything absent is added. Nothing is ever dropped, and nothing is altered
-- in place except in the two ways that keep every value: a column renamed
-- (RENAMED), and a table converted to utf8mb4, which holds every character
-- the old character set could. An automatic migration that can destroy a
-- column is a worse problem than the one it solves.

--- Columns renamed since an older version made them: [table] = { old = new }.
--- Moved with CHANGE COLUMN, which keeps the values, before anything is
--- added, so the new name is never added beside the old one. The old name is
--- quoted, since it may be the very word that could not be used unquoted.
local RENAMED = {
    crimson_escrow = { portion = 'line_portion' },
}
MySQLStore.RENAMED = RENAMED

--- Column and index declarations for one CREATE TABLE statement.
---@return string|nil name
---@return table columns [ { name, definition } ] in declaration order
---@return table indexes [ { name, definition } ]
local function declarationsIn(sql)
    local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
    if not name then return nil, {}, {} end

    local columns, indexes = {}, {}
    -- MySQL ignores the `--` comments; this has to as well. Read as
    -- declarations, the prose in them became columns named `and` and
    -- `which`, the ALTER TABLE built from them was a syntax error, oxmysql
    -- raised it, and mysql mode never started.
    -- Up to the last bracket: the table options (the character set) follow
    -- it.
    local body = sql:gsub('%-%-[^\n]*', ''):match('%((.*)%)[^)]*$') or ''

    -- Split on the commas between declarations only. One inside brackets
    -- belongs to a declaration: `INDEX idx_cid (cid, resolved_at)` is one.
    local parts, depth, start = {}, 0, 1
    for i = 1, #body do
        local ch = body:sub(i, i)
        if ch == '(' then
            depth = depth + 1
        elseif ch == ')' then
            depth = depth - 1
        elseif ch == ',' and depth == 0 then
            parts[#parts + 1] = body:sub(start, i - 1)
            start = i + 1
        end
    end
    parts[#parts + 1] = body:sub(start)

    for _, part in ipairs(parts) do
        local trimmed = part:gsub('%s+', ' '):match('^%s*(.-)%s*$')
        local head = trimmed:match('^([%w_]+)')

        if head then
            local upper = head:upper()
            if upper == 'INDEX' or upper == 'KEY' then
                local indexName = trimmed:match('^[%w_]+%s+([%w_]+)')
                if indexName then
                    indexes[#indexes + 1] = { name = indexName, definition = trimmed }
                end
            elseif upper ~= 'PRIMARY' and upper ~= 'UNIQUE'
                and upper ~= 'CONSTRAINT' and upper ~= 'FOREIGN' then
                columns[#columns + 1] = { name = head, definition = trimmed }
            end
        end
    end

    return name, columns, indexes
end

--- Table and column names here come from the literals in this file and from
--- nowhere else — never from config, never from a player — which is what
--- makes it safe to build DDL from them. MySQL will not take a placeholder
--- for an identifier, so there is no parameterized alternative. The guard is
--- belt and braces: anything that is not a plain lowercase identifier is not
--- something this file declared.
local function safeIdentifier(name)
    return type(name) == 'string' and name:match('^[a-z][a-z0-9_]*$') ~= nil
end

--- Whether a character set or collation name is utf8mb4's. MySQL 8 and
--- MariaDB both name the three-byte one utf8mb3 now, and older builds utf8.
local function isUtf8mb4(name)
    return type(name) == 'string' and name:lower():sub(1, 7) == 'utf8mb4'
end

--- Whether a collation is the one every table here declares. utf8mb4 is not
--- enough: two text columns compared in a join must share a collation, or
--- MariaDB and MySQL refuse the query outright (error 1267, "Illegal mix of
--- collations"). An older version took the database default, which on
--- Debian's MariaDB is utf8mb4_general_ci, on MariaDB 11.6 and later
--- utf8mb4_uca1400_ai_ci and on MySQL 8 utf8mb4_0900_ai_ci. One such table
--- left beside the ones this version creates broke every join between them,
--- the recovery at start included, and mysql mode never started.
local function isOurCollation(name)
    return type(name) == 'string' and name:lower() == COLLATION
end

--- Whether a table an older version made needs converting to utf8mb4 in
--- COLLATION: its own default (what a column added later inherits), or any
--- text column in it, is in another character set or another collation.
--- `columnRows` is the COLUMNS answer migrate already has; a column with no
--- character set is not text.
local function needsConverting(table_, columnRows)
    for j = 1, #columnRows do
        local row = columnRows[j]
        local charset = row.CHARACTER_SET_NAME or row.character_set_name
        local collation = row.COLLATION_NAME or row.collation_name
        if charset ~= nil and not isUtf8mb4(charset) then return true end
        if collation ~= nil and not isOurCollation(collation) then return true end
    end
    local rows = db.query([[
        SELECT TABLE_COLLATION FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
    ]], { table_ }) or {}
    local collation = rows[1] and (rows[1].TABLE_COLLATION or rows[1].table_collation)
    -- No answer is no table, or a query that failed: nothing to convert.
    return collation ~= nil and not isOurCollation(collation)
end

--- Add whatever the declarations have and the database does not.
---@return integer added columns
---@return integer added indexes
function MySQLStore.migrate()
    local addedColumns, addedIndexes = 0, 0

    for i = 1, #SCHEMA do
        local table_, columns, indexes = declarationsIn(SCHEMA[i])

        if table_ and safeIdentifier(table_) then
            local present = {}
            local rows = db.query([[
                SELECT COLUMN_NAME, CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
            ]], { table_ }) or {}
            for j = 1, #rows do
                present[tostring(rows[j].COLUMN_NAME or rows[j].column_name):lower()] = true
            end

            -- An empty answer means the table was just created by the
            -- statement above and already matches, or the query failed. Doing
            -- nothing is right either way.
            if next(present) and needsConverting(table_, rows) then
                -- Rebuilds the table, once. CREATE TABLE IF NOT EXISTS left
                -- one an older version made on a utf8mb3 or latin1 database
                -- as it was, refusing every four-byte character, and one
                -- made in another utf8mb4 collation unable to be joined
                -- with the tables made since.
                db.query(('ALTER TABLE %s CONVERT TO CHARACTER SET %s COLLATE %s')
                    :format(table_, CHARSET, COLLATION))
                print(('[crimson-hitman] migrated: converted %s to %s'):format(table_, COLLATION))
            end

            -- Renamed before anything is added, so the new name is not added
            -- beside the old one with every row's value left behind.
            if next(present) and RENAMED[table_] then
                for j = 1, #columns do
                    local column = columns[j]
                    for old, new in pairs(RENAMED[table_]) do
                        if column.name == new and safeIdentifier(old) and safeIdentifier(new)
                            and present[old] and not present[new] then
                            db.query(('ALTER TABLE %s CHANGE COLUMN `%s` %s')
                                :format(table_, old, column.definition))
                            print(('[crimson-hitman] migrated: renamed %s.%s to %s')
                                :format(table_, old, new))
                            present[old], present[new] = nil, true
                        end
                    end
                end
            end

            if next(present) then
                for j = 1, #columns do
                    local column = columns[j]
                    if safeIdentifier(column.name) and not present[column.name:lower()] then
                        db.query(
                            ('ALTER TABLE %s ADD COLUMN %s'):format(table_, column.definition))
                        print(('[crimson-hitman] migrated: added %s.%s'):format(table_, column.name))
                        addedColumns = addedColumns + 1
                    end
                end
            end

            local haveIndex = {}
            local indexRows = db.query([[
                SELECT INDEX_NAME FROM information_schema.STATISTICS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
            ]], { table_ }) or {}
            for j = 1, #indexRows do
                haveIndex[tostring(indexRows[j].INDEX_NAME or indexRows[j].index_name):lower()] = true
            end

            if next(haveIndex) then
                for j = 1, #indexes do
                    local index = indexes[j]
                    if safeIdentifier(index.name) and not haveIndex[index.name:lower()] then
                        db.query(
                            ('ALTER TABLE %s ADD %s'):format(table_, index.definition))
                        print(('[crimson-hitman] migrated: added index %s on %s')
                            :format(index.name, table_))
                        addedIndexes = addedIndexes + 1
                    end
                end
            end
        end
    end

    if addedColumns > 0 or addedIndexes > 0 then
        print(('[crimson-hitman] schema migration: %d column(s), %d index(es) added')
            :format(addedColumns, addedIndexes))
    end

    return addedColumns, addedIndexes
end

--- What the crimson_* tables hold, for a server started in another mode
--- (main.lua's refuseModeSwitch): escrow lines not yet settled, and payouts
--- owed to players who were offline. Creates nothing: a database this
--- resource never used answers zero.
---@return table { lines, owed }
function MySQLStore.inspect()
    local rows = db.query([[
        SELECT TABLE_NAME FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('crimson_escrow', 'crimson_pending')
    ]]) or {}
    local have = {}
    for i = 1, #rows do have[tostring(rows[i].TABLE_NAME or rows[i].table_name)] = true end

    local out = { lines = 0, owed = 0 }
    if have.crimson_escrow then
        out.lines = tonumber(db.scalar(
            "SELECT COUNT(*) FROM crimson_escrow WHERE state <> 'settled'")) or 0
    end
    if have.crimson_pending then
        out.owed = tonumber(db.scalar('SELECT COUNT(*) FROM crimson_pending')) or 0
    end
    return out
end

function MySQLStore.open()
    for i = 1, #SCHEMA do
        db.query(SCHEMA[i])
    end

    -- A table that already existed keeps whatever shape it had, so the
    -- statements above are not enough on their own.
    MySQLStore.migrate()

    local highest = db.scalar('SELECT COUNT(*) FROM crimson_contracts') or 0
    seq = tonumber(highest) or 0
    return true
end

function MySQLStore.nextId(prefix)
    seq = seq + 1
    -- Zero-padded, because Util.toId refuses anything under eight
    -- characters. Unpadded, the clock component is a single digit for ten
    -- seconds out of every twenty-eight hours, and every contract minted in
    -- that window carried an id the handlers would reject as malformed.
    return string.format('%s%05d%04d', prefix, os.time() % 100000, seq % 10000)
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
    db.query([[
        INSERT INTO crimson_contracts
            (id, creator_cid, creator_account, creator_name, target_cid, target_account,
             target_name, target_protected, target_job, reason, mode, state, anon_creator, bonus_percent,
             bailout_amount, penalty_amount, payout_slots, slots_claimed, next_slot,
             created_at, deadline_at, expires_at, paused_ms, paused_since,
             bailout_queued_at, bailout_paid_by, bailout_paid_amount, bailout_paid_account,
             bailout_attempts, resolved_at, resolution)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        -- Every column a caller can change after creation has to be in this
        -- list. Two were missing, and both were invisible in memory and json
        -- mode, which is where the tests ran.
        --
        --   bonus_percent — raise_bonus escrows the DIFFERENCE between the
        --   stored percentage and the new one. The escrow lines were written,
        --   the column was not, so the stored figure stayed at whatever the
        --   contract was created with. The next raise then computed its
        --   difference from that stale base and took the same band out of the
        --   creator's pocket a second time, and the guard that refuses a
        --   raise to a percentage already reached never fired, so it could be
        --   done again and again. The board also went on showing the old
        --   percentage to every hitman.
        --
        --   expires_at — the absolute lifetime. Nothing extended one until
        --   the staff timer refresh did.
        --
        ON DUPLICATE KEY UPDATE
            reason = VALUES(reason), mode = VALUES(mode),
            bonus_percent = VALUES(bonus_percent), expires_at = VALUES(expires_at),
            bailout_amount = VALUES(bailout_amount), penalty_amount = VALUES(penalty_amount),
            -- next_slot, slots_claimed and payout_slots are deliberately
            -- absent, as they move only through advanceSlot and reduceSlots.
            -- Every other writer carries a copy read before its own awaits,
            -- and writing them back undid a claim that landed in between —
            -- the collection just paid was put back on sale — or put back a
            -- collection just given back by agreement.
            --
            -- And the clock — deadline_at, paused_ms, paused_since — moves
            -- only through setDeadline, startPause and endPause, for the
            -- same reason. The expiry pass wrote a copy over an
            -- extension the client made while it waited, and a copy written
            -- by anything else erased a pause the pass had just begun.
            -- The five bailout_* columns are deliberately absent, as they move
            -- only through setBailoutQueue, so a caller writing back a copy
            -- it read before a buyout was paid cannot erase the buyout.
            resolved_at = VALUES(resolved_at), resolution = VALUES(resolution)
    ]], {
        c.id, c.creator_cid, c.creator_account, c.creator_name, c.target_cid, c.target_account,
        c.target_name, c.target_protected and 1 or 0, c.target_job, c.reason, c.mode, c.state,
        c.anon_creator and 1 or 0, c.bonus_percent or 0, c.bailout_amount or 0,
        c.penalty_amount or 0, c.payout_slots or 1, c.slots_claimed or 0, c.next_slot or 1,
        c.created_at, c.deadline_at, c.expires_at, c.paused_ms or 0, c.paused_since,
        c.bailout_queued_at, c.bailout_paid_by, c.bailout_paid_amount, c.bailout_paid_account,
        c.bailout_attempts or 0, c.resolved_at, c.resolution,
    })
    return true
end

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
function MySQLStore.setBailoutQueue(id, fields)
    local affected
    if fields then
        affected = db.update([[
            UPDATE crimson_contracts
            SET bailout_queued_at = ?, bailout_paid_by = ?, bailout_paid_amount = ?,
                bailout_paid_account = ?, bailout_attempts = ?
            WHERE id = ?
        ]], { fields.bailout_queued_at, fields.bailout_paid_by,
              fields.bailout_paid_amount, fields.bailout_paid_account,
              fields.bailout_attempts or 0, id })
    else
        affected = db.update([[
            UPDATE crimson_contracts
            SET bailout_queued_at = NULL, bailout_paid_by = NULL,
                bailout_paid_amount = NULL, bailout_paid_account = NULL,
                bailout_attempts = 0
            WHERE id = ?
        ]], { id })
    end
    return (tonumber(affected) or 0) > 0
end

--- A TINYINT(1) column as the boolean the rest of the resource compares
--- against. oxmysql's typeCast hands these back as true and false, while a
--- driver without it hands back 0 and 1. Comparing with `== 1` read every
--- flag as false under oxmysql: anonymous parties were shown by name and an
--- officer target lost its flag.
local function flag(value)
    return value == true or (tonumber(value) or 0) ~= 0
end

local function hydrateContract(row)
    if not row then return nil end
    row.target_protected = flag(row.target_protected)
    row.anon_creator = flag(row.anon_creator)
    return row
end

function MySQLStore.readContract(id)
    local rows = db.query('SELECT * FROM crimson_contracts WHERE id = ?', { id })
    return hydrateContract(rows and rows[1])
end

function MySQLStore.allContracts()
    local rows = db.query('SELECT * FROM crimson_contracts ORDER BY id') or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

--- Contracts still running, active or accepted, served by idx_state. See
--- the memory backend. allContracts is SELECT * of the whole table, thirty
--- days of finished contracts as shipped, and the sampler asked for it once
--- a second: past a thousand rows oxmysql also printed its oversized-result
--- warning, every second.
function MySQLStore.liveContracts()
    local rows = db.query(
        "SELECT * FROM crimson_contracts WHERE state IN ('active', 'accepted') ORDER BY id") or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

--- Contracts this player is involved in, as creator, target or hitman.
--- The indexes for all three columns already exist, so this is the query
--- the schema was designed for — rather than a full scan filtered in Lua.
function MySQLStore.contractsInvolving(cid)
    local rows = db.query([[
        SELECT c.* FROM crimson_contracts c
        WHERE c.creator_cid = ? OR c.target_cid = ?
        UNION
        SELECT c.* FROM crimson_contracts c
        JOIN crimson_hitmen h ON h.contract_id = c.id
        WHERE h.hitman_cid = ?
        ORDER BY id
    ]], { cid, cid, cid }) or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

function MySQLStore.contractsNaming(cid)
    local rows = db.query(
        'SELECT * FROM crimson_contracts WHERE target_cid = ? ORDER BY id', { cid }) or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

--- Contracts with a buyout waiting out its delay.
---
--- The tick used to read every contract the server has ever held and filter
--- in Lua. There is rarely more than one of these and usually none.
function MySQLStore.queuedBailouts()
    local rows = db.query(
        'SELECT * FROM crimson_contracts WHERE bailout_queued_at IS NOT NULL ORDER BY id') or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

function MySQLStore.contractsBy(cid)
    local rows = db.query(
        'SELECT * FROM crimson_contracts WHERE creator_cid = ? ORDER BY id', { cid }) or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

--- Contracts created by any character on this account. The creator-side
--- limits belong to the player, not to whichever character they are on.
function MySQLStore.contractsByAccount(account)
    if account == nil then return {} end
    local rows = db.query(
        'SELECT * FROM crimson_contracts WHERE creator_account = ? ORDER BY id', { account }) or {}
    for i = 1, #rows do hydrateContract(rows[i]) end
    return rows
end

--- Conditional state write, done in one statement so it is atomic at the
--- database rather than in Lua (§9.7).
--- Advance the payout slot, only if it is still the one the caller acted on.
--- One guarded UPDATE rather than writing back a contract read before
--- several yielding calls; see the memory backend for what that erased.
function MySQLStore.advanceSlot(id, expectedSlot)
    local affected = db.update([[
        UPDATE crimson_contracts
        SET next_slot = ?, slots_claimed = slots_claimed + 1
        WHERE id = ? AND next_slot = ?
    ]], { expectedSlot + 1, id, expectedSlot })
    return (tonumber(affected) or 0) > 0
end

--- End a contract as expired only if it is still due, in the same
--- statement: see the memory backend.
function MySQLStore.expireIfDue(id, expected, next_, now, byLifetime)
    local affected
    if byLifetime then
        affected = db.update([[
            UPDATE crimson_contracts SET state = ?
            WHERE id = ? AND state = ? AND expires_at < ?
        ]], { next_, id, expected, now })
    else
        affected = db.update([[
            UPDATE crimson_contracts SET state = ?
            WHERE id = ? AND state = ? AND paused_since IS NULL AND deadline_at < ?
        ]], { next_, id, expected, now })
    end
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.reduceSlots(id, expected)
    if expected <= 1 then return false end
    -- Guarded on the collection being unclaimed and no claim holding the
    -- contract, not only on the count (see Memory.reduceSlots).
    local affected = db.update([[
        UPDATE crimson_contracts SET payout_slots = ?
        WHERE id = ? AND payout_slots = ? AND next_slot < ? AND state IN ('active', 'accepted')
    ]], { expected - 1, id, expected, expected })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.setDeadline(id, expected, deadline)
    local affected
    if expected ~= nil then
        affected = db.update(
            'UPDATE crimson_contracts SET deadline_at = ? WHERE id = ? AND deadline_at = ?',
            { deadline, id, expected })
    else
        affected = db.update(
            'UPDATE crimson_contracts SET deadline_at = ? WHERE id = ?', { deadline, id })
    end
    return (tonumber(affected) or 0) > 0
end

--- The reason alone. An edit that wrote back the whole row it read put back
--- the buyout and the stake a concurrent re-clamp had just lowered.
--- Write only the named fields of a contract. Every other writer used to
--- read the row, await, and write the whole copy back, undoing whatever
--- changed in between: a re-clamp of the buyout and stake, a bonus raise,
--- an ending's resolution. Only these columns, and never the state, the
--- slot counters, the clock or the buyout queue, which have their own.
-- One literal statement per column: no SQL is ever built from a name.
local SETTABLE = {
    reason = 'UPDATE crimson_contracts SET reason = ? WHERE id = ?',
    mode = 'UPDATE crimson_contracts SET mode = ? WHERE id = ?',
    bonus_percent = 'UPDATE crimson_contracts SET bonus_percent = ? WHERE id = ?',
    bailout_amount = 'UPDATE crimson_contracts SET bailout_amount = ? WHERE id = ?',
    penalty_amount = 'UPDATE crimson_contracts SET penalty_amount = ? WHERE id = ?',
    resolved_at = 'UPDATE crimson_contracts SET resolved_at = ? WHERE id = ?',
    resolution = 'UPDATE crimson_contracts SET resolution = ? WHERE id = ?',
    expires_at = 'UPDATE crimson_contracts SET expires_at = ? WHERE id = ?',
}
function MySQLStore.setContractFields(id, fields)
    for k in pairs(fields) do
        if not SETTABLE[k] then error('setContractFields: not a settable field: ' .. tostring(k)) end
    end
    for column, sql in pairs(SETTABLE) do
        if fields[column] ~= nil then db.update(sql, { fields[column], id }) end
    end
    return true
end

function MySQLStore.setReason(id, reason)
    local affected = db.update(
        'UPDATE crimson_contracts SET reason = ? WHERE id = ?', { reason, id })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.startPause(id, at)
    local affected = db.update(
        'UPDATE crimson_contracts SET paused_since = ? WHERE id = ? AND paused_since IS NULL',
        { at, id })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.endPause(id, since, seconds)
    local affected = db.update([[
        UPDATE crimson_contracts
        SET deadline_at = deadline_at + ?, paused_ms = paused_ms + ?, paused_since = NULL
        WHERE id = ? AND paused_since = ?
    ]], { seconds, seconds * 1000, id, since })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.compareSetContractState(id, expected, next_)
    local affected = db.update(
        'UPDATE crimson_contracts SET state = ? WHERE id = ? AND state = ?',
        { next_, id, expected })
    return (tonumber(affected) or 0) > 0
end

--------------------------------------------------------------------------
-- Escrow
--------------------------------------------------------------------------

--- Every line in one transaction: a reader sees all of a write or none of it.
--- A statement a line let a reader land between two of them. A claim marks
--- each line of the collection it pays — the baseline for its hitman, an
--- elimination's bonus back to the client — and a top-up that found its
--- baseline marked and its bonus not handed the bonus back and was told it
--- had failed, while the hitman was paid the baseline.
local ESCROW_UPSERT = [[
    INSERT INTO crimson_escrow
        (id, contract_id, slot, line_portion, source, amount, item, quantity, metadata,
         staker, inv_slot, owed_to, releasing_to, state, derived, taken_from)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    -- State and amount are NOT written here, as they move only through
    -- claimEscrowLine / settleEscrowLine / setEscrowAmount, which are
    -- guarded. Writing them from a caller-held copy could resurrect a
    -- line that settled while the caller was reading.
    ON DUPLICATE KEY UPDATE owed_to = VALUES(owed_to),
        releasing_to = VALUES(releasing_to)
]]

local function escrowParams(contractId, l)
    return {
        l.id, contractId, l.slot or 1, l.portion, l.source, l.amount or 0,
        l.item, l.quantity or 0, l.metadata and json.encode(l.metadata) or nil,
        l.staker, l.inv_slot, l.owed_to, l.releasing_to, l.state,
        -- Whether this resource worked the bonus out, or the creator
        -- named it. Escrow.bonusTopUp raises only the former, so a line
        -- that loses this flag is a slot raise_bonus will not touch —
        -- and with no column at all, that was every slot on this
        -- backend.
        l.derived and 1 or 0,
        -- Never updated, like the staker: who put the line up does not
        -- change. See MySQLStore.orphanEscrow.
        l.taken_from,
    }
end

function MySQLStore.writeEscrow(contractId, lines)
    if #lines == 0 then return true end
    if #lines == 1 then
        db.query(ESCROW_UPSERT, escrowParams(contractId, lines[1]))
        return true
    end
    local queries = {}
    for i = 1, #lines do
        queries[i] = { query = ESCROW_UPSERT, values = escrowParams(contractId, lines[i]) }
    end
    return db.transaction(queries) ~= false
end

local function hydrateEscrow(row)
    if not row then return row end
    if row.metadata and type(row.metadata) == 'string' then
        local ok, decoded = pcall(json.decode, row.metadata)
        row.metadata = ok and decoded or nil
    end
    -- Back to the boolean the rest of the resource compares against. A 0
    -- from the database is truthy in Lua, so leaving it as a number would
    -- make every line look derived rather than none of them.
    row.derived = flag(row.derived) or nil
    -- The column is line_portion only because PORTION is reserved on
    -- MariaDB (see SCHEMA); every caller reads line.portion.
    row.portion, row.line_portion = row.line_portion, nil
    return row
end

--- The audit detail, as the table it was written as.
---
--- Stored as JSON text and handed straight back as text. Indexing a string
--- in Lua is nil rather than an error, so every reader of a detail field
--- quietly found nothing: /ch-stuck walks the log for release_interrupted
--- rows and reads detail.line, and reported "No interrupted releases" every
--- time, on every server, however much escrow was actually stuck.
local function hydrateAudit(row)
    if row and type(row.detail) == 'string' then
        local ok, decoded = pcall(json.decode, row.detail)
        row.detail = (ok and type(decoded) == 'table') and decoded or nil
    end
    return row
end

local function hydrateAuditRows(rows)
    for i = 1, #rows do hydrateAudit(rows[i]) end
    return rows
end

function MySQLStore.readEscrow(contractId)
    local rows = db.query(
        'SELECT * FROM crimson_escrow WHERE contract_id = ? ORDER BY id', { contractId }) or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

function MySQLStore.readEscrowLine(id)
    local rows = db.query('SELECT * FROM crimson_escrow WHERE id = ?', { id })
    return hydrateEscrow(rows and rows[1])
end

--- Escrow not yet settled whose contract does not exist; see the memory
--- backend. Read once, at boot.
--- Every contract holding an escrow line that is not settled, as a set.
---
--- Read once at boot, in one query served by idx_state. Recovery acts on
--- nothing else of a finished contract, and it asked every contract the
--- table keeps for its lines, twice, before the app answered anybody: some
--- four awaited queries per contract, thirty days of them.
function MySQLStore.unsettledEscrowContracts()
    local rows = db.query(
        "SELECT DISTINCT contract_id FROM crimson_escrow WHERE state IN ('held', 'releasing')") or {}
    local out = {}
    for i = 1, #rows do
        if rows[i].contract_id ~= nil then out[rows[i].contract_id] = true end
    end
    return out
end

function MySQLStore.orphanEscrow()
    local rows = db.query([[
        SELECT * FROM crimson_escrow e
        WHERE e.state IN ('held', 'releasing')
          AND NOT EXISTS (
              SELECT 1 FROM crimson_contracts c WHERE c.id = e.contract_id)
        ORDER BY id
    ]]) or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

--- The compare-and-set that makes double release impossible (§14.3).
--- One statement, so the check and the write cannot be interleaved.
function MySQLStore.claimEscrowLine(id, expected, next_)
    local affected = db.update(
        'UPDATE crimson_escrow SET state = ? WHERE id = ? AND state = ?',
        { next_, id, expected })
    return (tonumber(affected) or 0) > 0
end

--- Guarded amount change, in one statement so the check and the write
--- cannot be interleaved. State is deliberately not written here.
function MySQLStore.setEscrowAmount(id, expectedState, amount, expectedAmount)
    local affected
    if expectedAmount ~= nil then
        affected = db.update(
            'UPDATE crimson_escrow SET amount = ? WHERE id = ? AND state = ? AND amount = ?',
            { amount, id, expectedState, expectedAmount })
    else
        affected = db.update(
            'UPDATE crimson_escrow SET amount = ? WHERE id = ? AND state = ?',
            { amount, id, expectedState })
    end
    return (tonumber(affected) or 0) > 0
end

--- Settle a line this caller holds.
---
--- Guarded on `releasing`, because both callers settle only after claiming
--- held -> releasing. Without the guard the write was `WHERE id = ?`: it
--- would settle a line something else had taken back — restart recovery
--- returning a stuck `releasing` line to `held`, or a second server
--- instance on the same database — which is a line paid twice and recorded
--- once.
function MySQLStore.settleEscrowLine(id, recipientCid)
    local affected = db.update(
        'UPDATE crimson_escrow SET state = ?, settled_to = ?, settled_at = ? '
        .. 'WHERE id = ? AND state = ?',
        { CH.ESCROW_STATE.SETTLED, recipientCid, os.time(), id, CH.ESCROW_STATE.RELEASING })
    return (tonumber(affected) or 0) > 0
end

--------------------------------------------------------------------------
-- Hitmen
--------------------------------------------------------------------------

function MySQLStore.addHitman(h)
    db.query([[
        INSERT INTO crimson_hitmen
            (id, contract_id, hitman_cid, hitman_account, hitman_name, alias, anon,
             accepted_at, state, claims)
        VALUES (?,?,?,?,?,?,?,?,?,?)
    ]], {
        h.id, h.contract_id, h.hitman_cid, h.hitman_account, h.hitman_name, h.alias,
        h.anon and 1 or 0, h.accepted_at, h.state, h.claims or 0,
    })
    return true
end

local function hydrateHitman(row)
    if row then row.anon = flag(row.anon) end
    return row
end

function MySQLStore.readHitmen(contractId)
    local rows = db.query(
        'SELECT * FROM crimson_hitmen WHERE contract_id = ? ORDER BY accepted_at, id',
        { contractId }) or {}
    for i = 1, #rows do hydrateHitman(rows[i]) end
    return rows
end

function MySQLStore.readHitman(contractId, cid)
    local rows = db.query(
        'SELECT * FROM crimson_hitmen WHERE contract_id = ? AND hitman_cid = ?',
        { contractId, cid })
    return hydrateHitman(rows and rows[1])
end

--- One hitman row by its own id.
---
--- Used to confirm an id is free before minting onto it: the stake is taken
--- before the row is written, so an id already in use is a duplicate-key
--- error with the money already gone and no record naming who staked it.
function MySQLStore.readHitmanById(id)
    local rows = db.query('SELECT * FROM crimson_hitmen WHERE id = ?', { id })
    return hydrateHitman(rows and rows[1])
end

function MySQLStore.updateHitman(id, fields)
    -- Column names are literals here, never interpolated from the caller.
    if fields.state ~= nil then
        db.update('UPDATE crimson_hitmen SET state = ? WHERE id = ?', { fields.state, id })
    end
    if fields.left_at ~= nil then
        db.update('UPDATE crimson_hitmen SET left_at = ? WHERE id = ?', { fields.left_at, id })
    end
    if fields.last_claim_at ~= nil then
        db.update('UPDATE crimson_hitmen SET last_claim_at = ? WHERE id = ?', { fields.last_claim_at, id })
    end
    if fields.claims ~= nil then
        db.update('UPDATE crimson_hitmen SET claims = ? WHERE id = ?', { fields.claims, id })
    end
    -- A hitman who could not cover the anonymity fee is named instead. This
    -- branch was missing, so on the backend that ships by default the write
    -- was dropped: the hitman stayed listed as anonymous having paid nothing
    -- for it, and only on mysql.
    if fields.anon ~= nil then
        db.update('UPDATE crimson_hitmen SET anon = ? WHERE id = ?',
            { fields.anon and 1 or 0, id })
    end
    if fields.alias ~= nil then
        db.update('UPDATE crimson_hitmen SET alias = ? WHERE id = ?',
            { fields.alias, id })
    end
    -- A stint's start, rewritten when a hitman takes a contract up again.
    if fields.accepted_at ~= nil then
        db.update('UPDATE crimson_hitmen SET accepted_at = ? WHERE id = ?',
            { fields.accepted_at, id })
    end
    return true
end

--- The row goes active only if it is still the acceptance that wrote it.
function MySQLStore.confirmHitman(id, anon, acceptedAt)
    local affected = db.update([[
        UPDATE crimson_hitmen SET state = 'active', anon = ?, accepted_at = ?
        WHERE id = ? AND state IN ('joining', 'rejoining')
    ]], { anon and 1 or 0, acceptedAt, id })
    return (tonumber(affected) or 0) > 0
end

--- Mid-acceptance rows count: two acceptances in flight must each see the
--- other against the cap.
function MySQLStore.countHitmanContracts(cid, states)
    local rows = db.query([[
        SELECT c.state AS state FROM crimson_hitmen h
        JOIN crimson_contracts c ON c.id = h.contract_id
        WHERE h.hitman_cid = ? AND h.state IN ('active', 'joining', 'rejoining')
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
    db.query([[
        INSERT INTO crimson_amendments
            (id, contract_id, proposer, kind, payload, approvals, expires_at, outcome, declined_by)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            approvals = VALUES(approvals), outcome = VALUES(outcome),
            declined_by = VALUES(declined_by),
            -- Left out of this list, and so silently discarded on the backend
            -- that ships by default. A proposal re-written with a new expiry
            -- kept the old one. Nothing rewrote an expiry until the staff
            -- timer refresh did, and it would have worked in memory mode and
            -- done nothing on a real server.
            expires_at = VALUES(expires_at)
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
    local rows = db.query('SELECT * FROM crimson_amendments WHERE id = ?', { id })
    return hydrateAmendment(rows and rows[1])
end

--- Every contract with a proposal still open, as a set: one query at boot,
--- where the amendment expiry's index asked every contract kept.
function MySQLStore.openAmendmentContracts()
    local rows = db.query(
        "SELECT DISTINCT contract_id FROM crimson_amendments WHERE outcome = 'open'") or {}
    local out = {}
    for i = 1, #rows do
        if rows[i].contract_id ~= nil then out[rows[i].contract_id] = true end
    end
    return out
end

function MySQLStore.readOpenAmendments(contractId)
    local rows = db.query(
        "SELECT * FROM crimson_amendments WHERE contract_id = ? AND outcome = 'open'",
        { contractId }) or {}
    for i = 1, #rows do hydrateAmendment(rows[i]) end
    return rows
end

function MySQLStore.writeMessage(m)
    db.query([[
        INSERT INTO crimson_messages (contract_id, thread_id, from_cid, from_alias, body, sent_at)
        VALUES (?,?,?,?,?,?)
    ]], { m.contract_id, m.thread_id, m.from_cid, m.from_alias, m.body, m.sent_at })
    -- Only the newest Config.Relay.MaxMessagesPerThread stay, as the
    -- ledger keeps its depth.
    local keep = tonumber(Config.Relay.MaxMessagesPerThread) or 0
    if keep > 0 then
        db.query([[
            DELETE FROM crimson_messages WHERE thread_id = ? AND contract_id = ? AND id NOT IN (
                SELECT id FROM (
                    SELECT id FROM crimson_messages WHERE thread_id = ? AND contract_id = ?
                    ORDER BY id DESC LIMIT ?
                ) keep
            )
        ]], { m.thread_id, m.contract_id, m.thread_id, m.contract_id, keep })
    end
    return true
end

function MySQLStore.readMessages(contractId, threadId)
    return db.query(
        'SELECT * FROM crimson_messages WHERE contract_id = ? AND thread_id = ? ORDER BY id',
        { contractId, threadId }) or {}
end

function MySQLStore.writeLedger(entry)
    db.query([[
        INSERT INTO crimson_ledger
            (cid, contract_id, role, target_name, reason, fulfilment, slot, photo_ref, resolved_at)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], {
        entry.cid, entry.contract_id, entry.role, entry.target_name, entry.reason,
        entry.fulfilment, entry.slot or 1, entry.photo_ref, entry.resolved_at,
    })
    -- Keep the footprint small: prune anything past the configured depth.
    db.query([[
        DELETE FROM crimson_ledger WHERE cid = ? AND id NOT IN (
            SELECT id FROM (
                SELECT id FROM crimson_ledger WHERE cid = ? ORDER BY resolved_at DESC LIMIT ?
            ) keep
        )
    ]], { entry.cid, entry.cid, math.min(Config.Ledger.Depth, Config.Ledger.MaxDepthHardCap) })
    return true
end

function MySQLStore.readLedger(cid, depth)
    return db.query(
        'SELECT * FROM crimson_ledger WHERE cid = ? ORDER BY resolved_at DESC LIMIT ?',
        { cid, depth }) or {}
end

function MySQLStore.queuePending(cid, contractId, lineId)
    -- Random, not the clock and a sequence: the sequence starts again at
    -- every boot, so a restart within the same second minted the ids of
    -- entries already queued, and ON DUPLICATE KEY UPDATE landed the new
    -- entry on top of an old one — one owed payment silently unqueued.
    db.query([[
        INSERT INTO crimson_pending (id, cid, contract_id, line_id, queued_at)
        VALUES (?,?,?,?,?)
        ON DUPLICATE KEY UPDATE queued_at = VALUES(queued_at)
    ]], {
        Util.randomId('pnd'), cid, contractId, lineId, os.time(),
    })
    return true
end

function MySQLStore.readPending(cid)
    return db.query(
        'SELECT * FROM crimson_pending WHERE cid = ? ORDER BY queued_at', { cid }) or {}
end

function MySQLStore.clearPending(id)
    db.query('DELETE FROM crimson_pending WHERE id = ?', { id })
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
        db.query([[INSERT INTO crimson_stats (cid, completed) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE completed = completed + VALUES(completed)]], { cid, amount })
    elseif field == 'failed' then
        db.query([[INSERT INTO crimson_stats (cid, failed) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE failed = failed + VALUES(failed)]], { cid, amount })
    elseif field == 'placed' then
        db.query([[INSERT INTO crimson_stats (cid, placed) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE placed = placed + VALUES(placed)]], { cid, amount })
    else
        db.query([[INSERT INTO crimson_stats (cid, survived) VALUES (?, ?)
            ON DUPLICATE KEY UPDATE survived = survived + VALUES(survived)]], { cid, amount })
    end

    return amount
end

function MySQLStore.readStats(cid)
    local rows = db.query('SELECT * FROM crimson_stats WHERE cid = ?', { cid })
    return (rows and rows[1])
        or { cid = cid, completed = 0, failed = 0, placed = 0, survived = 0 }
end

local AUDIT_INSERT = [[
    INSERT INTO crimson_audit (ts, kind, action, actor_cid, contract_id, detail)
    VALUES (?,?,?,?,?,?)
]]

local function auditParams(entry)
    return { entry.ts, entry.kind, entry.action, entry.actor_cid, entry.contract_id,
             json.encode(entry.detail or {}) }
end

function MySQLStore.writeAudit(entry)
    db.query(AUDIT_INSERT, auditParams(entry))
    return true
end

--- Several rows in one INSERT, for the flush (Audit.flush chunks them).
---
--- writeAudit is one awaited round trip a row, and the flush is the tick's
--- first job: a busy ten seconds (a kill payout alone writes eight rows,
--- and the queue holds up to five thousand) kept every job after it waiting
--- on the database a row at a time. One statement is all or nothing, so a
--- batch the database refuses has written none of itself, and the flush
--- writes those rows one by one instead.
---@param entries table[]
function MySQLStore.writeAuditBatch(entries)
    if #entries == 0 then return true end
    local groups, params = {}, {}
    for i = 1, #entries do
        local row = auditParams(entries[i])
        groups[i] = '(?,?,?,?,?,?)'
        for j = 1, 6 do params[#params + 1] = row[j] end
    end
    db.query('INSERT INTO crimson_audit (ts, kind, action, actor_cid, contract_id, detail) '
        .. 'VALUES ' .. table.concat(groups, ','), params)
    return true
end

--- The same row, handed to oxmysql without waiting for the answer. Only for
--- the resource stopping (Audit.flush(true)).
---
--- An event handler runs as a coroutine, and an await yields it until the
--- database answers. At a stop nothing resumes it: the stop carries on and
--- this resource's Lua is torn down. So the flush on the way out wrote its
--- first row, yielded on it, and every row behind it — up to ten seconds of
--- them, financial ones among them — was gone, on every restart. Each call
--- here reaches oxmysql before it returns, so every row is on its way before
--- the runtime goes.
function MySQLStore.writeAuditNoWait(entry)
    MySQL.insert(AUDIT_INSERT, auditParams(entry))
    return true
end

function MySQLStore.readAudit(limit)
    return hydrateAuditRows(
        db.query('SELECT * FROM crimson_audit ORDER BY id DESC LIMIT ?',
            { limit or 100 }) or {})
end

--- Every audit row naming one contract, oldest first. Indexed, so the
--- admin timeline is a lookup rather than a scan of the whole log.
---
--- The LATEST `limit` rows, as the other backends return. This took the
--- first ones, so on a contract with more history than the limit — a relay
--- conversation writes a row per message — the timeline stopped at its
--- two-hundredth event and never showed what staff were asking about, and
--- /ch-stuck, which reads this for release_interrupted rows, reported a
--- stuck release as nothing at all.
function MySQLStore.auditForContract(contractId, limit)
    local newest = db.query(
        'SELECT * FROM crimson_audit WHERE contract_id = ? ORDER BY id DESC LIMIT ?',
        { contractId, limit or 200 }) or {}
    local rows = {}
    for i = #newest, 1, -1 do rows[#rows + 1] = newest[i] end
    return hydrateAuditRows(rows)
end

--- Every audit row with one action, oldest first, the newest `limit` of
--- them: one query, where /ch-stuck asked once per contract.
function MySQLStore.auditByAction(action, limit)
    local newest = db.query(
        'SELECT * FROM crimson_audit WHERE action = ? ORDER BY id DESC LIMIT ?',
        { action, limit or 500 }) or {}
    local rows = {}
    for i = #newest, 1, -1 do rows[#rows + 1] = newest[i] end
    return hydrateAuditRows(rows)
end

--- Drop the photo reference from rows older than the cutoff (§14.43).
--- One indexed UPDATE rather than reading the ledger into Lua.
function MySQLStore.forgetLedgerPhotos(cutoff)
    local affected = db.update(
        'UPDATE crimson_ledger SET photo_ref = NULL WHERE resolved_at < ? AND photo_ref IS NOT NULL',
        { cutoff })
    return tonumber(affected) or 0
end

function MySQLStore.prune()
    -- 0 keeps the log, as the retention settings beside it do.
    local auditDays = tonumber(Config.Audit.RetentionDays) or 0
    if auditDays > 0 then
        db.query('DELETE FROM crimson_audit WHERE ts < ?',
            { os.time() - (auditDays * 86400) })
    end

    local days = Config.Audit.ContractRetentionDays or 0
    if days > 0 then MySQLStore.pruneContracts(os.time() - (days * 86400)) end
    return true
end

--- Remove finished contracts, and the rows that hang off them, past the
--- retention age.
---
--- Nothing did this, so every full scan in the resource walked the server's
--- entire history rather than its live board and grew without bound.
---
--- Four conditions, and the last two are the ones that matter: a contract is
--- only removed when it is terminal, older than the cutoff, holds no escrow
--- line that is not settled, and owes nobody anything on their next login.
--- A contract whose creator was offline when it closed holds their money in
--- a `held` OWED line with a crimson_pending row pointing at it, and
--- deleting either would take that money with it.
---
--- The ledger is deliberately untouched: it is the player's own record of
--- what they did and carries its own copy of the target name and reason, so
--- it survives the contract it describes.
---@param cutoff integer
---@return integer removed
function MySQLStore.pruneContracts(cutoff)
    local rows = db.query([[
        SELECT c.id FROM crimson_contracts c
        WHERE c.state IN ('completed', 'bailed_out', 'expired', 'cancelled', 'voided')
          AND c.resolved_at IS NOT NULL
          AND c.resolved_at < ?
          AND NOT EXISTS (
              SELECT 1 FROM crimson_escrow e
              WHERE e.contract_id = c.id AND e.state <> 'settled')
          AND NOT EXISTS (
              SELECT 1 FROM crimson_pending p WHERE p.contract_id = c.id)
        ORDER BY c.resolved_at
        LIMIT ?
    ]], { cutoff, Config.Audit.ContractsPrunedPerTick or 200 }) or {}

    local removed = 0
    for i = 1, #rows do
        local id = rows[i].id
        if id then
            db.query('DELETE FROM crimson_escrow WHERE contract_id = ?', { id })
            db.query('DELETE FROM crimson_hitmen WHERE contract_id = ?', { id })
            db.query('DELETE FROM crimson_amendments WHERE contract_id = ?', { id })
            db.query('DELETE FROM crimson_messages WHERE contract_id = ?', { id })
            db.query('DELETE FROM crimson_reveals WHERE contract_id = ?', { id })
            db.query('DELETE FROM crimson_mutes WHERE contract_id = ?', { id })
            db.query('DELETE FROM crimson_contracts WHERE id = ?', { id })
            removed = removed + 1
        end
    end
    return removed
end

--- What one buyer's informant purchases on one contract have bought; see the
--- memory backend.
function MySQLStore.readReveal(contractId, buyerCid)
    local rows = db.query('SELECT * FROM crimson_reveals WHERE id = ?',
        { contractId .. ':' .. buyerCid }) or {}
    return rows[1]
end

function MySQLStore.writeReveal(contractId, buyerCid, record)
    db.query([[
        INSERT INTO crimson_reveals
            (id, contract_id, buyer_cid, hitman_cid, revealed_at, purchases, seed, answer)
        VALUES (?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE hitman_cid = VALUES(hitman_cid),
            revealed_at = VALUES(revealed_at), purchases = VALUES(purchases),
            seed = VALUES(seed), answer = VALUES(answer)
    ]], {
        contractId .. ':' .. buyerCid, contractId, buyerCid, record.hitman_cid,
        record.revealed_at, record.purchases or 0, record.seed, record.answer,
    })
    return true
end

function MySQLStore.clearReveals(contractId)
    db.query('DELETE FROM crimson_reveals WHERE contract_id = ?', { contractId })
    return true
end

--- Threads somebody has muted; see the memory backend.
function MySQLStore.readMute(threadId, cid)
    local rows = db.query('SELECT id FROM crimson_mutes WHERE id = ?',
        { threadId .. ':' .. cid }) or {}
    return rows[1] ~= nil
end

function MySQLStore.setMute(contractId, threadId, cid, muted, at)
    local id = threadId .. ':' .. cid
    if muted then
        db.query([[
            INSERT INTO crimson_mutes (id, contract_id, thread_id, cid, muted_at)
            VALUES (?,?,?,?,?)
            ON DUPLICATE KEY UPDATE muted_at = VALUES(muted_at)
        ]], { id, contractId, threadId, cid, at })
    else
        db.query('DELETE FROM crimson_mutes WHERE id = ?', { id })
    end
    return true
end

--- Kill photos kept for a contract's client; see the memory backend. Every
--- state change is one guarded UPDATE, so two requests racing to open the
--- same photo cannot both be shown it.
function MySQLStore.writePhoto(r)
    db.query([[
        INSERT INTO crimson_photos
            (id, contract_id, slot, owner_cid, kind, url, file, mime, size, state,
             created_at, opened_at, saved_link)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    ]], {
        r.id, r.contract_id, r.slot or 1, r.owner_cid, r.kind, r.url, r.file, r.mime,
        r.size, r.state, r.created_at, r.opened_at, r.saved_link,
    })
    return true
end

function MySQLStore.readPhoto(id)
    local rows = db.query('SELECT * FROM crimson_photos WHERE id = ?', { id }) or {}
    return rows[1]
end

function MySQLStore.photosOf(ownerCid)
    return db.query(
        'SELECT * FROM crimson_photos WHERE owner_cid = ? ORDER BY created_at',
        { ownerCid }) or {}
end

function MySQLStore.photosForContract(contractId)
    return db.query(
        'SELECT * FROM crimson_photos WHERE contract_id = ? ORDER BY created_at',
        { contractId }) or {}
end

function MySQLStore.photosOpenedBefore(cutoff, limit, state)
    return db.query([[
        SELECT * FROM crimson_photos WHERE state = ? AND opened_at < ?
        ORDER BY created_at LIMIT ?
    ]], { state or 'open', cutoff, limit or 200 }) or {}
end

function MySQLStore.readPhotoByPublic(publicId)
    if type(publicId) ~= 'string' then return nil end
    local rows = db.query('SELECT * FROM crimson_photos WHERE public_id = ?',
        { publicId }) or {}
    return rows[1]
end

--- Summed here rather than in SQL: it is for /ch-diag, and the photos that
--- hold a file at all are the few waiting, kept or served.
function MySQLStore.photoTotals()
    local rows = db.query(
        'SELECT state, size FROM crimson_photos WHERE file IS NOT NULL') or {}
    local out = {}
    for i = 1, #rows do
        local total = out[rows[i].state] or { count = 0, bytes = 0 }
        total.count = total.count + 1
        total.bytes = total.bytes + (tonumber(rows[i].size) or 0)
        out[rows[i].state] = total
    end
    return out
end

function MySQLStore.photosCreatedBefore(cutoff, limit)
    return db.query([[
        SELECT * FROM crimson_photos
        WHERE created_at < ? AND state <> 'kept' AND public_id IS NULL
        ORDER BY created_at LIMIT ?
    ]], { cutoff, limit or 200 }) or {}
end

function MySQLStore.openPhoto(id, at)
    local affected = db.update(
        "UPDATE crimson_photos SET state = 'open', opened_at = ? WHERE id = ? AND state = 'pending'",
        { at, id })
    return (tonumber(affected) or 0) > 0
end

--- The link and the file name are cleared in the same statement that moves
--- the state, so no row is ever closed and still pointing at an image.
function MySQLStore.closePhoto(id, expected, next_, savedLink)
    local affected = db.update([[
        UPDATE crimson_photos SET state = ?, url = NULL, file = NULL, saved_link = ?,
            public_id = NULL, saved_phone = NULL
        WHERE id = ? AND state = ?
    ]], { next_, savedLink, id, expected })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.publishPhoto(id, expected, publicId, link, phone)
    local affected = db.update([[
        UPDATE crimson_photos SET public_id = ?, saved_link = ?, saved_phone = ?
        WHERE id = ? AND state = ? AND file IS NOT NULL
    ]], { publicId, link, phone, id, expected })
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.movePhoto(id, expected, next_)
    local affected = db.update(
        'UPDATE crimson_photos SET state = ? WHERE id = ? AND state = ?',
        { next_, id, expected })
    return (tonumber(affected) or 0) > 0
end

--- The file stays as it is when none is given: a kept link has none.
function MySQLStore.keepPhoto(id, expected, file)
    local affected
    if file then
        affected = db.update([[
            UPDATE crimson_photos SET state = 'kept', file = ?,
                public_id = NULL, saved_link = NULL, saved_phone = NULL
            WHERE id = ? AND state = ?
        ]], { file, id, expected })
    else
        affected = db.update([[
            UPDATE crimson_photos SET state = 'kept',
                public_id = NULL, saved_link = NULL, saved_phone = NULL
            WHERE id = ? AND state = ?
        ]], { id, expected })
    end
    return (tonumber(affected) or 0) > 0
end

function MySQLStore.deletePhoto(id)
    db.query('DELETE FROM crimson_photos WHERE id = ?', { id })
    return true
end

--- When this process was last known to be running. See main.lua's Recover.
function MySQLStore.heartbeat(at)
    db.query([[
        INSERT INTO crimson_meta (meta_key, meta_value) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE meta_value = VALUES(meta_value)
    ]], { 'heartbeat', at })
    return true
end

function MySQLStore.lastHeartbeat()
    local rows = db.query(
        'SELECT meta_value FROM crimson_meta WHERE meta_key = ?', { 'heartbeat' }) or {}
    return rows[1] and tonumber(rows[1].meta_value) or nil
end

function MySQLStore.flush() return true end
function MySQLStore.close() return true end

return MySQLStore
