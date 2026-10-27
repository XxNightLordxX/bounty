--- MySQL backend (§10).
---
--- Every statement is parameterized. There is no string concatenation into
--- SQL anywhere in this file, and no table or column name comes from config
--- or from a player — they are literals in this source.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')
local MySQLStore = {}

--- Every statement here waits on another process, which may never answer
--- (OXMYSQL.md §6). The review queue reads this to keep the item a payment's
--- recording write would open in resource KVP before that write is sent
--- (Review.prepare), so a restart while it waits loses no record of money
--- already taken.
MySQLStore.remote = true

local seq = 0

--------------------------------------------------------------------------
-- Bounded awaits and the breaker
--------------------------------------------------------------------------

--- Once oxmysql's pool exists, a statement that cannot get a connection is
--- never answered at all (OXMYSQL.md §6), and a thread waiting on it is
--- never resumed, so no pcall around it ever returns. An outage of a second
--- stopped the handover loop, the condition sampler and the maintenance
--- tick until a restart, left every request that was waiting holding its
--- busy keys, and destroyed the money of a create, an acceptance or a
--- buyout caught between its charge and its first write, with nothing to
--- say so. So every statement here runs in a thread of its own, raced
--- against Config.Database.QueryTimeoutSeconds: whichever settles first is
--- the answer, and an answer that comes after is counted and changes
--- nothing (a promise settles once).
---
--- And a breaker, so an outage does not drain oxmysql's shared pool: one
--- statement given up on starts one probe of the connection; only when that
--- goes unanswered too is the store taken to be down, every statement still
--- waiting is answered at once, and nothing more is sent until a probe (made
--- only when something asks, at most every PROBE_EVERY_MS) is answered. Two
--- console lines an outage, one as it starts and one as it ends.

--- Two ways a statement can end that the database itself never said.
--- Sent and unanswered: it may still run, once a lock frees or a
--- connection does, so a caller never decides on "the store does not have
--- it" after one (MySQLStore.timedOut).
local NO_ANSWER = 'crimson-hitman: the database did not answer within '
--- Never sent, because the store had already found the database gone: it
--- certainly did not run (MySQLStore.notSent).
local NOT_SENT = 'crimson-hitman: not sent, the database is not answering'

--- Words the driver uses for a connection lost under a statement: the
--- statement may or may not have committed (OXMYSQL.md §6), so for a caller
--- it is the same as no answer.
local LOST = { 'Connection lost', 'ECONNRESET', 'PROTOCOL_CONNECTION_LOST' }

local DDL_SECONDS = 600        -- schema changes at start: an index on a long audit log takes a while
local PROBE_MS = 3000          -- the probe of the connection, after a statement went unanswered
local PROBE_EVERY_MS = 5000    -- while down, at most one probe this often, and only when asked
local SLOW_MS = 2000           -- a statement waiting longer makes the store "not healthy"

--- What the breaker knows. `since` is os.time() the outage began, `gaveUp`
--- and `late` count statements given up on and answered after that, and
--- `lastWhat` is the last one given up on (its first words, never its values).
local health = { down = false, since = nil, gaveUp = 0, late = 0, lastWhat = nil,
                 probing = false, probedAt = nil }
local waiting = {}             -- [promise] = { since = Util.monotonicMs(), what = string, timer = id }

