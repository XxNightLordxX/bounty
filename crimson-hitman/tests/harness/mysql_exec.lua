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
---     does not reach into the store;
---   * a value is held to its column as MariaDB 10.11's strict mode holds
---     it (OXMYSQL.md §5): an INT past -2^31..2^31-1, a VARCHAR(n) past n
---     characters, a TEXT past 65,535 bytes, a NULL in a NOT NULL column
---     and a NOT NULL column left out with no DEFAULT are refused, with
---     the server's own words inside oxmysql's message, and a statement
---     refused writes none of itself. A column left out takes its DEFAULT,
---     so crimson_hitmen.stake_amount reads 0 as it does there;
---   * a transaction is all or nothing, and answers false where a
---     statement in it fails, as oxmysql's does (OXMYSQL.md §3);
---   * an await can be left unanswered, the database gone (Exec.down), or
---     answered late, a write that lands after its caller stopped waiting
---     (Exec.lateNext, Exec.releaseLate). Both park the caller's coroutine
---     in Citizen.Await (tests/harness/natives.lua), so a test runs the
---     caller in Env.spawn.

local Exec = {
    tables = {}, schema = {}, primary = {}, engines = {}, booleans = true,
    -- Every await sent while this is set is never answered.
    down = false,
    -- How many of the next awaited statements are held for releaseLate.
    lateNext = 0,
    late = {},
    -- oxmysql's message for every statement the database refused.
    refused = {},
    -- Every statement sent while the database was down, which never landed.
    lost = {},
}

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

--- What one column declaration says its values must be: the base type and
--- length (VARCHAR(32), TINYINT(1), INT, TEXT), NOT NULL (a primary key is
--- one), the DEFAULT, and AUTO_INCREMENT.
local function declared(definition)
    local rest = definition:match('^[%w_]+%s+(.*)$') or ''
    local upper = rest:upper()
    local base, size = upper:match('^(%a+)%s*%((%d+)%)')
    if not base then base = upper:match('^(%a+)') end
    local literal = rest:match("%f[%w_][Dd][Ee][Ff][Aa][Uu][Ll][Tt]%s+('[^']*')")
        or rest:match('%f[%w_][Dd][Ee][Ff][Aa][Uu][Ll][Tt]%s+([^%s,]+)')
    local default
    if literal and literal:upper() ~= 'NULL' then
        default = literal:match("^'(.*)'$") or tonumber(literal) or literal
    end
    return {
        base = base, size = tonumber(size),
        notNull = upper:find('NOT NULL', 1, true) ~= nil
            or upper:find('PRIMARY KEY', 1, true) ~= nil,
        hasDefault = literal ~= nil, default = default,
        auto = upper:find('AUTO_INCREMENT', 1, true) ~= nil,
    }
end

local function parseSchema(sql)
    local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
    if not name then return end

    local columns, order, primary, types = {}, {}, nil, {}
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
                types[column] = declared(trimmed)
            end
        end
    end

    Exec.schema[name] = { columns = columns, order = order, types = types }
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
        -- NULL stays NULL: oxmysql's typeCast hands a NULL TINYINT(1) back
        -- as nil (typeCast.ts: `value === null ? null : value === '1'`),
        -- not false. A nullable one (crimson_playtime.grandfathered) uses it.
        if value == nil then return nil end
        local on = value == true or (tonumber(value) or 0) ~= 0
        if Exec.booleans then return on end
        return on and 1 or 0
    end
    return value
end

--------------------------------------------------------------------------
-- Strict mode
--------------------------------------------------------------------------

local INT_RANGE = { INT = { -2147483648, 2147483647 }, TINYINT = { -128, 127 } }
local TEXT_BYTES = 65535

--- A refusal on its way to Exec.run, which puts it in oxmysql's words.
local Refusal = {}

local function refuse(text)
    error(setmetatable({ text = text }, Refusal), 0)
end

