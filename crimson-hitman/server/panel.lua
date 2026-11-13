CrimsonBoot.define('server.panel', function() --- The admin panel's server side (/hitmanadmin, Config.Admin.Commands.panel).
---
--- The page (ui/admin.html) asks for everything through one net event,
--- crimson-hitman:admin, with an `op` and its `data`, and is answered on
--- crimson-hitman:adminResult (docs/developer.md, Integration, has every shape).
--- Nothing the page sends is trusted, and nothing the client says about
--- who is asking is either: every request runs, in this order,
---
---   1. the engine's source, above zero;
---   2. the ACE check, again, every time (Admin.allowed): reading needs
---      Config.Admin.Ace, Config.Admin.ModeratorAce or one of ExtraAces, as
---      the read-only commands do; the moderator's ops (MOD: freezing,
---      suspending, protecting, voiding and moving a deadline) need Ace or
---      ModeratorAce itself; anything else that writes needs Ace itself;
---      unmasking needs IdentityAce;
---   3. a per-source token bucket (Config.Cooldowns.admin, and adminWrite
---      on top for writes);
---   4. type checks and clamps on every field;
---   5. the work, through the same functions the commands use (Admin.void,
---      Admin.settleLine, Admin.resolveReview, ...), answered in the same
---      words, audited, and the log written at once for every write.
---
--- A write waits for boot recovery, and is refused after one that failed,
--- as /ch-settle is. Who is behind an anonymous party is shown only to staff
--- with IdentityAce: to everyone else an anonymous party is 'Anonymous', and
--- every citizen id is the party's role on the contract instead.

local Util = CrimsonBoot.requireShared('util')
local Words = CrimsonBoot.requireShared('words')
local Log = CrimsonBoot.requireShared('log')
--- The words staff read (locales/en.lua, Config.Locale).
local L = CrimsonBoot.requireShared('locale').t
local Measures = CrimsonBoot.require('server.measures')

local Panel = {}

local deps

local READ, MOD, WRITE, IDENTITY, DEVELOPER = 'read', 'moderate', 'write', 'identity', 'developer'

