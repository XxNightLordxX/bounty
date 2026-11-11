--- The config check (X3, server/configcheck.lua): /ch-diag config and the
--- panel's Health > Check the config. Every value out of range or invalid,
--- every script a switched-on feature needs and lacks, every staff ACE
--- group.admin does not hold, and every risky combination, each in plain
--- words with its fix; and "nothing to fix" when there is none.

--- The one the latest stack wired (newStack loads it afresh).
local ConfigCheck = setmetatable({}, { __index = function(_, k) return require('server.configcheck')[k] end })

local ALL_ACES = { 'crimson.admin', 'crimson.moderator', 'crimson.identity', 'crimson.developer', 'command' }

local function grantAll()
    local granted = {}
    for _, ace in ipairs(ALL_ACES) do granted[ace] = true end
    for _, name in pairs(Config.Admin.Commands) do granted['command.' .. name] = true end
    Env.principalAces['group.admin'] = granted
end

local function find(lines, text)
    for i, line in ipairs(lines) do
        if line:find(text, 1, true) then return line, lines[i + 1] end
    end
    return nil
end

local function run(name, src, ...)
    local said = {}
    local realPrint = _G.print
    _G.print = function(line) said[#said + 1] = tostring(line) end
    local ok, err = pcall(Env.commands[name], src, { ... })
    _G.print = realPrint
    if not ok then error(err, 0) end
    return table.concat(said, '\n')
end

--- A setup with nothing to report: a sound config with every risk off.
local function sound(s)
    grantAll()
    Config.Debug = false
    Config.Database.Mode = 'json'
    Config.Alerts.ToDiscord = false
    for _, st in ipairs(require('server.adapters.init').statusAll()) do
        if st.needed and not st.active and not st.required then Config.Integrations[st.key] = 'none' end
    end
    return s
end

describe('config check', function()
    it('says nothing to fix on a sound config, with every staff ACE held', function()
        local s = sound(newStack())
        local lines = ConfigCheck.lines()
        eq(lines[1], '--- crimson-hitman config check ---')
        eq(lines[#lines], '--- end ---')
        local findings = ConfigCheck.findings()
        local said = {}
        for _, f in ipairs(findings) do
            if f.kind ~= 'script' then said[#said + 1] = f.kind .. ': ' .. f.text end
        end
        eq(table.concat(said, ' | '), '', 'nothing but the scripts left none on purpose')
        local _ = s
    end)

    it('names a value the start-up checks refuse, with the setting to change', function()
        sound(newStack())
        Config.Limits.MaxAcceptedPerHitman = 'many'
        local found
        for _, f in ipairs(ConfigCheck.findings()) do
            if f.kind == 'setting' and f.text:find('MaxAcceptedPerHitman', 1, true) then found = f end
        end
        truthy(found, 'the bad value is named')
        truthy(found.fix:find('Config.Limits.MaxAcceptedPerHitman', 1, true), found.fix)
    end)

    it('names a script a switched-on feature needs and does not have, with what to do', function()
        sound(newStack())
        Config.Integrations.Dispatch = 'no-such-dispatch'
        Config.Advisory.Enabled, Config.Advisory.UseDispatch = true, true
        local found
        for _, f in ipairs(ConfigCheck.findings()) do
            if f.kind == 'script' and f.text:find('dispatch', 1, true) then found = f end
        end
        truthy(found, 'the dispatch script is named')
        truthy(found.fix:find("Config.Integrations.Dispatch to 'auto'", 1, true), found.fix)
    end)

    it('names every staff ACE group.admin does not hold, and the commands it may not run', function()
        sound(newStack())
        Env.principalAces = {}
        local lines = ConfigCheck.lines()
        for _, ace in ipairs({ 'crimson.admin', 'crimson.moderator', 'crimson.identity', 'crimson.developer' }) do
            local line, fix = find(lines, 'does not hold ' .. ace)
            truthy(line, ace)
            truthy(fix:find('add_ace group.admin ' .. ace .. ' allow', 1, true), fix)
        end
        local line, fix = find(lines, 'may not run')
        truthy(line and line:find('ch-diag', 1, true), tostring(line))
        truthy(fix:find('add_ace group.admin command allow', 1, true), fix)
    end)

    it('names the risky combinations, each with its fix', function()
        sound(newStack())
        Config.Debug = true
        Config.Database.Mode = 'memory'
        Config.Database.AllowModeSwitch = true
        Config.Admin.IdentityAce = Config.Admin.Ace
        Config.Alerts.ToDiscord = true
        Config.VersionCheck.Enabled, Config.VersionCheck.Url = true, ''
        local risky = {}
        for _, f in ipairs(ConfigCheck.findings()) do
            if f.kind == 'risky' then
                risky[#risky + 1] = f.text
                truthy(type(f.fix) == 'string' and #f.fix > 10, 'a fix for ' .. f.text)
            end
        end
        eq(#risky, 6, table.concat(risky, ' | '))
        local lines = ConfigCheck.lines()
        truthy(lines[#lines - 1]:find('thing(s) to look at', 1, true), lines[#lines - 1])
    end)

    it('runs as /ch-diag config, from the console, and changes nothing', function()
        local s = sound(newStack())
        fixture(s)
        Env.commands = {}
        s.bridges.installCommands(s)
        Config.Debug = true
        local before = Config.Debug
        local out = run('ch-diag', 0, 'config')
        truthy(out:find('crimson-hitman config check', 1, true), out)
        truthy(out:find('risky: Config.Debug is on', 1, true), out)
        truthy(out:find('-> fix: set Config.Debug = false', 1, true), out)
        falsy(out:find('crimson-hitman diagnosis', 1, true), 'the config check alone')
        eq(Config.Debug, before)
    end)

    it('runs from the panel\'s Health', function()
        local s = sound(newStack())
        fixture(s)
        Env.aces[1] = { ['crimson.admin'] = true }
        local reply = s.panel.handle(1, { op = 'diag', data = { config = true }, __rid = 1 })
        truthy(reply and reply.ok, reply and reply.message)
        eq(reply.data.lines[1], '--- crimson-hitman config check ---')
        local admin = read_file('crimson-hitman/ui/admin.js')
        truthy(admin:find("ask('diag', { config: true }", 1, true), 'Health asks for it')
    end)
end)
