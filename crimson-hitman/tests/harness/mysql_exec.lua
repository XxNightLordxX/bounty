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
---   * a TINYINT(1) comes back as true and false, as oxmysql's typeCast
---     hands it back (Exec.booleans = false gives the 0 and 1 of a driver
---     without it);
---   * every read returns a fresh copy, so a caller mutating what it read
---     does not reach into the store.

local Exec = { tables = {}, schema = {}, primary = {}, engines = {}, booleans = true }

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
    -- Up to the last bracket: the table options (the character set) follow.
    local body = sql:gsub('%-%-[^\n]*', ''):match('%((.*)%)[^)]*$') or ''

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
    -- The engine it names, or the server's default, which is InnoDB.
    Exec.engines[name] = sql:match('%)[^)]*ENGINE=([%w_]+)[^)]*$') or 'InnoDB'
end

--- Store a value the way it will be read back: a TINYINT(1) in the shape
--- of Exec.booleans, everything else as it stands. Anything the schema does
--- not declare is dropped.
local function coerce(tableName, column, value)
    local declared = Exec.schema[tableName]
    local kind = declared and declared.columns[column]
    if not kind then return nil end
    if kind == 'bool' then
        local on = value == true or (tonumber(value) or 0) ~= 0
        if Exec.booleans then return on end
        return on and 1 or 0
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
--- Compare the way MySQL would: numerically when both sides are numbers,
--- as text otherwise. `resolved_at < ?` against text comparison would order
--- timestamps lexically, which is right until the digit count changes.
local function compare(actual, operator, expected)
    if operator == nil or operator == '=' then
        return tostring(actual) == tostring(expected)
    end
    if operator == '<>' or operator == '!=' then
        return tostring(actual) ~= tostring(expected)
    end

    -- NULL is neither above nor below anything: the comparison is unknown,
    -- and a WHERE keeps only what is true.
    if actual == nil then return false end
    local a, b = tonumber(actual), tonumber(expected)
    if a == nil or b == nil then
        a, b = tostring(actual), tostring(expected)
    end
    if operator == '<' then return a < b end
    if operator == '<=' then return a <= b end
    if operator == '>' then return a > b end
    if operator == '>=' then return a >= b end
    error('mysql_exec: unsupported operator ' .. tostring(operator))
end

local function matches(row, conditions, params, from)
    for i = 1, #conditions do
        local condition = conditions[i]

        if condition.notExists then
            -- The correlated subquery, evaluated by scanning the other
            -- table. Slow and exact, which is what a test executor wants.
            local linked = row[condition.linkedTo]
            for _, other in pairs(Exec.tables[condition.notExists] or {}) do
                if tostring(other[condition.link]) == tostring(linked) then
                    local hit = true
                    for _, extra in ipairs(condition.extra) do
                        if not compare(other[extra.column], extra.operator, extra.literal) then
                            hit = false
                            break
                        end
                    end
                    if hit then return false end
                end
            end

        elseif condition.notNull then
            if row[condition.column] == nil then return false end
        elseif condition.isNull then
            if row[condition.column] ~= nil then return false end
        elseif condition.anyOf then
            if not condition.anyOf[tostring(row[condition.column])] then return false end
        else
            local expected = condition.literal
            if expected == nil then
                expected = params[from + condition.index - 1]
            end
            if not compare(row[condition.column], condition.operator, expected) then
                return false
            end
        end
    end
    return true
end

