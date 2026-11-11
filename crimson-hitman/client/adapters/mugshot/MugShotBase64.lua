--- mugshot adapter: MugShotBase64 (client).
---
--- Read from MugShotBase64 (client.lua): GetMugShotBase64(ped, transparent)
--- -> a data URL of the ped's headshot. client/mugshot.lua calls it inside
--- pcall.

CrimsonIntegrations.register('mugshot', 'MugShotBase64', {
    resource = 'MugShotBase64',
    GetMugShotBase64 = function(...) return exports['MugShotBase64']:GetMugShotBase64(...) end,
})
