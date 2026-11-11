--- A character's record (Config.Record, README, A hitman's record): the one
--- place that keeps and reads where a player stands.
---
---   * The counters (Storage.bumpStat / readStats): contracts placed,
---     completed, failed and survived, kept for the life of the character.
---     Record.of is the one read of them, for the app's Ledger, the
---     operatives on a card (Projection) and the panel's player card.
---   * Standing and level, both from those counters: the short label the
---     app shows (Record.standing) and the level the tiered board asks for
---     (Record.level, Config.Record.Tiers.CompletionsPerLevel).
---   * Trust (Config.Record.Progression): a completion feeds the server's
---     own criminal progression (exports[Resource]:AddTrust), scaled, with
---     Config.Record.Reputation on, by how it was done (Record.factorFor).
---   * The tiered board (Config.Record.Tiers): a payout above the viewer's
---     level is locked on the card and refused at Accept (Record.tierGate).
---   * Heat (Config.Record.Heat, server/record/heat.lua) and the placer's
---     record on a card (Config.Record.PlacerRecord,
---     server/record/placer.lua), each in its own file, read through here.
---
--- One start-up check for every block (Record.validate), one minute job
--- (Record.tick), one wiring (Record.init). Nothing here moves money; a
--- progression resource absent or shaped differently never breaks a
--- payout that already happened.

local Feature = CrimsonBoot.require('server.lib.feature')
local Util = CrimsonBoot.requireShared('util')
local Heat = CrimsonBoot.require('server.record.heat')
local Placer = CrimsonBoot.require('server.record.placer')
local Integrations = CrimsonBoot.require('server.adapters.init')

local Record = {}

Record.heat, Record.placer = Heat, Placer

--- The blocks of Config.Record.
local PROGRESSION, REPUTATION, TIERS = 'Record.Progression', 'Record.Reputation', 'Record.Tiers'

local Storage, Audit, Identity, Escrow, Projection

local function num(value)
    local n = tonumber(value)
    if not n or n ~= n then return 0 end
    return n
end

--------------------------------------------------------------------------
-- The counters, standing and level
--------------------------------------------------------------------------

--- A short label for the record. Deliberately vague at the low end: a new
--- hitman should not be visibly marked as one.
function Record.standing(completed, failed)
    if completed >= 50 then return 'Notorious' end
    if completed >= 20 then return 'Established' end
    if completed >= 5  then return 'Known' end
    return 'Unproven'
end

--- A player's record, as the app and the panel show it.
---@param cid string
---@return table
function Record.of(cid)
    local stats = Storage.readStats(cid)
    local completed = stats.completed or 0
    local failed = stats.failed or 0
    local total = completed + failed

    return {
        completed = completed,
        failed    = failed,
        placed    = stats.placed or 0,
        survived  = stats.survived or 0,
        -- Shown only once there is enough history for it to mean anything;
        -- a single completed contract is not a 100% record.
        rate      = total >= 3 and math.floor((completed / total) * 100) or nil,
        standing  = Record.standing(completed, failed),
    }
end

--- A hitman's level from their record: 1, plus one for every
--- CompletionsPerLevel contracts they completed.
---@param record table|nil Record.of
---@return integer
function Record.level(record)
    local cfg = Feature.on(PROGRESSION) and Feature.active(TIERS) or nil
    local per = math.max(1, math.floor(tonumber(cfg and cfg.CompletionsPerLevel) or 5))
    local completed = math.max(0, math.floor(tonumber(type(record) == 'table' and record.completed) or 0))
    return 1 + math.floor(completed / per)
end

function Record.onContractPlaced(cid)
    Storage.bumpStat(cid, 'placed')
end

