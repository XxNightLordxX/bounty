--- The tiered board (Config.Improvements.Tiers, README, Optional
--- features). Off as shipped, and off too while Config.Progression is.
---
--- Each tier is 'name, least reward, least level'. A contract's tier is the
--- highest one whose least reward its current payout reaches, priced as the
--- board orders it (Escrow.moneyValue of the slot being competed for). A
--- hitman's level is their own record's: 1, plus one for every
--- CompletionsPerLevel contracts they completed (Progression.record, the
--- same record the app shows them). Below the tier's level, the card says
--- it is locked and what level it needs, and Accept is refused on the
--- server (tier_locked) before anything is taken. Nothing here is about
--- anybody but the viewer: their own level, and the contract's price,
--- which every viewer already sees.

local Util = CrimsonBoot.requireShared('util')
local Feature = CrimsonBoot.require('server.lib.feature')

local Tiers = {}

local Escrow, Progression, Projection

--- One tier line, 'name, least reward, least level', read: nil when it is
--- not one. The name is what the card shows; nothing else reads it.
---@param line any
---@return table|nil { name, minReward, minLevel }
function Tiers.parseTier(line)
    if type(line) ~= 'string' or #line > 60 then return nil end
    local name, reward, level = line:match('^%s*([^%c<>,]-)%s*,%s*(%d+)%s*,%s*(%d+)%s*$')
    if not name or #name == 0 then return nil end
    reward, level = tonumber(reward), tonumber(level)
    if not reward or reward > 1000000000 or not level or level < 1 or level > 100 then return nil end
    return { name = name, minReward = math.floor(reward), minLevel = math.floor(level) }
end

--- The tiers' block while they are on, and progression with them (a
--- level is read from it); nil otherwise.
local function rules()
    if not Feature.on('Progression') then return nil end
    return Feature.active('Improvements.Tiers')
end

--- The tiers in force, highest least reward first.
---@return table[] { name, minReward, minLevel }
function Tiers.list()
    local cfg = rules()
    if not cfg then return {} end
    local out = {}
    for _, line in ipairs(type(cfg.Tiers) == 'table' and cfg.Tiers or {}) do
        local tier = Tiers.parseTier(line)
        if tier then out[#out + 1] = tier end
    end
    table.sort(out, function(a, b) return a.minReward > b.minReward end)
    return out
end

--- A hitman's level from their record.
---@param record table|nil Progression.record
---@return integer
function Tiers.levelOf(record)
    local cfg = rules()
    local per = math.max(1, math.floor(tonumber(cfg and cfg.CompletionsPerLevel) or 5))
    local completed = math.max(0, math.floor(tonumber(type(record) == 'table' and record.completed) or 0))
    return 1 + math.floor(completed / per)
end

--- The tier a payout of this worth falls in, or nil.
---@param worth number
---@return table|nil
function Tiers.tierFor(worth)
    worth = tonumber(worth) or 0
    for _, tier in ipairs(Tiers.list()) do
        if worth >= tier.minReward then return tier end
    end
    return nil
end

--- Why this hitman may not take this contract, or nil.
---@param contract table
---@param record table|nil the viewer's Progression.record
---@return table|nil { tier, level, yours }
function Tiers.lockFor(contract, record)
    if not rules() or type(contract) ~= 'table' then return nil end
    local worth = Escrow.moneyValue(contract.id, { slot = contract.next_slot or 1 })
    local tier = Tiers.tierFor(worth)
    if not tier then return nil end
    local level = Tiers.levelOf(record)
    if level >= tier.minLevel then return nil end
    return { tier = tier.name, level = tier.minLevel, yours = level }
end

--- In front of an acceptance (App's roleplay gate): a hitman below the
--- tier's level is refused before anything is taken.
---@return string|nil err
---@return table|nil data
function Tiers.gate(name, actor, payload)
    if name ~= 'accept' or not rules() then return nil end
    local Storage = Tiers.storage
    local id = type(payload) == 'table' and Util.toId(payload.id) or nil
    local contract = id and Storage.readContract(id) or nil
    if not contract or contract.creator_cid == actor.cid or contract.target_cid == actor.cid then
        return nil
    end
    local lock = Tiers.lockFor(contract, Progression.record(actor.cid))
    if lock then return CH.ERR.TIER_LOCKED, lock end
    return nil
end

function Tiers.init(deps)
    Escrow, Progression, Projection = deps.escrow, deps.progression, deps.projection
    Tiers.storage = deps.storage
    if Projection and Projection.extenders then
        -- A card the viewer could take: the board's strangers' cards only.
        Projection.extenders.impTiers = function(out, contract, viewerCid, role)
            if role ~= 'public' or not rules() then return end
            out.tierLocked = Tiers.lockFor(contract, Projection.recordFor(viewerCid))
        end
    end
end

return Tiers
