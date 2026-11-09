--- The admin panel's server side (/hitmanadmin, Config.Admin.Commands.panel).
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
local Log = CrimsonBoot.requireShared('log')

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
    -- Staff freezes (server/freeze.lua): the list is a read; freezing and
    -- releasing move no money and stop nothing for good: a moderator's.
    frozen = READ, freeze = MOD, unfreeze = MOD,
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
    -- the page), the settings history every reader of the settings reads,
    -- and an undo of one change through the normal set path.
    announce = WRITE, settingsHistory = READ, undoSetting = WRITE,
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
                  button = 'a row in Contracts, or any contract id: the contract\'s view' },
    contracts = { ops = { 'player' }, level = READ, audit = 'admin_contracts',
                  button = 'Players: Look up' },
    stuck     = { ops = { 'stuck' }, level = READ, audit = 'admin_stuck',
                  button = 'Stuck escrow' },
    diagnose  = { ops = { 'diag' }, level = READ, button = 'Tools: Run the diagnosis' },
    -- The command needs Ace itself; the button, the moderator level too.
    void      = { ops = { 'void' }, level = WRITE, moderator = true, confirm = true, audit = 'admin_void',
                  button = 'the contract\'s view: Void contract' },
    settle    = { ops = { 'settle' }, level = WRITE, confirm = true, audit = 'admin_settle_line',
                  button = 'Stuck escrow, or the contract\'s view: Pay, Pay amount, Return, Delivered' },
    review    = { ops = { 'reviews', 'resolve' }, level = WRITE, confirm = true,
                  audit = 'review_resolved', button = 'Needs review: Refund, Pay, Dismiss' },
    refresh   = { ops = { 'refresh' }, level = WRITE, confirm = true, audit = 'admin_timers_refreshed',
                  button = 'Tools: Bring timers forward' },
    whois     = { ops = { 'whois' }, level = IDENTITY, audit = 'admin_identify',
                  button = 'the contract\'s view, or Players: Whois' },
}
Panel.LEVELS = { READ = READ, MOD = MOD, WRITE = WRITE, IDENTITY = IDENTITY, DEVELOPER = DEVELOPER }
Panel.OPS = OPS

