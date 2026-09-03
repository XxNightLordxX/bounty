--- Live target mugshots (§7.2, §14.26).
---
--- Rendered on demand and cached, refreshed when appearance actually changes
--- rather than on a timer: a per-frame or per-listing render is the dominant
--- frame cost of a script like this.

local Mugshot = {}

local cache = {}       -- [cid] = { data = base64, at = ms }
local rendering = 0

local function canRender()
    return GetResourceState('MugShotBase64') == 'started'
        and rendering < Config.Mugshot.MaxConcurrentRenders
end

--- Render the given player's headshot, or return the cached one if it is
--- still fresh enough.
---@param serverId number
---@param cid string
---@return string|nil base64
function Mugshot.of(serverId, cid)
    local cached = cache[cid]
    local floorMs = (Config.Mugshot.MinRefreshMinutes or 5) * 60000

    if cached and (GetGameTimer() - cached.at) < floorMs then
        return cached.data
    end
    if not canRender() then
        return cached and cached.data or nil
    end

    local ped = GetPlayerPed(GetPlayerFromServerId(serverId))
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return cached and cached.data or nil
    end

    rendering = rendering + 1
    local ok, image = pcall(function()
        return exports['MugShotBase64']:GetMugShotBase64(ped, true)
    end)
    rendering = rendering - 1

    if not ok or not image then return cached and cached.data or nil end

    cache[cid] = { data = image, at = GetGameTimer() }
    return image
end

--- Invalidate a cached mugshot. Called when the player's appearance changes,
--- so the next request re-renders rather than a timer doing it for everyone.
function Mugshot.invalidate(cid)
    cache[cid] = nil
end

RegisterNetEvent('crimson-bounty:invalidateMugshot', function(cid)
    Mugshot.invalidate(cid)
end)

-- Clothing resources fire their own events on a change; hooking them keeps
-- the refresh event-driven.
for _, event in ipairs({
    'qb-clothing:client:loadOutfit', 'illenium-appearance:client:reloadSkin',
    'rcore_clothing:outfitChanged',
}) do
    AddEventHandler(event, function()
        TriggerServerEvent('crimson-bounty:appearanceChanged')
    end)
end

return Mugshot
