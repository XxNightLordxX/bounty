--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/org/schema.lua                   ║
    ║       The organisation's tables: one shape for all three storage modes    ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Every organisation row is one of these tables, by the short name the
--- storage backends take (Storage.readOrgRows, writeOrgRow, insertOrgRowOnce,
--- deleteOrgRow). memory and json keep the rows as they are given; mysql
--- keeps the columns below, the `json` ones encoded as text, and the CREATE
--- TABLE statements here are the ones it runs, word for word the same as
--- install/sql/crimson_hitman.sql (storage_spec). Never built from input:
--- every name and statement is a literal here.

local Schema = {}

--- [short name] = { table, columns (in order), json (columns kept as JSON),
--- bool (TINYINT(1) columns), by (the column rows are read by), sql }
Schema.TABLES = {
    orgs = {
        table = 'crimson_orgs',
        columns = { 'id', 'job', 'label', 'job_type', 'settings', 'created_at', 'updated_at' },
        json = { settings = true },
        by = nil,
    },
    roles = {
        table = 'crimson_org_roles',
        columns = { 'id', 'org_id', 'grade', 'name', 'label', 'pay', 'is_boss', 'locked', 'powers', 'updated_at' },
        json = { powers = true }, bool = { is_boss = true, locked = true },
        by = 'org_id',
    },
    members = {
        table = 'crimson_org_members',
        columns = { 'id', 'org_id', 'cid', 'name', 'grade', 'codename', 'grants', 'denies', 'limits',
            'locked', 'suspended_until', 'joined_at', 'last_seen', 'updated_at' },
        json = { grants = true, denies = true, limits = true }, bool = { locked = true },
        by = 'org_id',
    },
    grants = {
        table = 'crimson_org_grants',
        columns = { 'id', 'org_id', 'subject', 'subject_id', 'power', 'state', 'by_cid', 'updated_at' },
        by = 'org_id',
    },
    locations = {
        table = 'crimson_org_locations',
        columns = { 'id', 'org_id', 'kind', 'label', 'x', 'y', 'z', 'heading', 'radius', 'blip', 'enabled',
            'anchor', 'by_cid', 'updated_at' },
        json = { anchor = true }, bool = { blip = true, enabled = true },
        by = 'org_id',
    },
    funds = {
        table = 'crimson_org_funds',
        columns = { 'id', 'org_id', 'kind', 'amount', 'actor', 'reason', 'contract_id', 'created_at' },
        by = 'org_id',
    },
    splits = {
        table = 'crimson_org_splits',
        columns = { 'id', 'org_id', 'contract_id', 'cid', 'payout_pct', 'stake_pct', 'buyout_pct', 'created_at' },
        by = 'contract_id',
    },
    applications = {
        table = 'crimson_org_applications',
        columns = { 'id', 'org_id', 'cid', 'name', 'body', 'state', 'decided_by', 'created_at', 'decided_at' },
        by = 'org_id',
    },
}

