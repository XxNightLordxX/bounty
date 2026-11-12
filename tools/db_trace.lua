--- Every statement the mysql store sends while the server suite runs, as
--- the SQL text oxmysql would send, for tools/db_check.sh to run on a real
--- MariaDB or MySQL.
---
---   lua5.4 tools/db_trace.lua <out.jsonl>        (run from the repository root)
---   CH_SUITES=storage_spec,restart_spec lua5.4 tools/db_trace.lua out.jsonl
---
--- It runs tests/run.lua unchanged, with tests/harness/mysql_exec.lua (the
--- stand-in for oxmysql) watched: each statement is written with its `?`
--- filled in as oxmysql's formatter fills them (docs/developer.md, oxmysql
--- §2: a string quoted and escaped, a boolean `true` / `false`, nil NULL)
--- and with what the stand-in answered (its rows, the rows an UPDATE or
--- DELETE matched, or the refusal), so the real server's answer can be put
--- beside it. A new stack (Exec.reset) is a line of its own: the check
--- starts again from no tables there. A transaction is bracketed by
--- begin / commit or rollback, as the stand-in settled it.
---
--- One JSON object per line:
---   {"k":"reset","test":"..."}  {"k":"begin"}  {"k":"commit"}  {"k":"rollback"}
---   {"k":"q","sql":"...","shape":"...","ok":true,"rows":[...]|"n":N,"test":"..."}
---   {"k":"q",...,"ok":false,"err":"..."}
---   {"k":"warn","what":"...","shape":"..."}   a `?` inside a comment or a quoted string,
---                                             or more values than `?`

package.path = './?.lua;./?/init.lua;' .. package.path

local out = assert(arg[1], 'usage: lua5.4 tools/db_trace.lua <out.jsonl>')
local file = assert(io.open(out, 'w'))

--------------------------------------------------------------------------
-- JSON, enough for this
--------------------------------------------------------------------------

local function jstr(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\'
        elseif c == '\n' then return '\\n' elseif c == '\r' then return '\\r'
        elseif c == '\t' then return '\\t' end
        return ('\\u%04x'):format(c:byte())
    end) .. '"'
end

