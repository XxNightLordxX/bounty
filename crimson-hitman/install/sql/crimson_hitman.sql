-- Crimson-Hitman: every table mysql mode uses (Config.Database.Mode = 'mysql').
--
-- You do not need to import this file. In mysql mode the resource creates
-- these tables itself on its first start, and adds any column or index a
-- newer version needs to the tables an older version made (moving one left on
-- another engine to InnoDB). Import it only if your database user may not
-- create or alter tables: then run it once, as a user that may, before the
-- first start in mysql mode. Each start asks information_schema first and
-- creates or alters only what is missing, so that user starts on these tables
-- without CREATE or ALTER. When a newer version needs a column it cannot add,
-- the console names it and prints the ALTER TABLE to run as a user that may.
--
-- In json mode (the default) nothing here is used.
--
-- These are the same statements as server/storage/mysql.lua runs, word for
-- word: utf8mb4 with utf8mb4_unicode_ci, as qbx_core's own tables are, and
-- InnoDB, which the escrow writes need to be all-or-nothing.

CREATE TABLE IF NOT EXISTS crimson_contracts (
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
    -- The handover's meeting point (server/meeting.lua), where the
    -- person who placed it stood, to the metre, and when they last
    -- changed it. Move only through setMeeting, clearMeeting and
    -- dropMeeting. Added to existing databases by migrate; NULL where
    -- none is set.
    meeting_x INT,
    meeting_y INT,
    meeting_at INT,
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_escrow (
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
    -- What the player held before the last give that raised, and how much
    -- of the line has reached them, since a later give hands over only the
    -- rest. NULL when none.
    deliver_before INT,
    deliver_arrived INT,
    -- Settled by staff without anything given (/ch-settle delivered),
    -- 'delivered', and who; settled_at says when. NULL on every other line.
    settled_by_staff VARCHAR(16),
    settled_staff VARCHAR(64),
    INDEX idx_contract (contract_id),
    INDEX idx_state (state)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_hitmen (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_amendments (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_messages (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_ledger (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_pending (
    id VARCHAR(32) PRIMARY KEY,
    cid VARCHAR(32) NOT NULL,
    contract_id VARCHAR(32),
    line_id VARCHAR(64) NOT NULL,
    queued_at INT NOT NULL,
    INDEX idx_cid (cid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_stats (
    cid VARCHAR(32) PRIMARY KEY,
    completed INT DEFAULT 0,
    failed INT DEFAULT 0,
    placed INT DEFAULT 0,
    survived INT DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_audit (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_reveals (
    id VARCHAR(80) PRIMARY KEY,
    contract_id VARCHAR(32) NOT NULL,
    buyer_cid VARCHAR(32) NOT NULL,
    hitman_cid VARCHAR(32),
    revealed_at INT NOT NULL,
    purchases INT DEFAULT 0,
    seed INT,
    answer TEXT,
    INDEX idx_reveal_contract (contract_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The look-ups a contract's placer bought from their informant
-- (Config.PlacerInformant), one row each.
CREATE TABLE IF NOT EXISTS crimson_placer_informants (
    id VARCHAR(120) PRIMARY KEY,
    contract_id VARCHAR(32) NOT NULL,
    placer_cid VARCHAR(32) NOT NULL,
    hitman_cid VARCHAR(32) NOT NULL,
    seq INT NOT NULL,
    bought_at INT NOT NULL,
    revealed TINYINT(1) NOT NULL DEFAULT 0,
    alerted TINYINT(1) NOT NULL DEFAULT 0,
    INDEX idx_placer_informant_contract (contract_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_mutes (
    id VARCHAR(120) PRIMARY KEY,
    contract_id VARCHAR(32) NOT NULL,
    thread_id VARCHAR(80) NOT NULL,
    cid VARCHAR(32) NOT NULL,
    muted_at INT NOT NULL,
    INDEX idx_mute_contract (contract_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_photos (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_review (
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_settings (
    setting_key VARCHAR(64) PRIMARY KEY,
    setting_value TEXT,
    set_by VARCHAR(64),
    set_at INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The admin panel's alerts: every line the console printed whatever
-- Config.Debug said, the same line again counted on it, until staff
-- acknowledge it.
CREATE TABLE IF NOT EXISTS crimson_alerts (
    id VARCHAR(32) PRIMARY KEY,
    level VARCHAR(16) NOT NULL,
    text TEXT NOT NULL,
    contract_id VARCHAR(64),
    first_at INT NOT NULL,
    last_at INT NOT NULL,
    occurrences INT NOT NULL DEFAULT 1,
    acknowledged_by VARCHAR(64),
    acknowledged_at INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Who turned on Notify me on the whitelisted-job view: a row is the
-- choice, and turning it off deletes it.
CREATE TABLE IF NOT EXISTS crimson_view_alerts (
    cid VARCHAR(32) PRIMARY KEY,
    set_at INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- How long each character has been in the city, as the built-in playtime
-- tracker counts it, in seconds, and whether they existed before it first
-- started (NULL until that is decided). When it first started, and the
-- highest number in qbx_core's players table then, are two rows of
-- crimson_meta (playtime_since, playtime_players_id).
CREATE TABLE IF NOT EXISTS crimson_playtime (
    cid VARCHAR(32) PRIMARY KEY,
    played_seconds INT NOT NULL DEFAULT 0,
    grandfathered TINYINT(1),
    first_seen INT NOT NULL,
    updated_at INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Informant tips, one row per tip a hitman bought: the area they were
-- shown (its centre and radius, never where the target stood), when it was
-- bought and when it stops showing, and whether the target was told.
CREATE TABLE IF NOT EXISTS crimson_location_tips (
    id VARCHAR(80) PRIMARY KEY,
    contract_id VARCHAR(32) NOT NULL,
    buyer_cid VARCHAR(32) NOT NULL,
    bought_at INT NOT NULL,
    expires_at INT NOT NULL,
    centre_x INT NOT NULL,
    centre_y INT NOT NULL,
    radius INT NOT NULL,
    target_told TINYINT(1) NOT NULL DEFAULT 0,
    INDEX idx_tip_contract (contract_id),
    INDEX idx_tip_buyer (buyer_cid, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_meta (
    meta_key VARCHAR(32) PRIMARY KEY,
    meta_value INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
