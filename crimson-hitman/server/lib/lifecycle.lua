CrimsonBoot.define('server.lib.lifecycle', function() --- Cleanup lists: what each module forgets when a player leaves, a contract
--- ends or a hitman steps off one.
---
--- A list is the steps in the order they run, each a module's key in the
--- wiring table and the name of its function: { 'death', 'clearPlayer' }.
--- Run against the modules in hand, so a stack of its own (the tests', a
--- restart's) cleans its own modules. A module that is not wired, or has no
--- such function, is skipped. One step that raises is said in one line and
--- the rest still run: a module that could not forget its own state never
--- keeps the others holding theirs (handles, markers, countdowns that hold a
--- cap).

local Log = CrimsonBoot.requireShared('log')

local Lifecycle = {}

--- Run every step of `steps` with these arguments, in order.
---@param label string what the list is for, in the line a raise prints
---@param modules table the wiring table: { [key] = module }
---@param steps table[] { { key, functionName }, ... }
---@return integer ran how many steps ran
---@return integer failed how many of them raised
function Lifecycle.run(label, modules, steps, ...)
    local ran, failed = 0, 0
    for i = 1, #steps do
        local key, name = steps[i][1], steps[i][2]
        local module = modules and modules[key]
        local fn = type(module) == 'table' and module[name] or nil
        if type(fn) == 'function' then
            ran = ran + 1
            local ok, err = pcall(fn, ...)
            if not ok then
                failed = failed + 1
                Log.always(('%s: %s.%s raised: %s'):format(label, key, name, tostring(err)))
            end
        end
    end
    return ran, failed
end

return Lifecycle
end)
