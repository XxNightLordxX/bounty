--- The switches the owner's server runs, for a test of a shipped path.
---
--- tests/run.lua starts every stack from config/config.lua with a few
--- switches turned the other way (its CONFIG_DEFAULTS): kill photos on,
--- contracts a kill completes too, three collections, no least reward, kill
--- photos sent as links. Most specs are about what those make possible. A
--- test of what the owner's players meet puts the shipped values back with
--- Shipped.apply() after newStack(), or opens its stack with
--- Shipped.newStack(). newStack() puts the runner's config back for the
--- next test, so nothing set here leaks into it.
---
--- Shipped.VALUES is held to config/config.lua by fulfilment_spec, so a
--- change to what ships is a change here too.

local Shipped = {}

--- { section (nil for Config itself), key, value }, as config/config.lua
--- ships them.
Shipped.VALUES = {
    { 'Completion', 'Fulfilment', 'alive' },
    { 'Completion', 'KillPhotos', false },
    { 'Completion', 'PhotoStorage', 'server' },
    { 'Limits', 'MaxPayoutSlots', 1 },
    { 'Limits', 'MinContractReward', 1000 },
    { 'Mugshot', 'Enabled', true },
    { 'WhitelistedView', 'Enabled', true },
    { nil, 'Debug', false },
}

--- Set every shipped value on the live Config.
function Shipped.apply()
    for _, entry in ipairs(Shipped.VALUES) do
        local section, key, value = entry[1], entry[2], entry[3]
        local into = section and Config[section] or Config
        into[key] = value
    end
end

--- A fresh stack (tests/run.lua newStack) running the shipped values.
---@return table stack
function Shipped.newStack()
    local s = newStack()
    Shipped.apply()
    return s
end

--- config/config.lua read on its own, into a table of its own: the live
--- Config is not touched.
---@return table config
function Shipped.fromFile()
    local env = setmetatable({}, { __index = function(_, name)
        if name == 'Config' then return nil end
        return _G[name]
    end })
    local chunk = assert(loadfile('crimson-hitman/config/config.lua', 't', env))
    chunk()
    return rawget(env, 'Config')
end

return Shipped
