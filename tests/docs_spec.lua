--- The documents agree with the code (crimson-hitman/README.md, docs/*.md,
--- docs/dev/*.md):
---
---   * docs/configuration.md has a row for every setting in config.lua, in
---     its order, its shipped value exactly as config.lua ships it, and no
---     row for a setting that is gone;
---   * every refusal the server can send (CH.ERR) has words on the phone;
---   * every admin panel op (server/panel.lua OPS) is in the op table of
---     docs/dev/panel-requests.md, with no op there the server does not have;
---   * every feature with a switch has a line in the in-game checklist;
---   * the README is the owner's short README, its sections in order, with
---     no build history; every link and anchor in every document, every
---     docs/ path named in one and every file:line it cites exists.
---
--- CH_PRINT_DOCS=1 CH_SUITES=docs_spec lua5.4 tests/run.lua prints the
--- configuration reference as it should read, to paste over
--- docs/configuration.md after config.lua changes (docs/developer.md,
--- "Changing a setting").

local function file(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

local function exists(path)
    local handle = io.open(path, 'r')
    if handle then handle:close() end
    return handle ~= nil
end

local README = 'crimson-hitman/README.md'
local REFERENCE = 'docs/configuration.md'
local REQUESTS = 'docs/dev/panel-requests.md'
local CONFIG = 'crimson-hitman/config/config.lua'

--------------------------------------------------------------------------
-- The configuration reference, generated from config.lua
--------------------------------------------------------------------------

--- A shipped value as the reference shows it: strings quoted as in Lua,
--- numbers as Lua prints them, a list's first three entries and its count,
--- a record's fields by name.
local function render(value)
    if type(value) == 'string' then return "'" .. value .. "'" end
    if type(value) ~= 'table' then return tostring(value) end
    if next(value) == nil then return '{}' end
    if #value > 0 then
        local parts = {}
        for i = 1, math.min(#value, 3) do parts[i] = render(value[i]) end
        if #value > 3 then parts[#parts + 1] = ('… %d in all'):format(#value) end
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for i = 1, math.min(#keys, 4) do parts[i] = keys[i] .. ' = ' .. render(value[keys[i]]) end
    if #keys > 4 then parts[#parts + 1] = ('… %d in all'):format(#keys) end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

--- Tables shown whole on one row, as the README's coverage rule reads them
--- (config_layout_spec): sets and lists the owner edits as one thing.
local WHOLE_SECTIONS = { BlockedJobTypes = true, BlockedJobNames = true, EscrowBlacklist = true }
--- Sections whose entries are each one row: a reward source, a rate limit.
local CHILDREN_WHOLE = { Sources = true, Cooldowns = true }
local function whole(key)
    return key == 'Commands' or key == 'JailZone' or key == 'ParanoidAlertJitter' or key == 'AllowedMime'
        or key == 'MedicJobs' or key:find('Job') ~= nil
end

--- A record: string keys only, as config.lua writes a block of settings.
local function record(value)
    return type(value) == 'table' and next(value) ~= nil and #value == 0
end

--- config.lua read twice: run, for the values, and as text, for the order,
--- the section each setting is under, the section's prose and each
--- setting's note. Answers { sections = { { title, prose, rows = { { key,
--- value, note } } } } }.
local function reference()
    local text = file(CONFIG)
    local env = setmetatable({}, { __index = _G })
    assert(load(text, 'config.lua', 't', env))()
    local Config = env.Config

    -- Order and notes from the text: every `name =` with the path of the
    -- tables it is inside.
    local order, notes, sectionOf, sections = {}, {}, {}, {}
    local stack, current = {}, nil
    local lines = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local title = lines[i - 1] and lines[i - 1]:match('^%-%- ====') and line:match('^%-%-%s+([A-Z][A-Z :,]+)%s*$')
        if title and lines[i + 1] and lines[i + 1]:match('^%-%- ====') then
            current = { title = title, prose = {}, rows = {} }
            sections[#sections + 1] = current
            local j = i + 2
            while lines[j] and lines[j]:match('^%-%- ') do
                current.prose[#current.prose + 1] = lines[j]:sub(4)
                j = j + 1
            end
            i = j
        else
            local code, note = line, nil
            local at = line:find('%-%-')
            if at then
                -- A note is the comment after the code, not a '--' inside a string.
                local before = line:sub(1, at - 1)
                local _, quotes = before:gsub("'", '')
                if quotes % 2 == 0 then code, note = before, line:sub(at + 2):gsub('^%s+', '') end
            end
            local top, rest = code:match('^Config%.([%w_.]+)%s*=%s*(.-)%s*$')
            if top then
                stack = {}
                for part in top:gmatch('[^.]+') do stack[#stack + 1] = part end
                local path = table.concat(stack, '.')
                order[#order + 1] = path
                notes[path] = notes[path] or note
                sectionOf[path] = current
                if not (rest:match('^{') and not rest:match('}%s*,?%s*$')) then stack = {} end
            elseif #stack > 0 then
                local key, value = code:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
                if key then
                    local path = table.concat(stack, '.') .. '.' .. key
                    order[#order + 1] = path
                    notes[path] = notes[path] or note
                    sectionOf[path] = current
                    if value:match('^{') and not value:match('}%s*,?%s*$') then stack[#stack + 1] = key end
                elseif code:match('^%s*}') then
                    stack[#stack] = nil
                end
            end
            i = i + 1
        end
    end
    local rank = {}
    for n, path in ipairs(order) do rank[path] = rank[path] or n end

    local function get(path)
        local v = Config
        for part in path:gmatch('[^.]+') do v = v[part] end
        return v
    end

    -- The rows: a record is shown field by field, anything else whole.
    local rows = {}
    local function add(path)
        local value = get(path)
        local last = path:match('([%w_]+)$')
        local top = path:match('^([%w_]+)')
        local depth = select(2, path:gsub('%.', '')) + 1
        local recurse = record(value) and not WHOLE_SECTIONS[top] and not (depth > 1 and whole(last))
            and not (depth > 1 and CHILDREN_WHOLE[top])
        -- The roots of the optional features hold one block each.
        if recurse then
            local keys = {}
            for k in pairs(value) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b)
                local ra, rb = rank[path .. '.' .. a] or math.huge, rank[path .. '.' .. b] or math.huge
                if ra ~= rb then return ra < rb end
                return a < b
            end)
            for _, k in ipairs(keys) do add(path .. '.' .. k) end
            return
        end
        -- A field config.lua writes on its parent's line sorts with it.
        local at, parent = rank[path], path
        while not at and parent:find('%.') do
            parent = parent:match('^(.*)%.')
            at = rank[parent]
        end
        rows[#rows + 1] = { key = 'Config.' .. path, value = value, note = notes[path],
                            section = sectionOf[path] or sectionOf[parent] or sectionOf[top],
                            rank = (at or math.huge) + #rows / 1e6 }
    end
    local tops = {}
    for k in pairs(Config) do tops[#tops + 1] = k end
    table.sort(tops, function(a, b)
        local ra, rb = rank[a] or math.huge, rank[b] or math.huge
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    for _, k in ipairs(tops) do add(k) end
    for _, row in ipairs(rows) do
        local section = row.section or sections[#sections]
        section.rows[#section.rows + 1] = row
    end
    for _, section in ipairs(sections) do
        table.sort(section.rows, function(a, b) return a.rank < b.rank end)
    end
    return sections, rows
end

--- One row as the README writes it.
local function cells(row)
    return ('| `%s` | `%s` |'):format(row.key, render(row.value):gsub('|', '\\|'))
end

--- The whole reference, as markdown.
local function markdown()
    local sections = reference()
    local out = {}
    for _, s in ipairs(sections) do
        local title = s.title:lower():gsub('^%l', string.upper):gsub(': (%l)', function(c) return ': ' .. c:upper() end)
        out[#out + 1] = '## ' .. title
        out[#out + 1] = ''
        if #s.prose > 0 then
            out[#out + 1] = table.concat(s.prose, ' ')
            out[#out + 1] = ''
        end
        -- A section shown entry by entry is named whole too.
        local named, seen = {}, {}
        for _, row in ipairs(s.rows) do
            local top = row.key:match('^Config%.([%w_]+)%.')
            if top and CHILDREN_WHOLE[top] and not seen[top] then
                seen[top] = true
                named[#named + 1] = '`Config.' .. top .. '`'
            end
        end
        if #named > 0 then
            out[#out + 1] = table.concat(named, ', ') .. ': one row for each entry.'
            out[#out + 1] = ''
        end
        out[#out + 1] = '| Setting | Shipped | What it does |'
        out[#out + 1] = '|---|---|---|'
        for _, row in ipairs(s.rows) do
            out[#out + 1] = cells(row) .. ' ' .. ((row.note or ''):gsub('|', '\\|')) .. ' |'
        end
        out[#out + 1] = ''
    end
    return table.concat(out, '\n')
end

if os.getenv('CH_PRINT_DOCS') then io.write('\n', markdown(), '\n') end

--------------------------------------------------------------------------
-- The tests
--------------------------------------------------------------------------

--- Every document: the owner's README and CHANGELOG, the owner docs under
--- docs/, the developer docs under docs/dev/ and the data folders' notes.
local function documents()
    local out = { README, 'crimson-hitman/CHANGELOG.md', 'crimson-hitman/data/README.md',
                  'crimson-hitman/data/contracts/README.md', 'crimson-hitman/data/photos/README.md' }
    local pipe = assert(io.popen('ls docs/*.md docs/dev/*.md'))
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
    return out
end

--- A heading's anchor as GitHub makes it: lower case, punctuation dropped,
--- each space a hyphen.
local function slug(heading)
    return (heading:lower():gsub('`', ''):gsub('[^%w%- ]', ''):gsub(' ', '-'))
end

--- The anchors one document has.
local function anchors(text)
    local out = {}
    for heading in ('\n' .. text):gmatch('\n#+ ([^\n]+)') do out[slug(heading)] = true end
    return out
end

--- A path a document names, from the document's folder, `..` resolved.
local function resolve(doc, target)
    local parts = {}
    for part in ((doc:match('^(.*)/') or '.') .. '/' .. target):gmatch('[^/]+') do
        if part == '..' and #parts > 0 and parts[#parts] ~= '..' then parts[#parts] = nil
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    return table.concat(parts, '/')
end

describe('the owner README', function()
    it('has the owner README\'s sections, in order, and is short', function()
        local readme = file(README)
        local at = 0
        for _, title in ipairs({ 'What it is', 'Requirements', 'Install in 5 minutes', 'Main settings',
            'Admin panel and commands', 'Permissions', 'Updating', 'Escrow, and where the words live',
            'Troubleshooting', 'Documents' }) do
            local found = readme:find('\n## ' .. title .. '\n', at + 1, true)
            truthy(found, '## ' .. title .. ' after the section before it')
            at = found or at
        end
        local _, count = readme:gsub('\n', '')
        truthy(count < 320, count .. ' lines: the detail belongs in docs/')
    end)

    it('keeps build history out of the owner documents', function()
        -- The version history is CHANGELOG.md's; the owner docs say what is
        -- true now, not which step or sweep made it so.
        local found = {}
        for _, doc in ipairs({ README, 'docs/in-game-checklist.md', 'docs/how-it-works.md', 'docs/features.md',
                               'docs/admin-panel.md', 'docs/configuration.md', 'docs/running.md' }) do
            local text = file(doc)
            for _, word in ipairs({ "What's New", '%(step %d', '%(sweep', 'sweep %d', '%(X%d%)', '%(part %d' }) do
                if text:find(word) then found[#found + 1] = doc .. ': ' .. word end
            end
        end
        eq(#found, 0, 'build history in an owner document: ' .. table.concat(found, ', '))
    end)
end)

describe('the configuration reference and the request tables, against the code', function()
    it('gives every setting in config.lua its shipped value, exactly, in the reference', function()
        local reference_ = file(REFERENCE)
        local _, rows = reference()
        truthy(#rows > 300, #rows .. ' settings read from config.lua')
        local wrong, known = {}, {}
        for _, row in ipairs(rows) do
            known[row.key] = true
            if not reference_:find(cells(row), 1, true) then wrong[#wrong + 1] = cells(row) end
        end
        eq(#wrong, 0, 'rows missing or with a value config.lua does not ship:\n' .. table.concat(wrong, '\n'))
        -- And no row for a setting config.lua no longer has.
        local stale = {}
        for key in reference_:gmatch('\n| `(Config%.[%w_.]+)` |') do
            if not known[key] then stale[#stale + 1] = key end
        end
        eq(#stale, 0, 'rows for settings config.lua does not have: ' .. table.concat(stale, ', '))
    end)

    it('lists every admin panel op in its op table, and none the server does not have', function()
        local requests = file(REQUESTS)
        local panel = require('crimson-hitman.server.panel')
        local from = requests:find('\n## Panel requests', 1, true)
        truthy(from, 'the op table')
        local tableText = requests:sub(from, (requests:find('\n## ', from + 5, true) or #requests))
        local missing, listed = {}, {}
        for op in pairs(panel.OPS) do
            if not tableText:find('| `' .. op .. '` |', 1, true) then missing[#missing + 1] = op end
        end
        for op in tableText:gmatch('\n| `([%w_]+)` |') do listed[#listed + 1] = op end
        local extra = {}
        for _, op in ipairs(listed) do if panel.OPS[op] == nil then extra[#extra + 1] = op end end
        table.sort(missing)
        eq(#missing, 0, 'ops not in the table: ' .. table.concat(missing, ', '))
        eq(#extra, 0, 'ops in the table the server does not have: ' .. table.concat(extra, ', '))
    end)

    it('gives every refusal the server can send words on the phone', function()
        local codes = {}
        for name, value in pairs(CH.ERR) do codes[value] = name end
        -- The phone's words for them: locales/en.json, "errors" (ERRORS in ui/app.js).
        local json = file('crimson-hitman/locales/en.json')
        local map = json:match('"errors"%s*:%s*(%b{})') or ''
        local worded = {}
        for key in map:gmatch('[{,]%s*"([%w_]+)"%s*:') do worded[key] = true end
        local missing = {}
        for value, name in pairs(codes) do
            if not worded[value] then missing[#missing + 1] = value .. ' (CH.ERR.' .. name .. ')' end
        end
        table.sort(missing)
        truthy(next(codes) ~= nil, 'codes read')
        eq(#missing, 0, 'refusals with no words: ' .. table.concat(missing, ', '))
    end)


    it('links only to documents and headings that exist', function()
        local missing, checked = {}, 0
        for _, doc in ipairs(documents()) do
            -- Code is not a link: fenced blocks and `spans` taken out first.
            local text = file(doc):gsub('```.-```', ''):gsub('`[^`\n]*`', '')
            for target, anchor in text:gmatch('%]%(([^)#%s]*)#?([^)%s]*)%)') do
                if not target:match('^https?:') and not target:match('^mailto:') then
                    checked = checked + 1
                    local path = target == '' and doc or resolve(doc, target)
                    if not exists(path) then
                        missing[#missing + 1] = doc .. ' -> ' .. target
                    elseif anchor ~= '' and path:match('%.md$') and not anchors(file(path))[anchor] then
                        missing[#missing + 1] = doc .. ' -> ' .. target .. '#' .. anchor
                    end
                end
            end
        end
        truthy(checked > 20, checked .. ' links read')
        eq(#missing, 0, 'links to nothing: ' .. table.concat(missing, ', '))
        -- Merged into docs/developer.md, and named here by parts so the
        -- static check's cited-document rule does not read them as citations.
        for _, name in ipairs({ 'hitman-app-spec', 'implementation-plan', 'build-report', 'oxmysql',
            'improvements' }) do
            local gone = 'docs/' .. name .. '.md'
            falsy(exists(gone), gone .. ' is merged into docs/developer.md')
        end
    end)

    it('names only docs/ files that exist', function()
        local missing = {}
        for _, doc in ipairs(documents()) do
            for path in file(doc):gmatch('(docs/[%w_%-/]+%.md)') do
                if not exists(path) then missing[#missing + 1] = doc .. ' names ' .. path end
            end
        end
        eq(#missing, 0, table.concat(missing, ', '))
    end)

    it('cites only file:line places that exist', function()
        -- docs/dev/map.md is the map of the resource at b31d10a and cites
        -- its lines there, as its header says; every other document cites
        -- the files as they are now. A path is under crimson-hitman/ unless
        -- it starts with tests/ or docs/; one that is neither is another
        -- project's (oxmysql's, FiveM's) and not read here.
        local counts, bad, read = {}, {}, 0
        local function lineCount(path)
            if counts[path] == nil then
                local handle = io.open('crimson-hitman/' .. path, 'r') or io.open(path, 'r')
                if handle then
                    local n = 0
                    for _ in handle:lines() do n = n + 1 end
                    handle:close()
                    counts[path] = n
                else
                    counts[path] = false
                end
            end
            return counts[path]
        end
        for _, doc in ipairs(documents()) do
            if doc ~= 'docs/dev/map.md' then
                for path, from, to in file(doc):gmatch('([%w_./-]+%.%a+):(%d+)%-?(%d*)') do
                    local n = lineCount(path)
                    if n then
                        read = read + 1
                        if tonumber(from) > n or (to ~= '' and tonumber(to) > n) then
                            bad[#bad + 1] = ('%s cites %s:%s%s, which has %d lines'):format(doc, path, from,
                                to ~= '' and ('-' .. to) or '', n)
                        end
                    end
                end
            end
        end
        eq(#bad, 0, table.concat(bad, '\n'))
        truthy(file('docs/dev/map.md'):find('against `b31d10a`', 1, true), 'the map says which commit it cites')
    end)
end)


describe('the in-game checklist, against the code', function()
    it('has a line for every feature with a switch', function()
        local checklist = file('docs/in-game-checklist.md')
        local missing = {}
        local function look(path, value)
            if type(value) ~= 'table' then return end
            if type(value.Enabled) == 'boolean' then
                if not checklist:find('Config.' .. path, 1, true) then missing[#missing + 1] = 'Config.' .. path end
            end
            if path:find('%.') == nil then
                for k, v in pairs(value) do
                    if type(k) == 'string' then look(path .. '.' .. k, v) end
                end
            end
        end
        for k, v in pairs(Config) do look(k, v) end
        truthy(checklist:find('Config.Intel.Enabled', 1, true), 'the informants\' master switch')
        table.sort(missing)
        eq(#missing, 0, 'features with no checklist line: ' .. table.concat(missing, ', '))
    end)

    it('is one line per check, grouped by area', function()
        local checklist = file('docs/in-game-checklist.md')
        local continued = 0
        for line in checklist:gmatch('[^\n]+') do
            if line:match('^%s+%S') and not line:match('^%s*```') then continued = continued + 1 end
        end
        eq(continued, 0, 'checks wrapped over more than one line')
        local _, checks = checklist:gsub('\n%- %[ %] ', '')
        truthy(checks > 100, checks .. ' checks')
    end)
end)

describe('sale readiness (step 5b)', function()
    it('puts Install in 5 minutes after what it is and what it needs, numbered and short', function()
        local readme = file(README)
        local first = readme:find('\n## Install in 5 minutes\n\n1', 1, true)
        truthy(first, 'Install in 5 minutes, opening with its first step')
        truthy(first < readme:find('\n## Main settings\n', 1, true), 'before the settings')
        local section = readme:sub(first + 1, readme:find('\n## ', first + 5, true))
        local steps = 0
        for _ in section:gmatch('\n%d%. ') do steps = steps + 1 end
        truthy(steps >= 4 and steps <= 6, steps .. ' steps')
        truthy(section:find('First-start setup', 1, true) or section:find('first-start setup', 1, true))
    end)

    it('keeps a changelog, newest first, with version headings only', function()
        truthy(exists('crimson-hitman/CHANGELOG.md'), 'shipped with the resource')
        local text = file('crimson-hitman/CHANGELOG.md')
        local versions = {}
        for v in text:gmatch('\n## (%d+%.%d+%.%d+)') do versions[#versions + 1] = v end
        truthy(#versions >= 2)
        local manifest = file('crimson-hitman/fxmanifest.lua')
        eq(versions[1], manifest:match("\nversion '([%d.]+)'"), 'the newest is the version the manifest ships')
        for i = 2, #versions do truthy(versions[i - 1] > versions[i], 'newest first') end
    end)

    it('leaves every file a server owner edits out of escrow', function()
        local manifest = file('crimson-hitman/fxmanifest.lua')
        local block = manifest:match('escrow_ignore%s*(%b{})')
        truthy(block, 'escrow_ignore')
        for _, glob in ipairs({ 'config/*.lua', 'server/adapters/*.lua', 'server/adapters/*/*.lua',
                                 'client/adapters/*.lua', 'client/adapters/*/*.lua' }) do
            truthy(block:find("'" .. glob .. "'", 1, true), glob)
        end
        truthy(file(README):find('Escrow, and where the words live', 1, true), 'and where the words live')
    end)
end)

return { reference = reference, render = render, markdown = markdown }
