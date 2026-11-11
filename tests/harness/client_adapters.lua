--- The client's adapters into a client environment, as the manifest loads
--- them (shared/integrations.lua, then client/adapters/*/*.lua): a
--- CrimsonIntegrations of that environment's own, whose GetResourceState is
--- the environment's.
---@param env table|nil a loadfile environment; nil for the global one
return function(env)
    local function run(path)
        if env then assert(loadfile(path, 't', env))() else dofile(path) end
    end
    run('crimson-hitman/shared/integrations.lua')
    local pipe = io.popen("find crimson-hitman/client/adapters -mindepth 2 -maxdepth 2 -name '*.lua' -type f | sort")
    for path in pipe:lines() do run(path) end
    pipe:close()
end
