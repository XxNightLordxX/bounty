--- The improvements' settings (Config.Improvements, and the completion
--- cooldown in Config.Limits), put back after a test that changes them, as
--- tests/harness/roleplay.lua does for Config.Roleplay: in place, so a
--- module holding a block sees the same table, whichever way the test ends.

local IMP = {}

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
    return out
end

local function restoreInto(target, saved)
    for key in pairs(target) do
        if saved[key] == nil then target[key] = nil end
    end
    for key, value in pairs(saved) do
        if type(value) == 'table' and type(target[key]) == 'table' then
            restoreInto(target[key], value)
        else
            target[key] = deepCopy(value)
        end
    end
end

--- `fn` wrapped so that Config.Improvements and the completion cooldown are
--- put back after it, raise or not.
---@param fn function
---@return function
function IMP.guard(fn)
    return function(...)
        local original = Config.Improvements
        local saved = deepCopy(type(original) == 'table' and original or {})
        local cooldown = Config.Limits.TargetCooldownAfterCompletionSeconds
        local out = table.pack(pcall(fn, ...))
        if type(original) == 'table' then Config.Improvements = original end
        if type(Config.Improvements) ~= 'table' then Config.Improvements = {} end
        restoreInto(Config.Improvements, saved)
        Config.Limits.TargetCooldownAfterCompletionSeconds = cooldown
        if not out[1] then error(out[2], 0) end
        return table.unpack(out, 2, out.n)
    end
end

--- The suite's it(), with Config.Roleplay and Config.Improvements put back.
---@param name string
---@param fn function
function IMP.it(name, fn)
    return require('tests.harness.roleplay').it(name, IMP.guard(fn))
end

return IMP