--- A hitman finished a contract: counted, and the trust it earns given to
--- the server's wider criminal progression.
---@param cid string
---@param fulfilment string
---@param factor number|nil the reputation factor (Record.factorFor), when on
function Record.onCompleted(cid, fulfilment, factor)
    Storage.bumpStat(cid, 'completed')

    local cfg = Feature.block(PROGRESSION)
    if not cfg.Enabled then return end

    local amount = fulfilment == CH.FULFILMENT.KIDNAPPING
        and cfg.TrustPerKidnapping
        or cfg.TrustPerElimination

    -- Scaled by how it was done (Config.Record.Reputation, off as shipped:
    -- no factor is passed then), rounded to a whole amount.
    if amount and type(factor) == 'number' and factor == factor and factor >= 0 then
        amount = math.floor(amount * factor + 0.5)
    end

    if not amount or amount <= 0 then return end

    -- The progression adapter (Config.Integrations.Progression): none
    -- answering, nothing is given. One absent or shaped differently must
    -- never break a payout that has already happened.
    if not Integrations.has('progression') then return end
    local ok, err = Integrations.call('progression', 'AddTrust', cid, amount)

    if ok then
        Audit.action('progression_awarded', cid, nil, { amount = amount, fulfilment = fulfilment,
            factor = type(factor) == 'number' and factor or nil })
    else
        Audit.rejected('progression_failed', cid, nil, { error = tostring(err) })
    end
end

function Record.onFailed(cid)
    Storage.bumpStat(cid, 'failed')
end

--- The target outlived the contract: bought out, expired, or cancelled.
function Record.onSurvived(cid)
    Storage.bumpStat(cid, 'survived')
end

--------------------------------------------------------------------------
-- Reputation: how the trust of a completion is scaled
--------------------------------------------------------------------------
--- With Config.Record.Reputation on, the trust a completion earns is
--- multiplied by a factor that says how it was done: BaseFactor for a plain
--- completion, plus a bonus for each of these, capped at MaxFactor:
---   * the thread used: the hitman wrote to the client in the contract's
---     thread at least once;
---   * a meeting point used: one was set on the contract;
---   * a live handover: the completion is a delivery, not a kill;
---   * witness-free: no other player within WitnessRadius of the hitman, as
---     the server sees them, but the target and the placer.
--- The hitman's completion notice says the factor and what made it up.
--- Asked by the claim (Contracts.claimSlot) under its lock, before the
--- contract ends and drops its meeting point.

--- Whether nobody but the hitman, the target and the placer is within the
--- radius of the hitman, by the server's own positions. A hitman the server
--- cannot place (away, no ped) is not witness-free: it cannot be told.
---@return boolean
function Record.witnessFree(contract, hitmanCid)
    local hitman = Identity and Identity.byCitizenId(hitmanCid)
    if not hitman or not hitman.source then return false end
    local ok, here = pcall(function() return GetEntityCoords(GetPlayerPed(hitman.source)) end)
    if not ok or not here then return false end
    local radius = num(Feature.block(REPUTATION).WitnessRadius)
    -- Only those in the hitman's instance (routing bucket) saw anything:
    -- a player in an apartment shell at the same coordinates did not.
    local okB, bucket = pcall(GetPlayerRoutingBucket, hitman.source)
    if not okB or bucket == nil then return false end
    local parties = { [tostring(hitman.source)] = true }
    for _, cid in ipairs({ contract.target_cid, contract.creator_cid }) do
        local party = cid and Identity.byCitizenId(cid)
        if party and party.source then parties[tostring(party.source)] = true end
    end
    for _, src in ipairs(GetPlayers() or {}) do
        local okT, theirs = pcall(GetPlayerRoutingBucket, src)
        if not parties[tostring(src)] and (not okT or theirs == bucket) then
            local read, there = pcall(function() return GetEntityCoords(GetPlayerPed(src)) end)
            if read and there then
                local dx, dy, dz = num(there.x) - num(here.x), num(there.y) - num(here.y),
                    num(there.z) - num(here.z)
                if math.sqrt(dx * dx + dy * dy + dz * dz) <= radius then return false end
            end
        end
    end
    return true
end

