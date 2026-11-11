--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/settingsio.lua                  ║
    ║      Settings export and import: one JSON text, previewed, then applied   ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The admin panel's Developer > Export and import.
---
--- Export: one JSON text holding every setting changed from the panel (the
--- overrides in force, Settings.active; never a secret, never a key the
--- panel may not change) and this server's own presets (server/presets.lua,
--- X5), with this resource's version. Not in it: the map places
--- (Locations), which are positions on this server's map, and the target
--- limits staff set for a job or a player (Target limits), which are about
--- this server's jobs and characters; README, Settings export and import.
---
--- Import: the text is read and checked against the settings in force, and
--- nothing changes. The preview lists every change (from, to), every key it
--- refuses (a key on the deny list, one this version does not have, one
--- read-only, a value the start-up checks refuse) and why, and the presets
--- it would add. Applying it is each change through Settings.set, as the
--- panel's Save is: checked, kept, audited as admin_setting_changed and in
--- Change history with its Undo; then the presets; then one row,
--- admin_settings_imported. The server reads the text again for the apply,
--- and refuses it when the changes are no longer the ones previewed.

local Util = CrimsonBoot.requireShared('util')
local L = CrimsonBoot.requireShared('locale').t

local SettingsIO = {}

--- What the text says it is, and the largest text read.
SettingsIO.FORMAT = 'crimson-hitman-settings'
SettingsIO.VERSION = 1
SettingsIO.BYTES_MAX = 200000

local deps

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

---@param d table { settings, presets, audit }
function SettingsIO.init(d)
    deps = d
end

local function resourceVersion()
    local ok, version = pcall(GetResourceMetadata, GetCurrentResourceName(), 'version', 0)
    return ok and type(version) == 'string' and version or nil
end

