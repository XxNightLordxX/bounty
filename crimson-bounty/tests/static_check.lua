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
            local upper = line:upper()
            local looksLikeSql = false
            for _, verb in ipairs(SQL_VERBS) do
                if upper:find(verb, 1, true) then looksLikeSql = true end
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

io.write(('\nstatic check: %d files\n'):format(checked))
if #failures == 0 then
    io.write('no findings\n')
    os.exit(0)
end
for _, f in ipairs(failures) do io.write('FINDING  ', f, '\n') end
io.write(('\n%d finding(s)\n'):format(#failures))
os.exit(1)