--- The statements each table is read, written and deleted with.
Schema.SQL = {
    orgs = {
        all = 'SELECT * FROM crimson_orgs',
        one = 'SELECT * FROM crimson_orgs WHERE id = ?',
        upsert = [[INSERT INTO crimson_orgs (id, job, label, job_type, settings, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE job = VALUES(job), label = VALUES(label),
            job_type = VALUES(job_type), settings = VALUES(settings), updated_at = VALUES(updated_at)]],
        insert = [[INSERT INTO crimson_orgs (id, job, label, job_type, settings, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_orgs WHERE id = ?',
    },
    roles = {
        all = 'SELECT * FROM crimson_org_roles',
        by = 'SELECT * FROM crimson_org_roles WHERE org_id = ?',
        one = 'SELECT * FROM crimson_org_roles WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_roles (id, org_id, grade, name, label, pay, is_boss, locked, powers,
            updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE org_id = VALUES(org_id),
            grade = VALUES(grade), name = VALUES(name), label = VALUES(label), pay = VALUES(pay),
            is_boss = VALUES(is_boss), locked = VALUES(locked), powers = VALUES(powers),
            updated_at = VALUES(updated_at)]],
        insert = [[INSERT INTO crimson_org_roles (id, org_id, grade, name, label, pay, is_boss, locked, powers,
            updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_roles WHERE id = ?',
    },
    members = {
        all = 'SELECT * FROM crimson_org_members',
        by = 'SELECT * FROM crimson_org_members WHERE org_id = ?',
        one = 'SELECT * FROM crimson_org_members WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_members (id, org_id, cid, name, grade, codename, grants, denies, limits,
            locked, suspended_until, joined_at, last_seen, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE org_id = VALUES(org_id), cid = VALUES(cid), name = VALUES(name),
            grade = VALUES(grade), codename = VALUES(codename), grants = VALUES(grants), denies = VALUES(denies),
            limits = VALUES(limits), locked = VALUES(locked), suspended_until = VALUES(suspended_until),
            joined_at = VALUES(joined_at), last_seen = VALUES(last_seen), updated_at = VALUES(updated_at)]],
        insert = [[INSERT INTO crimson_org_members (id, org_id, cid, name, grade, codename, grants, denies, limits,
            locked, suspended_until, joined_at, last_seen, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_members WHERE id = ?',
    },
    grants = {
        all = 'SELECT * FROM crimson_org_grants',
        by = 'SELECT * FROM crimson_org_grants WHERE org_id = ?',
        one = 'SELECT * FROM crimson_org_grants WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_grants (id, org_id, subject, subject_id, power, state, by_cid, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE org_id = VALUES(org_id),
            subject = VALUES(subject), subject_id = VALUES(subject_id), power = VALUES(power),
            state = VALUES(state), by_cid = VALUES(by_cid), updated_at = VALUES(updated_at)]],
        insert = [[INSERT INTO crimson_org_grants (id, org_id, subject, subject_id, power, state, by_cid, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_grants WHERE id = ?',
    },
    locations = {
        all = 'SELECT * FROM crimson_org_locations',
        by = 'SELECT * FROM crimson_org_locations WHERE org_id = ?',
        one = 'SELECT * FROM crimson_org_locations WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_locations (id, org_id, kind, label, x, y, z, heading, radius, blip,
            enabled, anchor, by_cid, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE org_id = VALUES(org_id), kind = VALUES(kind), label = VALUES(label),
            x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading), radius = VALUES(radius),
            blip = VALUES(blip), enabled = VALUES(enabled), anchor = VALUES(anchor), by_cid = VALUES(by_cid),
            updated_at = VALUES(updated_at)]],
        insert = [[INSERT INTO crimson_org_locations (id, org_id, kind, label, x, y, z, heading, radius, blip,
            enabled, anchor, by_cid, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_locations WHERE id = ?',
    },
    funds = {
        all = 'SELECT * FROM crimson_org_funds',
        by = 'SELECT * FROM crimson_org_funds WHERE org_id = ?',
        one = 'SELECT * FROM crimson_org_funds WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_funds (id, org_id, kind, amount, actor, reason, contract_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE org_id = VALUES(org_id),
            kind = VALUES(kind), amount = VALUES(amount), actor = VALUES(actor), reason = VALUES(reason),
            contract_id = VALUES(contract_id), created_at = VALUES(created_at)]],
        insert = [[INSERT INTO crimson_org_funds (id, org_id, kind, amount, actor, reason, contract_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_funds WHERE id = ?',
    },
    splits = {
        all = 'SELECT * FROM crimson_org_splits',
        by = 'SELECT * FROM crimson_org_splits WHERE contract_id = ?',
        one = 'SELECT * FROM crimson_org_splits WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_splits (id, org_id, contract_id, cid, payout_pct, stake_pct, buyout_pct,
            created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE org_id = VALUES(org_id),
            contract_id = VALUES(contract_id), cid = VALUES(cid), payout_pct = VALUES(payout_pct),
            stake_pct = VALUES(stake_pct), buyout_pct = VALUES(buyout_pct), created_at = VALUES(created_at)]],
        insert = [[INSERT INTO crimson_org_splits (id, org_id, contract_id, cid, payout_pct, stake_pct, buyout_pct,
            created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_splits WHERE id = ?',
    },
    applications = {
        all = 'SELECT * FROM crimson_org_applications',
        by = 'SELECT * FROM crimson_org_applications WHERE org_id = ?',
        one = 'SELECT * FROM crimson_org_applications WHERE id = ?',
        upsert = [[INSERT INTO crimson_org_applications (id, org_id, cid, name, body, state, decided_by, created_at,
            decided_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE org_id = VALUES(org_id),
            cid = VALUES(cid), name = VALUES(name), body = VALUES(body), state = VALUES(state),
            decided_by = VALUES(decided_by), created_at = VALUES(created_at), decided_at = VALUES(decided_at)]],
        insert = [[INSERT INTO crimson_org_applications (id, org_id, cid, name, body, state, decided_by, created_at,
            decided_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        delete = 'DELETE FROM crimson_org_applications WHERE id = ?',
    },
}

--- The CREATE TABLE statements, in the order mysql mode runs them (after
--- its own), and install/sql/crimson_hitman.sql lists them.
Schema.CREATE = {
    -- The organisations: one row each, the job it is in qbx_core, and the
    -- staff's settings for it as JSON (cuts, bounds, the office rule, the
    -- notice, the boss menu layout).
    [[CREATE TABLE IF NOT EXISTS crimson_orgs (
        id VARCHAR(32) PRIMARY KEY,
        job VARCHAR(32) NOT NULL,
        label VARCHAR(64),
        job_type VARCHAR(32),
        settings TEXT,
        created_at INT NOT NULL,
        updated_at INT
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Its roles: the job's grades, each with its set of powers as JSON.
    [[CREATE TABLE IF NOT EXISTS crimson_org_roles (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Its members: the role each holds, their own grants and denies, their
    -- limits and codename. The source of truth the qbx_core job follows.
    [[CREATE TABLE IF NOT EXISTS crimson_org_members (
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
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Boss permissions: what staff allow or deny a role or one member.
    [[CREATE TABLE IF NOT EXISTS crimson_org_grants (
        id VARCHAR(96) PRIMARY KEY,
        org_id VARCHAR(32) NOT NULL,
        subject VARCHAR(8) NOT NULL,
        subject_id VARCHAR(32) NOT NULL,
        power VARCHAR(4) NOT NULL,
        state VARCHAR(8) NOT NULL,
        by_cid VARCHAR(64),
        updated_at INT,
        INDEX idx_org_grants_org (org_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Its places: the boss office, sign-up boards, meeting spots, NPCs, in
    -- decimetres (x, y, z, radius) and degrees.
    [[CREATE TABLE IF NOT EXISTS crimson_org_locations (
        id VARCHAR(48) PRIMARY KEY,
        org_id VARCHAR(32) NOT NULL,
        kind VARCHAR(16) NOT NULL,
        label VARCHAR(64),
        x INT NOT NULL,
        y INT NOT NULL,
        z INT NOT NULL,
        heading INT DEFAULT 0,
        radius INT DEFAULT 20,
        blip TINYINT(1) DEFAULT 0,
        enabled TINYINT(1) DEFAULT 1,
        anchor TEXT,
        by_cid VARCHAR(64),
        updated_at INT,
        INDEX idx_org_locations_org (org_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Its funds ledger: every movement in or out, by a reference that is
    -- written once (a cut by its escrow line, a withdrawal by its request).
    -- With Renewed-Banking running the balance is the society account's,
    -- and these rows are the history; without it the balance is their sum.
    [[CREATE TABLE IF NOT EXISTS crimson_org_funds (
        id VARCHAR(96) PRIMARY KEY,
        org_id VARCHAR(32) NOT NULL,
        kind VARCHAR(16) NOT NULL,
        amount INT NOT NULL,
        actor VARCHAR(64),
        reason VARCHAR(160),
        contract_id VARCHAR(32),
        created_at INT NOT NULL,
        INDEX idx_org_funds_org (org_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- The cut frozen onto a contract when a member accepted it.
    [[CREATE TABLE IF NOT EXISTS crimson_org_splits (
        id VARCHAR(80) PRIMARY KEY,
        org_id VARCHAR(32) NOT NULL,
        contract_id VARCHAR(32) NOT NULL,
        cid VARCHAR(32) NOT NULL,
        payout_pct INT DEFAULT 0,
        stake_pct INT DEFAULT 0,
        buyout_pct INT DEFAULT 0,
        created_at INT NOT NULL,
        INDEX idx_org_splits_contract (contract_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
    -- Sign-ups waiting for a boss or staff.
    [[CREATE TABLE IF NOT EXISTS crimson_org_applications (
        id VARCHAR(48) PRIMARY KEY,
        org_id VARCHAR(32) NOT NULL,
        cid VARCHAR(32) NOT NULL,
        name VARCHAR(64),
        body VARCHAR(255),
        state VARCHAR(12) NOT NULL,
        decided_by VARCHAR(64),
        created_at INT NOT NULL,
        decided_at INT,
        INDEX idx_org_applications_org (org_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
}

--- The short names, for a backend to walk.
Schema.NAMES = { 'orgs', 'roles', 'members', 'grants', 'locations', 'funds', 'splits', 'applications' }

return Schema
