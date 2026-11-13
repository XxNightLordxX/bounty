-- Crimson-Hitman: every table mysql mode uses (Config.Database.Mode = 'mysql').
--
-- You do not need to import this file. In mysql mode the resource creates
-- these tables itself on its first start, and adds any column or index a
-- newer version needs to the tables an older version made (moving one left on
-- another engine to InnoDB, and widening a text column a newer version
-- declares wider, which keeps every value). Import it only if your database user may not
-- create or alter tables: then run it once, as a user that may, before the
-- first start in mysql mode. Each start asks information_schema first and
-- creates or alters only what is missing, so that user starts on these tables
-- without CREATE or ALTER. When a newer version needs a column it cannot add,
-- the console names it and prints the ALTER TABLE to run as a user that may.
--
-- mysql is the shipped mode; in json mode nothing here is used.
--
-- The 32 tables: crimson_contracts, crimson_escrow, crimson_hitmen,
-- crimson_amendments, crimson_messages, crimson_ledger, crimson_pending,
-- crimson_stats, crimson_audit, crimson_reveals, crimson_placer_informants,
-- crimson_mutes, crimson_photos, crimson_review, crimson_settings,
-- crimson_alerts, crimson_view_alerts, crimson_playtime,
-- crimson_location_tips, crimson_freezes, crimson_contract_staff,
-- crimson_staff_records, crimson_meta and crimson_rp_rows (the roleplay and
-- improvements features' rows: proof-of-intent holds, bodyguard jobs, heat,
-- decay steps, tip warnings, going dark, EMS holds, the map spots staff set
-- and the like), and the hitman organisation's eight (Config.Organisation,
-- off as shipped): crimson_orgs, crimson_org_roles, crimson_org_members,
-- crimson_org_grants, crimson_org_funds, crimson_org_splits,
-- crimson_org_applications and crimson_org_messages.
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
    -- A payout given as Rate items a dollar, the items of a dollar not yet
    -- whole that have reached them. NULL when none.
    deliver_part INT,
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
    -- What kind of row ('paid', 'withdrawn', 'refunded', 'cancelled', 'buyout')
    -- and the money it moved (Ledger.ended). Added to existing databases by
    -- MySQLStore.migrate.
    kind VARCHAR(16),
    amount BIGINT NOT NULL DEFAULT 0,
    -- How much of that money was operatives' stakes handed to the client
    -- (Ledger.ended). Added to existing databases by MySQLStore.migrate.
    stakes BIGINT NOT NULL DEFAULT 0,
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
-- (Config.Intel.PlacerInformant), one row each.
CREATE TABLE IF NOT EXISTS crimson_placer_informants (
    id VARCHAR(120) PRIMARY KEY,
    contract_id VARCHAR(32) NOT NULL,
    placer_cid VARCHAR(32) NOT NULL,
    hitman_cid VARCHAR(32) NOT NULL,
    seq INT NOT NULL,
    bought_at INT NOT NULL,
    revealed TINYINT(1) NOT NULL DEFAULT 0,
    alerted TINYINT(1) NOT NULL DEFAULT 0,
    answer TEXT,
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

-- The players staff have put on hold from the admin panel: a row is the
-- freeze, and unfreezing deletes it. There is no timer.
CREATE TABLE IF NOT EXISTS crimson_freezes (
    cid VARCHAR(32) PRIMARY KEY,
    name VARCHAR(128),
    reason VARCHAR(255),
    by_cid VARCHAR(64),
    frozen_at INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- What staff wrote down or did on one contract from the admin panel:
-- private notes, the player text they replaced, the operatives they took
-- off it. Never shown to a player; removed with its contract.
CREATE TABLE IF NOT EXISTS crimson_contract_staff (
    id VARCHAR(64) PRIMARY KEY,
    contract_id VARCHAR(32) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    author_cid VARCHAR(64),
    author_name VARCHAR(128),
    body VARCHAR(500),
    field VARCHAR(32),
    subject_cid VARCHAR(32),
    subject_account VARCHAR(64),
    stint INT,
    stake_returned TINYINT(1) NOT NULL DEFAULT 0,
    blocked TINYINT(1) NOT NULL DEFAULT 0,
    created_at INT NOT NULL,
    INDEX idx_cstaff_contract (contract_id),
    INDEX idx_cstaff_kind (kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- What staff did to one player from the admin panel that must outlast a
-- restart: a suspension, a protection, a freeze's history, a manual
-- payment. Never deleted: an ended row stays for the player's history.
CREATE TABLE IF NOT EXISTS crimson_staff_records (
    id VARCHAR(32) PRIMARY KEY,
    kind VARCHAR(16) NOT NULL,
    cid VARCHAR(32) NOT NULL,
    name VARCHAR(128),
    reason VARCHAR(255),
    by_cid VARCHAR(64),
    created_at INT NOT NULL,
    until_at INT,
    ended_at INT,
    ended_by VARCHAR(64),
    ended_why VARCHAR(16),
    amount INT,
    account VARCHAR(16),
    INDEX idx_staff_records_cid (cid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS crimson_meta (
    meta_key VARCHAR(32) PRIMARY KEY,
    meta_value INT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The roleplay features' own rows: a payout held for proof of intent, and a
-- bodyguard job with the money its target put up; and a held contract's idle
-- clocks (kind 'idle_clock'). One row each, its fields as JSON in `body`.
CREATE TABLE IF NOT EXISTS crimson_rp_rows (
    id VARCHAR(48) PRIMARY KEY,
    kind VARCHAR(16) NOT NULL,
    contract_id VARCHAR(32),
    body TEXT NOT NULL,
    updated_at INT NOT NULL,
    INDEX idx_rp_rows_kind (kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The organisations: one row each, the job it is in qbx_core, and the
-- staff's settings for it as JSON (cuts, bounds, the office rule, the
-- notice, the boss menu layout, the activity log and discipline):
-- MEDIUMTEXT, since TEXT's 64 KB filled up. Widened on existing
-- databases by migrate (Schema.WIDENED).
CREATE TABLE IF NOT EXISTS crimson_orgs (
    id VARCHAR(32) PRIMARY KEY,
    job VARCHAR(32) NOT NULL,
    label VARCHAR(64),
    job_type VARCHAR(32),
    settings MEDIUMTEXT,
    created_at INT NOT NULL,
    updated_at INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Its roles: the job's grades, each with its set of powers as JSON.
CREATE TABLE IF NOT EXISTS crimson_org_roles (
    id VARCHAR(48) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    grade INT NOT NULL,
    name VARCHAR(32),
    label VARCHAR(64),
    pay INT DEFAULT 0,
    is_boss TINYINT(1) DEFAULT 0,
    locked TINYINT(1) DEFAULT 0,
    powers TEXT,
    updated_at INT,
    INDEX idx_org_roles_org (org_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Its members: the role each holds, their own grants and denies, their
-- limits and codename. The source of truth the qbx_core job follows.
CREATE TABLE IF NOT EXISTS crimson_org_members (
    id VARCHAR(80) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    cid VARCHAR(32) NOT NULL,
    name VARCHAR(64),
    grade INT NOT NULL,
    codename VARCHAR(32),
    grants TEXT,
    denies TEXT,
    limits TEXT,
    locked TINYINT(1) DEFAULT 0,
    suspended_until INT,
    joined_at INT NOT NULL,
    last_seen INT,
    updated_at INT,
    INDEX idx_org_members_org (org_id),
    INDEX idx_org_members_cid (cid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Boss permissions: what staff allow or deny a role or one member.
CREATE TABLE IF NOT EXISTS crimson_org_grants (
    id VARCHAR(96) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    subject VARCHAR(8) NOT NULL,
    subject_id VARCHAR(32) NOT NULL,
    power VARCHAR(4) NOT NULL,
    state VARCHAR(8) NOT NULL,
    by_cid VARCHAR(64),
    updated_at INT,
    INDEX idx_org_grants_org (org_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Its funds ledger: every movement in or out, by a reference that is
-- written once (a cut by its escrow line, a withdrawal by its request),
-- marked with the backend it moved. With Renewed-Banking chosen the
-- balance is the society account's, and its rows are the history; with
-- the ledger the balance is the sum of the ledger's own rows.
CREATE TABLE IF NOT EXISTS crimson_org_funds (
    id VARCHAR(96) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    amount INT NOT NULL,
    actor VARCHAR(64),
    reason VARCHAR(160),
    contract_id VARCHAR(32),
    created_at INT NOT NULL,
    backend VARCHAR(8),
    INDEX idx_org_funds_org (org_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The cut frozen onto a contract when a member accepted it, and the name
-- shown for them on it from then on (a codename, or NULL: their name).
-- Added to existing databases by migrate.
CREATE TABLE IF NOT EXISTS crimson_org_splits (
    id VARCHAR(80) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    contract_id VARCHAR(32) NOT NULL,
    cid VARCHAR(32) NOT NULL,
    payout_pct INT DEFAULT 0,
    stake_pct INT DEFAULT 0,
    buyout_pct INT DEFAULT 0,
    created_at INT NOT NULL,
    shown_name VARCHAR(48),
    INDEX idx_org_splits_contract (contract_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Sign-ups waiting for a boss or staff. The body holds the answers to
-- the recruitment form as JSON: MEDIUMTEXT (20 answers of 2000 letters
-- of two or more bytes are past TEXT's 65535 bytes), widened from TEXT or
-- VARCHAR(255) on existing databases by migrate (Schema.WIDENED).
CREATE TABLE IF NOT EXISTS crimson_org_applications (
    id VARCHAR(48) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    cid VARCHAR(32) NOT NULL,
    name VARCHAR(64),
    body MEDIUMTEXT,
    state VARCHAR(12) NOT NULL,
    decided_by VARCHAR(64),
    created_at INT NOT NULL,
    decided_at INT,
    INDEX idx_org_applications_org (org_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The private channel (Config.Organisation.Channel): one row a message,
-- kept Config.Organisation.ChannelRetentionDays.
CREATE TABLE IF NOT EXISTS crimson_org_messages (
    id VARCHAR(64) PRIMARY KEY,
    org_id VARCHAR(32) NOT NULL,
    cid VARCHAR(32) NOT NULL,
    name VARCHAR(64),
    body TEXT,
    created_at INT NOT NULL,
    INDEX idx_org_messages_org (org_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
