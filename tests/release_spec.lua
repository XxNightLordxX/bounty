--- The release build (tools/release.lua), run as a server owner's copy is
--- made: into a folder of its own, then read back.
---
---   * every file fxmanifest.lua names (read by tests/harness/manifest.lua,
---     as FiveM reads it, not by the script's own reader) is in the release,
---     and so is every file escrow_ignore leaves readable;
---   * no test, developer document, tool, scratch file or anything the
---     server wrote is;
---   * the zip is named for the manifest's version and holds exactly the
---     release folder;
---   * every link in a shipped document lands on a shipped file;
---   * a manifest naming a file that is not there, and a shipped file
---     holding a webhook, stop the build with the reason.

local Manifest = require('tests.harness.manifest')

local function sh(command)
    local pipe = assert(io.popen(command .. ' 2>&1; echo "exit:$?"'))
    local out = pipe:read('a')
    pipe:close()
    local code = tonumber(out:match('exit:(%d+)%s*$'))
    return code, out:gsub('exit:%d+%s*$', '')
end

local function read(path)
    local handle = io.open(path, 'rb')
    if not handle then return nil end
    local data = handle:read('a')
    handle:close()
    return data
end

local function tempDir()
    local code, out = sh('mktemp -d')
    assert(code == 0, out)
    return (out:gsub('%s+$', ''))
end

local function filesUnder(root)
    local out, set = {}, {}
    local pipe = assert(io.popen('cd \'' .. root .. '\' && find . -type f | LC_ALL=C sort'))
    for line in pipe:lines() do
        local f = line:gsub('^%./', '')
        out[#out + 1] = f
        set[f] = true
    end
    pipe:close()
    return out, set
end

--- The names in a zip's central directory.
local function zipNames(path)
    local data = assert(read(path), path)
    local eocd = data:find('PK\5\6', #data - 65557 > 0 and #data - 65557 or 1, true)
    assert(eocd, 'no end of central directory')
    local count, _, offset = string.unpack('<I2I4I4', data, eocd + 10)
    local names, at = {}, offset + 1
    for _ = 1, count do
        assert(data:sub(at, at + 3) == 'PK\1\2', 'central directory entry')
        local nameLen, extraLen, commentLen = string.unpack('<I2I2I2', data, at + 28)
        names[#names + 1] = data:sub(at + 46, at + 45 + nameLen)
        at = at + 46 + nameLen + extraLen + commentLen
    end
    table.sort(names)
    return names
end

local version = read('crimson-hitman/fxmanifest.lua'):match("\nversion '([%d.]+)'")

describe('the release build', function()
    local out = tempDir()
    local code, log = sh('lua5.4 tools/release.lua --out \'' .. out .. '\'')
    local folder = out .. '/crimson-hitman'
    local files, have = filesUnder(folder)

    it('builds, and says what it made', function()
        eq(code, 0, log)
        truthy(log:find(('release %s: %d files'):format(version, #files), 1, true), log)
    end)

    it('holds every file the manifest names, and every file escrow_ignore leaves readable', function()
        local missing, named = {}, 0
        for key in pairs(Manifest.lists()) do
            for _, f in ipairs(Manifest.files(key)) do
                if f:sub(1, 1) ~= '@' then
                    named = named + 1
                    if not have[f] then missing[#missing + 1] = key .. ': ' .. f end
                end
            end
        end
        truthy(named > 100, named .. ' files named')
        for _, f in ipairs({ 'fxmanifest.lua', 'README.md', 'CHANGELOG.md', 'install/sql/crimson_hitman.sql',
                             'data/README.md', 'data/contracts/README.md', 'data/photos/README.md',
                             'server/adapters/TEMPLATE.lua', 'client/adapters/TEMPLATE.lua',
                             'docs/in-game-checklist.md', 'docs/configuration.md' }) do
            if not have[f] then missing[#missing + 1] = f end
        end
        eq(#missing, 0, 'not in the release: ' .. table.concat(missing, ', '))
    end)

    it('holds nothing a server does not run but the owner docs', function()
        local extra = {}
        for _, f in ipairs(files) do
            if f:match('^tests/') or f:match('^tools/') or f:match('^docs/dev/') or f:match('developer%.md$')
                or f:match('%.git') or f:match('zz_') or f:match('_probe')
                or (f:match('^data/') and not f:match('README%.md$'))
                or (f:match('^docs/') and not f:match('^docs/[%w_-]+%.md$')) then
                extra[#extra + 1] = f
            end
        end
        eq(#extra, 0, 'shipped and should not be: ' .. table.concat(extra, ', '))
    end)

    it('names the zip for the manifest\'s version, holding exactly the folder', function()
        local zip = ('%s/crimson-hitman-%s.zip'):format(out, version)
        truthy(read(zip), zip .. ' made')
        local inZip = zipNames(zip)
        local expected = {}
        for _, f in ipairs(files) do expected[#expected + 1] = 'crimson-hitman/' .. f end
        table.sort(expected)
        eq(table.concat(inZip, '\n'), table.concat(expected, '\n'))
        -- Stored as the folder holds it, byte for byte (a sample).
        local zipData = read(zip)
        truthy(zipData:find(read(folder .. '/fxmanifest.lua'), 1, true), 'the manifest stored whole')
    end)

    it('points every link in a shipped document at a shipped file', function()
        local broken, checked = {}, 0
        for _, f in ipairs(files) do
            if f:match('%.md$') then
                local text = read(folder .. '/' .. f):gsub('```.-```', ''):gsub('`[^`\n]*`', '')
                local base = f:match('^(.*)/') or '.'
                for target in text:gmatch('%]%(([^)#%s]+)[^)]*%)') do
                    if not target:match('^%a+:') then
                        checked = checked + 1
                        if not read(folder .. '/' .. base .. '/' .. target) then
                            broken[#broken + 1] = f .. ' -> ' .. target
                        end
                    end
                end
            end
        end
        truthy(checked > 10, checked .. ' links read')
        eq(#broken, 0, table.concat(broken, ', '))
    end)

    it('stops, naming the file, when the manifest names one that is not there', function()
        local copy = tempDir()
        assert(sh(('cp -R crimson-hitman \'%s/\' && rm \'%s/crimson-hitman/server/payout.lua\''):format(copy, copy)) == 0)
        -- And what a server wrote is never copied, even where it sits.
        local into = tempDir()
        local failed, says = sh(('lua5.4 tools/release.lua --resource \'%s/crimson-hitman\' --out \'%s\'')
            :format(copy, into))
        truthy(failed ~= 0, 'refused')
        truthy(says:find('server/payout.lua', 1, true), says)
        falsy(read(into .. '/crimson-hitman/fxmanifest.lua'), 'nothing written')
        sh(('rm -rf \'%s\' \'%s\''):format(copy, into))
    end)

    it('stops when a shipped file holds a webhook, and never copies what the server wrote', function()
        local copy = tempDir()
        assert(sh(('cp -R crimson-hitman \'%s/\''):format(copy)) == 0)
        local root = copy .. '/crimson-hitman'
        local store = assert(io.open(root .. '/data/store.json', 'w'))
        store:write('{}')
        store:close()
        local into = tempDir()
        local ok = sh(('lua5.4 tools/release.lua --resource \'%s\' --out \'%s\''):format(root, into))
        eq(ok, 0, 'a clean copy builds')
        falsy(read(into .. '/crimson-hitman/data/store.json'), 'the store stays behind')

        -- Built from parts, so no scanner reads this file as holding one.
        local hook = 'https://' .. 'discord' .. '.com/api/' .. 'webhooks/' .. '1234567890' .. '/notARealToken_x'
        local config = assert(io.open(root .. '/config/config.lua', 'a'))
        config:write('\n-- ' .. hook .. '\n')
        config:close()
        local failed, says = sh(('lua5.4 tools/release.lua --resource \'%s\' --out \'%s\''):format(root, into))
        truthy(failed ~= 0, 'refused')
        truthy(says:find('config/config.lua holds a Discord webhook', 1, true), says)
        sh(('rm -rf \'%s\' \'%s\''):format(copy, into))
    end)

    sh(('rm -rf \'%s\''):format(out))
end)
