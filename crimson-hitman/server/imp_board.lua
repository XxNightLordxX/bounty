--- Board and progression improvements (README, Optional features), group
--- impB. Four features, each its own block of Config.Improvements and each
--- off as shipped; with all four off nothing here reads, writes or sends
--- anything, and the resource behaves as it did before them:
---
---   * PlacerRecord (server/imp_placer_record.lua): a hitman sees on a board
---     card how many contracts its placer placed, had paid out and
---     cancelled, never who they are.
---   * HitmanHeat (server/imp_heat.lua): completions on whitelisted-job
---     targets and police alerts about a hitman's work give them heat for a
---     while; a hitman at the threshold warns their targets more often and
---     sets off a vague police bulletin.
---   * Tiers (server/imp_tiers.lua): the bigger rewards are locked to a
---     hitman below the tier's progression level.
---   * ContractDecay (server/imp_decay.lua): an untaken contract's reward
---     rises, charged to its placer, or it ends sooner.
---
--- This file holds what the four share: their rules (checked at the start
--- through server/lib/feature.lua, in main.lua's validateConfig, which the
--- admin panel also runs against a copy with a change in it), the wiring,
--- and the one tick job.

local Feature = CrimsonBoot.require('server.lib.feature')

local ImpBoard = {}

local Record = CrimsonBoot.require('server.imp_placer_record')
local Heat = CrimsonBoot.require('server.imp_heat')
local Tiers = CrimsonBoot.require('server.imp_tiers')
local Decay = CrimsonBoot.require('server.imp_decay')

ImpBoard.record, ImpBoard.heat, ImpBoard.tiers, ImpBoard.decay = Record, Heat, Tiers, Decay

--- What each setting must be, as the start holds config.lua to it
--- (Feature.check, server/lib/feature.lua) and the panel's catalogue
--- (server/settings.lua) offers it.
local TEXT = '^[^%c<>]+$'
local RULES = {
    PlacerRecord = {
        Enabled = { kind = 'switch' }, ShowForAnonymous = { kind = 'switch' },
        LookbackDays = { kind = 'number', integer = true, min = 1, max = 365 },
    },
    HitmanHeat = {
        Enabled = { kind = 'switch' },
        ProtectedCompletionHeat = { kind = 'number', integer = true, min = 0, max = 100 },
        WitnessHeat = { kind = 'number', integer = true, min = 0, max = 100 },
        AdvisoryHeat = { kind = 'number', integer = true, min = 0, max = 100 },
        DecayHours = { kind = 'number', integer = true, min = 1, max = 720 },
        Threshold = { kind = 'number', integer = true, min = 1, max = 1000 },
        WarnTargetChancePercent = { kind = 'number', integer = true, min = 0, max = 100 },
        BulletinEveryMinutes = { kind = 'number', integer = true, min = 0, max = 1440 },
        BulletinTitle = { kind = 'text', pattern = TEXT, max = 60, says = 'text up to 60 characters, no < or >' },
        BulletinText = { kind = 'text', pattern = TEXT, max = 160, says = 'text up to 160 characters, no < or >' },
    },
    Tiers = {
        Enabled = { kind = 'switch' },
        CompletionsPerLevel = { kind = 'number', integer = true, min = 1, max = 1000 },
        Tiers = { kind = 'list', each = Tiers.parseTier, most = 20,
            says = "a list of tiers, each 'name, least reward, least level'" },
    },
    ContractDecay = {
        Enabled = { kind = 'switch' }, Mode = { kind = 'choice', choices = { 'rise', 'shorten' } },
        Percent = { kind = 'number', integer = true, min = 1, max = 100 },
        Hours = { kind = 'number', integer = true, min = 1, max = 168 },
        MaxIncreasePercent = { kind = 'number', integer = true, min = 0, max = 1000 },
        Account = { kind = 'choice', choices = { 'cash', 'bank' } },
    },
}
ImpBoard.RULES = RULES

--- The start-up checks for these four blocks, against the global Config. A
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

---@param deps table { storage, identity, notify, audit, escrow, contracts, amendments,
--- projection, progression, rpConsequences }
function ImpBoard.init(deps)
    Record.init(deps)
    Heat.init(deps)
    Tiers.init(deps)
    Decay.init(deps)
end

--- The maintenance tick's minute job for the board (imp_board.tick): heat
--- aged out and the police bulletin, and the anonymous records of contracts
--- that ended forgotten. Each does nothing while its feature is off.
function ImpBoard.tickBoard()
    Heat.tick()
    Record.sweep()
end

--- And contract decay's steps (imp_decay.tick), on a tick of their own:
--- the one of the four that charges and writes (Decay.tick).
---@return integer stepped
function ImpBoard.tickDecay()
    return Decay.tick()
end

--- Both, as one call (the tests, and anything that wants every step now).
function ImpBoard.tick()
    ImpBoard.tickBoard()
    ImpBoard.tickDecay()
end

return ImpBoard
