--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║         crimson-hitman - server/adapters/dispatch/sc-dispatch.lua         ║
    ║                       dispatch adapter: sc-dispatch                       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- sc-dispatch ships escrowed: these two calls are the ones this resource
--- has always made, as the Crimson RP house rules document them (not read
--- from its source):
---   AddNotification({ job_table, title, message, coords, street, caller,
---                     priority, sound, flash, unique_id, blip, radio })
---   ClearNotification(idOrUniqueId, jobs)
--- Police.dispatch / Police.clear (server/police.lua) are the only callers.

local Adapter = { resource = 'sc-dispatch', label = 'sc-dispatch' }

function Adapter.AddNotification(...) return exports['sc-dispatch']:AddNotification(...) end
function Adapter.ClearNotification(...) return exports['sc-dispatch']:ClearNotification(...) end

return Adapter
