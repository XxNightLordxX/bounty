--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║          crimson-hitman - server/adapters/framework/qbx_core.lua          ║
    ║                        framework adapter: qbx_core                        ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Read from qbx_core 1.24 (server/player.lua, server/groups.lua,
--- server/functions.lua). Each function is the export of the same name,
--- with the same arguments and answers; another framework's adapter
--- implements the same names (docs/dev/adapters.md). They may raise: the
--- callers keep their pcall.

local Adapter = { resource = 'qbx_core', label = 'Qbox (qbx_core)' }

-- ============================================================================
--                              PLAYERS
-- ============================================================================

function Adapter.GetPlayer(...) return exports.qbx_core:GetPlayer(...) end
function Adapter.GetPlayerByCitizenId(...) return exports.qbx_core:GetPlayerByCitizenId(...) end
function Adapter.GetOfflinePlayer(...) return exports.qbx_core:GetOfflinePlayer(...) end
function Adapter.GetMetadata(...) return exports.qbx_core:GetMetadata(...) end
function Adapter.Save(...) return exports.qbx_core:Save(...) end

-- ============================================================================
--                              MONEY
-- ============================================================================

function Adapter.GetMoney(...) return exports.qbx_core:GetMoney(...) end
function Adapter.AddMoney(...) return exports.qbx_core:AddMoney(...) end
function Adapter.RemoveMoney(who, account, amount, reason)
    return exports.qbx_core:RemoveMoney(who, account, amount, reason)
end

-- ============================================================================
--                              JOBS
-- ============================================================================

function Adapter.GetJob(...) return exports.qbx_core:GetJob(...) end
function Adapter.CreateJobs(...) return exports.qbx_core:CreateJobs(...) end
function Adapter.UpsertJobData(...) return exports.qbx_core:UpsertJobData(...) end
function Adapter.UpsertJobGrade(...) return exports.qbx_core:UpsertJobGrade(...) end
function Adapter.RemoveJobGrade(...) return exports.qbx_core:RemoveJobGrade(...) end
function Adapter.AddPlayerToJob(...) return exports.qbx_core:AddPlayerToJob(...) end
function Adapter.SetPlayerPrimaryJob(...) return exports.qbx_core:SetPlayerPrimaryJob(...) end
function Adapter.RemovePlayerFromJob(...) return exports.qbx_core:RemovePlayerFromJob(...) end
-- The duty of the player's primary job (server/player.lua: SetJobDuty(identifier,
-- onDuty)); optional: an adapter without it leaves qbx duty as it is.
function Adapter.SetJobDuty(...) return exports.qbx_core:SetJobDuty(...) end

return Adapter
