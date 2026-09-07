--- Static checks over the source itself.
--- These catch whole classes of mistake that a unit test cannot: a query
--- built by concatenation, or a handler that trusts a payload identity.

package.path = './?.lua;' .. package.path

local failures = {}
local checked = 0

local function read(path)
    local fh = io.open(path, 'r')
    if not fh then return nil end
    local content = fh:read('*a')
    fh:close()
    return content
end

local function walk(dir, out)
    out = out or {}
    local pipe = io.popen('find ' .. dir .. " -name '*.lua' -type f 2>/dev/null")
    if not pipe then return out end
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
    return out
end

local files = walk('crimson-bounty/server')
for _, f in ipairs(walk('crimson-bounty/client')) do files[#files + 1] = f end
for _, f in ipairs(walk('crimson-bounty/shared')) do files[#files + 1] = f end

--------------------------------------------------------------------------
-- 1. No SQL built by concatenation or interpolation (§10.1)
--------------------------------------------------------------------------

local SQL_VERBS = { 'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE TABLE' }

for _, path in ipairs(files) do
    local src = read(path)
    if src then
        checked = checked + 1
        local lineNo = 0
        for line in src:gmatch('[^\n]*') do
            lineNo = lineNo + 1
            -- Matched case-sensitively, against the line as written. The
            -- comparison used to be case-insensitive, which made every
            -- English sentence containing "update", "delete" or "select" a
            -- SQL line: a console message telling an operator to update
            -- their manifest was reported as SQL injection. Every query in
            -- this codebase writes its verbs in capitals, so requiring that
            -- costs nothing and stops the check crying wolf — and a check
            -- that cries wolf is one whose next real finding gets waved
            -- through.
            local looksLikeSql = false
            for _, verb in ipairs(SQL_VERBS) do
                if line:find(verb, 1, true) then looksLikeSql = true end
            end
            if looksLikeSql then
                -- A SQL line that also concatenates or formats is a finding.
                if line:find('%.%.') or line:find('string%.format') or line:find('%%s') then
                    failures[#failures + 1] =
                        ('%s:%d builds SQL by concatenation or formatting: %s')
                            :format(path, lineNo, line:gsub('^%s+', ''):sub(1, 90))
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 2. No handler reads an identity from a client payload (§14.1)
--------------------------------------------------------------------------

local FORBIDDEN_PAYLOAD_KEYS = {
    'data%.citizenid', 'data%.cid', 'data%.hunterCid', 'data%.hunterId',
    'payload%.citizenid', 'payload%.cid', 'payload%.source', 'data%.source',
    'data%.playerId', 'data%.serverId', 'payload%.serverId',
}

for _, path in ipairs(files) do
    local src = read(path)
    if src then
        -- A local bound to a server-side player record is not a client
        -- payload, however it happens to be named: `local data =
        -- player.PlayerData` is authoritative server state.
        local serverBound = {}
        for name in src:gmatch('local%s+([%w_]+)%s*=%s*[%w_%.]*PlayerData') do
            serverBound[name] = true
        end

        for _, pattern in ipairs(FORBIDDEN_PAYLOAD_KEYS) do
            local varName = pattern:match('^([%w_]+)%%%.')
            if not serverBound[varName] then
                local found = src:find(pattern)
                if found then
                    local upto = src:sub(1, found)
                    local _, lineNo = upto:gsub('\n', '')
                    failures[#failures + 1] =
                        ('%s:%d reads an identity from a client payload (%s)')
                            :format(path, lineNo + 1, pattern:gsub('%%', ''))
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 3. Server modules must not trust `source` outside identity.lua
--------------------------------------------------------------------------

for _, path in ipairs(files) do
    -- app.lua, main.lua and bridges.lua are the event boundary: they are
    -- where `source` legitimately enters and is immediately resolved.
    if path:find('server/') and not path:find('identity%.lua')
        and not path:find('app%.lua') and not path:find('main%.lua')
        and not path:find('bridges%.lua') then
        local src = read(path)
        if src and src:find('\n%s*local%s+src%s*=%s*source') then
            failures[#failures + 1] = ('%s captures `source` outside identity.lua'):format(path)
        end
    end
end

--------------------------------------------------------------------------
-- 4. Every engine bridge is actually installed
--------------------------------------------------------------------------
--
-- A producer that is written but never wired is a silent dead path. The
-- elimination payout depended on exactly one of these, and no unit test
-- would have noticed it missing.

local mainSrc = read('crimson-bounty/server/main.lua') or ''
if not mainSrc:find("require%('server%.bridges'%)%.install") then
    failures[#failures + 1] =
        'server/main.lua never installs the event bridges: damage would never be observed'
end

local bridgesSrc = read('crimson-bounty/server/bridges.lua') or ''
for _, event in ipairs({ 'weaponDamageEvent', 'playerDropped' }) do
    if not bridgesSrc:find(event, 1, true) then
        failures[#failures + 1] = ('server/bridges.lua does not register %s'):format(event)
    end
end
if not bridgesSrc:find('recordDamage', 1, true) then
    failures[#failures + 1] =
        'server/bridges.lua never calls Death.recordDamage: no elimination could be attributed'
end

--------------------------------------------------------------------------
-- 5. Every module the production loader asks for exists
--------------------------------------------------------------------------
--
-- The test harness resolves modules through package.path; the resource
-- resolves them through LoadResourceFile in server/boot.lua. A path that is
-- wrong for the second but right for the first would pass every test and
-- fail on the first start.

local function moduleExists(path)
    local file = path:gsub('%.', '/') .. '.lua'
    local handle = io.open('crimson-bounty/' .. file, 'r')
    if handle then handle:close() return true end
    return false
end

for _, path in ipairs(files) do
    local src = read(path)
    if src then
        for module in src:gmatch("require%('([%w_%.]+)'%)") do
            if not moduleExists(module) then
                failures[#failures + 1] =
                    ('%s requires "%s", which the resource loader cannot resolve')
                        :format(path, module)
            end
        end
        for module in src:gmatch("require_shared%('([%w_]+)'%)") do
            if not moduleExists('shared.' .. module) then
                failures[#failures + 1] =
                    ('%s requires shared "%s", which does not exist'):format(path, module)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 6. Files the manifest declares actually exist
--------------------------------------------------------------------------

local manifest = read('crimson-bounty/fxmanifest.lua') or ''
for declared in manifest:gmatch("'([%w_%-/%.]+%.%a+)'") do
    if declared:find('/') and not declared:find('^@') then
        local handle = io.open('crimson-bounty/' .. declared, 'r')
        if handle then handle:close()
        else
            failures[#failures + 1] = ('fxmanifest declares %s, which does not exist'):format(declared)
        end
    end
end

--------------------------------------------------------------------------
-- 7. The UI, the client bridge and the server agree on event names
--------------------------------------------------------------------------
--
-- The UI calls an NUI callback by name, the client forwards it to a server
-- event of the same name, and the server registers a handler for it. A
-- mismatch anywhere in that chain fails silently at runtime: the button
-- simply does nothing.

local uiSrc = read('crimson-bounty/ui/app.js') or ''
local clientSrc = read('crimson-bounty/client/main.lua') or ''
local appSrc = read('crimson-bounty/server/app.lua') or ''

local clientEvents, serverHandlers = {}, {}

for list in clientSrc:gmatch('local UI_EVENTS = {(.-)}') do
    for name in list:gmatch("'([%w_]+)'") do clientEvents[name] = true end
end
for name in clientSrc:gmatch("RegisterNUICallback%('crimson:([%w_]+)'") do
    clientEvents[name] = true
end
for name in appSrc:gmatch("handler%('([%w_]+)'") do serverHandlers[name] = true end

for name in uiSrc:gmatch("post%('([%w_]+)'") do
    if not clientEvents[name] then
        failures[#failures + 1] =
            ('ui/app.js calls "%s", which the client bridge does not forward'):format(name)
    elseif not serverHandlers[name] and name ~= 'takeVerificationPhoto' then
        failures[#failures + 1] =
            ('ui/app.js calls "%s", which no server handler answers'):format(name)
    end
end

--------------------------------------------------------------------------
-- 8. Every configuration key is actually read
--------------------------------------------------------------------------
--
-- A setting that nothing reads is worse than no setting: an owner tunes it,
-- nothing changes, and they have no way to tell. This walks the leaf keys in
-- config.lua and checks each one appears somewhere in the source.

local configSrc = read('crimson-bounty/config/config.lua') or ''

local sourceText = {}
for _, path in ipairs(files) do
    if not path:find('config/config%.lua') then
        sourceText[#sourceText + 1] = read(path) or ''
    end
end
sourceText[#sourceText + 1] = read('crimson-bounty/ui/app.js') or ''
local allSource = table.concat(sourceText, '\n')

-- Keys reached dynamically rather than by name.
local DYNAMIC = {
    Presets = true, Words = true, Apps = true,
    -- Cooldown buckets are looked up by action name.
    create = true, accept = true, bailout = true, informant = true,
    message = true, amend = true, search = true, photo = true,
    death = true, mugshot = true, per = true, burst = true,
    -- Source rules are indexed by source name.
    cash = true, bank = true, dirty = true, item = true, weapon = true,
    enabled = true, max = true, maxStacks = true, maxPerStack = true,
    -- Job tables are membership sets.
    police = true, sheriff = true, leo = true, trooper = true, sasp = true,
    bcso = true, fib = true, ranger = true, doj = true, lawyer = true,
    ambulance = true, fire = true, ems = true,
    -- Death-state provider entries.
    resource = true, dead = true, lastStand = true,
    -- MIME allowlist entries and escrow blacklist entries.
    phone = true, id_card = true, driver_license = true, weaponlicense = true,
    handcuffs = true, black_money = true,
    -- Coercion detector names.
    handcuffed = true, passengerOfHunter = true,
}

for key in configSrc:gmatch('\n%s*([%w_]+)%s*=') do
    if not DYNAMIC[key] and #key > 3 then
        if not allSource:find(key, 1, true) then
            failures[#failures + 1] =
                ('Config.%s is declared but nothing reads it'):format(key)
        end
    end
end

--------------------------------------------------------------------------
-- 9. No production code reads a field only the test harness invents
--------------------------------------------------------------------------
--
-- The worst bug in this build was a check reading `player._playtimeHours`,
-- a field the harness fabricated and the real framework never sets. Every
-- test passed and the resource refused every contract on a live server.
-- Any underscore-prefixed field read outside the harness is that mistake.

for _, path in ipairs(files) do
    if path:find('server/') or path:find('client/') or path:find('shared/') then
        local src = read(path)
        if src then
            for field in src:gmatch('%.player%._([%w_]+)') do
                failures[#failures + 1] =
                    ('%s reads player._%s, which only the test harness sets')
                        :format(path, field)
            end
            for field in src:gmatch('actor%._([%w_]+)') do
                failures[#failures + 1] =
                    ('%s reads actor._%s, which only the test harness sets')
                        :format(path, field)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 10. The app never relies on a native browser dialog
--------------------------------------------------------------------------
--
-- FiveM's NUI is a CEF browser with no dialog handler: confirm() resolves
-- false and prompt() null, neither is ever shown, and an action gated behind
-- one silently does nothing. Six actions in this app were dead that way.

local uiCode = (read('crimson-bounty/ui/app.js') or ''):gsub('/%*.-%*/', ''):gsub('//[^\n]*', '')
for _, call in ipairs({ 'confirm%s*%(', 'prompt%s*%(', 'alert%s*%(' }) do
    if uiCode:find('window%.' .. call) or uiCode:find('[^%w_%.]' .. call) then
        failures[#failures + 1] =
            ('ui/app.js uses a native browser dialog (%s), which FiveM NUI never shows')
                :format((call:gsub('%%s%*%(', '')))
    end
end

--------------------------------------------------------------------------
-- 11. The test harness wires every module the resource wires
--------------------------------------------------------------------------
--
-- app.init was missing from newStack for the life of this build. Nothing
-- caught it, because the app only reached through deps once the reward
-- builder needed the escrow module — at which point a live server would
-- have thrown on a nil index and the suite would still have been green.
-- Any module main.lua initialises must be initialised in the harness too.

do
    local main = read('crimson-bounty/server/main.lua') or ''
    local harness = read('crimson-bounty/tests/run.lua') or ''

    local wired = {}
    for name in main:gmatch('([%w_]+)%.init%s*%(') do wired[name] = true end

    for name in pairs(wired) do
        if not harness:find(name .. '%.init%s*%(') then
            failures[#failures + 1] =
                ('main.lua calls %s.init but tests/run.lua does not; anything that '
                 .. 'module reaches through deps is untested and nil on a live server')
                    :format(name)
        end
    end
end

--------------------------------------------------------------------------
-- 12. Every field written onto a contract has a column to live in
--------------------------------------------------------------------------
--
-- The memory and json backends store whole Lua tables, so a field the MySQL
-- schema forgets survives there for free and every test passes. The storage
-- suite compares a hand-written list of fields against the schema, which is
-- only as good as somebody remembering to extend it — `bailout_attempts` was
-- added, persisted fine in two backends, and would have been dropped on the
-- backend that ships by default.
--
-- This finds the fields by reading the code that assigns them, so the next
-- one is caught without anyone remembering anything.

do
    local schema = read('crimson-bounty/server/storage/mysql.lua') or ''
    local contractSchema = schema:match('CREATE TABLE IF NOT EXISTS crimson_contracts(.-)%]%]') or ''

    -- Fields deliberately not persisted. Each one needs a reason, because
    -- "it is in this list" is the only thing standing between a field and a
    -- silent data loss bug.
    local TRANSIENT = {
        -- Nothing yet. A field added here must say why it does not persist.
    }

    local seen = {}
    for _, path in ipairs(files) do
        if path:find('server/') then
            local src = read(path) or ''
            -- Assignments onto a variable holding a contract row. The
            -- trailing [^=] keeps a comparison from reading as a write.
            for name in src:gmatch('[^%w_]contract%.([%a_][%w_]*)%s*=[^=]') do
                seen[name] = seen[name] or path
            end
            for name in src:gmatch('[^%w_]settled%.([%a_][%w_]*)%s*=[^=]') do
                seen[name] = seen[name] or path
            end
        end
    end

    for name, path in pairs(seen) do
        if not TRANSIENT[name] and not contractSchema:find('[^%w_]' .. name .. '%s') then
            failures[#failures + 1] =
                ('%s writes contract.%s but crimson_contracts has no such column; '
                 .. 'mysql would drop it silently while memory and json keep it')
                    :format(path, name)
        end
    end
end

--------------------------------------------------------------------------
-- 13. No function is defined twice in one file
--------------------------------------------------------------------------
--
-- Lua takes the last definition silently. I added a Photo.allowedHosts that
-- returned a sorted list, twenty lines above one that already existed and
-- returned the raw set — so the new one never ran, and the test written
-- against it failed in a way that pointed at the loader instead. Nothing
-- warned.

do
    for _, path in ipairs(files) do
        if path:sub(-4) == '.lua' then
            local src = read(path) or ''
            local seen = {}
            for name in src:gmatch('\nfunction%s+([%w_]+[.:][%w_]+)%s*%(') do
                if seen[name] then
                    failures[#failures + 1] =
                        ('%s defines %s twice; Lua keeps the last one and the first '
                         .. 'silently never runs'):format(path, name)
                else
                    seen[name] = true
                end
            end

            local seenLocal = {}
            for name in src:gmatch('\nlocal function%s+([%w_]+)%s*%(') do
                if seenLocal[name] then
                    failures[#failures + 1] =
                        ('%s defines local function %s twice; the first is unreachable')
                            :format(path, name)
                else
                    seenLocal[name] = true
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 14. No test that asserts nothing
--------------------------------------------------------------------------
--
-- A test with no assertion in it passes forever and reads as coverage. I
-- wrote three of these in one sitting — one built an app and returned it,
-- one checked a value that could never be undefined — and every one of them
-- was found by a reviewer rather than by the suite.
--
-- The body is found by matching braces from the `function` that opens it,
-- so a one-line test and a fifty-line one are read the same way. A check
-- that fires on correct code would be worse than no check at all.

do
    local src = read('crimson-bounty/tests/ui/run.js') or ''
    local path = 'crimson-bounty/tests/ui/run.js'

    local position = 1
    while true do
        local from, to, name = src:find("it%s*%(%s*['\"]([^'\"]+)['\"]%s*,", position)
        if not from then break end
        position = to + 1

        -- The body starts at the first `{` after the callback's argument
        -- list and ends at its matching `}`.
        local open = src:find('{', to, true)
        if open then
            local depth, index = 0, open
            local limit = #src
            local close

            while index <= limit do
                local char = src:sub(index, index)
                if char == '{' then
                    depth = depth + 1
                elseif char == '}' then
                    depth = depth - 1
                    if depth == 0 then close = index break end
                end
                index = index + 1
            end

            if close then
                local body = src:sub(open, close)
                local asserts = body:find('eq%s*%(') or body:find('truthy%s*%(')
                    or body:find('falsy%s*%(') or body:find('throw%s')
                if not asserts then
                    failures[#failures + 1] =
                        ('%s: the test %q contains no assertion; it passes forever and '
                         .. 'reads as coverage'):format(path, name)
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 15. The app never builds markup from data
--------------------------------------------------------------------------
--
-- Contract reasons, target names and hunter aliases are written by other
-- players and rendered in everyone's phone. Every one of them goes through
-- textContent today. An innerHTML assignment of anything but a literal
-- empty string is how that stops being true.

do
    local src = read('crimson-bounty/ui/app.js') or ''
    for assignment in src:gmatch('innerHTML%s*=%s*([^;\n]+)') do
        local value = assignment:match('^%s*(.-)%s*$')
        if value ~= "''" and value ~= '""' then
            failures[#failures + 1] =
                ('ui/app.js assigns innerHTML = %s; player-written text is rendered here '
                 .. 'and textContent is the only safe way to put it on the page')
                    :format(value)
        end
    end

    for _, sink in ipairs({ 'insertAdjacentHTML', 'document%.write', 'outerHTML%s*=' }) do
        if src:find(sink) then
            failures[#failures + 1] =
                ('ui/app.js uses %s, which builds markup from data')
                    :format((sink:gsub('%%', '')))
        end
    end
end

--------------------------------------------------------------------------
-- 16. Nothing measures a duration against the raw game timer
--------------------------------------------------------------------------
--
-- GetGameTimer is a 32-bit millisecond counter and wraps about every 24.8
-- days. Every elapsed subtraction against it turns negative at that instant
-- and stays negative: the rate limiter's refill goes tens of thousands of
-- tokens below zero and locks every player out for good, its idle sweep
-- stops firing, and every proof token stops expiring because "issued more
-- than two minutes ago" is false when the subtraction is negative.
--
-- shared/util.lua absorbs the wrap once, in Util.monotonicMs, and every one
-- of the twenty-two call sites reads that instead. This is the guard on the
-- twenty-third: a new duration written against the raw timer would pass
-- every test, because a suite that never runs for a month never wraps.

do
    for _, path in ipairs(files) do
        local src = read(path) or ''
        -- shared/util.lua is the one file allowed to read the raw timer: it
        -- is where the wrap is absorbed. Everywhere else, including the
        -- client, goes through Util.monotonicMs.
        local exempt = path:find('shared/util%.lua$') ~= nil
        local line = 0
        for text in src:gmatch('[^\n]*') do
            line = line + 1
            -- Comments explaining the wrap are allowed to name the native.
            if not exempt and not text:match('^%s*%-%-') and text:find('GetGameTimer') then
                failures[#failures + 1] =
                    ('%s:%d calls GetGameTimer directly; it wraps every ~24.8 days and '
                     .. 'every elapsed subtraction against it then goes negative. Use '
                     .. 'Util.monotonicMs().'):format(path, line)
            end
        end
    end

    -- And the one file allowed to read it must still be absorbing the wrap,
    -- rather than having been quietly simplified back to a passthrough.
    local util = read('crimson-bounty/shared/util.lua') or ''
    local body = util:match('function Util%.monotonicMs%(%)(.-)\nend')
    if not body then
        failures[#failures + 1] =
            'shared/util.lua no longer defines Util.monotonicMs; every duration in the '
            .. 'resource depends on it'
    elseif not body:find('lastRaw') then
        failures[#failures + 1] =
            'shared/util.lua: Util.monotonicMs no longer compares against the previous '
            .. 'reading, so it cannot detect a wrap'
    end
end

--------------------------------------------------------------------------
-- 17. A global the client reads is a file the client actually loads
--------------------------------------------------------------------------
--
-- The client has no module loader, so shared code reaches it through a
-- global that the shared file assigns. That only works if the manifest lists
-- the file under client_scripts. Miss it and the global is nil on the
-- client, which throws the first time the code path runs — usually the one
-- path nobody tests by hand, since the server suite loads shared modules
-- through require_shared and never notices.

do
    local clientBlock = manifest:match('client_scripts%s*{(.-)}') or ''

    for _, sharedPath in ipairs(walk('crimson-bounty/shared')) do
        local src = read(sharedPath) or ''
        -- A global export is an assignment to a bare capitalised name at the
        -- start of a line: `CrimsonUtil = Util`.
        for name in src:gmatch('\n(%u[%w_]*)%s*=%s*%u') do
            local usedByClient = false
            for _, clientPath in ipairs(walk('crimson-bounty/client')) do
                local clientSrc = read(clientPath) or ''
                if clientSrc:find(name .. '%s*[%.%[]') then usedByClient = true end
            end

            local relative = sharedPath:gsub('^crimson%-bounty/', '')
            if usedByClient and not clientBlock:find(relative, 1, true) then
                failures[#failures + 1] =
                    ('the client reads the global %s, which %s assigns, but the manifest '
                     .. 'does not list %s under client_scripts — the global is nil on the '
                     .. 'client'):format(name, relative, relative)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 18. A percentage of money is not taken through a binary fraction
--------------------------------------------------------------------------
--
-- `amount * (percent / 100)` divides first, and most hundredths are not
-- representable in binary: 29/100 lands just under, so 29% of 50,000 came
-- out as 14,499. The creator promised a percentage, the hunter was shown a
-- percentage, and the escrow held a unit less than either.
--
-- Multiplying first keeps the whole calculation in integers, which is where
-- money belongs. This refuses the shape rather than the one instance, since
-- the next percentage added would be written the same way.

do
    for _, path in ipairs(files) do
        local src = read(path) or ''
        local line = 0
        for text in src:gmatch('[^\n]*') do
            line = line + 1
            if not text:match('^%s*%-%-')
                and text:match('%*%s*%(%s*[%w_%.]+%s*/%s*%d') then
                failures[#failures + 1] =
                    ('%s:%d multiplies by a parenthesised division. Dividing first goes '
                     .. 'through a binary fraction and loses whole units; multiply first, '
                     .. 'then divide.'):format(path, line)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 19. Every credit to a player is checked
--------------------------------------------------------------------------
--
-- qbx_core's AddMoney and ox_inventory's AddItem both return a boolean:
-- false for an account or an inventory that will not take what it is given,
-- and servers routinely patch balance ceilings and carry limits into them.
--
-- Four payout paths called one of these as a bare statement and carried on
-- as though it had worked. The money left escrow, never arrived, and nothing
-- recorded that anyone was owed it. Each of them already had a correct
-- recovery — owe it, defer it, or write an audit row — and the only thing
-- missing was asking.
--
-- A call whose answer is thrown away is refused here. The answer has to go
-- somewhere: returned, assigned, or tested.

do
    for _, path in ipairs(files) do
        local src = read(path) or ''
        local line = 0
        for text in src:gmatch('[^\n]*') do
            line = line + 1
            local body = text:match('^%s*(.-)%s*$')
            -- A bare call statement: the line begins with the call itself,
            -- so nothing receives what it returns.
            local bare = body:match('^[%w_%.:%[%]\'"]-[%.:]AddMoney%s*%(')
                or body:match('^[%w_%.:%[%]\'"]-[%.:]AddItem%s*%(')
            if bare and not body:match('^%-%-') then
                failures[#failures + 1] =
                    ('%s:%d credits a player and discards the answer. AddMoney and AddItem '
                     .. 'return false when the account or inventory will not take it; a '
                     .. 'payout that reports success regardless is money gone from escrow '
                     .. 'and never delivered.'):format(path, line)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 20. Nothing calls an optional export unguarded
--------------------------------------------------------------------------
--
-- lb-phone ships its server code escrowed and its export surface has moved
-- across releases; MugShotBase64 is optional entirely. Indexing an export
-- that is not there throws, and every one of these is called from inside an
-- event handler or an NUI callback — so the throw takes the handler with
-- it, and the page is left waiting for a reply that will never come.
--
-- client/main.lua routes them through `phone`, which pcalls and says which
-- export was missing. client/mugshot.lua pcalls its one call directly. A
-- new call site written without either is caught here.
--
-- The server is walked too, which it was not. The rule was written down in
-- two places and enforced on one half of the resource, and the server broke
-- it twice — in Contracts.create and Comms.send, both inside handlers, so
-- on a build without that one export every contract was refused with
-- server_error and every message with it. comms.lua guards an export a
-- hundred and ninety lines below the one it did not.

do
    local OPTIONAL = { 'lb%-phone', 'MugShotBase64' }

    local scanned = {}
    for _, dir in ipairs({ 'crimson-bounty/client', 'crimson-bounty/server' }) do
        for _, path in ipairs(walk(dir)) do scanned[#scanned + 1] = path end
    end

    for _, path in ipairs(scanned) do
        local src = read(path) or ''
        local line = 0
        for text in src:gmatch('[^\n]*') do
            line = line + 1
            for _, resource in ipairs(OPTIONAL) do
                if text:find("exports%['" .. resource .. "'%]") and not text:match('^%s*%-%-') then
                    -- Guarded either by the file-local helper on the line
                    -- above, or by a pcall in the same statement.
                    local before = src:sub(1, src:find(text, 1, true) or 1)
                    local window = before:sub(-400)
                    -- Guarded by the client's `phone` helper, by the
                    -- server's `phoneRefuses`, or by a pcall in the same
                    -- statement.
                    if not (window:find('phone%(') or window:find('pcall%(')
                        or window:find('phoneRefuses')) then
                        failures[#failures + 1] =
                            ('%s:%d calls an optional export without a guard. The export may '
                             .. 'not exist on this build, and the throw takes the handler '
                             .. 'with it.'):format(path, line)
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 21. Every config key the code reads actually exists
--------------------------------------------------------------------------
--
-- Config values are read directly and many of them go straight into
-- arithmetic. A key that is not there is nil, which throws — not at startup
-- where anyone would see it, but deep inside whichever handler happens to
-- reach that line first. A typo in a read, or a key renamed on one side
-- only, is silent until a player triggers it.
--
-- Reads are found textually and checked against the shipped config, which
-- this file loads for real.

do
    local ok, config = pcall(dofile, 'crimson-bounty/config/config.lua')
    if not ok or type(config) ~= 'table' then
        -- config.lua assigns to a global rather than returning; load it that
        -- way instead.
        local chunk = loadfile('crimson-bounty/config/config.lua')
        if chunk then
            _G.Config = {}
            pcall(chunk)
            config = _G.Config
        end
    end

    -- A key written as `Thing = nil` is a declaration, not an omission: Lua
    -- stores nothing for it, but the author said out loud that it is an
    -- optional integration hook and every read of one is guarded. Read from
    -- the source text, since the loaded table cannot tell the two apart.
    local declaredNil = {}
    local configSrc = read('crimson-bounty/config/config.lua') or ''
    for key in configSrc:gmatch('\n%s*([%w_]+)%s*=%s*nil%s*,') do
        declaredNil[key] = true
    end

    if type(config) ~= 'table' then
        failures[#failures + 1] = 'could not load crimson-bounty/config/config.lua to check '
            .. 'the keys the code reads against it'
    else
        local seen = {}

        for _, path in ipairs(files) do
            local src = read(path) or ''
            for section, key in src:gmatch('Config%.(%u[%w_]*)%.([%w_]+)') do
                local where = section .. '.' .. key
                if not seen[where] then
                    seen[where] = true
                    local block = config[section]
                    if type(block) ~= 'table' then
                        failures[#failures + 1] =
                            ('%s reads Config.%s, which the shipped config does not define')
                                :format(path, section)
                    elseif block[key] == nil and not declaredNil[key] then
                        failures[#failures + 1] =
                            ('%s reads Config.%s, which the shipped config does not define. '
                             .. 'It is nil at runtime, and the first handler to reach it throws. '
                             .. 'If it is meant to be optional, write it as `%s = nil,` in the '
                             .. 'config so that is on the record.')
                                :format(path, where, key)
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 22. Every class the app renders is one the stylesheet defines
--------------------------------------------------------------------------
--
-- A class name that does not exist fails in the quietest way there is: the
-- element renders, unstyled, and nothing anywhere says so. On a phone
-- screen that is a control the player cannot see or a list with no shape,
-- reported as "the buttons do not show up" — which is exactly how the
-- layout bugs in this app were found, by somebody using it rather than by
-- anything here.

do
    local css = read('crimson-bounty/ui/app.css') or ''
    local js = read('crimson-bounty/ui/app.js') or ''

    -- Comments hold example markup and old class names; they define nothing.
    local defined = css:gsub('/%*.-%*/', '')

    local seen = {}
    -- el('div', 'card is-protected', ...) — the second argument is the class
    -- list, and it is the only way this app sets one.
    for list in js:gmatch("el%('[%a%d]+',%s*'([%a%d%s_%-]+)'") do
        for class in list:gmatch('[%a%d_%-]+') do
            if not seen[class] then
                seen[class] = true
                if not defined:find('%.' .. class:gsub('%-', '%%-')) then
                    failures[#failures + 1] =
                        ('ui/app.js renders the class %q, which ui/app.css does not define. '
                         .. 'It renders unstyled and says nothing.'):format(class)
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 23. No local function is called above where it is defined
--------------------------------------------------------------------------
--
-- Lua resolves a bare name at call time, so a `local function` used before
-- its definition is nil at that point — not an error anyone sees at load,
-- but a crash the first time that line runs. Inside a request handler that
-- is a call which simply never answers.
--
-- This has shipped twice: reportIntegrations, called eighty lines above its
-- definition, would have thrown on startup while the whole suite was green;
-- and sourceEnabled, which took out the one handler the item picker depends
-- on. Both were caught by luck rather than by anything here.
--
-- Only same-file, file-scope `local function` declarations are considered:
-- a nested one is scoped to its enclosing function and a call to it from
-- outside would not resolve anyway.

do
    for _, path in ipairs(files) do
        local src = read(path) or ''

        -- Where each file-scope local function is declared. Indentation is
        -- what distinguishes it from a nested one.
        local declaredAt, order = {}, {}
        local line = 0
        for text in src:gmatch('[^\n]*') do
            line = line + 1
            local name = text:match('^local function ([%w_]+)%s*%(')
            if name and not declaredAt[name] then
                declaredAt[name] = line
                order[#order + 1] = name
            end
        end

        for _, name in ipairs(order) do
            local declared = declaredAt[name]
            local at = 0
            for text in src:gmatch('[^\n]*') do
                at = at + 1
                if at < declared and not text:match('^%s*%-%-') then
                    -- A call, not a mention: the name followed by an open
                    -- bracket, and not part of a longer identifier.
                    local before, after = text:match('(.?)' .. name .. '%s*%((.?)')
                    if before and not before:match('[%w_.:]') then
                        failures[#failures + 1] =
                            ('%s:%d calls %s(), which is declared as a local function on '
                             .. 'line %d. Lua resolves the name at call time, so it is nil '
                             .. 'here and this line throws the first time it runs.')
                                :format(path, at, name, declared)
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 27. A list from the server is iterated through asList, always.
--
-- FiveM msgpack-encodes Lua tables, and an EMPTY Lua table is
-- indistinguishable from an empty map: a server that meant to send an empty
-- list sends `{}`, not `[]`. On the page `{}` is truthy and has no .length,
-- so `if (x && x.length)` reads as "nothing there" whether or not there is,
-- and `x.forEach` throws outright — taking the whole tab down.
--
-- Two of these survived an earlier sweep for exactly this, on
-- contract.hunters: a creator whose contract nobody had taken yet, which is
-- every contract the moment it is placed.
--------------------------------------------------------------------------

do
    local ui = read('crimson-bounty/ui/app.js') or ''
    local lineNo = 0
    for line in ui:gmatch('[^\n]*') do
        lineNo = lineNo + 1
        -- Anything hanging off a contract came from the projection.
        local expr = line:match('(contract%.[A-Za-z_]+)%.forEach')
            or line:match('(contract%.[A-Za-z_]+)%.length')
            or line:match('(contract%.[A-Za-z_]+)%.map')
        if expr and not line:find('asList', 1, true) then
            failures[#failures + 1] =
                ('ui/app.js:%d iterates %s without asList. An empty Lua table '
                 .. 'crosses as {}, which is truthy and has no length: this '
                 .. 'either throws or silently reads as empty.')
                    :format(lineNo, expr)
        end
    end
end

--------------------------------------------------------------------------
-- 26. The shipped defaults and the operator's config must name the same
-- sections.
--
-- config/defaults.lua exists so that a setting added after an operator last
-- touched their copy still has a value. It only works while it is in step:
-- a section added to config.lua and not to defaults.lua is a section that
-- goes back to being nil on their server, which is the whole failure this
-- was written to end.
--------------------------------------------------------------------------

do
    local shipped = read('crimson-bounty/config/defaults.lua') or ''
    local live = read('crimson-bounty/config/config.lua') or ''

    local function sectionsOf(src, prefix)
        local found = {}
        for name in src:gmatch('\n' .. prefix .. '%.([A-Za-z]+)%s*=') do found[name] = true end
        return found
    end

    local inShipped = sectionsOf(shipped, 'ConfigDefaults')
    local inLive = sectionsOf(live, 'Config')

    for name in pairs(inLive) do
        if not inShipped[name] then
            failures[#failures + 1] =
                ('config/config.lua sets Config.%s and config/defaults.lua does '
                 .. 'not. An operator whose config predates that setting gets nil '
                 .. 'for it, which is what defaults.lua exists to prevent.')
                    :format(name)
        end
    end

    for name in pairs(inShipped) do
        if not inLive[name] then
            failures[#failures + 1] =
                ('config/defaults.lua sets ConfigDefaults.%s and config/config.lua '
                 .. 'does not. The file operators actually read should show every '
                 .. 'setting they can change.'):format(name)
        end
    end
end

--------------------------------------------------------------------------
-- 25. The tick must keep re-deciding who may have the app.
--
-- Whether a player's job bars them from the app is answered on the
-- maintenance tick rather than on a framework job-change event, because a
-- wrong event name fails silently in the direction that takes the app away
-- and never gives it back. If that job is dropped from the tick, a player
-- who leaves a barred job has no way at all to recover the app — which is
-- exactly the outage this replaced.
--------------------------------------------------------------------------

do
    local main = read('crimson-bounty/server/main.lua') or ''
    local bridges = read('crimson-bounty/server/bridges.lua') or ''

    if bridges:find('function Bridges.refreshAccess', 1, true)
        and not main:find('refreshAccess', 1, true) then
        failures[#failures + 1] =
            'server/main.lua never calls Bridges.refreshAccess. Nothing else '
            .. 're-decides who may have the app, so a player who leaves a barred '
            .. 'job never gets it back.'
    end
end

--------------------------------------------------------------------------
-- 24. The phone page must be cache-busted, in both halves.
--
-- CEF caches app.js on its own disk keyed by URL. While the URL was a
-- constant, a player who had opened the app once kept that copy through
-- every update — so fixes shipped to the page reached nobody who had
-- already used it, and neither end of a support conversation could tell.
-- Both halves are needed and each is useless alone: the client has to put
-- a build on the page URL, and the page has to pass it on to its assets.
--------------------------------------------------------------------------

do
    local client = read('crimson-bounty/client/main.lua')
    local page = read('crimson-bounty/ui/index.html')

    if client then
        local ui = client:match("ui%s*=%s*([^\n]+)")
        if ui and not ui:find('?v=', 1, true) then
            failures[#failures + 1] =
                'client/main.lua registers the phone page on a URL with no build '
                .. 'query. CEF caches it by URL, so players keep the copy they '
                .. 'already have and updates to the page reach nobody.'
        end
    end

    if page then
        -- A bare src/href to app.js or app.css is one CEF will cache
        -- forever. Both have to carry the query the page was opened with.
        if page:match('src%s*=%s*"app%.js"') or page:match('href%s*=%s*"app%.css"') then
            failures[#failures + 1] =
                'ui/index.html loads app.js or app.css without a build query. '
                .. 'Whatever the page URL carries, these are cached separately '
                .. 'and stay stale.'
        end
        if not page:find('CB_BUILD', 1, true) then
            failures[#failures + 1] =
                'ui/index.html does not record the build it was opened with. '
                .. 'The app cannot then say which copy of itself is running, '
                .. 'which is the only way to tell an update landed.'
        end
    end
end

--------------------------------------------------------------------------
-- 28. The keys a caller sends are the keys the handler reads.
--------------------------------------------------------------------------
--
-- Check 7 proves an event has a handler somewhere. It says nothing about
-- whether the two agree on what is inside the payload, and that is where
-- this app has actually broken twice.
--
-- reduce_reward: the page sent { amount }, the server sanitized on
-- payload.slot, and the proposal was built with nothing in it. Every module
-- test passed and the button did nothing.
--
-- create: the server read payload.reasonPreset, the page had no picker and
-- never sent one, and Util.toPositive(nil) is nil — so on any server set to
-- Config.Reason.Mode = 'preset' every contract was refused with
-- invalid_input, permanently, with the reason box the player had just
-- filled in not being the field rejected.
--
-- Both are invisible to a suite that calls modules directly, and both are a
-- one-line diff away from returning. Nested objects are excluded: only the
-- top level of each payload is this check's business, since a nested shape
-- is passed through whole and validated by whoever reads it.

do
    --- The balanced-brace slice starting at the '{' at position i.
    local function braced(src, i)
        local depth, j = 0, i
        while j <= #src do
            local ch = src:sub(j, j)
            if ch == '{' then depth = depth + 1
            elseif ch == '}' then
                depth = depth - 1
                if depth == 0 then return src:sub(i, j) end
            end
            j = j + 1
        end
        return nil
    end

    local sent = {}
    local function collect(src, callPattern, keyPattern)
        local pos = 1
        while true do
            local s2, e2, name = src:find(callPattern, pos)
            if not s2 then break end
            local open = src:find('{', e2 - 1, true)
            local body = open and braced(src, open) or nil
            sent[name] = sent[name] or {}
            if body then
                local flat = body:sub(2, -2)
                -- Comments first. A key pattern anchored on the preceding
                -- comma cannot reach past a comment sitting between the two,
                -- so a documented field read as an absent one — which had
                -- this check reporting the very bug it had just been written
                -- to catch, after the fix. The guard on ':' is so a URL in
                -- prose is not read as the start of a comment.
                flat = flat:gsub('/%*.-%*/', ' ')
                flat = flat:gsub('([^:])//[^\n]*', '%1')
                flat = flat:gsub('%-%-[^\n]*', '')
                -- Then blank out every nested object, array and call so
                -- their keys are not mistaken for ours.
                flat = flat:gsub('%b{}', '_'):gsub('%b[]', '_'):gsub('%b()', '_')
                for k in ('{' .. flat):gmatch(keyPattern) do sent[name][k] = true end
            end
            pos = e2
        end
    end

    collect(uiSrc, "post%('([%w_]+)'", "[{,]%s*([%w_]+)%s*:")
    collect(clientSrc, "App%.request%('([%w_]+)'", "[{,]%s*([%w_]+)%s*=")

    -- Each handler body runs to the next handler() registration.
    local reads, marks = {}, {}
    for pos, name in appSrc:gmatch("()handler%('([%w_]+)'") do
        marks[#marks + 1] = { pos = pos, name = name }
    end
    for i, m in ipairs(marks) do
        local stop = marks[i + 1] and marks[i + 1].pos or #appSrc
        reads[m.name] = reads[m.name] or {}
        for k in appSrc:sub(m.pos, stop):gmatch('payload%.([%w_]+)') do
            -- The correlation id is framework plumbing, not a field a
            -- caller chooses to send.
            if k ~= '__rid' then reads[m.name][k] = true end
        end
    end

    local function sortedKeys(t)
        local out = {}
        for k in pairs(t or {}) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    -- A parser that stopped matching reports a clean tree, which is the one
    -- result this check must never give by accident. Counted rather than
    -- assumed: these numbers only move when the app really changes shape.
    local comparable = 0
    for name in pairs(reads) do if sent[name] then comparable = comparable + 1 end end
    if comparable < 20 then
        failures[#failures + 1] = ((
            'the payload-shape check compared only %d handlers against their '
            .. 'callers. It reads post() and App.request() sites and handler() '
            .. 'bodies by pattern, so this means it stopped matching rather '
            .. 'than that the app shrank — and a check that matches nothing '
            .. 'reports no findings.'):format(comparable))
    end

    for _, name in ipairs(sortedKeys(reads)) do
        if sent[name] then
            for _, key in ipairs(sortedKeys(reads[name])) do
                if not sent[name][key] then
                    failures[#failures + 1] = ((
                        'handler "%s" reads payload.%s, which no caller sends. '
                        .. 'Either the page stopped sending it or the server '
                        .. 'started asking for something nothing offers.')
                        :format(name, key))
                end
            end
        end
    end

    for _, name in ipairs(sortedKeys(sent)) do
        if reads[name] then
            for _, key in ipairs(sortedKeys(sent[name])) do
                if not reads[name][key] then
                    failures[#failures + 1] = ((
                        'a caller sends "%s" with %s, which the handler never '
                        .. 'reads. A field nobody reads is a control that does '
                        .. 'nothing.'):format(name, key))
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 29. An amendment's payload is the payload its kind is sanitized on.
--------------------------------------------------------------------------
--
-- Check 28 stops at the top level of a request, because a nested object is
-- passed through whole and validated by whoever reads it. For amendments
-- that reader is Amendments.sanitize, which switches on the kind and keeps
-- only the fields that kind uses — so the nested payload has a contract of
-- its own, per kind, and nothing was checking it.
--
-- That is where reduce_reward broke: the page sent { amount }, sanitize
-- read payload.slot, the proposal was built holding nothing, and the button
-- did nothing on a live server while every module test passed.
--
-- Only proposal sites written as a literal kind and a literal payload can
-- be read here. One site picks its kind with a ternary (withdraw or cancel)
-- and is not matched; both of those kinds take no parameters, so there is
-- nothing for this check to compare on them anyway.

do
    local amendSrc = read('crimson-bounty/server/amendments.lua') or ''
    local constSrc = read('crimson-bounty/shared/constants.lua') or ''

    -- CB.AMENDMENT.SHORTEN_DEADLINE -> 'shorten_deadline'
    local enum = {}
    local block = constSrc:match('CB%.AMENDMENT%s*=%s*(%b{})') or ''
    for name, value in block:gmatch("([%u_]+)%s*=%s*'([%w_]+)'") do enum[name] = value end

    -- What the page proposes, by kind.
    local proposed = {}
    local function record(kind, body)
        proposed[kind] = proposed[kind] or {}
        local flat = body:sub(2, -2)
            :gsub('/%*.-%*/', ' '):gsub('([^:])//[^\n]*', '%1')
            :gsub('%b{}', '_'):gsub('%b[]', '_'):gsub('%b()', '_')
        for k in ('{' .. flat):gmatch("[{,]%s*([%w_]+)%s*:") do proposed[kind][k] = true end
    end
    for kind, body in uiSrc:gmatch("sendProposal%([%w_.]+,%s*'([%w_]+)'%s*,%s*(%b{})") do
        record(kind, body)
    end
    for kind, body in uiSrc:gmatch("kind:%s*'([%w_]+)'%s*,%s*payload:%s*(%b{})") do
        record(kind, body)
    end

    -- What sanitize reads, by kind. Each branch runs to the next one.
    local body = amendSrc:match('function Amendments%.sanitize.-\nend') or ''
    local bounds = {}
    for pos in body:gmatch('()\n%s*else?i?f?%s*kind%s*==') do bounds[#bounds + 1] = pos end
    bounds[#bounds + 1] = #body + 1

    local sanitized = {}
    local start = body:find('if%s+kind%s*==')
    if start then
        local cuts = { start }
        for _, b in ipairs(bounds) do if b > start then cuts[#cuts + 1] = b end end
        for i = 1, #cuts - 1 do
            local branch = body:sub(cuts[i], cuts[i + 1] - 1)
            local kinds = {}
            for name in branch:gmatch('CB%.AMENDMENT%.([%u_]+)') do
                if enum[name] then kinds[#kinds + 1] = enum[name] end
            end
            local keys = {}
            for k in branch:gmatch('payload%.([%w_]+)') do keys[k] = true end
            for _, kind in ipairs(kinds) do
                sanitized[kind] = sanitized[kind] or {}
                for k in pairs(keys) do sanitized[kind][k] = true end
            end
        end
    end

    local function sortedKeys(t)
        local out = {}
        for k in pairs(t or {}) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    -- The same guard. If either side stops parsing there is nothing to
    -- compare and the check goes quiet, which reads exactly like a pass.
    local kindsProposed, kindsSanitized = 0, 0
    for _ in pairs(proposed) do kindsProposed = kindsProposed + 1 end
    for _ in pairs(sanitized) do kindsSanitized = kindsSanitized + 1 end
    if kindsProposed < 3 or kindsSanitized < 5 then
        failures[#failures + 1] = ((
            'the amendment-payload check parsed %d proposed kinds and %d '
            .. 'sanitized ones. Both sides are read by pattern, so this is '
            .. 'the parser having stopped matching rather than the feature '
            .. 'having shrunk.'):format(kindsProposed, kindsSanitized))
    end

    for _, kind in ipairs(sortedKeys(proposed)) do
        if sanitized[kind] then
            for _, key in ipairs(sortedKeys(sanitized[kind])) do
                if not proposed[kind][key] then
                    failures[#failures + 1] = ((
                        'amendment "%s" is sanitized on payload.%s, which the '
                        .. 'page does not send. The proposal is then built '
                        .. 'holding nothing and the button does nothing.')
                        :format(kind, key))
                end
            end
            for _, key in ipairs(sortedKeys(proposed[kind])) do
                if not sanitized[kind][key] then
                    failures[#failures + 1] = ((
                        'the page proposes "%s" with %s, which sanitize drops. '
                        .. 'Whatever the player chose there is discarded.')
                        :format(kind, key))
                end
            end
        elseif enum ~= nil and next(enum) ~= nil then
            failures[#failures + 1] = ((
                'the page proposes "%s", which sanitize has no branch for. '
                .. 'Every such proposal is refused as invalid input.')
                :format(kind))
        end
    end
end

--------------------------------------------------------------------------
-- 30. Every refusal the server can send has words on the page.
--------------------------------------------------------------------------
--
-- A code with no entry in ERRORS falls through to "Something went wrong",
-- which is the message a player reads as a broken app. no_player had no
-- entry: the app fires three requests the moment it opens, so anybody who
-- opened it while still joining got that three times, for something that
-- would have cleared on its own in seconds.
--
-- The reverse matters less and is not an error — the page also names codes
-- the client raises for itself (a request that timed out, one the player
-- cancelled), which no server sends.

do
    local constSrc = read('crimson-bounty/shared/constants.lua') or ''

    local codes = {}
    local errBlock = constSrc:match('CB%.ERR%s*=%s*(%b{})') or ''
    for name, value in errBlock:gmatch("([%u_]+)%s*=%s*'([%w_]+)'") do
        codes[value] = name
    end

    -- Comments stripped first: a key pattern anchored on the preceding
    -- comma cannot see past a comment between the two, and this map is
    -- heavily commented.
    local messages = {}
    local mapBlock = (uiSrc:match('var ERRORS%s*=%s*(%b{})') or '')
        :gsub('/%*.-%*/', ' '):gsub('([^:])//[^\n]*', '%1')
    for key in mapBlock:gmatch("[{,]%s*([%w_]+)%s*:") do messages[key] = true end

    local codeCount, messageCount = 0, 0
    for _ in pairs(codes) do codeCount = codeCount + 1 end
    for _ in pairs(messages) do messageCount = messageCount + 1 end

    -- The same anti-vacuity guard as checks 28 and 29: a parser that stops
    -- matching reports a clean tree.
    if codeCount < 20 or messageCount < 20 then
        failures[#failures + 1] = ((
            'the refusal-message check read %d error codes and %d messages. '
            .. 'Both are read by pattern, so this is the parser having '
            .. 'stopped matching rather than either list having shrunk.')
            :format(codeCount, messageCount))
    end

    local unworded = {}
    for value, name in pairs(codes) do
        if not messages[value] then
            unworded[#unworded + 1] = ('%s (CB.ERR.%s)'):format(value, name)
        end
    end
    table.sort(unworded)
    for _, entry in ipairs(unworded) do
        failures[#failures + 1] =
            ('the server can refuse with %s and the page has no words for it, '
             .. 'so a player is told "Something went wrong" about something '
             .. 'they could have acted on.'):format(entry)
    end
end

--------------------------------------------------------------------------

io.write(('\nstatic check: %d files\n'):format(checked))
if #failures == 0 then
    io.write('no findings\n')
    os.exit(0)
end
for _, f in ipairs(failures) do io.write('FINDING  ', f, '\n') end
io.write(('\n%d finding(s)\n'):format(#failures))
os.exit(1)
