--- A MySQL simulator that behaves like a real database in the ways that
--- matter: it stores only the columns the schema declares, and it returns
--- fresh rows rather than shared tables.
---
--- The memory and json backends keep whole Lua tables, so a field the MySQL
--- backend forgets to persist survives there for free and no test notices.
--- That is exactly how the stake owner, the pause marker and the queued
--- bailout were all silently dropped in the default configuration.

local Sim = { tables = {}, schema = {} }

local function parseSchema(sql)
    local name = sql:match('CREATE TABLE IF NOT EXISTS ([%w_]+)')
    if not name then return end

    local columns = {}
    local body = sql:match('%((.*)%)%s*$')
    for line in (body or ''):gmatch('[^,\n]+') do
        local column = line:match('^%s*([%w_]+)%s+[%w()]+')
        if column then
            local upper = column:upper()
            if upper ~= 'INDEX' and upper ~= 'PRIMARY' and upper ~= 'KEY' then
                columns[column] = true
            end
        end
    end

    Sim.schema[name] = columns
    Sim.tables[name] = Sim.tables[name] or {}
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
    Sim.tables, Sim.schema = {}, {}
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
function Sim.existingSchema(tables, indexes)
    Sim.existing = tables
    Sim.existingIndexes = indexes or {}
end

--- Parse an ALTER TABLE so a test can assert on what the migration did.
local function parseAlter(sql)
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

    local missing = {}
    for field, value in pairs(record) do
        if value ~= nil and not declared[field] then
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

        if sql:find('CREATE TABLE', 1, true) then parseSchema(sql) end
        if sql:find('INSERT INTO', 1, true) then Sim.check(sql) end

        -- What the database says it already has. Only answered when a test
        -- has set up a pre-existing schema; otherwise the empty answer means
        -- "just created, nothing to migrate", which is the live behaviour
        -- for a fresh install.
        if sql:find('information_schema.COLUMNS', 1, true) then
            local held = Sim.existing and Sim.existing[params and params[1]]
            if not held then return {} end
            local rows = {}
            for column in pairs(held) do rows[#rows + 1] = { COLUMN_NAME = column } end
            return rows
        end

        if sql:find('information_schema.STATISTICS', 1, true) then
            local held = Sim.existingIndexes and Sim.existingIndexes[params and params[1]]
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
                if change.index and Sim.existingIndexes
                    and Sim.existingIndexes[change.table_] then
                    Sim.existingIndexes[change.table_][change.index] = true
                end
            end
        end

        return {}
    end

    Natives.mysql.query = { await = function(sql, params) return run(sql, params) end }
    Natives.mysql.insert = { await = function(sql, params) run(sql, params) return 1 end }
    Natives.mysql.update = { await = function(sql, params) run(sql, params) return 1 end }
    Natives.mysql.scalar = { await = function(sql, params) run(sql, params) return 0 end }
end

return Sim
