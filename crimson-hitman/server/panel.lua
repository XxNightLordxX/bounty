--- The admin panel's server side (/hitmanadmin, Config.Admin.Commands.panel).
---
--- The page (ui/admin.html) asks for everything through one net event,
--- crimson-hitman:admin, with an `op` and its `data`, and is answered on
--- crimson-hitman:adminResult (README, Integration Guide, has every shape).
--- Nothing the page sends is trusted, and nothing the client says about
--- who is asking is either: every request runs, in this order,
---
---   1. the engine's source, above zero;
---   2. the ACE check, again, every time (Admin.allowed): reading needs
---      Config.Admin.Ace or one of ExtraAces, as the read-only commands do;
---      anything that writes needs Ace itself; unmasking needs IdentityAce;
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

local READ, WRITE, IDENTITY = 'read', 'write', 'identity'

--- Every request the page may make, and what it needs.
local OPS = {
    access = READ, overview = READ, contracts = READ, contract = READ, reviews = READ,
    logs = READ, player = READ, settings = READ, diag = READ, stuck = READ, alerts = READ,
    console = READ,
    void = WRITE, settle = WRITE, resolve = WRITE, setSetting = WRITE, resetSetting = WRITE,
    resetSettings = WRITE, refresh = WRITE, flush = WRITE, ackAlerts = WRITE, testAlert = WRITE,
    removePhotos = WRITE,
    whois = IDENTITY,
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
    void      = { ops = { 'void' }, level = WRITE, confirm = true, audit = 'admin_void',
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
Panel.LEVELS = { READ = READ, WRITE = WRITE, IDENTITY = IDENTITY }
Panel.OPS = OPS

--- Writes that wait for boot recovery, as the commands do. Flushing the
--- log is not one: it moves nothing, and is how the log reaches the disk
--- after a recovery that failed.
local WAITS_FOR_RECOVERY = {
    void = true, settle = true, resolve = true, setSetting = true, resetSetting = true,
    resetSettings = true, refresh = true,
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

function Panel.init(d)
    deps = d
    overviewCache, contractsCache = nil, nil
    deniedLogged = {}
end

--- Every contract the store keeps, read at most once per OVERVIEW_SECONDS.
---@return table[]
local function everyContract()
    local now = os.time()
    if not contractsCache or now - contractsCache.at >= OVERVIEW_SECONDS then
        contractsCache = { at = now, rows = deps.storage.allContracts() or {} }
    end
    return contractsCache.rows
end

--------------------------------------------------------------------------
-- Who is asking
--------------------------------------------------------------------------

--- Whether a source may make a request at a level.
---@param src number
---@param level string READ | WRITE | IDENTITY
---@return boolean
local function allowed(src, level)
    local Admin = deps.admin
    if level == WRITE then return Admin.allowed(src, Config.Admin.Ace, true) end
    if not Admin.allowed(src, Config.Admin.Ace) then return false end
    if level == IDENTITY then return Admin.allowed(src, Config.Admin.IdentityAce, true) end
    return true
end

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
local function accessFor(src)
    local okVersion, version = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
    return {
        canWrite = allowed(src, WRITE),
        canIdentify = identifies(src),
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
        { write = access.canWrite or nil, identify = access.canIdentify or nil })
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
        if contract.creator_cid then labels[contract.creator_cid] = 'the client' end
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
        if contract and contract.creator_name then names[contract.creator_name] = 'the client' end
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
}
local IDENTITY_ONLY_SHOWN = '(identity only)'

--- One audit row, as the panel shows it.
local function rowView(row, r)
    local detail = r.value(nil, row.detail or {})
    local hidden = not r.canIdentify and IDENTITY_ONLY[row.action]
    if hidden then
        for key in pairs(hidden) do
            if detail[key] ~= nil then detail[key] = IDENTITY_ONLY_SHOWN end
        end
    end
    return {
        ts = row.ts, kind = row.kind, action = row.action, contract = row.contract_id,
        actor = r.who(row.actor_cid), detail = detail,
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
    return out
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------

--- One function per op: (src, data) -> ok, err, message, data.
local H = {}

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
        for _, contract in ipairs(Storage.contractsInvolving(cid) or {}) do
            local visible
            if contract.target_cid == cid then
                visible = true
            elseif contract.creator_cid == cid then
                visible = canIdentify or contract.anon_creator ~= true
            else
                local hitman = Storage.readHitman(contract.id, cid)
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
    table.sort(matched, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then
            return (a.created_at or 0) > (b.created_at or 0)
        end
        return tostring(a.id) > tostring(b.id)
    end)

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
H.contract = function(src, data)
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
        deps.audit.staff(canIdentify and 'admin_panel_contract_identified' or 'admin_panel_contract',
            staffOf(src), id, { never_stored = true })
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

    deps.audit.staff(canIdentify and 'admin_panel_contract_identified' or 'admin_panel_contract',
        staffOf(src), id, {})

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

--- The audit log, newest first, a page at a time (Storage.queryAudit). By
--- a citizen id only for staff with IdentityAce: the rows a player acted in
--- include the ones they acted in anonymously.
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
        if not canIdentify then
            return false, 'identity_required', ('Finding a player\'s rows needs %s.')
                :format(tostring(Config.Admin.IdentityAce))
        end
        filter.actor = typedCitizenId(data.actor)
        if not filter.actor then return false, CH.ERR.INVALID_INPUT, 'That is not a citizen id.' end
    end
    local limit = math.min(LOG_ROWS_MAX, wholeNumber(data.limit, 1, LOG_ROWS_MAX) or pageSize())
    local cursor = wholeNumber(data.cursor, 0)

    -- The queue first, so the newest rows are there to read.
    deps.audit.flush()
    local rows, next_ = deps.storage.queryAudit(filter, cursor, limit)
    local parties = partiesReader()
    local out = {}
    for _, row in ipairs(rows or {}) do
        local contract, hitmen = parties(row.contract_id)
        out[#out + 1] = rowView(row, redactor(canIdentify, contract, hitmen))
    end
    if canIdentify then
        deps.audit.staff('admin_panel_logs_identified', staffOf(src), filter.contract,
            { actor = filter.actor, rows = #out })
    end
    return true, nil, nil, { rows = out, next = next_ }
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
    local subject = data.subject
    local cid, actor, typedCid
    local serverId = (type(subject) == 'number' or (type(subject) == 'string'
        and subject:match('^%d+$') and #subject <= 6)) and wholeNumber(subject, 1, 65535) or nil
    if serverId then
        actor = deps.identity.resolve(serverId)
        if not actor then
            return false, CH.ERR.NOT_FOUND, 'Nobody with that player id is online. Give their citizen id instead.'
        end
        cid = actor.cid
    else
        cid = typedCitizenId(subject)
        if not cid then return false, CH.ERR.INVALID_INPUT, 'Give a player id or a citizen id.' end
        typedCid = true
        actor = deps.identity.byCitizenId(cid)
    end

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
        },
        contracts = contracts,
        stats = stats,
        owed = owed, pending = pending,
        notices = { count = notices, titles = titles },
    }
end

H.whois = function(src, data)
    local who, err = deps.admin.identify(src, data.id)
    if not who then
        return false, err, err == CH.ERR.NOT_FOUND and 'No contract has that id.' or 'Give a contract id.'
    end
    return true, nil, nil, who
end

H.settings = function()
    local view = deps.settings.view()
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
--- command's name put as the panel's own place for it.
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
            acknowledged_by = a.acknowledged_by, acknowledged_at = a.acknowledged_at,
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
-- The one way in
--------------------------------------------------------------------------

--- Note a refusal once per window per source.
local function noteDenied(src, op, why)
    local now = Util.monotonicMs()
    local last = deniedLogged[src]
    if last and now - last < DENIED_LOG_MS then return end
    deniedLogged[src] = now
    deps.audit.rejected('admin_panel_' .. why, nil, nil,
        { source = src, op = type(op) == 'string' and op:sub(1, 32) or nil })
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
        and payload.op:sub(1, 32) or nil
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
    if not allowed(src, level == IDENTITY and READ or level) then
        noteDenied(src, op, 'denied')
        return answer(false, 'not_allowed', deps.admin.howToAuthorise(Config.Admin.Ace, true)
            .. (level == WRITE
                and ' Changing anything needs that ACE itself; the extra ACEs only read.' or ''))
    end
    if level == IDENTITY and not identifies(src) then
        noteDenied(src, op, 'identity_denied')
        return answer(false, 'identity_required', ('Unmasking needs %s, a separate ACE.')
            :format(tostring(Config.Admin.IdentityAce)))
    end

    -- Per staff member's source, and once more for anything that writes.
    local key = 'panel:' .. tostring(src)
    for _, bucket in ipairs(level == WRITE and { 'admin', 'adminWrite' } or { 'admin' }) do
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
        local say = level == WRITE and Log.always or Log.debug
        say(('the admin panel\'s %s raised: %s'):format(op, tostring(ok)))
    end
    if level == WRITE then
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

--- Send a reply to the page's client: as a latent event when it is large.
---@param src number
---@param reply table
function Panel.send(src, reply)
    local okSize, encoded = pcall(json.encode, reply)
    if okSize and type(encoded) == 'string' and #encoded > LATENT_OVER then
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
