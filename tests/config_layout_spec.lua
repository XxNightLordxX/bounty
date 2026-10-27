--- config/config.lua as the one short file an owner reads: every setting
--- still in it with the value it had, defaults.lua in step with it, and the
--- README's reference covering each one.
---
--- The file was rewritten from some 1,400 lines of comments into short
--- sections, and nothing but three values was meant to change. That is
--- proved against the file as it stood before the rewrite, read from git:
--- every value, every key, every type, the same, except Config.Debug (now
--- on), Config.Kidnap.RequireCoercion (now off) and
--- Config.Diagnostics.SlowJobMs (now 25).

--- The commit the rewrite started from.
local BEFORE = '369e576211c9de5c3d62123941069b418a2d8a95'
local CHANGED = {
    ['Debug'] = { false, true },
    ['Kidnap.RequireCoercion'] = { true, false },
    ['Diagnostics.SlowJobMs'] = { 5, 25 },
    ['Database.Mode'] = { 'json', 'mysql' },
    -- The target's informant: a chance roll on a pick of the target's,
    -- with the proximity rule taken out (the owner's request).
    ['Informant.RequireProximity'] = { true, nil },
    ['Informant.ProximityWindowMinutes'] = { 10, nil },
    ['Informant.RevealChancePercent'] = { nil, 10 },
    -- The placer's informant, new, and its own rate-limit bucket.
    ['PlacerInformant'] = { nil, {
        Enabled = true, Cost = 25000, Account = 'bank', RevealChancePercent = 20,
        AlertChancePercent = 20, RevealMode = 'name', MaxPurchasesPerContract = 2,
        CooldownMinutes = 10,
    } },
    ['Cooldowns.placerInformant'] = { nil, { per = 300, burst = 1 } },
}

--- Settings added since the rewrite, by the path the comparison reports
--- them under (a whole new section or record), with what they ship as.
local ADDED = {
    ['LocationTip'] = {
        Enabled = true, Cost = 25000, Account = 'bank', RadiusMeters = 350, ShowMinutes = 10,
        CooldownMinutes = 10, MaxPurchasesPerContract = 3, NotifyTarget = true,
    },
    ['Cooldowns.locationTip'] = { per = 60, burst = 2 },
    ['Advisory.OnLocationTip'] = true,
}

--- A config file's text run on its own, into a table of its own.
local function run(text, global, name)
    local env = setmetatable({}, { __index = function(_, key)
        if key == global then return nil end
        return _G[key]
    end })
    local chunk = assert(load(text, '=' .. name, 't', env))
    chunk()
    return rawget(env, global)
end

local function file(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

local function before()
    local pipe = io.popen(('git show %s:crimson-hitman/config/config.lua 2>/dev/null'):format(BEFORE))
    local text = pipe and pipe:read('a') or ''
    if pipe then pipe:close() end
    return text
end

--- Every leaf of `a` and `b` that differs, by its path, and every leaf in one
--- and not the other. Numbers are compared with their kind as well
--- (12.0 is not 12 to math.type).
local function differences(a, b)
    local out = {}
    local function walk(x, y, path)
        if type(x) == 'table' and type(y) == 'table' then
            local keys = {}
            for k in pairs(x) do keys[k] = true end
            for k in pairs(y) do keys[k] = true end
            for k in pairs(keys) do
                walk(x[k], y[k], path == '' and tostring(k) or (path .. '.' .. tostring(k)))
            end
        elseif x ~= y or math.type(x) ~= math.type(y) then
            out[path] = { x, y }
        end
    end
    walk(a, b, '')
    return out
end

describe('the configuration as one short file', function()
    local old = before()

    it('can read the file as it was before it was shortened', function()
        truthy(#old > 10000, 'git show ' .. BEFORE .. ':crimson-hitman/config/config.lua gave '
            .. #old .. ' bytes; this test needs the repository history')
    end)

    it('keeps every setting with the value it had, but the three meant to change', function()
        if #old == 0 then error('no history to compare with', 0) end
        local was = run(old, 'Config', 'config.lua@' .. BEFORE:sub(1, 7))
        local now = run(file('crimson-hitman/config/config.lua'), 'Config', 'config.lua')
        local seen = {}
        for path, pair in pairs(differences(was, now)) do
            if ADDED[path] then
                eq(pair[1], nil, 'Config.' .. path .. ' is new since the rewrite')
                local off = {}
                for key in pairs(differences(ADDED[path], pair[2])) do off[#off + 1] = key end
                table.sort(off)
                eq(#off, 0, 'Config.' .. path .. ' ships as meant: ' .. table.concat(off, ', '))
                seen[path] = true
                goto continue
            end
            local meant = CHANGED[path]
            truthy(meant, ('Config.%s was %s and is %s'):format(path, tostring(pair[1]),
                tostring(pair[2])))
            eq(pair[1], meant[1], 'Config.' .. path .. ' before')
            if type(meant[2]) == 'table' then
                -- A section or a record added whole: every field of it.
                local off = {}
                for field in pairs(differences(pair[2], meant[2])) do off[#off + 1] = field end
                table.sort(off)
                eq(#off, 0, 'Config.' .. path .. ' now differs in ' .. table.concat(off, ', '))
            else
                eq(pair[2], meant[2], 'Config.' .. path .. ' now')
            end
            seen[path] = true
            ::continue::
        end
        for path in pairs(CHANGED) do truthy(seen[path], 'Config.' .. path .. ' changed') end
        for path in pairs(ADDED) do truthy(seen[path], 'Config.' .. path .. ' added') end
    end)

    it('is what config/defaults.lua ships, key for key and value for value', function()
        local now = run(file('crimson-hitman/config/config.lua'), 'Config', 'config.lua')
        local shipped = run(file('crimson-hitman/config/defaults.lua'), 'ConfigDefaults', 'defaults.lua')
        local off = {}
        for path in pairs(differences(now, shipped)) do off[#off + 1] = path end
        table.sort(off)
        eq(#off, 0, 'config.lua and defaults.lua differ: ' .. table.concat(off, ', '))
    end)

    it('is a short file in the sections an owner reads in order, with no secret in it', function()
        local text = file('crimson-hitman/config/config.lua')
        local lines = select(2, text:gsub('\n', '')) + 1
        truthy(lines < 500, 'config.lua is ' .. lines .. ' lines')
        local at = 0
        for _, title in ipairs({ 'DEBUG AND STORAGE', 'ACCESS', 'COMPLETION AND HANDOVERS', 'REWARDS AND LIMITS',
            'BUYOUTS', 'TARGETING', 'NOTIFICATIONS', 'ADMIN PANEL', 'ADVANCED' }) do
            local found = text:find('\n%-%-%s+' .. title:gsub(' ', '%%s') .. '%s*\n', at + 1)
            truthy(found, title .. ' after the section before it')
            at = found
        end
        truthy(text:find('README', 1, true), 'the header points to the README')
        falsy(text:find('discord%.com/api/webhooks'), 'no webhook')
        falsy(text:find('https?://'), 'no address at all')
        truthy(text:find('\n    MaxPayoutSlots%s*=%s*1,%s*%-%- each contract pays out once\n'),
            'one plain line saying each contract pays out once')
    end)

    it('gives every setting one short note, on its own line', function()
        local text = file('crimson-hitman/config/config.lua')
        local bare = {}
        for line in text:gmatch('[^\n]+') do
            local key = line:match('^%s*([%a_][%w_]*)%s*=') or line:match('^Config%.([%w_.]+)%s*=')
            local inList = line:match('^%s+[%a_][%w_]*%s*=%s*true,%s*[%a_]')
            -- A section's or a record's opening brace is not a setting.
            local opens = line:match('=%s*{%s*$')
            if key and key ~= 'Config' and not inList and not opens and not line:find('%-%-') then
                bare[#bare + 1] = line
            end
            local note = line:match('%-%-%s(.*)$')
            if note and key then
                truthy(#note <= 72, 'a note this long belongs in the README: ' .. line)
            end
        end
        eq(#bare, 0, 'settings with no note: ' .. table.concat(bare, ' | '))
    end)

    it('has a README reference row for every setting', function()
        local readme = file('crimson-hitman/README.md')
        local from = readme:find('\n## Configuration reference\n', 1, true)
        truthy(from, 'the README has the reference the header points to')
        local reference = readme:sub(from, (readme:find('\n## ', from + 10, true) or #readme))
        local now = run(file('crimson-hitman/config/config.lua'), 'Config', 'config.lua')
        local missing = {}
        local function covered(section, key)
            -- Named in full, or after a slash on a row that names its section.
            local full = '`Config.' .. section .. (key and ('.' .. key) or '') .. '`'
            if reference:find(full, 1, true) then return true end
            if not key then return false end
            for row in reference:gmatch('\n| `Config%.' .. section .. '%.[^\n]*') do
                if row:find('/ `' .. key .. '`', 1, true) then return true end
            end
            return false
        end
        local SETS = { BlockedJobTypes = true, BlockedJobNames = true, Sources = true,
            EscrowBlacklist = true, Cooldowns = true }
        for section, value in pairs(now) do
            if type(value) ~= 'table' or SETS[section] then
                if not covered(section) then missing[#missing + 1] = section end
            else
                for key, inner in pairs(value) do
                    -- A record inside a section (Database.Json, Kidnap.Coercion)
                    -- is covered field by field.
                    local fields = type(inner) == 'table' and #inner == 0
                        and key ~= 'Commands' and key ~= 'JailZone'
                        and key ~= 'ParanoidAlertJitter' and key ~= 'AllowedMime'
                        and key ~= 'MedicJobs' and not key:find('Job')
                    if fields then
                        for field in pairs(inner) do
                            if not covered(section, key .. '.' .. field) then
                                missing[#missing + 1] = section .. '.' .. key .. '.' .. field
                            end
                        end
                    elseif not covered(section, key) then
                        missing[#missing + 1] = section .. '.' .. key
                    end
                end
            end
        end
        truthy(covered('Kidnap', 'Coercion.handcuffed') and covered('Kidnap', 'Coercion.passengerOfHitman'),
            'the two restraint detectors')
        for _, key in ipairs({ 'PhotoStorage', 'Fulfilment' }) do
            truthy(covered('Completion', key))
        end
        table.sort(missing)
        eq(#missing, 0, 'settings the README reference does not explain: ' .. table.concat(missing, ', '))
    end)
end)
