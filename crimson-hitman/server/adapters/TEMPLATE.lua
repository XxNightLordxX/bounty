CrimsonBoot.define('server.adapters.dispatch.my-dispatch', function() --[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║               crimson-hitman - server/adapters/TEMPLATE.lua               ║
    ║            A server adapter of your own: copy, rename, fill in            ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- How to use this file (docs/dev/adapters.md, "Adding your own"):
---   1. Copy it to server/adapters/<kind>/<your-resource>.lua, for example
---      server/adapters/dispatch/my-dispatch.lua.
---   2. Write each function the kind needs (the list is in the shipped
---      adapter of the kind, and in docs/dev/adapters.md), calling your
---      script the way ITS documentation says. Never guess an export.
---   3. Change the name on the first line to the copy's own path, dots for
---      slashes and no .lua: 'server.adapters.dispatch.my-dispatch'. The
---      manifest loads every file in server/adapters/<kind>/, and the loader
---      finds the adapter by that name.
---   4. Add '<your-resource>' to server/adapters/list.lua under the kind.
---   5. Set Config.Integrations.<Kind> = '<your-resource>' (or leave 'auto').
--- This file itself is never loaded: only the names in list.lua are.
---
--- The example below is a dispatch adapter. Every function may raise; the
--- callers keep their pcall, and a raise turns the call into "not filed",
--- said once a minute in the console.

local L = CrimsonBoot.requireShared('locale').t
local Adapter = {
    resource = 'my-dispatch',          -- the resource 'auto' checks is started
    label = L('adapters_TEMPLATE.my_dispatch'),             -- shown in the diagnosis and the panel
}

--- File one alert. `alert` carries title, message, coords, street, caller,
--- priority, unique_id (60 characters at most) and job_table (the police
--- jobs, Police.jobs()). Answer anything but false for filed.
---@param alert table
---@return any
function Adapter.AddNotification(alert)
    -- return exports['my-dispatch']:SendAlert({ ... from alert ... })
    error('my-dispatch adapter: AddNotification is not written yet')
end

--- Take one alert off again, by the unique_id it was filed with.
---@param uniqueId string
---@param jobs string[]
function Adapter.ClearNotification(uniqueId, jobs)
    -- return exports['my-dispatch']:RemoveAlert(uniqueId)
    error('my-dispatch adapter: ClearNotification is not written yet')
end

return Adapter
end)