--- Writes that wait for boot recovery, as the commands do. Flushing the
--- log is not one: it moves nothing, and is how the log reaches the disk
--- after a recovery that failed.
local WAITS_FOR_RECOVERY = {
    void = true, settle = true, resolve = true, setSetting = true, resetSetting = true,
    resetSettings = true, refresh = true, freeze = true, unfreeze = true, adjustDeadline = true,
    removeHitman = true, editText = true,
    suspend = true, unsuspend = true, protect = true, unprotect = true, manualPay = true,
    undoSetting = true,
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

--- The handles the frozen list gives its rows, so Unfreeze there names a
--- player without the page holding their citizen id: [ref] = cid, and the
--- reverse. Kept for the life of the process.
local freezeRefs, freezeRefOf, freezeRefSeq = {}, {}, 0

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
    freezeRefs, freezeRefOf, freezeRefSeq = {}, {}, 0
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
        return (Admin.howToAuthorise(ace, true):gsub('^Not authorised: this needs the [^.]+ ACE%. ', ''))
    end
    local out = {
        { ace = Config.Admin.Ace, name = 'Staff ACE (Config.Admin.Ace)', held = holds(Config.Admin.Ace),
          unlocks = 'Opens this panel and the staff commands, and changes anything: voids, settles, '
              .. 'reviews, freezes, suspensions, protections, manual payments and every setting. Holders '
              .. 'see the Developer section too.',
          grant = grant(Config.Admin.Ace) },
        { ace = moderatorAce() or 'crimson.moderator', name = 'Moderator ACE (Config.Admin.ModeratorAce)',
          held = moderatorAce() ~= nil and holds(moderatorAce()) or false,
          unlocks = 'Opens this panel to read everything the staff ACE reads, scrubbed as without the '
              .. 'identity ACE, and to freeze and unfreeze, suspend, protect, void and move a deadline. '
              .. 'Never settings, payments, refunds or the Developer section.',
          grant = grant(moderatorAce() or 'crimson.moderator') },
        { ace = Config.Admin.IdentityAce, name = 'Identity ACE (Config.Admin.IdentityAce)',
          held = holds(Config.Admin.IdentityAce),
          unlocks = 'Shows who is behind an anonymous party, and citizen ids, everywhere in the panel; '
              .. 'every look is on the record. Changes nothing.',
          grant = grant(Config.Admin.IdentityAce) },
        { ace = developerAce(), name = 'Developer ACE (Config.Admin.DeveloperAce)', held = holds(developerAce()),
          unlocks = 'Opens the Developer section: the console, diagnostics, storage, debug and rate limits. '
              .. 'Holders of the staff ACE see it as well.',
          grant = grant(developerAce()) },
    }
    for _, extra in ipairs(type(Config.Admin.ExtraAces) == 'table' and Config.Admin.ExtraAces or {}) do
        if type(extra) == 'string' then
            out[#out + 1] = { ace = extra, name = 'Extra ACE (Config.Admin.ExtraAces)', held = holds(extra),
                unlocks = 'Opens this panel and the staff commands read-only: nothing it opens changes '
                    .. 'anything.', grant = grant(extra) }
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
            and deps.admin.howToAuthorise(developerAce(), true):gsub('^Not authorised: ', 'To give the '
                .. 'Developer section to its own people: ') or nil,
        permissions = permissionsFor(src),
        pageSize = math.max(5, math.min(100, math.floor(tonumber(Config.Admin.PanelPageSize) or 25))),
        refreshSeconds = math.max(2, math.floor(tonumber(Config.Admin.PanelRefreshSeconds) or 10)),
        recovery = recoveryState(),
        version = okVersion and version or nil,
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
local ACCOUNT_SHOWN = '(an account)'

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
        if contract.target_cid then labels[contract.target_cid] = 'the target' end
        if contract.creator_cid then labels[contract.creator_cid] = 'the placer' end
        if contract.anon_creator == true and contract.creator_name then
            hidden[contract.creator_name] = true
        end
        if contract.creator_account then needles[contract.creator_account] = ACCOUNT_SHOWN end
        if contract.target_account then needles[contract.target_account] = ACCOUNT_SHOWN end
    end
    for _, hitman in ipairs(hitmen or {}) do
        if hitman.hitman_cid and not labels[hitman.hitman_cid] then
            labels[hitman.hitman_cid] = ('operative %s'):format(tostring(hitman.alias or '?'))
        end
        if hitman.anon == true and hitman.hitman_name then hidden[hitman.hitman_name] = true end
        if hitman.hitman_account then needles[hitman.hitman_account] = ACCOUNT_SHOWN end
    end
    for cid, label in pairs(labels) do needles[cid] = label end
    for name in pairs(hidden) do needles[name] = 'Anonymous' end

    local r = { canIdentify = canIdentify }

    --- A citizen id as this staff member may see it.
    function r.who(cid)
        if cid == nil then return nil end
        if canIdentify then return cid end
        return labels[cid] or '(a player)'
    end

    --- A creator's or a hitman's name as this staff member may see it.
    function r.name(name, anonymous)
        if anonymous and not canIdentify then return 'Anonymous' end
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
        if not canIdentify and SOURCE_KEYS[key] and type(v) == 'number' then return '(a player)' end
        if canIdentify or type(v) ~= 'string' then return v end
        if labels[v] then return labels[v] end
        if hidden[v] then return 'Anonymous' end
        if CID_KEYS[key] and v:match('^[%u%d]+$') and #v >= 3 then return '(a player)' end
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
        if contract and contract.creator_name then names[contract.creator_name] = 'the placer' end
        if contract and contract.target_name then names[contract.target_name] = 'the target' end
        for _, hitman in ipairs(hitmen or {}) do
            if hitman.hitman_name then
                names[hitman.hitman_name] = ('operative %s'):format(tostring(hitman.alias or '?'))
            end
        end
        text = scrubbed(text, names):gsub('https?://%S+', '(a link)')
    end
    for _, prefix in ipairs(ACCOUNT_PREFIXES) do
        text = text:gsub('%f[%w]' .. prefix .. ':[%w%.:]+', ACCOUNT_SHOWN)
    end
    return (text:gsub('%f[%w][%u%d]+%f[%W]', function(word)
        if #word >= 5 and #word <= 32 and word:find('%u') and word:find('%d') then
            return '(a player)'
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
        return scheme .. host .. (rest ~= '' and '/(path hidden)' or '')
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
local IDENTITY_ONLY_SHOWN = '(identity only)'

--- Rows whose actor staff without IdentityAce are shown only as what they
--- were, not as which party: an informant tip (server/locationtip.lua) says
--- a hitman bought one, never which operative, since an anonymous hitman's
--- alias is the one thing that tells two of them apart.
local ACTOR_SHOWN_AS = {
    location_tip_bought = { actor = 'a hitman', said = 'a hitman bought an informant tip' },
    location_tip_refunded = { actor = 'a hitman', said = 'an informant tip was given back' },
    location_tip_refund_failed = { actor = 'a hitman',
                                   said = 'an informant tip could not be given back' },
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

--- What the diagnosis says that wants doing (the lines with '->', or a
--- word in capitals), run as the console would, which asks no player's
--- phone for anything, in the panel's words. The lines only the console
--- needs are left out, and so are the console's own lines it keeps (marked
--- with a dot), which are notes, not things to do.
local CONSOLE_ONLY = {
    'name somebody who is in the city', 'run from the console', 'the server-wide checks below',
    'name a player to test',
}

local function diagWarnings()
    local ok, lines = pcall(deps.admin.diagnose, 0, nil, nil, { panel = true })
    if not ok or type(lines) ~= 'table' then
        return { ('the diagnosis itself raised: %s'):format(Util.dbError(lines)) }
    end
    local out = {}
    for _, line in ipairs(lines) do
        local skip = line:find('^%-%-%-') ~= nil or line:find('^%s*·') ~= nil
            or line:find('^console:') ~= nil
        for _, text in ipairs(CONSOLE_ONLY) do
            if line:find(text, 1, true) then skip = true end
        end
        if not skip and (line:find('->', 1, true) or line:find('%u%u%u%u')) then
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
    -- Players staff have put on hold (server/freeze.lua): a count only.
    -- Unknown while the store's freezes cannot be read: never 0 of nobody known.
    local players, unknown = 0, false
    if deps.freeze then players, unknown = deps.freeze.count() end
    out.frozen = { players = players or 0, unknown = unknown == true or nil }
    -- The whole app paused by staff (Config.Staff.AppPaused), and since when.
    out.appPaused = deps.freeze and deps.freeze.appPausedSince and deps.freeze.appPausedSince() or nil
    return out
end

--- Who a staff member may be shown has put a contract on hold: its frozen
--- parties (server/freeze.lua), each as their place on it, leaving out an
--- anonymous one for staff without IdentityAce. Empty is shown as not
--- frozen at all: a badge on a contract whose visible parties are none of
--- them frozen said that its anonymous party was the player just frozen.
---@return string[]|nil places, nil when none may be shown
local function frozenShown(contract, hitmen, canIdentify)
    local parties = deps.freeze and deps.freeze.partiesOf(contract, hitmen)
    if not parties then return nil end
    local aliases = {}
    for _, hitman in ipairs(hitmen or deps.storage.readHitmen(contract.id) or {}) do
        aliases[hitman.hitman_cid] = hitman.alias
    end
    local out = {}
    for _, party in ipairs(parties) do
        if party.role == 'unknown' then
            -- The store's freezes could not be read: every live contract is
            -- held alike, through nobody. Said as that with IdentityAce, and
            -- to everybody else as held, which names nobody either.
            out[#out + 1] = canIdentify and 'store unreadable' or 'held'
        elseif canIdentify or not party.anonymous then
            out[#out + 1] = party.role == 'target' and 'the target'
                or party.role == 'client' and 'the placer'
                or ('operative %s'):format(tostring(aliases[party.cid] or '?'))
        end
    end
    table.sort(out)
    return #out > 0 and out or nil
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

--- Contracts, searched and filtered, newest first, a page at a time.
---
--- `query` is a contract id (or part of one), a citizen id, or part of a
--- name. A citizen id finds every contract it is party to through the
--- store's own index, and a name the client's or the target's: but a
--- party who paid to stay anonymous is matched only for staff with
--- IdentityAce, or a search would be a way round whois.
H.contracts = function(src, data)
    local Storage = deps.storage
    local canIdentify = identifies(src)
    local query = shortText(data.query, 64)
    local state = VALID_STATE[data.state] and data.state or nil
    local rule = (data.rule == CH.FULFILMENT_RULE.ALIVE or data.rule == CH.FULFILMENT_RULE.EITHER)
        and data.rule or nil
    local from = wholeNumber(data.from, 0)
    local to = wholeNumber(data.to, 0)
    local page = wholeNumber(data.page, 1, 100000) or 1

    -- One read of the store's index, in the form the server keeps the id:
    -- upper case, as qbx_core's are, unless a player in the city holds it as
    -- typed. typedCitizenId decides that with a read of its own, and this
    -- read again after it: every search typed in lower case, a name among
    -- them, walked every contract and every operative twice on json.
    local viaCid = {}
    local cid = query and Util.toCitizenId(query)
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
    for _, contract in ipairs(everyContract()) do
        local hit = not lowered
        if lowered and not hit then
            hit = viaCid[contract.id]
                or tostring(contract.id):lower():find(lowered, 1, true) ~= nil
                or tostring(contract.target_name or ''):lower():find(lowered, 1, true) ~= nil
                or ((canIdentify or contract.anon_creator ~= true)
                    and tostring(contract.creator_name or ''):lower():find(lowered, 1, true) ~= nil)
        end
        if hit and state and contract.state ~= state then hit = false end
        if hit and rule and Util.fulfilmentRule(contract) ~= rule then hit = false end
        if hit and from and (tonumber(contract.created_at) or 0) < from then hit = false end
        if hit and to and (tonumber(contract.created_at) or 0) > to then hit = false end
        if hit then matched[#matched + 1] = contract end
    end
    -- Already newest first (everyContract).

    local size = pageSize()
    local pages = math.max(1, math.ceil(#matched / size))
    if page > pages then page = pages end
    local rows = {}
    for i = (page - 1) * size + 1, math.min(#matched, page * size) do
        local contract = matched[i]
        rows[#rows + 1] = {
            id = contract.id, state = contract.state, mode = contract.mode,
            rule = Util.fulfilmentRule(contract), created_at = contract.created_at,
            deadline_at = contract.deadline_at, resolved_at = contract.resolved_at,
            resolution = contract.resolution, target = contract.target_name,
            client = (contract.anon_creator == true and not canIdentify) and 'Anonymous'
                or contract.creator_name,
            anonymous = contract.anon_creator == true,
            slots = contract.payout_slots, claimed = contract.slots_claimed,
            frozen = frozenShown(contract, nil, canIdentify) ~= nil or nil,
        }
    end

    -- A search by a person is a lookup, and every lookup is on the record.
    if query then
        deps.audit.staff(canIdentify and 'admin_panel_search_identified' or 'admin_panel_search',
            staffOf(src), nil, { query = query, rows = #matched })
    end
    return true, nil, nil, { rows = rows, page = page, pages = pages, total = #matched }
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
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local contract = Storage.readContract(id)
    local lines = Storage.readEscrow(id) or {}
    if not contract and #lines == 0 then return false, CH.ERR.NOT_FOUND, 'No contract has that id.' end

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
        -- On hold by staff (server/freeze.lua), with which of its parties
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
    if h > 0 then out[#out + 1] = h .. ' h' end
    if m > 0 or (h > 0 and s > 0) then out[#out + 1] = (h > 0 and ('%02d'):format(m) or tostring(m)) .. ' min' end
    if s > 0 or #out == 0 then out[#out + 1] = s .. ' s' end
    return table.concat(out, ' ')
end

--- Extend or shorten a live contract's deadline (Admin.adjustDeadline):
--- the panel's Extend and Shorten, on the contract's view. `seconds` is
--- signed, a whole number, not zero and within
--- Config.Limits.StaffDeadlineMaxAdjustSeconds either way; a reason is
--- required, and kept in the log (staff_deadline_adjust).
H.adjustDeadline = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local maxAdjust = adjustLimits()
    local seconds = wholeNumber(data.seconds, -maxAdjust, maxAdjust)
    if not seconds or seconds == 0 then
        return false, CH.ERR.INVALID_INPUT, ('Give a whole number of seconds, not zero, of at most %s '
            .. 'either way (Config.Limits.StaffDeadlineMaxAdjustSeconds).'):format(exactSpan(maxAdjust))
    end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end

    local ok, err, detail = deps.admin.adjustDeadline(src, id, seconds, reason)
    if not ok then
        if err == 'recovering' or err == 'recovery_failed' then return false, err, deps.admin.notRecovered() end
        if err == CH.ERR.NOT_FOUND then return false, err, 'No contract has that id.' end
        if err == CH.ERR.BAD_STATE then
            return false, err, 'Only a live contract (active or accepted) has a deadline to move.'
        end
        if err == 'no_deadline' then return false, err, 'That contract has no deadline to move.' end
        if err == 'min_left' then
            if (detail.most or 0) <= 0 then
                return false, err, ('Not shortened: it has %s left, and at least %s must remain '
                    .. '(Config.Limits.StaffDeadlineMinLeftSeconds). It cannot be shortened now.')
                    :format(exactSpan(detail.left), exactSpan(detail.minLeft))
            end
            return false, err, ('Not shortened: it has %s left, and at least %s must remain '
                .. '(Config.Limits.StaffDeadlineMinLeftSeconds). The most you can shorten it by is %s.')
                :format(exactSpan(detail.left), exactSpan(detail.minLeft), exactSpan(detail.most))
        end
        if err == 'at_limit' then
            return false, err, ('Not extended: its lifetime is already %s from now '
                .. '(Config.Limits.ContractLifetimeSeconds), and the deadline is at it.')
                :format(exactSpan(Config.Limits.ContractLifetimeSeconds))
        end
        if err == 'bad_adjust' then
            return false, CH.ERR.INVALID_INPUT, ('At most %s either way '
                .. '(Config.Limits.StaffDeadlineMaxAdjustSeconds).'):format(exactSpan(maxAdjust))
        end
        if err == CH.ERR.LOCKED then
            return false, err, 'The deadline was moving as you asked (a pause ending). Try again.'
        end
        return false, err, 'Not changed: the store did not take it. Try again in a moment.'
    end

    local moved = math.abs(detail.seconds)
    local message
    if detail.seconds > 0 then
        message = ('Extended by %s: %s left before, %s left now.')
            :format(exactSpan(moved), exactSpan(detail.left_before), exactSpan(detail.left_after))
        if detail.lifetime == 'extended' then
            message = message .. (' The new deadline passed its lifetime, so the lifetime was '
                .. 'extended by %s too.'):format(exactSpan(moved))
        elseif detail.lifetime == 'capped' then
            message = message .. (' The new deadline passed its lifetime, so the lifetime was '
                .. 'extended to its most, %s from now (Config.Limits.ContractLifetimeSeconds)%s.')
                :format(exactSpan(Config.Limits.ContractLifetimeSeconds),
                    moved < detail.requested and (', and the deadline only as far as it: %s of the %s asked')
                        :format(exactSpan(moved), exactSpan(detail.requested)) or '')
        end
    else
        message = ('Shortened by %s: %s left before, %s left now.')
            :format(exactSpan(moved), exactSpan(detail.left_before), exactSpan(detail.left_after))
    end
    if detail.paused then
        message = message .. ' Its clock is stopped now; it runs down from there once it runs again.'
    end
    message = message .. ' Every party was told its time changed, with no figures.'
    return true, nil, message, {
        seconds = detail.seconds, leftBefore = detail.left_before, leftAfter = detail.left_after,
        deadline = detail.new_deadline, lifetime = detail.lifetime, expires = detail.new_expires,
    }
end

H.void = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local reason = shortText(data.reason, 120)
    local ok, err, detail = deps.admin.void(src, id, reason)
    return ok, err, deps.admin.voidAnswer(id, ok, err, true, detail), { detail = detail }
end

local DISPOSITIONS = { pay = true, ['return'] = true, delivered = true }

H.settle = function(src, data)
    local line = Util.toLineId(data.line)
    if not line then return false, CH.ERR.INVALID_INPUT, 'Give an escrow line id.' end
    local disposition = DISPOSITIONS[data.disposition] and data.disposition or nil
    if not disposition then
        return false, CH.ERR.INVALID_INPUT, 'Say pay, return or delivered.'
    end
    local extra
    if disposition == 'pay' and data.amount ~= nil then
        extra = wholeNumber(data.amount, 1, 1000000000)
        if not extra then
            return false, CH.ERR.INVALID_INPUT, 'An amount is a whole number of at least 1.'
        end
    elseif disposition == 'return' and data.owner ~= nil then
        -- Checked by the settle itself, as the command's is: in the form the
        -- server keeps it, and only one somebody here has
        -- (Admin.knownCitizenId).
        extra = Util.toCitizenId(data.owner)
        if not extra then return false, CH.ERR.INVALID_INPUT, 'That is not a citizen id.' end
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
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a review item id.' end
    local action = REVIEW_ACTIONS[data.action] and data.action or nil
    if not action then return false, CH.ERR.INVALID_INPUT, 'Say refund, pay, dismiss or finish.' end
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
                    return false, CH.ERR.INVALID_INPUT, 'An amount is a whole number of at least 1.'
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
    local canIdentify = identifies(src)
    local filter = {
        kind = VALID_KIND[data.kind] and data.kind or nil,
        action = shortText(data.action, 48),
        contract = data.contract ~= nil and Util.toId(data.contract) or nil,
        from = wholeNumber(data.from, 0),
        to = wholeNumber(data.to, 0),
    }
    if data.contract ~= nil and not filter.contract then
        return false, CH.ERR.INVALID_INPUT, 'That is not a contract id.'
    end
    if data.actor ~= nil then
        filter.actor = typedCitizenId(data.actor)
        if not filter.actor then return false, CH.ERR.INVALID_INPUT, 'That is not a citizen id.' end
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
                return false, CH.ERR.INVALID_INPUT, 'That page of the search has run out. Search again.'
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
    if not id then return nil, CH.ERR.INVALID_INPUT, 'That is not a party to a contract.' end
    local contract = deps.storage.readContract(id)
    if not contract then return nil, CH.ERR.NOT_FOUND, 'No contract has that id.' end
    local cid
    if role == 'target' then
        cid = contract.target_cid
    elseif role == 'client' then
        if contract.anon_creator == true and not canIdentify then
            return nil, CH.ERR.NOT_PARTICIPANT, 'The placer placed it anonymously: only staff with '
                .. 'the identity permission may look them up.'
        end
        cid = contract.creator_cid
    elseif role == 'op' and rest ~= '' then
        for _, hitman in ipairs(deps.storage.readHitmen(id) or {}) do
            if tostring(hitman.id) == rest then
                if hitman.anon == true and not canIdentify then
                    return nil, CH.ERR.NOT_PARTICIPANT, 'That operative took it anonymously: only '
                        .. 'staff with the identity permission may look them up.'
                end
                cid = hitman.hitman_cid
                break
            end
        end
    end
    if not cid then return nil, CH.ERR.NOT_FOUND, 'Nobody on that contract matches.' end
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
        return nil, CH.ERR.INVALID_INPUT, 'Give a player id, a citizen id or a name.'
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
        return nil, CH.ERR.NOT_FOUND, 'Nobody by that name is in the city or on a contract you may see.'
    end
    if #order > 1 then
        return nil, CH.ERR.INVALID_INPUT, ('%d people match that name: give more of it, or their '
            .. 'player id.'):format(#order)
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
            return nil, CH.ERR.NOT_FOUND, 'Nobody with that player id is online. Give their citizen id instead.'
        end
        return { cid = actor.cid, actor = actor }
    end
    if type(subject) ~= 'string' then
        return nil, CH.ERR.INVALID_INPUT, 'Give a player id, a citizen id or a name.'
    end
    local canIdentify = src ~= nil and identifies(src)
    if subject:sub(1, 9) == 'contract:' then return contractParty(subject:sub(1, 96), canIdentify) end
    local text = shortText(subject, 64)
    if not text then return nil, CH.ERR.INVALID_INPUT, 'Give a player id, a citizen id or a name.' end
    local cid = typedCitizenId(text)
    if cid then
        local actor = deps.identity.byCitizenId(cid)
        -- A word that names no character and nothing here is read as a name.
        if actor or deps.identity.characterExists(cid) ~= false
            or #(deps.storage.contractsInvolving(cid) or {}) > 0 then
            return { cid = cid, actor = actor, typed = true }
        end
        local named = byName(text, canIdentify)
        if named then return named end
        return { cid = cid, actor = nil, typed = true }
    end
    return byName(text, canIdentify)
end

--- What a write says when its lookup handle is not this staff member's,
--- has run out, or never was.
local STALE_LOOKUP = 'That lookup is out of date, so nothing was changed. Look them up again.'

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
        return nil, CH.ERR.INVALID_INPUT, 'Look the player up first, then act from their card: a change '
            .. 'names them by that lookup or by their exact citizen id, never by a name or a player id.'
    end
    return { cid = cid, actor = deps.identity.byCitizenId(cid), typed = true }
end

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
freezeView = function(cid, canIdentify)
    local row = deps.freeze and deps.freeze.of(cid)
    if not row then return nil end
    return { since = row.frozen_at, reason = row.reason, by = canIdentify and row.by_cid or nil }
end

--- One player: their contracts as /ch-contracts lists them, their record,
--- what they are owed, and the notices kept for their next login.
---
--- To staff who may not see who is behind an anonymous party, nothing here
--- counts what the player did anonymously, as /ch-contracts leaves those
--- contracts out. A line owed, a delivery pending and a notice kept are each
--- left out when they are on a contract the player was an anonymous party
--- to. The record is counters kept for the life of the character
--- (Progression.record), anonymous contracts in them and nothing to say
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
    local stats = canIdentify and deps.progression.record(cid) or nil

    -- Which of the contracts shown are on hold, by the same rule the list
    -- of contracts follows.
    if deps.freeze and (deps.freeze.count() > 0 or select(2, deps.freeze.count())) then
        for _, row in ipairs(contracts) do
            local contract = Storage.readContract(row.id)
            row.frozen = contract and frozenShown(contract, nil, canIdentify) ~= nil or nil
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
        return false, CH.ERR.NOT_FOUND, 'Nobody in the city has that citizen id, and nothing you may '
            .. 'see here names it. Check how it is spelt.'
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
        -- Whether staff have put them on hold (server/freeze.lua). Who did,
        -- a staff member's citizen id, only with IdentityAce.
        frozen = freezeView(cid, canIdentify),
        -- Whether staff have suspended them from contracts, or protect them
        -- from contracts (server/sanctions.lua), the same way.
        suspended = Panel.sanctionView('suspend', cid, canIdentify),
        protected = Panel.sanctionView('protect', cid, canIdentify),
        -- The most one manual payment may be now (Config.Staff), for Pay.
        payMax = deps.payments and deps.payments.max() or 0,
    }
end

--- Freezing and releasing a player (server/freeze.lua), from Players.
--- Writes, needing the ACE itself, as void and settle do; each is audited
--- by the freeze itself (freeze_player, unfreeze_player). Not IdentityAce:
--- staff name the player as they looked them up, and nothing here says
--- which contracts are theirs.

--- A handle for a frozen player's row in the list.
local function freezeRef(cid)
    local ref = freezeRefOf[cid]
    if not ref then
        freezeRefSeq = freezeRefSeq + 1
        ref = 'f' .. freezeRefSeq
        freezeRefOf[cid], freezeRefs[ref] = ref, cid
    end
    return ref
end

H.frozen = function(src)
    local canIdentify = identifies(src)
    local rows = {}
    for _, row in ipairs(deps.freeze and deps.freeze.list() or {}) do
        local actor = deps.identity.byCitizenId(row.cid)
        rows[#rows + 1] = {
            ref = freezeRef(row.cid), name = (actor and actor.name) or row.name,
            cid = canIdentify and row.cid or nil, online = actor ~= nil,
            since = row.frozen_at, reason = row.reason,
            by = canIdentify and row.by_cid or nil,
        }
    end
    return true, nil, nil, { rows = rows }
end

H.freeze = function(src, data)
    if not deps.freeze then return false, 'unavailable', 'Freezing is not available on this server.' end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local cid, actor = who.cid, who.actor
    if not actor and deps.identity.characterExists(cid) == false
        and #(deps.storage.contractsInvolving(cid) or {}) == 0 then
        return false, CH.ERR.NOT_FOUND, 'Nobody in the city has that citizen id, and no character '
            .. 'has it. Check how it is spelt.'
    end
    local name = actor and actor.name or (who.typed and cid) or nil
    local staffCid = staffOf(src)
    local ok, err = deps.freeze.freeze(staffCid, cid, reason, name)
    -- Kept for their history card too (server/sanctions.lua): the freeze's
    -- own row goes when it is lifted.
    if ok and deps.sanctions then pcall(deps.sanctions.noteFreeze, staffCid, cid, reason, name) end
    if not ok then
        if err == 'already_frozen' then return false, err, 'They are already frozen.' end
        if err == CH.ERR.BUSY then
            return false, err, 'A freeze or release of them is still being saved. Try again in a moment.'
        end
        return false, err, 'Not frozen: the store did not take it. Try again in a moment.'
    end
    return true, nil, ('%s is frozen. Every live contract they are party to is on hold until you '
        .. 'unfreeze them; nothing on those contracts moves meanwhile.')
        :format(name or 'They'), { frozen = freezeView(cid, identifies(src)) }
end

H.unfreeze = function(src, data)
    if not deps.freeze then return false, 'unavailable', 'Freezing is not available on this server.' end
    local cid
    -- A row of the frozen list ('f' handles), or the player looked up.
    if data.ref ~= nil and not (type(data.ref) == 'string' and data.ref:sub(1, 1) == 'p') then
        cid = type(data.ref) == 'string' and freezeRefs[data.ref:sub(1, 16)] or nil
        if not cid then return false, CH.ERR.NOT_FOUND, 'That row is gone. Refresh the list.' end
    else
        local who, whoErr, whoMessage = writeSubject(data, src)
        if not who then return false, whoErr, whoMessage end
        cid = who.cid
    end
    local staffCid = staffOf(src)
    local ok, err = deps.freeze.unfreeze(staffCid, cid, shortText(data.reason, 120))
    if ok and deps.sanctions then pcall(deps.sanctions.noteUnfreeze, staffCid, cid) end
    if not ok then
        if err == 'not_frozen' then return false, err, 'They are not frozen.' end
        if err == CH.ERR.BUSY then
            return false, err, 'A freeze or release of them is still being saved. Try again in a moment.'
        end
        return false, err, 'Not unfrozen: the store did not take it. Try again in a moment.'
    end
    return true, nil, 'Unfrozen. Their contracts run again, with the time on hold given back.'
end

--- Hours with one decimal, as staff read them.
local function hoursText(hours)
    local whole = math.floor(hours)
    if whole == hours then return tostring(whole) .. ' h' end
    return ('%.1f h'):format(hours)
end

--- Set or reset one character's counted playtime (Players, under the
--- lookup). A write: the ACE itself, the write allowance, and a row in the
--- log with what it was and what it is now. Not IdentityAce: staff name the
--- player as they looked them up, and nothing here says who they are.
H.setPlaytime = function(src, data)
    if not deps.playtime then
        return false, 'unavailable', 'Playtime is not counted on this server.'
    end
    local hours = tonumber(data.hours)
    if not hours or hours ~= hours or hours < 0 or hours > 100000 then
        return false, CH.ERR.INVALID_INPUT, 'Hours are a number from 0 to 100000.'
    end
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local cid, actor = who.cid, who.actor
    -- A citizen id typed that no character has: refused, not a row made for
    -- somebody who does not exist.
    if not actor and deps.identity.characterExists(cid) == false
        and not deps.playtime.view(cid).counted then
        return false, CH.ERR.NOT_FOUND, 'Nobody in the city has that citizen id, and no character '
            .. 'has it. Check how it is spelt.'
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
            'Not changed: their counted time could not be read from the store. Try again in a moment.'
    end
    local after = tenths / 10
    deps.audit.staff('admin_playtime_set', staffOf(src), nil,
        { subject = cid, hours = after, before = before, reset = seconds == 0 or nil })

    local view = playtimeView(cid, actor)
    local name = actor and actor.name or (who.typed and cid) or 'This character'
    local parts = {
        seconds == 0 and ('%s\'s counted playtime is reset to 0 h (it was %s).'):format(name, hoursText(before))
            or ('%s\'s counted playtime is now %s (it was %s).'):format(name, hoursText(after), hoursText(before)),
    }
    -- Grandfathered counts only where the tracker is what the rule reads
    -- (Identity.playtimeHours): an export or QBox metadata answering for
    -- them decides by its own hours, as /ch-diag says.
    local tracked = view and (view.from == nil or view.from == 'tracker')
    if tracked and view.grandfathered then
        parts[#parts + 1] = 'They are grandfathered (from before the tracker), so they count as having '
            .. 'played enough whatever their hours say.'
    end
    if view and view.from == 'provider' then
        parts[#parts + 1] = 'The playtime rule reads your playtime export for them, not these hours.'
    elseif view and view.from == 'metadata' then
        parts[#parts + 1] = 'The playtime rule reads their QBox metadata for them, not these hours.'
    end
    if not written then
        parts[#parts + 1] = 'The store did not take it yet; it is written with the next pass, within a minute.'
    end
    return true, nil, table.concat(parts, ' '), { playtime = view }
end

H.whois = function(src, data)
    local who, err = deps.admin.identify(src, data.id)
    if not who then
        return false, err, err == CH.ERR.NOT_FOUND and 'No contract has that id.' or 'Give a contract id.'
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
local SCHEMA_FIELDS = { 'group', 'label', 'about', 'category', 'money', 'shipped', 'hasShipped',
    'kind', 'choices', 'min', 'integer', 'live', 'inflight', 'readonly', 'destroys', 'stricter',
    'strict', 'whole', 'default' }

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
    if err == 'not_allowed' then return 'Not a setting the panel may change.' end
    if err == 'read_only' then return ('Not changed: %s'):format(tostring(why)) end
    if err == 'not_overridden' then return ('%s is what config.lua says already.'):format(key) end
    if err == CH.ERR.BUSY then
        return 'Not changed: another change to the settings is being saved. Try again in a moment.'
    end
    if err == 'store_failed' then
        return ('Not changed: the store would not take it (%s). Nothing changed.'):format(tostring(why))
    end
    if err == 'store_unknown' then
        return ('Not sure it was kept: the store raised (%s), and reading it back raised too, so it '
            .. 'may or may not hold the change; the diagnosis lists it. What was in force still is: '
            .. 'set it again once the store answers.'):format(tostring(why))
    end
    return ('Not changed: %s.'):format(tostring(why))
end

--- The start's warnings about a value, said with the change: they refuse
--- nothing, and were said nowhere, not at the next start either.
local function warned(detail)
    local lines = type(detail) == 'table' and detail.warnings or nil
    if type(lines) ~= 'table' or #lines == 0 then return '' end
    return ' Note: ' .. table.concat(lines, '. ') .. '.'
end

H.setSetting = function(src, data)
    local key = type(data.key) == 'string' and #data.key <= 64 and data.key or nil
    if not key then return false, CH.ERR.INVALID_INPUT, 'Name a setting.' end
    local cid, who = staffOf(src)
    local ok, err, detail = deps.settings.set(key, data.value, who, cid)
    if not ok then return false, err, settingRefusal(key, err, detail) end
    if detail.unchanged then
        return true, nil, ('%s is %s already; nothing changed.%s')
            :format(key, deps.settings.describe(detail.value), warned(detail)), detail
    end
    local entry = deps.settings.entry(key)
    return true, nil, ('%s is now %s%s.%s'):format(key, deps.settings.describe(detail.value),
        detail.source == 'config' and ' (what config.lua says)'
            or ((entry and entry.live == false) and '; applies after restart' or ''),
        warned(detail)), detail
end

H.resetSetting = function(src, data)
    local key = type(data.key) == 'string' and #data.key <= 64 and data.key or nil
    if not key then return false, CH.ERR.INVALID_INPUT, 'Name a setting.' end
    local cid, who = staffOf(src)
    local ok, err, detail = deps.settings.reset(key, who, cid)
    if not ok then return false, err, settingRefusal(key, err, detail) end
    if detail.removed then
        return true, nil, ('%s is out of the store; nothing in force changed.'):format(key), detail
    end
    return true, nil, ('%s is back to what config.lua says (%s).')
        :format(key, deps.settings.describe(detail.value)), detail
end

H.resetSettings = function(src)
    local cid, who = staffOf(src)
    local ok, err, detail = deps.settings.resetAll(who, cid)
    if not ok then return false, err, settingRefusal('every setting', err, detail) end
    return true, nil, ('Every setting is back to what config.lua says (%d were changed).')
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
    local subject = data.subject ~= nil and wholeNumber(data.subject, 1, 65535) or nil
    if data.subject ~= nil and not subject then
        return false, CH.ERR.INVALID_INPUT, 'Give a player id, or nothing to run it as yourself.'
    end
    -- The one check that waits for an answer (whether the public photo
    -- address leads here) says what it found after the report, pushed to
    -- the open panel; and so does the subject's own page log, a list.
    local lines = deps.admin.diagnose(src, subject, function(said)
        local list = type(said) == 'table' and said or { said }
        for i = 1, #list do
            Panel.push(src, { kind = 'diag', line = deps.admin.panelWords(list[i]) })
        end
    end, { panel = true })
    return true, nil, nil, { lines = lines }
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
    if not Alerts then return false, 'unavailable', 'Alerts are not running on this server yet.' end
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
                or (a.acknowledged_by ~= nil and 'a staff member' or nil),
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
    if not Alerts then return false, 'unavailable', 'Alerts are not running on this server yet.' end
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
    if #ids == 0 then return false, CH.ERR.INVALID_INPUT, 'Name the alerts to acknowledge.' end
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
        message = missing > 0 and already == 0 and 'Those alerts are gone: pruned since the list was read.'
            or 'Those alerts were acknowledged already; nothing changed.'
        return true, nil, message, { done = 0, already = already, missing = missing }
    end
    message = ('Acknowledged %d alert(s).'):format(done)
    if already > 0 then message = message .. (' %d were acknowledged already.'):format(already) end
    return true, nil, message, { done = done, already = already, missing = missing }
end

--- Put a test alert in the next post to Discord. A write, on the record,
--- whether it went or not.
H.testAlert = function(src)
    local Alerts = deps.alerts
    if not Alerts then return false, 'unavailable', 'Alerts are not running on this server yet.' end
    local queued, err, seconds = Alerts.sendTest()
    deps.audit.staff('admin_alert_test', staffOf(src), nil, { queued = queued, why = err })
    if err == 'discord_off' then
        return false, err, 'Not sent: posting alerts to Discord is switched off (Alerts.ToDiscord, '
            .. 'under Features).'
    end
    if err == 'no_webhook' then
        return false, err, 'Not sent: no webhook is set. Add set crimson_hitman_alert_webhook '
            .. '"<your webhook>" to server.cfg (set, never setr), or run it in the server console, '
            .. 'and send the test again.'
    end
    return true, nil, ('A test alert goes to Discord in about %d second(s). This section says '
        .. 'whether it went through.'):format(math.max(0, seconds or 0)), { seconds = seconds }
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
        return 'No kill photos are kept from before; nothing to remove.'
    end
    local parts = {}
    if done.removed > 0 then
        parts[#parts + 1] = ('Removed %d kill photo(s).'):format(done.removed)
    else
        parts[#parts + 1] = 'Nothing removed yet.'
    end
    if done.files > 0 then
        parts[#parts + 1] = ('%d file(s) deleted from this server.'):format(done.files)
    end
    if done.links > 0 then
        parts[#parts + 1] = ('%d were on lb-phone\'s image host: this server has forgotten them, '
            .. 'and the pictures stay on the host.'):format(done.links)
    end
    if done.left > 0 then
        parts[#parts + 1] = ('%d file(s) could not be deleted: delete what is left in '
            .. 'data/photos/ by hand.'):format(done.left)
    end
    if done.waiting > 0 then
        parts[#parts + 1] = ('%d open on a phone right now: each is removed when that view '
            .. 'closes.'):format(done.waiting)
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
        return false, 'photos_on', 'Not removed: kill photos are on (Completion.KillPhotos). '
            .. 'This removes the ones kept from before they were turned off, so turn them off first.'
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
        unsaved = ', but the store did not save'
            .. (file and (': ' .. file .. ' could not be written') or '')
    end
    return true, nil, ('Audit log flushed: %d row(s) written%s.')
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
    if not canIdentify then return 'Staff' end
    if row.author_name and row.author_cid then return ('%s (%s)'):format(row.author_name, row.author_cid) end
    return tostring(row.author_name or row.author_cid or 'Staff')
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
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    if type(data.text) ~= 'string' then return false, CH.ERR.INVALID_INPUT, 'Write the note.' end
    local ok, err, detail = deps.staffContract.addNote(staffRecordOf(src), id, data.text:sub(1, 4000))
    if not ok then
        if err == 'empty' then return false, CH.ERR.INVALID_INPUT, 'Write the note.' end
        if err == 'too_long' then
            return false, CH.ERR.INVALID_INPUT, ('A note is at most %d characters.')
                :format(detail.max)
        end
        if err == 'too_many' then
            return false, err, ('This contract holds %d notes already, the most one may.')
                :format(detail.max)
        end
        if err == CH.ERR.NOT_FOUND then return false, err, 'No contract has that id.' end
        return false, err, 'Not added: the store did not take it. Try again in a moment.'
    end
    return true, nil, 'Note added.', { id = detail.id }
end

--- What a refusal of a player's text says, by the rule it broke.
local function textRefusal(rule)
    if rule == 'length' then
        return ('At most %d characters (Config.Reason.MaxLength).'):format(tonumber(Config.Reason.MaxLength) or 0)
    end
    if rule == 'digits' then
        return ('At most %d digits (Config.Reason.MaxDigits).'):format(tonumber(Config.Reason.MaxDigits) or 0)
    end
    if rule == 'pattern' then
        return 'It holds something players may not write (Config.Reason.PatternDenylist): a link, an '
            .. 'invite or a handle.'
    end
    if rule == 'phone' then return 'lb-phone\'s word blacklist refuses something in it.' end
    if rule == 'preset' then
        return 'This server uses preset reasons (Config.Reason.Mode): pick one of them.'
    end
    return 'Type the new text.'
end

--- Replace what a player wrote on a contract (its reason) through the same
--- checks a player's text gets, with a reason for the edit. The original
--- stays in the log (staff_text_edit); players see the new text marked
--- 'edited by staff'.
H.editText = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local field = data.field == nil and 'reason' or data.field
    if type(field) ~= 'string' or not deps.staffContract.FIELDS[field] then
        return false, CH.ERR.INVALID_INPUT, 'Only a contract\'s reason is text a player wrote on it.'
    end
    if type(data.text) ~= 'string' then return false, CH.ERR.INVALID_INPUT, 'Type the new text.' end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end
    local ok, err, detail = deps.staffContract.editText(staffRecordOf(src), id, field,
        data.text:sub(1, 4000), reason)
    if not ok then
        if err == CH.ERR.REASON_REFUSED then
            return false, err, 'Not replaced. ' .. textRefusal(type(detail) == 'table' and detail.rule or nil)
        end
        if err == CH.ERR.NOT_FOUND then return false, err, 'No contract has that id.' end
        if err == 'unchanged' then return false, err, 'That is what it says already.' end
        if err == 'no_text' then
            return false, err, 'This server keeps no reason on a contract (Config.Reason.Mode is off).'
        end
        if err == CH.ERR.BUSY then
            return false, err, 'Something else was changing this contract. Try again in a moment.'
        end
        return false, err, 'Not replaced: the store did not take it. Try again in a moment.'
    end
    return true, nil, 'Reason replaced. Players see the new text, marked "edited by staff"; '
        .. 'the original is kept in the log.', { new = detail.new }
end

--- Take one operative off a live contract without ending it for anybody
--- else, with a reason; optionally barred from taking it again, and their
--- stake given back instead of handed to the client as a walk-away hands it.
H.removeHitman = function(src, data)
    local id = Util.toId(data.id)
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local hitman = Util.toId(data.hitman)
    if not hitman then return false, CH.ERR.INVALID_INPUT, 'Pick the operative to remove.' end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end
    local ok, err, detail = deps.staffContract.removeHitman(staffRecordOf(src), id, hitman, reason,
        { block = data.block == true, returnStake = data.returnStake == true })
    if not ok then
        if err == CH.ERR.NOT_FOUND then return false, err, 'No contract has that id.' end
        if err == CH.ERR.BAD_STATE then
            return false, err, 'Only a live contract (active or accepted) has operatives to remove.'
        end
        if err == CH.ERR.CONTRACT_FROZEN then
            -- Said as on hold only where this staff member's view of it says
            -- so (frozenShown): held through an anonymous party they may not
            -- see, the refusal says no more than the view does.
            local contract = deps.storage.readContract(id)
            if not contract or not frozenShown(contract, nil, identifies(src)) then
                return false, 'not_removed', 'Not removed: try again in a moment.'
            end
            return false, err, 'It is on hold by staff, and nothing on it moves: unfreeze first.'
        end
        if err == 'no_operative' then return false, err, 'No operative on this contract has that id.' end
        if err == 'not_active' or err == CH.ERR.NOT_PARTICIPANT then
            return false, err, 'That operative is no longer on it.'
        end
        if err == CH.ERR.ALREADY_SETTLED then return false, err, 'It ended meanwhile.' end
        return false, err, 'Not removed: try again in a moment.'
    end
    local stake = ''
    if (detail.returned or 0) > 0 then
        stake = (' Their $%d stake went back to them.'):format(detail.returned)
    elseif (detail.forfeited or 0) > 0 then
        stake = (' Their $%d stake went to the placer, as a walk-away hands it over.'):format(detail.forfeited)
    end
    return true, nil, ('%s taken off the contract.%s%s They were told "%s"; the placer was told an '
        .. 'operative left, as a walk-away says it.'):format(tostring(detail.alias or 'The operative'), stake,
            detail.blocked and ' They may not take it again.' or '', deps.staffContract.REMOVED_TEXT),
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
    add(('Contract %s'):format(tostring(c.id)))
    add('Exported: ' .. stamp(os.time()))
    if c.neverStored then
        add('Never stored: escrow under this id has no contract record.')
    else
        add(('State: %s | Mode: %s | Completes by: %s'):format(tostring(c.state), tostring(c.mode),
            tostring(c.rule)))
        add('Reason: ' .. tostring(c.reason or '-')
            .. ((staff.text and staff.text.edited) and ' (edited by staff)' or ''))
        add('Client: ' .. person(c.client) .. (c.anonymous and ' (anonymous)' or ''))
        add('Target: ' .. person(c.target) .. (c.target_protected and ' (whitelisted job)' or ''))
        add(('Placed: %s | Deadline: %s | Expires: %s'):format(stamp(c.created_at), stamp(c.deadline_at),
            stamp(c.expires_at)))
        add('Ended: ' .. (c.resolved_at and (tostring(c.resolution or '') .. ' ' .. stamp(c.resolved_at))
            or 'not yet'))
        add(('Payouts: %s of %s claimed | Bonus: %s%% | Stake: $%s | Buyout price: $%s%s'):format(
            tostring(c.claimed or 0), tostring(c.slots or 1), tostring(c.bonus_percent or 0),
            tostring(c.penalty_amount or 0), tostring(c.bailout_amount or 0),
            c.buyout_queued and ' (a buyout is queued)' or ''))
    end
    add('')
    add('Operatives:')
    if #(view.hitmen or {}) == 0 then add('- none') end
    for _, m in ipairs(view.hitmen or {}) do
        add(('- %s | %s%s | %s | accepted %s | left %s | claims %s | stake $%s'):format(
            tostring(m.alias or '-'), tostring(m.name or '-'), m.cid and (' [' .. m.cid .. ']') or '',
            tostring(m.state), stamp(m.accepted_at), stamp(m.left_at), tostring(m.claims or 0),
            tostring(m.stake or 0)))
    end
    add('')
    add('Payments (escrow lines):')
    if #(view.escrow or {}) == 0 then add('- none') end
    for _, line in ipairs(view.escrow or {}) do
        local to = line.owed_to or line.releasing_to or line.settled_to
        add(('- %s | payout %s %s | %s | %s%s%s'):format(tostring(line.id), tostring(line.slot or '-'),
            tostring(line.portion or '-'), holdsText(line), tostring(line.state),
            to and (' | to ' .. tostring(to)) or '',
            line.settled_at and (' | settled ' .. stamp(line.settled_at)) or ''))
    end
    add('')
    add('Open proposals:')
    if #(view.amendments or {}) == 0 then add('- none') end
    for _, a in ipairs(view.amendments or {}) do
        add(('- %s by %s | runs out %s | %s'):format(tostring(a.kind), tostring(a.proposer or '-'),
            stamp(a.expires_at), flat(a.payload or {})))
    end
    add('')
    add('Staff notes:')
    if #(staff.notes or {}) == 0 then add('- none') end
    for _, note in ipairs(staff.notes or {}) do
        add(('- %s | %s | %s'):format(stamp(note.at), tostring(note.by), tostring(note.text)))
    end
    add('')
    add('Timeline (oldest first: states, amendments, payments and staff actions):')
    if #(view.timeline or {}) == 0 then add('- the log keeps nothing for it') end
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
    if not id then return false, CH.ERR.INVALID_INPUT, 'Give a contract id.' end
    local role = type(data.role) == 'string' and data.role or nil
    if not role or not VIEW_ROLES[role] then
        return false, CH.ERR.INVALID_INPUT, 'Pick whose view: the target, the placer or an operative.'
    end
    local Storage = deps.storage
    local contract = Storage.readContract(id)
    if not contract then return false, CH.ERR.NOT_FOUND, 'No contract has that id.' end
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
        if not operative then return false, CH.ERR.INVALID_INPUT, 'Pick one of its operatives.' end
        viewerCid = operative.hitman_cid
    end

    local shown, note, view, whitelisted = true, nil, nil, nil
    if CH.TERMINAL[contract.state] then
        shown, note = false, 'Closed: it is off their phone (only their history keeps it).'
    elseif role == 'target' and not deps.notify.shownToTarget(contract) then
        shown, note = false, 'Not shown to the target yet: their On me tab lists it once the alert\'s '
            .. 'wait is over.'
    else
        view = deps.projection.contract(contract, viewerCid, { peek = true })
        if role == 'target' then
            -- As On me sends it: never the roster.
            if view then view.hitmen = nil end
            if contract.target_protected == true then
                whitelisted = deps.projection.whitelistedListing(contract, viewerCid, nil)
                note = 'Recorded on a whitelisted job: while they work one they see the whitelisted-job '
                    .. 'view instead, below.'
            end
        elseif role == 'hitman' and operative.state ~= 'active' then
            note = ('No longer on it (%s): this is the card the board would show them.')
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

--- A suspension or a protection on a player as the panel shows it, or nil.
--- Who set it, a staff member's citizen id, only with IdentityAce.
---@param kind string 'suspend' | 'protect'
---@param cid string
---@param canIdentify boolean
---@return table|nil
function Panel.sanctionView(kind, cid, canIdentify)
    local Sanctions = deps and deps.sanctions
    if not Sanctions then return nil end
    local row
    if kind == 'suspend' then row = Sanctions.suspended(cid) else row = Sanctions.protected(cid) end
    if not row then return nil end
    return { since = row.created_at, ['until'] = row.until_at, reason = row.reason,
             by = canIdentify and row.by_cid or nil }
end

--- The player a staff action names, as the freeze takes one: the lookup's
--- handle or an exact citizen id (writeSubject), and refused for a citizen
--- id no character has and nothing here names. nil, the error and what to
--- say otherwise.
local function actionSubject(data, src)
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return nil, whoErr, whoMessage end
    if not who.actor and deps.identity.characterExists(who.cid) == false
        and #(deps.storage.contractsInvolving(who.cid) or {}) == 0 then
        return nil, CH.ERR.NOT_FOUND, 'Nobody in the city has that citizen id, and no character '
            .. 'has it. Check how it is spelt.'
    end
    who.name = who.actor and who.actor.name or (who.typed and who.cid) or nil
    return who
end

--- A span in words: days where it is whole days, otherwise hours.
local function spanWords(seconds)
    if seconds % 86400 == 0 then
        local days = seconds // 86400
        return days == 1 and '1 day' or (days .. ' days')
    end
    local hours = seconds // 3600
    return hours == 1 and '1 hour' or (hours .. ' hours')
end

--- What a refused suspension or protection says.
local function sanctionRefusal(err, already, missing)
    if err == 'already' then return false, err, already end
    if err == 'not_active' then return false, err, missing end
    if err == CH.ERR.BUSY then
        return false, err, 'A change to them is still being saved. Try again in a moment.'
    end
    if err == CH.ERR.INVALID_INPUT then return false, err, 'The server could not read that request.' end
    return false, err, 'Not changed: the store did not take it. Try again in a moment.'
end

--- One player's history (server/history.lua): read-only, and scrubbed as
--- the player view is for staff without IdentityAce.
H.history = function(src, data)
    if not deps.history then return false, 'unavailable', 'The history card is not available here.' end
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
    if not Sanctions then return false, 'unavailable', 'Suspensions are not available on this server.' end
    local reason = shortText(data.reason, 120)
    if not reason then
        return false, CH.ERR.INVALID_INPUT, 'Give a reason: the player is shown it, and it goes on the record.'
    end
    local days = wholeNumber(data.days, 0, Sanctions.MAX_SUSPEND_DAYS)
    if not days then
        return false, CH.ERR.INVALID_INPUT, ('Days are a whole number from 1 to %d, or 0 for until you '
            .. 'lift it.'):format(Sanctions.MAX_SUSPEND_DAYS)
    end
    local who, whoErr, whoMessage = actionSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Sanctions.place('suspend', staffOf(src), who.cid, days > 0 and days * 86400 or nil,
        reason, who.name)
    if not ok then
        return sanctionRefusal(err, 'They are suspended already. Lift it first to set another.')
    end
    return true, nil, ('%s is suspended from placing and accepting contracts %s. Their live '
        .. 'contracts are not touched: freeze them for that.')
        :format(who.name or 'They', days > 0 and ('for ' .. spanWords(days * 86400)) or 'until you lift it'),
        { suspended = Panel.sanctionView('suspend', who.cid, identifies(src)) }
end

H.unsuspend = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', 'Suspensions are not available on this server.' end
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Sanctions.lift('suspend', staffOf(src), who.cid, shortText(data.reason, 120))
    if not ok then return sanctionRefusal(err, nil, 'They are not suspended.') end
    return true, nil, 'Suspension lifted. They may place and accept contracts again.'
end

--- Protect a player from new contracts: { subject, hours (0 for good),
--- reason }. Contracts already on them are not touched.
H.protect = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', 'Protection is not available on this server.' end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end
    local hours = wholeNumber(data.hours, 0, Sanctions.MAX_PROTECT_HOURS)
    if not hours then
        return false, CH.ERR.INVALID_INPUT, ('Hours are a whole number from 1 to %d, or 0 for good.')
            :format(Sanctions.MAX_PROTECT_HOURS)
    end
    local who, whoErr, whoMessage = actionSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Sanctions.place('protect', staffOf(src), who.cid, hours > 0 and hours * 3600 or nil,
        reason, who.name)
    if not ok then
        return sanctionRefusal(err, 'They are protected already. Lift it first to set another.')
    end
    return true, nil, ('%s is protected from new contracts %s. Contracts already on them run on: '
        .. 'freeze them to put those on hold.')
        :format(who.name or 'They', hours > 0 and ('for ' .. spanWords(hours * 3600)) or 'for good'),
        { protected = Panel.sanctionView('protect', who.cid, identifies(src)) }
end

H.unprotect = function(src, data)
    local Sanctions = deps.sanctions
    if not Sanctions then return false, 'unavailable', 'Protection is not available on this server.' end
    local who, whoErr, whoMessage = writeSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, err = Sanctions.lift('protect', staffOf(src), who.cid, shortText(data.reason, 120))
    if not ok then return sanctionRefusal(err, nil, 'They are not protected.') end
    return true, nil, 'Protection lifted. New contracts may name them again.'
end

--- Pay a player by hand: { subject, amount, account ('cash' | 'bank'),
--- reason }. At most Config.Staff.ManualPaymentMax; paid now, or owed at
--- their next login (server/payments.lua). Audited as staff_manual_payment.
H.manualPay = function(src, data)
    local Payments = deps.payments
    if not Payments then return false, 'unavailable', 'Manual payments are not available on this server.' end
    local max = Payments.max()
    if max <= 0 then
        return false, 'payments_off', 'Manual payments are off (Config.Staff.ManualPaymentMax is 0).'
    end
    local reason = shortText(data.reason, 120)
    if not reason then return false, CH.ERR.INVALID_INPUT, 'Give a reason: it goes on the record.' end
    local account = (data.account == 'cash' or data.account == 'bank') and data.account or nil
    if not account then return false, CH.ERR.INVALID_INPUT, 'Pay in cash or bank.' end
    local amount = wholeNumber(data.amount, 1)
    if not amount then return false, CH.ERR.INVALID_INPUT, 'The amount is a whole number of dollars.' end
    if amount > max then
        return false, 'over_max', ('Not paid: $%d is over the most one payment may be, $%d '
            .. '(Config.Staff.ManualPaymentMax).'):format(amount, max)
    end
    local who, whoErr, whoMessage = actionSubject(data, src)
    if not who then return false, whoErr, whoMessage end
    local ok, result = Payments.pay(staffOf(src), who.cid, amount, account, reason, who.name)
    if not ok then
        if result == CH.ERR.BUSY then
            return false, result, 'A payment to them is still being made. Try again in a moment.'
        end
        return false, result, 'Not paid: the server could not pay or owe it. The log says why.'
    end
    local whom = who.name or 'them'
    if result.paid then
        return true, nil, ('Paid $%d in %s to %s.'):format(amount, account, whom),
            { paid = true, owed = false }
    end
    return true, nil, ('$%d in %s is owed to %s, handed over at their next login or once they have '
        .. 'room.'):format(amount, account, whom), { paid = false, owed = true }
end

--------------------------------------------------------------------------
-- Staff tools: the notice to every hitman, and the settings history
--------------------------------------------------------------------------

--- Send one phone notice, from 'Staff', to every player holding a contract
--- or every player online the app is open to (server/announce.lua). A
--- write: the ACE itself and the write allowance; the page asks twice.
--- On the record as staff_announce, by the module.
H.announce = function(src, data)
    if not deps.announce then return false, 'unavailable', 'Announcements are not running on this server.' end
    if data.text ~= nil and type(data.text) ~= 'string' then
        return false, CH.ERR.INVALID_INPUT, 'Write the notice.'
    end
    local scope = data.scope
    if scope ~= nil and scope ~= 'active' and scope ~= 'online' then
        return false, CH.ERR.INVALID_INPUT, 'Send it to every hitman, or to everybody online with the app.'
    end
    local ok, err, detail = deps.announce.send(staffOf(src), data.text, scope)
    if not ok then
        local rule = detail and detail.rule
        if rule == 'length' then
            return false, err, ('Not sent: at most %d characters.'):format(deps.announce.MAX)
        elseif rule == 'pattern' then
            return false, err, 'Not sent: no links, invites or handles in a notice to players.'
        end
        return false, err, 'Not sent: write the notice first.'
    end
    local who = detail.scope == 'online' and 'player(s) online with the app' or 'hitman/hitmen holding a contract'
    if detail.sent == 0 then
        return true, nil, ('Nobody to send it to: no %s right now. It is on the record all the same.')
            :format(detail.scope == 'online' and 'player online with the app' or 'hitman holding a contract'),
            detail
    end
    return true, nil, ('Sent to %d %s, from Staff.'):format(detail.sent, who), detail
end

--- The handles the history gives its rows, so Undo names a change without
--- the page holding the value it puts back: [ref] = { key, value }. Kept
--- for the life of the process, at most HISTORY_REFS_MAX.
local historyRefs, historyRefSeq, historyRefCount = {}, 0, 0
local HISTORY_REFS_MAX = 5000

local function historyRef(key, value)
    if historyRefCount >= HISTORY_REFS_MAX then historyRefs, historyRefCount = {}, 0 end
    historyRefSeq = historyRefSeq + 1
    historyRefCount = historyRefCount + 1
    local ref = 'h' .. historyRefSeq
    historyRefs[ref] = { key = key, value = value }
    return ref
end

--- Every setting change, newest first, a page at a time: who, when, the
--- key and its value before and after (Settings.history). Read by every
--- staff member who may read the settings; the Developer section's own
--- keys only by staff who may open it, as the settings list shows them. A
--- secret's values are never shown. Who made a change is their citizen id
--- with IdentityAce, and 'a staff member' without it.
H.settingsHistory = function(src, data)
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
                by = canIdentify and (row.actor or row.by) or 'a staff member',
                ref = (row.undoable and canUndo) and historyRef(row.key, row.old) or nil,
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
    if not held then return false, CH.ERR.NOT_FOUND, 'That row is gone. Refresh the history.' end
    local key = held.key
    if developerKey(key) and not developer(src) then
        return false, 'developer_required', deps.admin.howToAuthorise(developerAce(), true)
    end
    local cid, who = staffOf(src)
    local ok, err, detail = deps.settings.set(key, held.value, who, cid)
    if not ok then return false, err, settingRefusal(key, err, detail) end
    deps.audit.staff('admin_undo_setting', cid, nil,
        { key = key, to = detail.value, from = detail.old, unchanged = detail.unchanged or nil })
    if detail.unchanged then
        return true, nil, ('%s is %s already; nothing changed.')
            :format(key, deps.settings.describe(detail.value)), detail
    end
    return true, nil, ('Undone: %s is %s again (it was %s).'):format(key,
        deps.settings.describe(detail.value), deps.settings.describe(detail.old)), detail
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
        return answer(false, 'admin_off', 'The staff tools are switched off (Config.Admin.Enabled).')
    end

    -- Permission, before anything about the request is looked at. An op
    -- nobody knows is checked as a read, so it answers the same as any
    -- other to somebody who may not read.
    local level = (op and OPS[op]) or READ
    local byDeveloper = level == WRITE and type(payload) == 'table' and not allowed(src, WRITE)
        and developerWrite(src, op, payload.data)
    if not byDeveloper
        and not allowed(src, (level == IDENTITY or level == DEVELOPER) and READ or level) then
        noteDenied(src, op, 'denied')
        local why = ''
        if level == MOD then
            why = (' Freezing, suspending, protecting, voiding and moving a deadline need that ACE '
                .. 'itself or the moderator ACE (%s); the extra ACEs only read.')
                :format(tostring(moderatorAce() or 'Config.Admin.ModeratorAce'))
        elseif level == WRITE then
            why = ' Changing anything else needs that ACE itself; the moderator ACE only freezes, '
                .. 'suspends, protects, voids and moves deadlines, and the extra ACEs only read.'
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
        return answer(false, 'identity_required', ('Unmasking needs %s, a separate ACE.')
            :format(tostring(Config.Admin.IdentityAce)))
    end

    -- Per staff member's source, and once more for anything that writes.
    local key = 'panel:' .. tostring(src)
    local writes = level == WRITE or level == MOD
    for _, bucket in ipairs(writes and { 'admin', 'adminWrite' } or { 'admin' }) do
        if not deps.ratelimit.check(key, bucket) then
            local wait = deps.ratelimit.retryAfter(key, bucket) or 0
            return answer(false, CH.ERR.RATE_LIMITED,
                wait > 0 and ('Slow down. Try again in %d second(s).'):format(wait) or 'Slow down.',
                { retryAfter = wait })
        end
    end

    if not op or not OPS[op] then
        return answer(false, 'unknown_op', 'The page asked for something this server does not do.')
    end
    local data = type(payload.data) == 'table' and payload.data or {}

    if WAITS_FOR_RECOVERY[op] then
        local waiting = deps.admin.recovery()
        if waiting then return answer(false, waiting, deps.admin.notRecovered()) end
    end

    local ran, ok, err, message, result = pcall(H[op], src, data)
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
            'That raised an error on the server. Run the diagnosis, under Tools, to read it.')
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
