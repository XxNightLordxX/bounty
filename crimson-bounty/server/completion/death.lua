--- Death attribution (§7.4, §14.2).
---
--- Two independent signals must agree before a pending completion opens:
---   1. A damage record the server observed itself, via weaponDamageEvent.
---   2. The victim's death, read from the server-side medical state.
---
--- The hunter is never the source of either. A killer asserting "I killed
--- them" is not evidence and is dropped.

local Util = require_shared('util')

local Death = {}

local Storage, Identity, Contracts, Audit, Photo

--- Recent damage the server saw for itself: [victimCid] = { attackerCid, at, weapon, distance }
local damage = {}
--- Open pending completions: [contractId .. ':' .. hunterCid] = record
local pending = {}

function Death.init(deps)
    Storage, Identity, Contracts, Audit, Photo =
        deps.storage, deps.identity, deps.contracts, deps.audit, deps.photo
    damage, pending = {}, {}
end

--------------------------------------------------------------------------
-- Damage observation
--------------------------------------------------------------------------

--- Record a damage event the server observed. Called from the
--- weaponDamageEvent handler, whose arguments come from the engine rather
--- than from a script payload.
---@param attackerSource number
---@param victimSource number
---@param weaponHash number|nil
function Death.recordDamage(attackerSource, victimSource, weaponHash)
    local attacker = Identity.resolve(attackerSource)
    local victim = Identity.resolve(victimSource)
    if not attacker or not victim then return end
    if attacker.cid == victim.cid then return end

    local attackerCoords = GetEntityCoords(GetPlayerPed(attackerSource))
    local victimCoords = GetEntityCoords(GetPlayerPed(victimSource))
    local distance = math.sqrt(Util.dist2(attackerCoords, victimCoords))

    -- A hit reported from further than any weapon reaches did not happen.
    if distance > Config.Completion.MaxWeaponRange then
        Audit.rejected('damage_out_of_range', attacker.cid, nil, { distance = math.floor(distance) })
        return
    end

    local list = damage[victim.cid]
    if not list then
        list = {}
        damage[victim.cid] = list
    end

    list[#list + 1] = {
        attackerCid = attacker.cid,
        at = GetGameTimer(),
        weapon = weaponHash,
        distance = distance,
        coords = victimCoords,
    }

    -- Keep the window small: old damage cannot corroborate a later death.
    Death.prune(victim.cid)
end

function Death.prune(victimCid)
    local list = damage[victimCid]
    if not list then return end
    local cutoff = GetGameTimer() - Config.Completion.DeathReportWindowMs
    for i = #list, 1, -1 do
        if list[i].at < cutoff then table.remove(list, i) end
    end
    if #list == 0 then damage[victimCid] = nil end
end

--- The most recent corroborated damage from any of the given hunters.
---@param victimCid string
---@param hunterCids table set of citizen ids
---@return table|nil
function Death.lastAttackerAmong(victimCid, hunterCids)
    Death.prune(victimCid)
    local list = damage[victimCid]
    if not list then return nil end

    local best
    for i = 1, #list do
        local record = list[i]
        if hunterCids[record.attackerCid] then
            if not best or record.at > best.at then best = record end
        end
    end
    return best
end

--------------------------------------------------------------------------
-- Death reporting
--------------------------------------------------------------------------

--- Handle a death. The report is accepted only from the victim's own source
--- (§14.2); everything else about it is verified server-side.
---
---@param victimSource number the engine-supplied source of the reporting client
---@return integer opened number of pending completions opened
function Death.onVictimReport(victimSource)
    local victim = Identity.resolve(victimSource)
    if not victim then return 0 end

    -- The victim must actually be dead by the medical resource's own reading,
    -- not merely claiming to be, and a downed player is not a kill.
    if not Identity.isTrulyDead(victimSource) then
        Audit.rejected('death_report_not_dead', victim.cid, nil, {})
        return 0
    end

    local opened = 0
    local contracts = Storage.allContracts()

    for i = 1, #contracts do
        local contract = contracts[i]
        if contract.target_cid == victim.cid and contract.state == CB.STATE.ACCEPTED then
            local hunters = Storage.readHunters(contract.id)
            local active = {}
            for j = 1, #hunters do
                if hunters[j].state == 'active' then active[hunters[j].hunter_cid] = true end
            end

            local hit = Death.lastAttackerAmong(victim.cid, active)
            if hit then
                pending[contract.id .. ':' .. hit.attackerCid] = {
                    contractId = contract.id,
                    hunterCid  = hit.attackerCid,
                    victimCid  = victim.cid,
                    at         = GetGameTimer(),
                    coords     = hit.coords,
                    weapon     = hit.weapon,
                }
                Audit.action('death_attributed', hit.attackerCid, contract.id, {
                    victim = victim.cid, distance = math.floor(hit.distance),
                })
                opened = opened + 1
            else
                -- Died on a live contract, but not to a hunter. No payout,
                -- and worth recording: a target dying repeatedly with no
                -- attribution is a pattern staff may want to see.
                Audit.action('death_unattributed', nil, contract.id, { victim = victim.cid })
            end
        end
    end

    return opened
end

--- Fetch an open pending completion, if it has not expired.
---@return table|nil
function Death.getPending(contractId, hunterCid)
    local record = pending[contractId .. ':' .. hunterCid]
    if not record then return nil end
    if GetGameTimer() - record.at > (Config.Completion.PhotoTokenLifetimeSeconds * 1000) then
        pending[contractId .. ':' .. hunterCid] = nil
        return nil
    end
    return record
end

function Death.clearPending(contractId, hunterCid)
    pending[contractId .. ':' .. hunterCid] = nil
end

--- A revive invalidates every pending completion for that player: a target
--- who is back on their feet was not eliminated (§7.4).
function Death.onRevived(cid)
    local cleared = 0
    for key, record in pairs(pending) do
        if record.victimCid == cid then
            pending[key] = nil
            cleared = cleared + 1
        end
    end
    if cleared > 0 then
        Audit.action('pending_invalidated_by_revive', nil, nil, { victim = cid, cleared = cleared })
    end
    return cleared
end

--- Drop pending completions and damage records that have aged out.
--- Without this, entries only expire when their exact key happens to be
--- read again, so a busy server accumulates them indefinitely.
function Death.sweep()
    local now = GetGameTimer()
    local removed = 0

    for key, record in pairs(pending) do
        if now - record.at > (Config.Completion.PhotoTokenLifetimeSeconds * 1000) then
            pending[key] = nil
            removed = removed + 1
        end
    end

    local cutoff = now - Config.Completion.DeathReportWindowMs
    for cid, list in pairs(damage) do
        for i = #list, 1, -1 do
            if list[i].at < cutoff then table.remove(list, i) end
        end
        if #list == 0 then damage[cid] = nil end
    end

    return removed
end

function Death.pendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

function Death.clearPlayer(cid)
    damage[cid] = nil
    for key, record in pairs(pending) do
        if record.victimCid == cid or record.hunterCid == cid then pending[key] = nil end
    end
end

return Death
