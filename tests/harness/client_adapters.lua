--- The client's adapters into a client environment, as the manifest loads
--- them (shared/integrations.lua, then client/adapters/*/*.lua): a
--- CrimsonIntegrations of that environment's own, whose GetResourceState is
--- the environment's.
---@param env table|nil a loadfile environment; nil for the global one
return function(env)
    local function run(path)
        if env then assert(loadfile(path, 't', env))() else dofile(path) end
    end
    -- shared/integrations.lua hands its body to CrimsonBoot.define, which on
    -- the client is client/boot.lua's: it runs the body at once. The global
    -- environment holds the server's loader, so it is set aside meanwhile.
    if env then
        if rawget(env, 'CrimsonBoot') == nil then run('crimson-hitman/client/boot.lua') end
        run('crimson-hitman/shared/integrations.lua')
    else
        -- client/boot.lua run in an environment of its own, so its
        -- declarations of the shared globals leave the ones already
        -- published here alone; only its CrimsonBoot is taken.
        local server = _G.CrimsonBoot
        local own = setmetatable({}, { __index = _G })
        assert(loadfile('crimson-hitman/client/boot.lua', 't', own))()
        _G.CrimsonBoot = own.CrimsonBoot
        local ok, err = pcall(dofile, 'crimson-hitman/shared/integrations.lua')
        _G.CrimsonBoot = server
        if not ok then error(err, 0) end
    end
    local pipe = io.popen("find crimson-hitman/client/adapters -mindepth 2 -maxdepth 2 -name '*.lua' -type f | sort")
    for path in pipe:lines() do run(path) end
    pipe:close()
end
