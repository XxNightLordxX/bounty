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
--- This file holds what the four share: their rules, the start-up checks
--- (main.lua's validateConfig, which the admin panel also runs against a
--- copy with a change in it), the wiring, and the one tick job.

local Util = CrimsonBoot.requireShared('util')

local ImpBoard = {}

local Record = CrimsonBoot.require('server.imp_placer_record')
local Heat = CrimsonBoot.require('server.imp_heat')
local Tiers = CrimsonBoot.require('server.imp_tiers')
local Decay = CrimsonBoot.require('server.imp_decay')

ImpBoard.record, ImpBoard.heat, ImpBoard.tiers, ImpBoard.decay = Record, Heat, Tiers, Decay

--- One feature's block, or nil when it is off or missing. Handed to the
--- four (as `board.on`), not exported.
---@param name string
---@return table|nil
local function on(name)
    local imp = type(Config.Improvements) == 'table' and Config.Improvements or nil
    local block = imp and imp[name]
    if type(block) == 'table' and block.Enabled == true then return block end
    return nil
end

--- One tier line, 'name, least reward, least level', read: nil when it is
--- not one. The name is what the card shows; nothing else reads it.
---@param line any
---@return table|nil { name, minReward, minLevel }
function ImpBoard.parseTier(line)
    if type(line) ~= 'string' or #line > 60 then return nil end
    local name, reward, level = line:match('^%s*([^%c<>,]-)%s*,%s*(%d+)%s*,%s*(%d+)%s*$')
    if not name or #name == 0 then return nil end
    reward, level = tonumber(reward), tonumber(level)
    if not reward or reward > 1000000000 or not level or level < 1 or level > 100 then return nil end
    return { name = name, minReward = math.floor(reward), minLevel = math.floor(level) }
end

--- What each setting must be, as the start holds config.lua to it and the
--- panel's catalogue (server/settings.lua) offers it.
local TEXT = '^[^%c<>]+$'
local RULES = {
    PlacerRecord = {
        Enabled = { 'switch' }, ShowForAnonymous = { 'switch' },
        LookbackDays = { 'integer', 1, 365 },
    },
    HitmanHeat = {
        Enabled = { 'switch' },
        ProtectedCompletionHeat = { 'integer', 0, 100 }, WitnessHeat = { 'integer', 0, 100 },
        AdvisoryHeat = { 'integer', 0, 100 }, DecayHours = { 'integer', 1, 720 },
        Threshold = { 'integer', 1, 1000 }, WarnTargetChancePercent = { 'integer', 0, 100 },
        BulletinEveryMinutes = { 'integer', 0, 1440 },
        BulletinTitle = { 'text', TEXT, 60 }, BulletinText = { 'text', TEXT, 160 },
    },
    Tiers = {
        Enabled = { 'switch' }, CompletionsPerLevel = { 'integer', 1, 1000 },
        Tiers = { 'tiers' },
    },
    ContractDecay = {
        Enabled = { 'switch' }, Mode = { 'choice', { rise = true, shorten = true } },
        Percent = { 'integer', 1, 100 }, Hours = { 'integer', 1, 168 },
        MaxIncreasePercent = { 'integer', 0, 1000 },
        Account = { 'choice', { cash = true, bank = true } },
    },
}
ImpBoard.RULES = RULES

--- Whether one value keeps its rule.
local function fits(rule, value)
    local kind = rule[1]
    if kind == 'switch' then return type(value) == 'boolean' end
    if kind == 'integer' then
        if type(value) ~= 'number' or value ~= value or math.floor(value) ~= value then return false end
        return value >= rule[2] and value <= rule[3]
    end
    if kind == 'text' then
        return type(value) == 'string' and #value > 0 and #value <= rule[3] and value:match(rule[2]) ~= nil
    end
    if kind == 'choice' then return type(value) == 'string' and rule[2][value] == true end
    if kind == 'tiers' then
        if type(value) ~= 'table' or #value > 20 then return false end
        for k in pairs(value) do
            if math.type(k) ~= 'integer' or k < 1 or k > #value then return false end
        end
        for i = 1, #value do
            if not ImpBoard.parseTier(value[i]) then return false end
        end
        return true
    end
    return false
end

--- A deep copy (Util.copy, the one shared copy).
local copyOf = Util.copy

--- The start-up checks for these four blocks, against the global Config. A
--- block or a setting missing is filled from defaults.lua; one that breaks
--- its rule is put back to the shipped value, and said. A feature that
--- cannot work is never refused a start: it is off. Other blocks of
--- Config.Improvements (other features) are not looked at.
---@param warn string[] where each correction is said
---@param filled string[] where each setting filled in is named
function ImpBoard.checkConfig(warn, filled)
    local shipped = type(ConfigDefaults) == 'table' and type(ConfigDefaults.Improvements) == 'table'
        and ConfigDefaults.Improvements or {}
    if type(Config.Improvements) ~= 'table' then Config.Improvements = {} end
    local names = {}
    for name in pairs(RULES) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local rules, defaults = RULES[name], shipped[name] or { Enabled = false }
        local block = Config.Improvements[name]
        if type(block) ~= 'table' then
            block = copyOf(defaults)
            Config.Improvements[name] = block
            filled[#filled + 1] = 'Improvements.' .. name .. ' (whole block)'
        end
        for key, rule in pairs(rules) do
            local value = block[key]
            if value == nil then
                block[key] = copyOf(defaults[key])
                filled[#filled + 1] = ('Improvements.%s.%s'):format(name, key)
            elseif not fits(rule, value) then
                warn[#warn + 1] = ('Config.Improvements.%s.%s is %s, which it cannot be. Using the shipped %s.')
                    :format(name, key, type(value) == 'table' and 'a list it cannot use' or tostring(value),
                        type(defaults[key]) == 'table' and 'list' or tostring(defaults[key]))
                block[key] = copyOf(defaults[key])
            end
        end
    end
end

---@param deps table { storage, identity, notify, audit, escrow, contracts, amendments,
--- projection, progression, rpConsequences }
function ImpBoard.init(deps)
    local board = { on = on, parseTier = ImpBoard.parseTier }
    Record.init(deps, board)
    Heat.init(deps, board)
    Tiers.init(deps, board)
    Decay.init(deps, board)
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