local function isSequence(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return false, n end end
    return true, n
end

local function jval(v)
    local t = type(v)
    if v == nil then return 'null'
    elseif t == 'boolean' then return v and 'true' or 'false'
    elseif t == 'number' then
        if math.type(v) == 'integer' then return tostring(v) end
        if v ~= v or v == math.huge or v == -math.huge then return jstr(tostring(v)) end
        return ('%.17g'):format(v)
    elseif t == 'string' then return jstr(v)
    elseif t == 'table' then
        local seq, n = isSequence(v)
        local parts = {}
        if seq and n > 0 then
            for i = 1, n do parts[i] = jval(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local value = v[k]
            if value == nil then value = v[tonumber(k)] end
            parts[#parts + 1] = jstr(k) .. ':' .. jval(value)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return jstr(tostring(v))
end

local function emit(record)
    file:write(jval(record), '\n')
end

--------------------------------------------------------------------------
-- oxmysql's placeholders, as its formatter fills them
--------------------------------------------------------------------------

local function literal(v)
    local t = type(v)
    if v == nil then return 'NULL'
    elseif t == 'boolean' then return v and 'true' or 'false'
    elseif t == 'number' then
        if math.type(v) == 'integer' then return tostring(v) end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    elseif t == 'string' then
        return "'" .. v:gsub("[%z\b\t\n\r\26'\"\\]", {
            ['\0'] = '\\0', ['\b'] = '\\b', ['\t'] = '\\t', ['\n'] = '\\n', ['\r'] = '\\r',
            ['\26'] = '\\Z', ["'"] = "\\'", ['"'] = '\\"', ['\\'] = '\\\\',
        }) .. "'"
    elseif t == 'table' then
        local seq, n = isSequence(v)
        if seq then
            local parts = {}
            for i = 1, n do parts[i] = literal(v[i]) end
            return table.concat(parts, ', ')
        end
    end
    error('db_trace: a value oxmysql would not send as one: ' .. tostring(v))
end

--- The SQL with every `?` outside a quoted string or a comment filled in;
--- and what looked wrong about it.
local function format(sql, params)
    params = params or {}
    local outText, i, n, holes, warn = {}, 1, #sql, 0, nil
    local function noteQuestion(where)
        warn = warn or ('a ? inside ' .. where)
    end
    while i <= n do
        local c = sql:sub(i, i)
        if c == "'" or c == '"' or c == '`' then
            local j = i + 1
            while j <= n do
                local d = sql:sub(j, j)
                if d == '\\' then j = j + 1
                elseif d == c then
                    if sql:sub(j + 1, j + 1) == c then j = j + 1 else break end
                end
                j = j + 1
            end
            local quoted = sql:sub(i, j)
            if quoted:find('?', 1, true) then noteQuestion('a quoted string') end
            outText[#outText + 1] = quoted
            i = j + 1
        elseif c == '-' and sql:sub(i + 1, i + 1) == '-' then
            local j = sql:find('\n', i, true) or n
            if sql:sub(i, j):find('?', 1, true) then noteQuestion('a comment') end
            outText[#outText + 1] = sql:sub(i, j)
            i = j + 1
        elseif c == '/' and sql:sub(i + 1, i + 1) == '*' then
            local j = select(2, sql:find('*/', i + 2, true)) or n
            if sql:sub(i, j):find('?', 1, true) then noteQuestion('a comment') end
            outText[#outText + 1] = sql:sub(i, j)
            i = j + 1
        elseif c == '?' then
            holes = holes + 1
            outText[#outText + 1] = literal(params[holes])
            i = i + 1
        else
            outText[#outText + 1] = c
            i = i + 1
        end
    end
    local seq, count = isSequence(params)
    if seq and count > holes then
        warn = warn or ('more values (' .. count .. ') than ? (' .. holes .. ')')
    end
    return table.concat(outText), warn
end

local function squash(sql)
    return (sql:gsub('%-%-[^\n]*', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

--------------------------------------------------------------------------
-- The watch
--------------------------------------------------------------------------

local Exec = require('tests.harness.mysql_exec')
local currentTest = '?'

local realRun, realReset, realInstall = Exec.run, Exec.reset, Exec.install
local depth = 0

function Exec.run(sql, params)
    if type(sql) ~= 'string' then return realRun(sql, params) end
    local okFormat, formatted, warn = pcall(format, sql, params)
    local shape = squash(sql)
    if not okFormat then
        emit({ k = 'warn', what = tostring(formatted), shape = shape, test = currentTest })
        return realRun(sql, params)
    end
    if warn then emit({ k = 'warn', what = warn, shape = shape, test = currentTest }) end
    local ok, result = pcall(realRun, sql, params)
    local record = { k = 'q', sql = formatted, shape = shape, ok = ok, test = currentTest }
    if ok then
        if type(result) == 'number' then record.n = result
        elseif type(result) == 'table' then
            local rows = {}
            for i, row in ipairs(result) do rows[i] = row end
            record.rows = rows
            record.empty = #rows == 0
        end
    else
        record.err = tostring(result)
        -- One the stand-in could not read raises its own words, not a
        -- refusal: the real server is asked anyway.
        record.refused = record.err:find('was unable to execute a query!', 1, true) ~= nil
    end
    emit(record)
    if not ok then error(result, 0) end
    return result
end

function Exec.reset()
    emit({ k = 'reset', test = currentTest })
    return realReset()
end

function Exec.install(Natives)
    realInstall(Natives)
    local tx = Natives.mysql.transaction
    local call = getmetatable(tx).__call
    -- Bracketed only when it runs at once: one the stand-in parks (the
    -- database down, or held to answer late) runs its statements, if ever,
    -- in between other statements, and is replayed as they come.
    local function bracketed(run)
        if Exec.down or (Exec.lateNext or 0) > 0 then return run() end
        emit({ k = 'begin' })
        local ok, result = pcall(run)
        emit({ k = (ok and result) and 'commit' or 'rollback' })
        if not ok then error(result, 0) end
        return result
    end
    Natives.mysql.transaction = setmetatable({
        await = function(queries, params)
            return bracketed(function() return tx.await(queries, params) end)
        end,
    }, { __call = function(_, queries, params, cb)
        if type(params) == 'function' then params, cb = nil, params end
        local answered, answer = false, nil
        bracketed(function()
            call(tx, queries, params, function(r) answered, answer = true, r end)
            return answer
        end)
        if answered and type(cb) == 'function' then cb(answer) end
    end })
end

--------------------------------------------------------------------------
-- The suite, with each test's name kept for the report
--------------------------------------------------------------------------

_G.__DB_TRACE_HOOK = function()
    local it = _G.it
    _G.it = function(name, fn)
        return it(name, function(...)
            currentTest = tostring(Suite.current) .. ' > ' .. tostring(name)
            return fn(...)
        end)
    end
    _G.Suite.it = _G.it
    if os.getenv('DB_TRACE_MIGRATE') then
        _G.__DB_TRACE_MIGRATE()
    end
end

--- DB_TRACE_MIGRATE=1 (with CH_SUITES=none): instead of the suite, what
--- MySQLStore.migrate sends to a database an old version left at its
--- oldest: every table holding only its primary key, on MyISAM in latin1,
--- and crimson_escrow with the column under its old name (`portion`).
--- Written as {"k":"old",...} with the tables and keys, then each ALTER in
--- order; db_replay.py --migrate builds that database for real, runs them,
--- and compares what it ends with to a fresh install.
_G.__DB_TRACE_MIGRATE = function()
    local Sim = require('tests.harness.mysql_sim')
    Sim.install(Natives)
    package.loaded['crimson-hitman.server.storage.mysql'] = nil
    require('crimson-hitman.server.storage.mysql').open()
    local existing, indexes, collations, engines, keys = {}, {}, {}, {}, {}
    for name in pairs(Sim.schema) do
        local key = Sim.keys[name]
        existing[name], indexes[name] = { [key] = 'latin1' }, { PRIMARY = true }
        collations[name], engines[name], keys[name] = 'latin1_swedish_ci', 'MyISAM', key
    end
    existing.crimson_escrow.portion = 'latin1'
    emit({ k = 'old', keys = keys, renamed = { crimson_escrow = { portion = 'line_portion' } } })
    Sim.install(Natives)
    Sim.databaseCollation = 'latin1_swedish_ci'
    Sim.existingSchema(existing, indexes, collations, engines, keys)
    package.loaded['crimson-hitman.server.storage.mysql'] = nil
    local store = require('crimson-hitman.server.storage.mysql')
    store.open()
    for _, change in ipairs(Sim.altered) do emit({ k = 'alter', sql = change.sql }) end
    local first = #Sim.altered
    Sim.altered = {}
    store.migrate()
    emit({ k = 'again', n = #Sim.altered })
    io.stderr:write(('db_trace: migrate sent %d changes, and %d on a second run\n'):format(first, #Sim.altered))
end

local source = assert(io.open('tests/run.lua')):read('a')
local hooked, count = source:gsub('\nfor _, name in ipairs%(suites%) do', '\n_G.__DB_TRACE_HOOK()%0', 1)
assert(count == 1, 'db_trace: tests/run.lua no longer has the loop this hooks into')

local realExit = os.exit
os.exit = function(code)
    file:close()
    io.stderr:write('db_trace: wrote ', out, '\n')
    realExit(code)
end
assert(load(hooked, '@tests/run.lua'))()
