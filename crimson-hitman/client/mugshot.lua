--- Client half of the mugshot pipeline (§7.2).
---
--- A player renders only their OWN ped, on request, and sends the image back.
--- Rendering another player's ped only works while they are streamed in, so
--- doing it here is what makes a mugshot work at any distance — and one
--- render then serves every viewer instead of one per listing.

local Mugshot = {}

--- When this client last rendered, or nil when it never has.
---
--- Not 0. monotonicMs counts from resource start, so on a fresh session the
--- floor below compared 0 - 0 < 30000 and refused — which made the FIRST
--- render of every session the one that never happened, and kept refusing
--- for thirty seconds after that. A player who opened the board just after
--- joining had no headshot, and the server had already marked their entry
--- pending, so it waited out its own render timeout before asking again.
---
--- The floor means "not more than once per thirty seconds". It never meant
--- "not for the first thirty seconds".
local lastRender = nil

--- How fast a headshot goes to the server, in bytes a second. A full-size
--- one is tens of KB, which FiveM says to send as a latent event rather
--- than an ordinary one that holds up everything behind it.
local MUGSHOT_BPS = 100000

--- Render this player's headshot and hand it to the server.
local function renderSelf()
    -- The headshot adapter (client/adapters/mugshot/, Config.Integrations.Mugshot).
    local renderer = CrimsonIntegrations.get('mugshot')
    if not renderer then return false end
    -- Headshots switched off (Config.Mugshot.Enabled): the server asks for
    -- none, and this game renders none if asked all the same.
    local rules = Config and Config.Mugshot
    if type(rules) == 'table' and rules.Enabled == false then return false end

    -- A floor here as well as on the server: a client cannot be made to
    -- render in a loop by a flood of requests.
    -- Not GetGameTimer: it wraps, and after a wrap this subtraction is
    -- permanently negative, so the floor would refuse every render for the
    -- rest of the session and this player would have no mugshot at all.
    local now = CrimsonUtil.monotonicMs()
    if lastRender and now - lastRender < 30000 then return false end
    lastRender = now

    local ped = PlayerPedId()
    if not ped or ped == 0 then return false end

    -- The background is left in unless the server owner asks otherwise
    -- (Config.Mugshot.RemoveBackground): cutting it out loads a 2.6 MB
    -- model in MugShotBase64's page for every render and never frees it.
    local cutOut = type(rules) == 'table' and rules.RemoveBackground == true
    local ok, image = pcall(function()
        return renderer.GetMugShotBase64(ped, cutOut)
    end)
    if not ok or type(image) ~= 'string' then return false end

    TriggerLatentServerEvent('crimson-hitman:mugshot', MUGSHOT_BPS, image)
    return true
end

RegisterNetEvent('crimson-hitman:renderMugshot', function()
    renderSelf()
end)

--- Appearance changes invalidate the cached image rather than a timer
--- re-rendering every listed contract (§14.26).
local function announceAppearanceChange()
    TriggerServerEvent('crimson-hitman:appearanceChanged')
end

--- The same, for one clothing adapter's event: only while
--- Config.Integrations.Clothing lets that adapter answer, read when the
--- event comes, since staff change the choice live (the settings push).
local function fromAdapter(name)
    return function()
        for _, adapter in ipairs(CrimsonIntegrations.candidates('clothing')) do
            if adapter.name == name then return announceAppearanceChange() end
        end
    end
end

--- The clothing resources raise theirs from the server too (illenium's
--- /reloadskin is a TriggerClientEvent), and a copy from the server reaches
--- only a handler registered as a net event: with AddEventHandler alone it
--- was dropped as not safe for net. Only the server sends a client its net
--- events, so registering them opens nothing. Our own stays local.
--- Which events: every clothing adapter's (client/adapters/clothing/),
--- each answered only while Config.Integrations.Clothing lets that
--- adapter answer (fromAdapter).
for _, name in ipairs(CrimsonIntegrations.names('clothing')) do
    local adapter = CrimsonIntegrations.adapter('clothing', name)
    for _, event in ipairs(adapter.events or {}) do
        RegisterNetEvent(event, fromAdapter(name))
    end
end
AddEventHandler('crimson-hitman:appearanceChanged', announceAppearanceChange)

return Mugshot
