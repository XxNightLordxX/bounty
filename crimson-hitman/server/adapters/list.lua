CrimsonBoot.define('server.adapters.list', function() --- The adapters this build has, by kind, in the order 'auto' tries them
--- (docs/dev/adapters.md). A server that writes its own adds its name here,
--- in front of the shipped one to be tried first, and its file beside the
--- others: server/adapters/<kind>/<name>.lua for a server kind, or
--- client/adapters/<kind>/<name>.lua for a client kind (fxmanifest.lua
--- loads every file in both folders by pattern). Client kinds are listed
--- here too, so the server can say which is in use and the admin panel can
--- offer it.

return {
    framework   = { 'qbx_core' },
    inventory   = { 'ox_inventory' },
    target      = { 'ox_target' },                -- client
    dispatch    = { 'sc-dispatch' },
    ambulance   = { 'sc-ambulance', 'qbx_medical' },
    banking     = { 'Renewed-Banking' },
    phone       = { 'lb-phone' },                 -- server and client
    keys        = { 'qbx_vehiclekeys' },
    garage      = { 'onesync' },
    mugshot     = { 'MugShotBase64' },            -- client
    clothing    = { 'qb-clothing', 'illenium-appearance', 'rcore_clothing' },  -- client
    progression = { 'sc-blackmarket' },
}
end)