--- Every request the page may make, and what it needs, each named here:
--- READ (anybody who may open the panel: Ace, ModeratorAce or an extra ACE,
--- scrubbed without IdentityAce), MOD (Ace or ModeratorAce itself), WRITE
--- (Ace itself), IDENTITY and DEVELOPER. An op with no entry is refused.
local OPS = {
    access = READ, overview = READ, contracts = READ, contract = READ, reviews = READ,
    logs = READ, player = READ, settings = READ, diag = READ, stuck = READ, alerts = READ,
    -- The server's own console lines: the Developer section's, so
    -- Config.Admin.DeveloperAce (or Ace itself, see developer below).
    console = DEVELOPER,
    -- Voiding a contract refunds what it holds by the rules every ending
    -- follows, and pays nobody anything staff choose: a moderator's.
    void = MOD,
    -- Money staff choose, settings and the rest: the staff ACE's alone.
    settle = WRITE, resolve = WRITE, setSetting = WRITE, resetSetting = WRITE,
    resetSettings = WRITE, refresh = WRITE, flush = WRITE, ackAlerts = WRITE, testAlert = WRITE,
    removePhotos = WRITE, setPlaytime = WRITE,
    -- Every measure on a player in force (server/measures.lua: frozen,
    -- suspended, protected, their own target limits), one list: a read.
    measures = READ,
    -- Staff freezes (server/holds.lua): freezing and releasing move no
    -- money and stop nothing for good: a moderator's.
    freeze = MOD, unfreeze = MOD,
    -- A live contract's deadline moved later or sooner (Admin.adjustDeadline):
    -- a moderator's, as void is, on the contract's view.
    adjustDeadline = MOD,
    whois = IDENTITY,
    -- Staff tools on one contract (server/staffcontract.lua), on its view:
    -- a private note, taking one operative off it, replacing a player's
    -- text are writes; its record as text and the card a party sees are
    -- reads, scrubbed as the view is.
    addNote = WRITE, removeHitman = WRITE, editText = WRITE,
    exportContract = READ, playerView = READ,
    -- One player's history card (server/history.lua), under Players.
    history = READ,
    -- Suspending a player from contracts, and protecting one from them
    -- (server/sanctions.lua): a moderator's, as the freeze is.
    suspend = MOD, unsuspend = MOD, protect = MOD, unprotect = MOD,
    -- Paying a player by hand (server/payments.lua): money staff choose.
    manualPay = WRITE,
    -- The staff tools: a notice to every hitman (a write, asked twice on
    -- the page) and an undo of one change through the normal set path (the
    -- settings history is the logs op's 'settings' area).
    announce = WRITE, undoSetting = WRITE,
    -- Presets: named bundles of settings, previewed, then applied (server/presets.lua).
    presets = READ, presetApply = WRITE, presetSave = WRITE,
    -- Presets of the server's own (X5): saved under a name, and deleted.
    presetSaveOwn = WRITE, presetDelete = WRITE,
    -- Settings export and import (server/settingsio.lua), in the Developer
    -- section: reading the export and previewing an import are its own; an
    -- apply changes settings, so the staff ACE's as well.
    settingsExport = DEVELOPER, settingsImport = DEVELOPER, settingsImportApply = WRITE,
    -- The first-start setup (server/setup.lua): it shows the ACE lines and
    -- changes settings, so the staff ACE's alone.
    setup = WRITE, setupPreview = WRITE, setupApply = WRITE,
    -- Target limits (server/targetlimits.lua): the lists and one player's
    -- standing are reads; a job's own limits are settings, the staff ACE's;
    -- a player's cooldown, counts and override, and a job's players at
    -- once, a moderator's, as protecting a player is.
    targetLimits = READ, targetStatus = READ, targetJobCount = READ,
    targetJobSet = WRITE, targetJobRemove = WRITE,
    targetReset = MOD, targetExtend = MOD, targetCounts = MOD, targetOverride = MOD,
    targetOverrideClear = MOD, targetJobAction = MOD,
}

--- Every staff command (Config.Admin.Commands, but the panel's own) and the
--- button or form here that does the same thing: the ops it asks for, the
--- permission they need (as the command's gate: Ace with ExtraAces is a
--- read, Ace itself a write, IdentityAce identity), whether the button
--- takes the two-click confirm, which anything that moves money does, and
--- the audit row both write. The page has no commands in it, only these;
--- a command added without an entry here fails the suite (staff_output_spec).
Panel.COMMANDS = {
    timeline  = { ops = { 'contract' }, level = READ,
                  button = L('panel.a_row_in_contracts_or_any') },
    contracts = { ops = { 'player' }, level = READ, audit = 'admin_contracts',
                  button = L('panel.players_look_up') },
    stuck     = { ops = { 'stuck' }, level = READ, audit = 'admin_stuck',
                  button = L('panel.stuck_escrow') },
    diagnose  = { ops = { 'diag' }, level = READ, button = L('panel.tools_run_the_diagnosis') },
    -- The command needs Ace itself; the button, the moderator level too.
    void      = { ops = { 'void' }, level = WRITE, moderator = true, confirm = true, audit = 'admin_void',
                  button = L('panel.the_contracts_view_void_contract') },
    settle    = { ops = { 'settle' }, level = WRITE, confirm = true, audit = 'admin_settle_line',
                  button = L('panel.stuck_escrow_or_the_contracts_view') },
    review    = { ops = { 'reviews', 'resolve' }, level = WRITE, confirm = true,
                  audit = 'review_resolved', button = L('panel.needs_review_refund_pay_dismiss') },
    refresh   = { ops = { 'refresh' }, level = WRITE, confirm = true, audit = 'admin_timers_refreshed',
                  button = L('panel.tools_bring_timers_forward') },
    whois     = { ops = { 'whois' }, level = IDENTITY, audit = 'admin_identify',
                  button = L('panel.the_contracts_view_or_players_whois') },
}
Panel.LEVELS = { READ = READ, MOD = MOD, WRITE = WRITE, IDENTITY = IDENTITY, DEVELOPER = DEVELOPER }
Panel.OPS = OPS

--- Records › Logs: every log staff read is one op, logs, and each is one of
--- its areas (data.area): the audit log (none, or 'audit'), every setting
--- change ('settings', below), and the hitman organisation's log ('org',
--- its grant history being action 'org_grant'; server/org/staff_ops.lua).
--- [area] = function(src, data) -> ok, err, message, payload, each paged and
--- scrubbed as its own list always was, behind the logs op's gate (READ).
local LOG_AREAS = {}
Panel.LOG_AREAS = LOG_AREAS

--- Add a log area (a module's own log), answered through the logs op.
---@param area string
---@param fn function(src, data)
function Panel.logArea(area, fn)
    if type(area) == 'string' and area ~= 'audit' and type(fn) == 'function' then LOG_AREAS[area] = fn end
end

--- Ops a module adds (the hitman organisation's, server/org/staff_ops.lua),
--- answered through the same gate as OPS: [op] = level, and their handlers.
--- Writes among them wait for boot recovery.
local EXTRA_OPS, EXTRA_H = {}, {}
Panel.EXTRA_OPS = EXTRA_OPS

---@param op string
---@param level string a Panel.LEVELS value
---@param fn function (src, data) -> ok, err, message, data
function Panel.extend(op, level, fn)
    if type(op) == 'string' and not OPS[op] and type(fn) == 'function' then
        EXTRA_OPS[op], EXTRA_H[op] = level, fn
    end
end

--- Writes that wait for boot recovery, as the commands do. Flushing the
--- log is not one: it moves nothing, and is how the log reaches the disk
--- after a recovery that failed.
local WAITS_FOR_RECOVERY = {
    void = true, settle = true, resolve = true, setSetting = true, resetSetting = true,
    resetSettings = true, refresh = true, freeze = true, unfreeze = true, adjustDeadline = true,
    removeHitman = true, editText = true,
    suspend = true, unsuspend = true, protect = true, unprotect = true, manualPay = true,
    undoSetting = true, presetApply = true, presetSave = true, setupApply = true,
    presetSaveOwn = true, presetDelete = true, settingsImportApply = true,
    targetJobSet = true, targetJobRemove = true, targetReset = true, targetExtend = true,
    targetCounts = true, targetOverride = true, targetOverrideClear = true, targetJobAction = true,
    -- And the writes that move no money, as docs/admin-panel.md says every
    -- write but the log's flush waits: a note, a player's playtime, a
    -- notice to every hitman, kept photos removed, alerts acknowledged.
    addNote = true, setPlaytime = true, announce = true, removePhotos = true,
    ackAlerts = true, testAlert = true,
}

--- How long one overview is shared between requests. Each open panel asks
--- for it every Config.Admin.PanelRefreshSeconds, and it reads every
--- contract and every unsettled escrow line, so several staff with the
--- panel open read the store once between them.
local OVERVIEW_SECONDS = 5
local overviewCache = nil   -- { at = os.time(), data = table }

--- And one read of every contract, shared for as long between the overview
--- and the contract searches. On mysql it is a SELECT * of the whole table,
--- thirty days of finished contracts as shipped (Storage.allContracts), and
--- the search asked for it again at every pause in typing: past a thousand
--- rows each read also printed oxmysql's oversized-result warning. A search
--- is a few seconds behind a contract placed meanwhile, as the overview is;
--- a write here reads it afresh.
local contractsCache = nil  -- { at = os.time(), rows = table[] }

--- Refusals already written down, by source and when, so a page posting in
--- a loop cannot fill the audit log with one fact.
local deniedLogged = {}     -- [src] = Util.monotonicMs()
local DENIED_LOG_MS = 10000

--- A reply above this many bytes goes as a latent event, at LATENT_BPS: a
--- page of the log or a long contract timeline, which would otherwise hold
--- up the player's reliable channel.
local LATENT_OVER, LATENT_BPS = 16000, 200000

--- Rows the logs return per page at most, whatever the page asks for.
local LOG_ROWS_MAX = 100

--- Alerts shown at once, newest first, and acknowledged in one request at
--- most (Acknowledge all shown).
local ALERT_ROWS = 100

--- The handles a player lookup gives (H.player), so a write from that card
--- (freeze, suspend, protect, pay, set playtime, and their lifts) acts on
--- exactly the character the lookup found. The page sent back what was
--- typed, and each write matched it again: a name or a player id that by
--- then named somebody else (a drop and a join between the lookup and the
--- click) paid or froze the wrong player. [src] = { [ref] = { cid, staff,
--- at, typed, viaContract } }: only the staff member it was given to, and
--- only for PLAYER_REF_MS. The page never holds the citizen id it stands
--- for (staff without IdentityAce are not shown it).
local playerRefs, playerRefSeq = {}, 0
local PLAYER_REF_MS = 600000        -- ten minutes from the lookup
local PLAYER_REFS_PER_STAFF = 20    -- the oldest go first past this

--- The pages of a search by citizen id without IdentityAce, by the handle
--- each page gives for the next (H.logs). The store's own cursor names the
--- next row the search matched, kept or not: handed to staff, an unfiltered
--- page from it opened on a row the search had left out, so on the
--- anonymous contract the player placed or took. So staff get a handle
--- instead, good only for the staff member it was given to, for the same
--- search and for OPEN_PAGE_MS, and only where at least one more row they
--- may see is left (the rows found past this page are kept with it): its
--- being there says nothing about rows they may not see.
--- [src] = { [handle] = { key, raw, done, rows, at } }
local openPages, openPageSeq = {}, 0
local OPEN_PAGE_MS = 600000         -- ten minutes from the page
local OPEN_PAGES_PER_STAFF = 20     -- the oldest go first past this

function Panel.init(d)
    deps = d
    overviewCache, contractsCache = nil, nil
    deniedLogged = {}
    -- The measures list and its handles (server/measures.lua).
    Measures.init(d)
    playerRefs, playerRefSeq = {}, 0
    openPages, openPageSeq = {}, 0
end

--- Newest first, then by id: the order the Contracts section lists in.
local function newestFirst(a, b)
    if (a.created_at or 0) ~= (b.created_at or 0) then
        return (a.created_at or 0) > (b.created_at or 0)
    end
    return tostring(a.id) > tostring(b.id)
end

--- How long the contract list is kept while nothing is written to the
--- store. Kept until the next write or prune (Projection.keptVersion) rather than
--- for OVERVIEW_SECONDS: the whole table (5,400 rows, 4.6 MB on mysql with
--- thirty days kept) was read again every five seconds the panel stayed on
--- Contracts, the same every time. This is only the backstop for a store
--- changed some way the server did not see (a database edited by hand).
local CONTRACTS_KEPT_SECONDS = 300

--- Every contract the store keeps, newest first: sorted once when read, not
--- once per search or page asked of it (a filter keeps the order). Read
--- again after anything is written through the store, at most once per
--- OVERVIEW_SECONDS while writes keep coming, and at least every
--- CONTRACTS_KEPT_SECONDS. Where the store's writes are not counted, every
--- OVERVIEW_SECONDS as before.
---@return table[]
local function everyContract()
    local now = os.time()
    -- Writes and retention prunes (Projection.keptVersion): a prune removes
    -- finished contracts, which this list shows.
    local function version()
        return deps.projection and deps.projection.keptVersion and deps.projection.keptVersion() or nil
    end
    local gen = version()
    local cache = contractsCache
    local fresh = cache ~= nil and now - cache.at < OVERVIEW_SECONDS
    if cache and not fresh and gen ~= nil and cache.gen == gen
        and now - cache.at < CONTRACTS_KEPT_SECONDS then
        fresh = true
    end
    if not fresh then
        local rows = deps.storage.allContracts() or {}
        table.sort(rows, newestFirst)
        -- Kept as of this generation only if nothing was written while it
        -- was read (mysql waits): otherwise as of no generation, read again
        -- after OVERVIEW_SECONDS as before.
        local after = version()
        contractsCache = { at = now, rows = rows, gen = (after == gen) and gen or nil }
    end
    return contractsCache.rows
end

--------------------------------------------------------------------------
-- Who is asking
--------------------------------------------------------------------------

--- The moderator ACE, as config.lua names it, or nil where it is unset.
local function moderatorAce()
    local ace = Config.Admin.ModeratorAce
    return type(ace) == 'string' and ace ~= '' and ace or nil
end

--- Whether a source may make a request at a level.
---@param src number
---@param level string READ | MOD | WRITE | IDENTITY
---@return boolean
local function allowed(src, level)
    local Admin = deps.admin
    if level == WRITE then return Admin.allowed(src, Config.Admin.Ace, true) end
    if level == MOD then
        if Admin.allowed(src, Config.Admin.Ace, true) then return true end
        local ace = moderatorAce()
        return ace ~= nil and Admin.allowed(src, ace, true)
    end
    if not Admin.allowed(src, Config.Admin.Ace) then return false end
    if level == IDENTITY then return Admin.allowed(src, Config.Admin.IdentityAce, true) end
    return true
end

--- The ACE that opens the Developer section, as config.lua names it.
local function developerAce()
    local ace = Config.Admin.DeveloperAce
    return type(ace) == 'string' and ace ~= '' and ace or 'crimson.developer'
end

--- Whether this staff member may use the Developer section: the console,
--- and the settings in the developer category. Config.Admin.DeveloperAce,
--- or Config.Admin.Ace itself: the owner, who holds Ace under its strict
--- rule, keeps everything they had before the section existed, whether or
--- not anybody was granted the new ACE. Neither opens it to somebody who
--- may not read the panel at all.
local function developer(src)
    if not allowed(src, READ) then return false end
    local Admin = deps.admin
    return Admin.allowed(src, developerAce(), true) or Admin.allowed(src, Config.Admin.Ace, true)
end
Panel.developer = function(src) return developer(src) end

--- Whether this staff member may see who is behind an anonymous party.
local function identifies(src)
    return deps.admin.allowed(src, Config.Admin.IdentityAce, true)
end

--- The staff member's citizen id, for the audit row, and how they are
--- named on a record (a resolution, a setting).
---@return string|nil cid
---@return string who
local function staffOf(src)
    local actor = deps.identity.resolve(src)
    local cid = actor and actor.cid or nil
    return cid, cid or ('player ' .. tostring(src))
end

--- Where boot recovery stands: 'ready', 'recovering' or 'recovery_failed'.
local function recoveryState()
    return deps.admin.recovery() or 'ready'
end

--- What the page needs to draw itself for this staff member. No command
--- names: the page is buttons only, and says nothing about commands.
--- Every ACE this resource checks, for the panel's Permissions page: what
--- it opens, whether this staff member holds it, and the line that grants
--- it (Admin.howToAuthorise's). Read-only: nothing here changes an ACE.
local function permissionsFor(src)
    local Admin = deps.admin
    local function holds(ace) return IsPlayerAceAllowed(src, ace) and true or false end
    local function grant(ace)
        return (select(2, Admin.grantFor(ace)))
    end
    local out = {
        { ace = Config.Admin.Ace, name = L('panel.staff_ace_config_admin_ace'), held = holds(Config.Admin.Ace),
          unlocks = L('panel.opens_this_panel_and_the_staff'),
          grant = grant(Config.Admin.Ace) },
        { ace = moderatorAce() or 'crimson.moderator', name = L('panel.moderator_ace_config_admin_moderatorace'),
          held = moderatorAce() ~= nil and holds(moderatorAce()) or false,
          unlocks = L('panel.opens_this_panel_to_read_everything'),
          grant = grant(moderatorAce() or 'crimson.moderator') },
        { ace = Config.Admin.IdentityAce, name = L('panel.identity_ace_config_admin_identityace'),
          held = holds(Config.Admin.IdentityAce),
          unlocks = L('panel.shows_who_is_behind_an_anonymous'),
          grant = grant(Config.Admin.IdentityAce) },
        { ace = developerAce(), name = L('panel.developer_ace_config_admin_developerace'), held = holds(developerAce()),
          unlocks = L('panel.opens_the_developer_section_the_console'),
          grant = grant(developerAce()) },
    }
    for _, extra in ipairs(type(Config.Admin.ExtraAces) == 'table' and Config.Admin.ExtraAces or {}) do
        if type(extra) == 'string' then
            out[#out + 1] = { ace = extra, name = L('panel.extra_ace_config_admin_extraaces'), held = holds(extra),
                unlocks = L('panel.opens_this_panel_and_the_staff_2'), grant = grant(extra) }
        end
    end
    return out
end

local function accessFor(src)
    local okVersion, version = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
    local isDeveloper = developer(src)
    return {
        canWrite = allowed(src, WRITE),
        -- The moderator's ops (OPS = MOD): the staff ACE, or the moderator ACE.
        canModerate = allowed(src, MOD),
        canIdentify = identifies(src),
        -- The Developer section, and whether it is open through the ACE of
        -- its own or only through the staff ACE (the page says how to grant
        -- the own one then).
        canDevelop = isDeveloper,
        developerAce = developerAce(),
        developerByAce = isDeveloper and deps.admin.allowed(src, developerAce(), true) or false,
        developerHint = isDeveloper and not deps.admin.allowed(src, developerAce(), true)
            and L('panel.to_give_the_developer_section_to') .. table.concat({ deps.admin.grantFor(developerAce()) })
            or nil,
        permissions = permissionsFor(src),
        pageSize = math.max(5, math.min(100, math.floor(tonumber(Config.Admin.PanelPageSize) or 25))),
        refreshSeconds = math.max(2, math.floor(tonumber(Config.Admin.PanelRefreshSeconds) or 10)),
        recovery = recoveryState(),
        version = okVersion and version or nil,
        -- No first-start setup saved yet: the page opens on it for staff who
        -- may change settings (server/setup.lua).
        setupDue = (deps.setup and allowed(src, WRITE) and not deps.setup.saved()) or nil,
    }
end

--- Open the panel for a player: what the page is told when it opens, or
--- nil when they may not open it. Written to the log either way it goes.
---@param src number
---@return table|nil access
function Panel.open(src)
    src = tonumber(src) or 0
    if src <= 0 or not Config.Admin.Enabled or not allowed(src, READ) then return nil end
    local cid = staffOf(src)
    local access = accessFor(src)
    deps.audit.staff('admin_panel_opened', cid, nil,
        { write = access.canWrite or nil, moderate = access.canModerate or nil,
          identify = access.canIdentify or nil })
    return access
end

--------------------------------------------------------------------------
-- Showing people
--------------------------------------------------------------------------

--- Detail fields that hold a citizen id. One of these holding something
--- shaped like one (qbx_core's are capitals and digits) is redacted even
--- when it names nobody on the contract in view.
local CID_KEYS = {
    actor_cid = true, cid = true, to = true, from = true, recipient = true, staker = true,
    payer = true, owed_to = true, releasing_to = true, taken_from = true, settled_to = true,
    creator = true, target = true, hitman = true, subject = true, owed = true, by = true,
    creator_cid = true, target_cid = true, hitman_cid = true, buyer = true, buyer_cid = true,
    killer = true, victim = true, intended = true, owner = true, owner_cid = true,
    proposer = true, declined_by = true, actor = true, who = true,
}

--- Detail fields that hold a server id. A refused or flooded request is
--- kept by the server id that sent it, with the second it came: set beside
--- a contract row of the same second ('operative #1' messaged), it said
--- which player in the city an anonymous party was.
local SOURCE_KEYS = { source = true, src = true, serverId = true }

--- How a party's account (a licence) is shown to staff who may not see who
--- is behind an anonymous party: it is never shown at all.
local ACCOUNT_SHOWN = L('panel.an_account')

--- Every occurrence of each of `needles` in `text`, replaced with what it
--- maps to, the longest first so one that contains another goes whole.
---@param text string
---@param needles table [string] = replacement
---@return string
local function scrubbed(text, needles)
    local order = {}
    for needle in pairs(needles) do
        if type(needle) == 'string' and #needle >= 3 then order[#order + 1] = needle end
    end
    table.sort(order, function(a, b) return #a > #b end)
    for _, needle in ipairs(order) do
        if text:find(needle, 1, true) then
            text = text:gsub(needle:gsub('%W', '%%%0'), (needles[needle]:gsub('%%', '%%%%')))
        end
    end
    return text
end

--- How one staff member is shown the people of one contract.
---
--- With IdentityAce, as they are. Without it, every citizen id is the
--- party's place on the contract ('the client', 'the target', 'operative
--- <alias>', or '(a player)' for anybody else, as /ch-stuck says it), and
--- the name of a party who paid to stay anonymous is 'Anonymous'. Wherever
--- it is written, not only as a whole value: a staff note naming the client,
--- or a database error carrying the statement's values (one stored before
--- Audit cleaned them), named them inside a sentence. Every account (a
--- licence) is left out the same way, and an error's text is shown as Audit
--- keeps it now (Audit.cleaned).
---@param canIdentify boolean
---@param contract table|nil
---@param hitmen table[]|nil
local function redactor(canIdentify, contract, hitmen)
    local labels, hidden, needles = {}, {}, {}
    if contract then
        if contract.target_cid then labels[contract.target_cid] = L('panel.the_target') end
        if contract.creator_cid then labels[contract.creator_cid] = L('panel.the_placer') end
        if contract.anon_creator == true and contract.creator_name then
            hidden[contract.creator_name] = true
        end
        if contract.creator_account then needles[contract.creator_account] = ACCOUNT_SHOWN end
        if contract.target_account then needles[contract.target_account] = ACCOUNT_SHOWN end
    end
    for _, hitman in ipairs(hitmen or {}) do
        if hitman.hitman_cid and not labels[hitman.hitman_cid] then
            labels[hitman.hitman_cid] = L('panel.operative'):format(tostring(hitman.alias or '?'))
        end
        if hitman.anon == true and hitman.hitman_name then hidden[hitman.hitman_name] = true end
        if hitman.hitman_account then needles[hitman.hitman_account] = ACCOUNT_SHOWN end
    end
    for cid, label in pairs(labels) do needles[cid] = label end
    for name in pairs(hidden) do needles[name] = L('panel.anonymous') end

    local r = { canIdentify = canIdentify }

    --- A citizen id as this staff member may see it.
    function r.who(cid)
        if cid == nil then return nil end
        if canIdentify then return cid end
        return labels[cid] or L('panel.a_player')
    end

    --- A creator's or a hitman's name as this staff member may see it.
    function r.name(name, anonymous)
        if anonymous and not canIdentify then return L('panel.anonymous') end
        return name
    end

    --- Anything read from the log, copied, with every citizen id, account
    --- and anonymous name in it put the way this staff member may see them,
    --- whole values and inside text alike.
    local function value(key, v)
        if type(v) == 'table' then
            local out = {}
            for k, inner in pairs(v) do out[k] = value(k, inner) end
            return out
        end
        if not canIdentify and SOURCE_KEYS[key] and type(v) == 'number' then return L('panel.a_player') end
        if canIdentify or type(v) ~= 'string' then return v end
        if labels[v] then return labels[v] end
        if hidden[v] then return L('panel.anonymous') end
        if CID_KEYS[key] and v:match('^[%u%d]+$') and #v >= 3 then return L('panel.a_player') end
        -- An error's text as Audit keeps it now: a row stored before it
        -- cleaned them still holds the statement's values.
        if key ~= nil then v = deps.audit.cleaned({ [key] = v })[key] end
        return scrubbed(v, needles)
    end
    r.value = value
    return r
end

--- The parties of one contract, read once per request.
local function partiesReader()
    local contracts, hitmen = {}, {}
    return function(contractId)
        if not contractId then return nil, nil end
        if contracts[contractId] == nil then
            local ok, found = pcall(deps.storage.readContract, contractId)
            contracts[contractId] = ok and found or false
            local okH, list = pcall(deps.storage.readHitmen, contractId)
            hitmen[contractId] = okH and list or {}
        end
        return contracts[contractId] or nil, hitmen[contractId]
    end
end

--- What names a player's account wherever it is written: a licence, and
--- the other identifiers FiveM gives an account.
local ACCOUNT_PREFIXES = { 'license2', 'license', 'steam', 'discord', 'fivem', 'xbl', 'live', 'ip' }

--- Free text kept for staff (an alert, a console line), as one staff member
--- may read it: whole with IdentityAce, and otherwise scrubbed as every
--- other view here is. A database error in it keeps the server's words and
--- the start of the statement, never the values it was sent (Util.dbErrorIn);
--- the people of the contract it names are put as the redactor puts them
--- (their place on it, Anonymous, an account); and any account, or word
--- shaped like a citizen id (capitals and digits, both), whoever it names,
--- is left out. `outside` is a reader outside the server (Discord, which
--- never has an identity ACE): every party's name is their place on the
--- contract as well, anonymous or not, and every link is left out; and where
--- the contract named cannot be read, so its parties' names are not known,
--- nothing is given at all (nil).
---@param text any
---@param canIdentify boolean
---@param contractId string|nil the contract the text names
---@param outside boolean|nil
---@param parties function|nil a partiesReader, shared by every row of a page
---@return string|nil
function Panel.scrubText(text, canIdentify, contractId, outside, parties)
    text = tostring(text or '')
    if canIdentify and not outside then return text end
    text = Util.dbErrorIn(text)
    local contract, hitmen
    if contractId and deps then contract, hitmen = (parties or partiesReader())(contractId) end
    if outside and contractId and not contract then return nil end
    text = redactor(false, contract, hitmen).value(nil, text)
    if outside then
        local names = {}
        if contract and contract.creator_name then names[contract.creator_name] = L('panel.the_placer') end
        if contract and contract.target_name then names[contract.target_name] = L('panel.the_target') end
        for _, hitman in ipairs(hitmen or {}) do
            if hitman.hitman_name then
                names[hitman.hitman_name] = L('panel.operative'):format(tostring(hitman.alias or '?'))
            end
        end
        text = scrubbed(text, names):gsub('https?://%S+', L('panel.a_link'))
    end
    for _, prefix in ipairs(ACCOUNT_PREFIXES) do
        text = text:gsub('%f[%w]' .. prefix .. ':[%w%.:]+', ACCOUNT_SHOWN)
    end
    return (text:gsub('%f[%w][%u%d]+%f[%W]', function(word)
        if #word >= 5 and #word <= 32 and word:find('%u') and word:find('%d') then
            return L('panel.a_player')
        end
        return word
    end))
end

--- The server convars that hold a secret, whose values never reach the
--- page: the two Discord webhooks, and oxmysql's connection string, whose
--- password a database error could carry.
local SECRET_CONVARS = { 'crimson_hitman_webhook', 'crimson_hitman_alert_webhook',
                         'mysql_connection_string' }

--- How a password is written in a connection string, in any case.
local PASSWORD_WORDS = { '[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]', '[Pp][Aa][Ss][Ss][Ww][Dd]', '[Pp][Ww][Dd]' }

--- Every occurrence of `needle` in `text`, as `with`.
local function replacePlain(text, needle, with)
    return (text:gsub(needle:gsub('%p', '%%%0'), (with:gsub('%%', '%%%%'))))
end

--- A console line as the admin panel's Console section shows it to anybody,
--- identity ACE or not: never a webhook's address, a convar's secret or the
--- values a statement was sent. A database error keeps the server's words
--- and the start of the statement (Util.dbErrorIn); a secret convar's value
--- is '(hidden)' wherever it is written; every web address is cut to its
--- host, which drops a webhook's id and token, a served photo's name and a
--- key in a query, and the user and password of one that has them; and a
--- password written as `password=` is hidden.
---@param text any
---@return string
function Panel.withoutSecrets(text)
    text = Util.dbErrorIn(tostring(text or ''))
    for _, name in ipairs(SECRET_CONVARS) do
        local ok, value = pcall(GetConvar, name, '')
        if ok and type(value) == 'string' and #value >= 8 then
            text = replacePlain(text, value, '(hidden)')
        end
    end
    text = text:gsub('(%a[%w+.-]*://)([^%s/?#]+)([^%s]*)', function(scheme, host, rest)
        host = host:gsub('^.*@', '')
        return scheme .. host .. (rest ~= '' and L('panel.path_hidden') or '')
    end)
    text = text:gsub('(api/webhooks/)%S+', '%1(hidden)')
    for _, word in ipairs(PASSWORD_WORDS) do
        text = text:gsub('(%f[%w]' .. word .. '%s*[=:]%s*)[^%s;,&]+', '%1(hidden)')
    end
    return text
end

--- The first contract id a line names, if it names one: whose parties the
--- scrub puts by their place on it (as the Alerts do).
local function contractIn(text)
    for candidate in text:gmatch('%f[%w](ct[%l%d]+)%f[%W]') do
        if Util.toId(candidate) then return candidate end
    end
    return nil
end

--- One escrow line, as the panel shows it.
local function lineView(line, r)
    local escrow = deps.escrow
    return {
        id = line.id, contract = line.contract_id, slot = line.slot, portion = line.portion,
        source = line.source,
        amount = CH.MONEY_SOURCES[line.source] and (tonumber(line.amount) or 0) or nil,
        item = line.item, quantity = tonumber(line.quantity), state = line.state,
        owed_to = r.who(line.owed_to), releasing_to = r.who(line.releasing_to),
        taken_from = r.who(line.taken_from), staker = r.who(line.staker),
        settled_to = r.who(line.settled_to), settled_at = line.settled_at,
        settled_by_staff = line.settled_by_staff,
        arrived = tonumber(line.deliver_arrived), raised = tonumber(line.deliver_raises) or 0,
        parked = escrow.parked(line),
        owes = line.state ~= CH.ESCROW_STATE.SETTLED and escrow.stillOwed(line) or 0,
    }
end

--- Detail fields only staff with IdentityAce read, by the row's action.
---
--- What an identity holder searched for, and how many contracts it found,
--- counts the ones it matched through an anonymous party: a reader without
--- the ACE who ran the same search and found fewer learned that the citizen
--- id or name typed was behind that many anonymous contracts. Neither is a
--- citizen id in a field that says so, so nothing else here redacted them.
local IDENTITY_ONLY = {
    admin_panel_search_identified = { query = true, rows = true },
    -- A weapon's serial before it was scrubbed (Config.Improvements.SerialScrub,
    -- server/imp_scrub.lua): it can be traced to the anonymous placer.
    weapon_serial_scrubbed = { original = true },
}
local IDENTITY_ONLY_SHOWN = L('panel.identity_only')

--- Rows whose actor staff without IdentityAce are shown only as what they
--- were, not as which party: an informant tip (server/intel/tip.lua) says
--- a hitman bought one, never which operative, since an anonymous hitman's
--- alias is the one thing that tells two of them apart.
local ACTOR_SHOWN_AS = {
    location_tip_bought = { actor = L('panel.a_hitman'), said = L('panel.a_hitman_bought_an_informant_tip') },
    location_tip_refunded = { actor = L('panel.a_hitman'), said = L('panel.an_informant_tip_was_given_back') },
    location_tip_refund_failed = { actor = L('panel.a_hitman'),
                                   said = L('panel.an_informant_tip_could_not_be') },
}

--- One audit row, as the panel shows it.
local function rowView(row, r)
    local detail = r.value(nil, row.detail or {})
    local hidden = not r.canIdentify and IDENTITY_ONLY[row.action]
    if hidden then
        for key in pairs(hidden) do
            if detail[key] ~= nil then detail[key] = IDENTITY_ONLY_SHOWN end
        end
    end
    local shownAs = not r.canIdentify and ACTOR_SHOWN_AS[row.action]
    if shownAs then detail.said = shownAs.said end
    return {
        ts = row.ts, kind = row.kind, action = row.action, contract = row.contract_id,
        actor = shownAs and shownAs.actor or r.who(row.actor_cid), detail = detail,
    }
end

--------------------------------------------------------------------------
-- Reading the values a request carries
--------------------------------------------------------------------------

local function wholeNumber(value, min, max)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge or math.floor(n) ~= n then return nil end
    n = math.tointeger(n)
    if not n or (min and n < min) or (max and n > max) then return nil end
    return n
end

--- How far staff may move a deadline either way, and the least run time a
--- shortening must leave (Config.Limits).
local function adjustLimits()
    return math.max(60, math.floor(tonumber(Config.Limits.StaffDeadlineMaxAdjustSeconds) or 86400)),
        math.max(0, math.floor(tonumber(Config.Limits.StaffDeadlineMinLeftSeconds) or 300))
end

local function shortText(value, max)
    if type(value) ~= 'string' then return nil end
    return Util.sanitizeText(value, max)
end

--- A citizen id staff typed, in the form the server keeps it, or nil.
---
--- qbx_core's are capitals and digits, and every lookup by one is an exact
--- match on the store's index: 'target01' found no contract, a player view
--- of nobody, and no log row, each answered as though there were nothing to
--- find. Upper case, unless the server knows it as typed (a server whose ids
--- are not all capitals), which costs a lookup only when it was typed in
--- lower case.
---@param value any
---@return string|nil
local function typedCitizenId(value)
    local cid = Util.toCitizenId(value)
    if not cid then return nil end
    local upper = cid:upper()
    if upper == cid then return cid end
    if deps.identity.byCitizenId(cid) or #(deps.storage.contractsInvolving(cid) or {}) > 0 then
        return cid
    end
    return upper
end

local VALID_STATE = {}
for _, state in pairs(CH.STATE) do VALID_STATE[state] = true end

local VALID_KIND = { financial = true, conduct = true, rejected = true, system = true }

local function pageSize()
    return math.max(5, math.min(100, math.floor(tonumber(Config.Admin.PanelPageSize) or 25)))
end

--------------------------------------------------------------------------
-- The overview
--------------------------------------------------------------------------

--- What the diagnosis says that wants doing (the lines with '->', the lines
--- it marks 'act', or a word in capitals), run as the console would, which
--- asks no player's phone for anything, in the panel's words. The lines only
--- the console needs (marked 'console') are left out, and so are the
--- console's own lines it keeps (marked with a dot), which are notes, not
--- things to do. Read by mark, never by the words: they are in the
--- language Config.Locale names.
local function diagWarnings()
    local ok, lines, marks = pcall(deps.admin.diagnose, 0, nil, nil, { panel = true })
    if not ok or type(lines) ~= 'table' then
        return { L('panel.the_diagnosis_itself_raised'):format(Util.dbError(lines)) }
    end
    marks = type(marks) == 'table' and marks or {}
    local out = {}
    for i, line in ipairs(lines) do
        local skip = marks[i] == 'console' or line:find('^%-%-%-') ~= nil or line:find('^%s*·') ~= nil
        if not skip and (marks[i] == 'act' or line:find('->', 1, true) or line:find('%u%u%u%u')) then
            out[#out + 1] = (line:gsub('^%s+', ''))
        end
    end
    return out
end

--- What a stuck line can be settled with, as /ch-stuck says (Admin.interrupted).
---
--- Never `return` for a line owed to somebody (a buyout's premium, a review
--- item's pay): it was put up by nobody it could go back to, and
--- Admin.settleLine refuses every return of one, so the button only ever
--- answered invalid_input.
---
--- Only Pay for a line nothing of which was given (Escrow.NEVER_GIVEN, and
--- one left mid-release before it named anyone that is owed to somebody):
--- Pay amount there gave the player the amount typed and wrote the rest
--- off as arrived. One of those owed to nobody takes Return alone, which
--- puts it back to its contract. A line owed and queued to a citizen id no
--- character has takes Return to, which moves it to the right one; one
--- where that could not be checked, nothing.
local function settleActions(entry)
    if entry.unfinished then return {} end
    if entry.orphan then return { 'return_owner' } end
    if entry.why == 'owed_to_nobody' then return { 'return_owner' } end
    if entry.why == 'owed_to_unchecked' then return {} end
    local owed = entry.portion == CH.PORTION.OWED
    if entry.raised ~= nil then
        if deps.escrow.NEVER_GIVEN[entry.why] then return { 'pay' } end
        if entry.why == 'never_given_release' then return entry.owed and { 'pay' } or { 'return' } end
        if owed then return { 'pay', 'pay_amount', 'delivered' } end
        return { 'pay', 'pay_amount', 'return', 'delivered' }
    end
    if entry.settles == 'queued' then return {} end
    if entry.settles == 'return_owner' then return { 'return_owner' } end
    if entry.settles == 'pay_or_return' then return owed and { 'pay' } or { 'pay', 'return' } end
    return owed and {} or { 'return' }
end

local function addLine(bucket, line, owes)
    if CH.MONEY_SOURCES[line.source] then
        bucket[line.source] = bucket[line.source] + (owes or tonumber(line.amount) or 0)
    elseif line.source == CH.SOURCE.ITEM then
        bucket.items = bucket.items + (owes or tonumber(line.quantity) or 0)
    elseif line.source == CH.SOURCE.WEAPON then
        bucket.weapons = bucket.weapons + 1
    end
    bucket.lines = bucket.lines + 1
end

local function buildOverview()
    local Storage = deps.storage
    local out = { at = os.time() }

    -- Counted by the store where it can (one GROUP BY on mysql), not from
    -- every row of the table brought into Lua every few seconds.
    local byState, total = {}, 0
    if Storage.countContractsByState then
        for state, n in pairs(Storage.countContractsByState() or {}) do
            byState[state] = n
            total = total + n
        end
    else
        for _, contract in ipairs(everyContract()) do
            byState[contract.state] = (byState[contract.state] or 0) + 1
            total = total + 1
        end
    end
    out.contracts = { byState = byState, total = total }

    -- Places held (one per operative on a contract), the people holding
    -- them, and the contracts they are on: two operatives on one contract
    -- are two places and one contract, which the tile said were two.
    local active, operatives, distinct, onContracts = 0, {}, 0, 0
    for _, list in pairs(Storage.liveHitmen() or {}) do
        local onIt = false
        for _, hitman in ipairs(list) do
            if hitman.state == 'active' then
                active = active + 1
                onIt = true
                if not operatives[hitman.hitman_cid] then
                    operatives[hitman.hitman_cid] = true
                    distinct = distinct + 1
                end
            end
        end
        if onIt then onContracts = onContracts + 1 end
    end
    out.hitmen = { active = active, operatives = distinct, contracts = onContracts }

    -- Money still in escrow for contracts, and money owed to somebody: the
    -- second is what the owed-delivery queue holds (or waits on staff for).
    local held = { cash = 0, bank = 0, dirty = 0, items = 0, weapons = 0, lines = 0 }
    local owed = { cash = 0, bank = 0, dirty = 0, items = 0, weapons = 0, lines = 0,
                   players = 0, queued = 0 }
    local owedTo, queues = {}, {}
    for _, line in ipairs(Storage.unsettledEscrow and Storage.unsettledEscrow() or {}) do
        if line.owed_to then
            addLine(owed, line, deps.escrow.stillOwed(line))
            if not owedTo[line.owed_to] then
                owedTo[line.owed_to] = true
                owed.players = owed.players + 1
            end
            if deps.escrow.queued(line, queues) then owed.queued = owed.queued + 1 end
        else
            addLine(held, line)
        end
    end
    out.held, out.owed = held, owed

    -- What waits for staff, as /ch-stuck lists it. Not while recovery is
    -- still deciding it: the command says nothing is listed then, and so
    -- does this. Left for staff is every line something settles by hand
    -- (settleActions): counted as the parked ones only, a line a shutdown
    -- caught mid-release and escrow of a contract never stored were said not
    -- to be staff's, and the total counted lines queued since or an ending
    -- finishing itself, which need nobody.
    --
    -- A listing that raised (a store read failing) says so: left out, the
    -- tile read as though recovery were still running, with the badge gone,
    -- while Stuck escrow itself answered with the error.
    out.recovery = recoveryState()
    if out.recovery == 'ready' then
        local ok, lines = pcall(deps.admin.interrupted, 0, true)
        if ok and type(lines) == 'table' then
            local byWhy, leftForStaff = {}, 0
            for _, entry in ipairs(lines) do
                local why = entry.why or (entry.orphan and 'orphan') or 'interrupted'
                byWhy[why] = (byWhy[why] or 0) + 1
                if #settleActions(entry) > 0 then leftForStaff = leftForStaff + 1 end
            end
            out.stuck = { total = #lines, byWhy = byWhy, leftForStaff = leftForStaff }
        else
            Log.debug(('the admin panel overview could not list stuck escrow: %s')
                :format(Util.dbError(lines)))
            out.stuck = { error = true }
        end
    end

    out.reviews = { open = deps.review and deps.review.openCount() or 0 }
    -- Alerts nobody has acknowledged, for the badge and the tile.
    out.alerts = { open = deps.alerts and deps.alerts.openCount() or 0 }

    local okPhotos, totals = pcall(deps.photos.totals)
    out.photos = okPhotos and totals or nil

    out.storage = Config.Database.Mode
    out.fulfilment = Util.placingRule()
    out.photoStorage = Config.Completion.PhotoStorage
    -- Kill photos at all (Config.Completion.KillPhotos): off, where they
    -- are kept says nothing.
    out.killPhotos = Config.Completion.KillPhotos == true
    out.slowest = deps.timing and deps.timing.slowest(5) or {}
    out.slowMs = tonumber(Config.Diagnostics.SlowJobMs) or 0
    out.warnings = diagWarnings()
    -- Settings in force over config.lua, as the Settings section counts
    -- them, and apart from those the store holds that were not applied.
    local overrides, notApplied = 0, 0
    for _, row in ipairs(deps.settings and deps.settings.active() or {}) do
        if row.ignored then notApplied = notApplied + 1 else overrides = overrides + 1 end
    end
    out.overrides, out.notApplied = overrides, notApplied
    out.auditQueued = deps.audit.pending()
    -- Every measure on a player in force (server/measures.lua): counts
    -- only, for the overview; the list is the measures op's. The frozen
    -- count is unknown while the store's freezes cannot be read: never 0 of
    -- nobody known.
    local counts = Measures.counts()
    out.measures = { freeze = counts.freeze or 0, unknown = counts.unknown == true or nil,
        suspend = deps.sanctions and counts.suspend or nil, protect = deps.sanctions and counts.protect or nil,
        limit = deps.targetLimits and counts.limit or nil }
    -- The whole app paused by staff (Config.Holds.AppPaused), and since when.
    out.appPaused = deps.holds and deps.holds.global('app') or nil
    return out
end

--- Which of a contract's parties this staff member may be shown has put it
--- on hold (Holds.shown), or nil.
local function frozenShown(contract, hitmen, canIdentify)
    return deps.holds and deps.holds.shown(contract, hitmen, canIdentify) or nil
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------

--- One function per op: (src, data) -> ok, err, message, data.
local H = {}

local freezeView

H.access = function(src)
    return true, nil, nil, accessFor(src)
end

H.overview = function()
    local now = os.time()
    if not overviewCache or now - overviewCache.at >= OVERVIEW_SECONDS then
        overviewCache = { at = now, data = buildOverview() }
    end
    return true, nil, nil, overviewCache.data
end


--- The lines /ch-stuck lists for one contract, with what settles each, or
--- nil while recovery is still deciding them.

local function stuckOf(src, id)
    if recoveryState() ~= 'ready' then return nil end
    local stuck = {}
    local ok, lines = pcall(deps.admin.interrupted, src, true)
    for _, entry in ipairs(ok and lines or {}) do
        if entry.contract == id then
            local view = {}
            for k, v in pairs(entry) do view[k] = v end
            view.actions = settleActions(entry)
            stuck[#stuck + 1] = view
        end
    end
    return stuck
end

--- One contract, whole: its terms, payouts, escrow, operatives, open
--- proposals, the lines /ch-stuck lists for it, and its audit timeline.
---
--- An id with escrow and no contract row (a contract whose recording write
--- failed after its money was taken, or a review pay on one never stored)
--- answers too, as a view of its lines alone: the overview counts them as
--- left for staff, and this is the one view that can settle them (Return
--- to, which names who put the money up). Answered not found, only the
--- console's settle command could.
H.contract = function(src, data, quiet)
    local Storage = deps.storage
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    local contract = Storage.readContract(id)
    local lines = Storage.readEscrow(id) or {}
    if not contract and #lines == 0 then return false, CH.ERR.NOT_FOUND, L('panel.no_contract_has_that_id') end

    -- The log written first, as the timeline command does: a staff member
    -- looking into something that just happened is asking about the last
    -- ten seconds.
    deps.audit.flush()
    local canIdentify = identifies(src)
    local hitmen = contract and Storage.readHitmen(id) or {}
    local r = redactor(canIdentify, contract, hitmen)

    -- What each operative has at stake now: their stake lines not yet
    -- settled, as the stake itself is kept (Contracts' heldStakes). The
    -- hitmen row's stake_amount is written by nothing and read $0 for
    -- every operative on every backend.
    local escrow, stakes = {}, {}
    for _, line in ipairs(lines) do
        escrow[#escrow + 1] = lineView(line, r)
        if line.portion == CH.PORTION.STAKE and line.staker
            and line.state ~= CH.ESCROW_STATE.SETTLED then
            stakes[line.staker] = (stakes[line.staker] or 0) + (tonumber(line.amount) or 0)
        end
    end

    local timeline = {}
    for _, row in ipairs(Storage.auditForContract(id, Config.Admin.TimelineRows) or {}) do
        timeline[#timeline + 1] = rowView(row, r)
    end

    if not contract then
        if not quiet then
            deps.audit.staff(canIdentify and 'admin_panel_contract_identified' or 'admin_panel_contract',
                staffOf(src), id, { never_stored = true })
        end
        return true, nil, nil, {
            contract = { id = id, neverStored = true },
            escrow = escrow, hitmen = {}, amendments = {}, timeline = timeline,
            stuck = stuckOf(src, id), canVoid = false,
        }
    end

    local operatives = {}
    for _, hitman in ipairs(hitmen) do
        operatives[#operatives + 1] = {
            id = hitman.id, alias = hitman.alias, anonymous = hitman.anon == true,
            name = r.name(hitman.hitman_name, hitman.anon == true),
            cid = canIdentify and hitman.hitman_cid or nil,
            state = hitman.state, accepted_at = hitman.accepted_at, left_at = hitman.left_at,
            claims = tonumber(hitman.claims) or 0, stake = stakes[hitman.hitman_cid] or 0,
            last_claim_at = hitman.last_claim_at,
        }
    end

    local amendments = {}
    for _, proposal in ipairs(Storage.readOpenAmendments(id) or {}) do
        amendments[#amendments + 1] = {
            id = proposal.id, kind = proposal.kind, proposer = r.who(proposal.proposer),
            outcome = proposal.outcome, expires_at = proposal.expires_at,
            payload = r.value(nil, proposal.payload),
        }
    end

    -- The lines /ch-stuck lists for this contract, with what settles each.
    -- Not while recovery is still deciding them.
    local stuck = stuckOf(src, id)

    if not quiet then
        deps.audit.staff(canIdentify and 'admin_panel_contract_identified' or 'admin_panel_contract',
            staffOf(src), id, {})
    end

    return true, nil, nil, {
        contract = {
            id = contract.id, state = contract.state, mode = contract.mode,
            rule = Util.fulfilmentRule(contract), reason = contract.reason,
            created_at = contract.created_at, deadline_at = contract.deadline_at,
            expires_at = contract.expires_at, resolved_at = contract.resolved_at,
            resolution = contract.resolution, paused_since = contract.paused_since,
            bailout_amount = tonumber(contract.bailout_amount) or 0,
            penalty_amount = tonumber(contract.penalty_amount) or 0,
            bonus_percent = tonumber(contract.bonus_percent) or 0,
            slots = contract.payout_slots, claimed = contract.slots_claimed,
            next_slot = contract.next_slot,
            buyout_queued = contract.bailout_queued_at ~= nil,
            target_protected = contract.target_protected == true,
            anonymous = contract.anon_creator == true,
            client = { name = r.name(contract.creator_name, contract.anon_creator == true),
                       cid = canIdentify and contract.creator_cid or nil },
            target = { name = contract.target_name, cid = canIdentify and contract.target_cid or nil },
            -- The handover's meeting point (server/meeting.lua): where the
            -- client stood, so with IdentityAce only, as who they are is.
            -- Without it, not even whether one is set.
            meeting = canIdentify and contract.meeting_x ~= nil
                and { x = tonumber(contract.meeting_x), y = tonumber(contract.meeting_y) } or nil,
        },
        escrow = escrow, hitmen = operatives, amendments = amendments,
        timeline = timeline, stuck = stuck,
        canVoid = not CH.TERMINAL[contract.state],
        -- The exact run time left (staff see it; players see its band), and
        -- whether Extend and Shorten apply: only while the deadline still
        -- runs, active or accepted. The limits the server holds them to.
        deadline = {
            left = Util.runLeft(contract), stopped = contract.paused_since ~= nil,
            adjustable = (contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED)
                and contract.deadline_at ~= nil,
            maxAdjust = adjustLimits(),
            minLeft = select(2, adjustLimits()),
        },
        -- On hold by staff (server/holds.lua), with which of its parties
        -- this staff member may be told.
        frozen = frozenShown(contract, hitmen, canIdentify),
        -- Staff notes, removals and text edits on it (server/staffcontract.lua).
        staff = Panel.staffPart(contract, r),
    }
end

--- Run time as staff read it, to the second: '1 h 05 min', '25 min 10 s'.
local function exactSpan(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
    local out = {}
    if h > 0 then out[#out + 1] = (L('panel.span_hours')):format(h) end
    if m > 0 or (h > 0 and s > 0) then
        out[#out + 1] = (L('panel.span_minutes')):format(h > 0 and ('%02d'):format(m) or tostring(m))
    end
    if s > 0 or #out == 0 then out[#out + 1] = (L('panel.span_seconds')):format(s) end
    return table.concat(out, ' ')
end

--- Extend or shorten a live contract's deadline (Admin.adjustDeadline):
--- the panel's Extend and Shorten, on the contract's view. `seconds` is
--- signed, a whole number, not zero and within
--- Config.Limits.StaffDeadlineMaxAdjustSeconds either way; a reason is
--- required, and kept in the log (staff_deadline_adjust).
H.adjustDeadline = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    local maxAdjust = adjustLimits()
    local seconds = wholeNumber(data.seconds, -maxAdjust, maxAdjust)
    if not seconds or seconds == 0 then
        return false, CH.ERR.INVALID_INPUT, L('panel.give_a_whole_number_of_seconds'):format(exactSpan(maxAdjust))
    end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end

    local ok, err, detail = deps.admin.adjustDeadline(src, id, seconds, reason)
    if not ok then
        if err == 'recovering' or err == 'recovery_failed' then return false, err, deps.admin.notRecovered() end
        if err == CH.ERR.NOT_FOUND then return false, err, L('panel.no_contract_has_that_id') end
        if err == CH.ERR.BAD_STATE then
            return false, err, L('panel.only_a_live_contract_active_or')
        end
        if err == 'no_deadline' then return false, err, L('panel.that_contract_has_no_deadline_to') end
        if err == 'min_left' then
            if (detail.most or 0) <= 0 then
                return false, err, (L('panel.not_shortened_it_has_left_and'))
                    :format(exactSpan(detail.left), exactSpan(detail.minLeft))
            end
            return false, err, (L('panel.not_shortened_it_has_left_and_2'))
                :format(exactSpan(detail.left), exactSpan(detail.minLeft), exactSpan(detail.most))
        end
        if err == 'at_limit' then
            return false, err, (L('panel.not_extended_its_lifetime_is_already'))
                :format(exactSpan(Config.Limits.ContractLifetimeSeconds))
        end
        if err == 'bad_adjust' then
            return false, CH.ERR.INVALID_INPUT, (L('panel.at_most_either_way')):format(exactSpan(maxAdjust))
        end
        if err == CH.ERR.LOCKED then
            return false, err, L('panel.the_deadline_was_moving_as_you')
        end
        return false, err, L('panel.not_changed_the_store_did_not')
    end

    local moved = math.abs(detail.seconds)
    local message
    if detail.seconds > 0 then
        message = (L('panel.extended_by_left_before_left_now'))
            :format(exactSpan(moved), exactSpan(detail.left_before), exactSpan(detail.left_after))
        if detail.lifetime == 'extended' then
            message = message .. L('panel.the_new_deadline_passed_its_lifetime'):format(exactSpan(moved))
        elseif detail.lifetime == 'capped' then
            message = message .. (L('panel.the_new_deadline_passed_its_lifetime_2'))
                :format(exactSpan(Config.Limits.ContractLifetimeSeconds),
                    moved < detail.requested and (L('panel.and_the_deadline_only_as_far'))
                        :format(exactSpan(moved), exactSpan(detail.requested)) or '')
        end
    else
        message = (L('panel.shortened_by_left_before_left_now'))
            :format(exactSpan(moved), exactSpan(detail.left_before), exactSpan(detail.left_after))
    end
    if detail.paused then
        message = message .. L('panel.its_clock_is_stopped_now_it')
    end
    message = message .. L('panel.every_party_was_told_its_time')
    return true, nil, message, {
        seconds = detail.seconds, leftBefore = detail.left_before, leftAfter = detail.left_after,
        deadline = detail.new_deadline, lifetime = detail.lifetime, expires = detail.new_expires,
    }
end

H.void = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    local reason = shortText(data.reason, 120)
    local ok, err, detail = deps.admin.void(src, id, reason)
    return ok, err, deps.admin.voidAnswer(id, ok, err, true, detail), { detail = detail }
end

local DISPOSITIONS = { pay = true, ['return'] = true, delivered = true }

H.settle = function(src, data)
    local line = Util.toLineId(data.line)
    if not line then return false, CH.ERR.INVALID_INPUT, L('panel.give_an_escrow_line_id') end
    local disposition = DISPOSITIONS[data.disposition] and data.disposition or nil
    if not disposition then
        return false, CH.ERR.INVALID_INPUT, L('panel.say_pay_return_or_delivered')
    end
    local extra
    if disposition == 'pay' and data.amount ~= nil then
        extra = wholeNumber(data.amount, 1, 1000000000)
        if not extra then
            return false, CH.ERR.INVALID_INPUT, L('panel.an_amount_is_a_whole_number')
        end
    elseif disposition == 'return' and data.owner ~= nil then
        -- Checked by the settle itself, as the command's is: in the form the
        -- server keeps it, and only one somebody here has
        -- (Admin.knownCitizenId).
        extra = Util.toCitizenId(data.owner)
        if not extra then return false, CH.ERR.INVALID_INPUT, L('panel.that_is_not_a_citizen_id') end
    end
    local ok, err, detail = deps.admin.settleLine(src, line, disposition, extra)
    return ok, err, deps.admin.settleAnswer(ok, err, detail, true), { detail = detail }
end

H.reviews = function(src, data)
    return true, nil, nil, { items = deps.admin.reviews(src, data.all == true) }
end

--- Every escrow line waiting for staff, with what settles each, as the
--- stuck listing in F8 lists them (Admin.interrupted, audited the same
--- way), and how many items wait in the review queue, which it lists
--- below them. Not while recovery is still deciding them: that listing
--- says nothing is listed then, and so does this.
H.stuck = function(src)
    local recovery = recoveryState()
    local reviews = deps.review and deps.review.openCount() or 0
    if recovery ~= 'ready' then
        return true, nil, nil, { recovery = recovery, reviews = reviews }
    end
    local lines = {}
    for _, entry in ipairs(deps.admin.interrupted(src) or {}) do
        local view = {}
        for k, v in pairs(entry) do view[k] = v end
        view.actions = settleActions(entry)
        lines[#lines + 1] = view
    end
    return true, nil, nil, { recovery = recovery, lines = lines, reviews = reviews }
end

local REVIEW_ACTIONS = { refund = true, pay = true, dismiss = true, finish = true }

H.resolve = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_review_item_id') end
    local action = REVIEW_ACTIONS[data.action] and data.action or nil
    if not action then return false, CH.ERR.INVALID_INPUT, L('panel.say_refund_pay_dismiss_or_finish') end
    -- Built into the words the command takes, so it is resolved by exactly
    -- the path /ch-review resolves it by (Admin.resolveReview).
    local args = { action }
    if action == 'finish' then
        -- An item left being resolved, finished as it was decided: the id
        -- alone, as /ch-review <id> takes it, and no other action's fields
        -- (W137). One still open is refused there.
        args = {}
    elseif action == 'dismiss' then
        args[2] = shortText(data.note, 200)
    else
        local who = type(data.who) == 'string' and #data.who <= 32
            and data.who:match('^[%w_%-]+$') and data.who or nil
        if not who then
            return false, 'no_party', deps.admin.reviewAnswer(id, false, 'no_party', nil, true)
        end
        args[2] = who
        if action == 'refund' then
            if data.goods == true then
                args[3] = 'items'
            else
                local amount = wholeNumber(data.amount, 1, 1000000000)
                if not amount then
                    return false, CH.ERR.INVALID_INPUT, L('panel.an_amount_is_a_whole_number')
                end
                args[3] = tostring(amount)
                if data.account ~= nil then
                    if not CH.MONEY_SOURCES[data.account] then
                        return false, 'which_money', deps.admin.reviewAnswer(id, false, 'which_money', nil, true)
                    end
                    args[4] = data.account
                end
            end
        end
    end
    local ok, err, detail = deps.admin.resolveReview(src, id, args)
    return ok, err, deps.admin.reviewAnswer(id, ok, err, detail, true), { detail = detail }
end

--- Whether a log row a citizen id acted in may be listed, for staff without
--- IdentityAce who searched by it: only a row about a contract they are a
--- party of in a role they did not pay to keep anonymous (its target, a
--- client who placed it under their name, an operative who took it under
--- theirs). A row about no contract, or one that cannot be read, is left
--- out: whether the player is behind something anonymous is not to be
--- learned from what a search leaves out or keeps.
local function actedOpenly(row, cid, parties)
    local contract, hitmen = parties(row.contract_id)
    if not contract then return false end
    if contract.target_cid == cid then return true end
    if contract.creator_cid == cid then return contract.anon_creator ~= true end
    for _, hitman in ipairs(hitmen or {}) do
        if hitman.hitman_cid == cid then return hitman.anon ~= true end
    end
    return false
end

--- Pages of the log read at most for one page of a search by citizen id
--- without IdentityAce, which keeps only the rows actedOpenly allows.
local OPEN_SEARCH_READS = 10


--- The audit log, newest first, a page at a time (Storage.queryAudit). By
--- a citizen id: every row they acted in for staff with IdentityAce, which
--- includes the ones they acted in anonymously; for staff without it, only
--- the rows they acted in openly (actedOpenly), each scrubbed as ever.
H.logs = function(src, data)
    if data.area ~= nil and data.area ~= 'audit' then
        local area = type(data.area) == 'string' and LOG_AREAS[data.area] or nil
        if not area then return false, CH.ERR.INVALID_INPUT, L('panel.there_is_no_such_log') end
        return area(src, data)
    end
    local canIdentify = identifies(src)
    local filter = {
        kind = VALID_KIND[data.kind] and data.kind or nil,
        action = shortText(data.action, 48),
        contract = data.contract ~= nil and Util.toId(data.contract) or nil,
        from = wholeNumber(data.from, 0),
        to = wholeNumber(data.to, 0),
    }
    if data.contract ~= nil and not filter.contract then
        return false, CH.ERR.INVALID_INPUT, L('panel.that_is_not_a_contract_id')
    end
    if data.actor ~= nil then
        filter.actor = typedCitizenId(data.actor)
        if not filter.actor then return false, CH.ERR.INVALID_INPUT, L('panel.that_is_not_a_citizen_id') end
    end
    local openly = filter.actor ~= nil and not canIdentify
    local limit = math.min(LOG_ROWS_MAX, wholeNumber(data.limit, 1, LOG_ROWS_MAX) or pageSize())
    local cursor = wholeNumber(data.cursor, 0)

    -- The queue first, so the newest rows are there to read.
    deps.audit.flush()
    local parties = partiesReader()
    local rows, next_
    if openly then
        -- Only the rows they acted in openly, read on until a page's worth
        -- and one more, or the log ends (a few pages at most, then the
        -- search stops there). Never the store's cursor (openPages).
        local key = table.concat({ tostring(filter.kind), tostring(filter.action),
            tostring(filter.contract), tostring(filter.from), tostring(filter.to), filter.actor }, '|')
        local now = Util.monotonicMs()
        for holder, pages in pairs(openPages) do
            for handle, page in pairs(pages) do
                if now - page.at >= OPEN_PAGE_MS then pages[handle] = nil end
            end
            if next(pages) == nil then openPages[holder] = nil end
        end
        local kept, raw, done = {}, nil, false
        if data.cursor ~= nil then
            local page = cursor and openPages[src] and openPages[src][cursor] or nil
            if not page or page.key ~= key then
                return false, CH.ERR.INVALID_INPUT, L('panel.that_page_of_the_search_has')
            end
            for i = 1, #page.rows do kept[i] = page.rows[i] end
            raw, done = page.raw, page.done
        end
        local reads = 0
        while #kept <= limit and not done and reads < OPEN_SEARCH_READS do
            local got
            got, raw = deps.storage.queryAudit(filter, raw, limit)
            reads = reads + 1
            done = raw == nil
            for _, row in ipairs(got or {}) do
                -- Every one a page read holds, so a page is never cut
                -- part-way and its rest skipped by the cursor.
                if actedOpenly(row, filter.actor, parties) then kept[#kept + 1] = row end
            end
        end
        rows = {}
        for i = 1, math.min(limit, #kept) do rows[i] = kept[i] end
        if #kept > limit then
            local mine = openPages[src]
            if not mine then
                mine = {}
                openPages[src] = mine
            end
            local count, oldest, oldestAt = 0, nil, math.huge
            for handle, page in pairs(mine) do
                count = count + 1
                if page.at < oldestAt then oldest, oldestAt = handle, page.at end
            end
            if count >= OPEN_PAGES_PER_STAFF and oldest then mine[oldest] = nil end
            openPageSeq = openPageSeq + 1
            next_ = openPageSeq * 1000 + math.random(0, 999)
            local rest = {}
            for i = limit + 1, #kept do rest[#rest + 1] = kept[i] end
            mine[next_] = { key = key, raw = raw, done = done, rows = rest, at = now }
        end
    else
        rows, next_ = deps.storage.queryAudit(filter, cursor, limit)
    end
    local out = {}
    for _, row in ipairs(rows or {}) do
        local contract, hitmen = parties(row.contract_id)
        out[#out + 1] = rowView(row, redactor(canIdentify, contract, hitmen))
    end
    if canIdentify then
        deps.audit.staff('admin_panel_logs_identified', staffOf(src), filter.contract,
            { actor = filter.actor, rows = #out })
    elseif openly then
        deps.audit.staff('admin_panel_logs_player', staffOf(src), filter.contract,
            { actor = filter.actor, rows = #out })
    end
    return true, nil, nil, { rows = out, next = next_ }
end

--- The party a contract names by its role, for Look up / Freeze in the
--- contract view: 'contract:<id>:client', 'contract:<id>:target' or
--- 'contract:<id>:op:<operative row id>'. Resolved here, so the citizen id
--- never has to reach a staff member without IdentityAce; and refused for a
--- party who is anonymous on it to one without it, whom the view does not
--- name either.
---@return table|nil who { cid, actor, viaContract = true }
---@return string|nil err
---@return string|nil message
local function contractParty(subject, canIdentify)
    local id, role, rest = subject:match('^contract:([%w_%-]+):(%a+):?(.*)$')
    id = id and Util.toId(id)
    if not id then return nil, CH.ERR.INVALID_INPUT, L('panel.that_is_not_a_party_to') end
    local contract = deps.storage.readContract(id)
    if not contract then return nil, CH.ERR.NOT_FOUND, L('panel.no_contract_has_that_id') end
    local cid
    if role == 'target' then
        cid = contract.target_cid
    elseif role == 'client' then
        if contract.anon_creator == true and not canIdentify then
            return nil, CH.ERR.NOT_PARTICIPANT, L('panel.the_placer_placed_it_anonymously_only')
        end
        cid = contract.creator_cid
    elseif role == 'op' and rest ~= '' then
        for _, hitman in ipairs(deps.storage.readHitmen(id) or {}) do
            if tostring(hitman.id) == rest then
                if hitman.anon == true and not canIdentify then
                    return nil, CH.ERR.NOT_PARTICIPANT, L('panel.that_operative_took_it_anonymously_only')
                end
                cid = hitman.hitman_cid
                break
            end
        end
    end
    if not cid then return nil, CH.ERR.NOT_FOUND, L('panel.nobody_on_that_contract_matches') end
    return { cid = cid, actor = deps.identity.byCitizenId(cid), viaContract = true }
end

--- A lookup by name, as Contracts searches: anybody in the city whose name
--- holds it, and failing that a target, or a client who placed openly (any
--- client, with IdentityAce), whose name on a contract is exactly it. One
--- person, or nil and what to say.
---@return table|nil who { cid, actor, byName = true }
---@return string|nil err
---@return string|nil message
local function byName(text, canIdentify)
    -- A name has letters in it; anything else is not one.
    if not text:find('%a') then
        return nil, CH.ERR.INVALID_INPUT, L('panel.give_a_player_id_a_citizen')
    end
    local needle = text:lower()
    local order, seen = {}, {}
    local function add(cid, actor)
        if cid and not seen[cid] then
            seen[cid] = actor or false
            order[#order + 1] = cid
        end
    end
    for _, actor in ipairs(deps.identity.online() or {}) do
        if type(actor.name) == 'string' and actor.name:lower():find(needle, 1, true) then
            add(actor.cid, actor)
        end
    end
    if #order == 0 then
        for _, contract in ipairs(everyContract()) do
            if tostring(contract.target_name or ''):lower() == needle then add(contract.target_cid) end
            if (canIdentify or contract.anon_creator ~= true)
                and tostring(contract.creator_name or ''):lower() == needle then
                add(contract.creator_cid)
            end
        end
    end
    if #order == 0 then
        return nil, CH.ERR.NOT_FOUND, L('panel.nobody_by_that_name_is_in')
    end
    if #order > 1 then
        return nil, CH.ERR.INVALID_INPUT, L('panel.people_match_that_name_give_more'):format(#order)
    end
    local cid = order[1]
    return { cid = cid, actor = seen[cid] or deps.identity.byCitizenId(cid), byName = true }
end

--- Who a lookup names: a player id (somebody in the city), a citizen id
--- typed (anybody), a name (as Contracts takes one), or a party to a
--- contract by its role (contractParty). nil, the error and what to say,
--- for none of them.
---@param subject any
---@param src integer|nil the staff member asking, for what they may be shown
---@return table|nil who { cid, actor, typed }
---@return string|nil err
---@return string|nil message
local function playerSubject(subject, src)
    local serverId = (type(subject) == 'number' or (type(subject) == 'string'
        and subject:match('^%d+$') and #subject <= 6)) and wholeNumber(subject, 1, 65535) or nil
    if serverId then
        local actor = deps.identity.resolve(serverId)
        if not actor then
            return nil, CH.ERR.NOT_FOUND, L('panel.nobody_with_that_player_id_is')
        end
        return { cid = actor.cid, actor = actor }
    end
    if type(subject) ~= 'string' then
        return nil, CH.ERR.INVALID_INPUT, L('panel.give_a_player_id_a_citizen')
    end
    local canIdentify = src ~= nil and identifies(src)
    if subject:sub(1, 9) == 'contract:' then return contractParty(subject:sub(1, 96), canIdentify) end
    local text = shortText(subject, 64)
    if not text then return nil, CH.ERR.INVALID_INPUT, L('panel.give_a_player_id_a_citizen') end
    local cid = typedCitizenId(text)
    if cid then
        local actor = deps.identity.byCitizenId(cid)
        -- A word that names no character and nothing here is read as a name.
        if actor or deps.identity.characterExists(cid) ~= false
            or #(deps.storage.contractsInvolving(cid) or {}) > 0 then
            return { cid = cid, actor = actor, typed = true }
        end
        local named, namedErr, namedSays = byName(text, canIdentify)
        if named then return named end
        -- Several people by that name: said, not read as an id.
        if namedErr == CH.ERR.INVALID_INPUT then return nil, namedErr, namedSays end
        -- Text with a digit in it reads as a citizen id typed; a word with
        -- none is a name nobody has.
        if not text:find('%d') then return nil, namedErr, namedSays end
        return { cid = cid, actor = nil, typed = true }
    end
    return byName(text, canIdentify)
end

--- What a write says when its lookup handle is not this staff member's,
--- has run out, or never was.
local STALE_LOOKUP = L('panel.that_lookup_is_out_of_date')

--- A handle for the character a lookup found, for this staff member only.
--- None for a staff member with no character: a handle names who it was
--- given to, and nobody would match any other nobody.
---@param src integer
---@param who table playerSubject's answer
---@return string|nil ref
local function playerRef(src, who)
    local staff = staffOf(src)
    if not staff then return nil end
    local now = Util.monotonicMs()
    -- Every staff member's handles that have run out, not only these: one
    -- who never looks anybody up again would otherwise keep theirs.
    for holder, refs in pairs(playerRefs) do
        for ref, entry in pairs(refs) do
            if now - entry.at >= PLAYER_REF_MS then refs[ref] = nil end
        end
        if next(refs) == nil then playerRefs[holder] = nil end
    end
    local mine = playerRefs[src]
    if not mine then
        mine = {}
        playerRefs[src] = mine
    end
    local count, oldest, oldestAt = 0, nil, math.huge
    for ref, entry in pairs(mine) do
        if now - entry.at >= PLAYER_REF_MS then
            mine[ref] = nil
        else
            count = count + 1
            if entry.at < oldestAt then oldest, oldestAt = ref, entry.at end
        end
    end
    if count >= PLAYER_REFS_PER_STAFF and oldest then mine[oldest] = nil end
    playerRefSeq = playerRefSeq + 1
    local ref = ('p%d_%d'):format(playerRefSeq, math.random(100000, 999999))
    mine[ref] = { cid = who.cid, staff = staff, at = now, typed = who.typed or nil,
                  viaContract = who.viaContract or nil }
    return ref
end

--- Test seam: how many lookup handles each staff source holds now.
---@return table [src] = count
function Panel._heldRefs()
    local out = {}
    for holder, refs in pairs(playerRefs) do
        local n = 0
        for _ in pairs(refs) do n = n + 1 end
        out[holder] = n
    end
    return out
end

--- Forget a source's lookup handles when it leaves: the next player given
--- that server id is not who they were minted for.
---@param src integer
function Panel.forgetSource(src)
    playerRefs[src] = nil
    openPages[src] = nil
end

--- The character a lookup handle stands for, or nil and what to say.
---@return table|nil who { cid, actor, typed, viaContract }
---@return string|nil err
---@return string|nil message
local function fromPlayerRef(src, ref)
    local mine = type(ref) == 'string' and playerRefs[src] or nil
    local key = mine and ref:sub(1, 24) or nil
    local entry = key and mine[key] or nil
    if not entry or Util.monotonicMs() - entry.at >= PLAYER_REF_MS or not entry.staff
        or entry.staff ~= staffOf(src) then
        if entry then mine[key] = nil end
        return nil, 'stale_lookup', STALE_LOOKUP
    end
    return { cid = entry.cid, actor = deps.identity.byCitizenId(entry.cid), typed = entry.typed,
             viaContract = entry.viaContract }
end

--- The one list of contracts, searched and filtered, a page at a time: the
--- panel's All contracts, a player's contracts and the live contracts on
--- someone (Target limits) are this list with a filter.
---
--- `query` is a contract id (or part of one), a citizen id, or part of a
--- name. A citizen id finds every contract it is party to through the
--- store's own index, and a name the client's or the target's: but a
--- party who paid to stay anonymous is matched only for staff with
--- IdentityAce, or a search would be a way round whois.
---
--- The person filter: `ref` (the handle a player lookup gave) or `person`
--- (a player id, citizen id or name, as Players' lookup takes) keeps the
--- contracts that person is party to, each with their `role` on it
--- (target, client, hitman), narrowed by `as` to one role. A party they
--- were anonymously is left out for staff without IdentityAce, with
--- nothing to say anything was.
---
--- `byTarget`: the live contracts (open, taken, settling, on hold) grouped
--- by target, the query matching the target only; each row says its
--- group (the target's citizen id only with IdentityAce, else a number
--- telling one from the next) and how many are live on them.
H.contracts = function(src, data)
    local Storage = deps.storage
    local canIdentify = identifies(src)
    local query = shortText(data.query, 64)
    local state = VALID_STATE[data.state] and data.state or nil
    -- 'live': every contract still running (active, accepted, completing),
    -- the list's default.
    local live = data.state == 'live'
    local rule = (data.rule == CH.FULFILMENT_RULE.ALIVE or data.rule == CH.FULFILMENT_RULE.EITHER)
        and data.rule or nil
    local from = wholeNumber(data.from, 0)
    local to = wholeNumber(data.to, 0)
    local page = wholeNumber(data.page, 1, 100000) or 1
    local byTarget = data.byTarget == true
    local as = (data.as == 'target' or data.as == 'client' or data.as == 'hitman') and data.as or nil

    -- The person, from the lookup's handle or as typed; their part on each
    -- contract they may be shown on.
    local personCid, roleOn = nil, nil
    if data.ref ~= nil or data.person ~= nil then
        local who, err, message
        if data.ref ~= nil then
            who, err, message = fromPlayerRef(src, data.ref)
        else
            who, err, message = playerSubject(data.person, src)
        end
        if not who then return false, err, message end
        personCid = who.cid
        roleOn = {}
        local hitmen = deps.admin and deps.admin.operativeRows and deps.admin.operativeRows(personCid) or nil
        for _, contract in ipairs(Storage.contractsInvolving(personCid) or {}) do
            local role, anonymous
            if contract.target_cid == personCid then
                role, anonymous = 'target', false
            elseif contract.creator_cid == personCid then
                role, anonymous = 'client', contract.anon_creator == true
            else
                local row
                if hitmen then row = hitmen[contract.id] else row = Storage.readHitman(contract.id, personCid) end
                role, anonymous = 'hitman', row ~= nil and row.anon == true
            end
            if canIdentify or not anonymous then
                roleOn[contract.id] = { role = role, anonymous = anonymous }
            end
        end
    end

    -- One read of the store's index, in the form the server keeps the id:
    -- upper case, as qbx_core's are, unless a player in the city holds it as
    -- typed. typedCitizenId decides that with a read of its own, and this
    -- read again after it: every search typed in lower case, a name among
    -- them, walked every contract and every operative twice on json.
    local viaCid = {}
    local cid = query and not byTarget and Util.toCitizenId(query)
    if cid and cid:upper() ~= cid then
        local online = deps.identity.byCitizenId(cid)
        if not (online and online.cid == cid) then cid = cid:upper() end
    end
    if cid then
        -- Their operative rows in one read (Admin.operativeRows), where one
        -- per contract in their history was an await each on mysql.
        local rows = deps.admin and deps.admin.operativeRows and deps.admin.operativeRows(cid) or nil
        for _, contract in ipairs(Storage.contractsInvolving(cid) or {}) do
            local visible
            if contract.target_cid == cid then
                visible = true
            elseif contract.creator_cid == cid then
                visible = canIdentify or contract.anon_creator ~= true
            else
                local hitman
                if rows then hitman = rows[contract.id] else hitman = Storage.readHitman(contract.id, cid) end
                visible = canIdentify or not (hitman and hitman.anon == true)
            end
            if visible then viaCid[contract.id] = true end
        end
    end

    local lowered = query and query:lower()
    local matched = {}
    for _, contract in ipairs(byTarget and (Storage.unfinishedContracts() or {}) or everyContract()) do
        local hit = not lowered
        if lowered and not hit then
            if byTarget then
                hit = contract.target_cid == query
                    or tostring(contract.target_name or ''):lower():find(lowered, 1, true) ~= nil
            else
                hit = viaCid[contract.id]
                    or tostring(contract.id):lower():find(lowered, 1, true) ~= nil
                    or tostring(contract.target_name or ''):lower():find(lowered, 1, true) ~= nil
                    or ((canIdentify or contract.anon_creator ~= true)
                        and tostring(contract.creator_name or ''):lower():find(lowered, 1, true) ~= nil)
            end
        end
        if hit and roleOn then
            local part = roleOn[contract.id]
            hit = part ~= nil and (not as or part.role == as)
        end
        if hit and state and contract.state ~= state then hit = false end
        if hit and live and CH.TERMINAL[contract.state] then hit = false end
        if hit and rule and Util.fulfilmentRule(contract) ~= rule then hit = false end
        if hit and from and (tonumber(contract.created_at) or 0) < from then hit = false end
        if hit and to and (tonumber(contract.created_at) or 0) > to then hit = false end
        if hit then matched[#matched + 1] = contract end
    end
    -- Newest first (everyContract); by target, each target's together.
    local perTarget, targets = {}, 0
    if byTarget then
        table.sort(matched, function(a, b)
            local ta, tb = tostring(a.target_name or ''):lower(), tostring(b.target_name or ''):lower()
            if ta ~= tb then return ta < tb end
            if a.target_cid ~= b.target_cid then return tostring(a.target_cid) < tostring(b.target_cid) end
            return newestFirst(a, b)
        end)
        for _, c in ipairs(matched) do
            local key = tostring(c.target_cid)
            if not perTarget[key] then targets = targets + 1 end
            perTarget[key] = (perTarget[key] or 0) + 1
        end
    end

    local size = pageSize()
    local pages = math.max(1, math.ceil(#matched / size))
    if page > pages then page = pages end
    -- The page's live rows' rosters in one read, for the On hold badge, and
    -- only while anybody is frozen (frozenShown reads nothing otherwise).
    local rosters = {}
    if deps.holds and (deps.holds.count() or 0) > 0 and Storage.readHitmenMany then
        local ids = {}
        for i = (page - 1) * size + 1, math.min(#matched, page * size) do
            local contract = matched[i]
            if contract.state == CH.STATE.ACTIVE or contract.state == CH.STATE.ACCEPTED then
                ids[#ids + 1] = contract.id
            end
        end
        if #ids > 0 then
            local read, many = pcall(Storage.readHitmenMany, ids)
            if read and type(many) == 'table' then rosters = many end
        end
    end
    local rows, alias, seq = {}, {}, 0
    for i = (page - 1) * size + 1, math.min(#matched, page * size) do
        local contract = matched[i]
        local part = roleOn and roleOn[contract.id] or nil
        local group
        if byTarget then
            group = tostring(contract.target_cid)
            if not canIdentify then
                if not alias[group] then
                    seq = seq + 1
                    alias[group] = 't' .. seq
                end
                group = alias[group]
            end
        end
        rows[#rows + 1] = {
            id = contract.id, state = contract.state, mode = contract.mode,
            rule = Util.fulfilmentRule(contract), created_at = contract.created_at,
            deadline_at = contract.deadline_at, resolved_at = contract.resolved_at,
            resolution = contract.resolution, target = contract.target_name,
            client = (contract.anon_creator == true and not canIdentify) and L('panel.anonymous')
                or contract.creator_name,
            anonymous = contract.anon_creator == true,
            slots = contract.payout_slots, claimed = contract.slots_claimed,
            frozen = frozenShown(contract, rosters[contract.id], canIdentify) ~= nil or nil,
            role = part and part.role or nil, roleAnonymous = part and part.anonymous or nil,
            group = group, onTarget = group and perTarget[tostring(contract.target_cid)] or nil,
        }
    end

    -- A search by a person is a lookup, and every lookup is on the record.
    if personCid then
        deps.audit.staff(canIdentify and 'admin_contracts_identified' or 'admin_contracts',
            staffOf(src), nil, { subject = personCid, rows = #matched })
    end
    if query and byTarget then
        deps.audit.staff('admin_panel_target_contracts', staffOf(src), nil, { query = query, rows = #matched })
    elseif query then
        deps.audit.staff(canIdentify and 'admin_panel_search_identified' or 'admin_panel_search',
            staffOf(src), nil, { query = query, rows = #matched })
    end
    return true, nil, nil, { rows = rows, page = page, pages = pages, total = #matched,
                             targets = byTarget and targets or nil }
end

--- Who a write names: the handle of the lookup staff made (data.ref), a
--- citizen id typed exactly, or a party to a contract by its role (fixed by
--- the contract). Never a name or a player id matched again now: those can
--- name somebody else by the time of the click.
---@return table|nil who { cid, actor, typed }
---@return string|nil err
---@return string|nil message
local function writeSubject(data, src)
    if data.ref ~= nil then return fromPlayerRef(src, data.ref) end
    local subject = data.subject
    if type(subject) == 'string' and subject:sub(1, 9) == 'contract:' then
        return contractParty(subject:sub(1, 96), src ~= nil and identifies(src))
    end
    local text = type(subject) == 'string' and shortText(subject, 64) or nil
    local cid = text and not text:match('^%d+$') and typedCitizenId(text) or nil
    if not cid then
        return nil, CH.ERR.INVALID_INPUT, L('panel.look_the_player_up_first_then')
    end
    return { cid = cid, actor = deps.identity.byCitizenId(cid), typed = true }
end

--- For a module's ops (Panel.extend): who a write names, and a lookup
--- handle for a character it lists, as the panel's own ops use them.
Panel.writeSubject = function(data, src) return writeSubject(data, src) end
Panel.refFor = function(src, cid) return playerRef(src, { cid = cid }) end
Panel.staffOf = function(src) return staffOf(src) end
--- The staff member a module's write is made by: { cid, name, source }.
---@param src integer
---@return table
Panel.staffActor = function(src)
    local actor = deps.identity.resolve(src)
    return { cid = actor and actor.cid or staffOf(src), name = actor and actor.name or nil, source = src }
end
Panel.identifies = function(src) return identifies(src) end

--- A character's playtime as the panel shows it: what the built-in tracker
--- counted (Playtime.view), the floor, and what the rule reads for them
--- (Identity.playtimeHours: an export, QBox metadata, or the tracker).
local function playtimeView(cid, actor)
    if not deps.playtime then return nil end
    local view = deps.playtime.view(cid)
    local _, from = deps.identity.playtimeHours(actor or { cid = cid })
    view.from = from
    view.floor = tonumber(Config.Immunity.MinTargetPlaytimeHours) or 0
    return view
end

--- Whether a player is frozen, as the panel shows it, or nil.
freezeView = function(cid, canIdentify) return Measures.view('freeze', cid, canIdentify) end

--- One player: their contracts as /ch-contracts lists them, their record,
--- what they are owed, and the notices kept for their next login.
---
--- To staff who may not see who is behind an anonymous party, nothing here
--- counts what the player did anonymously, as /ch-contracts leaves those
--- contracts out. A line owed, a delivery pending and a notice kept are each
--- left out when they are on a contract the player was an anonymous party
--- to. The record is counters kept for the life of the character
--- (Record.of), anonymous contracts in them and nothing to say
--- which: one placed more than the list shows was one placed anonymously,
--- and with one anonymous contract on the board that named its client. It
--- is shown only with IdentityAce.
---
--- A citizen id nobody in the city has and nothing shown names answers
--- not found: answered with an empty profile, a mistyped one read as a
--- player with nothing on record.
H.player = function(src, data)
    local Storage = deps.storage
    local canIdentify = identifies(src)
    -- Read again after a write, by the handle the lookup gave: the same
    -- character, whatever the box says now.
    local who, whoErr, whoMessage
    if data.ref ~= nil then
        who, whoErr, whoMessage = fromPlayerRef(src, data.ref)
    else
        who, whoErr, whoMessage = playerSubject(data.subject, src)
    end
    if not who then return false, whoErr, whoMessage end
    local cid, actor, typedCid = who.cid, who.actor, who.typed

    local contracts = deps.admin.contractsOf(src, cid) or {}

    -- Whether something of theirs is on a contract they were an anonymous
    -- party to, which this staff member may not be shown.
    local parties = partiesReader()
    local function hiddenOn(contractId)
        if canIdentify then return false end
        local contract, hitmen = parties(contractId)
        if contract and contract.anon_creator == true and contract.creator_cid == cid then return true end
        for _, hitman in ipairs(hitmen or {}) do
            if hitman.hitman_cid == cid and hitman.anon == true then return true end
        end
        return false
    end

    local owed, queues = {}, {}
    for _, line in ipairs(Storage.owedHeldEscrow and Storage.owedHeldEscrow() or {}) do
        if line.owed_to == cid and not hiddenOn(line.contract_id) then
            local contract, hitmen = parties(line.contract_id)
            local view = lineView(line, redactor(canIdentify, contract, hitmen))
            view.queued = deps.escrow.queued(line, queues)
            owed[#owed + 1] = view
        end
    end
    local pending = 0
    for _, entry in ipairs(Storage.readPending(cid) or {}) do
        if not hiddenOn(entry.contract_id) then pending = pending + 1 end
    end
    local notices, titles = 0, {}
    if deps.notify and deps.notify.waitingFor then
        notices, titles = deps.notify.waitingFor(cid, hiddenOn)
    end
    local stats = canIdentify and deps.record.of(cid) or nil

    -- Which of the contracts shown are on hold, by the same rule the list
    -- of contracts follows.
    if deps.holds and (deps.holds.count() > 0 or select(2, deps.holds.count())) then
        -- Their rosters in one read, not one each (and two, in frozenShown).
        local ids = {}
        for _, row in ipairs(contracts) do ids[#ids + 1] = row.id end
        local rosters = {}
        if #ids > 0 and Storage.readHitmenMany then
            local read, many = pcall(Storage.readHitmenMany, ids)
            if read and type(many) == 'table' then rosters = many end
        end
        for _, row in ipairs(contracts) do
            local contract = Storage.readContract(row.id)
            row.frozen = contract and frozenShown(contract, rosters[row.id], canIdentify) ~= nil or nil
        end
    end

    -- A name for somebody offline, from a contract that names them openly.
    local name = actor and actor.name or nil
    if not name then
        for _, contract in ipairs(Storage.contractsInvolving(cid) or {}) do
            if contract.target_cid == cid then
                name = contract.target_name
            elseif contract.creator_cid == cid and contract.anon_creator ~= true then
                name = contract.creator_name
            end
            if name then break end
        end
    end

    deps.audit.staff(canIdentify and 'admin_panel_player_identified' or 'admin_panel_player',
        staffOf(src), nil, { subject = cid, typed = typedCid or nil })

    local recorded = stats and ((stats.placed or 0) + (stats.completed or 0) + (stats.failed or 0)
        + (stats.survived or 0)) > 0
    if typedCid and not actor and not name and #contracts == 0 and #owed == 0 and pending == 0
        and notices == 0 and not recorded then
        return false, CH.ERR.NOT_FOUND, L('panel.nobody_in_the_city_has_that')
    end

    return true, nil, nil, {
        player = {
            cid = (canIdentify or typedCid) and cid or nil, name = name,
            online = actor ~= nil, server = actor and actor.source or nil,
            -- What every write from this card names them by (writeSubject).
            ref = playerRef(src, who),
        },
        contracts = contracts,
        stats = stats,
        owed = owed, pending = pending,
        notices = { count = notices, titles = titles },
        -- Hours counted here and whether they are grandfathered: nothing
        -- about any contract, so shown to every reader of the panel.
        playtime = playtimeView(cid, actor),
        -- Whether staff have put them on hold (server/holds.lua). Who did,
        -- a staff member's citizen id, only with IdentityAce.
        frozen = freezeView(cid, canIdentify),
        -- Whether staff have suspended them from contracts, or protect them
        -- from contracts (server/sanctions.lua), the same way.
        suspended = Measures.view('suspend', cid, canIdentify),
        protected = Measures.view('protect', cid, canIdentify),
        -- And whether they have target limits of their own (server/targetlimits.lua).
        limit = Measures.view('limit', cid, canIdentify),
        -- The most one manual payment may be now (Config.Staff), for Pay.
        payMax = deps.payments and deps.payments.max() or 0,
    }
end

--- Freezing and releasing a player (server/holds.lua), from Players.
--- Writes, needing the ACE itself, as void and settle do; each is audited
--- by the freeze itself (freeze_player, unfreeze_player). Not IdentityAce:
--- staff name the player as they looked them up, and nothing here says
--- which contracts are theirs.

--- Every measure on a player in force, newest first: Players, Measures.
--- Each row carries the list's handle ('f'), so Unfreeze or Lift on a row
--- names the player by it; the citizen id and who set it only with
--- IdentityAce. { kind } filters to one kind.
H.measures = function(src, data)
    local kind = data.kind
    if kind ~= nil and not Measures.known(kind) then
        return false, CH.ERR.INVALID_INPUT, L('panel.no_such_measure')
    end
    return true, nil, nil, { rows = Measures.list(kind, identifies(src)), kinds = Measures.KINDS }
end

--- The player a lift names: a row of the measures list ('f' handles), or
--- as every other write (writeSubject).
local function listedSubject(data, src)
    local listed, cid = Measures.fromRef(data.ref)
    if listed then
        if not cid then return nil, CH.ERR.NOT_FOUND, L('panel.that_row_is_gone_refresh_the') end
        return { cid = cid, actor = deps.identity.byCitizenId(cid) }
    end
    return writeSubject(data, src)
end

H.freeze = function(src, data)
    if not deps.holds then return false, 'unavailable', L('panel.freezing_is_not_available_on_this') end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local cid, actor = who.cid, who.actor
    if not actor and deps.identity.characterExists(cid) == false
        and #(deps.storage.contractsInvolving(cid) or {}) == 0 then
        return false, CH.ERR.NOT_FOUND, L('panel.nobody_in_the_city_has_that_2')
    end
    -- Stored with the freeze, and so shown in Measures to every reader:
    -- the character's name, never the citizen id typed for one away (a
    -- reader without the identity ACE is never shown a citizen id). The
    -- reply, to the staff member who typed it, may say it back.
    local stored = actor and actor.name or nil
    local name = stored or (who.typed and cid) or nil
    local staffCid = staffOf(src)
    local ok, err = Measures.apply('freeze', staffCid, cid, { reason = reason, name = stored })
    if not ok then
        if err == 'already_frozen' then return false, err, L('panel.they_are_already_frozen') end
        if err == CH.ERR.BUSY then
            return false, err, L('panel.a_freeze_or_release_of_them')
        end
        return false, err, L('panel.not_frozen_the_store_did_not')
    end
    return true, nil, (L('panel.is_frozen_every_live_contract_they'))
        :format(name or L('panel.they')), { frozen = freezeView(cid, identifies(src)) }
end

H.unfreeze = function(src, data)
    if not deps.holds then return false, 'unavailable', L('panel.freezing_is_not_available_on_this') end
    -- A row of the measures list ('f' handles), or the player looked up.
    local who, whoErr, whoMessage = listedSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Measures.lift('freeze', staffOf(src), who.cid, shortText(data.reason, 120))
    if not ok then
        if err == 'not_frozen' then return false, err, L('panel.they_are_not_frozen') end
        if err == CH.ERR.BUSY then
            return false, err, L('panel.a_freeze_or_release_of_them')
        end
        return false, err, L('panel.not_unfrozen_the_store_did_not')
    end
    return true, nil, L('panel.unfrozen_their_contracts_run_again_with')
end

--- Set or reset one character's counted playtime (Players, under the
--- lookup). A write: the ACE itself, the write allowance, and a row in the
--- log with what it was and what it is now. Not IdentityAce: staff name the
--- player as they looked them up, and nothing here says who they are.
H.setPlaytime = function(src, data)
    if not deps.playtime then
        return false, 'unavailable', L('panel.playtime_is_not_counted_on_this')
    end
    local hours = tonumber(data.hours)
    if not hours or hours ~= hours or hours < 0 or hours > 100000 then
        return false, CH.ERR.INVALID_INPUT, L('panel.hours_are_a_number_from_0')
    end
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local cid, actor = who.cid, who.actor
    -- A citizen id typed that no character has: refused, not a row made for
    -- somebody who does not exist.
    if not actor and deps.identity.characterExists(cid) == false
        and not deps.playtime.view(cid).counted then
        return false, CH.ERR.NOT_FOUND, L('panel.nobody_in_the_city_has_that_2')
    end
    -- To a tenth of an hour, as the panel shows hours, so what it says it
    -- set is what it set.
    local tenths = math.floor(hours * 10 + 0.5)
    local seconds = tenths * 360
    local set, before, written = pcall(deps.playtime.set, cid, seconds)
    if not set then
        Log.debug(('the admin panel could not read %s\'s counted playtime: %s')
            :format(cid, Util.dbError(before)))
        local unanswered = deps.storage.timedOut and deps.storage.timedOut(before)
        return false, unanswered and CH.ERR.DB_TIMEOUT or CH.ERR.SERVER_ERROR,
            L('panel.not_changed_their_counted_time_could')
    end
    local after = tenths / 10
    deps.audit.staff('admin_playtime_set', staffOf(src), nil,
        { subject = cid, hours = after, before = before, reset = seconds == 0 or nil })

    local view = playtimeView(cid, actor)
    local name = actor and actor.name or (who.typed and cid) or L('panel.this_character')
    local parts = {
        seconds == 0 and L('panel.ss_counted_playtime_is_reset_to'):format(name, Words.hours(before, true))
            or L('panel.ss_counted_playtime_is_now_it'):format(name, Words.hours(after, true), Words.hours(before, true)),
    }
    -- Grandfathered counts only where the tracker is what the rule reads
    -- (Identity.playtimeHours): an export or QBox metadata answering for
    -- them decides by its own hours, as /ch-diag says.
    local tracked = view and (view.from == nil or view.from == 'tracker')
    if tracked and view.grandfathered then
        parts[#parts + 1] = L('panel.they_are_grandfathered_from_before_the')
    end
    if view and view.from == 'provider' then
        parts[#parts + 1] = L('panel.the_playtime_rule_reads_your_playtime')
    elseif view and view.from == 'metadata' then
        parts[#parts + 1] = L('panel.the_playtime_rule_reads_their_qbox')
    end
    if not written then
        parts[#parts + 1] = L('panel.the_store_did_not_take_it')
    end
    return true, nil, table.concat(parts, ' '), { playtime = view }
end

H.whois = function(src, data)
    local who, err = deps.admin.identify(src, data.id)
    if not who then
        return false, err, err == CH.ERR.NOT_FOUND and L('panel.no_contract_has_that_id') or L('panel.give_a_contract_id')
    end
    return true, nil, nil, who
end

--- Whether a settings row or key is in the Developer section.
local function developerKey(key)
    if type(key) ~= 'string' then return false end
    if deps.settings.DENY and deps.settings.DENY[key] then return true end
    local entry = deps.settings.entry(key)
    return entry ~= nil and entry.category == 'developer'
end

--- Whether this request is a change to one setting of the Developer section
--- by name (setSetting, resetSetting) from somebody who may open it: what
--- Config.Admin.DeveloperAce writes without Config.Admin.Ace. Never a key
--- on the deny list, which nobody writes from the panel, and nothing else.
local function developerWrite(src, op, data)
    if op ~= 'setSetting' and op ~= 'resetSetting' then return false end
    local key = type(data) == 'table' and data.key or nil
    if type(key) ~= 'string' or (deps.settings.DENY and deps.settings.DENY[key]) then return false end
    local entry = deps.settings.entry(key)
    return entry ~= nil and entry.category == 'developer' and developer(src)
end

--- The parts of a Features or Limits row that come from the catalogue and
--- the shipped and start-up defaults, fixed until the settings are set up
--- again (Settings.schemaVersion). Sent once: the reply was 172 KB, nearly
--- all of it these, rebuilt and sent whole at every open of the section and
--- after every change. The value, where it comes from, who set it and
--- whether it applies, and the most it may be, are sent every time.
local SCHEMA_FIELDS = { 'group', 'label', 'about', 'category', 'money', 'area', 'shipped', 'hasShipped',
    'kind', 'choices', 'min', 'integer', 'live', 'inflight', 'readonly', 'destroys', 'stricter',
    'strict', 'whole', 'default', 'maxLength', 'says' }

--- [developer or not] = { owner, version, hash }
local schemaHashes = {}

--- The fixed parts of the rows this staff member is shown, as one short
--- hash: worked out once per version of them, and again only when the
--- settings are set up again.
local function schemaHash(view, developerToo)
    local settings = deps.settings
    local version = settings.schemaVersion and settings.schemaVersion() or nil
    local slot = developerToo and 'developer' or 'other'
    local kept = schemaHashes[slot]
    if kept and version ~= nil and kept.owner == settings and kept.version == version then
        return kept.hash
    end
    local fixed = {}
    for _, list in ipairs({ 'features', 'limits' }) do
        local rows = {}
        for i, row in ipairs(view[list] or {}) do
            local parts = { key = row.key }
            for _, field in ipairs(SCHEMA_FIELDS) do parts[field] = row[field] end
            rows[i] = parts
        end
        fixed[list] = rows
    end
    local hash = deps.projection.digest(fixed)
    schemaHashes[slot] = { owner = settings, version = version, hash = hash }
    return hash
end

H.settings = function(src, data)
    local view = deps.settings.view()
    -- The Developer section's settings only for staff who may open it.
    if not developer(src) then
        for _, list in ipairs({ 'features', 'limits', 'readonly' }) do
            local kept = {}
            for _, row in ipairs(view[list] or {}) do
                if row.category ~= 'developer' then kept[#kept + 1] = row end
            end
            view[list] = kept
        end
        view.developerHidden = true
    end
    -- The fixed parts once (SCHEMA_FIELDS): a page that already holds the
    -- ones this hash names is sent each row's key and what changes.
    local hash = schemaHash(view, view.developerHidden ~= true)
    view.schema = hash
    if type(data) == 'table' and data.schema == hash then
        view.lean = true
        for _, list in ipairs({ 'features', 'limits' }) do
            for _, row in ipairs(view[list] or {}) do
                for _, field in ipairs(SCHEMA_FIELDS) do row[field] = nil end
            end
        end
    end
    -- The kill photos kept from before they were turned off, for the button
    -- under Completion that removes them: only while they are off and some
    -- are kept. A store that cannot say leaves the button out.
    local ok, kept = pcall(deps.photos.keptFromBefore)
    if ok then
        view.keptPhotos = kept
    else
        Log.debug(('the admin panel could not count the kill photos kept from before: %s')
            :format(Util.dbError(kept)))
    end
    return true, nil, nil, view
end

--- What a refused setting says. `why` from the settings names the key
--- once, without the start's own correction, and says which other key to
--- change first where one is in the way (Settings.check).
local function settingRefusal(key, err, why)
    if err == 'not_allowed' then return L('panel.not_a_setting_the_panel_may') end
    if err == 'read_only' then return L('panel.not_changed'):format(tostring(why)) end
    if err == 'not_overridden' then return L('panel.is_what_config_lua_says_already'):format(key) end
    if err == 'changed_since' then
        return L('panel.not_changed_was_changed_since_you'):format(key,
            deps.settings.describe(type(why) == 'table' and why.value or nil))
    end
    if err == CH.ERR.BUSY then
        return L('panel.not_changed_another_change_to_the')
    end
    if err == 'store_failed' then
        return L('panel.not_changed_the_store_would_not'):format(tostring(why))
    end
    if err == 'store_unknown' then
        return L('panel.not_sure_it_was_kept_the'):format(tostring(why))
    end
    return L('panel.not_changed_2'):format(tostring(why))
end

--- The start's warnings about a value, said with the change: they refuse
--- nothing, and were said nowhere, not at the next start either.
local function warned(detail)
    local lines = type(detail) == 'table' and detail.warnings or nil
    if type(lines) ~= 'table' or #lines == 0 then return '' end
    return (L('panel.note_warnings')):format(table.concat(lines, '. '))
end

H.setSetting = function(src, data)
    local key = type(data.key) == 'string' and #data.key <= 64 and data.key or nil
    if not key then return false, CH.ERR.INVALID_INPUT, L('panel.name_a_setting') end
    local cid, who = staffOf(src)
    -- The value the page made the change from (what it read): a save over a
    -- change another staff member made since is refused, not written over it.
    local ok, err, detail = deps.settings.set(key, data.value, who, cid, data.basis)
    if not ok then return false, err, settingRefusal(key, err, detail), err == 'changed_since' and detail or nil end
    if detail.unchanged then
        return true, nil, (L('panel.is_already_nothing_changed'))
            :format(key, deps.settings.describe(detail.value), warned(detail)), detail
    end
    local entry = deps.settings.entry(key)
    return true, nil, L('panel.is_now'):format(key, deps.settings.describe(detail.value),
        detail.source == 'config' and L('panel.what_config_lua_says')
            or ((entry and entry.live == false) and L('panel.applies_after_restart') or ''),
        warned(detail)), detail
end

H.resetSetting = function(src, data)
    local key = type(data.key) == 'string' and #data.key <= 64 and data.key or nil
    if not key then return false, CH.ERR.INVALID_INPUT, L('panel.name_a_setting') end
    local cid, who = staffOf(src)
    local ok, err, detail = deps.settings.reset(key, who, cid)
    if not ok then return false, err, settingRefusal(key, err, detail) end
    if detail.removed then
        return true, nil, L('panel.is_out_of_the_store_nothing'):format(key), detail
    end
    return true, nil, (L('panel.is_back_to_what_config_lua'))
        :format(key, deps.settings.describe(detail.value)), detail
end

--- Every preset, each with the changes it would make now and what the
--- server would refuse: nothing changes by reading them.
--- Who saved an own preset is their citizen id with IdentityAce, and 'a
--- staff member' without it, as Change history says it; the Developer
--- section's keys (and the deny list) only for staff who may open it,
--- counted as `hidden` otherwise.
H.presets = function(src)
    if not deps.presets then return false, 'unavailable', L('panel.presets_are_not_running_on_this') end
    local list = deps.presets.list()
    local canIdentify, isDeveloper = identifies(src), developer(src)
    for _, preset in ipairs(list) do
        if preset.own and not canIdentify then
            preset.by = L('panel.a_staff_member')
            preset.about = L('presets.saved_by_the_settings_changed_from'):format(preset.by)
        end
        if not isDeveloper then
            local hidden = 0
            for _, field in ipairs({ 'changes', 'refused' }) do
                local kept = {}
                for _, row in ipairs(preset[field] or {}) do
                    if developerKey(row.key) then hidden = hidden + 1 else kept[#kept + 1] = row end
                end
                preset[field] = kept
            end
            preset.hidden = hidden > 0 and hidden or nil
        end
    end
    return true, nil, nil, { presets = list }
end

--- Apply one preset by name (two clicks on the page, naming how many
--- changes). Each change is a setting change of its own: audited, in
--- Change history with its Undo; Current is saved first.
H.presetApply = function(src, data)
    if not deps.presets then return false, 'unavailable', L('panel.presets_are_not_running_on_this') end
    local name = shortText(data.name, 32)
    if not name then return false, CH.ERR.INVALID_INPUT, L('panel.name_a_preset') end
    local cid, who = staffOf(src)
    local ok, err, detail = deps.presets.apply(name, who, cid)
    if not ok then return false, err, detail end
    local refused = #detail.refused
    return true, nil, L('panel.applied_setting_changed_each_is_in'):format(name, #detail.applied, #detail.applied == 1 and '' or 's',
        refused > 0 and L('panel.left_as_they_were_the_preview'):format(refused) or ''), detail
end

--- The first-start setup screen: storage, the other scripts, the ACE lines,
--- the panel command and the key switches, each at the value in force.
H.setup = function(src)
    if not deps.setup then return false, 'unavailable', L('panel.the_setup_is_not_running_on') end
    local view = deps.setup.view(permissionsFor(src))
    -- Who saved it, as Change history names them.
    if type(view) == 'table' and view.savedBy ~= nil and not identifies(src) then
        view.savedBy = L('panel.a_staff_member')
    end
    return true, nil, nil, view
end

--- The values the setup page chose, as a table of at most 64 keys, or nil.
local function setupValues(data)
    local values = type(data) == 'table' and data.values
    if type(values) ~= 'table' then return nil end
    local out, n = {}, 0
    for key, value in pairs(values) do
        n = n + 1
        if n > 64 or type(key) ~= 'string' or #key > 96 then return nil end
        local kind = type(value)
        if kind ~= 'string' and kind ~= 'boolean' and kind ~= 'number' then return nil end
        out[key] = kind == 'string' and value:sub(1, 64) or value
    end
    return out
end

--- What applying the setup's values would change: nothing changes here.
H.setupPreview = function(_, data)
    if not deps.setup then return false, 'unavailable', L('panel.the_setup_is_not_running_on') end
    local values = setupValues(data)
    if not values then return false, CH.ERR.INVALID_INPUT, L('panel.the_setup_sent_something_it_should') end
    local preview = deps.setup.preview(values)
    for _, change in ipairs(preview.changes) do change.value = nil end
    return true, nil, nil, preview
end

--- Apply the setup (two clicks on the page): each change a setting change
--- of its own, audited and in Change history with its Undo, and the setup
--- saved as done.
H.setupApply = function(src, data)
    if not deps.setup then return false, 'unavailable', L('panel.the_setup_is_not_running_on') end
    local values = setupValues(data)
    if not values then return false, CH.ERR.INVALID_INPUT, L('panel.the_setup_sent_something_it_should') end
    local cid, who = staffOf(src)
    local ok, err, detail = deps.setup.apply(values, who, cid)
    if not ok then return false, err, detail end
    local refused = #detail.refused
    return true, nil, L('panel.setup_saved_setting_changed_each_is'):format(#detail.applied, #detail.applied == 1 and '' or 's',
        refused > 0 and L('panel.left_as_they_were_the_preview'):format(refused) or ''), detail
end

--- Keep the settings presets name, as they are now, as Current.
H.presetSave = function(src)
    if not deps.presets then return false, 'unavailable', L('panel.presets_are_not_running_on_this') end
    local cid, who = staffOf(src)
    local ok, err = deps.presets.saveCurrent(who)
    if not ok then return false, err, L('panel.the_store_did_not_take_it_2') end
    deps.audit.staff('admin_preset_saved', cid, nil, { preset = 'Current', by = who })
    return true, nil, L('panel.saved_current_holds_the_settings_the')
end

--- Save the settings changed from the panel now as a preset of the
--- server's own, under a name (two clicks on the page).
H.presetSaveOwn = function(src, data)
    if not deps.presets then return false, 'unavailable', L('panel.presets_are_not_running_on_this') end
    local cid, who = staffOf(src)
    local name = type(data.name) == 'string' and data.name:sub(1, 64) or nil
    local ok, err, message = deps.presets.saveOwn(name, who, cid)
    return ok, err, message
end

--- Delete a preset of the server's own (two clicks on the page).
H.presetDelete = function(src, data)
    if not deps.presets then return false, 'unavailable', L('panel.presets_are_not_running_on_this') end
    local cid, who = staffOf(src)
    local name = type(data.name) == 'string' and data.name:sub(1, 64) or nil
    local ok, err, message = deps.presets.deleteOwn(name, who, cid)
    return ok, err, message
end

--- Every setting changed from the panel and the server's own presets, as
--- one JSON text (Developer > Export and import).
H.settingsExport = function()
    if not deps.settingsio then return false, 'unavailable', L('panel.export_and_import_are_not_running') end
    return true, nil, nil, deps.settingsio.export()
end

--- What an exported text would change now: nothing changes.
H.settingsImport = function(src, data)
    if not deps.settingsio then return false, 'unavailable', L('panel.export_and_import_are_not_running') end
    -- Remembered for whoever is shown it, so their apply holds to it
    -- (SettingsIO.apply).
    local _, who = staffOf(src)
    local preview, why = deps.settingsio.preview(data.text, who)
    if not preview then return false, CH.ERR.INVALID_INPUT, why end
    preview.values = nil
    return true, nil, nil, preview
end

--- Apply an exported text (two clicks on the page, naming how many changes):
--- each change through Settings.set, then its presets. The Developer
--- section's, so its ACE as well as the staff one.
H.settingsImportApply = function(src, data)
    if not deps.settingsio then return false, 'unavailable', L('panel.export_and_import_are_not_running') end
    if not developer(src) then
        return false, 'developer_required', deps.admin.howToAuthorise(developerAce(), true)
    end
    local cid, who = staffOf(src)
    local ok, err, message, detail = deps.settingsio.apply(data.text, data.expect, who, cid)
    return ok, err, message, detail
end

H.resetSettings = function(src)
    local cid, who = staffOf(src)
    local ok, err, detail = deps.settings.resetAll(who, cid)
    if not ok then return false, err, settingRefusal(L('panel.every_setting'), err, detail) end
    return true, nil, (L('panel.every_setting_is_back_to_what'))
        :format(detail.keys), detail
end

H.refresh = function(src)
    local lines, waiting = deps.admin.refreshTimers(src)
    -- Refused before this is reached (WAITS_FOR_RECOVERY), and by the
    -- refresh itself as well, in the same words.
    if waiting then return false, waiting, lines[1] end
    return true, nil, table.concat(lines, ' '), { lines = lines }
end

H.diag = function(src, data)
    -- Health's Check the config (server/configcheck.lua): every value out of
    -- range, script missing, ACE not held and risky combination, with the
    -- fix. Names nobody, so nothing to scrub.
    if data.config == true then
        if not deps.configcheck then return false, 'unavailable', L('panel.the_config_check_is_not_running') end
        return true, nil, nil, { lines = deps.configcheck.lines(), config = true }
    end
    local subject = data.subject ~= nil and wholeNumber(data.subject, 1, 65535) or nil
    if data.subject ~= nil and not subject then
        return false, CH.ERR.INVALID_INPUT, L('panel.give_a_player_id_or_nothing')
    end
    -- Or the player Players looked up (their lookup handle), so staff need
    -- not type the id again: run as them while they are in the city.
    if data.ref ~= nil and data.subject == nil then
        local who, whoErr, whoMessage = fromPlayerRef(src, data.ref)
        if not who then return false, whoErr, whoMessage end
        if not who.actor then
            return false, CH.ERR.NOT_FOUND, L('panel.they_are_not_in_the_city')
        end
        subject = who.actor.source
    end
    -- The one check that waits for an answer (whether the public photo
    -- address leads here) says what it found after the report, pushed to
    -- the open panel; and so does the subject's own page log, a list. Each
    -- push names the lookup handle it was asked for (`ref`), so the page
    -- draws it under that player and nobody else, and a run from Health
    -- (no handle) apart from either.
    --
    -- And scrubbed as every other view is for staff without IdentityAce
    -- (Panel.scrubText): the report's identity line names the subject's
    -- citizen id, which a Players lookup hides from them.
    local canIdentify = identifies(src)
    local function shown(line)
        line = tostring(line or '')
        if canIdentify then return line end
        return Panel.scrubText(line, false) or ''
    end
    local ref = data.subject == nil and type(data.ref) == 'string' and data.ref or nil
    local lines = deps.admin.diagnose(src, subject, function(said)
        local list = type(said) == 'table' and said or { said }
        for i = 1, #list do
            Panel.push(src, { kind = 'diag', line = shown(deps.admin.panelWords(list[i])), ref = ref })
        end
    end, { panel = true })
    local out = {}
    for i, line in ipairs(lines or {}) do out[i] = shown(line) end
    return true, nil, nil, { lines = out, ref = ref }
end

--------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------

--- Alerts open or acknowledged, newest first, at most ALERT_ROWS, with how
--- many of each there are, and where posting to Discord stands (whether a
--- webhook is set, never its address). The text scrubbed for staff without
--- IdentityAce as every other view is (Panel.scrubText), and with each staff
--- command's name put as the panel's own place for it. Who acknowledged one
--- is a staff member's citizen id, shown only with IdentityAce, as the Logs
--- view shows whoever acted.
H.alerts = function(src, data)
    local Alerts = deps.alerts
    if not Alerts then return false, 'unavailable', L('panel.alerts_are_not_running_on_this') end
    local canIdentify = identifies(src)
    local state = data.state == 'acknowledged' and 'acknowledged' or 'open'
    local list, counts = Alerts.list(state, ALERT_ROWS)
    local parties = partiesReader()
    local rows = {}
    for _, a in ipairs(list) do
        rows[#rows + 1] = {
            id = a.id, level = a.level, contract = a.contract_id, count = a.count,
            first_at = a.first_at, last_at = a.last_at,
            text = deps.admin.panelWords(Panel.scrubText(a.text, canIdentify, a.contract_id, false,
                parties)),
            acknowledged_by = canIdentify and a.acknowledged_by
                or (a.acknowledged_by ~= nil and L('panel.a_staff_member') or nil),
            acknowledged_at = a.acknowledged_at,
        }
    end
    return true, nil, nil, {
        state = state, rows = rows, open = counts.open, acknowledged = counts.acknowledged,
        limit = ALERT_ROWS, discord = Alerts.discordState(),
    }
end

--- Acknowledge alerts: one, or every one the page shows (at most
--- ALERT_ROWS). A write: the ACE itself, the write allowance, and a row in
--- the log naming how many and which.
H.ackAlerts = function(src, data)
    local Alerts = deps.alerts
    if not Alerts then return false, 'unavailable', L('panel.alerts_are_not_running_on_this') end
    local ids, seen = {}, {}
    if type(data.ids) == 'table' then
        for i = 1, ALERT_ROWS do
            local id = Util.toId(data.ids[i])
            if data.ids[i] == nil then break end
            if id and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    if #ids == 0 then return false, CH.ERR.INVALID_INPUT, L('panel.name_the_alerts_to_acknowledge') end
    local cid, who = staffOf(src)
    local done, already, missing = Alerts.acknowledge(ids, who)
    if done > 0 then
        local named = {}
        for i = 1, math.min(#ids, 20) do named[i] = ids[i] end
        deps.audit.staff('admin_alerts_acknowledged', cid, nil,
            { count = done, already = already > 0 and already or nil, ids = named })
    end
    local message
    if done == 0 then
        message = missing > 0 and already == 0 and L('panel.those_alerts_are_gone_pruned_since')
            or L('panel.those_alerts_were_acknowledged_already_nothing')
        return true, nil, message, { done = 0, already = already, missing = missing }
    end
    message = L('panel.acknowledged_alert'):format(done)
    if already > 0 then message = message .. L('panel.were_acknowledged_already'):format(already) end
    return true, nil, message, { done = done, already = already, missing = missing }
end

--- Put a test alert in the next post to Discord. A write, on the record,
--- whether it went or not.
H.testAlert = function(src)
    local Alerts = deps.alerts
    if not Alerts then return false, 'unavailable', L('panel.alerts_are_not_running_on_this') end
    local queued, err, seconds = Alerts.sendTest()
    deps.audit.staff('admin_alert_test', staffOf(src), nil, { queued = queued, why = err })
    if err == 'discord_off' then
        return false, err, L('panel.not_sent_posting_alerts_to_discord')
    end
    if err == 'no_webhook' then
        return false, err, L('panel.not_sent_no_webhook_is_set')
    end
    return true, nil, L('panel.a_test_alert_goes_to_discord'):format(math.max(0, seconds or 0)), { seconds = seconds }
end

--------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------

--- What shared/log.lua keeps (Log.view): the settings that need attention
--- found at start, what the last start said, and the newest lines since,
--- each with its kind ('always', 'problem' or 'debug'), when it was last
--- said and how many times. Every line without a secret in it
--- (Panel.withoutSecrets), and scrubbed for staff without IdentityAce as the
--- Alerts are (Panel.scrubText), with each staff command's name put as the
--- panel's own place for it.
H.console = function(src)
    local kept = Log.view()
    local canIdentify = identifies(src)
    local parties = partiesReader()
    local function shown(text)
        text = Panel.withoutSecrets(text)
        return deps.admin.panelWords(Panel.scrubText(text, canIdentify, contractIn(text), false,
            parties))
    end
    local problems, boot, recent = {}, {}, {}
    for i, text in ipairs(kept.problems) do problems[i] = shown(text) end
    for i, text in ipairs(kept.boot) do
        boot[i] = { text = shown(text), kind = kept.bootKinds[i] or 'debug' }
    end
    for i, entry in ipairs(kept.recent) do
        recent[i] = { text = shown(entry.text), kind = entry.kind, at = entry.at, times = entry.times }
    end
    return true, nil, nil, {
        at = os.time(), debug = kept.debug, count = kept.count, problems = problems,
        boot = boot, bootLeft = kept.bootLeft or 0, recent = recent,
        bootKept = Log.BOOT_KEPT, recentKept = Log.KEPT, alwaysKept = Log.KEPT_ALWAYS,
    }
end

--------------------------------------------------------------------------
-- Kill photos kept from before
--------------------------------------------------------------------------

--- What a removal of the kill photos kept from before says it did.
local function removedWords(done)
    if done.removed == 0 and done.waiting == 0 then
        return L('panel.no_kill_photos_are_kept_from')
    end
    local parts = {}
    if done.removed > 0 then
        parts[#parts + 1] = L('panel.removed_kill_photo'):format(done.removed)
    else
        parts[#parts + 1] = L('panel.nothing_removed_yet')
    end
    if done.files > 0 then
        parts[#parts + 1] = L('panel.file_deleted_from_this_server'):format(done.files)
    end
    if done.links > 0 then
        parts[#parts + 1] = L('panel.were_on_lb_phones_image_host'):format(done.links)
    end
    if done.left > 0 then
        parts[#parts + 1] = L('panel.file_could_not_be_deleted_delete'):format(done.left)
    end
    if done.waiting > 0 then
        parts[#parts + 1] = L('panel.open_on_a_phone_right_now'):format(done.waiting)
    end
    return table.concat(parts, ' ')
end

--- Remove every kill photo kept from before kill photos were turned off
--- (Features, under Completion). A write: the ACE itself, the write
--- allowance, and a row in the log with how many, whatever it removed.
--- Refused while kill photos are on, when they are not photos kept from
--- before. Run again, it removes what is left, or nothing.
H.removePhotos = function(src)
    if Util.killPhotos() then
        return false, 'photos_on', L('panel.not_removed_kill_photos_are_on')
    end
    local done = deps.photos.removeAll()
    deps.audit.staff('admin_photos_removed', staffOf(src), nil, {
        count = done.removed, files = done.files, links = done.links,
        left = done.left > 0 and done.left or nil, waiting = done.waiting > 0 and done.waiting or nil,
    })
    return true, nil, removedWords(done), done
end

--- What the store answered, not only whether it raised: the json store's
--- flush answers false, with the file it could not write, and never raises,
--- so "the store did not save" could never be said and staff pressing this
--- before a restart were told the rows were on disk when nothing was.
H.flush = function(src)
    local written = deps.audit.flush() or 0
    local stored, file = true, nil
    if deps.storage.flush then
        local ran, saved, failed = pcall(deps.storage.flush)
        stored = ran and saved ~= false
        file = ran and type(failed) == 'string' and failed or nil
    end
    deps.audit.staff('admin_log_flushed', staffOf(src), nil, { rows = written })
    deps.audit.flush()
    local unsaved = ''
    if not stored then
        unsaved = L('panel.but_the_store_did_not_save')
            .. (file and (': ' .. file .. L('panel.could_not_be_written')) or '')
    end
    return true, nil, (L('panel.audit_log_flushed_row_written'))
        :format(written, unsaved), { written = written }
end

--------------------------------------------------------------------------
-- Staff tools on one contract (server/staffcontract.lua)
--------------------------------------------------------------------------

--- Who a staff member is, for the records they leave on a contract.
local function staffRecordOf(src)
    local actor = deps.identity.resolve(src)
    return { cid = actor and actor.cid or nil, name = actor and actor.name or nil, source = src }
end

--- How the author of a staff record on a contract is shown: their name and
--- citizen id with IdentityAce, and 'Staff' without, as a freeze's `by` is.
local function authorShown(row, canIdentify)
    if not canIdentify then return L('panel.staff') end
    if row.author_name and row.author_cid then return ('%s (%s)'):format(row.author_name, row.author_cid) end
    return tostring(row.author_name or row.author_cid or L('panel.staff'))
end

--- The staff records on one contract, as one staff member may read them:
--- its notes, the operatives taken off it, the edits to its text, and what
--- its text may be replaced with. Each text scrubbed as the timeline is.
---@param contract table
---@param r table a redactor
---@return table|nil
function Panel.staffPart(contract, r)
    local SC = deps.staffContract
    if not SC then return nil end
    local notes, removals, edits = {}, {}, {}
    for _, row in ipairs(SC.records(contract.id)) do
        local shown = { id = row.id, at = row.created_at, by = authorShown(row, r.canIdentify) }
        if row.kind == 'note' then
            shown.text = r.value(nil, tostring(row.body or ''))
            notes[#notes + 1] = shown
        elseif row.kind == 'removal' then
            shown.who = r.who(row.subject_cid)
            shown.reason = r.value(nil, tostring(row.body or ''))
            shown.stakeReturned = row.stake_returned == true
            shown.blocked = row.blocked == true
            removals[#removals + 1] = shown
        elseif row.kind == 'edit' then
            shown.field = row.field
            shown.reason = r.value(nil, tostring(row.body or ''))
            edits[#edits + 1] = shown
        end
    end
    local mode = Config.Reason.Mode
    return {
        notes = notes, removals = removals, edits = edits, noteMax = (SC.noteLimits()),
        removable = not CH.TERMINAL[contract.state] and contract.state ~= CH.STATE.COMPLETING,
        text = {
            editable = mode == 'freetext' or mode == 'preset', mode = mode,
            max = tonumber(Config.Reason.MaxLength) or 0,
            presets = mode == 'preset' and Config.Reason.Presets or nil,
            edited = SC.edited(contract.id) == true,
        },
    }
end

--- A private note on a contract, kept with its author and time; shown in
--- the contract's view and nowhere a player reads.
H.addNote = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    if type(data.text) ~= 'string' then return false, CH.ERR.INVALID_INPUT, L('panel.write_the_note') end
    local ok, err, detail = deps.staffContract.addNote(staffRecordOf(src), id, data.text:sub(1, 4000))
    if not ok then
        if err == 'empty' then return false, CH.ERR.INVALID_INPUT, L('panel.write_the_note') end
        if err == 'too_long' then
            return false, CH.ERR.INVALID_INPUT, (L('panel.a_note_is_at_most_characters'))
                :format(detail.max)
        end
        if err == 'too_many' then
            return false, err, (L('panel.this_contract_holds_notes_already_the'))
                :format(detail.max)
        end
        if err == CH.ERR.NOT_FOUND then return false, err, L('panel.no_contract_has_that_id') end
        return false, err, L('panel.not_added_the_store_did_not')
    end
    return true, nil, L('panel.note_added'), { id = detail.id }
end

--- What a refusal of a player's text says, by the rule it broke.
local function textRefusal(rule)
    if rule == 'length' then
        return L('panel.at_most_characters_config_reason_maxlength'):format(tonumber(Config.Reason.MaxLength) or 0)
    end
    if rule == 'digits' then
        return L('panel.at_most_digits_config_reason_maxdigits'):format(tonumber(Config.Reason.MaxDigits) or 0)
    end
    if rule == 'pattern' then
        return L('panel.it_holds_something_players_may_not')
    end
    if rule == 'phone' then return L('panel.lb_phones_word_blacklist_refuses_something') end
    if rule == 'preset' then
        return L('panel.this_server_uses_preset_reasons_config')
    end
    return L('panel.type_the_new_text')
end

--- Replace what a player wrote on a contract (its reason) through the same
--- checks a player's text gets, with a reason for the edit. The original
--- stays in the log (staff_text_edit); players see the new text marked
--- 'edited by staff'.
H.editText = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    local field = data.field == nil and 'reason' or data.field
    if type(field) ~= 'string' or not deps.staffContract.FIELDS[field] then
        return false, CH.ERR.INVALID_INPUT, L('panel.only_a_contracts_reason_is_text')
    end
    if type(data.text) ~= 'string' then return false, CH.ERR.INVALID_INPUT, L('panel.type_the_new_text') end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    local ok, err, detail = deps.staffContract.editText(staffRecordOf(src), id, field,
        data.text:sub(1, 4000), reason)
    if not ok then
        if err == CH.ERR.REASON_REFUSED then
            return false, err, L('panel.not_replaced') .. textRefusal(type(detail) == 'table' and detail.rule or nil)
        end
        if err == CH.ERR.NOT_FOUND then return false, err, L('panel.no_contract_has_that_id') end
        if err == 'unchanged' then return false, err, L('panel.that_is_what_it_says_already') end
        if err == 'no_text' then
            return false, err, L('panel.this_server_keeps_no_reason_on')
        end
        if err == CH.ERR.BUSY then
            return false, err, L('panel.something_else_was_changing_this_contract')
        end
        return false, err, L('panel.not_replaced_the_store_did_not')
    end
    return true, nil, L('panel.reason_replaced_players_see_the_new'), { new = detail.new }
end

--- Take one operative off a live contract without ending it for anybody
--- else, with a reason; optionally barred from taking it again, and their
--- stake given back instead of handed to the client as a walk-away hands it.
H.removeHitman = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    local hitman = Util.toId(data.hitman)
    if not hitman then return false, CH.ERR.INVALID_INPUT, L('panel.pick_the_operative_to_remove') end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    local ok, err, detail = deps.staffContract.removeHitman(staffRecordOf(src), id, hitman, reason,
        { block = data.block == true, returnStake = data.returnStake == true })
    if not ok then
        if err == CH.ERR.NOT_FOUND then return false, err, L('panel.no_contract_has_that_id') end
        if err == CH.ERR.BAD_STATE then
            return false, err, L('panel.only_a_live_contract_active_or_2')
        end
        if err == CH.ERR.CONTRACT_FROZEN then
            -- Said as on hold only where this staff member's view of it says
            -- so (frozenShown): held through an anonymous party they may not
            -- see, the refusal says no more than the view does.
            local contract = deps.storage.readContract(id)
            if not contract or not frozenShown(contract, nil, identifies(src)) then
                return false, 'not_removed', L('panel.not_removed_try_again_in_a')
            end
            return false, err, L('panel.it_is_on_hold_by_staff')
        end
        if err == 'no_operative' then return false, err, L('panel.no_operative_on_this_contract_has') end
        if err == 'not_active' or err == CH.ERR.NOT_PARTICIPANT then
            return false, err, L('panel.that_operative_is_no_longer_on')
        end
        if err == CH.ERR.ALREADY_SETTLED then return false, err, L('panel.it_ended_meanwhile') end
        return false, err, L('panel.not_removed_try_again_in_a')
    end
    local stake = ''
    if (detail.returned or 0) > 0 then
        stake = L('panel.their_stake_went_back_to_them'):format(detail.returned)
    elseif (detail.forfeited or 0) > 0 then
        stake = L('panel.their_stake_went_to_the_placer'):format(detail.forfeited)
    end
    return true, nil, L('panel.taken_off_the_contract_they_were'):format(tostring(detail.alias or L('panel.the_operative')), stake,
            detail.blocked and L('panel.they_may_not_take_it_again') or '', deps.staffContract.REMOVED_TEXT),
        { stake = detail.stake or 0, returned = detail.returned or 0, forfeited = detail.forfeited or 0,
          blocked = detail.blocked == true, remaining = detail.remaining or 0 }
end

--- A time as an export writes it.
local function stamp(ts)
    ts = tonumber(ts)
    if not ts then return '-' end
    return os.date('!%Y-%m-%d %H:%M:%S', math.floor(ts)) .. ' UTC'
end

--- Any value from the view as one line of plain text.
local function flat(value, depth)
    depth = depth or 0
    if type(value) ~= 'table' then return tostring(value) end
    if depth > 3 then return '{...}' end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = (type(k) == 'number' and '' or (tostring(k) .. '=')) .. flat(value[k], depth + 1)
    end
    if depth == 0 then return table.concat(parts, ', ') end
    return '{' .. table.concat(parts, ', ') .. '}'
end

local function holdsText(line)
    if line.amount ~= nil then
        return ('$%d %s'):format(math.floor(tonumber(line.amount) or 0), tostring(line.source or ''))
    end
    return ('%s x%d'):format(tostring(line.item or line.source or '?'), math.floor(tonumber(line.quantity) or 1))
end

--- A contract's view (H.contract) as plain text for a ticket: its terms, its
--- operatives, its payments, its open proposals, the staff notes and the
--- whole timeline. Built from the view itself, so it is scrubbed exactly as
--- the view is for staff without IdentityAce.
local function exportText(view)
    local c = view.contract or {}
    local out = {}
    local function add(line) out[#out + 1] = line end
    local function person(p)
        p = p or {}
        return tostring(p.name or '-') .. (p.cid and (' [' .. p.cid .. ']') or '')
    end
    local staff = view.staff or {}
    add(L('panel.contract'):format(tostring(c.id)))
    add(L('panel.export_exported'):format(stamp(os.time())))
    if c.neverStored then
        add(L('panel.never_stored_escrow_under_this_id'))
    else
        add(L('panel.state_mode_completes_by'):format(tostring(c.state), tostring(c.mode),
            tostring(c.rule)))
        add(L('panel.export_reason'):format(tostring(c.reason or '-'),
            (staff.text and staff.text.edited) and L('panel.edited_by_staff') or ''))
        add(L('panel.export_client'):format(person(c.client),
            c.anonymous and L('panel.export_anonymous') or ''))
        add(L('panel.export_target'):format(person(c.target),
            c.target_protected and L('panel.whitelisted_job') or ''))
        add((L('panel.export_placed_deadline_expires')):format(stamp(c.created_at), stamp(c.deadline_at),
            stamp(c.expires_at)))
        add(L('panel.export_ended'):format(c.resolved_at
            and (tostring(c.resolution or '') .. ' ' .. stamp(c.resolved_at)) or L('panel.not_yet')))
        add(L('panel.payouts_of_claimed_bonus_stake_buyout'):format(
            tostring(c.claimed or 0), tostring(c.slots or 1), tostring(c.bonus_percent or 0),
            tostring(c.penalty_amount or 0), tostring(c.bailout_amount or 0),
            c.buyout_queued and L('panel.a_buyout_is_queued') or ''))
    end
    add('')
    add(L('panel.export_operatives'))
    if #(view.hitmen or {}) == 0 then add(L('panel.export_none')) end
    for _, m in ipairs(view.hitmen or {}) do
        add(L('panel.accepted_left_claims_stake'):format(
            tostring(m.alias or '-'), tostring(m.name or '-'), m.cid and (' [' .. m.cid .. ']') or '',
            tostring(m.state), stamp(m.accepted_at), stamp(m.left_at), tostring(m.claims or 0),
            tostring(m.stake or 0)))
    end
    add('')
    add(L('panel.payments_escrow_lines'))
    if #(view.escrow or {}) == 0 then add(L('panel.export_none')) end
    for _, line in ipairs(view.escrow or {}) do
        local to = line.owed_to or line.releasing_to or line.settled_to
        add(L('panel.payout'):format(tostring(line.id), tostring(line.slot or '-'),
            tostring(line.portion or '-'), holdsText(line), tostring(line.state),
            to and (L('panel.export_to')):format(tostring(to)) or '',
            line.settled_at and (L('panel.export_settled')):format(stamp(line.settled_at)) or ''))
    end
    add('')
    add(L('panel.open_proposals'))
    if #(view.amendments or {}) == 0 then add(L('panel.export_none')) end
    for _, a in ipairs(view.amendments or {}) do
        add(L('panel.by_runs_out'):format(tostring(a.kind), tostring(a.proposer or '-'),
            stamp(a.expires_at), flat(a.payload or {})))
    end
    add('')
    add(L('panel.staff_notes'))
    if #(staff.notes or {}) == 0 then add(L('panel.export_none')) end
    for _, note in ipairs(staff.notes or {}) do
        add(('- %s | %s | %s'):format(stamp(note.at), tostring(note.by), tostring(note.text)))
    end
    add('')
    add(L('panel.timeline_oldest_first_states_amendments_payments'))
    if #(view.timeline or {}) == 0 then add(L('panel.the_log_keeps_nothing_for_it')) end
    for _, row in ipairs(view.timeline or {}) do
        add(('- %s | %s | %s | %s | %s'):format(stamp(row.ts), tostring(row.kind), tostring(row.action),
            tostring(row.actor or '-'), flat(row.detail or {})))
    end
    return table.concat(out, '\n')
end

--- One contract's whole record as plain text, for a ticket (Export on its
--- view): scrubbed exactly as the view is, being made from it.
H.exportContract = function(src, data)
    local ok, err, message, view = H.contract(src, data, true)
    if not ok then return ok, err, message end
    deps.audit.staff(identifies(src) and 'admin_panel_export_identified' or 'admin_panel_export',
        staffOf(src), Util.toId(data.id), {})
    return true, nil, nil, { text = exportText(view) }
end

local VIEW_ROLES = { target = true, placer = true, hitman = true }

--- The contract as one of its parties sees it on their phone: the real
--- projection for that viewer (Projection.contract, as On me, Mine and the
--- operative's card build it), read-only. Without IdentityAce, scrubbed as
--- the view is, so no anonymous party is named; with it, who the viewer is.
H.playerView = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_contract_id') end
    local role = type(data.role) == 'string' and data.role or nil
    if not role or not VIEW_ROLES[role] then
        return false, CH.ERR.INVALID_INPUT, L('panel.pick_whose_view_the_target_the')
    end
    local Storage = deps.storage
    local contract = Storage.readContract(id)
    if not contract then return false, CH.ERR.NOT_FOUND, L('panel.no_contract_has_that_id') end
    local hitmen = Storage.readHitmen(id) or {}
    local canIdentify = identifies(src)
    local r = redactor(canIdentify, contract, hitmen)

    local viewerCid, operative
    if role == 'target' then
        viewerCid = contract.target_cid
    elseif role == 'placer' then
        viewerCid = contract.creator_cid
    else
        local wanted = Util.toId(data.hitman)
        for _, row in ipairs(hitmen) do
            if row.id == wanted then operative = row end
        end
        if not operative then return false, CH.ERR.INVALID_INPUT, L('panel.pick_one_of_its_operatives') end
        viewerCid = operative.hitman_cid
    end

    local shown, note, view, whitelisted = true, nil, nil, nil
    if CH.TERMINAL[contract.state] then
        shown, note = false, L('panel.closed_it_is_off_their_phone')
    elseif role == 'target' and not deps.notify.shownToTarget(contract) then
        shown, note = false, L('panel.not_shown_to_the_target_yet')
    else
        view = deps.projection.contract(contract, viewerCid, { peek = true })
        if role == 'target' then
            -- As On me sends it: never the roster.
            if view then view.hitmen = nil end
            if contract.target_protected == true then
                whitelisted = deps.projection.whitelistedListing(contract, viewerCid, nil)
                note = L('panel.recorded_on_a_whitelisted_job_while')
            end
        elseif role == 'hitman' and operative.state ~= 'active' then
            note = (L('panel.no_longer_on_it_this_is'))
                :format(tostring(operative.state))
        end
    end
    if not canIdentify then
        view = view and r.value(nil, view) or nil
        whitelisted = whitelisted and r.value(nil, whitelisted) or nil
        -- On hold only where a party they may be shown is frozen, as the
        -- contract view's badge (frozenShown): the party's own card says
        -- On hold whoever is frozen, so a freeze of one suspect, then this
        -- view, said which anonymous contracts were theirs.
        if view and view.onHold and not frozenShown(contract, hitmen, false) then view.onHold = nil end
    end

    deps.audit.staff(canIdentify and 'admin_panel_player_view_identified' or 'admin_panel_player_view',
        staffOf(src), id, { role = role, alias = operative and operative.alias or nil })
    local viewerName
    if role == 'target' then viewerName = contract.target_name
    elseif role == 'placer' then viewerName = contract.creator_name
    else viewerName = operative.hitman_name end
    return true, nil, nil, {
        role = role, shown = shown, note = note, view = view, whitelisted = whitelisted,
        alias = operative and operative.alias or nil,
        viewer = canIdentify and { cid = viewerCid, name = viewerName } or nil,
    }
end

--------------------------------------------------------------------------
-- Suspensions, protections, the history card and manual payments
--------------------------------------------------------------------------

--- The player a staff action names, as the freeze takes one: the lookup's
--- handle or an exact citizen id (writeSubject), and refused for a citizen
--- id no character has and nothing here names. nil, the error and what to
--- say otherwise.
local function actionSubject(data, src)
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return nil, whoErr, whoMessage end
    if not who.actor and deps.identity.characterExists(who.cid) == false
        and #(deps.storage.contractsInvolving(who.cid) or {}) == 0 then
        return nil, CH.ERR.NOT_FOUND, L('panel.nobody_in_the_city_has_that_2')
    end
    -- `stored` goes with the measure or payment and is shown to every
    -- reader: the character's name, never a citizen id typed for one away.
    -- `name` is for the reply to the staff member who typed it.
    who.stored = who.actor and who.actor.name or nil
    who.name = who.stored or (who.typed and who.cid) or nil
    return who
end

--- The sentence a measure's answer is, for how long it runs: whole days
--- where it is whole days, otherwise hours, each its own whole sentence
--- with its plural (`base` .. '_days_one' and so on), so a translation
--- words the span with the rest of it. A span pieced into the sentence
--- ('for 1 day') was English inside a translated answer.
---@param base string the keys' common start
---@param name string who it is on
---@param seconds integer
---@return string
local function spanSentence(base, name, seconds)
    if seconds % 86400 == 0 then
        local days = seconds // 86400
        return (L(base .. (days == 1 and '_days_one' or '_days_many'))):format(name, days)
    end
    local hours = seconds // 3600
    return (L(base .. (hours == 1 and '_hours_one' or '_hours_many'))):format(name, hours)
end

--- What a refused suspension or protection says.
local function sanctionRefusal(err, already, missing)
    if err == 'already' then return false, err, already end
    if err == 'not_active' then return false, err, missing end
    if err == CH.ERR.BUSY then
        return false, err, L('panel.a_change_to_them_is_still')
    end
    if err == CH.ERR.INVALID_INPUT then return false, err, L('panel.the_server_could_not_read_that') end
    return false, err, L('panel.not_changed_the_store_did_not')
end

--- One player's history (server/history.lua): read-only, and scrubbed as
--- the player view is for staff without IdentityAce.
H.history = function(src, data)
    if not deps.history then return false, 'unavailable', L('panel.the_history_card_is_not_available') end
    local canIdentify = identifies(src)
    local who, whoErr, whoMessage
    if data.ref ~= nil then
        who, whoErr, whoMessage = fromPlayerRef(src, data.ref)
    else
        who, whoErr, whoMessage = playerSubject(data.subject, src)
    end
    if not who then return false, whoErr, whoMessage end
    -- The queue first, so the newest purchases are there to read.
    deps.audit.flush()
    local view = deps.history.build(deps, who.cid, canIdentify)
    deps.audit.staff(canIdentify and 'admin_panel_history_identified' or 'admin_panel_history',
        staffOf(src), nil, { subject = who.cid, typed = who.typed or nil })
    return true, nil, nil, view
end

--- Suspend a player from placing or accepting contracts: { subject, days
--- (0 until lifted), reason }. Their live contracts are not touched.
H.suspend = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', L('panel.suspensions_are_not_available_on_this') end
    local reason = shortText(data.reason, 120)
    if not reason then
        return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_the_player_is')
    end
    local days = wholeNumber(data.days, 0, Sanctions.MAX_SUSPEND_DAYS)
    if not days then
        return false, CH.ERR.INVALID_INPUT, L('panel.days_are_a_whole_number_from'):format(Sanctions.MAX_SUSPEND_DAYS)
    end
    local who, whoErr, whoMessage = actionSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Measures.apply('suspend', staffOf(src), who.cid,
        { seconds = days > 0 and days * 86400 or nil, reason = reason, name = who.stored })
    if not ok then
        return sanctionRefusal(err, L('panel.they_are_suspended_already_lift_it'))
    end
    local name = who.name or L('panel.they')
    return true, nil, days > 0 and spanSentence('panel.suspended', name, days * 86400)
            or (L('panel.suspended_until_lifted')):format(name),
        { suspended = Measures.view('suspend', who.cid, identifies(src)) }
end

H.unsuspend = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', L('panel.suspensions_are_not_available_on_this') end
    local who, whoErr, whoMessage = listedSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Measures.lift('suspend', staffOf(src), who.cid, shortText(data.reason, 120))
    if not ok then return sanctionRefusal(err, nil, L('panel.they_are_not_suspended')) end
    return true, nil, L('panel.suspension_lifted_they_may_place_and')
end

--- Protect a player from new contracts: { subject, hours (0 for good),
--- reason }. Contracts already on them are not touched.
H.protect = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', L('panel.protection_is_not_available_on_this') end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    local hours = wholeNumber(data.hours, 0, Sanctions.MAX_PROTECT_HOURS)
    if not hours then
        return false, CH.ERR.INVALID_INPUT, (L('panel.hours_are_a_whole_number_from'))
            :format(Sanctions.MAX_PROTECT_HOURS)
    end
    local who, whoErr, whoMessage = actionSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Measures.apply('protect', staffOf(src), who.cid,
        { seconds = hours > 0 and hours * 3600 or nil, reason = reason, name = who.stored })
    if not ok then
        return sanctionRefusal(err, L('panel.they_are_protected_already_lift_it'))
    end
    local name = who.name or L('panel.they')
    return true, nil, hours > 0 and spanSentence('panel.protected', name, hours * 3600)
            or (L('panel.protected_for_good')):format(name),
        { protected = Measures.view('protect', who.cid, identifies(src)) }
end

H.unprotect = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', L('panel.protection_is_not_available_on_this') end
    local who, whoErr, whoMessage = listedSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Measures.lift('protect', staffOf(src), who.cid, shortText(data.reason, 120))
    if not ok then return sanctionRefusal(err, nil, L('panel.they_are_not_protected')) end
    return true, nil, L('panel.protection_lifted_new_contracts_may_name')
end

--- Pay a player by hand: { subject, amount, account ('cash' | 'bank'),
--- reason }. At most Config.Staff.ManualPaymentMax; paid now, or owed at
--- their next login (server/payments.lua). Audited as staff_manual_payment.
H.manualPay = function(src, data)
    local Payments = deps.payments
    if not Payments then return false, 'unavailable', L('panel.manual_payments_are_not_available_on') end
    local max = Payments.max()
    if max <= 0 then
        return false, 'payments_off', L('panel.manual_payments_are_off_config_staff')
    end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    local account = (data.account == 'cash' or data.account == 'bank') and data.account or nil
    if not account then return false, CH.ERR.INVALID_INPUT, L('panel.pay_in_cash_or_bank') end
    local amount = wholeNumber(data.amount, 1)
    if not amount then return false, CH.ERR.INVALID_INPUT, L('panel.the_amount_is_a_whole_number') end
    if amount > max then
        return false, 'over_max', (L('panel.not_paid_is_over_the_most')):format(amount, max)
    end
    local who, whoErr, whoMessage = actionSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, result = Payments.pay(staffOf(src), who.cid, amount, account, reason, who.stored)
    if not ok then
        if result == CH.ERR.BUSY then
            return false, result, L('panel.a_payment_to_them_is_still')
        end
        return false, result, L('panel.not_paid_the_server_could_not')
    end
    local whom = who.name or L('panel.them')
    -- A sentence for each account, not its code in one.
    local bank = account == 'bank'
    if result.paid then
        return true, nil, L(bank and 'panel.paid_bank_to' or 'panel.paid_cash_to'):format(amount, whom),
            { paid = true, owed = false }
    end
    return true, nil, L(bank and 'panel.owed_bank_to' or 'panel.owed_cash_to'):format(amount, whom),
        { paid = false, owed = true }
end

--------------------------------------------------------------------------
-- Staff tools: the notice to every hitman, and the settings history
--------------------------------------------------------------------------

--- Send one phone notice, from 'Staff', to every player holding a contract
--- or every player online the app is open to (server/announce.lua). A
--- write: the ACE itself and the write allowance; the page asks twice.
--- On the record as staff_announce, by the module.
H.announce = function(src, data)
    if not deps.announce then return false, 'unavailable', L('panel.announcements_are_not_running_on_this') end
    if data.text ~= nil and type(data.text) ~= 'string' then
        return false, CH.ERR.INVALID_INPUT, L('panel.write_the_notice')
    end
    local scope = data.scope
    if scope ~= nil and scope ~= 'active' and scope ~= 'online' then
        return false, CH.ERR.INVALID_INPUT, L('panel.send_it_to_every_hitman_or')
    end
    local ok, err, detail = deps.announce.send(staffOf(src), data.text, scope)
    if not ok then
        local rule = detail and detail.rule
        if rule == 'length' then
            return false, err, L('panel.not_sent_at_most_characters'):format(deps.announce.MAX)
        elseif rule == 'pattern' then
            return false, err, L('panel.not_sent_no_links_invites_or')
        end
        return false, err, L('panel.not_sent_write_the_notice_first')
    end
    local who = detail.scope == 'online' and L('panel.player_online_with_the_app') or L('panel.hitman_hitmen_holding_a_contract')
    if detail.sent == 0 then
        return true, nil, (L('panel.nobody_to_send_it_to_no'))
            :format(detail.scope == 'online' and L('panel.player_online_with_the_app_2') or L('panel.hitman_holding_a_contract')),
            detail
    end
    return true, nil, L('panel.sent_to_from_staff'):format(detail.sent, who), detail
end

--- The handles the history gives its rows, so Undo names a change without
--- the page holding the value it puts back: [ref] = { key, value, after }. Kept
--- for the life of the process, at most HISTORY_REFS_MAX.
local historyRefs, historyRefSeq, historyRefCount = {}, 0, 0
local HISTORY_REFS_MAX = 5000

local function historyRef(key, value, after)
    if historyRefCount >= HISTORY_REFS_MAX then historyRefs, historyRefCount = {}, 0 end
    historyRefSeq = historyRefSeq + 1
    historyRefCount = historyRefCount + 1
    local ref = 'h' .. historyRefSeq
    historyRefs[ref] = { key = key, value = value, after = after }
    return ref
end

--- Logs, area 'settings': every setting change, newest first, a page at a
--- time: who, when, the key and its value before and after
--- (Settings.history). Read by every staff member who may read the
--- settings; the Developer section's own keys only by staff who may open
--- it, as the settings list shows them. A secret's values are never shown.
--- Who made a change is their citizen id with IdentityAce, and 'a staff
--- member' without it.
LOG_AREAS.settings = function(src, data)
    local canIdentify = identifies(src)
    local isDeveloper = developer(src)
    local limit = math.min(LOG_ROWS_MAX, wholeNumber(data.limit, 1, LOG_ROWS_MAX) or pageSize())
    local cursor = wholeNumber(data.cursor, 0)
    local rows, next_ = deps.settings.history(cursor, limit)
    local canUndo = allowed(src, WRITE)
    local out, hidden = {}, 0
    for _, row in ipairs(rows or {}) do
        if not isDeveloper and developerKey(row.key) then
            hidden = hidden + 1
        else
            local entry = deps.settings.entry(row.key)
            out[#out + 1] = {
                ts = row.ts, key = row.key, label = entry and entry.label or nil,
                old = row.old, new = row.new, secret = row.secret,
                reset = row.source == 'config' or nil,
                by = canIdentify and (row.actor or row.by) or L('panel.a_staff_member'),
                ref = (row.undoable and canUndo) and historyRef(row.key, row.old, row.new) or nil,
            }
        end
    end
    return true, nil, nil, { rows = out, next = next_, hidden = hidden > 0 and hidden or nil }
end

--- Put a key back to the value it had before one change: through the
--- normal set path (Settings.set, checked as any change is, and its own
--- admin_setting_changed row), with a row of its own saying it was an
--- undo. The page asks twice. The value is the server's, from the row's
--- handle, never the page's.
H.undoSetting = function(src, data)
    local ref = type(data.ref) == 'string' and data.ref:sub(1, 16) or nil
    local held = ref and historyRefs[ref] or nil
    if not held then return false, CH.ERR.NOT_FOUND, L('panel.that_row_is_gone_refresh_the_2') end
    local key = held.key
    if developerKey(key) and not developer(src) then
        return false, 'developer_required', deps.admin.howToAuthorise(developerAce(), true)
    end
    local cid, who = staffOf(src)
    -- Only over the value this row left: a newer change since is refused,
    -- never undone along with it.
    local ok, err, detail = deps.settings.set(key, held.value, who, cid, held.after)
    if not ok then return false, err, settingRefusal(key, err, detail) end
    deps.audit.staff('admin_undo_setting', cid, nil,
        { key = key, to = detail.value, from = detail.old, unchanged = detail.unchanged or nil })
    if detail.unchanged then
        return true, nil, (L('panel.is_already_nothing_changed_2'))
            :format(key, deps.settings.describe(detail.value)), detail
    end
    return true, nil, L('panel.undone_is_again_it_was'):format(key,
        deps.settings.describe(detail.value), deps.settings.describe(detail.old)), detail
end

--------------------------------------------------------------------------
-- Target limits (server/targetlimits.lua): the section of its own
--------------------------------------------------------------------------

--- The limits as the page edits them: { [key] = number }. nil for anything
--- but a small table; TargetLimits checks every key and value.
local function limitsOf(value)
    if type(value) ~= 'table' then return nil end
    local out, n = {}, 0
    for key, v in pairs(value) do
        n = n + 1
        if n > 16 or type(key) ~= 'string' then return nil end
        out[key:sub(1, 64)] = tonumber(v) or v
    end
    return out
end

local TL_OFF = L('panel.target_limits_are_not_running_on')

--- What a refused target limit write says.
local function targetRefusal(err, detail)
    if err == CH.ERR.BUSY then
        return false, err, L('panel.a_change_to_them_is_still')
    end
    if err == 'not_active' then return false, err, L('panel.nothing_like_that_is_set_so') end
    if err == 'too_many' then
        return false, err, L('panel.at_most_jobs_may_have_their'):format(deps.targetLimits.JOBS_MAX)
    end
    if err == CH.ERR.INVALID_INPUT then
        local why = detail and detail.why
        if why == 'job' then
            return false, err, (L('panel.a_job_name_is_its_qbx'))
                :format(deps.targetLimits.JOB_MAX)
        end
        return false, err, L('panel.not_changed_3') .. (why and tostring(why) or L('panel.the_server_could_not_read_that_2'))
            .. '.'
    end
    return false, err, L('panel.not_changed_the_store_did_not')
end

--- Every limit, as the page lists them, with the global value now.
local function limitKeys()
    local out = {}
    for _, entry in ipairs(deps.targetLimits.KEYS) do
        out[#out + 1] = { key = entry.key, label = entry.label, unit = entry.unit, min = entry.min,
                          max = entry.max, value = tonumber(Config.Limits[entry.key]) or 0 }
    end
    return out
end

--- The section's lists: the limits, and every job with its own and what
--- applies to that job's members as a result.
H.targetLimits = function()
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local jobs = {}
    for _, row in ipairs(TL.jobs()) do
        jobs[#jobs + 1] = { job = row.job, limits = row.limits, at = row.at,
                            effective = TL.effective(nil, row.job).values }
    end
    return true, nil, nil, { keys = limitKeys(), jobs = jobs, ignored = #deps.targetLimits.ignored(),
                             jobMax = TL.JOB_MAX, extendMax = TL.EXTEND_MAX_MINUTES,
                             overrideMaxHours = TL.OVERRIDE_MAX_HOURS }
end

--- Add or change one job's limits: { job, limits }.
H.targetJobSet = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local limits = limitsOf(data.limits)
    if not limits then return false, CH.ERR.INVALID_INPUT, L('panel.give_at_least_one_limit_for') end
    local ok, err, detail = deps.targetLimits.setJob(staffOf(src), data.job, limits)
    if not ok then return targetRefusal(err, detail) end
    return true, nil, L('panel.targets_working_as_now_have_these'):format(detail.job)
end

--- Remove one job's limits: { job }.
H.targetJobRemove = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local ok, err = deps.targetLimits.removeJob(staffOf(src), data.job)
    if not ok then return targetRefusal(err) end
    return true, nil, L('panel.removed_that_jobs_members_have_the')
end

--- The jobs a target holds now (the one they are working first, then every
--- other they hold: TargetLimits.jobsOf, as placing reads them), or the one
--- the latest contract on them recorded, and which it is.
local function targetJobOf(cid, actor, contracts)
    if actor then
        local jobs = deps.targetLimits.jobsOf(actor)
        if #jobs > 0 then return jobs, 'now' end
    end
    local best
    for _, c in ipairs(contracts or {}) do
        if c.target_cid == cid and c.target_job and (not best or (c.created_at or 0) > (best.created_at or 0)) then
            best = c
        end
    end
    return best and tostring(best.target_job) or nil, best and L('panel.last_known') or nil
end

--- One player as a target, exactly: { ref } from a lookup made here, or
--- { subject } to look them up (as Players does), which gives the ref
--- every write from this card names them by.
H.targetStatus = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local canIdentify = identifies(src)
    local who, whoErr, whoMessage
    if data.ref ~= nil then
        who, whoErr, whoMessage = fromPlayerRef(src, data.ref)
    else
        who, whoErr, whoMessage = playerSubject(data.subject, src)
    end
    if not who then return false, whoErr, whoMessage end
    local cid = who.cid
    local actor = who.actor or deps.identity.byCitizenId(cid)
    local now = os.time()
    local eff = TL.effective(cid, actor and TL.jobsOf(actor) or nil).values
    local back = math.max(TL.WEEK, tonumber(eff.TargetCooldownAfterResolveSeconds) or 0,
        tonumber(eff.TargetCooldownAfterCompletionSeconds) or 0,
        tonumber(Config.Immunity.AfterBailoutSeconds) or 0)
    local contracts = deps.storage.contractsNaming(cid, now - back) or {}
    local job, jobFrom = targetJobOf(cid, actor, contracts)
    local status = deps.targetLimits.status(cid, job, contracts, deps.contracts.everTakenUp)
    status.jobFrom = jobFrom
    local name = actor and actor.name or nil
    if not name then
        for _, c in ipairs(contracts) do
            if c.target_cid == cid then
                name = c.target_name
                break
            end
        end
    end
    if who.typed and not actor and not name and deps.identity.characterExists(cid) == false then
        return false, CH.ERR.NOT_FOUND, L('panel.nobody_in_the_city_has_that_3')
    end
    deps.audit.staff('admin_panel_target_status', staffOf(src), nil, { subject = cid, typed = who.typed or nil })
    return true, nil, nil, {
        player = { cid = (canIdentify or who.typed) and cid or nil, name = name, online = actor ~= nil,
                   ref = data.ref ~= nil and data.ref or playerRef(src, who) },
        status = status,
    }
end

--- One staff action on the player a lookup found: data.ref only, never a
--- name or a player id matched again now.
local function targetWrite(src, data, action, args, said)
    -- `said` is the reply, or a function of the player's row as written.
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    if data.ref == nil then return false, 'stale_lookup', STALE_LOOKUP end
    local who, whoErr, whoMessage = fromPlayerRef(src, data.ref)
    if not who then return false, whoErr, whoMessage end
    local reason = shortText(data.reason, TL.REASON_MAX)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    args.reason = reason
    args.name = who.actor and who.actor.name or nil
    local ok, err, detail
    -- A player's own limits are one of their measures (server/measures.lua).
    if action == 'override' then
        ok, err, detail = Measures.apply('limit', staffOf(src), who.cid, args)
    elseif action == 'clear' then
        ok, err, detail = Measures.lift('limit', staffOf(src), who.cid, args.reason, args.name)
    else
        ok, err, detail = deps.targetLimits.adjust(staffOf(src), who.cid, action, args)
    end
    if not ok then return targetRefusal(err, detail) end
    if type(said) == 'function' then said = said(detail) end
    return true, nil, said
end

--- What a buyout's immunity means to a staff action that leaves it.
local BUYOUT_KEPT = L('panel.a_buyout_they_paid_for_still')

H.targetReset = function(src, data)
    local all = data.all == true
    if all then
        return targetWrite(src, data, 'reset', { all = true },
            L('panel.every_cooldown_on_them_is_cleared'))
    end
    return targetWrite(src, data, 'reset', { all = false }, function(row)
        -- A staff extension is not a cooldown Reset clears (canCreate
        -- still refuses on it), so it is said, with the way to clear it.
        local held = deps.targetLimits.extendedUntil(row)
        if held then
            return (L('panel.their_cooldown_is_cleared_but_a'))
                :format((L('panel.span_minutes')):format(tostring(math.max(1, math.ceil((held - os.time()) / 60)))),
                    BUYOUT_KEPT)
        end
        return L('panel.their_cooldown_is_cleared_the_same') .. BUYOUT_KEPT
    end)
end

H.targetExtend = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local most = TL.EXTEND_MAX_MINUTES
    local minutes = wholeNumber(data.minutes, 1, most)
    local untilAt = wholeNumber(data.untilAt, 1)
    if not minutes and not untilAt then
        return false, CH.ERR.INVALID_INPUT,
            L('panel.give_the_minutes_to_add_1'):format(most)
    end
    if untilAt and (untilAt <= os.time() or untilAt > os.time() + most * 60) then
        return false, CH.ERR.INVALID_INPUT, L('panel.that_time_is_in_the_past')
    end
    return targetWrite(src, data, 'extend', { minutes = not untilAt and minutes or nil, untilAt = untilAt },
        L('panel.their_cooldown_is_extended_nobody_may'))
end

H.targetCounts = function(src, data)
    return targetWrite(src, data, 'counts', {}, L('panel.their_day_and_week_counts_start'))
end

H.targetOverride = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local hours = wholeNumber(data.hours, 0, TL.OVERRIDE_MAX_HOURS)
    if not hours then return false, CH.ERR.INVALID_INPUT, L('panel.hours_are_a_whole_number_or') end
    local exempt = data.exempt == true
    local limits = exempt and {} or limitsOf(data.limits)
    if not limits then return false, CH.ERR.INVALID_INPUT, L('panel.give_the_limits_or_choose_exempt') end
    return targetWrite(src, data, 'override', { exempt = exempt, limits = limits, hours = hours },
        exempt and (L('panel.they_are_exempt_from_the_target') .. BUYOUT_KEPT) or L('panel.their_own_limits_are_set'))
end

H.targetOverrideClear = function(src, data)
    return targetWrite(src, data, 'clear', {},
        L('panel.their_own_limits_are_lifted_the'))
end

--- Who a job action reaches: every player in the city holding that job now,
--- working it or not (TargetLimits.jobsOf, as placing reads it), and every
--- character not in the city whom the latest contract placed on them in the
--- last 7 days recorded as holding it. Citizen ids, sorted.
local function jobPlayers(job)
    local out, seen = {}, {}
    for _, actor in ipairs(deps.identity.online() or {}) do
        seen[actor.cid] = true
        for _, name in ipairs(deps.targetLimits.jobsOf(actor)) do
            if tostring(name):lower() == job then
                out[#out + 1] = actor.cid
                break
            end
        end
    end
    local since, latest = os.time() - deps.targetLimits.WEEK, {}
    for _, c in ipairs(everyContract()) do
        if (tonumber(c.created_at) or 0) >= since and c.target_cid and not seen[c.target_cid] then
            local was = latest[c.target_cid]
            if not was or (c.created_at or 0) > (was.created_at or 0) then latest[c.target_cid] = c end
        end
    end
    for cid, c in pairs(latest) do
        if tostring(c.target_job or ''):lower() == job then out[#out + 1] = cid end
    end
    table.sort(out)
    return out
end

--- How many players a job action would reach, for the confirm: { job }.
H.targetJobCount = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local job = TL.jobName(data.job)
    if not job then return targetRefusal(CH.ERR.INVALID_INPUT, { why = 'job' }) end
    return true, nil, nil, { job = job, count = #jobPlayers(job) }
end

--- One action on every player of a job: { job, action ('reset' | 'extend'
--- | 'counts'), minutes, all, reason }. One audit row, with the count.
H.targetJobAction = function(src, data)
    local TL = deps.targetLimits
    if not TL then return false, 'unavailable', TL_OFF end
    local job = TL.jobName(data.job)
    if not job then return targetRefusal(CH.ERR.INVALID_INPUT, { why = 'job' }) end
    local action = (data.action == 'reset' or data.action == 'extend' or data.action == 'counts')
        and data.action or nil
    if not action then return false, CH.ERR.INVALID_INPUT, L('panel.reset_extend_or_reset_the_counts') end
    local reason = shortText(data.reason, TL.REASON_MAX)
    if not reason then return false, CH.ERR.INVALID_INPUT, L('panel.give_a_reason_it_goes_on') end
    -- A buyout's immunity is lifted one player at a time, never for a job.
    local args = { reason = reason, all = (action == 'reset' and data.all == true) or nil,
                   keepBuyout = action == 'reset' or nil }
    if action == 'extend' then
        args.minutes = wholeNumber(data.minutes, 1, TL.EXTEND_MAX_MINUTES)
        if not args.minutes then
            return false, CH.ERR.INVALID_INPUT,
                L('panel.give_the_minutes_to_add_1_2'):format(TL.EXTEND_MAX_MINUTES)
        end
    end
    local cids = jobPlayers(job)
    if #cids == 0 then
        return false, 'nobody', L('panel.nobody_is_working_as_or_was'):format(job)
    end
    local _, _, done = deps.targetLimits.adjustMany(staffOf(src), job, cids, action, args)
    local what = (action == 'reset' and L('panel.cooldowns_reset')) or (action == 'extend' and L('panel.cooldowns_extended'))
        or L('panel.day_and_week_counts_reset')
    return true, nil, L('panel.player_had_their'):format(job, done.done, what,
        done.failed > 0 and L('panel.could_not_be_changed'):format(done.failed) or '',
        action == 'reset' and (L('panel.a_buyout_any_of_them_paid')) or ''), done
end


--------------------------------------------------------------------------
-- The one way in
--------------------------------------------------------------------------

--- Note a refusal once per window per source.
local function noteDenied(src, op, why)
    local now = Util.monotonicMs()
    local last = deniedLogged[src]
    if last and now - last < DENIED_LOG_MS then return end
    deniedLogged[src] = now
    deps.audit.rejected('admin_panel_' .. why, nil, nil,
        { source = src, op = type(op) == 'string' and Util.toValidUtf8(op:sub(1, 32)) or nil })
end

--- Answer one request from the page, in the house order: the source, the
--- ACE, the rate limit, the fields, the work. Every request is answered,
--- refusals included, so the page never waits for one that is not coming.
---@param src number the engine's source
---@param payload any { op, data, __rid }
---@return table|nil reply { rid, op, ok, err, message, data }; nil for the console
function Panel.handle(src, payload)
    src = tonumber(src) or 0
    if src <= 0 then return nil end
    local rid = type(payload) == 'table' and wholeNumber(payload.__rid, 0) or nil
    local op = type(payload) == 'table' and type(payload.op) == 'string'
        and Util.toValidUtf8(payload.op:sub(1, 32)) or nil
    local function answer(ok, err, message, data)
        return { rid = rid, op = op, ok = ok == true, err = err, message = message, data = data }
    end

    if not Config.Admin.Enabled then
        return answer(false, 'admin_off', L('panel.the_staff_tools_are_switched_off'))
    end

    -- Permission, before anything about the request is looked at. An op
    -- nobody knows is checked as a read, so it answers the same as any
    -- other to somebody who may not read.
    local level = (op and (OPS[op] or EXTRA_OPS[op])) or READ
    local byDeveloper = level == WRITE and type(payload) == 'table' and not allowed(src, WRITE)
        and developerWrite(src, op, payload.data)
    if not byDeveloper
        and not allowed(src, (level == IDENTITY or level == DEVELOPER) and READ or level) then
        noteDenied(src, op, 'denied')
        local why = ''
        if level == MOD then
            why = (L('panel.freezing_suspending_protecting_voiding_and_moving'))
                :format(tostring(moderatorAce() or 'Config.Admin.ModeratorAce'))
        elseif level == WRITE then
            why = L('panel.changing_anything_else_needs_that_ace')
        end
        return answer(false, 'not_allowed', deps.admin.howToAuthorise(Config.Admin.Ace, true) .. why)
    end
    if level == DEVELOPER and not developer(src) then
        noteDenied(src, op, 'developer_denied')
        return answer(false, 'developer_required', deps.admin.howToAuthorise(developerAce(), true))
    end
    -- A setting in the Developer section, changed or reset, by name: the
    -- same ACE as reading it. Only staff with Ace write at all, and they see
    -- the section, so this refuses nothing today; it is the gate should the
    -- fallback ever narrow.
    if (op == 'setSetting' or op == 'resetSetting') and type(payload.data) == 'table'
        and developerKey(payload.data.key) and not developer(src) then
        noteDenied(src, op, 'developer_denied')
        return answer(false, 'developer_required', deps.admin.howToAuthorise(developerAce(), true))
    end
    if level == IDENTITY and not identifies(src) then
        noteDenied(src, op, 'identity_denied')
        return answer(false, 'identity_required', (L('panel.unmasking_needs_a_separate_ace'))
            :format(tostring(Config.Admin.IdentityAce)))
    end

    -- Per staff member's source, and once more for anything that writes.
    local key = 'panel:' .. tostring(src)
    local writes = level == WRITE or level == MOD
    for _, bucket in ipairs(writes and { 'admin', 'adminWrite' } or { 'admin' }) do
        if not deps.ratelimit.check(key, bucket) then
            local wait = deps.ratelimit.retryAfter(key, bucket) or 0
            return answer(false, CH.ERR.RATE_LIMITED,
                wait > 0 and L('panel.slow_down_try_again_in_second'):format(wait) or L('panel.slow_down'),
                { retryAfter = wait })
        end
    end

    if not op or not (OPS[op] or EXTRA_OPS[op]) then
        return answer(false, 'unknown_op', L('panel.the_page_asked_for_something_this'))
    end
    local data = type(payload.data) == 'table' and payload.data or {}

    if WAITS_FOR_RECOVERY[op] or (EXTRA_OPS[op] and writes) then
        local waiting = deps.admin.recovery()
        if waiting then return answer(false, waiting, deps.admin.notRecovered()) end
    end

    local ran, ok, err, message, result = pcall(H[op] or EXTRA_H[op], src, data)
    if not ran then
        -- What it was asked to act on, and why, so the contract's timeline
        -- and the log say which one a raised void or settle was about.
        local about = Util.toId(data.id) or Util.toLineId(data.line)
        deps.audit.rejected('admin_panel_error', staffOf(src),
            op == 'void' and Util.toId(data.id) or nil, { op = op, error = tostring(ok), id = about,
            reason = shortText(data.reason, 120) })
        -- A write that raised may have moved money part-way, so the console
        -- hears of it whatever Config.Debug says; a read only with it on.
        -- Either is kept for the diagnosis, which is where this sends staff.
        local say = writes and Log.always or Log.debug
        say(('the admin panel\'s %s raised: %s'):format(op, tostring(ok)))
    end
    if writes then
        -- Whatever it moved shows in the next overview and search, not
        -- ones cached from before it: one that raised part-way included.
        overviewCache, contractsCache = nil, nil
        -- Every write on the record at once, not at the next flush, the
        -- row saying it raised with the rest.
        pcall(deps.audit.flush)
        if deps.storage.flush then pcall(deps.storage.flush) end
    end
    if not ran then
        return answer(false, CH.ERR.SERVER_ERROR,
            L('panel.that_raised_an_error_on_the'))
    end
    return answer(ok, err, message, result)
end

--- Whether `value` written out as JSON would be more than `limit` bytes,
--- counted as it walks and given up at the limit: the reply was encoded
--- whole only to be measured, then serialised again to be sent, and a page
--- of the log is a few hundred KB of string built and thrown away. A
--- string counts its bytes and its quotes, a number its digits, a key its
--- name and the punctuation around it. Escapes count too: a quote, a
--- backslash or a newline is two bytes written out, any other control
--- character six (\u00XX), so a reply made mostly of them (a diagnosis
--- dump, a log page of multi-line reasons) is not counted short of the
--- line and sent in one frame.
---@param value any
---@param limit integer
---@return boolean
function Panel.over(value, limit)
    local total = 0
    local function walk(v, depth)
        if total > limit then return end
        local kind = type(v)
        if kind == 'string' then
            total = total + #v + 2
            if v:find('[\0-\31"\\]') then
                local _, quotes = v:gsub('["\\]', '')
                local _, short = v:gsub('[\b\f\n\r\t]', '')
                local _, control = v:gsub('[\0-\31]', '')
                total = total + quotes + short + (control - short) * 5
            end
        elseif kind == 'number' then
            if v == math.floor(v) and v > -1e15 and v < 1e15 then
                local n, digits = math.abs(v), 1
                while n >= 10 do n, digits = n // 10, digits + 1 end
                total = total + digits + (v < 0 and 1 or 0)
            else
                total = total + 17
            end
        elseif kind == 'boolean' then
            total = total + 5
        elseif kind == 'table' then
            if depth > 32 then return end
            total = total + 2
            for k, child in pairs(v) do
                total = total + 1
                if type(k) == 'string' then total = total + #k + 3 end
                walk(child, depth + 1)
                if total > limit then return end
            end
        else
            total = total + 4
        end
    end
    walk(value, 0)
    return total > limit
end

--- Send a reply to the page's client: as a latent event when it is large.
---@param src number
---@param reply table
function Panel.send(src, reply)
    if Panel.over(reply, LATENT_OVER) then
        TriggerLatentClientEvent('crimson-hitman:adminResult', src, LATENT_BPS, reply)
    else
        TriggerClientEvent('crimson-hitman:adminResult', src, reply)
    end
end

--- Something the server has for an open panel that no request asked for
--- just now: a diagnosis line that had to wait for an answer.
---@param src number
---@param data table { kind, line }
function Panel.push(src, data)
    TriggerClientEvent('crimson-hitman:adminPush', src, data)
end

return Panel
end)