--- The export, as a table and as its JSON text.
---@return table data { text, settings = n, presets = n }
function SettingsIO.export()
    local Settings = deps.settings
    local settings, count = {}, 0
    for _, row in ipairs(Settings.active()) do
        local entry = row.applied and Settings.entry(row.key) or nil
        if entry and not entry.readonly and not Settings.secretKey(row.key) then
            settings[row.key] = Util.copy(row.value)
            count = count + 1
        end
    end
    local presets = deps.presets and deps.presets.ownList and deps.presets.ownList() or {}
    local body = { format = SettingsIO.FORMAT, version = SettingsIO.VERSION, resource = resourceVersion(),
                   exported = os.time(), settings = settings, presets = presets }
    return { text = json.encode(body), settings = count, presets = #presets }
end

--- Read a text: the table it holds, or nil and why.
local function decode(text)
    if type(text) ~= 'string' or text == '' then return nil, L('settingsio.paste_the_exported_text_first') end
    if #text > SettingsIO.BYTES_MAX then
        return nil, (L('settingsio.that_text_is_longer_than_kb'))
            :format(SettingsIO.BYTES_MAX // 1000)
    end
    local ok, body = pcall(json.decode, text)
    if not ok or type(body) ~= 'table' then return nil, L('settingsio.that_text_is_not_json_copy') end
    if body.format ~= SettingsIO.FORMAT then
        return nil, L('settingsio.that_text_is_not_a_settings')
    end
    if tonumber(body.version) ~= SettingsIO.VERSION then
        return nil, L('settingsio.that_export_is_from_a_version')
    end
    if body.settings ~= nil and type(body.settings) ~= 'table' then return nil, L('settingsio.its_settings_are_not_a_list') end
    if body.presets ~= nil and type(body.presets) ~= 'table' then return nil, L('settingsio.its_presets_are_not_a_list') end
    return body
end

--- What a text would change now. nil and why when it cannot be read.
---@param text any
---@return table|nil { changes = { { key, label, from, to } }, refused = { { key, label, why } }, same = n,
--- presets = { { name, keys, why } }, resource }
---@return string|nil why
function SettingsIO.preview(text)
    local body, why = decode(text)
    if not body then return nil, why end
    local Settings = deps.settings
    local keys = {}
    for key in pairs(body.settings or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = { changes = {}, refused = {}, same = 0, presets = {}, resource = body.resource,
                  values = {} }
    for _, key in ipairs(keys) do
        local raw = body.settings[key]
        local entry = type(key) == 'string' and Settings.entry(key) or nil
        local label = entry and entry.label or tostring(key)
        local deny = type(key) == 'string' and Settings.DENY and Settings.DENY[key] or nil
        if type(key) ~= 'string' or Settings.secretKey(key) then
            out.refused[#out.refused + 1] = { key = tostring(key), label = label,
                why = L('settingsio.a_secret_never_imported') }
        elseif deny then
            out.refused[#out.refused + 1] = { key = key, label = deny.label or label,
                why = L('settingsio.never_changed_from_the_panel') .. tostring(deny.why) }
        elseif not entry then
            out.refused[#out.refused + 1] = { key = key, label = label,
                why = L('settingsio.not_a_setting_this_version_has') }
        elseif entry.readonly then
            out.refused[#out.refused + 1] = { key = key, label = label, why = tostring(entry.readonly) }
        else
            local value, _, refusal = Settings.check(key, Util.copy(raw))
            if value == nil then
                out.refused[#out.refused + 1] = { key = key, label = label, why = tostring(refusal or 'refused') }
            elseif Settings.describe(Settings.valueOf(key)) == Settings.describe(value) then
                out.same = out.same + 1
            else
                out.changes[#out.changes + 1] = { key = key, label = label,
                    from = Settings.describe(Settings.valueOf(key)), to = Settings.describe(value) }
                out.values[key] = raw
            end
        end
    end
    for _, preset in ipairs(type(body.presets) == 'table' and body.presets or {}) do
        local name = type(preset) == 'table' and preset.name or nil
        local values = type(preset) == 'table' and preset.values or nil
        local ok, refusal = false, L('settingsio.it_has_no_settings')
        if deps.presets and deps.presets.importable then
            ok, refusal = deps.presets.importable(name, values)
        end
        out.presets[#out.presets + 1] = { name = tostring(name), keys = type(values) == 'table'
            and count(values) or 0, why = not ok and refusal or nil }
    end
    return out
end

--- Apply a text: each change through Settings.set, then the presets. Refused,
--- with nothing changed, when the changes are not the `expect` previewed.
---@param text any
---@param expect any the number of changes the preview showed
---@param staff string|nil
---@param actorCid string|nil
---@return boolean ok
---@return string|nil err
---@return string message
---@return table|nil detail { applied, refused, presets }
function SettingsIO.apply(text, expect, staff, actorCid)
    local preview, why = SettingsIO.preview(text)
    if not preview then return false, 'invalid_input', why end
    local addable = 0
    for _, p in ipairs(preview.presets) do if not p.why then addable = addable + 1 end end
    if tonumber(expect) ~= #preview.changes then
        return false, 'invalid_value', L('settingsio.the_settings_changed_since_the_preview')
    end
    if #preview.changes == 0 and addable == 0 then
        return false, 'unchanged', L('settingsio.nothing_to_change_the_settings_are')
    end
    local applied, refused = {}, {}
    for _, change in ipairs(preview.changes) do
        local ok, err, detail = deps.settings.set(change.key, Util.copy(preview.values[change.key]), staff, actorCid)
        if ok then
            applied[#applied + 1] = change.key
        else
            refused[#refused + 1] = { key = change.key, why = type(detail) == 'string' and detail or tostring(err) }
        end
    end
    local body = decode(text)
    local added = {}
    for _, p in ipairs(preview.presets) do
        if not p.why and deps.presets and deps.presets.importOwn then
            for _, preset in ipairs(body.presets or {}) do
                if type(preset) == 'table' and preset.name == p.name then
                    local ok = deps.presets.importOwn(preset.name, preset.values, staff, actorCid)
                    if ok then added[#added + 1] = p.name end
                end
            end
        end
    end
    pcall(deps.audit.staff, 'admin_settings_imported', actorCid, nil,
        { keys = applied, refused = #refused + #preview.refused, presets = added, by = staff })
    return true, nil, (L('settingsio.imported_setting_changed_each_is_in'))
        :format(#applied, #applied == 1 and '' or 's',
            #refused > 0 and (', ' .. #refused .. ' refused') or '',
            #added > 0 and ('; ' .. #added .. ' preset' .. (#added == 1 and '' or 's') .. ' added') or ''),
        { applied = applied, refused = refused, presets = added }
end

return SettingsIO
