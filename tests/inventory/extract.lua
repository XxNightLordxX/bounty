--- The capability inventory: every name the resource answers to, read from
--- its source. tests/capability_inventory_spec.lua compares a fresh
--- extraction against tests/inventory/baseline.lua, so nothing the resource
--- can do disappears without a line in tests/inventory/moved.lua saying where
--- it went (docs/dev/map.md, "Capability inventory").
---
--- Static: every category is read from the files as text, except two that
--- the source builds rather than writes out:
---   * config keys: config/config.lua and config/defaults.lua are run in an
---     empty sandbox (they are plain assignments) and every key path walked;
---   * settings catalogue keys: server/settings.lua builds part of its
---     catalogue in loops (commands, rate-limit buckets, the organisation's
---     entries), so its CATALOGUE is loaded and read.
---
--- Regenerate the baseline (only when a capability was added on purpose,
--- or after a move recorded in moved.lua has been folded in):
---
---     lua5.4 tests/inventory/extract.lua            -- writes baseline.lua
---     lua5.4 tests/inventory/extract.lua --print    -- counts only
---
--- Run from the repository root.

local Extract = {}

local ROOT = 'crimson-hitman/'

local function read(path)
    local fh = io.open(path, 'r')
    if not fh then return nil end
    local text = fh:read('a')
    fh:close()
    return text
end

local function listFiles(dir, ext)
    local out = {}
    local pipe = io.popen('find ' .. dir .. " -name '*." .. ext .. "' -type f 2>/dev/null | sort")
    if pipe then
        for line in pipe:lines() do out[#out + 1] = line end
        pipe:close()
    end
    return out
end

--- Lua source with its comments blanked (line count kept), so a name in a
--- comment is not taken for a capability.
local function stripLua(src)
    src = src:gsub('%-%-%[(=*)%[.-%]%1%]', function(block)
        return (block:gsub('[^\n]', ''))
    end)
    local out = {}
    for line in (src .. '\n'):gmatch('(.-)\n') do
        -- A `--` outside a string ends the line's code.
        local i, quote, cut = 1, nil, nil
        while i <= #line do
            local c = line:sub(i, i)
            if quote then
                if c == '\\' then i = i + 1 elseif c == quote then quote = nil end
            elseif c == "'" or c == '"' then
                quote = c
            elseif c == '-' and line:sub(i + 1, i + 1) == '-' then
                cut = i
                break
            end
            i = i + 1
        end
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, '\n')
end

