--- A MySQL simulator that behaves like a real database in the ways that
--- matter: it stores only the columns the schema declares, and it returns
--- fresh rows rather than shared tables.
---
--- The memory and json backends keep whole Lua tables, so a field the MySQL
--- backend forgets to persist survives there for free and no test notices.
--- That is exactly how the stake owner, the pause marker and the queued
--- bailout were all silently dropped in the default configuration.

local Sim = { tables = {}, schema = {}, indexes = {} }

--- Read a CREATE TABLE the way MySQL does: `--` comments are not there,
--- and only a comma outside brackets ends a declaration.
local function parseSchema(sql)
    local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
    if not name then return end

    local columns, indexes, key = {}, { PRIMARY = true }, nil
    -- Up to the last bracket: the table options (the character set) follow.
    local body = sql:gsub('%-%-[^\n]*', ''):match('%((.*)%)[^)]*$') or ''
    local depth, part = 0, {}
    for ch in (body .. ','):gmatch('.') do
        if ch == ',' and depth == 0 then
            local line = table.concat(part)
            part = {}
            local column = line:match('^%s*([%w_]+)%s+[%w()]+')
            if column then
                local upper = column:upper()
                if upper == 'INDEX' or upper == 'KEY' then
                    indexes[line:match('^%s*[%w_]+%s+([%w_]+)')] = true
                elseif upper ~= 'PRIMARY' then
                    columns[column] = true
                    if line:upper():find('PRIMARY KEY', 1, true) then key = key or column end
                end
            end
        else
            if ch == '(' then depth = depth + 1 elseif ch == ')' then depth = depth - 1 end
            part[#part + 1] = ch
        end
    end

    Sim.schema[name] = columns
    Sim.indexes[name] = indexes
    Sim.keys[name] = key
    Sim.tables[name] = Sim.tables[name] or {}
    -- What the table is made with: what it declares after its last
    -- bracket, or else the database's own default, which on a txAdmin
    -- database is utf8mb3.
    Sim.collations[name] = sql:match('%)[^)]*COLLATE=([%w_]+)[^)]*$') or Sim.databaseCollation
    -- And on the engine it names, or the server's default, InnoDB.
    Sim.engines[name] = sql:match('%)[^)]*ENGINE=([%w_]+)[^)]*$') or 'InnoDB'
end

--- Extract the column list from an INSERT so we can check it against the
--- schema and against what the caller actually held.
local function parseInsert(sql)
    local table_ = sql:match('INSERT INTO ([%w_]+)')
    if not table_ then return nil end
    local list = sql:match('INSERT INTO [%w_]+%s*%(([^)]+)%)')
    if not list then return table_, {} end

    local columns = {}
    for column in list:gmatch('[%w_]+') do columns[#columns + 1] = column end
    return table_, columns
end

function Sim.reset()
    Sim.tables, Sim.schema, Sim.indexes, Sim.collations = {}, {}, {}, {}
    -- [table] = its primary key column: the one its CREATE TABLE declares,
    -- or for a table an older version (or another resource) left, the one
    -- existingSchema's fifth argument names.
    Sim.keys = {}
    Sim.existingKeys = nil
    -- [table] = engine, for the tables there are: made here, or left by an
    -- older version (existingSchema's fourth argument; InnoDB otherwise).
    Sim.engines = {}
    -- Statements this database user may not run: { CREATE = true, ALTER =
    -- true }. Refused as MySQL and MariaDB refuse them, error 1142, even for
    -- a table that is already there.
    Sim.denied = nil
    -- What CREATE TABLE gives a table that names no character set.
    Sim.databaseCollation = 'utf8mb3_general_ci'
    Sim.existingCollations = nil
    Sim.rejected = {}
    -- What a pre-existing database reports it has, which is the whole point
    -- of a migration: nil means the table is new and matches its
    -- declaration, a table here means it was created by an older version.
    Sim.existing = nil
    Sim.existingIndexes = nil
    Sim.altered = {}
end

--- Pretend the database already holds these tables, shaped as an older
--- version left them. Anything the current declarations add on top is what
--- a migration has to find.
---@param tables table [tableName] = { column = true }
---@param indexes table|nil [tableName] = { indexName = true }
---@param collations table|nil [tableName] = collation it was made with; a
--- table not named here answers nothing, as a query that failed would
---@param engines table|nil [tableName] = engine it was made on; InnoDB if
--- not named
---@param keys table|nil [tableName] = its primary key column; where not
--- named, the first of id, cid, setting_key and meta_key it has, which is
--- what every version of this resource's tables has had
function Sim.existingSchema(tables, indexes, collations, engines, keys)
    Sim.existing = tables
    Sim.existingIndexes = indexes or {}
    Sim.existingCollations = collations or {}
    Sim.existingKeys = keys or {}
    for name in pairs(tables or {}) do
        Sim.engines[name] = engines and engines[name] or 'InnoDB'
    end
end

--- The collation a table's text is in now, or nil when the test never said:
--- a text column given in a collation of its own wins over the table's.
function Sim.collationOf(table_)
    if Sim.existing and Sim.existing[table_] then
        for _, text in pairs(Sim.existing[table_]) do
            if type(text) == 'string' and text:find('_', 1, true) then return text end
        end
        return Sim.existingCollations and Sim.existingCollations[table_]
    end
    return Sim.collations[table_]
end

--- Parse an ALTER TABLE so a test can assert on what the migration did.
local function parseAlter(sql)
    local renamedIn, from, to = sql:match('^ALTER TABLE ([%w_]+) CHANGE COLUMN `([%w_]+)` ([%w_]+)')
    if renamedIn then return { table_ = renamedIn, from = from, to = to, sql = sql } end

    local movedIn, engine = sql:match('^ALTER TABLE ([%w_]+) ENGINE=([%w_]+)$')
    if movedIn then return { table_ = movedIn, engine = engine, sql = sql } end

    local convertedIn, charset, collation =
        sql:match('^ALTER TABLE ([%w_]+) CONVERT TO CHARACTER SET ([%w_]+) COLLATE ([%w_]+)')
    if convertedIn then
        return { table_ = convertedIn, charset = charset, collation = collation, sql = sql }
    end

    local table_, rest = sql:match('^ALTER TABLE ([%w_]+) ADD (.+)$')
    if not table_ then return nil end

    local column = rest:match('^COLUMN ([%w_]+)')
    if column then return { table_ = table_, column = column, sql = sql } end

    local index = rest:match('^INDEX ([%w_]+)')
    if index then return { table_ = table_, index = index, sql = sql } end

    return { table_ = table_, sql = sql }
end

--- Record any column an INSERT names that the schema does not declare.
function Sim.check(sql)
    local table_, columns = parseInsert(sql)
    if not table_ or not Sim.schema[table_] then return end
    for i = 1, #columns do
        if not Sim.schema[table_][columns[i]] then
            Sim.rejected[#Sim.rejected + 1] =
                ('%s.%s is written but not declared'):format(table_, columns[i])
        end
    end
end

--- Which fields of a record the schema can actually hold.
---@return table missing field names present on the record but not the schema
function Sim.missingColumns(tableName, record)
    local declared = Sim.schema[tableName]
    if not declared then return { 'no such table: ' .. tableName } end

    -- A field the backend keeps under another column name (RENAMED in
    -- mysql.lua), and hands back under its own (hydrateEscrow).
    local backend = package.loaded['crimson-hitman.server.storage.mysql']
    local renamed = backend and backend.RENAMED and backend.RENAMED[tableName] or {}

    local missing = {}
    for field, value in pairs(record) do
        if value ~= nil and not declared[renamed[field] or field] then
            missing[#missing + 1] = field
        end
    end
    table.sort(missing)
    return missing
end

function Sim.install(Natives)
    Sim.reset()

    local function run(sql, params)
        if type(sql) ~= 'string' then return {} end

        -- A statement that compares text across two tables in different
        -- collations, as every join between crimson tables does on their
        -- ids, is refused by MariaDB and MySQL alike.
        if not sql:find('information_schema', 1, true) and not sql:find('^%s*ALTER')
            and not sql:find('CREATE TABLE', 1, true) then
            local seen, first = {}, nil
            for table_ in sql:gmatch('crimson_[%w_]+') do
                if not seen[table_] then
                    seen[table_] = true
                    local collation = Sim.collationOf(table_)
                    if collation then
                        if first and collation ~= first then
                            error(('Illegal mix of collations (%s,IMPLICIT) and (%s,IMPLICIT) '
                                .. 'for operation \'=\' (1267)'):format(first, collation))
                        end
                        first = first or collation
                    end
                end
            end
        end

        -- A user without the privilege is refused before the database looks
        -- for the table, IF NOT EXISTS or not.
        local verb = sql:match('^%s*(%u+)')
        if Sim.denied and verb and Sim.denied[verb] then
            local target = sql:match('TABLE IF NOT EXISTS ([%w_]+)') or sql:match('TABLE ([%w_]+)')
            error(("%s command denied to user 'ch'@'localhost' for table `ch`.`%s` (1142)")
                :format(verb, tostring(target)), 0)
        end

        if sql:find('CREATE TABLE', 1, true) then
            -- IF NOT EXISTS: one already there is left exactly as it is.
            local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
            if not (name and (Sim.schema[name] or (Sim.existing and Sim.existing[name]))) then
                parseSchema(sql)
            end
        end
        if sql:find('INSERT INTO', 1, true) then Sim.check(sql) end

        -- The crimson tables there are, with each one's engine: the ones an
        -- older version left, and the ones made here.
        if sql:find('information_schema.TABLES', 1, true) and sql:find("LIKE 'crimson%'", 1, true) then
            local rows, seen = {}, {}
            for _, source in ipairs({ Sim.existing or {}, Sim.schema }) do
                for name in pairs(source) do
                    if not seen[name] then
                        seen[name] = true
                        rows[#rows + 1] = { TABLE_NAME = name, ENGINE = Sim.engines[name] or 'InnoDB' }
                    end
                end
            end
            return rows
        end

        -- What the database says it already has: the shape a test set up
        -- as left by an older version, or else what CREATE TABLE just made.
        -- Real MySQL never answers a table it has with nothing, and an empty
        -- answer here once hid a migration that could not start.
        if sql:find('information_schema.COLUMNS', 1, true) then
            local table_ = params and params[1]
            local held = Sim.existing and Sim.existing[table_] or Sim.schema[table_]
            if not held then return {} end
            local rows = {}
            -- A column a test gave as a string is a text column in that
            -- character set, or in that collation when the string names one
            -- (`utf8mb4_general_ci`). Like MySQL, a text column always
            -- reports a collation: the table's own, when it is in the
            -- table's character set.
            local own = Sim.existing and Sim.existing[table_]
                and Sim.existingCollations and Sim.existingCollations[table_]
                or Sim.collations[table_]
            for column, text in pairs(held) do
                local charset, collation
                if type(text) == 'string' then
                    charset = text:match('^([^_]+)')
                    if text:find('_', 1, true) then
                        collation = text
                    elseif own and own:match('^([^_]+)') == charset then
                        collation = own
                    else
                        collation = charset .. '_general_ci'
                    end
                end
                rows[#rows + 1] = { COLUMN_NAME = column, COLUMN_KEY = '',
                    CHARACTER_SET_NAME = charset, COLLATION_NAME = collation }
            end
            -- Which column is the table's primary key (COLUMN_KEY 'PRI').
            local key
            if Sim.existing and Sim.existing[table_] then
                key = Sim.existingKeys and Sim.existingKeys[table_]
                if not key then
                    for _, candidate in ipairs({ 'id', 'cid', 'setting_key', 'meta_key' }) do
                        if held[candidate] then
                            key = candidate
                            break
                        end
                    end
                end
            else
                key = Sim.keys[table_]
            end
            for _, row in ipairs(rows) do
                if row.COLUMN_NAME == key then row.COLUMN_KEY = 'PRI' end
            end
            return rows
        end

        -- A table's own default collation: for one an older version left,
        -- what the test said it was made with (or nothing); for one CREATE
        -- TABLE just made, what it declared.
        if sql:find('information_schema.TABLES', 1, true) then
            local table_ = params and params[1]
            local collation
            if Sim.existing and Sim.existing[table_] then
                collation = Sim.existingCollations and Sim.existingCollations[table_]
            else
                collation = Sim.collations[table_]
            end
            if not collation then return {} end
            return { { TABLE_COLLATION = collation } }
        end

        if sql:find('information_schema.STATISTICS', 1, true) then
            local table_ = params and params[1]
            local held = Sim.existing and Sim.existing[table_]
                and Sim.existingIndexes and Sim.existingIndexes[table_]
                or Sim.indexes[table_]
            if not held then return {} end
            local rows = {}
            for index in pairs(held) do rows[#rows + 1] = { INDEX_NAME = index } end
            return rows
        end

        if sql:find('^ALTER TABLE') then
            local change = parseAlter(sql)
            if change then
                Sim.altered[#Sim.altered + 1] = change
                -- Applied, so a second migration finds nothing to do.
                if change.column and Sim.existing and Sim.existing[change.table_] then
                    Sim.existing[change.table_][change.column] = true
                end
                if change.from and Sim.existing and Sim.existing[change.table_] then
                    Sim.existing[change.table_][change.from] = nil
                    Sim.existing[change.table_][change.to] = true
                end
                if change.collation then
                    if Sim.existing and Sim.existing[change.table_] then
                        Sim.existingCollations[change.table_] = change.collation
                        for column, charset in pairs(Sim.existing[change.table_]) do
                            if type(charset) == 'string' then
                                Sim.existing[change.table_][column] = change.charset
                            end
                        end
                    else
                        Sim.collations[change.table_] = change.collation
                    end
                end
                if change.index and Sim.existingIndexes
                    and Sim.existingIndexes[change.table_] then
                    Sim.existingIndexes[change.table_][change.index] = true
                end
                if change.engine then Sim.engines[change.table_] = change.engine end
            end
        end

        return {}
    end

    local method = Natives.mysqlMethod
    Natives.mysql.query = method({ await = function(sql, params) return run(sql, params) end })
    Natives.mysql.insert = method({ await = function(sql, params) run(sql, params) return 1 end })
    Natives.mysql.update = method({ await = function(sql, params) run(sql, params) return 1 end })
    Natives.mysql.scalar = method({ await = function(sql, params) run(sql, params) return 0 end })
end

return Sim
