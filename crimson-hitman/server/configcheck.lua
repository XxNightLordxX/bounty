--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/configcheck.lua                  ║
    ║       The config check: what is wrong or risky, each with its fix         ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- `/ch-diag config` (Admin.diagnose with 'config'), and Developer > Health
--- > Check the config in the admin panel. Reads only; changes nothing.
---
--- Five kinds of finding, each one line in plain words and a line with the
--- fix:
---   setting      a value out of range or invalid: what the start-up checks
---                said at this start (Log.view().problems, the values as
---                config.lua and the panel gave them), and what they say of
---                the settings in force now (Settings.configWarnings)
---   script       another script a switched-on feature needs and that does
---                not answer (Config.Integrations; Integrations.offLine)
---   permission   a staff ACE nobody in group.admin holds, or a staff command
---                group.admin may not run (IsPrincipalAceAllowed)
---   risky        a combination that works and is likely not meant
---                (RISKS below)
---
--- Nothing found reads "nothing to fix". The check is never on the
--- request path: it runs when staff ask for it.

local Log = CrimsonBoot.requireShared('log')
local Integrations = CrimsonBoot.require('server.adapters.init')

local ConfigCheck = {}

local Settings

---@param deps table { settings }
function ConfigCheck.init(deps)
    Settings = deps and deps.settings or nil
end

--- The setting a line names (Config.<key>), for its fix.
local function keyIn(line)
    return tostring(line):match('Config%.([%w_]+[%w_%.]*[%w_])')
end

local function settingFix(line)
    local key = keyIn(line)
    if key then
        return ('change Config.%s in config/config.lua, or in the admin panel (Settings: search %s)')
            :format(key, key)
    end
    return 'change the setting it names in config/config.lua, or in the admin panel\'s Settings'
end

--- The group every staff ACE is checked against: what the README's
--- Permissions section tells you to grant them to.
ConfigCheck.GROUP = 'group.admin'

--- A combination that works and is likely not meant: when(Config) says
--- whether it applies; text and fix are what is said.
ConfigCheck.RISKS = {
    { when = function(c) return c.Debug == true end,
      text = 'Config.Debug is on: the console prints every debug line, which is noisy on a live server',
      fix = 'set Config.Debug = false once the server is set up (the diagnosis still lists everything)' },
    { when = function(c) return type(c.Database) == 'table' and c.Database.Mode == 'memory' end,
      text = 'storage is \'memory\' (Config.Database.Mode): every contract and all escrowed money are lost '
          .. 'at a restart',
      fix = 'set Config.Database.Mode = \'mysql\' (or \'json\'); memory is for testing only' },
    { when = function(c) return type(c.Database) == 'table' and c.Database.AllowModeSwitch == true end,
      text = 'Config.Database.AllowModeSwitch is on: the next start opens a new storage mode even while the '
          .. 'old one still holds players\' money',
      fix = 'set it back to false once the switch is done and the old money settled' },
    { when = function(c)
          local a = type(c.Admin) == 'table' and c.Admin or {}
          return a.IdentityAce ~= nil and a.IdentityAce == a.Ace
      end,
      text = 'Config.Admin.IdentityAce is the same ACE as Config.Admin.Ace: everybody with the staff tools '
          .. 'can see who is behind an anonymous party',
      fix = 'give Config.Admin.IdentityAce a name of its own (crimson.identity as shipped) and grant it to '
          .. 'fewer people' },
    { when = function(c) return type(c.Admin) == 'table' and c.Admin.Enabled == false end,
      text = 'Config.Admin.Enabled is off: no staff command and no admin panel answers, so money left for '
          .. 'staff cannot be settled',
      fix = 'set Config.Admin.Enabled = true' },
    { when = function(c)
          local alerts = type(c.Alerts) == 'table' and c.Alerts or {}
          if alerts.ToDiscord ~= true then return false end
          -- The one reader of the webhook convars (server/discord.lua).
          return CrimsonBoot.require('server.discord').url('alerts') == nil
      end,
      text = 'Config.Alerts.ToDiscord is on and no webhook is set: alerts reach only the panel',
      fix = 'add  set crimson_hitman_alert_webhook "https://discord.com/api/webhooks/..."  to server.cfg '
          .. '(set, never setr), or turn Config.Alerts.ToDiscord off' },
    { when = function(c)
          local v = type(c.VersionCheck) == 'table' and c.VersionCheck or {}
          return v.Enabled == true and (type(v.Url) ~= 'string' or v.Url == '')
      end,
      text = 'Config.VersionCheck.Enabled is on with no Config.VersionCheck.Url: nothing is asked',
      fix = 'give the https:// address of the version file, or turn it off' },
}

