--- An escrowed build starts (FiveM Asset Escrow).
---
--- Only the manifest's script loader decrypts an escrowed file;
--- LoadResourceFile hands back the encrypted bytes. server/boot.lua used to
--- read every module with LoadResourceFile and compile it with load(), so
--- an escrowed build could not start. Every module is a manifest script now,
--- whose first line hands its body to CrimsonBoot.define (server/boot.lua).
---
---   * a whole start, every .lua file sealed to LoadResourceFile, in a
---     process of its own (tests/harness/escrow_boot.lua)
---   * every module file is listed in the manifest once, defines exactly its
---     own path once, and is closed on its last line; boot.lua first and
---     main.lua last
---   * every module named anywhere (CrimsonBoot.require, requireShared, the
---     adapters by kind and name, the language files) is one the manifest
---     lists
---   * the client loads client/boot.lua before any shared file
---   * nothing in the resource compiles Lua it read itself

local Manifest = require('tests.harness.manifest')
local Modules = require('tests.harness.modules')

local ROOT = 'crimson-hitman/'

local function read(path)
    local handle = io.open(ROOT .. path, 'r')
    if not handle then return nil end
    local text = handle:read('a')
    handle:close()
    return text
end

local function luaFiles(dir)
    local out = {}
    local pipe = assert(io.popen('cd ' .. ROOT .. " && find " .. dir .. " -name '*.lua' -type f | sort"))
    for line in pipe:lines() do out[#out + 1] = line:gsub('^%./', '') end
    pipe:close()
    return out
end

--- The server's scripts, by file, with where each is in the list.
local function serverList()
    local list, at = Manifest.files('server_scripts'), {}
    for i, f in ipairs(list) do
        at[f] = at[f] or {}
        at[f][#at[f] + 1] = i
    end
    return list, at
end

describe('an escrowed build', function()
    it('starts, with every .lua file sealed to LoadResourceFile', function()
        local lua = (arg and arg[-1]) or 'lua5.4'
        local pipe = assert(io.popen(lua .. ' tests/harness/escrow_boot.lua 2>&1'))
        local said = pipe:read('a')
        local ok, how, code = pipe:close()
        truthy(said:find('escrow boot ok', 1, true), said)
        truthy(ok and how == 'exit' and code == 0, ('exit %s %s: %s'):format(tostring(how), tostring(code), said))
    end)
end)

describe('every module through the manifest', function()
    local list, at = serverList()

    it('lists the loader first and the start last', function()
        local own = {}
        for _, f in ipairs(list) do if f:sub(1, 1) ~= '@' then own[#own + 1] = f end end
        eq(own[1], 'server/boot.lua', 'boot.lua defines CrimsonBoot.define before any module')
        eq(own[#own], 'server/main.lua', 'main.lua asks for the modules, after every define')
    end)

    it('lists every module file once', function()
        for _, dir in ipairs({ 'server', 'shared' }) do
            for _, f in ipairs(luaFiles(dir)) do
                if Modules.nameOf(f) then
                    truthy(at[f], f .. ' is not in fxmanifest.lua server_scripts: an escrowed build cannot load it')
                    eq(at[f] and #at[f], 1, f .. ' is listed more than once')
                end
            end
        end
    end)

    it('has each listed module define its own path exactly once, closed on its last line', function()
        local checked = 0
        for _, f in ipairs(list) do
            local name = Modules.nameOf(f)
            if name then
                local src = read(f)
                local first = src:match('^[^\n]*')
                local opening = ("CrimsonBoot.define('%s', function() "):format(name)
                eq(first:sub(1, #opening), opening, f .. ' must start with ' .. opening)
                local count = 0
                for _ in src:gmatch('CrimsonBoot%.define%(') do count = count + 1 end
                eq(count, 1, f .. ' calls CrimsonBoot.define once')
                truthy(src:match('\nend%)\n?$'), f .. ' must end with end)')
                checked = checked + 1
            elseif f:match('^server/') or f:match('^shared/') then
                truthy(f == 'server/boot.lua' or f == 'server/main.lua',
                    f .. ' is listed but is not a module')
            end
        end
        truthy(checked > 100, 'the modules were found: ' .. checked)
    end)

    it('lists every module anything asks for, by literal name or by kind and name', function()
        local wanted = {}
        for _, dir in ipairs({ 'server', 'shared' }) do
            for _, f in ipairs(luaFiles(dir)) do
                local src = read(f)
                for name in src:gmatch("CrimsonBoot%.require%(%s*'([%w_%.%-]+)'") do wanted[name] = f end
                for name in src:gmatch("pcall%(CrimsonBoot%.require,%s*'([%w_%.%-]+)'") do wanted[name] = f end
                for name in src:gmatch("requireShared%(%s*'([%w_%-]+)'") do wanted['shared.' .. name] = f end
            end
        end
        -- The adapters, as server/adapters/init.lua builds the name.
        local Integrations = require('crimson-hitman.shared.integrations')
        local LIST = require('server.adapters.list')
        for _, spec in ipairs(Integrations.KINDS) do
            if spec.side ~= 'client' then
                for _, name in ipairs(LIST[spec.kind] or {}) do
                    wanted[('server.adapters.%s.%s'):format(spec.kind, name)] = 'server/adapters/list.lua'
                end
            end
        end
        local n = 0
        for name, by in pairs(wanted) do
            n = n + 1
            local file = name:gsub('%.', '/') .. '.lua'
            truthy(at[file] and Modules.nameOf(file) == name,
                ('%s asks for %s, which fxmanifest.lua does not list as a module'):format(by, name))
        end
        truthy(n > 100, 'the names were found: ' .. n)
    end)

    it('lists every language file for the server, as a plain script', function()
        for _, f in ipairs(luaFiles('locales')) do
            truthy(at[f], f .. ' is not in server_scripts: shared/locale.lua would never see it')
            falsy(read(f):find('CrimsonBoot', 1, true), f .. ' publishes its table; it is not a module')
        end
    end)

    it('loads client/boot.lua in the game before any shared file', function()
        local client = Manifest.files('client_scripts')
        local bootAt
        for i, f in ipairs(client) do
            if f == 'client/boot.lua' then bootAt = bootAt or i end
            if f:match('^shared/') then
                truthy(bootAt and bootAt < i, f .. ' runs before client/boot.lua defines CrimsonBoot.define')
            end
        end
        truthy(bootAt, 'client/boot.lua is a client script')
    end)

    it('compiles no Lua it read itself', function()
        -- What LoadResourceFile returns of an escrowed .lua file is sealed;
        -- loading code by name would also be a way in that the manifest does
        -- not list.
        for _, dir in ipairs({ 'server', 'shared', 'client', 'config', 'locales' }) do
            for _, f in ipairs(luaFiles(dir)) do
                local code = read(f):gsub('%-%-%[(=*)%[.-%]%1%]', ''):gsub('%-%-[^\n]*', '')
                    :gsub("'[^'\n]*'", "''"):gsub('"[^"\n]*"', '""')
                falsy(code:find('loadstring', 1, true) or code:find('dofile', 1, true)
                    or code:find('loadfile', 1, true), f .. ' loads Lua from a file')
                if code:find('[^%w_%.:]load%s*%(') and not code:find('local function load%s*%(') then
                    error(f .. ' calls load(): modules come through the manifest (CrimsonBoot.define)')
                end
            end
        end
        falsy(read('server/boot.lua'):gsub('%-%-[^\n]*', ''):find('LoadResourceFile', 1, true),
            'the loader reads no file')
    end)
end)
