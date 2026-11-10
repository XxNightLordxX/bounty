--- Reputation earned in character (Config.Roleplay.Reputation, README
--- Roleplay features).
---
--- With it on, the progression trust a completion earns (Config.Progression,
--- TrustPerElimination / TrustPerKidnapping) is multiplied by a factor that
--- says how it was done: BaseFactor for a plain completion, plus a bonus for
--- each of these, capped at MaxFactor:
---   * the thread used: the hitman wrote to the client in the contract's
---     thread at least once;
---   * a meeting point used: one was set on the contract;
---   * a live handover: the completion is a delivery, not a kill;
---   * witness-free: no other player within WitnessRadius of the hitman, as
---     the server sees them, but the target and the placer.
--- The hitman's completion notice says the factor and what made it up.
---
--- Asked by the claim (Contracts.claimSlot) under its lock, before the
--- contract ends and drops its meeting point. Nothing here moves money or
--- stores anything; the trust itself is given by Progression.onCompleted.

local Feature = CrimsonBoot.require('server.lib.feature')

--- This feature's block of config (server/lib/feature.lua reads and checks it).
local BLOCK = 'Roleplay.Reputation'

local Reputation = {}

local Storage, Identity

local function num(value)
    local n = tonumber(value)
    if not n or n ~= n then return 0 end
    return n
end

function Reputation.init(deps)
    Storage, Identity = deps.storage, deps.identity
    if deps.contracts then deps.contracts.reputationFor = Reputation.factorFor end
end

--- Whether nobody but the hitman, the target and the placer is within the
--- radius of the hitman, by the server's own positions. A hitman the server
--- cannot place (away, no ped) is not witness-free: it cannot be told.
---@return boolean
function Reputation.witnessFree(contract, hitmanCid)
    local hitman = Identity and Identity.byCitizenId(hitmanCid)
    if not hitman or not hitman.source then return false end
    local ok, here = pcall(function() return GetEntityCoords(GetPlayerPed(hitman.source)) end)
    if not ok or not here then return false end
    local radius = num(Feature.block(BLOCK).WitnessRadius)
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
--- nil while the feature is off.
---@param contract table as read under the claim's lock
---@param hitmanCid string
---@param fulfilment string
---@return table|nil { factor, parts = { { label, value } } }
function Reputation.factorFor(contract, hitmanCid, fulfilment)
    local rules = Feature.block(BLOCK)
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
    if Reputation.witnessFree(contract, hitmanCid) then add('no witnesses', rules.WitnessFreeBonus) end

    local most = num(rules.MaxFactor)
    if factor > most then factor = most end
    if factor < 0 then factor = 0 end
    -- Two places, as the notice says it.
    factor = math.floor(factor * 100 + 0.5) / 100
    local earned = { factor = factor, parts = parts, capped = factor >= most or nil }
    earned.text = Reputation.describe(earned)
    return earned
end

--- The breakdown in words, for the completion notice: "Reputation x0.9
--- (plain 0.5, thread +0.2, meeting point +0.2)."
---@param earned table|nil from factorFor
---@return string|nil
function Reputation.describe(earned)
    if type(earned) ~= 'table' or type(earned.parts) ~= 'table' then return nil end
    local words = {}
    for i, part in ipairs(earned.parts) do
        words[#words + 1] = (i == 1 and '%s %s' or '%s +%s'):format(part.label, tostring(part.value))
    end
    return ('Reputation x%s (%s%s).'):format(tostring(earned.factor), table.concat(words, ', '),
        earned.capped and ', capped' or '')
end

--- What each setting must be, as the start holds config.lua to it
--- (Feature.check) and the panel's catalogue offers it.
Reputation.RULES = {
    Enabled = { kind = 'switch' },
    BaseFactor = { kind = 'number', min = 0, max = 10 },
    ThreadBonus = { kind = 'number', min = 0, max = 10 },
    MeetingBonus = { kind = 'number', min = 0, max = 10 },
    HandoverBonus = { kind = 'number', min = 0, max = 10 },
    WitnessFreeBonus = { kind = 'number', min = 0, max = 10 },
    WitnessRadius = { kind = 'number', min = 1, max = 500 },
    MaxFactor = { kind = 'number', min = 0, max = 10 },
}

---@param warn string[]
---@param filled string[]|nil
function Reputation.validate(warn, filled)
    local rules = Feature.check(BLOCK, Reputation.RULES, warn, filled)
    if rules.BaseFactor > rules.MaxFactor then
        warn[#warn + 1] = ('Config.Roleplay.Reputation.BaseFactor (%s) is above MaxFactor (%s). Using %s for both.')
            :format(tostring(rules.BaseFactor), tostring(rules.MaxFactor), tostring(rules.MaxFactor))
        rules.BaseFactor = rules.MaxFactor
    end
end

return Reputation
