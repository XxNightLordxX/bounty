--- The roleplay features' settings, put back after a test that changes them.
---
--- Config.Roleplay ships every feature off. A test that turns one on, or
--- changes a figure, live (Config.Roleplay.X.Enabled = true, or through the
--- admin panel) used to leave it so for whatever ran next, until the next
--- newStack(): a check that read Config without a fresh stack, or a spec's
--- describe-time code, then saw it on, and the suite passed or failed by its
--- order. Every roleplay test runs through RP.it (or RP.guard) instead,
--- which puts Config.Roleplay back exactly as it found it, in place (a
--- module holding a block sees the same table), whichever way the test ends.
--- A test of what ships reads tests/harness/shipped.lua's fromFile().

local RP = {}

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

--- What Config.Roleplay is now, to put back with RP.restore.
---@return table
function RP.snapshot()
    return deepCopy(type(Config.Roleplay) == 'table' and Config.Roleplay or {})
end

---@param saved table from RP.snapshot
---@param original table|nil the Config.Roleplay table itself, put back if a test swapped it
function RP.restore(saved, original)
    if type(original) == 'table' then Config.Roleplay = original end
    if type(Config.Roleplay) ~= 'table' then Config.Roleplay = {} end
    restoreInto(Config.Roleplay, saved)
end

--- `fn` wrapped so that Config.Roleplay is put back after it, raise or not.
---@param fn function
---@return function
function RP.guard(fn)
    return function(...)
        local original, saved = Config.Roleplay, RP.snapshot()
        local out = table.pack(pcall(fn, ...))
        RP.restore(saved, original)
        if not out[1] then error(out[2], 0) end
        return table.unpack(out, 2, out.n)
    end
end

--- The suite's it(), with Config.Roleplay put back after the test.
---@param name string
---@param fn function
function RP.it(name, fn)
    return _G.it(name, RP.guard(fn))
end

return RP
