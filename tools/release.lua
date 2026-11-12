--- The release build: a clean copy of the resource, and a zip of it.
---
---   lua5.4 tools/release.lua [--out dist] [--resource crimson-hitman] [--docs docs]
---
--- Run from the repository root. Writes <out>/crimson-hitman/ and
--- <out>/crimson-hitman-<version>.zip (<out> is dist/ unless given; dist/ is
--- git-ignored), holding only what the resource runs and its owner docs:
---
---   * every file fxmanifest.lua names (shared, client and server scripts,
---     files {}, ui_page), its globs expanded as FiveM expands them, and
---     every file escrow_ignore leaves readable (config, words, adapters and
---     their templates);
---   * fxmanifest.lua, README.md, CHANGELOG.md and a LICENSE if there is one;
---   * install/sql/ and the data/ folders' notes (the folders the json store
---     writes into must exist; nothing the server wrote there is copied);
---   * the owner docs, under docs/, with their links rewritten for where they
---     land and any link to a developer document left as plain text.
---
--- Nothing else: no tests, no docs/dev, no developer guide, no tools, no
--- .git, no store or photos the server wrote. It fails, naming the file,
--- when the manifest names a file that is not there, when a glob matches
--- nothing, when the manifest uses a directive this script does not know,
--- when CHANGELOG.md's newest version is not the manifest's, when a
--- scratch file would be shipped, and when a shipped file holds something
--- that reads as a secret (a Discord webhook, a password in a connection
--- string). docs/developer.md, "Release build", says how to run it.

local Release = {}

--- The owner docs, from the docs folder; shipped as docs/<name>.
Release.OWNER_DOCS = { 'in-game-checklist.md', 'how-it-works.md', 'features.md', 'admin-panel.md',
                       'configuration.md', 'running.md' }

--- Manifest directives that name files to ship, and those that do not.
local FILE_LISTS = { shared_scripts = true, shared_script = true, client_scripts = true, client_script = true,
                     server_scripts = true, server_script = true, files = true, file = true, ui_page = true,
                     escrow_ignore = true }
local META = { fx_version = true, game = true, lua54 = true, name = true, author = true, description = true,
               version = true, dependencies = true, dependency = true }

--- Never shipped, whatever names them: the probes .gitignore keeps out.
local SCRATCH = { '/zz_[^/]*$', '^zz_[^/]*$', '/_probe[^/]*$', '^_probe[^/]*$', '%.bak$', '~$', '%.DS_Store$',
                  '%.orig$', '%.rej$' }

--- What reads as a secret in a shipped file.
local SECRETS = {
    { 'discord%.com/api/webhooks/%d%d%d%d+/[%w_%-]+', 'a Discord webhook' },
    { 'discordapp%.com/api/webhooks/%d%d%d%d+/[%w_%-]+', 'a Discord webhook' },
    { 'mysql://[^%s:/@\'"]+:[^%s@\'"]+@', 'a database password in a connection string' },
    { '[Pp]assword=[^;%s\'"]+;', 'a database password in a connection string' },
    { 'ghp_[%w]{20,}', 'a GitHub token' },
}

local function fail(message)
    io.stderr:write('release: ', message, '\n')
    os.exit(1)
end

local function quote(path)
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function run(command)
    local ok = os.execute(command)
    if not ok then fail('command failed: ' .. command) end
end

local function readFile(path)
    local handle = io.open(path, 'rb')
    if not handle then return nil end
    local data = handle:read('a')
    handle:close()
    return data
end

local function writeFile(path, data)
    local handle = assert(io.open(path, 'wb'))
    handle:write(data)
    handle:close()
end

--------------------------------------------------------------------------
-- The manifest, as FiveM reads it
--------------------------------------------------------------------------

