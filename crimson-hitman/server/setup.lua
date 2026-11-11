CrimsonBoot.define('server.setup', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                     crimson-hitman - server/setup.lua                     ║
    ║        The first-start setup: one screen, previewed, two clicks           ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The admin panel shows this to the first staff member who may change
--- settings, while no setup has been saved (Developer, First-start setup,
--- opens it again later). It shows, every value defaulting to what is in
--- force now:
---   * the storage mode (set in config.lua: a switch needs the old mode's
---     money settled and a restart, so it is shown with the line to write)
---   * each other script this resource works with, what was detected and
---     the adapter chosen (Config.Integrations), to override
---   * the ACE lines that grant the panel's permissions, and which the
---     staff member holds
---   * the panel's command name and a handful of key switches
--- Nothing changes until it is applied: the preview lists each change (from,
--- to) and each value the server would refuse; applying makes each change
--- through Settings.set, as the panel's own Save does (checked, kept, on the
--- audit log, in Change history with its Undo), and saves the setup as done
--- (crimson_rp_rows, kind 'setup'), even when nothing changed.

local Util = CrimsonBoot.requireShared('util')
local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t

local Setup = {}

Setup.STORE_KIND = 'setup'
Setup.ROW_ID = 'setup:done'

--- The key switches the screen offers, in its order, each a catalogue key.
--- One that is not in the catalogue (or read only) is left out.
Setup.SWITCHES = {
    'Completion.Fulfilment',
    'TargetClasses.default.AllowAnonymousPlacer',
    'TargetClasses.default.AllowAnonymousHitman',
    'Intel.Enabled',
    'Advisory.Enabled',
    'Organisation.Enabled',
    'Completion.KillPhotos',
    'Mugshot.Enabled',
    'Debug',
}

--- The panel's command name.
Setup.COMMAND = 'Admin.Commands.panel'

local deps = nil

---@param d table { settings, storage, audit }
function Setup.init(d)
    deps = d
end

--- The saved row, or nil (never saved, or the store did not answer).
local function savedRow()
    local Storage = deps and deps.storage
    if not (Storage and Storage.readRpRows) then return nil end
    local ok, rows = pcall(Storage.readRpRows, Setup.STORE_KIND)
    if not ok or type(rows) ~= 'table' then return nil end
    for _, row in ipairs(rows) do
        if row.id == Setup.ROW_ID then return row end
    end
    return nil
end

--- Whether a setup has been saved.
---@return boolean
function Setup.saved()
    return savedRow() ~= nil
end

--- Every key the screen may change: the switches, the command name and one
--- per kind of other script. [key] = true
local function editable()
    local out = {}
    for _, key in ipairs(Setup.SWITCHES) do out[key] = true end
    out[Setup.COMMAND] = true
    for _, spec in ipairs(Integrations.KINDS) do out['Integrations.' .. spec.key] = true end
    return out
end

--- One catalogue key as the screen shows it, or nil when it is not one it
--- may change.
local function rowOf(key)
    local Settings = deps.settings
    local entry = Settings.entry(key)
    if not entry or entry.readonly then return nil end
    return { key = key, label = entry.label or key, kind = entry.kind, choices = entry.choices,
             value = Settings.valueOf(key), about = entry.about }
end

--- What the screen shows.
---@param permissions table[]|nil the panel's ACE list for this staff member
---@return table
function Setup.view(permissions)
    local row = savedRow()
    local switches = {}
    for _, key in ipairs(Setup.SWITCHES) do switches[#switches + 1] = rowOf(key) end
    local integrations = {}
    for _, st in ipairs(Integrations.statusAll()) do
        local setting = rowOf('Integrations.' .. st.key)
        integrations[#integrations + 1] = {
            kind = st.kind, key = 'Integrations.' .. st.key, choice = st.choice, active = st.active,
            detected = st.detected, without = st.without, required = st.required,
            choices = setting and setting.choices or { st.choice },
        }
    end
    local aces = {}
    for _, p in ipairs(permissions or {}) do
        aces[#aces + 1] = { name = p.name, ace = p.ace, held = p.held == true,
                            line = (L('setup.add_ace_group_admin_allow')):format(tostring(p.ace)) }
    end
    local mode = tostring(Config.Database and Config.Database.Mode or 'mysql')
    return {
        saved = row ~= nil, savedAt = row and row.at or nil, savedBy = row and row.by or nil,
        storage = { mode = mode, choices = { 'mysql', 'json' },
                    line = ("Config.Database.Mode = '%s'"):format(mode) },
        integrations = integrations,
        aces = aces,
        command = rowOf(Setup.COMMAND),
        switches = switches,
    }
end

--- What applying these values would change, against the settings in force
--- now: { changes = { { key, label, from, to } }, refused = { { key, label, why } }, same = n }.
--- A key the screen does not offer is refused.
---@param values table [key] = value
---@return table
function Setup.preview(values)
    local Settings = deps.settings
    local allowed = editable()
    local keys = {}
    for key in pairs(type(values) == 'table' and values or {}) do
        if type(key) == 'string' then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local out = { changes = {}, refused = {}, same = 0 }
    for _, key in ipairs(keys) do
        local entry = allowed[key] and Settings.entry(key) or nil
        local label = entry and entry.label or key
        if not entry or entry.readonly then
            out.refused[#out.refused + 1] = { key = key, label = label, why = L('setup.not_one_the_setup_changes') }
        else
            local value, _, why = Settings.check(key, Util.copy(values[key]))
            if value == nil then
                out.refused[#out.refused + 1] = { key = key, label = label, why = tostring(why or 'refused') }
            elseif Settings.describe(Settings.valueOf(key)) == Settings.describe(value) then
                out.same = out.same + 1
            else
                out.changes[#out.changes + 1] = { key = key, label = label,
                    from = Settings.describe(Settings.valueOf(key)), to = Settings.describe(value), value = value }
            end
        end
    end
    return out
end

--- Apply: each change through Settings.set, then the setup saved as done
--- (whatever changed, even nothing). A value refused is left as it is and
--- said; the rest apply.
---@param values table
---@param staff string|nil
---@param actorCid string|nil
---@return boolean ok
---@return string|nil err
---@return table|string detail { applied = keys, refused = { { key, why } } } or the reason
function Setup.apply(values, staff, actorCid)
    local Storage = deps and deps.storage
    if not (Storage and Storage.writeRpRow) then return false, 'store_failed', L('setup.the_store_is_not_answering') end
    local preview = Setup.preview(values)
    local applied, refused = {}, {}
    for _, change in ipairs(preview.changes) do
        local ok, err, detail = deps.settings.set(change.key, change.value, staff, actorCid)
        if ok then
            applied[#applied + 1] = change.key
        else
            refused[#refused + 1] = { key = change.key, why = type(detail) == 'string' and detail or tostring(err) }
        end
    end
    for _, r in ipairs(preview.refused) do refused[#refused + 1] = { key = r.key, why = r.why } end
    local ok = pcall(Storage.writeRpRow, { id = Setup.ROW_ID, kind = Setup.STORE_KIND, by = staff, at = os.time() })
    pcall(deps.audit.staff, 'admin_setup_applied', actorCid, nil,
        { keys = applied, refused = #refused, by = staff, saved = ok or nil })
    if not ok then
        return false, 'store_failed', L('setup.the_changes_were_made_but_the')
    end
    return true, nil, { applied = applied, refused = refused }
end

return Setup
end)