--- Split a WHERE clause on its top-level ANDs, ignoring ones inside
--- parentheses so a subquery's own conditions stay with it.
local function andTerms(clause)
    local terms, depth, start = {}, 0, 1
    local i = 1
    while i <= #clause do
        local char = clause:sub(i, i)
        if char == '(' then depth = depth + 1
        elseif char == ')' then depth = depth - 1
        elseif depth == 0 and clause:sub(i, i + 4):upper() == ' AND ' then
            terms[#terms + 1] = clause:sub(start, i - 1)
            i = i + 4
            start = i + 1
        end
        i = i + 1
    end
    terms[#terms + 1] = clause:sub(start)

    local out = {}
    for j = 1, #terms do
        local trimmed = terms[j]:match('^%s*(.-)%s*$')
        if trimmed ~= '' then out[#out + 1] = trimmed end
    end
    return out
end

local function unquote(value)
    return (value:gsub("^'", ''):gsub("'$", ''))
end

--- Parse one WHERE clause into conditions this executor can evaluate.
---
--- Anything it cannot account for raises. It used to scan for `col = value`
--- pairs and silently ignore the rest of the clause, so a query whose real
--- filtering lived in an IS NOT NULL, a range, an IN list or a subquery
--- matched every row in the table — and the test reading that result had no
--- way to tell. A statement shape this does not understand has to be loud,
--- which is the whole reason this executor exists.
local function parseConditions(clause, sql)
    local conditions, index = {}, 0
    if not clause then return conditions, 0 end

    for _, term in ipairs(andTerms(clause)) do
        -- The OR in contractsInvolving is routed to its own handler; every
        -- other clause here is a conjunction, and treating an OR as one
        -- would silently narrow the result.
        if term:upper():find(' OR ') then
            error('mysql_exec: OR is not supported by the generic reader: ' .. tostring(sql))
        end

        local negatedExists = term:match('^[Nn][Oo][Tt]%s+EXISTS%s*%((.*)%)$')
        local column, operator, value = term:match('^([%w_.]+)%s*([=<>!]+)%s*(.+)$')
        local isNull = term:match('^([%w_.]+)%s+IS%s+NULL$')
        local notNull = term:match('^([%w_.]+)%s+IS%s+NOT%s+NULL$')
        local inColumn, inList = term:match('^([%w_.]+)%s+IN%s*%((.*)%)$')
        local notInColumn = term:match('^([%w_.]+)%s+NOT%s+IN%s*%(')

        local function bare(name) return name:match('([%w_]+)$') end

        if negatedExists then
            -- NOT EXISTS (SELECT 1 FROM <table> WHERE <table>.<col> = <outer>.<col> [AND ...])
            local subTable = negatedExists:match('FROM%s+([%w_]+)')
            local subWhere = negatedExists:match('WHERE%s+(.*)$')
            if not subTable or not subWhere then
                error('mysql_exec: cannot read the subquery in: ' .. tostring(sql))
            end
            local link, linkedTo, extra = nil, nil, {}
            for _, inner in ipairs(andTerms(subWhere)) do
                local left, op, right = inner:match('^([%w_.]+)%s*([=<>!]+)%s*(.+)$')
                if not left then
                    error('mysql_exec: cannot read `' .. inner .. '` in: ' .. tostring(sql))
                end
                if right:match('^[%w_]+%.[%w_]+$') then
                    link, linkedTo = bare(left), bare(right)
                elseif right == '?' then
                    error('mysql_exec: a bound parameter inside a subquery is '
                        .. 'not supported: ' .. tostring(sql))
                else
                    extra[#extra + 1] = { column = bare(left), operator = op,
                                          literal = unquote(right) }
                end
            end
            if not link then
                error('mysql_exec: the subquery names no join column: ' .. tostring(sql))
            end
            conditions[#conditions + 1] = { notExists = subTable, link = link,
                                            linkedTo = linkedTo, extra = extra }

        elseif notNull then
            conditions[#conditions + 1] = { column = bare(notNull), notNull = true }
        elseif isNull then
            conditions[#conditions + 1] = { column = bare(isNull), isNull = true }
        elseif notInColumn then
            error('mysql_exec: NOT IN is not supported by the generic reader: '
                .. tostring(sql))
        elseif inColumn then
            local allowed = {}
            for entry in inList:gmatch("'([^']*)'") do allowed[entry] = true end
            if not next(allowed) then
                error('mysql_exec: cannot read the IN list in: ' .. tostring(sql))
            end
            conditions[#conditions + 1] = { column = bare(inColumn), anyOf = allowed }
        elseif column then
            if value == '?' then
                index = index + 1
                conditions[#conditions + 1] =
                    { column = bare(column), operator = operator, index = index }
            elseif value:match("^'") or tonumber(value) then
                conditions[#conditions + 1] =
                    { column = bare(column), operator = operator, literal = unquote(value) }
            else
                error('mysql_exec: cannot read `' .. term .. '` in: ' .. tostring(sql))
            end
        else
            error('mysql_exec: cannot read `' .. term .. '` in: ' .. tostring(sql))
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

    -- Several rows in one statement, VALUES (...),(...): each group a row,
    -- its parameters in order. Not under ON DUPLICATE KEY UPDATE, whose
    -- VALUES(col) are not row groups.
    if not sql:find('ON DUPLICATE KEY UPDATE', 1, true) then
        local groups = 0
        for _ in (sql:match('VALUES%s*(.*)$') or ''):gmatch('%b()') do groups = groups + 1 end
        if groups > 1 then
            local single = sql:match('^(.-VALUES)') .. ' (' .. ('?,'):rep(#columns - 1) .. '?)'
            for g = 0, groups - 1 do
                local slice = {}
                for i = 1, #columns do slice[i] = params[g * #columns + i] end
                insert(single, slice)
            end
            return {}
        end
    end

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
        -- Written even when nil. `col = VALUES(col)` with a NULL parameter
        -- sets the column to NULL on a real database; this used to skip nil
        -- values, so a stale copy carrying nil could never erase a column
        -- here while it did on MySQL. That is exactly the shape of the
        -- buyout-queue fault — a row read before the target paid, written
        -- back after with nil in the queue columns — and the simulator was
        -- incapable of showing it.
        for column in clause:gmatch('([%w_]+) = VALUES%(') do
            existing[column] = row[column]
        end
        -- `col = COALESCE(VALUES(col), col)`: a NULL parameter keeps what
        -- the row has.
        for column in clause:gmatch('([%w_]+) = COALESCE%(VALUES%(') do
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
        -- `col = col + 1`, which a real database evaluates against the row.
        -- Stored as a literal it would put the text of the expression into
        -- the column, which is exactly the kind of difference this exists
        -- to surface.
        local source, delta = trimmed:match('^([%w_]+)%s*([%+%-]%s*%d+)$')
        -- And `col = col + ?`, the same with the amount bound.
        local boundSource, sign = trimmed:match('^([%w_]+)%s*([%+%-])%s*%?$')

        if boundSource then
            index = index + 1
            assignments[#assignments + 1] = {
                column = column, relative = boundSource, index = index,
                negate = sign == '-',
            }
        elseif trimmed == '?' then
            index = index + 1
            assignments[#assignments + 1] = { column = column, index = index }
        elseif source then
            assignments[#assignments + 1] = {
                column = column, relative = source,
                delta = tonumber((delta:gsub('%s', ''))),
            }
        else
            assignments[#assignments + 1] =
                { column = column, literal = trimmed:gsub("^'", ''):gsub("'$", '') }
        end
    end

    local conditions = parseConditions(whereClause, sql)

    -- `col IS NOT NULL` / `col IS NULL`, which parseConditions does not read
    -- as an equality. Without these the row count comes back wrong, and the
    -- count is what callers act on.
    local requireSet, requireUnset = {}, {}
    for column in whereClause:gmatch('([%w_]+) IS NOT NULL') do
        requireSet[#requireSet + 1] = column
    end
    for column in whereClause:gmatch('([%w_]+) IS NULL') do
        -- `IS NOT NULL` also matches here, so anything already required to be
        -- set is not also required to be unset.
        local alsoNotNull = false
        for _, name in ipairs(requireSet) do if name == column then alsoNotNull = true end end
        if not alsoNotNull then requireUnset[#requireUnset + 1] = column end
    end

    local changed = 0

    for _, row in pairs(Exec.tables[tableName] or {}) do
        local eligible = matches(row, conditions, params, index + 1)
        for _, column in ipairs(requireSet) do
            if row[column] == nil then eligible = false end
        end
        for _, column in ipairs(requireUnset) do
            if row[column] ~= nil then eligible = false end
        end

        if eligible then
            for i = 1, #assignments do
                local assignment = assignments[i]

                if assignment.relative then
                    local delta = assignment.delta
                    if delta == nil then
                        delta = tonumber(params[assignment.index]) or 0
                        if assignment.negate then delta = -delta end
                    end
                    row[assignment.column] = (tonumber(row[assignment.relative]) or 0) + delta
                    goto continue
                end

                local value = assignment.literal
                local bound = value == nil
                if bound then value = params[assignment.index] end

                if bound and value == nil then
                    -- `col = ?` bound to nil is NULL on a real database, as
                    -- it is in an INSERT above. Skipping it left a column a
                    -- statement meant to clear holding its old value here
                    -- alone: a kill photo's served link outlived the close
                    -- that took its file.
                    row[assignment.column] = nil
                elseif type(value) == 'string' and value:upper() == 'NULL' then
                    -- A real database stores a NULL and oxmysql hands it back
                    -- as nil. Storing the string 'NULL' would make a column
                    -- that was cleared look like one holding the word.
                    row[assignment.column] = nil
                else
                    local coerced = coerce(tableName, assignment.column, value)
                    if coerced ~= nil then row[assignment.column] = coerced end
                end

                ::continue::
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
    local conditions = parseConditions(whereClause, sql)

    local out = {}
    for _, row in pairs(Exec.tables[tableName]) do
        if matches(row, conditions, params, 1) then out[#out + 1] = copy(row) end
    end

    -- SELECT DISTINCT col: that column alone, once per value.
    local distinct = sql:match('^SELECT DISTINCT ([%w_]+) FROM')
    if distinct then
        local seen, only = {}, {}
        for i = 1, #out do
            local value = out[i][distinct]
            if value ~= nil and not seen[value] then
                seen[value] = true
                only[#only + 1] = { [distinct] = value }
            end
        end
        out = only
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
    -- Both captures. `a and f()` keeps only f()'s first result, so the
    -- comparison was always nil and no DELETE with one ever matched a row:
    -- the audit prune on mysql was never exercised.
    local column, comparison
    if whereClause then column, comparison = whereClause:match('([%w_]+) ([<>]=?) %?') end

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
            local conditions = parseConditions(whereClause, sql)
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
    for _, hitman in pairs(Exec.tables.crimson_hitmen or {}) do
        if hitman.hitman_cid == cid and not seen[hitman.contract_id] then
            local contract = Exec.tables.crimson_contracts[hitman.contract_id]
            if contract then
                seen[contract.id] = true
                out[#out + 1] = copy(contract)
            end
        end
    end

    sortRows(out, { 'id' }, false)
    return out
end

local function hitmanContractStates(sql, params)
    -- The hitman states the statement asks for, read from it rather than
    -- assumed, so a change to which rows count is exercised here too.
    local wanted = {}
    local list = sql:match("h%.state IN %(([^)]*)%)")
    if list then
        for state in list:gmatch("'([^']*)'") do wanted[state] = true end
    else
        local one = sql:match("h%.state = '([^']*)'")
        if not one then error('mysql_exec: cannot read the hitman states in: ' .. sql) end
        wanted[one] = true
    end
    local out = {}
    for _, hitman in pairs(Exec.tables.crimson_hitmen or {}) do
        if hitman.hitman_cid == params[1] and wanted[hitman.state] then
            local contract = Exec.tables.crimson_contracts[hitman.contract_id]
            if contract then out[#out + 1] = { state = contract.state } end
        end
    end
    return out
end

--- Every hitman row whose contract is in one of the named states, in
--- (accepted_at, id) order: the death sampler's one roster read a pass.
local function liveHitmen(sql)
    local wanted = {}
    local list = sql:match("c%.state IN %(([^)]*)%)")
    if not list then error('mysql_exec: cannot read the contract states in: ' .. sql) end
    for state in list:gmatch("'([^']*)'") do wanted[state] = true end
    local out = {}
    for _, hitman in pairs(Exec.tables.crimson_hitmen or {}) do
        local contract = (Exec.tables.crimson_contracts or {})[hitman.contract_id]
        if contract and wanted[contract.state] then out[#out + 1] = copy(hitman) end
    end
    sortRows(out, { 'accepted_at', 'id' }, false)
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

local function pruneMessages(params)
    local thread, contract, keep = params[1], params[2], tonumber(params[5]) or 100
    local mine = {}
    for _, row in pairs(Exec.tables.crimson_messages or {}) do
        if row.thread_id == thread and row.contract_id == contract then mine[#mine + 1] = row end
    end
    sortRows(mine, { 'id' }, true)
    for i = keep + 1, #mine do
        Exec.tables.crimson_messages[mine[i].id] = nil
    end
    return {}
end

--------------------------------------------------------------------------

function Exec.reset()
    Exec.tables, Exec.schema, Exec.primary, Exec.engines = {}, {}, {}, {}
    Exec.statements = {}
end

function Exec.run(sql, params)
    if type(sql) ~= 'string' then return {} end
    params = params or {}

    local flat = squash(sql)
    Exec.statements[#Exec.statements + 1] = flat

    if flat:find('^CREATE TABLE') then
        -- IF NOT EXISTS: a table already here is left exactly as it is.
        local name = flat:match('^CREATE TABLE IF NOT EXISTS ([%w_]+)')
        if not (name and Exec.schema[name]) then parseSchema(sql) end
        return {}
    end
    -- A table moved to another engine keeps its rows.
    local moved, engine = flat:match('^ALTER TABLE ([%w_]+) ENGINE=([%w_]+)$')
    if moved then
        if Exec.schema[moved] then Exec.engines[moved] = engine end
        return {}
    end
    if flat:find('^ALTER TABLE') then return {} end
    -- The crimson tables there are, with each one's engine.
    if flat:find('information_schema%.TABLES') and flat:find("TABLE_NAME LIKE 'crimson%%'") then
        local rows = {}
        for name in pairs(Exec.schema) do
            rows[#rows + 1] = { TABLE_NAME = name, ENGINE = Exec.engines[name] or 'InnoDB' }
        end
        table.sort(rows, function(a, b) return a.TABLE_NAME < b.TABLE_NAME end)
        return rows
    end
    -- Which of a list of tables exist: the ones CREATE TABLE has made here.
    if flat:find('information_schema%.TABLES') and flat:find('TABLE_NAME IN %(') then
        local rows = {}
        for name in flat:match('TABLE_NAME IN %((.-)%)'):gmatch("'([%w_]+)'") do
            if Exec.schema[name] then rows[#rows + 1] = { TABLE_NAME = name } end
        end
        return rows
    end
    if flat:find('information_schema') then return {} end

    if flat:find('^INSERT INTO crimson_ledger') and flat:find('DELETE') then
        return pruneLedger(params)
    end
    if flat:find('^DELETE FROM crimson_ledger') then return pruneLedger(params) end
    if flat:find('^DELETE FROM crimson_messages') and flat:find('NOT IN') then
        return pruneMessages(params)
    end
    if flat:find('^SELECT c%.%* FROM crimson_contracts') then
        return contractsInvolving(params)
    end
    if flat:find('^SELECT c%.state AS state') then return hitmanContractStates(flat, params) end
    if flat:find('^SELECT h%.%* FROM crimson_hitmen h JOIN crimson_contracts c') then
        return liveHitmen(flat)
    end
    -- A count with a condition is the rows the same SELECT * would return.
    if flat:find('^SELECT COUNT%(%*%) FROM [%w_]+ WHERE ') then
        return #select_(flat:gsub('^SELECT COUNT%(%*%)', 'SELECT *', 1), params)
    end
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
    local method = Natives.mysqlMethod
    Natives.mysql.query = method({ await = function(sql, params) return Exec.run(sql, params) end })
    Natives.mysql.insert = method({ await = function(sql, params) Exec.run(sql, params) return 1 end })
    Natives.mysql.update = method({ await = function(sql, params) return Exec.run(sql, params) end })
    Natives.mysql.scalar = method({ await = function(sql, params)
        local result = Exec.run(sql, params)
        return type(result) == 'number' and result or 0
    end })
    -- All of it, in one await: nothing else runs in between, as nothing sees
    -- a transaction half-applied on a real database.
    Natives.mysql.transaction = { await = function(queries)
        for _, q in ipairs(queries) do
            Exec.run(q.query or q[1], q.values or q.parameters or q[2])
        end
        return true
    end }
end

return Exec
