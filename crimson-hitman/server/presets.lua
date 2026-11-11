--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                    crimson-hitman - server/presets.lua                    ║
    ║          Named bundles of settings, previewed before they apply           ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- A preset is a name and a set of setting values: Strict, Relaxed and
--- Roleplay-heavy ship with the resource; Current is the server's own
--- values of every key a preset names, kept in the store (crimson_rp_rows,
--- kind 'settings_preset', in every backend) when staff save it, and saved
--- by itself just before any other preset is applied, so going back is one
--- more apply.
---
--- Staff also keep presets of their own (X5): a name and the settings
--- changed from the panel at the moment it is saved (every override in
--- force, Settings.active), in the same store (kind 'settings_preset', id
--- 'preset:own:<name>'), listed after the shipped ones, previewed and
--- applied the same way, and deleted with two clicks. Saving and deleting
--- one is on the audit log (admin_preset_saved, admin_preset_deleted).
---
--- Nothing changes until a preset is applied (rule 7). Its preview lists
--- every change it would make (from, to) and every value the server would
--- refuse (and why), read against the settings in force now. Applying one
--- is each change through Settings.set, as the panel's own Save is: each is
--- checked, kept, on the audit log as admin_setting_changed and in Change
--- history with its Undo; the apply itself is one more row,
--- admin_preset_applied, naming the preset and the keys it changed.

local Util = CrimsonBoot.requireShared('util')
local L = CrimsonBoot.requireShared('locale').t

local Presets = {}

Presets.STORE_KIND = 'settings_preset'
--- The one preset staff save (and every apply saves first).
Presets.CURRENT = 'Current'
--- Own presets: how many a server keeps, and the longest name.
Presets.OWN_MAX = 20
Presets.NAME_MAX = 32
--- The most a preset's values may take, encoded (the store's row is a TEXT
--- of 64 KB on mysql).
Presets.BYTES_MAX = 60000

--- The shipped presets, in the order the panel lists them. Each value is
--- what the panel's own Save would take for that key.
Presets.BUILT_IN = {
    {
        name = 'Strict',
        about = L('presets.fewer_contracts_at_once_longer_waits'),
        values = {
            ['Limits.MaxAcceptedPerHitman'] = 2,
            ['Limits.MaxActiveContractsPerTarget'] = 1,
            ['Limits.MaxContractsPerTargetPerDay'] = 2,
            ['Limits.TargetCooldownAfterResolveSeconds'] = 7200,
            ['Limits.MinContractReward'] = 5000,
            ['Roleplay.ReasonQuality.Enabled'] = true,
        },
    },
    {
        name = 'Relaxed',
        about = L('presets.more_contracts_at_once_short_waits'),
        values = {
            ['Limits.MaxAcceptedPerHitman'] = 5,
            ['Limits.MaxActiveContractsPerTarget'] = 3,
            ['Limits.MaxContractsPerTargetPerDay'] = 0,
            ['Limits.TargetCooldownAfterResolveSeconds'] = 900,
            ['Limits.MinContractReward'] = 500,
            ['Roleplay.ReasonQuality.Enabled'] = false,
        },
    },
    {
        name = 'Roleplay-heavy',
        about = L('presets.contracts_that_ask_for_roleplay_proof'),
        values = {
            ['Roleplay.ProofOfIntent.Enabled'] = true,
            ['Roleplay.WitnessHeat.Enabled'] = true,
            ['Roleplay.ReasonQuality.Enabled'] = true,
            ['Kidnap.MeetingPoint'] = true,
            ['Limits.DefaultDeadlineSeconds'] = 21600,
        },
    },
}

local deps = nil

---@param d table { settings, storage, audit }
function Presets.init(d)
    deps = d
end

