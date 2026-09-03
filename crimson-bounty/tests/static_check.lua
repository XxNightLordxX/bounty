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

io.write(('\nstatic check: %d files\n'):format(checked))
if #failures == 0 then
    io.write('no findings\n')
    os.exit(0)
end
for _, f in ipairs(failures) do io.write('FINDING  ', f, '\n') end
io.write(('\n%d finding(s)\n'):format(#failures))
os.exit(1)