--- A statement's first 60 characters, whitespace squashed, or what a
--- transaction is: what the console and /ch-diag name it by. Never its
--- parameters (OXMYSQL.md §12.7): they carry citizen ids and names.
---@param sql string|table
---@return string
local function words(sql)
    if type(sql) == 'table' then return ('a transaction of %d statements'):format(#sql) end
    return (tostring(sql):gsub('%s+', ' '):gsub('^ ', ''):sub(1, 60))
end

--- How long one statement may wait, in ms, or 0 for no limit. `long` is a
--- schema change at start.
---@param long boolean|nil
---@return integer
local function limitMs(long)
    local seconds = tonumber(Config.Database.QueryTimeoutSeconds) or 10
    if seconds <= 0 then return 0 end
    if long then seconds = math.max(seconds, DDL_SECONDS) end
    return math.floor(seconds * 1000)
end

--- Said only in mysql mode: a json start asks the database once, whether
--- mysql mode still holds money (main.lua refuseModeSwitch), and says so
--- itself when it could not.
---@param text string
local function sayOutage(text)
    if Config.Database.Mode == 'mysql' then Log.always(text) else Log.debug(text) end
end

local probe

--- The store found the database gone: every statement still waiting is
--- answered now (sent, so each may still land), and nothing more is sent
--- until a probe is answered. Once an outage.
local function goDown()
    if health.down then return end
    health.down, health.since = true, os.time()
    local pending = {}
    for p, entry in pairs(waiting) do pending[#pending + 1] = { p = p, entry = entry } end
    waiting = {}
    for i = 1, #pending do
        local entry = pending[i].entry
        if entry.timer then ClearTimeout(entry.timer) end
        pending[i].p:resolve({ ok = false, value = ('%s%d s (%s); it may still run')
            :format(NO_ANSWER, math.floor(limitMs() / 1000), entry.what) })
    end
    sayOutage(('the database stopped answering ("%s" had no answer in %d s); what needs it is '
        .. 'refused until it answers (/%s)'):format(tostring(health.lastWhat),
        math.floor(limitMs() / 1000), tostring(Config.Admin.Commands.diagnose)))
end

--- A probe was answered. Said once an outage, and nothing at all when the
--- one slow statement that started the probe was all there was.
local function comeBack()
    if not health.down then return end
    local seconds = os.time() - (health.since or os.time())
    health.down, health.since = false, nil
    sayOutage(('the database answers again after %d s'):format(seconds))
end

--- One statement, in a thread of its own, raced against `ms` (0: no limit).
--- The answer travels packed, so a raised SQL error reaches the caller with
--- its words exactly as oxmysql raised them.
---@param kind string an oxmysql method
---@param ms integer
---@param what string words(sql)
---@param probing boolean|nil the probe itself, which the breaker does not count
local function awaitWithin(kind, ms, what, probing, ...)
    local p = promise.new()
    local args = table.pack(...)
    Citizen.CreateThreadNow(function()
        local ok, result = pcall(MySQL[kind].await, table.unpack(args, 1, args.n))
        if p.state ~= 0 then
            -- Given up on already: the caller was told, and this changes nothing.
            health.late = health.late + 1
            return
        end
        local entry = waiting[p]
        waiting[p] = nil
        if entry and entry.timer then ClearTimeout(entry.timer) end
        p:resolve({ ok = ok, value = result })
    end)
    -- Answered already (a parse error is raised without waiting).
    if p.state == 0 then
        local entry = { since = Util.monotonicMs(), what = what }
        waiting[p] = entry
        if ms > 0 then
            entry.timer = SetTimeout(ms, function()
                if p.state ~= 0 then return end
                waiting[p] = nil
                p:resolve({ ok = false, value = ('%s%d s (%s); it may still run')
                    :format(NO_ANSWER, math.floor(ms / 1000), what) })
                if not probing then
                    health.gaveUp = health.gaveUp + 1
                    health.lastWhat = what
                    if not health.down then probe() end
                end
            end)
        end
    end
    local answer = Citizen.Await(p)
    if not answer.ok then error(answer.value, 0) end
    return answer.value
end

--- Is the connection there? One `SELECT 1`, past the breaker, in a thread
--- of its own. No loop: it runs only when a statement went unanswered, or
--- while down when something asks the store for something.
probe = function()
    if health.probing then return end
    health.probing, health.probedAt = true, Util.monotonicMs()
    Citizen.CreateThreadNow(function()
        local answered = pcall(awaitWithin, 'scalar', PROBE_MS, 'SELECT 1', true, 'SELECT 1')
        health.probing = false
        if answered then comeBack() else goDown() end
    end)
end

--- A statement, unless the store has found the database gone: then it is
--- not sent at all, and a probe is made if none was made lately.
local function bounded(kind, long, ...)
    local what = words((...))
    if health.down then
        if not health.probing and (not health.probedAt
            or Util.monotonicMs() - health.probedAt >= PROBE_EVERY_MS) then
            probe()
        end
        error(('%s (%s)'):format(NOT_SENT, what), 0)
    end
    return awaitWithin(kind, limitMs(long), what, false, ...)
end

--- Every oxmysql await this file makes goes through `db`, so the time spent
--- waiting on the database can be told from the time spent working
--- (MySQLStore.timeWaitsWith, which main points at Timing.await). Without
--- it a maintenance job was charged for everything the server did while it
--- waited. Looked up at call time, as oxmysql's own table is. `db.ddl` is a
--- schema change, allowed DDL_SECONDS.
local awaitVia = function(fn, ...) return fn(...) end
local db = {}
for _, kind in ipairs({ 'query', 'update', 'insert', 'scalar', 'transaction' }) do
    local send = function(...) return bounded(kind, false, ...) end
    db[kind] = function(...) return awaitVia(send, ...) end
end
local sendDdl = function(...) return bounded('query', true, ...) end
db.ddl = function(...) return awaitVia(sendDdl, ...) end

--- Whether an error is a statement the database never answered: given up
--- on, never sent, or a connection lost under it. The database's answer is
--- missing in every one, so it may or may not have run; a caller never
--- decides on what the store does not hold after one. An SQL error, and a
--- transaction answering false, are answers.
---@param err any
---@return boolean
function MySQLStore.timedOut(err)
    local text = tostring(err)
    if text:find(NO_ANSWER, 1, true) or text:find(NOT_SENT, 1, true) then return true end
    for i = 1, #LOST do
        if text:find(LOST[i], 1, true) then return true end
    end
    return false
end

--- Whether an error is a statement that was never sent: it certainly did
--- not run. The audit flush queues such a batch again.
---@param err any
---@return boolean
function MySQLStore.notSent(err)
    return tostring(err):find(NOT_SENT, 1, true) ~= nil
end

--- Answering, with nothing waiting longer than SLOW_MS: an outage that began
--- a few seconds ago counts as one.
---@return boolean
function MySQLStore.healthy()
    if health.down then return false end
    local now = Util.monotonicMs()
    for _, entry in pairs(waiting) do
        if now - entry.since > SLOW_MS then return false end
    end
    return true
end

--- What the breaker knows, for /ch-diag: a copy of it, with `oldestMs` the
--- longest any statement still waiting has waited, and `oldestWhat` which.
---@return table
function MySQLStore.health()
    local out = {}
    for k, v in pairs(health) do out[k] = v end
    local now = Util.monotonicMs()
    for _, entry in pairs(waiting) do
        local age = now - entry.since
        if not out.oldestMs or age > out.oldestMs then out.oldestMs, out.oldestWhat = age, entry.what end
    end
    return out
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

--- Every table also names InnoDB rather than taking the server's default
--- engine. Escrow writes go through db.transaction, which is only atomic on
--- InnoDB: on MyISAM a failure half-way left half the lines written, and
--- migrate() converts a table an older version left on another engine. The
--- same statements are in install/sql/crimson_hitman.sql, for an owner who
--- imports them by hand (tests/storage_spec.lua holds the two together).

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
        -- How it may be completed, 'alive' or 'either' (CH.FULFILMENT_RULE),
        -- as it was placed, and it never changes after. Added to existing
        -- databases by migrate. NULL on older rows, which read as 'either',
        -- the terms they were taken on.
        fulfilment_rule VARCHAR(8),
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
        -- What the law enforcement advisory said of it, kept as each
        -- bulletin goes out (Notify.advisory), when the posting one went
        -- and the count the latest acceptance one carried. The
        -- whitelisted-job view reads a colleague's entry from these, never
        -- from the advisory as it is set now. Move only through setAdvised.
        -- Added to existing databases by migrate; NULL where none went.
        advised_posted_at INT,
        advised_hitmen INT,
        INDEX idx_state (state),
        INDEX idx_target (target_cid),
        INDEX idx_creator (creator_cid),
        -- Asked on every creation. Added to existing databases by migrate.
        INDEX idx_creator_account (creator_account),
        -- Read on every maintenance tick, and almost always empty. Added
        -- to existing databases by MySQLStore.migrate.
        INDEX idx_bailout_queued (bailout_queued_at),
        -- The prune asks every tick which finished contracts are old enough,
        -- and without it read the whole table to find none. Added to
        -- existing databases by MySQLStore.migrate.
        INDEX idx_resolved (resolved_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
        -- How many times giving it raised with nothing arriving, until staff
        -- settle it (Escrow.deliver); the limit at once when what arrived
        -- cannot be told. At the limit it waits for staff in /ch-stuck.
        -- NULL on older rows, as 0.
        deliver_raises INT DEFAULT 0,
        -- What the player held before the last give that raised, and how
        -- much of the line has reached them, since a later give hands over
        -- only the rest. Added to existing databases by migrate; NULL when
        -- none.
        deliver_before INT,
        deliver_arrived INT,
        -- Settled by staff without anything given (/ch-settle delivered),
        -- 'delivered', and who; settled_at says when. Added to existing
        -- databases by migrate; NULL on every other line.
        settled_by_staff VARCHAR(16),
        settled_staff VARCHAR(64),
        INDEX idx_contract (contract_id),
        INDEX idx_state (state)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
        -- Read by nothing and written by nothing. A stake is an escrow line
        -- (portion stake, staker the hitman), and the admin panel totals
        -- those; kept so no column that may hold data is dropped.
        stake_amount INT DEFAULT 0,
        state VARCHAR(16) NOT NULL,
        INDEX idx_contract (contract_id),
        INDEX idx_hitman (hitman_cid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_messages (
        id INT AUTO_INCREMENT PRIMARY KEY,
        contract_id VARCHAR(32) NOT NULL,
        thread_id VARCHAR(80) NOT NULL,
        from_cid VARCHAR(32) NOT NULL,
        from_alias VARCHAR(32) NOT NULL,
        body VARCHAR(255) NOT NULL,
        sent_at INT NOT NULL,
        INDEX idx_thread (thread_id),
        -- A pruned contract's messages are deleted by contract, which was a
        -- scan of every message (and a lock on each) per contract pruned.
        -- Added to existing databases by MySQLStore.migrate.
        INDEX idx_message_contract (contract_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_pending (
        id VARCHAR(32) PRIMARY KEY,
        cid VARCHAR(32) NOT NULL,
        contract_id VARCHAR(32),
        line_id VARCHAR(64) NOT NULL,
        queued_at INT NOT NULL,
        INDEX idx_cid (cid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    [[CREATE TABLE IF NOT EXISTS crimson_stats (
        cid VARCHAR(32) PRIMARY KEY,
        completed INT DEFAULT 0,
        failed INT DEFAULT 0,
        placed INT DEFAULT 0,
        survived INT DEFAULT 0
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
        INDEX idx_audit_contract (contract_id),
        -- The overview, a contract's page, /ch-stuck and /ch-settle read
        -- the rows of one rare action, and without this read the whole log
        -- to find them. Added to existing databases by MySQLStore.migrate.
        INDEX idx_audit_action (action)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- The review queue (server/review.lua): money events no rule here can
    -- settle by itself, kept until staff resolve them. `cids` are the
    -- parties by role, `items` the lines or goods involved and `known` what
    -- could be told (what arrived, the error), as JSON; `resolution` how it
    -- was resolved, by `resolved_by` at `resolved_at`. Created on an
    -- existing database by the CREATE TABLE IF NOT EXISTS at the next start,
    -- like any table added since.
    [[CREATE TABLE IF NOT EXISTS crimson_review (
        id VARCHAR(32) PRIMARY KEY,
        kind VARCHAR(48) NOT NULL,
        contract_id VARCHAR(32),
        cids TEXT,
        amount INT,
        account VARCHAR(16),
        items TEXT,
        known TEXT,
        created_at INT NOT NULL,
        state VARCHAR(16) NOT NULL,
        resolution TEXT,
        resolved_by VARCHAR(64),
        resolved_at INT,
        INDEX idx_review_state (state, created_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Settings staff changed from the admin panel (server/settings.lua),
    -- by config key ('Bailout.Enabled'), applied over config.lua at every
    -- start. The value is JSON, so a switch, a number, a word and a list of
    -- job names all keep their type. Created on an existing database by the
    -- CREATE TABLE IF NOT EXISTS at the next start, like any table added since.
    [[CREATE TABLE IF NOT EXISTS crimson_settings (
        setting_key VARCHAR(64) PRIMARY KEY,
        setting_value TEXT,
        set_by VARCHAR(64),
        set_at INT
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- The admin panel's alerts (server/alerts.lua): every line the console
    -- printed whatever Config.Debug said, one row each, the same line again
    -- counted on it (`occurrences`, the alert's count, from `first_at` to
    -- `last_at`; not `count`, which is a function's name and so a reserved
    -- word where sql_mode has IGNORE_SPACE), until staff acknowledge it. At
    -- most a few hundred rows, all read at start. Created on an existing
    -- database by the CREATE TABLE IF NOT EXISTS at the next start, like any
    -- table added since.
    [[CREATE TABLE IF NOT EXISTS crimson_alerts (
        id VARCHAR(32) PRIMARY KEY,
        level VARCHAR(16) NOT NULL,
        text TEXT NOT NULL,
        contract_id VARCHAR(64),
        first_at INT NOT NULL,
        last_at INT NOT NULL,
        occurrences INT NOT NULL DEFAULT 1,
        acknowledged_by VARCHAR(64),
        acknowledged_at INT
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Small facts about the store itself. Holds the heartbeat: when this
    -- process was last known to be running, so a boot can tell how long
    -- nobody could play.
    [[CREATE TABLE IF NOT EXISTS crimson_meta (
        meta_key VARCHAR(32) PRIMARY KEY,
        meta_value INT NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
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
-- in place except in the ways that keep every value: a column renamed
-- (RENAMED), a table converted to utf8mb4, which holds every character the
-- old character set could, and a table moved to InnoDB. An automatic
-- migration that can destroy a column is a worse problem than the one it
-- solves.
--
-- Each of these is run only for what the database says is missing, and
-- information_schema is asked first. So a database user who may not create
-- or alter tables starts on tables that are already right — imported from
-- install/sql/crimson_hitman.sql by a user who may — and one that is missing
-- something is told exactly what, instead of failing on a CREATE TABLE IF
-- NOT EXISTS it was never going to need (MySQL and MariaDB check the
-- privilege before they look for the table: error 1142).

--- Columns renamed since an older version made them: [table] = { old = new }.
--- Moved with CHANGE COLUMN, which keeps the values, before anything is
--- added, so the new name is never added beside the old one. The old name is
--- quoted, since it may be the very word that could not be used unquoted.
local RENAMED = {
    crimson_escrow = { portion = 'line_portion' },
}
MySQLStore.RENAMED = RENAMED

--- Column and index declarations for one CREATE TABLE statement, and the
--- column declared PRIMARY KEY.
---@return string|nil name
---@return table columns [ { name, definition } ] in declaration order
---@return table indexes [ { name, definition } ]
---@return string|nil key the primary key column
local function declarationsIn(sql)
    local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
    if not name then return nil, {}, {} end

    local columns, indexes, key = {}, {}, nil
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
                if trimmed:upper():find('PRIMARY KEY', 1, true) then key = key or head end
            end
        end
    end

    return name, columns, indexes, key
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

--- The crimson tables this database has, with the engine of each:
--- [name] = engine. Every crimson_* table this file declares is among them;
--- a table of the same prefix that it does not declare (another resource's)
--- is listed and never touched.
---@return table<string, string>
local function tablesPresent()
    local rows = db.query([[
        SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'crimson%'
    ]]) or {}
    local out = {}
    for i = 1, #rows do
        local name = rows[i].TABLE_NAME or rows[i].table_name
        if name ~= nil then out[tostring(name)] = tostring(rows[i].ENGINE or rows[i].engine or '') end
    end
    return out
end

--- What information_schema.COLUMNS says of one table, read once a start:
--- the check for a table that is not this resource's reads it first, and
--- migrate goes on from the same answer.
---@param table_ string
---@param cache table [table] = rows
---@return table rows
local function columnsOf(table_, cache)
    if cache[table_] == nil then
        cache[table_] = db.query([[
            SELECT COLUMN_NAME, COLUMN_KEY, CHARACTER_SET_NAME, COLLATION_NAME FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
        ]], { table_ }) or {}
    end
    return cache[table_]
end

--- The tables this file declares that are in the database and are not this
--- resource's: one whose declared primary key column is not there, or is
--- there and is not its primary key.
---
--- migrate took any table with a declared name for an older version of its
--- own, so another resource's crimson_settings (or crimson_audit, or
--- crimson_meta) was moved to InnoDB, rebuilt in utf8mb4 and given columns
--- before the start refused, on "Multiple primary key", as a missing grant.
--- Every table here has had the same key column since it was first made
--- (id; cid for crimson_stats; setting_key; meta_key), so a table without
--- it as its key is somebody else's.
---@param engines table<string, string> tablesPresent()
---@param cache table columnsOf's
---@return table[] { table, key }
local function foreignTables(engines, cache)
    local out = {}
    for i = 1, #SCHEMA do
        local table_, _, _, key = declarationsIn(SCHEMA[i])
        if table_ and key and engines[table_] then
            local keyed = false
            for _, row in ipairs(columnsOf(table_, cache)) do
                local column = tostring(row.COLUMN_NAME or row.column_name or ''):lower()
                local role = tostring(row.COLUMN_KEY or row.column_key or ''):upper()
                if column == key:lower() and role == 'PRI' then keyed = true end
            end
            if not keyed then out[#out + 1] = { table = table_, key = key } end
        end
    end
    return out
end

--- What to tell an owner whose database already has a table of one of
--- these names that is not this resource's. Nothing was changed.
---@param foreign table[] foreignTables()
---@return string
local function foreignRefused(foreign)
    if #foreign == 1 then
        return ('mysql mode cannot start: table %s already exists in this database and is not '
            .. 'this resource\'s (it has no %s primary key, which every version of it has had). '
            .. 'Nothing was changed. Rename that table, or give crimson-hitman a database of its '
            .. 'own, then start again.'):format(foreign[1].table, foreign[1].key)
    end
    local named = {}
    for i = 1, #foreign do
        named[i] = ('%s (it has no %s primary key)'):format(foreign[i].table, foreign[i].key)
    end
    return ('mysql mode cannot start: tables %s already exist in this database and are not '
        .. 'this resource\'s, whose tables have had those keys in every version. Nothing was '
        .. 'changed. Rename those tables, or give crimson-hitman a database of its own, then '
        .. 'start again.'):format(table.concat(named, ', '))
end

--- Make one schema change, or note that the database refused it. Every
--- change a start needs is tried, and what could not be made is reported
--- together (schemaRefused), rather than the first refusal standing for all.
---@param failed table what could not be made: { what, sql, err, whole }
---@param whole boolean|nil a whole table, which the install SQL makes
---@return boolean made
local function change(sql, what, failed, whole)
    local ok, err = pcall(db.ddl, sql)
    if ok then return true end
    -- Not a refusal: nothing answered it, so no grant would help.
    if MySQLStore.timedOut(err) then error(err, 0) end
    failed[#failed + 1] = { what = what, sql = sql, err = tostring(err), whole = whole }
    return false
end

--- What to tell an owner whose database user could not make a change the
--- tables need: each thing missing and the database's own reason, then how
--- to fix it, with the exact statements for a change to a table that exists.
---@param failed table[]
---@return string
local function schemaRefused(failed)
    local lines = {
        'mysql mode cannot start: the database is missing what it needs, and this database '
            .. 'user could not add it:',
    }
    local statements = {}
    for i = 1, #failed do
        local f = failed[i]
        lines[#lines + 1] = ('  - %s (%s)'):format(f.what, f.err)
        if not f.whole then
            statements[#statements + 1] = '    ' .. f.sql:gsub('%s+', ' ') .. ';'
        end
    end
    lines[#lines + 1] = 'Import install/sql/crimson_hitman.sql as a database user that may '
        .. 'create tables' .. (#statements > 0 and ', run the statements below as one that may '
        .. 'alter them,' or '') .. ' or grant this user CREATE, ALTER and INDEX on the '
        .. 'database; then start the resource again.'
    for i = 1, #statements do lines[#lines + 1] = statements[i] end
    return table.concat(lines, '\n')
end

--- Add whatever the declarations have and the database does not.
---
--- `failed` collects the changes the database refused (open passes its own
--- list); called without one, a refusal raises with the same report, and a
--- table that is not this resource's is refused first, with nothing changed
--- (open checks that itself, before it creates anything). `cache` is the
--- COLUMNS answers open already read (columnsOf).
---@param failed table|nil
---@param cache table|nil
---@return integer added columns
---@return integer added indexes
function MySQLStore.migrate(failed, cache)
    local addedColumns, addedIndexes = 0, 0
    local raiseAtEnd = failed == nil
    failed = failed or {}
    cache = cache or {}
    local engines = tablesPresent()
    if raiseAtEnd then
        local foreign = foreignTables(engines, cache)
        if #foreign > 0 then error(foreignRefused(foreign), 0) end
    end

    for i = 1, #SCHEMA do
        local table_, columns, indexes = declarationsIn(SCHEMA[i])

        if table_ and safeIdentifier(table_) then
            -- Moved to InnoDB first, once: escrow's transactions are only
            -- all-or-nothing there, and the changes below are then made on
            -- the engine the table keeps. A table an older version or an
            -- import made on MyISAM (the server's default engine, or a dump
            -- restored onto one) kept it, since CREATE TABLE IF NOT EXISTS
            -- never looks at a table it finds.
            local engine = engines[table_]
            if engine and engine ~= '' and engine:lower() ~= 'innodb' then
                if change(('ALTER TABLE %s ENGINE=InnoDB'):format(table_),
                    ('%s on the InnoDB engine (it is %s)'):format(table_, engine), failed) then
                    Log.debug(('migrated: moved %s from %s to InnoDB')
                        :format(table_, engine))
                end
            end

            local present = {}
            local rows = columnsOf(table_, cache)
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
                if change(('ALTER TABLE %s CONVERT TO CHARACTER SET %s COLLATE %s')
                    :format(table_, CHARSET, COLLATION),
                    ('%s in %s'):format(table_, COLLATION), failed) then
                    Log.debug(('migrated: converted %s to %s'):format(table_, COLLATION))
                end
            end

            -- Renamed before anything is added, so the new name is not added
            -- beside the old one with every row's value left behind.
            if next(present) and RENAMED[table_] then
                for j = 1, #columns do
                    local column = columns[j]
                    for old, new in pairs(RENAMED[table_]) do
                        if column.name == new and safeIdentifier(old) and safeIdentifier(new)
                            and present[old] and not present[new] then
                            if change(('ALTER TABLE %s CHANGE COLUMN `%s` %s')
                                :format(table_, old, column.definition),
                                ('column %s.%s, renamed from %s'):format(table_, new, old), failed) then
                                Log.debug(('migrated: renamed %s.%s to %s')
                                    :format(table_, old, new))
                            end
                            -- Made or refused, the new name is the rename's to
                            -- make: a refused rename also queued ADD COLUMN
                            -- of the same name, and the fix list printed, run
                            -- in order, stopped there at error 1060.
                            present[old], present[new] = nil, true
                        end
                    end
                end
            end

            if next(present) then
                for j = 1, #columns do
                    local column = columns[j]
                    if safeIdentifier(column.name) and not present[column.name:lower()] then
                        if change(('ALTER TABLE %s ADD COLUMN %s'):format(table_, column.definition),
                            ('column %s.%s'):format(table_, column.name), failed) then
                            Log.debug(('migrated: added %s.%s'):format(table_, column.name))
                            addedColumns = addedColumns + 1
                        end
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
                        if change(('ALTER TABLE %s ADD %s'):format(table_, index.definition),
                            ('index %s on %s'):format(index.name, table_), failed) then
                            Log.debug(('migrated: added index %s on %s')
                                :format(index.name, table_))
                            addedIndexes = addedIndexes + 1
                        end
                    end
                end
            end
        end
    end

    if addedColumns > 0 or addedIndexes > 0 then
        Log.debug(('schema migration: %d column(s), %d index(es) added')
            :format(addedColumns, addedIndexes))
    end

    if raiseAtEnd and #failed > 0 then error(schemaRefused(failed), 0) end
    return addedColumns, addedIndexes
end

--- How many contracts holding money inspect reads whole for the refusal.
local INSPECT_LISTED = 10

--- What the crimson_* tables hold, for a server started in another mode
--- (main.lua's refuseModeSwitch): escrow lines not yet settled, payouts
--- still owed to players who were offline, and the contracts holding money
--- with their lines (the first INSPECT_LISTED, and `more` when there are
--- others). Creates nothing: a database this resource never used answers
--- zero.
---
--- A queued payout counts only while the line it names is not settled: one
--- handed over at once leaves its row behind until the player's next login,
--- and that is not money anybody is owed.
---
--- And the review items still waiting for staff (open, or left part-way
--- resolved), the first INSPECT_LISTED of them, with the money each records:
--- an item is the only record of a payment no rule could settle, and the
--- new mode's queue starts empty.
---@return table { lines, owed, holding = { { id, contract, lines, hitmen } }, more, reviews }
function MySQLStore.inspect()
    local rows = db.query([[
        SELECT TABLE_NAME FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME IN ('crimson_escrow', 'crimson_pending', 'crimson_contracts', 'crimson_hitmen',
                             'crimson_review')
    ]]) or {}
    local have = {}
    for i = 1, #rows do have[tostring(rows[i].TABLE_NAME or rows[i].table_name)] = true end

    local out = { lines = 0, owed = 0, holding = {}, reviews = {} }
    if have.crimson_review then
        local items = db.query([[
            SELECT * FROM crimson_review WHERE state IN ('open', 'resolving')
            ORDER BY created_at LIMIT ?
        ]], { INSPECT_LISTED + 1 }) or {}
        for i = 1, math.min(#items, INSPECT_LISTED) do
            local item = items[i]
            local decoded, lines = pcall(json.decode, item.items or '')
            local money, goods = tonumber(item.amount) or 0, 0
            for _, entry in ipairs(decoded and type(lines) == 'table' and lines or {}) do
                if type(entry) == 'table' then
                    if entry.source == 'item' or entry.source == 'weapon' then
                        goods = goods + 1
                    else
                        money = money + (tonumber(entry.amount) or 0)
                    end
                end
            end
            out.reviews[#out.reviews + 1] = { id = item.id, kind = item.kind,
                contract_id = item.contract_id, state = item.state, account = item.account,
                money = math.floor(money), goods = goods }
        end
        if #items > INSPECT_LISTED then out.moreReviews = true end
    end
    if have.crimson_escrow then
        out.lines = tonumber(db.scalar(
            "SELECT COUNT(*) FROM crimson_escrow WHERE state <> 'settled'")) or 0
    end
    if have.crimson_pending and have.crimson_escrow then
        out.owed = tonumber(db.scalar([[
            SELECT COUNT(*) FROM crimson_pending p
            WHERE EXISTS (
                SELECT 1 FROM crimson_escrow e
                WHERE e.id = p.line_id AND e.state <> 'settled')
        ]])) or 0
    end
    if out.lines == 0 then return out end

    local ids = db.query([[
        SELECT DISTINCT contract_id FROM crimson_escrow WHERE state <> 'settled'
        ORDER BY contract_id LIMIT ?
    ]], { INSPECT_LISTED + 1 }) or {}
    for i = 1, math.min(#ids, INSPECT_LISTED) do
        local id = ids[i].contract_id
        local contract = have.crimson_contracts
            and (db.query('SELECT * FROM crimson_contracts WHERE id = ?', { id }) or {})[1] or nil
        -- As stored: the refusal reads the source, amount, owed_to,
        -- releasing_to and deliver_raises, none of which hydrateEscrow renames.
        local lines = db.query(
            "SELECT * FROM crimson_escrow WHERE contract_id = ? AND state <> 'settled'", { id }) or {}
        local hitmen = {}
        if have.crimson_hitmen then
            for _, row in ipairs(db.query('SELECT hitman_cid FROM crimson_hitmen WHERE contract_id = ?',
                { id }) or {}) do
                if row.hitman_cid then hitmen[row.hitman_cid] = true end
            end
        end
        out.holding[#out.holding + 1] = { id = id, contract = contract, lines = lines, hitmen = hitmen }
    end
    if #ids > INSPECT_LISTED then out.more = true end
    return out
end

--- Wait `ms` without holding the thread: on a timer, so whatever drives
--- timers (the engine, or the test harness) resumes it.
---@param ms integer
local function sleep(ms)
    local p = promise.new()
    SetTimeout(ms, function() p:resolve(true) end)
    Citizen.Await(p)
end

--- The first statement of a start, asked again every OPEN_RETRY_MS while
--- the database does not answer it, with a console line every
--- OPEN_SAY_EVERY seconds. During a full server start oxmysql's pool may
--- not exist yet, and every statement then waits for its next connection
--- try, every 30 s (OXMYSQL.md §6). This start used to wait on that first
--- statement for ever, silently, with no handler registered, and stayed
--- dead after the database came back. Any other error raises as before.
local OPEN_RETRY_MS, OPEN_SAY_EVERY = 5000, 30

---@return table<string, string> tablesPresent()
local function tablesWhenAnswering()
    local started, said = os.time(), os.time()
    while true do
        local ok, present = pcall(tablesPresent)
        if ok then return present end
        if not MySQLStore.timedOut(present) then error(present, 0) end
        sleep(OPEN_RETRY_MS)
        local now = os.time()
        if now - said >= OPEN_SAY_EVERY then
            said = now
            local readyOk, ready = pcall(function() return MySQL.isReady() end)
            local why = 'the database does not answer'
            if readyOk and ready == false then
                why = 'oxmysql has not connected yet; it retries every 30 s'
            elseif readyOk and ready then
                why = 'oxmysql is connected but the database does not answer'
            end
            Log.always(('waiting for the database (%d s): %s'):format(now - started, why))
        end
    end
end

function MySQLStore.open()
    -- Only the tables that are not there. CREATE TABLE IF NOT EXISTS for a
    -- table that is there still needs CREATE, so a database user without it
    -- failed here even after install/sql/crimson_hitman.sql had made every
    -- table, which the README said was all it needed.
    local failed, cache = {}, {}
    local present = tablesWhenAnswering()

    -- Before anything is made or changed: a table of one of these names that
    -- is not this resource's is refused with nothing touched (foreignTables).
    local foreign = foreignTables(present, cache)
    if #foreign > 0 then error(foreignRefused(foreign), 0) end

    for i = 1, #SCHEMA do
        local name = SCHEMA[i]:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
        if name and not present[name] then
            change(SCHEMA[i], ('table %s'):format(name), failed, true)
        end
    end

    -- A table that already existed keeps whatever shape it had, so the
    -- statements above are not enough on their own.
    MySQLStore.migrate(failed, cache)
    if #failed > 0 then error(schemaRefused(failed), 0) end

    local highest = db.scalar('SELECT COUNT(*) FROM crimson_contracts') or 0
    seq = tonumber(highest) or 0

    -- Every time column is a signed INT of seconds, which runs out at
    -- 2038-01-19 03:14:07 UTC: from then every insert is refused. Said at
    -- every start from a year before, so there is time to update.
    if os.time() >= 2147483647 - 365 * 86400 then
        Log.always('the crimson_* tables keep times as signed INT, which runs out on '
            .. '2038-01-19; update crimson-hitman before then')
    end
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

--- A contract's columns in the order writeContract and insertContract list
--- them.
local function contractParams(c)
    return {
        c.id, c.creator_cid, c.creator_account, c.creator_name, c.target_cid, c.target_account,
        c.target_name, c.target_protected and 1 or 0, c.target_job, c.reason, c.mode, c.state,
        c.anon_creator and 1 or 0, c.fulfilment_rule, c.bonus_percent or 0, c.bailout_amount or 0,
        c.penalty_amount or 0, c.payout_slots or 1, c.slots_claimed or 0, c.next_slot or 1,
        c.created_at, c.deadline_at, c.expires_at, c.paused_ms or 0, c.paused_since,
        c.bailout_queued_at, c.bailout_paid_by, c.bailout_paid_amount, c.bailout_paid_account,
        c.bailout_attempts or 0, c.resolved_at, c.resolution,
    }
end

--- Persist a contract's fields. `state` is intentionally absent from the
--- UPDATE clause: it changes only through compareSetContractState, so a
--- caller writing a copy it read before a transition cannot revert it. This
--- matters more here than in the other backends, because reads return fresh
--- rows rather than shared tables.
function MySQLStore.writeContract(c)
    db.query([[
        INSERT INTO crimson_contracts
            (id, creator_cid, creator_account, creator_name, target_cid, target_account,
             target_name, target_protected, target_job, reason, mode, state, anon_creator,
             fulfilment_rule, bonus_percent,
             bailout_amount, penalty_amount, payout_slots, slots_claimed, next_slot,
             created_at, deadline_at, expires_at, paused_ms, paused_since,
             bailout_queued_at, bailout_paid_by, bailout_paid_amount, bailout_paid_account,
             bailout_attempts, resolved_at, resolution)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        -- fulfilment_rule is deliberately absent too. It is a term the
        -- contract was placed under and never changes, so a copy written
        -- back could only put the same value, or none from a row older
        -- than it.
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
    ]], contractParams(c))
    return true
end

--- Store a new contract, and never write over one already there.
---
--- writeContract's insert, with an update clause that changes nothing: the
--- id was confirmed unused when it was minted, so this stores what that
--- would, and the server writing it again after the first write went
--- unanswered (server/review.lua's deciders), or the first landing late,
--- meets the row and leaves it. writeContract's update clause put back the
--- penalty, the buyout price and the resolution from the creation copy over
--- a contract changed or withdrawn since.
function MySQLStore.insertContract(c)
    db.query([[
        INSERT INTO crimson_contracts
            (id, creator_cid, creator_account, creator_name, target_cid, target_account,
             target_name, target_protected, target_job, reason, mode, state, anon_creator,
             fulfilment_rule, bonus_percent,
             bailout_amount, penalty_amount, payout_slots, slots_claimed, next_slot,
             created_at, deadline_at, expires_at, paused_ms, paused_since,
             bailout_queued_at, bailout_paid_by, bailout_paid_amount, bailout_paid_account,
             bailout_attempts, resolved_at, resolution)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE id = id
    ]], contractParams(c))
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

--- Record a paid buyout, only on a contract still running whose queue is
--- free or already holds this very buyout (the same moment and payer).
---
--- A compare-and-set, so the record the server writes again after the first
--- write went unanswered (server/review.lua's deciders), or the first landing
--- late, never lands on a contract another buyout has queued or one that has
--- closed. Matched rows, as oxmysql's update answers them (OXMYSQL.md §3): a
--- row already holding this buyout counts, so "already ours" is true.
---@return boolean recorded
function MySQLStore.recordBailout(id, fields)
    local affected = db.update([[
        UPDATE crimson_contracts
        SET bailout_queued_at = ?, bailout_paid_by = ?, bailout_paid_amount = ?,
            bailout_paid_account = ?, bailout_attempts = 0
        WHERE id = ? AND state IN ('active', 'accepted')
          AND (bailout_queued_at IS NULL OR (bailout_queued_at = ? AND bailout_paid_by = ?))
    ]], { fields.bailout_queued_at, fields.bailout_paid_by, fields.bailout_paid_amount,
          fields.bailout_paid_account, id, fields.bailout_queued_at, fields.bailout_paid_by })
    return (tonumber(affected) or 0) > 0
end

--- Clear the buyout queue, only while it still holds the buyout recorded at
--- `queuedAt`: a clear that lands late never clears a later buyout.
---@return boolean cleared
function MySQLStore.clearBailout(id, queuedAt)
    local affected = db.update([[
        UPDATE crimson_contracts
        SET bailout_queued_at = NULL, bailout_paid_by = NULL, bailout_paid_amount = NULL,
            bailout_paid_account = NULL, bailout_attempts = 0
        WHERE id = ? AND bailout_queued_at = ?
    ]], { id, queuedAt })
    return (tonumber(affected) or 0) > 0
end

--- What the law enforcement advisory said of a contract, which moves ONLY
--- through here, never through writeContract (which does not name these
--- columns at all): a copy read before a bulletin went out and written after
--- cannot take back what it said. One literal statement per column, as
--- SETTABLE below.
local ADVISED = {
    advised_posted_at = 'UPDATE crimson_contracts SET advised_posted_at = ? WHERE id = ?',
    advised_hitmen = 'UPDATE crimson_contracts SET advised_hitmen = ? WHERE id = ?',
}
function MySQLStore.setAdvised(id, fields)
    for k in pairs(fields) do
        if not ADVISED[k] then error('setAdvised: not an advisory field: ' .. tostring(k)) end
    end
    for column, sql in pairs(ADVISED) do
        if fields[column] ~= nil then db.update(sql, { fields[column], id }) end
    end
    return true
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

--- How many contracts are in each state. See the memory backend. Served by
--- idx_state: on 100,000 rows the SELECT * the overview counted from took
--- 1.8 s every five seconds while the panel was open, and this takes 50 ms.
function MySQLStore.countContractsByState()
    local rows = db.query('SELECT state, COUNT(*) AS n FROM crimson_contracts GROUP BY state') or {}
    local out = {}
    for i = 1, #rows do
        local state = rows[i].state
        if state ~= nil then out[state] = (out[state] or 0) + (tonumber(rows[i].n) or 0) end
    end
    return out
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

--- The pause total is kept in milliseconds in an INT, which holds 24.86
--- days of them, and the panel allows a 30-day lifetime. Past it strict
--- mode refused the statement, the pause never ended, and the raise stopped
--- the expiry pass at this contract for every contract after it. So the
--- total stops at the ceiling: MariaDB adds in BIGINT before LEAST, so the
--- sum itself is never refused. The deadline still moves by the whole
--- pause; only the banked total (unpausedDeadline, the accept guard's net
--- figure) stops counting, and Contracts.accept refuses any deadline change
--- on a contract whose total has stopped.
function MySQLStore.endPause(id, since, seconds)
    local affected = db.update([[
        UPDATE crimson_contracts
        SET deadline_at = deadline_at + ?, paused_ms = LEAST(paused_ms + ?, 2147483647),
            paused_since = NULL
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
         staker, inv_slot, owed_to, releasing_to, state, derived, taken_from, deliver_raises,
         deliver_before, deliver_arrived)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    -- State and amount are NOT written here, as they move only through
    -- claimEscrowLine / settleEscrowLine / setEscrowAmount, which are
    -- guarded. Writing them from a caller-held copy could resurrect a
    -- line that settled while the caller was reading.
    -- The raise count only when the copy carries one, so a copy read
    -- before Escrow.deliver counted a raise does not wipe it; and the same
    -- for what arrived, which a wipe would give a second time.
    ON DUPLICATE KEY UPDATE owed_to = VALUES(owed_to),
        releasing_to = VALUES(releasing_to),
        deliver_raises = COALESCE(VALUES(deliver_raises), deliver_raises),
        deliver_before = COALESCE(VALUES(deliver_before), deliver_before),
        deliver_arrived = COALESCE(VALUES(deliver_arrived), deliver_arrived)
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
        l.deliver_raises,
        -- The recipient's whole balance before a give that raised, which
        -- can be past what an INT holds. Refused, the raise was never
        -- counted and the line was left releasing. Held to the column
        -- here; the exact figure is in the escrow_deliver_raised row.
        l.deliver_before and math.max(-2147483648, math.min(2147483647, l.deliver_before)),
        l.deliver_arrived,
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

--- ESCROW_UPSERT's insert, with an update clause that changes nothing.
---
--- A take's line ids are new, so this stores what the upsert would. Written
--- again by the server after the first write went unanswered (server/
--- review.lua's deciders), or the first landing late, it leaves a line
--- already there as it is: the upsert put back whom it was owed and going
--- to from the take's copy, over a line that had moved since, and whom it is
--- going to is what boot recovery reads as "may have reached them".
local ESCROW_INSERT = [[
    INSERT INTO crimson_escrow
        (id, contract_id, slot, line_portion, source, amount, item, quantity, metadata,
         staker, inv_slot, owed_to, releasing_to, state, derived, taken_from, deliver_raises,
         deliver_before, deliver_arrived)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON DUPLICATE KEY UPDATE id = id
]]

--- Store a take's lines, each only where its id is not there yet: one line
--- one statement, several in one transaction, as writeEscrow does.
function MySQLStore.insertEscrow(contractId, lines)
    if #lines == 0 then return true end
    if #lines == 1 then
        db.query(ESCROW_INSERT, escrowParams(contractId, lines[1]))
        return true
    end
    local queries = {}
    for i = 1, #lines do
        queries[i] = { query = ESCROW_INSERT, values = escrowParams(contractId, lines[i]) }
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
--- Every escrow line not settled yet, held or mid-release, in one query
--- served by idx_state. See the memory backend.
function MySQLStore.unsettledEscrow()
    local rows = db.query(
        "SELECT * FROM crimson_escrow WHERE state IN ('held', 'releasing') ORDER BY id") or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

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

--- Escrow not yet settled whose give has raised `limit` times or more; see
--- the memory backend. A row from before the column has NULL there, which
--- is no raise, and compares false.
function MySQLStore.parkedEscrow(limit)
    local rows = db.query([[
        SELECT * FROM crimson_escrow
        WHERE state IN ('held', 'releasing') AND deliver_raises >= ?
        ORDER BY id
    ]], { limit }) or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

--- Held escrow owed to somebody; see the memory backend.
function MySQLStore.owedHeldEscrow()
    local rows = db.query([[
        SELECT * FROM crimson_escrow
        WHERE state = 'held' AND owed_to IS NOT NULL
        ORDER BY id
    ]]) or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

--- Escrow `releasing`; see the memory backend.
function MySQLStore.releasingEscrow()
    local rows = db.query([[
        SELECT * FROM crimson_escrow WHERE state = 'releasing' ORDER BY id
    ]]) or {}
    for i = 1, #rows do hydrateEscrow(rows[i]) end
    return rows
end

--- Held escrow owed to nobody and naming no give, of a closed contract; see
--- the memory backend. Read by the maintenance tick, so served by idx_state
--- on the held lines and the contracts' primary key, never a scan of the
--- settled ones. The closed states are CH.TERMINAL's.
---@param limit integer
function MySQLStore.strandedEscrow(limit)
    local rows = db.query([[
        SELECT e.* FROM crimson_escrow e
        JOIN crimson_contracts c ON c.id = e.contract_id
        WHERE e.state = 'held' AND e.owed_to IS NULL AND e.releasing_to IS NULL
          AND c.state IN ('completed', 'bailed_out', 'expired', 'cancelled', 'voided')
        ORDER BY e.id
        LIMIT ?
    ]], { math.floor(tonumber(limit) or 100) }) or {}
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
--- `staff`: see the memory backend. In the same statement as the settle.
function MySQLStore.settleEscrowLine(id, recipientCid, staff)
    local affected = db.update(
        'UPDATE crimson_escrow SET state = ?, settled_to = ?, settled_at = ?, '
        .. 'settled_by_staff = ?, settled_staff = ? WHERE id = ? AND state = ?',
        { CH.ESCROW_STATE.SETTLED, recipientCid, os.time(), staff and staff.disposition,
          staff and staff.by, id, CH.ESCROW_STATE.RELEASING })
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

--- Every running contract's hitmen, by contract id, in one query.
---
--- The death sampler reads the roster of every live contract once a second.
--- One readHitmen each was 1 + N awaited queries a second for the life of
--- the server, which the slow-job timer never shows (it does not count
--- database waits); this is one.
function MySQLStore.liveHitmen()
    local rows = db.query([[
        SELECT h.* FROM crimson_hitmen h
        JOIN crimson_contracts c ON c.id = h.contract_id
        WHERE c.state IN ('active', 'accepted')
        ORDER BY h.accepted_at, h.id
    ]]) or {}
    local out = {}
    for i = 1, #rows do
        local h = hydrateHitman(rows[i])
        local list = out[h.contract_id]
        if not list then list = {} out[h.contract_id] = list end
        list[#list + 1] = h
    end
    return out
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

--- A hitman walks away: the row goes abandoned only while it is active and
--- its contract is still open. A claim, a void, an expiry or a buyout moves
--- the contract's state before it touches a row, so an abandon read before
--- one of them landed matches nothing here instead of overwriting a hitman
--- just paid, or one whose stake the ending had already returned.
function MySQLStore.abandonHitman(id, contractId, leftAt)
    local affected = db.update([[
        UPDATE crimson_hitmen SET state = 'abandoned', left_at = ?
        WHERE id = ? AND state = 'active'
          AND EXISTS (SELECT 1 FROM crimson_contracts c WHERE c.id = ? AND c.state IN ('active', 'accepted'))
    ]], { leftAt, id, contractId })
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

--- Proposals a start finds still being applied. See the memory backend.
--- Once, at start, as openAmendmentContracts is read.
function MySQLStore.applyingAmendments()
    local rows = db.query(
        "SELECT * FROM crimson_amendments WHERE outcome = 'applying'") or {}
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
        -- By position, as writeAudit's are: a row with no actor or no
        -- contract (a console /ch-settle, a system row) has a NULL in that
        -- column. Appended, the nil was skipped, and every value after it
        -- landed one column early, the rest of the batch with it.
        for j = 1, 6 do params[(i - 1) * 6 + j] = row[j] end
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

--- Rows the admin panel's log reads per round trip, and at most per page.
local AUDIT_BATCH, AUDIT_SCAN_ROWS = 500, 5000

--- The most a TEXT column holds, in bytes. crimson_escrow.metadata stores
--- exactly what escrowParams encodes (escaping happens only in the
--- statement text), so an item whose encoded metadata is longer is refused
--- by Escrow.validate before anything is taken, and a review item that
--- would not fit is kept without its goods' metadata (Review.open). Only
--- this store sets it.
MySQLStore.MAX_TEXT_BYTES = 65535

--- How many audit rows past the retention age one prune removes. One
--- statement for the whole backlog (a first start with retention on, or
--- after a long downtime) removed 900,000 rows in twelve seconds, with the
--- tick waiting on it; at 5,000 a tick a backlog still drains at 1.8 million
--- rows an hour.
local AUDIT_PRUNE_ROWS = 5000

--- A page of the audit log for the admin panel, newest first. See the
--- memory backend; the cursor here is the id to read below.
---
--- Read in batches by id, newest first, through the one index the filters
--- can use (the contract's, or the actor's), and filtered as the other
--- backends filter (Util.auditMatches). At most AUDIT_SCAN_ROWS rows are
--- looked at for one page: a filter that matches almost nothing in a long
--- log answers with what it found so far and a cursor to go on from, rather
--- than reading the whole log in one request. Rows come in the order they
--- were written, so the first one older than the time range ends the read.
---
--- A range that ends in the past starts at its newest row, found on idx_ts,
--- rather than at the newest row of the log: every row newer than the range
--- was scanned and matched nothing, five thousand to a page, and a day ten
--- days back answered sixty empty pages before its first row. No row with
--- a ts inside the range has a higher id than the one this finds, a row
--- written again by the flush included, so the seek skips nothing.
function MySQLStore.queryAudit(filter, cursor, limit)
    filter = type(filter) == 'table' and filter or {}
    local below = math.tointeger(tonumber(cursor)) or 2147483647
    if filter.to and math.tointeger(tonumber(cursor)) == nil then
        local seek = db.query('SELECT MAX(id) AS top FROM crimson_audit WHERE ts >= ? AND ts <= ?',
            { filter.from or 0, filter.to }) or {}
        local top = seek[1] and math.tointeger(tonumber(seek[1].top))
        if not top then return {}, nil end
        below = top + 1
    end
    local out, scanned = {}, 0
    while scanned < AUDIT_SCAN_ROWS do
        local batch
        if filter.contract then
            batch = db.query(
                'SELECT * FROM crimson_audit WHERE contract_id = ? AND id < ? ORDER BY id DESC LIMIT ?',
                { filter.contract, below, AUDIT_BATCH })
        elseif filter.actor then
            batch = db.query(
                'SELECT * FROM crimson_audit WHERE actor_cid = ? AND id < ? ORDER BY id DESC LIMIT ?',
                { filter.actor, below, AUDIT_BATCH })
        else
            batch = db.query('SELECT * FROM crimson_audit WHERE id < ? ORDER BY id DESC LIMIT ?',
                { below, AUDIT_BATCH })
        end
        batch = batch or {}
        for i = 1, #batch do
            local row = hydrateAudit(batch[i])
            local id = tonumber(row.id) or 0
            scanned = scanned + 1
            if filter.from and (tonumber(row.ts) or 0) < filter.from then return out, nil end
            if Util.auditMatches(row, filter) then
                -- Full: the next page starts at this row (id below id + 1).
                if #out >= limit then return out, id + 1 end
                out[#out + 1] = row
            end
            below = id
        end
        if #batch < AUDIT_BATCH then return out, nil end
    end
    return out, below
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
        db.query('DELETE FROM crimson_audit WHERE ts < ? ORDER BY ts LIMIT ?',
            { os.time() - (auditDays * 86400), AUDIT_PRUNE_ROWS })
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
--- Five conditions, and the last three are the ones that matter: a contract
--- is only removed when it is terminal, older than the cutoff, holds no
--- escrow line that is not settled, owes nobody anything on their next
--- login, and is named by no review item staff have not resolved. A
--- contract whose creator was offline when it closed holds their money in a
--- `held` OWED line with a crimson_pending row pointing at it, and deleting
--- either would take that money with it.
---
--- A crimson_pending row owes something only while the line it names is not
--- settled: a payout handed over at once leaves its row until the player's
--- next login, and one who never came back held the contract here for good.
--- A review item's advice is read against its contract, so the contract
--- stays until the item is resolved (see the json backend).
---
--- idx_resolved serves the age test and idx_message_contract the messages
--- delete; without them each tick read every contract, and each contract
--- pruned scanned every message.
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
              SELECT 1 FROM crimson_pending p
              WHERE p.contract_id = c.id AND EXISTS (
                  SELECT 1 FROM crimson_escrow q
                  WHERE q.id = p.line_id AND q.state <> 'settled'))
          AND NOT EXISTS (
              SELECT 1 FROM crimson_review r
              WHERE r.contract_id = c.id AND r.state IN ('open', 'resolving'))
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

--- Whether any photo record is kept at all, in any state (Photos.anyStored).
--- One row by the primary key, never a count of the table.
function MySQLStore.anyPhoto()
    local rows = db.query('SELECT id FROM crimson_photos LIMIT 1') or {}
    return rows[1] ~= nil
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

--- See the memory backend.
function MySQLStore.photosNotOpen(limit)
    return db.query([[
        SELECT * FROM crimson_photos WHERE state <> 'open'
        ORDER BY created_at LIMIT ?
    ]], { limit or 200 }) or {}
end

--- One guarded DELETE a record, each only while it is in the state it was
--- read in: a photo opened between the read and the delete is left to the
--- view that has it. `update` answers the rows a DELETE removed.
function MySQLStore.deletePhotosIn(list)
    local gone = {}
    for _, wanted in ipairs(list or {}) do
        local affected = db.update('DELETE FROM crimson_photos WHERE id = ? AND state = ?',
            { wanted.id, wanted.state })
        if (tonumber(affected) or 0) > 0 then gone[wanted.id] = true end
    end
    return gone
end

--- Counted here rather than in SQL, as photoTotals is: it is read only
--- while kill photos are off and some are kept from before, which are few.
function MySQLStore.photoCounts()
    local rows = db.query('SELECT state, kind, file FROM crimson_photos') or {}
    local out = { total = #rows, open = 0, links = 0, files = 0 }
    for i = 1, #rows do
        if rows[i].state == 'open' then out.open = out.open + 1 end
        if rows[i].kind == 'url' then out.links = out.links + 1 end
        if rows[i].file then out.files = out.files + 1 end
    end
    return out
end

--- When this process was last known to be running. See main.lua's Recover.
--------------------------------------------------------------------------
-- The review queue
--------------------------------------------------------------------------

local function encoded(value)
    if value == nil then return nil end
    return json.encode(value)
end

local function hydrateReview(row)
    if not row then return nil end
    for _, column in ipairs({ 'cids', 'items', 'known', 'resolution' }) do
        if type(row[column]) == 'string' then
            local ok, decoded = pcall(json.decode, row[column])
            row[column] = ok and decoded or nil
        end
    end
    return row
end

--- See the memory backend. Never over an item already there: the update
--- clause changes nothing.
function MySQLStore.writeReview(r)
    db.query([[
        INSERT INTO crimson_review
            (id, kind, contract_id, cids, amount, account, items, known, created_at, state,
             resolution, resolved_by, resolved_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE id = id
    ]], {
        r.id, r.kind, r.contract_id, encoded(r.cids), r.amount, r.account, encoded(r.items),
        encoded(r.known), r.created_at, r.state, encoded(r.resolution), r.resolved_by,
        r.resolved_at,
    })
    return true
end

function MySQLStore.readReview(id)
    local rows = db.query('SELECT * FROM crimson_review WHERE id = ?', { id }) or {}
    return hydrateReview(rows[1])
end

function MySQLStore.reviewItems(open, limit)
    local rows
    if open then
        rows = db.query([[
            SELECT * FROM crimson_review WHERE state IN ('open', 'resolving')
            ORDER BY created_at LIMIT ?
        ]], { limit or 200 }) or {}
    else
        rows = db.query(
            'SELECT * FROM crimson_review ORDER BY created_at DESC LIMIT ?',
            { limit or 200 }) or {}
    end
    for i = 1, #rows do hydrateReview(rows[i]) end
    return rows
end

function MySQLStore.setReviewState(id, expected, next_, fields)
    local affected = db.update([[
        UPDATE crimson_review SET state = ?, resolution = ?, resolved_by = ?, resolved_at = ?
        WHERE id = ? AND state = ?
    ]], { next_, encoded(fields.resolution), fields.resolved_by, fields.resolved_at,
          id, expected })
    return (tonumber(affected) or 0) > 0
end

--------------------------------------------------------------------------
-- Settings changed from the admin panel
--------------------------------------------------------------------------

--- See the memory backend. The value is kept as JSON, wrapped so a bare
--- switch or number encodes as a document.
function MySQLStore.readSettings()
    local rows = db.query('SELECT * FROM crimson_settings') or {}
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        local ok, decoded = pcall(json.decode, row.setting_value or '')
        if ok and type(decoded) == 'table' and row.setting_key then
            out[row.setting_key] = { value = decoded.value, by = row.set_by,
                                     at = tonumber(row.set_at) }
        end
    end
    return out
end

function MySQLStore.writeSetting(key, value, by, at)
    db.query([[
        INSERT INTO crimson_settings (setting_key, setting_value, set_by, set_at)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value),
            set_by = VALUES(set_by), set_at = VALUES(set_at)
    ]], { key, json.encode({ value = value }), by, at })
    return true
end

function MySQLStore.deleteSetting(key)
    db.query('DELETE FROM crimson_settings WHERE setting_key = ?', { key })
    return true
end

function MySQLStore.clearSettings()
    db.query('DELETE FROM crimson_settings')
    return true
end

--------------------------------------------------------------------------
-- The admin panel's alerts
--------------------------------------------------------------------------

--- See the memory backend. Each alert is written whole, over what the row
--- held: Alerts keeps every one in memory and is the only writer.
local ALERT_INSERT = [[
    INSERT INTO crimson_alerts
        (id, level, text, contract_id, first_at, last_at, occurrences, acknowledged_by,
         acknowledged_at)
    VALUES (?,?,?,?,?,?,?,?,?)
    ON DUPLICATE KEY UPDATE level = VALUES(level), text = VALUES(text),
        contract_id = VALUES(contract_id), first_at = VALUES(first_at),
        last_at = VALUES(last_at), occurrences = VALUES(occurrences),
        acknowledged_by = VALUES(acknowledged_by), acknowledged_at = VALUES(acknowledged_at)
]]

local function alertParams(row)
    return {
        row.id, row.level, row.text, row.contract_id, row.first_at, row.last_at, row.count,
        row.acknowledged_by, row.acknowledged_at,
    }
end

function MySQLStore.readAlerts()
    local rows = db.query('SELECT * FROM crimson_alerts') or {}
    for i = 1, #rows do
        local row = rows[i]
        row.first_at, row.last_at = tonumber(row.first_at), tonumber(row.last_at)
        row.count, row.occurrences = tonumber(row.occurrences), nil
        row.acknowledged_at = tonumber(row.acknowledged_at)
    end
    return rows
end

function MySQLStore.writeAlert(row)
    db.query(ALERT_INSERT, alertParams(row))
    return true
end

--- At a stop, handed over without waiting, as the audit log is
--- (writeAuditNoWait): waiting there yields the stop handler for good.
function MySQLStore.writeAlertNoWait(row)
    MySQL.query(ALERT_INSERT, alertParams(row))
    return true
end

function MySQLStore.deleteAlert(id)
    db.query('DELETE FROM crimson_alerts WHERE id = ?', { id })
    return true
end

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
