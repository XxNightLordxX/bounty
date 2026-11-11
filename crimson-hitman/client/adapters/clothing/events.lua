--- clothing adapters (client): the event each clothing script raises when a
--- player's outfit changes, which refreshes their headshot
--- (client/mugshot.lua). These are the events this resource has always
--- listened for; they are not read from those scripts' source. Listening
--- costs nothing whether the script is there or not, so 'auto' listens for
--- every one. A server whose clothing script raises another event adds an
--- adapter here with its `events`, and its name to server/adapters/list.lua
--- (docs/dev/adapters.md).

local function listened() return true end

CrimsonIntegrations.register('clothing', 'qb-clothing', {
    resource = 'qb-clothing', detect = listened, events = { 'qb-clothing:client:loadOutfit' },
})
CrimsonIntegrations.register('clothing', 'illenium-appearance', {
    resource = 'illenium-appearance', detect = listened, events = { 'illenium-appearance:client:reloadSkin' },
})
CrimsonIntegrations.register('clothing', 'rcore_clothing', {
    resource = 'rcore_clothing', detect = listened, events = { 'rcore_clothing:outfitChanged' },
})
