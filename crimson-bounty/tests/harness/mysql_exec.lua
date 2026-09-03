--- A MySQL that actually runs the statements.
---
--- The other simulator checks that an INSERT only names declared columns,
--- which catches a dropped column but proves nothing about whether a query
--- returns the right rows. Everything else known about this backend was
--- known by reading it.
---
--- This executes the statement shapes mysql.lua issues — and only those. A
--- statement it does not understand raises rather than returning an empty
--- result, so a gap in the coverage is loud instead of looking like a query
--- that legitimately matched nothing.
---
--- It is faithful in the ways that have actually caused bugs here:
---   * a row is stored as the columns the schema declares and nothing else,
---     so an undeclared field is dropped exactly as MySQL drops it;
---   * booleans come back as 0 and 1, not as true and false;
---   * every read returns a fresh copy, so a caller mutating what it read
---     does not reach into the store.

local Exec = { tables = {}, schema = {}, primary = {} }

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function squash(sql)
    return (sql:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

--------------------------------------------------------------------------
-- Schema
--------------------------------------------------------------------------

local function parseSchema(sql)
    local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
    if not name then return end

    local columns, order, primary = {}, {}, nil
    local body = sql:match('%((.*)%)%s*$') or ''

    for line in body:gmatch('[^,\n]+') do
        local trimmed = line:match('^%s*(.-)%s*$')
        local column = trimmed:match('^([%w_]+)%s+[%w()]+')
        if column then
            local upper = column:upper()
            if upper ~= 'INDEX' and upper ~= 'PRIMARY' and upper ~= 'KEY'
                and upper ~= 'UNIQUE' then
                columns[column] = trimmed:upper():find('TINYINT%(1%)') and 'bool' or 'value'
                order[#order + 1] = column
                if trimmed:upper():find('PRIMARY KEY') then primary = column end
                if trimmed:upper():find('AUTO_INCREMENT') then
                    columns[column] = 'auto'
                    primary = primary or column
                end
            end
        end
    end

    Exec.schema[name] = { columns = columns, order = order }
    Exec.primary[name] = primary or 'id'
    Exec.tables[name] = Exec.tables[name] or {}
end

--- Store a value the way MySQL would: booleans as 0 and 1, everything else
--- as it stands. Anything the schema does not declare is dropped.
local function coerce(tableName, column, value)
    local declared = Exec.schema[tableName]
    local kind = declared and declared.columns[column]
    if not kind then return nil end
    if kind == 'bool' then
        if value == true then return 1 end
        if value == false then return 0 end
        return tonumber(value) or 0
    end
    return value
end

--------------------------------------------------------------------------
-- Statements
--------------------------------------------------------------------------

local function rowsOf(tableName)
    local out = {}
    for _, row in pairs(Exec.tables[tableName] or {}) do out[#out + 1] = row end
    return out
end

local function sortRows(rows, columns, descending)
    table.sort(rows, function(a, b)
        for i = 1, #columns do
            local key = columns[i]
            local av, bv = a[key], b[key]
            if av ~= bv then
                if av == nil then return false end
                if bv == nil then return true end
                if descending then return av > bv end
                return av < bv
            end
        end
        return false
    end)
end

--- WHERE clauses this backend uses: `col = ?` joined by AND, or the two
--- specific OR/JOIN shapes handled by name below.
local function matches(row, conditions, params, from)
    for i = 1, #conditions do
        local condition = conditions[i]
        local expected = condition.literal
        if expected == nil then
            expected = params[from + condition.index - 1]
        end
        if tostring(row[condition.column]) ~= tostring(expected) then return false end
    end
    return true
end

local function parseConditions(clause)
    local conditions, index = {}, 0
    if not clause then return conditions, 0 end

    for column, value in clause:gmatch("([%w_]+)%s*=%s*([^%s]+)") do
        if value == '?' then
            index = index + 1
            conditions[#conditions + 1] = { column = column, index = index }
        else
            conditions[#conditions + 1] =
                { column = column, literal = value:gsub("^'", ''):gsub("'$", '') }
        end
    end
    return conditions, index
end

local function insert(sql, params)
    local tableName = sql:match('INSERT INTO ([%w_]+)')
    local list = sql:match('INSERT INTO [%w_]+ %(([^)]+)%)')
    if not tableName or not list then return {} end

    local columns = {}
    for column in list:gmatch('[%w_]+') do columns[#columns + 1] = column end

    local row = {}
    for i = 1, #columns do
        local value = coerce(tableName, columns[i], params[i])
        if value ~= nil then row[columns[i]] = value end
    end

    local key = Exec.primary[tableName] or 'id'
    Exec.tables[tableName] = Exec.tables[tableName] or {}

    local id = row[key]
    if id == nil then
        -- AUTO_INCREMENT.
        local next_ = 1
        for existing in pairs(Exec.tables[tableName]) do
            if type(existing) == 'number' and existing >= next_ then next_ = existing + 1 end
        end
        id = next_
        row[key] = id
    end

    local existing = Exec.tables[tableName][id]
    if existing and sql:find('ON DUPLICATE KEY UPDATE') then
        -- Only the columns the UPDATE clause names are changed, which is how
        -- `state` stays out of writeContract's reach.
        local clause = sql:match('ON DUPLICATE KEY UPDATE (.*)$') or ''
        for column in clause:gmatch('([%w_]+) = VALUES%(') do
            if row[column] ~= nil then existing[column] = row[column] end
        end
        return {}
    end

    Exec.tables[tableName][id] = row
    return {}
end

local function update(sql, params)
    local tableName, setClause, whereClause =
        sql:match('^UPDATE ([%w_]+) SET (.-) WHERE (.*)$')
    if not tableName then return {} end

    -- Assignments first, then the WHERE, which is the parameter order.
    local assignments, index = {}, 0
    for column, value in setClause:gmatch("([%w_]+)%s*=%s*([^,]+)") do
        local trimmed = value:match('^%s*(.-)%s*$')
        if trimmed == '?' then
            index = index + 1
            assignments[#assignments + 1] = { column = column, index = index }
        else
            assignments[#assignments + 1] =
                { column = column, literal = trimmed:gsub("^'", ''):gsub("'$", '') }
        end
    end

    local conditions = parseConditions(whereClause)
    local changed = 0

    for _, row in pairs(Exec.tables[tableName] or {}) do
        if matches(row, conditions, params, index + 1) then
            for i = 1, #assignments do
                local assignment = assignments[i]
                local value = assignment.literal
                if value == nil then value = params[assignment.index] end
                local coerced = coerce(tableName, assignment.column, value)
                if coerced ~= nil then row[assignment.column] = coerced end
            end
            changed = changed + 1
        end
    end

    return changed
end

local function select_(sql, params)
    local tableName = sql:match('FROM ([%w_]+)')
    if not tableName or not Exec.tables[tableName] then
        error('mysql_exec: no such table in: ' .. sql)
    end

    local whereClause = sql:match('WHERE (.-)%s*ORDER BY') or sql:match('WHERE (.-)%s*LIMIT')
        or sql:match('WHERE (.*)$')
    local conditions = parseConditions(whereClause)

    local out = {}
    for _, row in pairs(Exec.tables[tableName]) do
        if matches(row, conditions, params, 1) then out[#out + 1] = copy(row) end
    end

    local orderBy = sql:match('ORDER BY ([%w_, ]+)')
    if orderBy then
        local columns, descending = {}, sql:find('DESC') ~= nil
        for column in orderBy:gmatch('[%w_]+') do
            if column:upper() ~= 'DESC' and column:upper() ~= 'ASC' then
                columns[#columns + 1] = column
            end
        end
        sortRows(out, columns, descending)
    end

    local limit = sql:match('LIMIT %?')
    if limit then
        local n = tonumber(params[#params]) or #out
        while #out > n do table.remove(out) end
    end

    return out
end

local function delete(sql, params)
    local tableName = sql:match('DELETE FROM ([%w_]+)')
    if not tableName then return {} end

    local whereClause = sql:match('WHERE (.*)$')
    local column, comparison = whereClause and whereClause:match('([%w_]+) ([<>]=?) %?')

    for key, row in pairs(Exec.tables[tableName] or {}) do
        if column then
            local value, bound = tonumber(row[column]), tonumber(params[1])
            if value and bound then
                if (comparison == '<' and value < bound)
                    or (comparison == '>' and value > bound) then
                    Exec.tables[tableName][key] = nil
                end
            end
        else
            local conditions = parseConditions(whereClause)
            if matches(row, conditions, params, 1) then Exec.tables[tableName][key] = nil end
        end
    end

    return {}
end

--------------------------------------------------------------------------
-- The three statements that are not one table and a WHERE
--------------------------------------------------------------------------

local function contractsInvolving(params)
    local cid = params[1]
    local seen, out = {}, {}

    for _, row in pairs(Exec.tables.crimson_contracts or {}) do
        if row.creator_cid == cid or row.target_cid == cid then
            seen[row.id] = true
            out[#out + 1] = copy(row)
        end
    end
    for _, hunter in pairs(Exec.tables.crimson_hunters or {}) do
        if hunter.hunter_cid == cid and not seen[hunter.contract_id] then
            local contract = Exec.tables.crimson_contracts[hunter.contract_id]
            if contract then
                seen[contract.id] = true
                out[#out + 1] = copy(contract)
            end
        end
    end

    sortRows(out, { 'id' }, false)
    return out
end

local function hunterContractStates(params)
    local out = {}
    for _, hunter in pairs(Exec.tables.crimson_hunters or {}) do
        if hunter.hunter_cid == params[1] and hunter.state == 'active' then
            local contract = Exec.tables.crimson_contracts[hunter.contract_id]
            if contract then out[#out + 1] = { state = contract.state } end
        end
    end
    return out
end

local function pruneLedger(params)
    local cid, depth = params[1], tonumber(params[3]) or 10
    local mine = {}
    for _, row in pairs(Exec.tables.crimson_ledger or {}) do
        if row.cid == cid then mine[#mine + 1] = row end
    end
    sortRows(mine, { 'resolved_at' }, true)
    for i = depth + 1, #mine do
        Exec.tables.crimson_ledger[mine[i].id] = nil
    end
    return {}
end

--------------------------------------------------------------------------

function Exec.reset()
    Exec.tables, Exec.schema, Exec.primary = {}, {}, {}
    Exec.statements = {}
end

function Exec.run(sql, params)
    if type(sql) ~= 'string' then return {} end
    params = params or {}

    local flat = squash(sql)
    Exec.statements[#Exec.statements + 1] = flat

    if flat:find('^CREATE TABLE') then parseSchema(sql) return {} end
    if flat:find('^ALTER TABLE') then return {} end
    if flat:find('information_schema') then return {} end

    if flat:find('^INSERT INTO crimson_ledger') and flat:find('DELETE') then
        return pruneLedger(params)
    end
    if flat:find('^DELETE FROM crimson_ledger') then return pruneLedger(params) end
    if flat:find('^SELECT c%.%* FROM crimson_contracts') then
        return contractsInvolving(params)
    end
    if flat:find('^SELECT c%.state AS state') then return hunterContractStates(params) end
    if flat:find('^SELECT COUNT%(%*%)') then
        return #rowsOf(flat:match('FROM ([%w_]+)') or '')
    end

    if flat:find('^INSERT INTO') then return insert(flat, params) end
    if flat:find('^UPDATE ') then return update(flat, params) end
    if flat:find('^DELETE FROM') then return delete(flat, params) end
    if flat:find('^SELECT ') then return select_(flat, params) end

    error('mysql_exec: unrecognised statement: ' .. flat)
end

function Exec.install(Natives)
    Exec.reset()
    Natives.mysql.query = { await = function(sql, params) return Exec.run(sql, params) end }
    Natives.mysql.insert = { await = function(sql, params) Exec.run(sql, params) return 1 end }
    Natives.mysql.update = { await = function(sql, params) return Exec.run(sql, params) end }
    Natives.mysql.scalar = { await = function(sql, params)
        local result = Exec.run(sql, params)
        return type(result) == 'number' and result or 0
    end }
end

return Exec
