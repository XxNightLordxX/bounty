--- The client's half of the module loader (server/boot.lua).
---
--- The shared files (shared/util.lua and the rest) hand their body to
--- CrimsonBoot.define in their first line, for the server's loader. The
--- client has no loader: each body runs here at once, as the manifest loads
--- the file, and publishes its global (CrimsonUtil, CrimsonGeo, CrimsonLog,
--- ...) for the files listed after it, as it always has.

CrimsonBoot = {}

--- The globals the shared files publish when their body runs, one each
--- (shared/util.lua, geo.lua, log.lua, locale.lua, integrations.lua), for
--- the client files after them: declared here, at file scope, because each
--- file sets its own from inside the body it hands to CrimsonBoot.define.
CrimsonUtil, CrimsonGeo, CrimsonLog, CrimsonLocale, CrimsonIntegrations = nil, nil, nil, nil, nil

---@param _ string the module's name (the server's loader keys on it)
---@param factory function the file's body
function CrimsonBoot.define(_, factory)
    factory()
end
