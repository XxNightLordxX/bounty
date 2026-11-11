--- A client adapter of your own: copy, rename, fill in
--- (docs/dev/adapters.md, "Adding your own").
---
---   1. Copy this file to client/adapters/<kind>/<your-resource>.lua, for
---      example client/adapters/target/my-target.lua. The manifest loads
---      every client/adapters/*/*.lua; this file, one folder up, is never
---      loaded.
---   2. Write each function the kind needs (the list is in the shipped
---      adapter of the kind, and in docs/dev/adapters.md), calling your
---      script the way ITS documentation says. Never guess an export.
---   3. Add '<your-resource>' to server/adapters/list.lua under the kind, so
---      the server can say which one is in use and the panel can offer it.
---   4. Set Config.Integrations.<Kind> = '<your-resource>' (or leave 'auto').
---
--- The example is a target adapter. Every function may raise: the callers
--- keep their pcall.

CrimsonIntegrations.register('target', 'my-target', {
    resource = 'my-target',  -- the resource 'auto' checks is started
    -- A sphere the player can interact with: def = { coords, radius, debug,
    -- options = { { name, label, icon, distance, onSelect } } }. Answer an id.
    addSphereZone = function(def)
        error('my-target adapter: addSphereZone is not written yet')
    end,
    removeZone = function(id)
        error('my-target adapter: removeZone is not written yet')
    end,
    -- The same options on one local entity (a ped).
    addLocalEntity = function(entity, options)
        error('my-target adapter: addLocalEntity is not written yet')
    end,
    removeLocalEntity = function(entity, names)
        error('my-target adapter: removeLocalEntity is not written yet')
    end,
})
