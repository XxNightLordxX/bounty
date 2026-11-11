--- phone adapter: lb-phone (client half; the server half is
--- server/adapters/phone/lb-phone.lua).
---
--- lb-phone 2.9's documented client exports (docs.lbscripts.com/phone,
--- client exports and custom apps), with the same arguments and answers.
--- DeleteCustomApp and UninstallApp are not documented: they are the names
--- older builds were tried under before RemoveCustomApp, and are still
--- tried in turn (client/main.lua). Every caller wraps these in pcall.

CrimsonIntegrations.register('phone', 'lb-phone', {
    resource = 'lb-phone',
    AddCustomApp = function(...) return exports['lb-phone']:AddCustomApp(...) end,
    RemoveCustomApp = function(...) return exports['lb-phone']:RemoveCustomApp(...) end,
    DeleteCustomApp = function(...) return exports['lb-phone']:DeleteCustomApp(...) end,
    UninstallApp = function(...) return exports['lb-phone']:UninstallApp(...) end,
    SendCustomAppMessage = function(...) return exports['lb-phone']:SendCustomAppMessage(...) end,
    SendNotification = function(...) return exports['lb-phone']:SendNotification(...) end,
    SaveToGallery = function(...) return exports['lb-phone']:SaveToGallery(...) end,
    EnableWalkableCam = function(...) return exports['lb-phone']:EnableWalkableCam(...) end,
    DisableWalkableCam = function(...) return exports['lb-phone']:DisableWalkableCam(...) end,
    SetCameraComponent = function(...) return exports['lb-phone']:SetCameraComponent(...) end,
})
