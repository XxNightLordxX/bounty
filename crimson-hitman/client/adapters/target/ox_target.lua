--- target adapter: ox_target (client).
---
--- Read from ox_target 1.18 (client/api.lua): addSphereZone(def) -> id,
--- removeZone(id, suppressWarning), addLocalEntity(entities, options),
--- removeLocalEntity(entities, optionNames). The step markers
--- (client/missionsteps.lua) and the organisation's spots (client/org.lua)
--- call these inside pcall.

CrimsonIntegrations.register('target', 'ox_target', {
    resource = 'ox_target',
    addSphereZone = function(...) return exports.ox_target:addSphereZone(...) end,
    removeZone = function(...) return exports.ox_target:removeZone(...) end,
    addLocalEntity = function(...) return exports.ox_target:addLocalEntity(...) end,
    removeLocalEntity = function(...) return exports.ox_target:removeLocalEntity(...) end,
})