--- The factor this completion's trust is multiplied by, and its parts, or
--- nil while reputation is off.
---@param contract table as read under the claim's lock
---@param hitmanCid string
---@param fulfilment string
---@return table|nil { factor, parts = { { label, value } } }
function Record.factorFor(contract, hitmanCid, fulfilment)
    local rules = Feature.block(REPUTATION)
    if rules.Enabled ~= true or type(contract) ~= 'table' then return nil end
    local factor = num(rules.BaseFactor)
    local parts = { { label = 'plain', value = factor } }
    local function add(label, bonus)
        bonus = num(bonus)
        if bonus <= 0 then return end
        factor = factor + bonus
        parts[#parts + 1] = { label = label, value = bonus }
    end

    local wrote = false
    local ok, rows = pcall(Storage.readMessages, contract.id, contract.id .. '|' .. hitmanCid)
    if ok and type(rows) == 'table' then
        for i = 1, #rows do
            if rows[i].from_cid == hitmanCid then wrote = true break end
        end
    end
    if wrote then add('thread', rules.ThreadBonus) end
    if contract.meeting_x ~= nil and contract.meeting_y ~= nil then add('meeting point', rules.MeetingBonus) end
    if fulfilment == CH.FULFILMENT.KIDNAPPING then add('live handover', rules.HandoverBonus) end
    if Record.witnessFree(contract, hitmanCid) then add('no witnesses', rules.WitnessFreeBonus) end

    local most = num(rules.MaxFactor)
    if factor > most then factor = most end
    if factor < 0 then factor = 0 end
    -- Two places, as the notice says it.
    factor = math.floor(factor * 100 + 0.5) / 100
    local earned = { factor = factor, parts = parts, capped = factor >= most or nil }
    earned.text = Record.describe(earned)
    return earned
end

--- The breakdown in words, for the completion notice: "Reputation x0.9
--- (plain 0.5, thread +0.2, meeting point +0.2)."
---@param earned table|nil from factorFor
---@return string|nil
function Record.describe(earned)
    if type(earned) ~= 'table' or type(earned.parts) ~= 'table' then return nil end
    local words = {}
    for i, part in ipairs(earned.parts) do
        words[#words + 1] = (i == 1 and '%s %s' or '%s +%s'):format(part.label, tostring(part.value))
    end
    return ('Reputation x%s (%s%s).'):format(tostring(earned.factor), table.concat(words, ', '),
        earned.capped and ', capped' or '')
end

--------------------------------------------------------------------------
-- The tiered board
--------------------------------------------------------------------------
--- Each tier is 'name, least reward, least level'. A contract's tier is the
--- highest one whose least reward its current payout reaches, priced as the
--- board orders it (Escrow.moneyValue of the slot being competed for). Below
--- the tier's level the card says it is locked and what level it needs,
--- and Accept is refused on the server (tier_locked) before anything is
--- taken. Off while trust is: a level is read from the same record.

--- One tier line, 'name, least reward, least level', read: nil when it is
--- not one. The name is what the card shows; nothing else reads it.
---@param line any
---@return table|nil { name, minReward, minLevel }
function Record.parseTier(line)
    if type(line) ~= 'string' or #line > 60 then return nil end
    local name, reward, level = line:match('^%s*([^%c<>,]-)%s*,%s*(%d+)%s*,%s*(%d+)%s*$')
    if not name or #name == 0 then return nil end
    reward, level = tonumber(reward), tonumber(level)
    if not reward or reward > 1000000000 or not level or level < 1 or level > 100 then return nil end
    return { name = name, minReward = math.floor(reward), minLevel = math.floor(level) }
end

--- The tiers' block while they are on, and progression with them; nil
--- otherwise.
local function tierRules()
    if not Feature.on(PROGRESSION) then return nil end
    return Feature.active(TIERS)
end

--- The tiers in force, highest least reward first.
---@return table[] { name, minReward, minLevel }
function Record.tiers()
    local cfg = tierRules()
    if not cfg then return {} end
    local out = {}
    for _, line in ipairs(type(cfg.Tiers) == 'table' and cfg.Tiers or {}) do
        local tier = Record.parseTier(line)
        if tier then out[#out + 1] = tier end
    end
    table.sort(out, function(a, b) return a.minReward > b.minReward end)
    return out
end

--- The tier a payout of this worth falls in, or nil.
---@param worth number
---@return table|nil
function Record.tierFor(worth)
    worth = tonumber(worth) or 0
    for _, tier in ipairs(Record.tiers()) do
        if worth >= tier.minReward then return tier end
    end
    return nil
end

--- Why this hitman may not take this contract, or nil.
---@param contract table
---@param record table|nil the viewer's Record.of
---@return table|nil { tier, level, yours }
function Record.tierLock(contract, record)
    if not tierRules() or type(contract) ~= 'table' then return nil end
    local worth = Escrow.moneyValue(contract.id, { slot = contract.next_slot or 1 })
    local tier = Record.tierFor(worth)
    if not tier then return nil end
    local level = Record.level(record)
    if level >= tier.minLevel then return nil end
    return { tier = tier.name, level = tier.minLevel, yours = level }
end

--- In front of an acceptance (App's roleplay gate): a hitman below the
--- tier's level is refused before anything is taken.
---@return string|nil err
---@return table|nil data
function Record.tierGate(name, actor, payload)
    if name ~= 'accept' or not tierRules() then return nil end
    local id = type(payload) == 'table' and Util.toId(payload.id) or nil
    local contract = id and Storage.readContract(id) or nil
    if not contract or contract.creator_cid == actor.cid or contract.target_cid == actor.cid then
        return nil
    end
    local lock = Record.tierLock(contract, Record.of(actor.cid))
    if lock then return CH.ERR.TIER_LOCKED, lock end
    return nil
end

--------------------------------------------------------------------------
-- The settings, the start-up check, the wiring and the tick
--------------------------------------------------------------------------

--- What each setting of Config.Record must be, by block, as the start holds
--- config.lua to it (Feature.check) and the panel's catalogue offers it.
--- Progression's Resource is an export called by name, edited in
--- config.lua only (Settings.DENY): filled with its block, never put back.
local TEXT = '^[^%c<>]+$'
Record.RULES = {
    Progression = {
        Enabled = { kind = 'switch' },
        TrustPerElimination = { kind = 'number', integer = true, min = 0, max = 10000 },
        TrustPerKidnapping = { kind = 'number', integer = true, min = 0, max = 10000 },
    },
    Reputation = {
        Enabled = { kind = 'switch' },
        BaseFactor = { kind = 'number', min = 0, max = 10 },
        ThreadBonus = { kind = 'number', min = 0, max = 10 },
        MeetingBonus = { kind = 'number', min = 0, max = 10 },
        HandoverBonus = { kind = 'number', min = 0, max = 10 },
        WitnessFreeBonus = { kind = 'number', min = 0, max = 10 },
        WitnessRadius = { kind = 'number', min = 1, max = 500 },
        MaxFactor = { kind = 'number', min = 0, max = 10 },
    },
    Tiers = {
        Enabled = { kind = 'switch' },
        CompletionsPerLevel = { kind = 'number', integer = true, min = 1, max = 1000 },
        Tiers = { kind = 'list', each = Record.parseTier, most = 20,
            says = "a list of tiers, each 'name, least reward, least level'" },
    },
    Heat = {
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
    PlacerRecord = {
        Enabled = { kind = 'switch' }, ShowForAnonymous = { kind = 'switch' },
        LookbackDays = { kind = 'number', integer = true, min = 1, max = 365 },
    },
}

--- The start-up check of every block of Config.Record: a block or a
--- setting missing is filled from defaults.lua, one that breaks its rule is
--- put back to the shipped value, and said. A feature that cannot work is
--- never refused a start: it is off.
---@param warn string[] where each correction is said
---@param filled string[]|nil where each setting filled in is named
function Record.validate(warn, filled)
    if type(Config.Record) ~= 'table' then Config.Record = {} end
    for _, name in ipairs({ 'Heat', 'PlacerRecord', 'Progression', 'Reputation', 'Tiers' }) do
        Feature.check('Record.' .. name, Record.RULES[name], warn, filled)
    end
    local rules = Feature.block(REPUTATION)
    if rules.BaseFactor > rules.MaxFactor then
        warn[#warn + 1] = ('Config.Record.Reputation.BaseFactor (%s) is above MaxFactor (%s). Using %s for both.')
            :format(tostring(rules.BaseFactor), tostring(rules.MaxFactor), tostring(rules.MaxFactor))
        rules.BaseFactor = rules.MaxFactor
    end
end

---@param deps table { storage, identity, audit, escrow, notify, contracts, projection, rpConsequences }
function Record.init(deps)
    Storage, Audit, Identity = deps.storage, deps.audit, deps.identity
    Escrow, Projection = deps.escrow, deps.projection
    Heat.init(deps)
    Placer.init(deps)
    if Projection and Projection.extenders then
        -- A card the viewer could take: the board's strangers' cards only.
        Projection.extenders.recordTiers = function(out, contract, viewerCid, role)
            if role ~= 'public' or not tierRules() then return end
            out.tierLocked = Record.tierLock(contract, Projection.recordFor(viewerCid))
        end
    end
end

--- The record's minute job (record.tick): heat aged out and the police
--- bulletin, and the anonymous placer records of contracts that ended
--- forgotten. Each does nothing while its feature is off.
function Record.tick()
    Heat.tick()
    Placer.sweep()
end

return Record
