--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║            crimson-hitman - server/adapters/phone/lb-phone.lua            ║
    ║                   phone adapter: lb-phone (server half)                   ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- lb-phone 2.9 ships its server code escrowed; these are its documented
--- server exports (docs.lbscripts.com/phone, server exports), with the
--- same arguments and answers. The client half is client/adapters/phone/
--- lb-phone.lua. They may raise: the callers keep their pcall.

local Adapter = { resource = 'lb-phone', label = 'lb-phone' }

function Adapter.GetEquippedPhoneNumber(...) return exports['lb-phone']:GetEquippedPhoneNumber(...) end
function Adapter.SendNotification(...) return exports['lb-phone']:SendNotification(...) end
function Adapter.ContainsBlacklistedWord(...) return exports['lb-phone']:ContainsBlacklistedWord(...) end
function Adapter.IsInCall(...) return exports['lb-phone']:IsInCall(...) end
function Adapter.EndCall(...) return exports['lb-phone']:EndCall(...) end
function Adapter.GetConfig(...) return exports['lb-phone']:GetConfig(...) end
function Adapter.PostBirdy(...) return exports['lb-phone']:PostBirdy(...) end

--- Whether this build exports CreateCall: probed, never assumed (indexing a
--- missing export raises in FiveM). Asked each time, never kept: FiveM's
--- export proxy empties its cache when lb-phone restarts.
---@return boolean
function Adapter.canCall()
    local ok, fn = pcall(function() return exports['lb-phone'].CreateCall end)
    return ok and type(fn) == 'function'
end

--- CreateCall(caller, calleeNumber, options) -> callId, or nil.
function Adapter.CreateCall(...) return exports['lb-phone']:CreateCall(...) end

return Adapter