--- Every file under a folder, relative to it, sorted.
local function listFiles(root)
    local out = {}
    local pipe = assert(io.popen('cd ' .. quote(root) .. ' && find . -type f | LC_ALL=C sort'))
    for line in pipe:lines() do out[#out + 1] = (line:gsub('^%./', '')) end
    pipe:close()
    return out
end

--- A manifest glob as a Lua pattern: `*` within one folder, `**` across
--- folders (FiveM's ResourceMetaDataComponent::GlobValue).
local function globPattern(glob)
    local out = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')
    out = out:gsub('%*%*/', '\1'):gsub('%*%*', '\2'):gsub('%*', '[^/]*')
    out = out:gsub('\1', '.-'):gsub('\2', '.*')
    return '^' .. out .. '$'
end

--- The manifest's directives, in order: { { key, values } }.
function Release.readManifest(resource)
    local path = resource .. '/fxmanifest.lua'
    local chunk, err = loadfile(path, 't', setmetatable({}, { __index = function(_, key)
        return function(value)
            local values = type(value) == 'table' and value or { value }
            Release._directives[#Release._directives + 1] = { key = key, values = values }
            -- A directive written `key 'a' 'b'` (data_file) calls again.
            return function() fail(('%s: %s takes more than one value, which this script does not read')
                :format(path, key)) end
        end
    end }))
    if not chunk then fail('cannot read ' .. path .. ': ' .. tostring(err)) end
    Release._directives = {}
    chunk()
    return Release._directives
end

--- The files the manifest names, each once, and its version.
function Release.manifestFiles(resource)
    local every = listFiles(resource)
    local out, seen, version = {}, {}, nil
    for _, d in ipairs(Release.readManifest(resource)) do
        if FILE_LISTS[d.key] then
            for _, entry in ipairs(d.values) do
                if type(entry) ~= 'string' then fail(('fxmanifest.lua: %s holds a %s'):format(d.key, type(entry))) end
                if entry:sub(1, 1) ~= '@' then
                    local found = 0
                    local pattern = entry:find('*', 1, true) and globPattern(entry)
                    for _, f in ipairs(every) do
                        if (pattern and f:match(pattern)) or f == entry then
                            found = found + 1
                            if not seen[f] then seen[f] = true; out[#out + 1] = f end
                        end
                    end
                    if found == 0 then
                        fail(('fxmanifest.lua %s names %s, and %s'):format(d.key, entry,
                            pattern and 'that glob matches no file' or 'that file is not in the resource'))
                    end
                end
            end
        elseif d.key == 'version' then
            version = d.values[1]
        elseif not META[d.key] then
            fail(('fxmanifest.lua uses %s, which this script does not know: say in tools/release.lua '
                .. 'whether it names files to ship'):format(d.key))
        end
    end
    if type(version) ~= 'string' or not version:match('^%d+%.%d+%.%d+$') then
        fail('fxmanifest.lua has no version n.n.n')
    end
    return out, version
end

--------------------------------------------------------------------------
-- What ships
--------------------------------------------------------------------------

--- { { from = source path, to = path inside the release folder } }, sorted.
function Release.plan(resource, docs)
    local files, version = Release.manifestFiles(resource)
    local entries, seen = {}, {}
    local function add(from, to, required)
        if seen[to] then return end
        local handle = io.open(from, 'rb')
        if not handle then
            if required then fail(from .. ' is missing') end
            return
        end
        handle:close()
        seen[to] = true
        entries[#entries + 1] = { from = from, to = to }
    end
    for _, f in ipairs(files) do add(resource .. '/' .. f, f, true) end
    add(resource .. '/fxmanifest.lua', 'fxmanifest.lua', true)
    add(resource .. '/README.md', 'README.md', true)
    add(resource .. '/CHANGELOG.md', 'CHANGELOG.md', true)
    for _, name in ipairs({ 'LICENSE', 'LICENSE.md', 'LICENSE.txt' }) do
        add(resource .. '/' .. name, name, false)
        add(resource .. '/../' .. name, name, false)
    end
    for _, f in ipairs(listFiles(resource)) do
        if f:match('^install/sql/[^/]+%.sql$') or f:match('^data/.*README%.md$') then
            add(resource .. '/' .. f, f, true)
        end
    end
    for _, name in ipairs(Release.OWNER_DOCS) do add(docs .. '/' .. name, 'docs/' .. name, true) end
    for _, e in ipairs(entries) do
        for _, pattern in ipairs(SCRATCH) do
            if e.to:match(pattern) then fail(e.from .. ' is a scratch file and would be shipped') end
        end
    end
    table.sort(entries, function(a, b) return a.to < b.to end)

    local changelog = readFile(resource .. '/CHANGELOG.md') or ''
    local newest = changelog:match('\n## (%d+%.%d+%.%d+)')
    if newest ~= version then
        fail(('CHANGELOG.md\'s newest version is %s, the manifest\'s %s'):format(tostring(newest), version))
    end
    return entries, version
end

--------------------------------------------------------------------------
-- Links in the shipped documents
--------------------------------------------------------------------------

local function split(path)
    local parts = {}
    for part in path:gmatch('[^/]+') do
        if part == '..' and #parts > 0 and parts[#parts] ~= '..' then parts[#parts] = nil
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    return parts
end

local function dirOf(path)
    return path:match('^(.*)/') or '.'
end

--- `to` relative to the folder `fromDir`.
local function relative(fromDir, to)
    local a, b = split(fromDir), split(to)
    local i = 1
    while i <= #a and i <= #b and a[i] == b[i] do i = i + 1 end
    local parts = {}
    for _ = i, #a do parts[#parts + 1] = '..' end
    for j = i, #b do parts[#parts + 1] = b[j] end
    return #parts > 0 and table.concat(parts, '/') or '.'
end

--- A shipped markdown file's links, pointed at where their targets land;
--- a link to a document that is not shipped becomes its text.
function Release.relink(text, from, to, byFrom)
    return (text:gsub('%[([^%]\n]+)%]%(([^)%s]+)%)', function(label, target)
        if target:match('^%a+:') then return nil end
        local path, anchor = target:match('^([^#]*)(#?.*)$')
        if path == '' then return nil end
        local source = table.concat(split(dirOf(from) .. '/' .. path), '/')
        local landed = byFrom[source]
        if not landed then return label end
        return '[' .. label .. '](' .. relative(dirOf(to), landed) .. anchor .. ')'
    end))
end

--------------------------------------------------------------------------
-- The zip (stored, no compression; one fixed date, so a build is the same
-- bytes every time)
--------------------------------------------------------------------------

local CRC = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
    end
    CRC[i] = c
end

local function crc32(data)
    local c = 0xFFFFFFFF
    for i = 1, #data do c = CRC[(c ~ data:byte(i)) & 0xFF] ~ (c >> 8) end
    return c ~ 0xFFFFFFFF
end

function Release.zip(path, entries)
    local DOS_TIME, DOS_DATE = 0, (0 << 9) | (1 << 5) | 1 -- 1980-01-01 00:00
    local out, central, offset = {}, {}, 0
    for _, e in ipairs(entries) do
        local name, data = e.name, e.data
        if #data >= 0xFFFFFFFF or offset >= 0xFFFFFFFF then fail('the zip would need zip64') end
        local crc = crc32(data)
        local header = string.pack('<I4I2I2I2I2I2I4I4I4I2I2', 0x04034b50, 20, 0x0800, 0, DOS_TIME, DOS_DATE,
            crc, #data, #data, #name, 0) .. name
        out[#out + 1] = header
        out[#out + 1] = data
        central[#central + 1] = string.pack('<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4', 0x02014b50, 0x031E, 20,
            0x0800, 0, DOS_TIME, DOS_DATE, crc, #data, #data, #name, 0, 0, 0, 0, 0x81A40000, offset) .. name
        offset = offset + #header + #data
    end
    local dir = table.concat(central)
    if #entries >= 0xFFFF then fail('the zip would need zip64') end
    out[#out + 1] = dir
    out[#out + 1] = string.pack('<I4I2I2I2I2I4I4I2', 0x06054b50, 0, 0, #entries, #entries, #dir, offset, 0)
    writeFile(path, table.concat(out))
end

--------------------------------------------------------------------------
-- The build
--------------------------------------------------------------------------

function Release.build(opts)
    local resource, docs, outDir = opts.resource, opts.docs, opts.out
    local name = resource:match('([^/]+)/*$')
    for _, p in ipairs({ outDir, resource, docs }) do
        if p == '' or p == '.' or p == '/' then fail('refusing to use ' .. p) end
    end
    if table.concat(split(outDir), '/') == table.concat(split(resource), '/') then
        fail('the release cannot be written into the resource')
    end
    local entries, version = Release.plan(resource, docs)
    local folder = outDir .. '/' .. name
    local zipPath = ('%s/%s-%s.zip'):format(outDir, name, version)
    run('mkdir -p ' .. quote(outDir))
    run('rm -rf ' .. quote(folder))
    os.remove(zipPath)

    local byFrom = {}
    for _, e in ipairs(entries) do byFrom[table.concat(split(e.from), '/')] = e.to end
    local zipped, bytes, problems = {}, 0, {}
    for _, e in ipairs(entries) do
        local data = assert(readFile(e.from), e.from)
        if e.to:match('%.md$') then data = Release.relink(data, table.concat(split(e.from), '/'), e.to, byFrom) end
        for _, s in ipairs(SECRETS) do
            if data:find(s[1]) then problems[#problems + 1] = ('%s holds %s'):format(e.from, s[2]) end
        end
        local target = folder .. '/' .. e.to
        run('mkdir -p ' .. quote(dirOf(target)))
        writeFile(target, data)
        bytes = bytes + #data
        zipped[#zipped + 1] = { name = name .. '/' .. e.to, data = data }
    end
    if #problems > 0 then
        run('rm -rf ' .. quote(folder))
        fail('not shipped, it reads as a secret:\n  ' .. table.concat(problems, '\n  '))
    end
    Release.zip(zipPath, zipped)
    local zipBytes = #readFile(zipPath)
    return { folder = folder, zip = zipPath, version = version, files = #entries, bytes = bytes,
             zipBytes = zipBytes, entries = entries }
end

local function main(argv)
    local opts = { out = 'dist', resource = 'crimson-hitman', docs = 'docs' }
    local i = 1
    while i <= #argv do
        local flag, value = argv[i], argv[i + 1]
        local key = flag:match('^%-%-(%a+)$')
        if not key or opts[key] == nil or not value then
            fail('usage: lua5.4 tools/release.lua [--out dist] [--resource crimson-hitman] [--docs docs]')
        end
        opts[key] = value:gsub('/+$', '')
        i = i + 2
    end
    local r = Release.build(opts)
    print(('release %s: %d files, %d bytes, in %s'):format(r.version, r.files, r.bytes, r.folder))
    print(('zip: %s (%d bytes)'):format(r.zip, r.zipBytes))
end

if arg and arg[0] and arg[0]:match('release%.lua$') and not package.loaded['tools.release'] then
    main(arg)
end

return Release