--- JavaScript with block comments and whole-line `//` comments blanked.
local function stripJs(src)
    src = src:gsub('/%*.-%*/', function(block) return (block:gsub('[^\n]', '')) end)
    local out = {}
    for line in (src .. '\n'):gmatch('(.-)\n') do
        out[#out + 1] = line:match('^%s*//') and '' or line
    end
    return table.concat(out, '\n')
end

local cache = {}
local function luaSrc(path)
    if cache[path] == nil then cache[path] = stripLua(read(path) or '') end
    return cache[path]
end

local function luaFiles(...)
    local out = {}
    for _, dir in ipairs({ ... }) do
        for _, f in ipairs(listFiles(ROOT .. dir, 'lua')) do out[#out + 1] = f end
    end
    return out
end

--- The text from `open` (a plain string) to the first line that is exactly
--- `close`, after it.
local function block(src, open, close)
    local s = src:find(open, 1, true)
    if not s then return '' end
    local e = src:find('\n' .. close, s, true)
    return src:sub(s, e or #src)
end

--------------------------------------------------------------------------
-- Categories
--------------------------------------------------------------------------

--- Config key paths: leaves, and lists or empty tables as one item each.
local function configKeys(add)
    local function walk(prefix, value)
        if type(value) ~= 'table' then return add(prefix) end
        local named = false
        for k in pairs(value) do
            if type(k) ~= 'number' then named = true break end
        end
        if not named then return add(prefix) end
        for k, v in pairs(value) do
            if type(k) ~= 'number' then
                local key = tostring(k)
                if not key:match('^[%a_][%w_]*$') then key = '[' .. key .. ']' end
                walk(prefix == '' and key or (prefix .. '.' .. key), v)
            end
        end
    end
    for _, spec in ipairs({ { 'config/config.lua', 'Config' }, { 'config/defaults.lua', 'ConfigDefaults' } }) do
        local env = setmetatable({}, { __index = { pairs = pairs, ipairs = ipairs, type = type,
            tostring = tostring, tonumber = tonumber, math = math, string = string, table = table } })
        local chunk = assert(loadfile(ROOT .. spec[1], 't', env))
        local ok, result = pcall(chunk)
        assert(ok, spec[1] .. ': ' .. tostring(result))
        walk('', env[spec[2]] or result)
    end
end

--- The settings catalogue, as server/settings.lua builds it.
local function settingKeys(add)
    if not _G.CrimsonBoot then
        package.path = './?.lua;./?/init.lua;./crimson-hitman/?.lua;' .. package.path
        require('tests.harness.natives').install()
        _G.CrimsonBoot = {
            require = function(path) return require(path) end,
            requireShared = function(name) return require('crimson-hitman.shared.' .. name) end,
        }
        _G.CH = _G.CH or require('crimson-hitman.shared.constants')
        _G.ConfigDefaults = _G.ConfigDefaults or require('crimson-hitman.config.defaults')
        _G.Config = _G.Config or require('crimson-hitman.config.config')
    end
    local Settings = package.loaded['crimson-hitman.server.settings'] or package.loaded['server.settings']
        or require('server.settings')
    for _, entry in ipairs(Settings.CATALOGUE) do add(entry.key) end
end

--- Admin panel ops: server/panel.lua's OPS, every Panel.extend with a
--- literal name, and the organisation's OPS.name table.
local function panelOps(add)
    local ops = block(luaSrc(ROOT .. 'server/panel.lua'), 'local OPS = {', '}')
    for name in ops:gmatch('([%a_][%w_]*)%s*=%s*[%u]') do add(name) end
    for _, f in ipairs(luaFiles('server')) do
        for name in luaSrc(f):gmatch('[%.:]extend%(%s*\'([%w_]+)\'') do add(name) end
    end
    for name in luaSrc(ROOT .. 'server/org/staff_ops.lua'):gmatch('\nOPS%.([%w_]+)%s*=') do add(name) end
end

--- Phone app requests: handler('name' in server/app.lua, addHandler('name'
--- anywhere, and the organisation's REQUESTS list.
local function appHandlers(add)
    for name in luaSrc(ROOT .. 'server/app.lua'):gmatch('%f[%w_]handler%(%s*\'([%w_]+)\'') do add(name) end
    for _, f in ipairs(luaFiles('server')) do
        for name in luaSrc(f):gmatch('addHandler%(%s*\'([%w_]+)\'') do add(name) end
    end
    local requests = block(luaSrc(ROOT .. 'server/org/boss_ops.lua'), 'local REQUESTS = {', '}')
    for name in requests:gmatch('\n%s*{%s*\'([%w_]+)\'%s*,') do add(name) end
end

local function netEvents(side)
    return function(add)
        for _, f in ipairs(luaFiles(side)) do
            for name in luaSrc(f):gmatch('RegisterNetEvent%(%s*\'([^\']+)\'%s*[,)]') do add(name) end
        end
    end
end

local function localEvents(add)
    for _, side in ipairs({ 'server', 'client' }) do
        for _, f in ipairs(luaFiles(side)) do
            for name in luaSrc(f):gmatch('AddEventHandler%(%s*\'([^\']+)\'%s*[,)]') do add(side .. ':' .. name) end
        end
    end
end

--- NUI callbacks the phone page and the admin page call: literal ones, and
--- client/main.lua's UI_EVENTS list (each registered as 'crimson:' .. name).
local function nuiCallbacks(add)
    for _, f in ipairs(luaFiles('client')) do
        for name in luaSrc(f):gmatch('RegisterNUICallback%(%s*\'([^\']+)\'%s*,') do add(name) end
    end
    local list = block(luaSrc(ROOT .. 'client/main.lua'), 'local UI_EVENTS = {', '}')
    for name in list:gmatch('\'([%w_]+)\'') do add('crimson:' .. name) end
end

--- Commands: the staff commands and the buyout command (config), and any
--- literal RegisterCommand / lib.addCommand.
local function commands(add)
    local env = setmetatable({}, { __index = _G })
    local cfg = assert(loadfile(ROOT .. 'config/config.lua', 't', env))()
    cfg = env.Config or cfg
    for _, name in pairs(cfg.Admin.Commands) do add(name) end
    if cfg.Admin.Commands.panel then add(cfg.Admin.Commands.panel .. '-close') end
    if cfg.Bailout and cfg.Bailout.Command then add(cfg.Bailout.Command) end
    for _, f in ipairs(luaFiles('server', 'client')) do
        local src = luaSrc(f)
        for name in src:gmatch('RegisterCommand%(%s*\'([^\']+)\'') do add(name) end
        for name in src:gmatch('lib%.addCommand%(%s*\'([^\']+)\'') do add(name) end
    end
end

local function exportsOf(add)
    for _, f in ipairs(luaFiles('server', 'client', 'shared')) do
        for name in luaSrc(f):gmatch('%f[%w_]exports%(%s*\'([^\']+)\'') do add(name) end
    end
end

--- ACE names: every config value under a key ending Ace or Aces, and any
--- literal IsPlayerAceAllowed(src, '...').
local function aceNames(add)
    local env = setmetatable({}, { __index = _G })
    local cfg = assert(loadfile(ROOT .. 'config/config.lua', 't', env))()
    cfg = env.Config or cfg
    local function walk(t, depth)
        if depth > 6 then return end
        for k, v in pairs(t) do
            if type(k) == 'string' and k:match('Aces?$') then
                if type(v) == 'string' and v ~= '' then add(v) end
                if type(v) == 'table' then
                    for _, ace in pairs(v) do if type(ace) == 'string' then add(ace) end end
                end
            elseif type(v) == 'table' then
                walk(v, depth + 1)
            end
        end
    end
    walk(cfg, 0)
    for _, f in ipairs(luaFiles('server', 'client')) do
        for name in luaSrc(f):gmatch('IsPlayerAceAllowed%([^,]+,%s*\'([^\']+)\'') do add(name) end
    end
end

--- Audit actions: every snake_case string literal in the first argument of
--- an audit call (Audit.financial/staff/action/rejected, through any
--- deps table, and the organisation's record()).
local function auditActions(add)
    local function firstArg(src, from)
        local depth, i, out = 0, from, {}
        while i <= #src do
            local c = src:sub(i, i)
            if c == "'" or c == '"' then
                local j = i + 1
                while j <= #src and src:sub(j, j) ~= c do
                    if src:sub(j, j) == '\\' then j = j + 1 end
                    j = j + 1
                end
                out[#out + 1] = src:sub(i + 1, j - 1)
                i = j
            elseif c == '(' or c == '{' then depth = depth + 1
            elseif c == ')' or c == '}' then
                if depth == 0 then break end
                depth = depth - 1
            elseif c == ',' and depth == 0 then break
            end
            i = i + 1
        end
        return out
    end
    for _, f in ipairs(luaFiles('server')) do
        local src = luaSrc(f)
        for _, pat in ipairs({ '[Aa]udit[%w_]*[%.:]financial%(()', '[Aa]udit[%w_]*[%.:]staff%(()',
                               '[Aa]udit[%w_]*[%.:]action%(()', '[Aa]udit[%w_]*[%.:]rejected%(()',
                               '%f[%w_]record%(()\'' }) do
            for at in src:gmatch(pat) do
                for _, s in ipairs(firstArg(src, at)) do
                    if s:match('^[a-z][a-z0-9_]*$') and s:find('_') then add(s) end
                end
            end
        end
    end
end

--- Refusal codes: CH.ERR (shared/constants.lua) and Org.ERR, by name.
local function errCodes(add)
    for name in block(luaSrc(ROOT .. 'shared/constants.lua'), 'CH.ERR = {', '}'):gmatch('\n%s*([%u_][%u%d_]*)%s*=') do
        add(name)
    end
    local org = block(luaSrc(ROOT .. 'server/org/init.lua'), 'Org.ERR = {', '}')
    for name in org:gmatch('([%u_][%u%d_]*)%s*=%s*\'') do add('Org.' .. name) end
end

--- Screens: the phone's tabs and dialog kinds (ui/app.js) and the admin
--- panel's groups and views (ui/admin.js).
local function screens(add)
    local app = stripJs(read(ROOT .. 'ui/app.js') or '')
    local tabs = app:match('%(%{%s*(board:.-)%}%)%[state%.tab%]') or ''
    for name in tabs:gmatch('([%w_]+):%s*view') do add('phone.tab:' .. name) end
    for name in app:gmatch('state%.dialog%.kind === \'([%w_]+)\'') do add('phone.dialog:' .. name) end
    for name in app:gmatch('state%.boardTab = \'([%w_]+)\'') do add('phone.boardtab:' .. name) end
    for name in app:gmatch('state%.boardTab === \'([%w_]+)\'') do add('phone.boardtab:' .. name) end
    local admin = stripJs(read(ROOT .. 'ui/admin.js') or '')
    for name in block(admin, 'var GROUPS = [', '  ];'):gmatch('{ id: \'([%w_]+)\'') do add('admin.group:' .. name) end
    for name in block(admin, 'var VIEW_LABEL = {', '  };'):gmatch('([%w_]+):%s*%[') do add('admin.view:' .. name) end
    for name in block(admin, 'var DRAWER_TABS = [', '  ];'):gmatch('{ id: \'([%w_]+)\'') do add('admin.drawer:' .. name) end
    for name in admin:gmatch('S%.inbox === \'([%w_]+)\'') do add('admin.inbox:' .. name) end
end

--- The maintenance tick's jobs (server/main.lua Tick: job / every).
local function tickJobs(add)
    local src = luaSrc(ROOT .. 'server/main.lua')
    for name in src:gmatch('%f[%w_]job%(\'([%w_%.]+)\'') do add(name) end
    for name in src:gmatch('%f[%w_]every%(\'([%w_%.]+)\'') do add(name) end
end

--- Other resources' exports this resource calls, as resource:export.
local function externalCalls(add)
    for _, f in ipairs(luaFiles('server', 'client', 'shared')) do
        local src = luaSrc(f)
        for res, name in src:gmatch('exports%[\'([^\']+)\'%]:([%w_]+)') do add(res .. ':' .. name) end
        for res, name in src:gmatch('exports%[\'([^\']+)\'%]%[\'([%w_]+)\'%]') do add(res .. ':' .. name) end
        for res, name in src:gmatch('exports%.([%w_]+):([%w_]+)') do add(res .. ':' .. name) end
    end
end

Extract.CATEGORIES = {
    { 'config', configKeys, 'config key paths (config/config.lua + defaults.lua)' },
    { 'setting', settingKeys, 'admin panel settings catalogue keys' },
    { 'op', panelOps, 'admin panel ops' },
    { 'handler', appHandlers, 'phone app requests (App handlers)' },
    { 'netevent.server', netEvents('server'), 'net events the server registers' },
    { 'netevent.client', netEvents('client'), 'net events the client registers' },
    { 'event', localEvents, 'local event handlers (side:name)' },
    { 'nui', nuiCallbacks, 'NUI callbacks' },
    { 'command', commands, 'commands' },
    { 'export', exportsOf, 'exports this resource offers' },
    { 'ace', aceNames, 'ACE names' },
    { 'audit', auditActions, 'audit action names' },
    { 'err', errCodes, 'refusal codes (CH.ERR, Org.ERR)' },
    { 'screen', screens, 'phone tabs and dialogs, admin groups and views' },
    { 'tick', tickJobs, 'maintenance tick jobs' },
    { 'ext', externalCalls, 'other resources\' exports called' },
}

--- What a fresh extraction lost against the baseline.
---@param baseline string[] the items as written
---@param current table<string, true> a fresh extraction
---@param moved table<string, string|{to: string, note?: string}> [item] = where it now lives
---@return string[] missing baseline items neither present nor moved
---@return string[] broken moved entries whose target is not a current item
function Extract.compare(baseline, current, moved)
    local missing, broken = {}, {}
    for _, item in ipairs(baseline) do
        if not current[item] and moved[item] == nil then missing[#missing + 1] = item end
    end
    for item, where in pairs(moved) do
        local to = type(where) == 'table' and where.to or where
        if type(to) ~= 'string' or not current[to] then
            broken[#broken + 1] = ('%s -> %s'):format(item, tostring(to))
        end
    end
    table.sort(missing)
    table.sort(broken)
    return missing, broken
end

--- Every item, as a set of 'category:name' strings.
---@return table<string, true> items
---@return table<string, integer> counts per category
function Extract.run()
    local items, counts = {}, {}
    for _, cat in ipairs(Extract.CATEGORIES) do
        local name, fn = cat[1], cat[2]
        counts[name] = 0
        fn(function(item)
            local key = name .. ':' .. item
            if not items[key] then
                items[key] = true
                counts[name] = counts[name] + 1
            end
        end)
    end
    return items, counts
end

--- The items as a sorted list.
function Extract.sorted(items)
    local list = {}
    for k in pairs(items) do list[#list + 1] = k end
    table.sort(list)
    return list
end

local function quote(s) return ("'%s'"):format(s:gsub('\\', '\\\\'):gsub("'", "\\'")) end

function Extract.write(path)
    local items, counts = Extract.run()
    local out = {
        '--- GENERATED by tests/inventory/extract.lua: do not edit by hand.',
        '--- Every capability the resource had when this was written. The',
        '--- capability inventory spec fails when one is missing and not listed',
        '--- in tests/inventory/moved.lua (docs/dev/map.md).',
        '---',
    }
    for _, cat in ipairs(Extract.CATEGORIES) do
        out[#out + 1] = ('--- %-16s %4d  %s'):format(cat[1], counts[cat[1]], cat[3])
    end
    out[#out + 1] = 'return {'
    for _, item in ipairs(Extract.sorted(items)) do out[#out + 1] = '    ' .. quote(item) .. ',' end
    out[#out + 1] = '}'
    local fh = assert(io.open(path, 'w'))
    fh:write(table.concat(out, '\n'), '\n')
    fh:close()
    return counts
end

if arg and arg[0] and arg[0]:find('inventory/extract%.lua$') then
    local counts
    if arg[1] == '--print' then
        local _
        _, counts = Extract.run()
    else
        counts = Extract.write('tests/inventory/baseline.lua')
    end
    local total = 0
    for _, cat in ipairs(Extract.CATEGORIES) do
        io.stderr:write(('%-16s %5d\n'):format(cat[1], counts[cat[1]]))
        total = total + counts[cat[1]]
    end
    io.stderr:write(('%-16s %5d\n'):format('total', total))
end

return Extract
