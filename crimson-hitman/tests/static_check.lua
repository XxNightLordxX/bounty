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

local files = walk('crimson-hitman/server')
for _, f in ipairs(walk('crimson-hitman/client')) do files[#files + 1] = f end
for _, f in ipairs(walk('crimson-hitman/shared')) do files[#files + 1] = f end

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
    'data%.citizenid', 'data%.cid', 'data%.hitmanCid', 'data%.hitmanId',
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

local mainSrc = read('crimson-hitman/server/main.lua') or ''
if not mainSrc:find("require%('server%.bridges'%)%.install") then
    failures[#failures + 1] =
        'server/main.lua never installs the event bridges: damage would never be observed'
end

local bridgesSrc = read('crimson-hitman/server/bridges.lua') or ''
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
--
-- And every server file loads through that loader's namespace table
-- (CrimsonBoot.require / CrimsonBoot.requireShared), never the runtime's
-- own require: boot.lua no longer replaces it, so a bare require('server.x')
-- would pass here, where package.path resolves it, and fail on a live server.

local function moduleExists(path)
    local file = path:gsub('%.', '/') .. '.lua'
    local handle = io.open('crimson-hitman/' .. file, 'r')
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
        for module in src:gmatch("requireShared%('([%w_]+)'%)") do
            if not moduleExists('shared.' .. module) then
                failures[#failures + 1] =
                    ('%s requires shared "%s", which does not exist'):format(path, module)
            end
        end
        if path:find('/server/', 1, true) then
            local lineNo = 0
            for line in src:gmatch('[^\n]*') do
                lineNo = lineNo + 1
                local code = line:gsub('%-%-.*$', '')
                local bare = code:find('[^%w_%.]require%s*%(') or code:find('^require%s*%(')
                    or code:find('[^%w_%.]require_shared%s*%(') or code:find('^require_shared%s*%(')
                    or code:find('function%s+require[%s_(]')
                if bare then
                    failures[#failures + 1] =
                        ('%s:%d loads through the bare global require; use CrimsonBoot.require '
                            .. '(server/boot.lua): %s'):format(path, lineNo, line:gsub('^%s+', ''):sub(1, 90))
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 6. Files the manifest declares actually exist
--------------------------------------------------------------------------

local manifest = read('crimson-hitman/fxmanifest.lua') or ''
for declared in manifest:gmatch("'([%w_%-/%.]+%.%a+)'") do
    if declared:find('/') and not declared:find('^@') then
        local handle = io.open('crimson-hitman/' .. declared, 'r')
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

local uiSrc = read('crimson-hitman/ui/app.js') or ''
local clientSrc = read('crimson-hitman/client/main.lua') or ''
local appSrc = read('crimson-hitman/server/app.lua') or ''

-- Two kinds of NUI callback. The UI_EVENTS list is forwarded to the server
-- event of the same name and needs a handler there. A callback the client
-- registers by name of its own (the camera, saving a photo to the phone)
-- is answered by the client, whatever it asks the server along the way.
local clientEvents, forwarded, serverHandlers = {}, {}, {}

for list in clientSrc:gmatch('local UI_EVENTS = {(.-)}') do
    for name in list:gmatch("'([%w_]+)'") do
        clientEvents[name] = true
        forwarded[name] = true
    end
end
for name in clientSrc:gmatch("RegisterNUICallback%('crimson:([%w_]+)'") do
    clientEvents[name] = true
end
for name in appSrc:gmatch("handler%('([%w_]+)'") do serverHandlers[name] = true end

for name in uiSrc:gmatch("post%('([%w_]+)'") do
    if not clientEvents[name] then
        failures[#failures + 1] =
            ('ui/app.js calls "%s", which the client bridge does not forward'):format(name)
    elseif forwarded[name] and not serverHandlers[name] then
        failures[#failures + 1] =
            ('ui/app.js calls "%s", which no server handler answers'):format(name)
    end
end

-- And what the client asks the server for itself, from inside those.
for name in clientSrc:gmatch("App%.request%('([%w_]+)'") do
    if not serverHandlers[name] then
        failures[#failures + 1] =
            ('client/main.lua asks the server for "%s", which no handler answers'):format(name)
    end
end

--------------------------------------------------------------------------
-- 8. Every configuration key is actually read
--------------------------------------------------------------------------
--
-- A setting that nothing reads is worse than no setting: an owner tunes it,
-- nothing changes, and they have no way to tell. This walks the leaf keys in
-- config.lua and checks each one appears somewhere in the source.

local configSrc = read('crimson-hitman/config/config.lua') or ''

local sourceText = {}
for _, path in ipairs(files) do
    if not path:find('config/config%.lua') then
        sourceText[#sourceText + 1] = read(path) or ''
    end
end
sourceText[#sourceText + 1] = read('crimson-hitman/ui/app.js') or ''
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
    ambulance = true, fire = true, ems = true, sast = true, k9 = true,
    -- Death-state provider entries.
    resource = true, dead = true, lastStand = true,
    -- MIME allowlist entries and escrow blacklist entries.
    phone = true, id_card = true, driver_license = true, weaponlicense = true,
    handcuffs = true, black_money = true,
    -- Coercion detector names.
    handcuffed = true, passengerOfHitman = true,
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

local uiCode = (read('crimson-hitman/ui/app.js') or ''):gsub('/%*.-%*/', ''):gsub('//[^\n]*', '')
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
    local main = read('crimson-hitman/server/main.lua') or ''
    local harness = read('crimson-hitman/tests/run.lua') or ''

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
    local schema = read('crimson-hitman/server/storage/mysql.lua') or ''
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
            -- And the fields a contract is born with, in the constructor
            -- Contracts.create builds it from. None of them is assigned as
            -- contract.<field>, so a term only ever set there — how the
            -- contract may be completed, fulfilment_rule — passed the reads
            -- above with no column behind it. One field per line, as the
            -- constructor is written; a comment line starts with '-'.
            local born = src:match('\n%s*local contract = (%b{})')
            for name in (born or ''):gmatch('\n%s*([%a_][%w_]*)%s*=[^=]') do
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
    local src = read('crimson-hitman/tests/ui/run.js') or ''
    local path = 'crimson-hitman/tests/ui/run.js'

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
                -- drewCleanly is an assertion in its own right: it throws
                -- when the app took a render throw the harness recorded.
                -- Listed here rather than left out, because a test whose
                -- whole point is "and nothing threw" has no other one.
                local asserts = body:find('eq%s*%(') or body:find('truthy%s*%(')
                    or body:find('falsy%s*%(') or body:find('throw%s')
                    or body:find('drewCleanly%s*%(')
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
-- 14b. And the same rule for the Lua specs
--------------------------------------------------------------------------
--
-- Rule 14 read one file. Everything above it, and the eleven hundred tests
-- underneath, went unchecked — which mattered the moment several hundred
-- tests arrived at once from somewhere other than this file's author.
--
-- A Lua test body runs from `function()` to its matching `end`, and `end`
-- closes several other things too, so the depth is counted over every
-- keyword that opens a block. Keywords inside strings and comments are not
-- keywords: the first version of this check read the ` end` in a test
-- fixture's own text as the end of the test and reported four assertions it
-- had simply stopped before reaching.
--
-- A test that only calls a helper is not assertion-free either. The helpers
-- listed here all raise, so a test whose single statement is a call to one
-- still fails when it should.

do
    local OPENS = { ['function'] = true, ['if'] = true, ['for'] = true,
                    ['while'] = true, ['do'] = true }
    local HELPERS = { 'ok', 'refused', 'runRow', 'conserves', 'drewCleanly',
                      'assertRefused', 'assertOnlyAllowed', 'expectRefusal',
                      'expectOk' }

    --- Blank out every string literal and comment, keeping the length and
    --- the newlines so positions still line up with the original.
    local function withoutText(src)
        local out, i, n = {}, 1, #src
        while i <= n do
            local char = src:sub(i, i)

            if char == '-' and src:sub(i + 1, i + 1) == '-' then
                local long = src:match('^%-%-%[(=*)%[', i)
                local stop
                if long then
                    stop = src:find(']' .. long .. ']', i, true)
                    stop = stop and stop + #long + 1 or n
                else
                    stop = (src:find('\n', i, true) or n + 1) - 1
                end
                for j = i, stop do
                    out[#out + 1] = src:sub(j, j) == '\n' and '\n' or ' '
                end
                i = stop + 1

            elseif char == '"' or char == "'" then
                out[#out + 1] = ' '
                i = i + 1
                while i <= n do
                    local c = src:sub(i, i)
                    out[#out + 1] = c == '\n' and '\n' or ' '
                    i = i + 1
                    if c == '\\' then
                        if i <= n then
                            out[#out + 1] = src:sub(i, i) == '\n' and '\n' or ' '
                            i = i + 1
                        end
                    elseif c == char then
                        break
                    end
                end

            elseif char == '[' and src:match('^%[(=*)%[', i) then
                local eq = src:match('^%[(=*)%[', i)
                local stop = src:find(']' .. eq .. ']', i, true)
                stop = stop and stop + #eq + 1 or n
                for j = i, stop do
                    out[#out + 1] = src:sub(j, j) == '\n' and '\n' or ' '
                end
                i = stop + 1

            else
                out[#out + 1] = char
                i = i + 1
            end
        end
        return table.concat(out)
    end

    local specs = {}
    for _, path in ipairs(walk('crimson-hitman/tests')) do
        if path:find('_spec%.lua$') then specs[#specs + 1] = path end
    end
    table.sort(specs)

    for _, path in ipairs(specs) do
        local raw = read(path) or ''
        -- Names come from the original; structure from the blanked copy.
        local code = withoutText(raw)
        local position = 1

        while true do
            local from, to, name =
                raw:find("it%s*%(%s*'([^']+)'%s*,%s*function%s*%(%s*%)", position)
            if not from then break end
            position = to + 1

            local depth, index, close = 1, to + 1, nil
            while index <= #code do
                local wordFrom, wordTo, word = code:find('([%a_]+)', index)
                if not wordFrom then break end
                if OPENS[word] then
                    -- `for ... do` and `while ... do` open one block, not
                    -- two, so the `do` that closes their header is not
                    -- counted a second time.
                    local header = code:sub(math.max(1, wordFrom - 120), wordFrom - 1)
                    if word ~= 'do' or not header:find('[^%a_]for[^%a_]')
                        and not header:find('[^%a_]while[^%a_]') then
                        depth = depth + 1
                    end
                elseif word == 'end' then
                    depth = depth - 1
                    if depth == 0 then close = wordFrom break end
                end
                index = wordTo + 1
            end

            if close then
                local body = code:sub(to, close)
                local asserts = body:find('eq%s*%(') or body:find('truthy%s*%(')
                    or body:find('falsy%s*%(') or body:find('error%s*%(')
                if not asserts then
                    for _, helper in ipairs(HELPERS) do
                        if body:find('[^%a_]' .. helper .. '%s*%(') then
                            asserts = true
                            break
                        end
                    end
                end
                if not asserts then
                    failures[#failures + 1] =
                        ('%s: the test %q contains no assertion; it passes forever '
                         .. 'and reads as coverage'):format(path, name)
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 14c. No exported function that nothing calls
--------------------------------------------------------------------------
--
-- Kidnap.cancel and Kidnap.clearContract both sat here unreferenced, and
-- one of them was load-bearing: wiring it fixed live delivery dying
-- server-wide once the countdown cap filled with entries nothing released.
-- Neither reading the code nor running the tests found them, because a
-- function nothing calls is a function nothing exercises. Line coverage
-- found them by accident.
--
-- So: an exported server function with no reference anywhere in the
-- resource is reported, unless it is named below as a seam the suite needs
-- to see inside a module. That exemption is checked too — a seam no test
-- calls is not a seam, it is dead code with a note on it.
--
-- Passing a function by value counts as a reference: main.lua's tick is a
-- list of `job('name', Module.fn)`, and those are call sites.

do
    --- Functions that exist for the suite rather than for the resource, and
    --- what each one lets a test see.
    local SEAMS = {
        ['App.canUseApp']              = 'whether a player may ACT, which is a '
            .. 'different question from whether they may SEE the app — that one '
            .. 'is Bridges.tellAccess, and the two disagree by design when '
            .. 'Config.HideAppFromBlockedJobs is off',
        ['Audit.droppedCount']         = 'how many audit rows the queue shed at capacity',
        ['Bailout.queuedCount']        = 'how many buyouts are waiting out their delay',
        ['Bridges.accessMemoSize']     = 'that the access memo does not grow without bound',
        ['Mugshot.get']                = 'the stored image, without going through a handle',
        ['Notify.clearPush']           = 'the push cooldown, so a test can send twice',
        ['RateLimit.count']            = 'how many buckets are held, so a test can watch them expire',
        ['Mugshot.count']              = 'how many faces are cached, so a test can watch the '
            .. 'cache let go of players who left',
        -- The store's own seams. Every backend implements them so the
        -- conformance suite can ask all three the same question.
        ['Memory._raw']                = 'the raw tables, so a spec can assert on stored state',
        ['JsonStore._raw']             = 'the same, on the json backend',
        ['Memory.readAudit']           = 'the whole audit log; the resource itself only '
            .. 'ever reads one contract worth, through auditForContract',
        ['JsonStore.readAudit']        = 'the same, on the json backend',
        ['MySQLStore.readAudit']       = 'the same, on the mysql backend',
        ['MySQLStore.writeContract']   = 'the contract upsert every backend has: a create '
            .. 'writes its row through insertContract, which memory and json build on '
            .. 'writeContract, and the conformance suite writes a contract back through it '
            .. 'on all three',
        -- Client and shared.
        ['App.forgetRegistration']     = 'the client forgetting it registered the '
            .. 'app, so a test can watch the reconciler put it back',
        ['AdminPanel.isOpen']          = 'whether the admin page holds the focus, which '
            .. 'the client spec checks after each way of closing it',
        ['Util.resetMonotonic']        = 'the wrap-absorbing clock, which is not '
            .. 'reloaded between stacks and would otherwise carry one test\'s '
            .. 'elapsed time into the next',
    }

    local function read_all(dir, filter)
        local out = {}
        for _, path in ipairs(walk(dir)) do
            if not filter or filter(path) then out[#out + 1] = read(path) or '' end
        end
        return table.concat(out, '\n')
    end

    -- Comments do not call anything.
    local function code(text) return (text:gsub('%-%-[^\n]*', '')) end

    local resource = code(read_all('crimson-hitman/server')
        .. '\n' .. read_all('crimson-hitman/client')
        .. '\n' .. read_all('crimson-hitman/shared'))
    local suite = code(read_all('crimson-hitman/tests'))

    --- The names a module is actually reached by.
    ---
    --- Counting every `.name` in the resource made a common name
    --- unfalsifiable: unwiring Kidnap.cancel — the exact bug this check
    --- exists for — left it green, because Contracts.cancel, Config.Cancel
    --- and AMENDMENT.CANCEL all match a bare `cancel`.
    ---
    --- But the table a file defines is not always the name callers use. The
    --- storage backends define MySQLStore, Memory and JsonStore and are
    --- every one of them reached through a local called `storage`, so
    --- qualifying on the definition name alone reported all 127 of them.
    --- A module answers to its own table name, to its file's basename —
    --- which is the key it is wired under — and, under storage/, to
    --- `storage`.
    local function aliasesOf(path, module)
        -- Deduplicated. Photo lives in photo.lua, so the table name and the
        -- basename are the same string, and counting both counted every
        -- match twice — which made the definition itself look like a call
        -- site and reported eight live seams as "the resource calls it".
        local seen, names = {}, {}
        local function add(value)
            value = (value or ''):lower()
            if value ~= '' and not seen[value] then
                seen[value] = true
                names[#names + 1] = value
            end
        end
        add(module)
        add(path:match('([%w_]+)%.lua$'))
        if path:find('/storage/') then add('storage') end
        return names
    end

    local function countCalls(text, path, module, name)
        local lowered = text:lower()
        local total = 0
        for _, alias in ipairs(aliasesOf(path, module)) do
            for _ in lowered:gmatch('[%w_]*' .. alias .. '%s*[.:]%s*'
                .. name:lower() .. '%f[^%w_]') do
                total = total + 1
            end
            -- Called straight off the require, with no local in between:
            -- main.lua does `require('server.bridges').install(modules)`,
            -- where the module is named by a string rather than by an
            -- identifier the pattern above can see.
            for _ in lowered:gmatch("require%s*%(%s*['\"][^'\"]*" .. alias
                .. "['\"]%s*%)%s*[.:]%s*" .. name:lower() .. '%f[^%w_]') do
                total = total + 1
            end
        end
        return total
    end

    local function countDefs(text, module, name)
        local total = 0
        for _ in text:lower():gmatch('\nfunction%s+' .. module:lower()
            .. '%s*%.%s*' .. name:lower() .. '%s*%(') do
            total = total + 1
        end
        return total
    end

    local unreferenced, unusedSeams = {}, {}
    local declared = {}
    local definedIn = {}

    -- The whole resource, not just the server. App.refresh sat dead in the
    -- client for as long as this check only looked at one directory: the
    -- page drives its own refreshes through post(), and nothing had called
    -- the client's copy since that changed.
    local sources = {}
    for _, dir in ipairs({ 'crimson-hitman/server', 'crimson-hitman/client',
                           'crimson-hitman/shared' }) do
        for _, path in ipairs(walk(dir)) do sources[#sources + 1] = path end
    end
    table.sort(sources)

    for _, path in ipairs(sources) do
        local src = code(read(path) or '')
        for module, name in src:gmatch('\nfunction%s+([%w_]+)%.([%w_]+)%s*%(') do
            local full = module .. '.' .. name
            declared[full] = true
            definedIn[full] = path

            local mentions = countCalls(resource, path, module, name)
            local defs = countDefs(resource, module, name)
            -- Dispatched by name rather than called: App.handlers[name].
            local dynamic = resource:find("%['" .. name .. "'%]") ~= nil

            if mentions <= defs and not dynamic and not SEAMS[full] then
                unreferenced[#unreferenced + 1] =
                    ('%s: %s is exported and nothing in the resource calls it')
                        :format(path, full)
            end
        end
    end

    for full in pairs(SEAMS) do
        local module, name = full:match('^([%w_]+)%.([%w_]+)$')
        local path = definedIn[full] or ''
        local calledByResource = countCalls(resource, path, module, name)
        local defs = countDefs(resource, module, name)

        if not declared[full] then
            unusedSeams[#unusedSeams + 1] =
                full .. ' is named as a test seam and no longer exists'
        elseif not suite:find('[.:]' .. name .. '%s*%(') then
            unusedSeams[#unusedSeams + 1] =
                full .. ' is named as a test seam and no test calls it'
        elseif calledByResource > defs then
            -- Not a seam: the resource calls it. Left on the list it would
            -- exempt live code from ever being reported as orphaned.
            unusedSeams[#unusedSeams + 1] =
                full .. ' is named as a test seam and the resource calls it'
        end
    end

    table.sort(unreferenced)
    table.sort(unusedSeams)
    for _, line in ipairs(unreferenced) do failures[#failures + 1] = line end
    for _, line in ipairs(unusedSeams) do
        failures[#failures + 1] = 'crimson-hitman/tests/static_check.lua: ' .. line
    end
end

--------------------------------------------------------------------------
-- 15. The app never builds markup from data
--------------------------------------------------------------------------
--
-- Contract reasons, target names and hitman aliases are written by other
-- players and rendered in everyone's phone. Every one of them goes through
-- textContent today. An innerHTML assignment of anything but a literal
-- empty string is how that stops being true.

do
    local src = read('crimson-hitman/ui/app.js') or ''
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
    local util = read('crimson-hitman/shared/util.lua') or ''
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
-- the file under client_scripts, or under shared_scripts, which FiveM loads
-- on both sides. Miss it and the global is nil on the client, which throws
-- the first time the code path runs — usually the one path nobody tests by
-- hand, since the server suite loads shared modules through require_shared
-- and never notices.

do
    local clientBlock = (manifest:match('client_scripts%s*{(.-)}') or '')
        .. (manifest:match('shared_scripts%s*{(.-)}') or '')

    for _, sharedPath in ipairs(walk('crimson-hitman/shared')) do
        local src = read(sharedPath) or ''
        -- A global export is an assignment to a bare capitalised name at the
        -- start of a line: `CrimsonUtil = Util`.
        for name in src:gmatch('\n(%u[%w_]*)%s*=%s*%u') do
            local usedByClient = false
            for _, clientPath in ipairs(walk('crimson-hitman/client')) do
                local clientSrc = read(clientPath) or ''
                if clientSrc:find(name .. '%s*[%.%[]') then usedByClient = true end
            end

            local relative = sharedPath:gsub('^crimson%-hitman/', '')
            if usedByClient and not clientBlock:find(relative, 1, true) then
                failures[#failures + 1] =
                    ('the client reads the global %s, which %s assigns, but the manifest '
                     .. 'does not list %s under client_scripts or shared_scripts — the '
                     .. 'global is nil on the client'):format(name, relative, relative)
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
-- out as 14,499. The creator promised a percentage, the hitman was shown a
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
    for _, dir in ipairs({ 'crimson-hitman/client', 'crimson-hitman/server' }) do
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
    local ok, config = pcall(dofile, 'crimson-hitman/config/config.lua')
    if not ok or type(config) ~= 'table' then
        -- config.lua assigns to a global rather than returning; load it that
        -- way instead.
        local chunk = loadfile('crimson-hitman/config/config.lua')
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
    local configSrc = read('crimson-hitman/config/config.lua') or ''
    for key in configSrc:gmatch('\n%s*([%w_]+)%s*=%s*nil%s*,') do
        declaredNil[key] = true
    end

    if type(config) ~= 'table' then
        failures[#failures + 1] = 'could not load crimson-hitman/config/config.lua to check '
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
    local css = read('crimson-hitman/ui/app.css') or ''
    local js = read('crimson-hitman/ui/app.js') or ''

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
-- contract.hitmen: a creator whose contract nobody had taken yet, which is
-- every contract the moment it is placed.
--------------------------------------------------------------------------

do
    local ui = read('crimson-hitman/ui/app.js') or ''
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
    local shipped = read('crimson-hitman/config/defaults.lua') or ''
    local live = read('crimson-hitman/config/config.lua') or ''

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
    local main = read('crimson-hitman/server/main.lua') or ''
    local bridges = read('crimson-hitman/server/bridges.lua') or ''

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
    local client = read('crimson-hitman/client/main.lua')
    local page = read('crimson-hitman/ui/index.html')

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
        if not page:find('CH_BUILD', 1, true) then
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
    local amendSrc = read('crimson-hitman/server/amendments.lua') or ''
    local constSrc = read('crimson-hitman/shared/constants.lua') or ''

    -- CH.AMENDMENT.SHORTEN_DEADLINE -> 'shorten_deadline'
    local enum = {}
    local block = constSrc:match('CH%.AMENDMENT%s*=%s*(%b{})') or ''
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
    -- Not the ones posted to 'improve'. Those apply at once and are read by
    -- improveUnlocked, not sanitize, which has never had a branch for
    -- raise_bonus because nobody proposes it.
    for at, kind, body in uiSrc:gmatch("()kind:%s*'([%w_]+)'%s*,%s*payload:%s*(%b{})") do
        local before = uiSrc:sub(math.max(1, at - 120), at)
        if not before:find("post%('improve'") then record(kind, body) end
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
            for name in branch:gmatch('CH%.AMENDMENT%.([%u_]+)') do
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
    local constSrc = read('crimson-hitman/shared/constants.lua') or ''

    local codes = {}
    local errBlock = constSrc:match('CH%.ERR%s*=%s*(%b{})') or ''
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
            unworded[#unworded + 1] = ('%s (CH.ERR.%s)'):format(value, name)
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
-- 14d. No column an upsert inserts and then refuses to update
--------------------------------------------------------------------------
--
-- MySQL's ON DUPLICATE KEY UPDATE names the columns a second write is
-- allowed to change. A column left off that list is written once, at
-- creation, and every later write to it is discarded — with no error, no
-- warning, and nothing in the log.
--
-- Memory and json mode have no such list. They store what they are given.
-- So the entire suite, which runs against memory, agrees that the field was
-- saved, and the backend that ships by default quietly disagrees. Two
-- columns were sitting in exactly that state:
--
--   bonus_percent — raise_bonus escrows the difference between the stored
--   percentage and the new one, so a stale stored figure means the next
--   raise takes the same band out of the creator's pocket again, and the
--   guard against raising to a percentage already reached never fires.
--
--   expires_at — a contract's absolute lifetime.
--
-- Every inserted column must therefore be either updatable or listed below
-- as deliberately immutable, with the reason. The allowlist is checked in
-- both directions: naming a column that the statement does update, or one
-- it does not insert at all, is reported too, so this list cannot rot into
-- a blanket exemption.

do
    --- Columns an upsert deliberately writes once and never again.
    ---@type table<string, string>
    local IMMUTABLE = {
        ['crimson_contracts.id']              = 'the primary key',
        ['crimson_contracts.creator_cid']     = 'who placed it; a contract does not change hands',
        ['crimson_contracts.creator_account'] = 'the account behind the creator, fixed with them',
        ['crimson_contracts.creator_name']    = 'their name as it was when they placed it',
        ['crimson_contracts.target_cid']      = 'who it names; re-targeting is a new contract',
        ['crimson_contracts.target_account']  = 'the account behind the target, read when it was placed',
        ['crimson_contracts.target_name']     = 'their name as it was when it was placed',
        ['crimson_contracts.target_protected'] = 'judged once, at creation, against the rules then',
        ['crimson_contracts.target_job']      = 'the same: what they were doing when it was placed',
        ['crimson_contracts.anon_creator']    = 'chosen at creation and not revisitable',
        ['crimson_contracts.fulfilment_rule'] = 'how it may be completed, a term it was placed under',
        ['crimson_contracts.created_at']      = 'when it was placed',
        -- The payout counters. Move only through advanceSlot, because every
        -- other writer carries a copy read before its own awaits, and writing
        -- them back undid a claim that landed in between.
        ['crimson_contracts.next_slot']       = 'moves only through advanceSlot',
        ['crimson_contracts.slots_claimed']   = 'moves only through advanceSlot',
        ['crimson_contracts.payout_slots']    = 'moves only through reduceSlots, for the same reason',
        -- The clock. Moves only through setDeadline, startPause and endPause:
        -- the expiry pass wrote its copy over an extension made
        -- while it waited, and any other copy erased a pause it had begun.
        ['crimson_contracts.deadline_at']     = 'moves only through setDeadline and endPause',
        ['crimson_contracts.paused_ms']       = 'moves only through endPause',
        ['crimson_contracts.paused_since']    = 'moves only through startPause and endPause',
        -- The buyout queue. Moves only through setBailoutQueue and the two
        -- compare-and-sets beside it (recordBailout, clearBailout), because a
        -- caller writing back a copy it read before a buyout was paid used to
        -- erase the buyout: premium charged, nothing left to settle it.
        ['crimson_contracts.bailout_queued_at']    = 'moves only through setBailoutQueue, recordBailout '
            .. 'and clearBailout',
        ['crimson_contracts.bailout_paid_by']      = 'moves only through setBailoutQueue, recordBailout '
            .. 'and clearBailout',
        ['crimson_contracts.bailout_paid_amount']  = 'moves only through setBailoutQueue, recordBailout '
            .. 'and clearBailout',
        ['crimson_contracts.bailout_paid_account'] = 'moves only through setBailoutQueue, recordBailout '
            .. 'and clearBailout',
        ['crimson_contracts.bailout_attempts']     = 'moves only through setBailoutQueue, recordBailout '
            .. 'and clearBailout',
        ['crimson_contracts.state']           = 'moves only through compareSetContractState, which '
            .. 'is guarded; writing it from a caller-held copy could resurrect a contract that '
            .. 'closed while the caller was reading',
        ['crimson_settings.setting_key']      = 'the primary key: which setting it is',
        ['crimson_escrow.id']                 = 'the primary key',
        ['crimson_escrow.contract_id']        = 'a line does not move between contracts',
        ['crimson_escrow.slot']               = 'which payout slot it belongs to',
        ['crimson_escrow.line_portion']       = 'baseline, bonus or stake, decided when it was taken',
        ['crimson_escrow.source']             = 'the account or inventory it came out of',
        ['crimson_escrow.amount']             = 'moves only through setEscrowAmount, which is guarded',
        ['crimson_escrow.item']               = 'what was taken',
        ['crimson_escrow.quantity']           = 'how much of it',
        ['crimson_escrow.metadata']           = 'the item as it was, serial and all',
        ['crimson_escrow.staker']             = 'who put it up',
        ['crimson_escrow.taken_from']         = 'who it was taken from, when it was taken',
        ['crimson_escrow.inv_slot']           = 'the inventory slot it came from, for returning it',
        ['crimson_escrow.derived']            = 'whether this resource worked the bonus out or the '
            .. 'creator named it; a property of how the line was made',
        ['crimson_escrow.state']              = 'moves only through claimEscrowLine and '
            .. 'settleEscrowLine, which are guarded against exactly this',
        ['crimson_amendments.id']             = 'the primary key',
        ['crimson_amendments.contract_id']    = 'which contract it proposes to change',
        ['crimson_amendments.proposer']       = 'who put it forward',
        ['crimson_amendments.kind']           = 'what it proposes; a different change is a '
            .. 'different proposal, not an edit of this one',
        ['crimson_amendments.payload']        = 'the terms as proposed. Rewriting these under '
            .. 'an approval already given is the one thing this row must not allow',
        ['crimson_pending.id']                = 'the primary key',
        ['crimson_pending.cid']               = 'who is owed',
        ['crimson_pending.contract_id']       = 'what it came from',
        ['crimson_pending.line_id']           = 'the escrow line waiting to be handed over',
        ['crimson_stats.cid']                 = 'the primary key',
        ['crimson_meta.meta_key']             = 'the primary key',
        ['crimson_reveals.id']                = 'the primary key',
        ['crimson_reveals.contract_id']       = 'which contract the purchases were on',
        ['crimson_reveals.buyer_cid']         = 'who bought them',
        ['crimson_mutes.id']                  = 'the primary key',
        ['crimson_mutes.contract_id']         = 'which contract the thread is on',
        ['crimson_mutes.thread_id']           = 'which thread was muted',
        ['crimson_mutes.cid']                 = 'who muted it',
        -- A review item is written once and never over (writeReview's
        -- update clause changes nothing): a write the store reported as
        -- failed may have landed, and the queue writes it again, so writing
        -- over would put back open an item staff had resolved meanwhile, to
        -- be paid a second time. Its state and resolution move only through
        -- setReviewState, which is guarded.
        ['crimson_review.kind']               = 'what happened, when it happened',
        ['crimson_review.contract_id']        = 'which contract it happened on',
        ['crimson_review.cids']               = 'who was involved',
        ['crimson_review.amount']             = 'how much was involved',
        ['crimson_review.account']            = 'which account it was in',
        ['crimson_review.items']              = 'which lines or goods were involved',
        ['crimson_review.known']              = 'what could be told at the time',
        ['crimson_review.created_at']         = 'when it was left for staff',
        ['crimson_review.state']              = 'moves only through setReviewState, which is guarded',
        ['crimson_review.resolution']         = 'moves only through setReviewState',
        ['crimson_review.resolved_by']        = 'moves only through setReviewState',
        ['crimson_review.resolved_at']        = 'moves only through setReviewState',
    }

    --- What the rule finds in a source's statements: the findings, and every
    --- column some statement inserts.
    ---
    --- A statement whose update clause is `id = id` changes nothing: it is an
    --- insert that leaves a row already there alone (writeReview, and the
    --- insert-if-absent writes a take and a create make, insertEscrow and
    --- insertContract), and nothing it inserts is written again by it, so it
    --- needs no IMMUTABLE entry. One that updates a column still lists every
    --- other.
    ---@return string[] found
    ---@return table<string, boolean> seen
    local function upsertFindings(sql, immutable)
        local found, seen = {}, {}
        for statement in sql:gmatch('INSERT%s+INTO.-%]%]') do
            local table_ = statement:match('INSERT%s+INTO%s+([%w_]+)')
            local update = statement:match('ON DUPLICATE KEY UPDATE(.*)$')
            if table_ and update then
                -- Comments inside the clause carry column names in prose.
                update = update:gsub('%-%-[^\n]*', '')
                local insertOnly = update:gsub('%]%]$', ''):match('^%s*id%s*=%s*id%s*$') ~= nil

                local updated = {}
                for name in update:gmatch('([%w_]+)%s*=') do updated[name] = true end

                local columns = statement:match('INSERT%s+INTO%s+[%w_]+%s*%((.-)%)')
                for name in (columns or ''):gmatch('[%w_]+') do
                    local key = table_ .. '.' .. name
                    seen[key] = true
                    if insertOnly then
                        -- Nothing to discard: it writes a row once or not at all.
                    elseif not updated[name] and not immutable[key] then
                        found[#found + 1] = ('%s is inserted and then left out of the '
                            .. 'ON DUPLICATE KEY UPDATE list, so every write to it after the '
                            .. 'first is discarded on the backend that ships by default — '
                            .. 'silently, and only there. Add it to the update list, or to '
                            .. 'IMMUTABLE in static_check with the reason it never changes.')
                            :format(key)
                    elseif updated[name] and immutable[key] then
                        found[#found + 1] = ('%s is named as deliberately immutable and '
                            .. 'the statement updates it. One of the two is wrong.'):format(key)
                    end
                end
            end
        end
        return found, seen
    end

    -- The rule checked on its own samples first, so a clean run of it
    -- means something: an insert-only statement with a column nobody
    -- listed finds nothing, and an upsert that updates one column and
    -- leaves another unlisted still finds that one.
    local sample = table.concat({
        'local A = [[\n    INSERT INTO crimson_x (id, a) VALUES (?,?)\n',
        '    ON DUPLICATE KEY UPDATE id = id\n]]\n',
        'local B = [[\n    INSERT INTO crimson_y (id, a, b) VALUES (?,?,?)\n',
        '    ON DUPLICATE KEY UPDATE a = VALUES(a)\n]]\n',
    })
    local probe = upsertFindings(sample, { ['crimson_y.id'] = 'the key' })
    if #probe ~= 1 or not probe[1]:find('crimson_y.b', 1, true) then
        failures[#failures + 1] = ('the upsert column rule found %d thing(s) in its own sample, '
            .. 'not the one unlisted column of the upsert: %s'):format(#probe, table.concat(probe, '; '))
    end

    local sql = read('crimson-hitman/server/storage/mysql.lua')
    if sql then
        local found, seen = upsertFindings(sql, IMMUTABLE)
        for _, line in ipairs(found) do failures[#failures + 1] = line end

        for key in pairs(IMMUTABLE) do
            if not seen[key] then
                failures[#failures + 1] = ('%s is named as deliberately immutable and no upsert '
                    .. 'inserts it. A stale exemption is one that stops being checked.'):format(key)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 14e. No terminal state nothing can reach
--------------------------------------------------------------------------
--
-- CH.STATE.VOIDED was declared, marked terminal, allowed as a transition
-- from ACTIVE and ACCEPTED, and commented "admin" — and nothing ever set
-- it. The one command that should, Admin.void, resolved to CANCELLED, which
-- is the state that means the CREATOR changed their mind: so a staff member
-- voiding a contract to fix something charged the person they were helping
-- the cooldown for cancelling their own listing.
--
-- A state the machine declares is a promise that something reaches it.
-- Every state named as a transition target must therefore be passed to
-- Contracts.resolve or Contracts.transition somewhere in the server.

do
    local constants = read('crimson-hitman/shared/constants.lua') or ''

    --- Every state named as the destination of a legal transition.
    local targets = {}
    local table_ = constants:match('CH%.TRANSITIONS%s*=%s*{(.*)\n}') or ''
    for name in table_:gmatch('%[CH%.STATE%.(%u[%u_]*)%]%s*=%s*true') do
        targets[name] = true
    end

    if next(targets) == nil then
        failures[#failures + 1] = 'the transition table could not be read, so '
            .. 'this rule is checking nothing.'
    end

    --- Where a state is actually moved to.
    local reached = {}
    for _, path in ipairs(walk('crimson-hitman/server')) do
        -- Comments name states in prose; blanking them keeps a note about
        -- CANCELLED from reading as a call that reaches it.
        local src = (read(path) or ''):gsub('%-%-[^\n]*', '')
        for call in src:gmatch('%.%s*resolve%s*%b()') do
            for name in call:gmatch('CH%.STATE%.(%u[%u_]*)') do reached[name] = true end
        end
        for call in src:gmatch('%.%s*transition%s*%b()') do
            for name in call:gmatch('CH%.STATE%.(%u[%u_]*)') do reached[name] = true end
        end
    end

    local unreachable = {}
    for name in pairs(targets) do
        if not reached[name] then unreachable[#unreachable + 1] = name end
    end
    table.sort(unreachable)

    for _, name in ipairs(unreachable) do
        failures[#failures + 1] = ('CH.STATE.%s is declared as a legal transition '
            .. 'target and nothing ever moves a contract to it. Either something '
            .. 'should and does not — which is a contract ending in the wrong '
            .. 'state, with whatever that state\'s cooldowns and wording bring '
            .. 'with it — or the transition should not be declared.'):format(name)
    end
end

--------------------------------------------------------------------------
-- 31. A BOOL native's answer is never compared with true
--------------------------------------------------------------------------
--
-- FXServer hands a BOOL native's answer to Lua as the integer 1 or false,
-- never true, unless the manifest opts into fxv2, and fxmanifest.lua does
-- not. `IsPlayerAceAllowed(src, ace) == true` was therefore false for
-- everybody: it refused every staff command in game, and passed here while
-- the stub answered true. Read a BOOL native for truth, or normalise it
-- with `== 1 or == true` where a real boolean has to leave the function.
--
-- No list of BOOL natives is kept, because the shape is wrong for every
-- native: the others answer numbers, strings, vectors or tables, none of
-- them true either. A native here is a bare capitalised name called as a
-- function that this resource does not define, as a global anywhere or a
-- local in that file; `Storage.readMute(...) == true` and the like are
-- the resource's own. GetStateBagValue alone is let through: it hands back
-- whatever was stored, and true can be.

do
    local ANSWERS_ANYTHING = { GetStateBagValue = true }

    --- Comments blanked, newlines kept, so a line number still points at
    --- the line, and prose about `== true` is not code.
    local function code(text)
        text = text:gsub('(%-%-%[(=*)%[.-%]%2%])', function(whole)
            return (whole:gsub('[^\n]', ''))
        end)
        return (text:gsub('%-%-[^\n]*', ''))
    end

    --- Every `Name(...) == true` / `~= true`, and `true == Name(...)`,
    --- where Name is not one of `defined`: { line, name } each.
    local function comparedWithTrue(text, defined)
        local out = {}
        local function lineAt(pos)
            local _, n = text:sub(1, pos):gsub('\n', '')
            return n + 1
        end
        local function native(pos, name)
            local before = pos > 1 and text:sub(pos - 1, pos - 1) or ''
            return not before:find('[%w_%.:]') and not defined[name]
                and not ANSWERS_ANYTHING[name]
        end
        for pos, name in text:gmatch('()(%u[%w_]*)%s*%b()%s*[~=]=%s*true%f[^%w_]') do
            if native(pos, name) then out[#out + 1] = { line = lineAt(pos), name = name } end
        end
        for pos, name in text:gmatch('%f[%w_]true%s*[~=]=%s*()(%u[%w_]*)%s*%b()') do
            if native(pos, name) then out[#out + 1] = { line = lineAt(pos), name = name } end
        end
        return out
    end

    -- What the resource defines itself: global functions and assignments
    -- anywhere, and each file's own locals.
    local globals, sources = {}, {}
    for _, path in ipairs(files) do
        local text = code(read(path) or '')
        sources[path] = text
        for name in text:gmatch('%f[%w_]function%s+(%u[%w_]*)%s*%(') do globals[name] = true end
        for name in ('\n' .. text):gmatch('\n(%u[%w_]*)%s*=[^=]') do globals[name] = true end
    end

    -- The same anti-vacuity guard as checks 28 to 30: a pattern that stops
    -- matching reports a clean tree.
    local probe = comparedWithTrue(code(table.concat({
        'if IsPlayerAceAllowed(src, (\'crimson.%s\'):format(x)) == true then end',
        'local gone = true ~= DoesEntityExist(ped) -- == true',
        'local mine = Util.isReady() == true or IsReady() == true',
        '-- IsEntityDead(ped) == true',
    }, '\n')), { IsReady = true })
    if #probe ~= 2 or probe[1].name ~= 'IsPlayerAceAllowed' or probe[2].name ~= 'DoesEntityExist' then
        failures[#failures + 1] =
            'the BOOL-native check no longer finds `IsPlayerAceAllowed(...) == true` and '
            .. '`true ~= DoesEntityExist(...)` alone in its own sample, so a clean run of it '
            .. 'means nothing'
    end

    for _, path in ipairs(files) do
        local text = sources[path]
        local defined = setmetatable({}, { __index = globals })
        for name in text:gmatch('local%s+function%s+(%u[%w_]*)') do defined[name] = true end
        for name in text:gmatch('local%s+(%u[%w_]*)') do defined[name] = true end
        for _, hit in ipairs(comparedWithTrue(text, defined)) do
            failures[#failures + 1] =
                ('%s:%d compares %s(...) with true. FXServer answers a BOOL native with 1 '
                 .. 'or false, never true, so in game this comes out the same every time; '
                 .. 'test it for truth instead.'):format(path, hit.line, hit.name)
        end
    end
end

--------------------------------------------------------------------------
-- No ':' or '@' in any SQL the MySQL store sends.
--
-- Parameters here are positional Lua tables, and FiveM sends a table with a
-- nil in it as a map, not a list. Given a map, oxmysql compiles the
-- statement for named placeholders whenever its text holds ':' or '@' —
-- a colon in a comment is enough — and then numbers the '?' from 0, so
-- every value lands one column over: the id went in as NULL and the write
-- failed, for every contract, amendment and escrow line.
--------------------------------------------------------------------------

do
    local path = 'crimson-hitman/server/storage/mysql.lua'
    local f = io.open(path, 'r')
    local src = f and f:read('*a') or ''
    if f then f:close() end
    --- Where a source has SQL holding ':' or '@': its long strings, and its
    --- quoted ones in either kind of quote.
    local function marked(text)
        local out = {}
        local function checkSql(body, where)
            local sql = body:upper()
            if not (sql:find('SELECT') or sql:find('INSERT') or sql:find('UPDATE')
                or sql:find('DELETE') or sql:find('CREATE') or sql:find('ALTER')) then return end
            if body:find('[:@]') then out[#out + 1] = where end
        end
        for _, body in text:gmatch('%[(=*)%[(.-)%]%1%]') do
            local line = body:match('[^\n]*[:@][^\n]*') or ''
            checkSql(body, (line:gsub('^%s+', '')))
        end
        for body in text:gmatch("'([^'\n]*)'") do checkSql(body, body) end
        for body in text:gmatch('"([^"\n]*)"') do checkSql(body, body) end
        return out
    end

    -- Not vacuous: a colon in a SQL comment in a long string, and an @ in
    -- SQL in double quotes, are found; a key built with a colon is not.
    local probe = marked(table.concat({
        'local a = [[SELECT ? FROM t -- note: x]]',
        'local b = "SELECT * FROM t WHERE a = @b"',
        "local key = contractId .. ':' .. cid",
        "local c = 'SELECT * FROM t WHERE id = ?'",
    }, '\n'))
    if #probe ~= 2 then
        failures[#failures + 1] = ('the SQL colon check found %d of the two marked statements in '
            .. 'its own sample, so a clean run of it means nothing'):format(#probe)
    end

    for _, where in ipairs(marked(src)) do
        failures[#failures + 1] = ('%s has a SQL statement containing \':\' or \'@\' '
            .. '(%s). oxmysql reads that as named placeholders whenever the '
            .. 'parameters arrive as a map, which they do whenever one is nil, '
            .. 'and every value shifts a column. Reword the comment.'):format(path, where)
    end
end

--------------------------------------------------------------------------
-- Every claim of an escrow line (held -> releasing) goes through claimLine.
--
-- /ch-stuck lists, and /ch-settle puts back, a `releasing` line that no
-- call in this process holds, and the set of claims in flight is the only
-- thing that says which those are. claimLine counts a claim in it before
-- the claim is made. A staff `delivered` and a split being voided claimed
-- straight from the store instead: a /ch-settle landing meanwhile put the
-- live claim back as stuck and paid the line on top of the delivered.
--------------------------------------------------------------------------

do
    local home = 'crimson-hitman/server/escrow.lua'
    for _, path in ipairs(files) do
        local src = read(path)
        if src and path:find('/server/', 1, true) then
            -- Comments out, keeping every line where it was.
            src = src:gsub('(%-%-%[(=*)%[.-%]%2%])', function(c) return (c:gsub('[^\n]', '')) end)
                :gsub('%-%-[^\n]*', '')
            local from, to = nil, nil
            if path == home then
                from = src:find('local function claimLine%(')
                to = from and src:find('\nend', from, true)
            end
            local at = 1
            while true do
                local s, e, args = src:find('claimEscrowLine%s*(%b())', at)
                if not s then break end
                at = e + 1
                local held = args:find('ESCROW_STATE%.HELD')
                local releasing = args:find('ESCROW_STATE%.RELEASING')
                if held and releasing and held < releasing
                    and not (from and to and s > from and s < to) then
                    local _, lineNo = src:sub(1, s):gsub('\n', '')
                    failures[#failures + 1] = ('%s:%d claims an escrow line from the store '
                        .. 'directly. Claim it through claimLine (escrow.lua), which counts it '
                        .. 'in flight first: a claim outside that set is one /ch-settle puts back '
                        .. 'as stuck while it is still being settled.'):format(path, lineNo + 1)
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- 32. The staff panel's page (ui/admin.js) asks only for what is answered,
-- and builds markup only through its escaping helper.
--------------------------------------------------------------------------
--
-- The panel's page posts an op to the client, which carries it to
-- server/panel.lua; an op the server does not list answers unknown_op, and
-- the button that sent it does nothing a staff member can understand. Its
-- rows carry player-written text in nearly every cell, so the one way
-- markup reaches the page is setHtml(), which takes only what h() made, and
-- h() escapes every value. And it is a CEF page: no native dialog (they
-- never show), no native <select> (its popup is drawn wrongly).
--------------------------------------------------------------------------

do
    local page = read('crimson-hitman/ui/admin.js') or ''
    local html = read('crimson-hitman/ui/admin.html') or ''
    local css = (read('crimson-hitman/ui/admin.css') or ''):gsub('/%*.-%*/', '')
    local panelSrc = read('crimson-hitman/server/panel.lua') or ''
    local clientAdmin = read('crimson-hitman/client/admin.lua') or ''
    local code = page:gsub('/%*.-%*/', ''):gsub('\n%s*//[^\n]*', '\n')

    if page == '' then failures[#failures + 1] = 'ui/admin.js is missing' end

    -- Every op the page asks for is one the server answers, and every op
    -- the server answers has a control on the page (but `access`, which the
    -- page is told as it opens).
    local ops, used = {}, {}
    for name in (panelSrc:match('local OPS = (%b{})') or ''):gmatch('([%a_][%w_]*)%s*=%s*%u+') do
        ops[name] = true
    end
    for _, call in ipairs({ "ask%('([%w_]+)'", "write%('([%w_]+)'" }) do
        for name in code:gmatch(call) do
            used[name] = true
            if not ops[name] then
                failures[#failures + 1] = ('ui/admin.js asks for "%s", which server/panel.lua does '
                    .. 'not answer (OPS)'):format(name)
            end
        end
    end
    for name in pairs(ops) do
        if not used[name] and name ~= 'access' then
            failures[#failures + 1] = ('server/panel.lua answers "%s", and nothing on the staff '
                .. 'panel\'s page asks for it'):format(name)
        end
    end

    -- Every NUI callback it posts to is one client/admin.lua registers.
    local callbacks = {}
    for name in clientAdmin:gmatch("RegisterNUICallback%('([%w_]+)'") do callbacks[name] = true end
    for name in code:gmatch("nui%('([%w_]+)'") do
        if not callbacks[name] then
            failures[#failures + 1] = ('ui/admin.js posts to "%s", which client/admin.lua does not '
                .. 'register'):format(name)
        end
    end

    -- The resource's name from FiveM, never written into a URL.
    if not code:find('GetParentResourceName', 1, true) then
        failures[#failures + 1] = 'ui/admin.js does not take its resource name from GetParentResourceName()'
    end
    if code:find("https://crimson%-hitman") then
        failures[#failures + 1] = 'ui/admin.js posts to a hard-coded resource name'
    end

    -- One innerHTML assignment, of what h() made; nothing else that parses.
    local assignments = {}
    for value in code:gmatch('innerHTML%s*=%s*([^;\n]+)') do assignments[#assignments + 1] = value end
    if #assignments ~= 1 or not assignments[1]:find("markup instanceof Markup ? markup.html : ''", 1, true) then
        failures[#failures + 1] = ('ui/admin.js sets innerHTML %d time(s); the one place is setHtml(), '
            .. 'which takes only what h() made'):format(#assignments)
    end
    for _, sink in ipairs({ 'insertAdjacentHTML', 'document%.write', 'outerHTML%s*=', 'new Markup%(' }) do
        local count = select(2, code:gsub(sink, ''))
        -- Markup objects are made in h() and frag() only.
        local allowed = sink == 'new Markup%(' and 3 or 0
        if count > allowed then
            failures[#failures + 1] = ('ui/admin.js uses %s outside h() and frag()'):format((sink:gsub('%%', '')))
        end
    end
    if not code:find("return esc(child);", 1, true) or not code:find("'=\"' + esc(v) + '\"'", 1, true) then
        failures[#failures + 1] = 'ui/admin.js: h() no longer escapes every text and attribute value'
    end

    -- No native dialog, no native select.
    for _, dialog in ipairs({ 'confirm', 'prompt', 'alert' }) do
        local call = dialog .. '%s*%('
        if code:find('window%.' .. call) or code:find('[^%w_%.]' .. call) then
            failures[#failures + 1] = ('ui/admin.js uses a native browser dialog (%s), which FiveM NUI '
                .. 'never shows'):format(dialog)
        end
    end
    if code:find("h%('select") or code:find("createElement%('select'%)") or html:find('<select') then
        failures[#failures + 1] = 'the staff panel draws a native <select>; use its own dropdown (CEF draws the popup wrongly)'
    end

    -- Its script and stylesheet are loaded with a build query, as the phone
    -- page's are, or CEF keeps the copy it first saw.
    if html:match('src%s*=%s*"admin%.js"') or html:match('href%s*=%s*"admin%.css"')
        or not html:find("'admin.js?v='", 1, true) or not html:find("'admin.css?v='", 1, true) then
        failures[#failures + 1] = 'ui/admin.html loads admin.js or admin.css without a build query'
    end

    -- Every class it draws is one admin.css defines (Font Awesome's aside).
    local seen = {}
    local function check(class, where)
        if seen[class] or class == '' or class:find('^fa%-') or class:sub(-1) == '-' then return end
        seen[class] = true
        if not css:find('%.' .. class:gsub('%-', '%%-') .. '[^%w_%-]') then
            failures[#failures + 1] = ('%s draws the class %q, which ui/admin.css does not define. '
                .. 'It renders unstyled and says nothing.'):format(where, class)
        end
    end
    for spec in code:gmatch("h%('[%a%d]+([%.%w_%-]*)'") do
        for class in spec:gmatch('%.([%w_%-]+)') do check(class, 'ui/admin.js') end
    end
    for _, fn in ipairs({ 'btn', 'writeBtn', 'card', 'tile', 'dropdown' }) do
        for spec in code:gmatch(fn .. "%(%s*'([%.%w_%-]+)'") do
            for class in spec:gmatch('%.([%w_%-]+)') do check(class, 'ui/admin.js') end
        end
    end
    for list in code:gmatch("class: '([%w_%- ]+)'") do
        for class in list:gmatch('[%w_%-]+') do check(class, 'ui/admin.js') end
    end
    for list in html:gmatch('class="([^"]+)"') do
        for class in list:gmatch('[%w_%-]+') do check(class, 'ui/admin.html') end
    end
end

--------------------------------------------------------------------------
-- 33. Nothing prints but the logger (shared/log.lua).
--------------------------------------------------------------------------
--
-- With Config.Debug off the console stays quiet, and that holds only if
-- every line goes through the one logger, which decides by kind whether it
-- is printed (Log.always, Log.problem, Log.debug) and keeps it for the
-- diagnosis either way. A bare print in server/, client/ or shared/ is a
-- line that prints whatever Debug says and that the diagnosis never sees.
-- The harness and the tests are not walked here, so they print as they like.
--------------------------------------------------------------------------

do
    local LOGGER = 'crimson-hitman/shared/log.lua'
    local SINKS = {
        { pattern = '%f[%w_%.:]print%s*%(', name = 'print' },
        { pattern = '%f[%w_%.:]warn%s*%(', name = 'warn' },
        { pattern = 'Citizen%.Trace%s*%(', name = 'Citizen.Trace' },
        { pattern = 'lib%.print', name = 'lib.print' },
    }
    -- Comments out, keeping every line where it was; string contents out
    -- too, so a sentence that says print( is not a call.
    local function codeOf(src)
        return src:gsub('(%-%-%[(=*)%[.-%]%2%])', function(c) return (c:gsub('[^\n]', '')) end)
            :gsub('%-%-[^\n]*', '')
            :gsub("'[^'\n]*'", "''"):gsub('"[^"\n]*"', '""')
    end
    local function sinksIn(src)
        local out = {}
        local code = codeOf(src)
        for _, sink in ipairs(SINKS) do
            local at = 1
            while true do
                local s = code:find(sink.pattern, at)
                if not s then break end
                local _, lineNo = code:sub(1, s):gsub('\n', '')
                out[#out + 1] = { line = lineNo + 1, name = sink.name }
                at = s + 1
            end
        end
        return out
    end

    -- Not vacuous: the patterns find each sink in a sample, and nothing in
    -- a comment, a string or a table named warn.
    local probe = sinksIn(table.concat({
        'print("x")', 'local t = {} warn[#warn + 1] = 1', 'warn("y")', 'Citizen.Trace("z")',
        'lib.print.info("w")', '-- print("in a comment")', "local s = 'print(it)'",
        'Log.debug("fine") Log.always("fine")', 'x.print("a method")',
    }, '\n'))
    local names = {}
    for _, hit in ipairs(probe) do names[#names + 1] = hit.name end
    table.sort(names)
    if table.concat(names, ',') ~= 'Citizen.Trace,lib.print,print,warn' then
        failures[#failures + 1] = ('the bare-print check no longer finds exactly print, warn, '
            .. 'Citizen.Trace and lib.print in its own sample (found %s), so a clean run of it '
            .. 'means nothing'):format(table.concat(names, ','))
    end

    local logger = read(LOGGER) or ''
    if not logger:find('local function emit%(text%)%s*print%(') then
        failures[#failures + 1] = 'shared/log.lua no longer prints through its one emit(), which '
            .. 'every kind of line is held to'
    end

    for _, path in ipairs(files) do
        if path ~= LOGGER then
            for _, hit in ipairs(sinksIn(read(path) or '')) do
                failures[#failures + 1] = ('%s:%d calls %s directly. Every line goes through the '
                    .. 'logger (shared/log.lua): Log.always for refusing to start, money left for '
                    .. 'staff or a write that failed, Log.problem for a setting found wrong at '
                    .. 'start, Log.debug for everything else, Log.console for a command\'s answer.')
                    :format(path, hit.line, hit.name)
            end
        end
    end
end

--------------------------------------------------------------------------
-- 34. Every mysql table is named in the README's account of the database
--------------------------------------------------------------------------
-- The paragraph for an owner whose database user cannot create or alter
-- tables listed what 1.1.0 adds as six columns, and not the two new tables
-- (crimson_review, crimson_settings) that user has to import or have made:
-- the start then refused on both. Every CREATE TABLE in mysql.lua's SCHEMA
-- is named in the README's Install section, where that account is.

do
    local function unnamedTables(schemaSrc, readme)
        local section = readme:match('\n## Install\n(.-)\n## ') or ''
        local out = {}
        for name in schemaSrc:gmatch('CREATE TABLE IF NOT EXISTS (crimson_[%w_]+)') do
            if not section:find('`' .. name .. '`', 1, true) then out[#out + 1] = name end
        end
        return out
    end

    -- Not vacuous: a table left out of the section is found.
    local probe = unnamedTables('CREATE TABLE IF NOT EXISTS crimson_a (\nCREATE TABLE IF NOT EXISTS crimson_b (',
        '\n## Install\nThe tables are `crimson_a`.\n## Next\n`crimson_b`')
    if #probe ~= 1 or probe[1] ~= 'crimson_b' then
        failures[#failures + 1] = 'the README table check no longer finds a table its own sample '
            .. 'leaves out, so a clean run of it means nothing'
    end

    local schemaSrc = read('crimson-hitman/server/storage/mysql.lua') or ''
    local readme = read('crimson-hitman/README.md') or ''
    local _, tables = schemaSrc:gsub('CREATE TABLE IF NOT EXISTS crimson_', '')
    if tables < 15 then
        failures[#failures + 1] = ('the README table check found %d tables in mysql.lua; it reads '
            .. 'SCHEMA wrongly'):format(tables)
    end
    if not readme:find('\n## Install\n', 1, true) then
        failures[#failures + 1] = 'README.md has no "## Install" section for the table check to read'
    end
    for _, name in ipairs(unnamedTables(schemaSrc, readme)) do
        failures[#failures + 1] = ('README.md\'s Install section does not name the table %s, '
            .. 'which mysql mode creates (server/storage/mysql.lua SCHEMA): an owner whose user '
            .. 'cannot create tables is not told to import it'):format(name)
    end
end

--------------------------------------------------------------------------
-- 35. Every error's text kept for staff is cleaned where it is stored
--------------------------------------------------------------------------
-- oxmysql's message lists every value the statement was sent, and a write
-- of a contract sends the client's citizen id, licence and name: kept whole
-- in an audit row (contract_write_failed and every row that keeps an
-- `error`), an anonymous client was named to every staff member who read the
-- log or the contract's timeline. Every row goes through Audit's queue
-- (server/audit.lua push), which keeps an error's text as Util.dbError cuts
-- it, so no caller can store one whole; nothing but Audit writes the log;
-- and a review item keeps its own `known.error` the same way (Review.open).

do
    --- What is wrong with how a source keeps error text, or nil.
    local function auditKeepsWhole(auditSrc)
        local push = auditSrc:match('local function push%(.-\nend\n') or ''
        if not push:find('detail = cleaned%(detail%)') then
            return 'server/audit.lua push no longer stores a row\'s detail as cleaned(detail)'
        end
        local clean = auditSrc:match('local function cleaned%(.-\nend\n') or ''
        if not clean:find('Util.dbError(', 1, true) then
            return 'server/audit.lua cleaned no longer passes an error\'s text through Util.dbError'
        end
        return nil
    end

    --- Files that write the log without going through Audit's queue.
    local function writersBesideAudit(sources)
        local out = {}
        for path, src in pairs(sources) do
            if not path:find('server/audit%.lua$') and not path:find('server/storage/') then
                for line in src:gmatch('[^\n]+') do
                    if not line:match('^%s*%-%-') and line:find('%.writeAudit') then
                        out[#out + 1] = path
                        break
                    end
                end
            end
        end
        return out
    end

    -- Not vacuous: each finds what its subject put back would be.
    if not auditKeepsWhole('local function cleaned(detail)\n    return detail\nend\n'
        .. 'local function push(kind)\n    queue[1] = { detail = cleaned(detail) or {} }\nend\n') then
        failures[#failures + 1] = 'the error-text check no longer finds a cleaned() without '
            .. 'Util.dbError, so a clean run of it means nothing'
    end
    if not auditKeepsWhole('local function cleaned(detail)\n    return Util.dbError(detail)\nend\n'
        .. 'local function push(kind)\n    queue[1] = { detail = detail or {} }\nend\n') then
        failures[#failures + 1] = 'the error-text check no longer finds a push that stores the '
            .. 'detail as it came, so a clean run of it means nothing'
    end
    local probe = writersBesideAudit({ ['crimson-hitman/server/x.lua'] = 'Storage.writeAudit(row)' })
    if #probe ~= 1 then
        failures[#failures + 1] = 'the error-text check no longer finds a file writing the log '
            .. 'beside Audit, so a clean run of it means nothing'
    end

    local auditSrc = read('crimson-hitman/server/audit.lua') or ''
    local why = auditKeepsWhole(auditSrc)
    if why then
        failures[#failures + 1] = why .. ': an error kept in an audit row keeps the values its '
            .. 'statement was sent, an anonymous client\'s citizen id, licence and name among them'
    end
    local sources = {}
    for _, path in ipairs(files) do sources[path] = read(path) or '' end
    for _, path in ipairs(writersBesideAudit(sources)) do
        failures[#failures + 1] = ('%s writes the audit log itself, past Audit\'s queue, which '
            .. 'is where an error\'s text is cleaned (Util.dbError)'):format(path)
    end
    local reviewSrc = read('crimson-hitman/server/review.lua') or ''
    if not reviewSrc:find('known[key] = Util.dbError(known[key])', 1, true) then
        failures[#failures + 1] = 'server/review.lua Review.open no longer keeps known.error and '
            .. 'known.read_error as Util.dbError cuts them'
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