--- Refuse a value its column cannot hold, as MariaDB 10.11 in strict mode
--- does (STRICT_TRANS_TABLES, which oxmysql's connections run under): in
--- its own words, the row counted from 1. A column the schema does not
--- declare is dropped elsewhere, not refused here.
local function check(tableName, column, value, rowNumber)
    local schema = Exec.schema[tableName]
    local t = schema and schema.types and schema.types[column]
    if not t then return end
    if value == nil then
        if t.notNull and not t.auto then refuse(("Column '%s' cannot be null"):format(column)) end
        return
    end
    local range = INT_RANGE[t.base]
    if range then
        local n = value
        if type(n) == 'boolean' then n = n and 1 or 0 end
        n = tonumber(n)
        if n and (n < range[1] or n > range[2]) then
            refuse(("Out of range value for column '%s' at row %d"):format(column, rowNumber or 1))
        end
    elseif (t.base == 'VARCHAR' and t.size and (utf8.len(tostring(value)) or #tostring(value)) > t.size)
        or (t.base == 'TEXT' and #tostring(value) > TEXT_BYTES) then
        refuse(("Data too long for column '%s' at row %d"):format(column, rowNumber or 1))
    end
end

--- What oxmysql's await raises for a statement the database refused
--- (OXMYSQL.md §5): the statement, its parameters, the server's message.
local function oxmysqlText(sql, params, message)
    local ok, encoded = pcall(json.encode, params or {})
    return ('%s was unable to execute a query!\nQuery: %s\n%s\n%s'):format(
        GetCurrentResourceName(), tostring(sql), ok and encoded or '[]', message)
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

        if condition.subquery then
            -- The correlated subquery, evaluated by scanning the other
            -- table. Slow and exact, which is what a test executor wants.
            -- Its own conditions are read as any WHERE is, so one inside it
            -- (an IN list, another EXISTS) is held to the row it names.
            -- With no join column it is uncorrelated: any row of the other
            -- table its own conditions keep.
            local linked = condition.link and row[condition.linkedTo]
            local found = false
            for _, other in pairs(Exec.tables[condition.subquery] or {}) do
                if (not condition.link or tostring(other[condition.link]) == tostring(linked))
                    and matches(other, condition.inner, params, from) then
                    found = true
                    break
                end
            end
            if found ~= condition.exists then return false end

        elseif condition.branches then
            -- ( A OR B ... ): true when any branch, a conjunction, is.
            local any = false
            for _, branch in ipairs(condition.branches) do
                if matches(row, branch, params, from) then
                    any = true
                    break
                end
            end
            if not any then return false end
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

--- The inside of a term written wholly in one pair of parentheses, or nil:
--- `(a OR b)` is, `(a) OR (b)` and `EXISTS (...)` are not.
local function enclosed(term)
    if term:sub(1, 1) ~= '(' or term:sub(-1) ~= ')' then return nil end
    local depth = 0
    for i = 1, #term do
        local char = term:sub(i, i)
        if char == '(' then depth = depth + 1 elseif char == ')' then depth = depth - 1 end
        if depth == 0 and i < #term then return nil end
    end
    return term:sub(2, -2)
end

--- Split a clause on its top-level ORs, as andTerms does on ANDs; nil when
--- there is none.
local function orTerms(clause)
    local terms, depth, start, i = {}, 0, 1, 1
    while i <= #clause do
        local char = clause:sub(i, i)
        if char == '(' then depth = depth + 1
        elseif char == ')' then depth = depth - 1
        elseif depth == 0 and clause:sub(i, i + 3):upper() == ' OR ' then
            terms[#terms + 1] = clause:sub(start, i - 1)
            i = i + 3
            start = i + 1
        end
        i = i + 1
    end
    if #terms == 0 then return nil end
    terms[#terms + 1] = clause:sub(start)
    for j = 1, #terms do terms[j] = terms[j]:match('^%s*(.-)%s*$') end
    return terms
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
        -- One parenthesised OR of conjunctions, as recordBailout's
        -- `(bailout_queued_at IS NULL OR (bailout_queued_at = ? AND
        -- bailout_paid_by = ?))`: each branch read as any WHERE is, its
        -- values numbered after every `?` before it.
        local inside = enclosed(term)
        local alternatives = inside and orTerms(inside)
        if alternatives then
            local branches = {}
            for _, alternative in ipairs(alternatives) do
                local branch, bound = parseConditions(enclosed(alternative) or alternative, sql)
                for _, condition in ipairs(branch) do
                    if condition.subquery or condition.branches then
                        error('mysql_exec: a subquery or a nested OR inside an OR is not '
                            .. 'supported: ' .. tostring(sql))
                    end
                    if condition.index then condition.index = condition.index + index end
                end
                index = index + bound
                branches[#branches + 1] = branch
            end
            conditions[#conditions + 1] = { branches = branches }
            goto continue
        end
        -- The OR in contractsInvolving is routed to its own handler; every
        -- other clause here is a conjunction, and treating an OR as one
        -- would silently narrow the result.
        if term:upper():find(' OR ') then
            error('mysql_exec: OR is not supported by the generic reader: ' .. tostring(sql))
        end

        local negatedExists = term:match('^[Nn][Oo][Tt]%s+EXISTS%s*%((.*)%)$')
        local positiveExists = not negatedExists and term:match('^EXISTS%s*%((.*)%)$')
        local column, operator, value = term:match('^([%w_.]+)%s*([=<>!]+)%s*(.+)$')
        local isNull = term:match('^([%w_.]+)%s+IS%s+NULL$')
        local notNull = term:match('^([%w_.]+)%s+IS%s+NOT%s+NULL$')
        local inColumn, inList = term:match('^([%w_.]+)%s+IN%s*%((.*)%)$')
        local notInColumn = term:match('^([%w_.]+)%s+NOT%s+IN%s*%(')

        local function bare(name) return name:match('([%w_]+)$') end

        if negatedExists or positiveExists then
            -- [NOT] EXISTS (SELECT 1 FROM <table> <alias> WHERE <alias>.<col> =
            -- <outer>.<col> [AND ...]): the one term naming a column of the
            -- row outside is the join, and the rest are read as any WHERE is,
            -- a nested EXISTS among them, against the row inside.
            local subquery = negatedExists or positiveExists
            local subTable = subquery:match('FROM%s+([%w_]+)')
            local subWhere = subquery:match('WHERE%s+(.*)$')
            if not subTable or not subWhere then
                error('mysql_exec: cannot read the subquery in: ' .. tostring(sql))
            end
            local link, linkedTo, rest = nil, nil, {}
            for _, inner in ipairs(andTerms(subWhere)) do
                local left, op, right = inner:match('^([%w_.]+)%s*([=<>!]+)%s*(.+)$')
                if left and op == '=' and right:match('^[%a_][%w_]*%.[%w_]+$') and not link then
                    link, linkedTo = bare(left), bare(right)
                else
                    rest[#rest + 1] = inner
                end
            end
            local inner, bound = parseConditions(#rest > 0 and table.concat(rest, ' AND ') or nil, sql)
            if bound > 0 then
                -- An uncorrelated subquery may bind its own values, as
                -- MySQLStore.abandonHitman's `c.id = ?` does: they come after
                -- every `?` before it in the statement, which is where they
                -- are read from. One that also joins, or nests a subquery
                -- of its own, is not a shape this backend sends.
                if link then
                    error('mysql_exec: a bound parameter inside a correlated subquery is '
                        .. 'not supported: ' .. tostring(sql))
                end
                for _, condition in ipairs(inner) do
                    if condition.subquery then
                        error('mysql_exec: a subquery inside a subquery that binds values is '
                            .. 'not supported: ' .. tostring(sql))
                    end
                    if condition.index then condition.index = condition.index + index end
                end
                index = index + bound
            elseif not link then
                error('mysql_exec: the subquery names no join column: ' .. tostring(sql))
            end
            conditions[#conditions + 1] = { subquery = subTable,
                exists = type(positiveExists) == 'string',
                link = link, linkedTo = linkedTo, inner = inner }

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
        ::continue::
    end

    return conditions, index
end

--- One row of an INSERT, checked as MariaDB checks it, and the change it
--- makes, not yet made: answers the function that makes it.
local function prepareRow(sql, tableName, columns, values, rowNumber)
    local declaredTable = Exec.schema[tableName]
    local row, named = {}, {}
    for i = 1, #columns do
        named[columns[i]] = true
        check(tableName, columns[i], values[i], rowNumber)
        local value = coerce(tableName, columns[i], values[i])
        if value ~= nil then row[columns[i]] = value end
    end
    -- Every column the statement leaves out takes its DEFAULT, or refuses
    -- the row where it is NOT NULL with none to take.
    for _, column in ipairs(declaredTable and declaredTable.order or {}) do
        local t = declaredTable.types and declaredTable.types[column]
        if t and not named[column] then
            if t.hasDefault then
                if t.default ~= nil then row[column] = coerce(tableName, column, t.default) end
            elseif t.notNull and not t.auto then
                refuse(("Field '%s' doesn't have a default value"):format(column))
            end
        end
    end

    local key = Exec.primary[tableName] or 'id'
    local existing = row[key] ~= nil and (Exec.tables[tableName] or {})[row[key]]
    if existing and sql:find('ON DUPLICATE KEY UPDATE') then
        -- Only the columns the UPDATE clause names are changed, which is how
        -- `state` stays out of writeContract's reach.
        local clause = sql:match('ON DUPLICATE KEY UPDATE (.*)$') or ''
        local changes = {}
        -- Written even when nil. `col = VALUES(col)` with a NULL parameter
        -- sets the column to NULL on a real database; this used to skip nil
        -- values, so a stale copy carrying nil could never erase a column
        -- here while it did on MySQL. That is exactly the shape of the
        -- buyout-queue fault — a row read before the target paid, written
        -- back after with nil in the queue columns — and the simulator was
        -- incapable of showing it.
        for column in clause:gmatch('([%w_]+) = VALUES%(') do changes[column] = { row[column] } end
        -- `col = COALESCE(VALUES(col), col)`: a NULL parameter keeps what
        -- the row has.
        for column in clause:gmatch('([%w_]+) = COALESCE%(VALUES%(') do
            if row[column] ~= nil then changes[column] = { row[column] } end
        end
        -- `col = col + VALUES(col)`: bumpStat's counters, added to what the
        -- row holds. Ignored, a second bump left the first one's count.
        for column, source in clause:gmatch('([%w_]+) = ([%w_]+) %+ VALUES%(') do
            local held, added = tonumber(existing[source]), tonumber(row[column])
            changes[column] = { (held and added) and (held + added) or nil }
        end
        for column, change in pairs(changes) do check(tableName, column, change[1], rowNumber) end
        return function()
            for column, change in pairs(changes) do existing[column] = change[1] end
        end
    end

    return function()
        Exec.tables[tableName] = Exec.tables[tableName] or {}
        local id = row[key]
        if id == nil then
            -- AUTO_INCREMENT.
            local next_ = 1
            for taken in pairs(Exec.tables[tableName]) do
                if type(taken) == 'number' and taken >= next_ then next_ = taken + 1 end
            end
            id = next_
            row[key] = id
        end
        Exec.tables[tableName][id] = row
    end
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
    local groups = 1
    if not sql:find('ON DUPLICATE KEY UPDATE', 1, true) then
        groups = 0
        for _ in (sql:match('VALUES%s*(.*)$') or ''):gmatch('%b()') do groups = groups + 1 end
        groups = math.max(groups, 1)
    end

    -- Every row checked before any is stored: one statement is all or
    -- nothing, so a row the database refuses leaves none of the others.
    local writes = {}
    for g = 0, groups - 1 do
        local values = {}
        for i = 1, #columns do values[i] = params[g * #columns + i] end
        writes[#writes + 1] = prepareRow(sql, tableName, columns, values, g + 1)
    end
    for i = 1, #writes do writes[i]() end
    return {}
end

local function update(sql, params)
    local tableName, setClause, whereClause =
        sql:match('^UPDATE ([%w_]+) SET (.-) WHERE (.*)$')
    if not tableName then return {} end

    -- Assignments first, then the WHERE, which is the parameter order. Split
    -- on the commas between assignments only, not the ones inside a call.
    local parts, depth, part = {}, 0, {}
    for ch in (setClause .. ','):gmatch('.') do
        if ch == ',' and depth == 0 then
            parts[#parts + 1] = table.concat(part)
            part = {}
        else
            if ch == '(' then depth = depth + 1 elseif ch == ')' then depth = depth - 1 end
            part[#part + 1] = ch
        end
    end
    local assignments, index = {}, 0
    for _, text in ipairs(parts) do
        local column, value = text:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if not column then error('mysql_exec: cannot read the assignment ' .. text) end
        local trimmed = value
        -- `col = col + 1`, which a real database evaluates against the row.
        -- Stored as a literal it would put the text of the expression into
        -- the column, which is exactly the kind of difference this exists
        -- to surface.
        local source, delta = trimmed:match('^([%w_]+)%s*([%+%-]%s*%d+)$')
        -- And `col = col + ?`, the same with the amount bound.
        local boundSource, sign = trimmed:match('^([%w_]+)%s*([%+%-])%s*%?$')
        -- And `col = LEAST(col + ?, n)`: the sum held to a ceiling, worked
        -- out before it is held, as MariaDB adds in BIGINT first.
        local leastSource, leastCap = trimmed:match('^LEAST%(%s*([%w_]+)%s*%+%s*%?%s*,%s*(%-?%d+)%s*%)$')

        if leastSource then
            index = index + 1
            assignments[#assignments + 1] = {
                column = column, relative = leastSource, index = index,
                cap = tonumber(leastCap),
            }
        elseif boundSource then
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
    -- Not inside a parenthesised OR, which parseConditions reads itself: a
    -- `col IS NULL` there is one branch, not a condition on every row.
    local outside = {}
    for _, term in ipairs(andTerms(whereClause)) do
        if not (enclosed(term) and orTerms(enclosed(term))) then outside[#outside + 1] = term end
    end
    local flatWhere = table.concat(outside, ' AND ')
    for column in flatWhere:gmatch('([%w_]+) IS NOT NULL') do
        requireSet[#requireSet + 1] = column
    end
    for column in flatWhere:gmatch('([%w_]+) IS NULL') do
        -- `IS NOT NULL` also matches here, so anything already required to be
        -- set is not also required to be unset.
        local alsoNotNull = false
        for _, name in ipairs(requireSet) do if name == column then alsoNotNull = true end end
        if not alsoNotNull then requireUnset[#requireUnset + 1] = column end
    end

    -- Every matched row worked out and checked before any is changed: one
    -- statement is all or nothing, so a row the database refuses leaves
    -- every other row as it was.
    local changed, writes = 0, {}

    for _, row in pairs(Exec.tables[tableName] or {}) do
        local eligible = matches(row, conditions, params, index + 1)
        for _, column in ipairs(requireSet) do
            if row[column] == nil then eligible = false end
        end
        for _, column in ipairs(requireUnset) do
            if row[column] ~= nil then eligible = false end
        end

        if eligible then
            changed = changed + 1
            -- Left to right, each assignment seeing the ones before it, as
            -- MariaDB assigns a single-table UPDATE.
            local after, order = {}, {}
            local function current(column)
                if after[column] ~= nil then return after[column][1] end
                return row[column]
            end
            for i = 1, #assignments do
                local assignment = assignments[i]
                local value

                if assignment.relative then
                    local delta = assignment.delta
                    if delta == nil then
                        delta = tonumber(params[assignment.index]) or 0
                        if assignment.negate then delta = -delta end
                    end
                    value = { (tonumber(current(assignment.relative)) or 0) + delta }
                    if assignment.cap and value[1] > assignment.cap then value = { assignment.cap } end
                else
                    local literal = assignment.literal
                    local bound = literal == nil
                    if bound then literal = params[assignment.index] end

                    if bound and literal == nil then
                        -- `col = ?` bound to nil is NULL on a real database, as
                        -- it is in an INSERT above. Skipping it left a column a
                        -- statement meant to clear holding its old value here
                        -- alone: a kill photo's served link outlived the close
                        -- that took its file.
                        value = { nil }
                    elseif type(literal) == 'string' and literal:upper() == 'NULL' then
                        -- A real database stores a NULL and oxmysql hands it back
                        -- as nil. Storing the string 'NULL' would make a column
                        -- that was cleared look like one holding the word.
                        value = { nil }
                    else
                        local coerced = coerce(tableName, assignment.column, literal)
                        if coerced ~= nil then value = { coerced } end
                    end
                end

                if value then
                    check(tableName, assignment.column, value[1], changed)
                    if after[assignment.column] == nil then order[#order + 1] = assignment.column end
                    after[assignment.column] = value
                end
            end
            writes[#writes + 1] = { row = row, after = after, order = order }
        end
    end

    for _, write in ipairs(writes) do
        for _, column in ipairs(write.order) do write.row[column] = write.after[column][1] end
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
    -- `... ORDER BY col LIMIT ?`: the first `?`-many rows in that order,
    -- as MariaDB deletes them (the audit prune, a batch a tick).
    local orderBy, limit
    if whereClause then
        local head, by = whereClause:match('^(.-)%s+ORDER BY ([%w_]+)')
        if head then
            whereClause, orderBy = head, by
            if sql:find('LIMIT %?%s*$') then limit = tonumber(params[#params]) end
        end
    end
    -- Both captures. `a and f()` keeps only f()'s first result, so the
    -- comparison was always nil and no DELETE with one ever matched a row:
    -- the audit prune on mysql was never exercised.
    local column, comparison
    if whereClause then column, comparison = whereClause:match('^([%w_]+) ([<>]=?) %?$') end

    local doomed = {}
    for key, row in pairs(Exec.tables[tableName] or {}) do
        if column then
            local value, bound = tonumber(row[column]), tonumber(params[1])
            if value and bound then
                if (comparison == '<' and value < bound)
                    or (comparison == '>' and value > bound)
                    or (comparison == '<=' and value <= bound)
                    or (comparison == '>=' and value >= bound) then
                    doomed[#doomed + 1] = { key = key, row = row }
                end
            end
        else
            local conditions = parseConditions(whereClause, sql)
            if matches(row, conditions, params, 1) then doomed[#doomed + 1] = { key = key, row = row } end
        end
    end
    if orderBy then
        table.sort(doomed, function(a, b)
            local av, bv = a.row[orderBy], b.row[orderBy]
            if av ~= bv then return (tonumber(av) or 0) < (tonumber(bv) or 0) end
            return tostring(a.key) < tostring(b.key)
        end)
    end
    -- How many it deleted, as oxmysql's `update` answers a DELETE (its
    -- affectedRows, OXMYSQL.md §2): a guarded delete reads it to know
    -- whether the row was still there in the state it was read in.
    local deleted = 0
    for i = 1, #doomed do
        if limit and i > limit then break end
        Exec.tables[tableName][doomed[i].key] = nil
        deleted = deleted + 1
    end

    return deleted
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

--- SELECT e.* FROM crimson_escrow e JOIN crimson_contracts c ON c.id =
--- e.contract_id WHERE ... [ORDER BY e.id] [LIMIT ?]: each condition read by
--- the generic reader and asked of the row its alias names, so a condition
--- this cannot place raises like any other it cannot read.
local function escrowOfContracts(sql, params)
    if not sql:find('JOIN crimson_contracts c ON c%.id = e%.contract_id') then
        error('mysql_exec: cannot read the join in: ' .. sql)
    end
    local whereClause = sql:match('WHERE (.-)%s*ORDER BY') or sql:match('WHERE (.-)%s*LIMIT')
        or sql:match('WHERE (.*)$')
    local onEscrow, onContract = {}, {}
    for _, term in ipairs(andTerms(whereClause or '')) do
        local alias = term:match('^(%a)%.')
        if term:find('?', 1, true) then
            error('mysql_exec: a bound parameter in this join\'s WHERE is not supported: ' .. sql)
        elseif alias == 'e' then
            onEscrow[#onEscrow + 1] = term
        elseif alias == 'c' then
            onContract[#onContract + 1] = term
        else
            error('mysql_exec: `' .. term .. '` names neither table in: ' .. sql)
        end
    end
    local escrowConditions = parseConditions(#onEscrow > 0 and table.concat(onEscrow, ' AND ') or nil, sql)
    local contractConditions =
        parseConditions(#onContract > 0 and table.concat(onContract, ' AND ') or nil, sql)

    local out = {}
    for _, row in pairs(Exec.tables.crimson_escrow or {}) do
        local contract = (Exec.tables.crimson_contracts or {})[row.contract_id]
        if contract and matches(row, escrowConditions, params, 1)
            and matches(contract, contractConditions, params, 1) then
            out[#out + 1] = copy(row)
        end
    end
    if sql:find('ORDER BY e%.id') then sortRows(out, { 'id' }, false) end
    if sql:find('LIMIT %?') then
        local n = tonumber(params[#params]) or #out
        while #out > n do table.remove(out) end
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
    Exec.down, Exec.lateNext, Exec.late, Exec.refused, Exec.lost = false, 0, {}, {}, {}
end

--- What one statement does, by its shape.
local function execute(sql, params, flat)
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
    -- A table's columns, with which is its primary key (COLUMN_KEY 'PRI'),
    -- and the character set and collation every text column here is made
    -- in, for the tables CREATE TABLE has made here.
    if flat:find('information_schema%.COLUMNS') then
        local name = params[1]
        local declared = Exec.schema[name]
        if not declared then return {} end
        local rows = {}
        for _, column in ipairs(declared.order) do
            local t = declared.types[column] or {}
            local text = t.base == 'VARCHAR' or t.base == 'TEXT'
            rows[#rows + 1] = {
                COLUMN_NAME = column,
                COLUMN_KEY = Exec.primary[name] == column and 'PRI' or '',
                CHARACTER_SET_NAME = text and 'utf8mb4' or nil,
                COLLATION_NAME = text and 'utf8mb4_unicode_ci' or nil,
            }
        end
        return rows
    end
    if flat:find('information_schema') then return {} end
    -- The store's probe of the connection (server/storage/mysql.lua).
    if flat == 'SELECT 1' then return 1 end

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
    if flat:find('^SELECT e%.%* FROM crimson_escrow e JOIN crimson_contracts c') then
        return escrowOfContracts(flat, params)
    end
    -- `SELECT col, COUNT(*) AS n FROM t GROUP BY col`: one row per value
    -- the column holds, with how many rows hold it (the overview's count by
    -- state). A NULL is a group of its own, as MariaDB groups it.
    local groupColumn, countAlias, groupTable, groupBy = flat:match(
        '^SELECT ([%w_]+), COUNT%(%*%) AS ([%w_]+) FROM ([%w_]+) GROUP BY ([%w_]+)$')
    if groupColumn then
        if groupBy ~= groupColumn then error('mysql_exec: GROUP BY another column: ' .. flat) end
        local counts, order, nulls = {}, {}, 0
        for _, row in pairs(rowsOf(groupTable)) do
            local value = row[groupColumn]
            if value == nil then
                nulls = nulls + 1
            else
                if not counts[value] then order[#order + 1] = value end
                counts[value] = (counts[value] or 0) + 1
            end
        end
        local out = {}
        for _, value in ipairs(order) do out[#out + 1] = { [groupColumn] = value, [countAlias] = counts[value] } end
        if nulls > 0 then out[#out + 1] = { [countAlias] = nulls } end
        return out
    end
    -- `SELECT MAX(col) AS name FROM t WHERE ...`: one row, the column's
    -- highest value among the rows the same SELECT * would return, and NULL
    -- (nil here, as oxmysql hands it back) when none matches.
    local maxColumn, maxAlias = flat:match('^SELECT MAX%(([%w_]+)%) AS ([%w_]+) FROM ')
    if maxColumn then
        local top
        for _, row in ipairs(select_(flat:gsub('^SELECT MAX%([%w_]+%) AS [%w_]+', 'SELECT *', 1), params)) do
            local value = tonumber(row[maxColumn])
            if value and (not top or value > top) then top = value end
        end
        return { { [maxAlias] = top } }
    end
    -- A count with a condition is the rows the same SELECT * would return.
    if flat:find('^SELECT COUNT%(%*%) FROM [%w_]+ WHERE ')
        or flat:find('^SELECT COUNT%(%*%) FROM [%w_]+ %a+ WHERE ') then
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

--- Run one statement. One the database refuses raises what oxmysql's await
--- raises, the server's words last, and is kept in Exec.refused; one this
--- executor cannot read raises its own words, so a gap stays loud.
function Exec.run(sql, params)
    if type(sql) ~= 'string' then return {} end
    params = params or {}

    local flat = squash(sql)
    Exec.statements[#Exec.statements + 1] = flat

    local ok, result = pcall(execute, sql, params, flat)
    if ok then return result end
    if getmetatable(result) == Refusal then
        local message = oxmysqlText(sql, params, result.text)
        Exec.refused[#Exec.refused + 1] = message
        error(message, 0)
    end
    error(result, 0)
end

--- Whether an error is a statement the database refused, rather than one
--- this executor could not read.
local function isRefusal(err)
    return type(err) == 'string' and err:find('was unable to execute a query!', 1, true) ~= nil
end

local function describeStatement(sql)
    if type(sql) == 'table' then return 'TRANSACTION(' .. #sql .. ')' end
    return squash(tostring(sql))
end

--- One oxmysql method over the executor, both ways lib/MySQL.lua gives it.
---
--- `.await(sql, params)` answers at once, unless the database is down
--- (Exec.down: it parks for good, as an await on a pool that cannot
--- connect does, OXMYSQL.md §6) or the statement is one of the next
--- Exec.lateNext (held, unanswered, until Exec.releaseLate runs it).
---
--- Called directly, `(sql, params, cb)`, it is handed over and not waited
--- for: lost while the database is down, and where the database refuses
--- it, printed by oxmysql with cb never called (no return_callback_errors);
--- a statement this executor cannot read still raises.
local function method(run)
    local m = {}
    m.await = function(sql, params)
        if Exec.down then
            Exec.lost[#Exec.lost + 1] = describeStatement(sql)
            return Citizen.Await(promise.new())
        end
        if (Exec.lateNext or 0) > 0 then
            Exec.lateNext = Exec.lateNext - 1
            local p = promise.new()
            Exec.late[#Exec.late + 1] = {
                promise = p, sql = describeStatement(sql),
                run = function() return run(sql, params) end,
            }
            return Citizen.Await(p)
        end
        return run(sql, params)
    end
    return setmetatable(m, { __call = function(_, sql, params, cb)
        if type(params) == 'function' then params, cb = nil, params end
        if Exec.down then
            Exec.lost[#Exec.lost + 1] = describeStatement(sql)
            return
        end
        local ok, result = pcall(run, sql, params)
        if not ok then
            if isRefusal(result) then return end
            error(result, 0)
        end
        if type(cb) == 'function' then cb(result) end
    end })
end

--- Every statement Exec.lateNext held, run now in the order they were
--- sent, each one's await settled with what it answered. A caller whose
--- own timeout settled its promise first is told nothing more, and the
--- write lands all the same: a timed-out write landing late. The callers
--- still waiting resume at the next Env.runTimers or Env.advance.
---@return integer count how many ran
function Exec.releaseLate()
    local held = Exec.late
    Exec.late = {}
    for i = 1, #held do
        local ok, result = pcall(held[i].run)
        if ok then held[i].promise:resolve(result) else held[i].promise:reject(result) end
    end
    return #held
end

--- The table a write statement changes, or nil.
local function writtenTable(sql)
    local flat = squash(tostring(sql or ''))
    return flat:match('^INSERT INTO ([%w_]+)') or flat:match('^UPDATE ([%w_]+)')
        or flat:match('^DELETE FROM ([%w_]+)')
end

--- oxmysql's transaction: every statement on one connection, committed
--- together or not at all. A statement that fails rolls back every one
--- before it and the answer is false, not a raise (OXMYSQL.md §3); this
--- used to keep the ones before it and raise. A statement this executor
--- cannot read is put back the same way and still raises.
local function transaction(queries)
    local saved = {}
    for _, q in ipairs(queries) do
        local name = writtenTable(q.query or q[1])
        if name and saved[name] == nil then
            saved[name] = { rows = Exec.tables[name] and copy(Exec.tables[name]) }
        end
    end
    for _, q in ipairs(queries) do
        local ok, err = pcall(Exec.run, q.query or q[1], q.values or q.parameters or q[2])
        if not ok then
            for name, kept in pairs(saved) do Exec.tables[name] = kept.rows end
            if type(err) == 'string' and err:find('mysql_exec: ', 1, true) and not isRefusal(err) then
                error(err, 0)
            end
            return false
        end
    end
    return true
end

function Exec.install(Natives)
    Exec.reset()
    Natives.mysql.query = method(function(sql, params) return Exec.run(sql, params) end)
    Natives.mysql.insert = method(function(sql, params) Exec.run(sql, params) return 1 end)
    Natives.mysql.update = method(function(sql, params) return Exec.run(sql, params) end)
    Natives.mysql.scalar = method(function(sql, params)
        local result = Exec.run(sql, params)
        return type(result) == 'number' and result or 0
    end)
    -- All of it, in one await: nothing else runs in between, as nothing sees
    -- a transaction half-applied on a real database.
    Natives.mysql.transaction = method(transaction)
end

return Exec