--- Every key any shipped preset names, sorted: what Current keeps.
local function trackedKeys()
    local seen, out = {}, {}
    for _, preset in ipairs(Presets.BUILT_IN) do
        for key in pairs(preset.values) do
            if not seen[key] then seen[key] = true; out[#out + 1] = key end
        end
    end
    table.sort(out)
    return out
end

--- Every saved row (Current and the own presets), or nil when the store
--- did not answer.
local function readRows()
    local Storage = deps and deps.storage
    if not (Storage and Storage.readRpRows) then return nil end
    local ok, rows = pcall(Storage.readRpRows, Presets.STORE_KIND)
    if not ok or type(rows) ~= 'table' then return nil end
    return rows
end

--- The saved Current, or nil (never saved, or the store did not answer).
local function readCurrent()
    for _, row in ipairs(readRows() or {}) do
        if row.name == Presets.CURRENT and row.own ~= true and type(row.values) == 'table' then return row end
    end
    return nil
end

--- The own presets, by name, sorted.
local function readOwn()
    local out = {}
    for _, row in ipairs(readRows() or {}) do
        if row.own == true and type(row.name) == 'string' and type(row.values) == 'table' then
            out[#out + 1] = row
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

local function isBuiltIn(name)
    if tostring(name):lower() == Presets.CURRENT:lower() then return true end
    for _, preset in ipairs(Presets.BUILT_IN) do
        if preset.name:lower() == tostring(name):lower() then return true end
    end
    return false
end

--- A preset by name: a shipped one, the saved Current, or an own one.
local function find(name)
    for _, preset in ipairs(Presets.BUILT_IN) do
        if preset.name == name then return preset end
    end
    if name == Presets.CURRENT then
        local row = readCurrent()
        if row then
            return { name = Presets.CURRENT, values = row.values, at = row.at, by = row.by,
                     about = L('presets.the_values_these_settings_had_when') }
        end
    end
    for _, row in ipairs(readOwn()) do
        if row.name == name then
            return { name = row.name, values = row.values, at = row.at, by = row.by, own = true,
                     about = (L('presets.saved_by_the_settings_changed_from'))
                         :format(tostring(row.by or 'staff')) }
        end
    end
    return nil
end

--- What a preset would change now: each key's label, the value in force
--- and the one it would set, and the keys the server would refuse.
---@param preset table
---@return table { changes = { { key, label, from, to } }, refused = { { key, label, why } }, same = n }
local function previewOf(preset)
    local Settings = deps.settings
    local keys = {}
    for key in pairs(preset.values) do keys[#keys + 1] = key end
    table.sort(keys)
    local out = { changes = {}, refused = {}, same = 0 }
    for _, key in ipairs(keys) do
        local entry = Settings.entry(key)
        local label = entry and entry.label or key
        local value, _, why = Settings.check(key, Util.copy(preset.values[key]))
        if value == nil then
            out.refused[#out.refused + 1] = { key = key, label = label, why = tostring(why or 'refused') }
        else
            local now = Settings.valueOf(key)
            if Settings.describe(now) == Settings.describe(value) then
                out.same = out.same + 1
            else
                out.changes[#out.changes + 1] = { key = key, label = label,
                    from = Settings.describe(now), to = Settings.describe(value) }
            end
        end
    end
    return out
end

--- Every preset with its preview against the settings in force now.
---@return table[]
function Presets.list()
    local out = {}
    local function add(preset, builtIn)
        local p = previewOf(preset)
        out[#out + 1] = { name = preset.name, about = preset.about, builtIn = builtIn,
                          at = preset.at, changes = p.changes, refused = p.refused, same = p.same }
    end
    for _, preset in ipairs(Presets.BUILT_IN) do add(preset, true) end
    local current = find(Presets.CURRENT)
    if current then add(current, false) end
    for _, row in ipairs(readOwn()) do
        local preset = find(row.name)
        if preset then
            add(preset, false)
            out[#out].own, out[#out].by = true, preset.by
        end
    end
    return out
end

--- A name for an own preset, or nil and why: 1 to 32 letters, digits,
--- spaces, - _ and ', not a shipped one's.
---@param name any
---@return string|nil
---@return string|nil why
function Presets.ownName(name)
    if type(name) ~= 'string' then return nil, L('presets.name_the_preset') end
    name = name:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    if name == '' then return nil, L('presets.name_the_preset') end
    if #name > Presets.NAME_MAX then
        return nil, (L('presets.a_presets_name_is_at_most')):format(Presets.NAME_MAX)
    end
    if not name:match('^[%w][%w %-_\']*$') then
        return nil, L('presets.a_presets_name_takes_letters_digits')
    end
    if isBuiltIn(name) then return nil, (L('presets.is_a_shipped_presets_name_pick')):format(name) end
    return name
end

--- Save the settings changed from the panel now as an own preset, under a
--- name (one already saved under it is replaced).
---@param name any
---@param staff string|nil
---@param actorCid string|nil
---@return boolean ok
---@return string|nil err
---@return string message
function Presets.saveOwn(name, staff, actorCid)
    local Storage = deps and deps.storage
    if not (Storage and Storage.writeRpRow) then return false, 'store_failed', L('presets.the_store_would_not_take_it') end
    local clean, why = Presets.ownName(name)
    if not clean then return false, 'invalid_input', why end
    local rows = readRows()
    if not rows then return false, 'store_failed', L('presets.the_store_did_not_answer_nothing') end
    local own, replacing = readOwn(), false
    for _, row in ipairs(own) do if row.name == clean then replacing = true end end
    if not replacing and #own >= Presets.OWN_MAX then
        return false, 'limit_reached', (L('presets.this_server_keeps_presets_of_its'))
            :format(Presets.OWN_MAX)
    end
    local values, count = {}, 0
    for _, row in ipairs(deps.settings.active()) do
        local entry = row.applied and deps.settings.entry(row.key) or nil
        if entry and not entry.readonly and not deps.settings.secretKey(row.key) then
            values[row.key] = Util.copy(row.value)
            count = count + 1
        end
    end
    if count == 0 then
        return false, 'unchanged', L('presets.nothing_to_save_no_setting_is')
    end
    local okSize, encoded = pcall(json.encode, values)
    if not okSize or type(encoded) ~= 'string' or #encoded > Presets.BYTES_MAX then
        return false, 'invalid_value', L('presets.those_settings_are_too_many_to')
    end
    local ok = pcall(Storage.writeRpRow, { id = 'preset:own:' .. clean, kind = Presets.STORE_KIND,
        name = clean, values = values, own = true, by = staff, at = os.time() })
    if not ok then return false, 'store_failed', L('presets.the_store_would_not_take_it_2') end
    pcall(deps.audit.staff, 'admin_preset_saved', actorCid, nil,
        { preset = clean, own = true, keys = count, replaced = replacing or nil, by = staff })
    return true, nil, (L('presets.saved_holds_the_setting_changed_from'))
        :format(clean, count, count == 1 and '' or 's', replacing and L('presets.the_one_saved_under_that_name') or '')
end

--- The own presets as the settings export carries them (server/settingsio.lua):
--- { { name, values } }, by name.
---@return table[]
function Presets.ownList()
    local out = {}
    for _, row in ipairs(readOwn()) do out[#out + 1] = { name = row.name, values = Util.copy(row.values) } end
    return out
end

--- The keys of an imported preset's values that may be kept: catalogue
--- keys the panel may change, never a secret or one on the deny list, each
--- with a value the start-up checks take.
local function importValues(values)
    local out, count = {}, 0
    if type(values) ~= 'table' then return out, 0 end
    for key, value in pairs(values) do
        local entry = type(key) == 'string' and deps.settings.entry(key) or nil
        if entry and not entry.readonly and not deps.settings.secretKey(key)
            and not (deps.settings.DENY and deps.settings.DENY[key])
            and deps.settings.check(key, Util.copy(value)) ~= nil then
            out[key] = Util.copy(value)
            count = count + 1
        end
    end
    return out, count
end

--- Whether an imported preset would be added: a free own name, room, and
--- at least one value this server takes. nil and why when not.
---@param name any
---@param values any
---@return boolean ok
---@return string|nil why
function Presets.importable(name, values)
    local clean, why = Presets.ownName(name)
    if not clean then return false, why end
    for _, row in ipairs(readOwn()) do
        if row.name:lower() == clean:lower() then return false, L('presets.a_preset_of_that_name_is') end
    end
    if #readOwn() >= Presets.OWN_MAX then
        return false, (L('presets.this_server_keeps_presets_of_its_2')):format(Presets.OWN_MAX)
    end
    local _, count = importValues(values)
    if count == 0 then return false, L('presets.none_of_its_settings_is_one') end
    return true
end

--- Add an imported preset (Presets.importable said yes), with only the
--- values this server takes. Audited as a save is.
---@return boolean ok
function Presets.importOwn(name, values, staff, actorCid)
    local ok = Presets.importable(name, values)
    if not ok then return false end
    local clean = Presets.ownName(name)
    local kept, count = importValues(values)
    local wrote = pcall(deps.storage.writeRpRow, { id = 'preset:own:' .. clean, kind = Presets.STORE_KIND,
        name = clean, values = kept, own = true, by = staff, at = os.time() })
    if not wrote then return false end
    pcall(deps.audit.staff, 'admin_preset_saved', actorCid, nil,
        { preset = clean, own = true, keys = count, imported = true, by = staff })
    return true
end

--- Delete an own preset.
---@param name any
---@param staff string|nil
---@param actorCid string|nil
---@return boolean ok
---@return string|nil err
---@return string message
function Presets.deleteOwn(name, staff, actorCid)
    local Storage = deps and deps.storage
    local preset = type(name) == 'string' and find(name) or nil
    if not preset or not preset.own then
        return false, 'not_found', L('presets.there_is_no_preset_of_this')
    end
    if not (Storage and Storage.deleteRpRow) then return false, 'store_failed', L('presets.the_store_would_not_take_it') end
    local ok = pcall(Storage.deleteRpRow, 'preset:own:' .. preset.name)
    if not ok then return false, 'store_failed', L('presets.the_store_would_not_take_it_3') end
    pcall(deps.audit.staff, 'admin_preset_deleted', actorCid, nil, { preset = preset.name, by = staff })
    return true, nil, (L('presets.deleted_nothing_else_changed')):format(preset.name)
end

--- Keep the values in force now of every key a preset names, as Current.
---@param staff string|nil who, for the row
---@return boolean ok
---@return string|nil err
function Presets.saveCurrent(staff)
    local Storage = deps and deps.storage
    if not (Storage and Storage.writeRpRow) then return false, 'store_failed' end
    local values = {}
    for _, key in ipairs(trackedKeys()) do
        if deps.settings.entry(key) then values[key] = deps.settings.valueOf(key) end
    end
    local ok = pcall(Storage.writeRpRow, { id = 'preset:' .. Presets.CURRENT, kind = Presets.STORE_KIND,
        name = Presets.CURRENT, values = values, by = staff, at = os.time() })
    if not ok then return false, 'store_failed' end
    return true
end

--- Apply a preset: Current saved first (unless Current is the one
--- applied), then each change through Settings.set. A value the server
--- refuses is left as it is and said; the rest apply.
---@param name string
---@param staff string|nil
---@param actorCid string|nil
---@return boolean ok
---@return string|nil err
---@return table|string detail { applied = { keys }, refused = { { key, why } } } or the reason
function Presets.apply(name, staff, actorCid)
    local preset = type(name) == 'string' and find(name) or nil
    if not preset then return false, 'not_found', L('presets.there_is_no_preset_by_that') end
    local preview = previewOf(preset)
    if #preview.changes == 0 then
        return false, 'unchanged', (L('presets.nothing_to_change_the_settings_are')):format(preset.name)
    end
    if preset.name ~= Presets.CURRENT then
        local saved = Presets.saveCurrent(staff)
        if not saved then
            return false, 'store_failed', L('presets.current_could_not_be_saved_first')
        end
    end
    local applied, refused = {}, {}
    for _, change in ipairs(preview.changes) do
        local ok, err, detail = deps.settings.set(change.key, Util.copy(preset.values[change.key]), staff, actorCid)
        if ok then
            applied[#applied + 1] = change.key
        else
            refused[#refused + 1] = { key = change.key, why = type(detail) == 'string' and detail or tostring(err) }
        end
    end
    for _, r in ipairs(preview.refused) do refused[#refused + 1] = { key = r.key, why = r.why } end
    pcall(deps.audit.staff, 'admin_preset_applied', actorCid, nil,
        { preset = preset.name, keys = applied, refused = #refused, by = staff })
    return true, nil, { applied = applied, refused = refused }
end

return Presets