--- Every finding, in order: { kind, text, fix }.
---@return table[]
function ConfigCheck.findings()
    local out, seen = {}, {}
    local function add(kind, text, fix)
        text = tostring(text):gsub('^warning: ', '')
        if seen[text] then return end
        seen[text] = true
        out[#out + 1] = { kind = kind, text = text, fix = fix }
    end

    -- Values: what this start found, and what the checks say now.
    local view = Log.view()
    for _, line in ipairs(view.problems or {}) do add('setting', line, settingFix(line)) end
    if Settings and Settings.configWarnings then
        local fatal, warn = Settings.configWarnings()
        for _, line in ipairs(fatal or {}) do add('setting', line, settingFix(line)) end
        for _, line in ipairs(warn or {}) do add('setting', line, settingFix(line)) end
    end

    -- Other scripts a feature that is on needs.
    for _, st in ipairs(Integrations.statusAll()) do
        local line = Integrations.offLine(st)
        if line and (st.needed or st.required) then
            local fix
            if not st.valid then
                fix = ('set Config.Integrations.%s to \'auto\' or one of: %s'):format(st.key,
                    table.concat(st.names, ', '))
            elseif st.choice == 'none' then
                fix = ('set Config.Integrations.%s = \'auto\' once you run one of: %s, or leave it if '
                    .. 'you mean it'):format(st.key, table.concat(st.names, ', '))
            else
                local names = {}
                for i = 1, #st.detected do names[i] = st.detected[i].resource end
                fix = ('install and start %s before crimson-hitman in server.cfg, or set '
                    .. 'Config.Integrations.%s = \'none\' to say you mean it')
                    :format(#names > 0 and table.concat(names, ' or ') or 'one', st.key)
            end
            add('script', line, fix)
        end
    end

    -- Permissions: each staff ACE held by somebody, and the commands.
    local admin = type(Config.Admin) == 'table' and Config.Admin or {}
    local function held(ace)
        local ok, yes = pcall(IsPrincipalAceAllowed, ConfigCheck.GROUP, ace)
        return ok and (yes == true or yes == 1)
    end
    for _, item in ipairs({
        { 'Ace', 'the staff tools and the panel' }, { 'ModeratorAce', 'freezing, suspending and voiding' },
        { 'IdentityAce', 'seeing who is behind an anonymous party' }, { 'DeveloperAce', 'the panel\'s Developer section' },
    }) do
        local ace = admin[item[1]]
        if type(ace) == 'string' and ace ~= '' and not held(ace) then
            add('permission', ('%s does not hold %s (Config.Admin.%s), for %s'):format(ConfigCheck.GROUP, ace,
                item[1], item[2]),
                ('add  add_ace %s %s allow  to server.cfg (README, Permissions), or to a group of its own '
                    .. 'if fewer people should have it'):format(ConfigCheck.GROUP, ace))
        end
    end
    local commands = type(admin.Commands) == 'table' and admin.Commands or {}
    local names = {}
    for _, name in pairs(commands) do if type(name) == 'string' then names[#names + 1] = name end end
    table.sort(names)
    local blocked = {}
    for _, name in ipairs(names) do
        if not held('command.' .. name) then blocked[#blocked + 1] = name end
    end
    if #blocked > 0 then
        add('permission', ('%s may not run %s (a restricted command needs command.<name>)')
            :format(ConfigCheck.GROUP, table.concat(blocked, ', ')),
            ('add  add_ace %s command allow  (FiveM\'s own default), or one add_ace %s command.<name> '
                .. 'allow for each'):format(ConfigCheck.GROUP, ConfigCheck.GROUP))
    end

    -- Risky combinations.
    for _, risk in ipairs(ConfigCheck.RISKS) do
        local ok, yes = pcall(risk.when, Config)
        if ok and yes then add('risky', risk.text, risk.fix) end
    end
    return out
end

--- The check as lines, for /ch-diag config and the panel.
---@return string[]
function ConfigCheck.lines()
    local found = ConfigCheck.findings()
    local out = { '--- crimson-hitman config check ---' }
    local words = { setting = 'setting', script = 'other script', permission = 'permission', risky = 'risky' }
    for _, f in ipairs(found) do
        out[#out + 1] = ('%s: %s'):format(words[f.kind] or f.kind, f.text)
        out[#out + 1] = '  -> fix: ' .. tostring(f.fix)
    end
    out[#out + 1] = #found == 0 and 'nothing to fix: every value is in range, every script a switched-on '
        .. 'feature needs answers, and group.admin holds every staff ACE'
        or ('%d thing(s) to look at'):format(#found)
    out[#out + 1] = '--- end ---'
    return out
end

return ConfigCheck
