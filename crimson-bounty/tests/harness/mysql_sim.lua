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
        if type(sql) == 'string' then
            if sql:find('CREATE TABLE', 1, true) then parseSchema(sql) end
            if sql:find('INSERT INTO', 1, true) then Sim.check(sql) end
        end
        return {}
    end

    Natives.mysql.query = { await = function(sql, params) return run(sql, params) end }
    Natives.mysql.insert = { await = function(sql, params) run(sql, params) return 1 end }
    Natives.mysql.update = { await = function(sql, params) run(sql, params) return 1 end }
    Natives.mysql.scalar = { await = function(sql, params) run(sql, params) return 0 end }
end

return Sim
