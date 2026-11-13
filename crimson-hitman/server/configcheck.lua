CrimsonBoot.define('server.configcheck', function() --[[
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
---   setting      a value out of range or invalid: what the checks say of
---                the settings in force now (Settings.configWarnings). Not
---                the console's problem lines (Log.view().problems): those
---                carry other scripts' error text, and are the Developer
---                console's, scrubbed there
---   script       another script a switched-on feature needs and that does
---                not answer (Config.Integrations; Integrations.offLine)
---   permission   a staff ACE nobody in group.admin holds, or a staff command
---                group.admin may not run (IsPrincipalAceAllowed)
---   risky        a combination that works and is likely not meant
---                (RISKS below)
---
--- Nothing found reads "nothing to fix". The check is never on the
--- request path: it runs when staff ask for it.

local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t

local ConfigCheck = {}

local Settings

--- What this start's own checks said of config.lua (main.lua's
--- validateConfig), kept for the findings: a value they put back is in
--- range in the settings in force, and only these still name it.
local startWarnings = {}

---@param deps table { settings }
function ConfigCheck.init(deps)
    Settings = deps and deps.settings or nil
end

--- Keep what this start's checks said (main.lua, once a start).
---@param warn string[]
function ConfigCheck.startSaid(warn)
    startWarnings = {}
    for i, line in ipairs(type(warn) == 'table' and warn or {}) do startWarnings[i] = tostring(line) end
end

--- The setting a line names (Config.<key>), for its fix.
local function keyIn(line)
    return tostring(line):match('Config%.([%w_]+[%w_%.]*[%w_])')
end

local function settingFix(line)
    local key = keyIn(line)
    if key then
        return (L('configcheck.change_config_in_config_config_lua'))
            :format(key, key)
    end
    return L('configcheck.change_the_setting_it_names_in')
end

--- The group every staff ACE is checked against: what the README's
--- Permissions section tells you to grant them to.
ConfigCheck.GROUP = 'group.admin'

--- A combination that works and is likely not meant: when(Config) says
--- whether it applies; text and fix are what is said.
ConfigCheck.RISKS = {
    { when = function(c) return c.Debug == true end,
      text = L('configcheck.config_debug_is_on_the_console'),
      fix = L('configcheck.set_config_debug_false_once_the') },
    { when = function(c) return type(c.Database) == 'table' and c.Database.Mode == 'memory' end,
      text = L('configcheck.storage_is_memory_config_database_mode'),
      fix = L('configcheck.set_config_database_mode_mysql_or') },
    { when = function(c) return type(c.Database) == 'table' and c.Database.AllowModeSwitch == true end,
      text = L('configcheck.config_database_allowmodeswitch_is_on_the'),
      fix = L('configcheck.set_it_back_to_false_once') },
    { when = function(c)
          local a = type(c.Admin) == 'table' and c.Admin or {}
          return a.IdentityAce ~= nil and a.IdentityAce == a.Ace
      end,
      text = L('configcheck.config_admin_identityace_is_the_same'),
      fix = L('configcheck.give_config_admin_identityace_a_name') },
    { when = function(c) return type(c.Admin) == 'table' and c.Admin.Enabled == false end,
      text = L('configcheck.config_admin_enabled_is_off_no'),
      fix = L('configcheck.set_config_admin_enabled_true') },
    { when = function(c)
          local alerts = type(c.Alerts) == 'table' and c.Alerts or {}
          if alerts.ToDiscord ~= true then return false end
          -- The one reader of the webhook convars (server/discord.lua).
          return CrimsonBoot.require('server.discord').url('alerts') == nil
      end,
      text = L('configcheck.config_alerts_todiscord_is_on_and'),
      fix = L('configcheck.add_set_crimson_hitman_alert_webhook') },
    { when = function(c)
          local v = type(c.VersionCheck) == 'table' and c.VersionCheck or {}
          return v.Enabled == true and (type(v.Url) ~= 'string' or v.Url == '')
      end,
      text = L('configcheck.config_versioncheck_enabled_is_on_with'),
      fix = L('configcheck.give_the_https_address_of_the') },
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

    -- Values: what the checks said of config.lua at this start, and what
    -- they say of the settings in force now (one line said by both, once).
    for _, line in ipairs(startWarnings) do add('setting', line, settingFix(line)) end
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
                fix = (L('configcheck.set_config_integrations_to_auto_or')):format(st.key,
                    table.concat(st.names, ', '))
            elseif st.choice == 'none' then
                fix = (L('configcheck.set_config_integrations_auto_once_you')):format(st.key, table.concat(st.names, ', '))
            else
                -- Only the script the setting names, when it names one: a
                -- started script beside it is offered, by name, rather than
                -- told to be installed.
                local names, started, startedResource = Integrations.notStarted(st)
                if started then
                    fix = (L('configcheck.set_config_integrations_to_the_started'))
                        :format(st.key, tostring(st.choice), startedResource, st.key, started)
                elseif #names > 0 then
                    fix = (L('configcheck.install_and_start_before_crimson_hitman'))
                        :format(table.concat(names, ' or '), st.key)
                else
                    fix = (L('configcheck.install_one_and_start_it_before'))
                        :format(table.concat(st.names or {}, ', '), st.key)
                end
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
        { 'Ace', L('configcheck.the_staff_tools_and_the_panel') }, { 'ModeratorAce', L('configcheck.freezing_suspending_and_voiding') },
        { 'IdentityAce', L('configcheck.seeing_who_is_behind_an_anonymous') }, { 'DeveloperAce', L('configcheck.the_panels_developer_section') },
    }) do
        local ace = admin[item[1]]
        if type(ace) == 'string' and ace ~= '' and not held(ace) then
            add('permission', (L('configcheck.does_not_hold_config_admin_for')):format(ConfigCheck.GROUP, ace,
                item[1], item[2]),
                (L('configcheck.add_add_ace_allow_to_server')):format(ConfigCheck.GROUP, ace))
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
        add('permission', (L('configcheck.may_not_run_a_restricted_command'))
            :format(ConfigCheck.GROUP, table.concat(blocked, ', ')),
            (L('configcheck.add_add_ace_command_allow_fivems')):format(ConfigCheck.GROUP, ConfigCheck.GROUP))
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
    local out = { L('configcheck.crimson_hitman_config_check') }
    local words = { setting = L('configcheck.kind_setting'), script = L('configcheck.other_script'),
        permission = L('configcheck.kind_permission'), risky = L('configcheck.kind_risky') }
    for _, f in ipairs(found) do
        out[#out + 1] = (L('configcheck.finding_line')):format(words[f.kind] or f.kind, f.text)
        out[#out + 1] = (L('configcheck.fix_line')):format(tostring(f.fix))
    end
    out[#out + 1] = #found == 0 and L('configcheck.nothing_to_fix_every_value_is')
        or (L('configcheck.thing_to_look_at')):format(#found)
    out[#out + 1] = '--- end ---'
    return out
end

return ConfigCheck
end)
