--- Client half of the mugshot pipeline (§7.2).
---
--- A player renders only their OWN ped, on request, and sends the image back.
--- Rendering another player's ped only works while they are streamed in, so
--- doing it here is what makes a mugshot work at any distance — and one
--- render then serves every viewer instead of one per listing.

local Mugshot = {}

local lastRender = 0

--- Render this player's headshot and hand it to the server.
local function renderSelf()
    if GetResourceState('MugShotBase64') ~= 'started' then return false end

    -- A floor here as well as on the server: a client cannot be made to
    -- render in a loop by a flood of requests.
    -- Not GetGameTimer: it wraps, and after a wrap this subtraction is
    -- permanently negative, so the floor would refuse every render for the
    -- rest of the session and this player would have no mugshot at all.
    local now = CrimsonUtil.monotonicMs()
    if now - lastRender < 30000 then return false end
    lastRender = now

    local ped = PlayerPedId()
    if not ped or ped == 0 then return false end

    local ok, image = pcall(function()
        return exports['MugShotBase64']:GetMugShotBase64(ped, true)
    end)
    if not ok or type(image) ~= 'string' then return false end

    TriggerServerEvent('crimson-bounty:mugshot', image)
    return true
end

RegisterNetEvent('crimson-bounty:renderMugshot', function()
    renderSelf()
end)

--- Appearance changes invalidate the cached image rather than a timer
--- re-rendering every listed bounty (§14.26).
local function announceAppearanceChange()
    TriggerServerEvent('crimson-bounty:appearanceChanged')
end

for _, event in ipairs({
    'qb-clothing:client:loadOutfit',
    'illenium-appearance:client:reloadSkin',
    'rcore_clothing:outfitChanged',
    'crimson-bounty:appearanceChanged',
}) do
    AddEventHandler(event, announceAppearanceChange)
end

return Mugshot
