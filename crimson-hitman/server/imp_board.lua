--- Board improvements (README, Optional features), group impB: contract
--- decay (server/imp_decay.lua), its block of Config.Improvements, off as
--- shipped: an untaken contract's reward rises, charged to its placer, or
--- it ends sooner. With it off nothing here reads, writes or sends anything.
---
--- The rest of what this group once held is part of a character's record
--- (server/record/: the placer's record on a card, hitman heat, the tiered
--- board). This file holds decay's rules (checked at the start through
--- server/lib/feature.lua, in main.lua's validateConfig, which the admin
--- panel also runs against a copy with a change in it), its wiring, and its
--- tick.

local Feature = CrimsonBoot.require('server.lib.feature')

local ImpBoard = {}

local Decay = CrimsonBoot.require('server.imp_decay')

ImpBoard.decay = Decay

--- What each setting must be, as the start holds config.lua to it
--- (Feature.check, server/lib/feature.lua) and the panel's catalogue
--- (server/settings.lua) offers it.
local RULES = {
    ContractDecay = {
        Enabled = { kind = 'switch' }, Mode = { kind = 'choice', choices = { 'rise', 'shorten' } },
        Percent = { kind = 'number', integer = true, min = 1, max = 100 },
        Hours = { kind = 'number', integer = true, min = 1, max = 168 },
        MaxIncreasePercent = { kind = 'number', integer = true, min = 0, max = 1000 },
        Account = { kind = 'choice', choices = { 'cash', 'bank' } },
    },
}
ImpBoard.RULES = RULES

--- The start-up check for decay's block, against the global Config. A
--- block or a setting missing is filled from defaults.lua; one that breaks
--- its rule is put back to the shipped value, and said. A feature that
--- cannot work is never refused a start: it is off.
---@param warn string[] where each correction is said
---@param filled string[] where each setting filled in is named
function ImpBoard.checkConfig(warn, filled)
    local names = {}
    for name in pairs(RULES) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        Feature.check('Improvements.' .. name, RULES[name], warn, filled)
    end
end

---@param deps table { storage, identity, notify, audit, escrow, contracts, amendments, projection }
function ImpBoard.init(deps)
    Decay.init(deps)
end

--- Contract decay's steps (imp_decay.tick), on a tick of their own: it
--- charges and writes (Decay.tick).
---@return integer stepped
function ImpBoard.tick()
    return Decay.tick()
end

return ImpBoard
