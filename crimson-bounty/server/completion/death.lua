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

--- Condition last seen for a player, so a damage claim can be checked
--- against a decrease the server observed for itself.
---
--- Armour is tracked alongside health because a shot that lands on an
--- armoured target costs no health at all: corroborating on health alone
--- would reject real hits on anyone wearing a vest.
---
--- [cid] = { health = n, armour = n, at = ms }
local condition = {}

--- Read a player's current condition, server-side.
local function readCondition(source)
    local ped = GetPlayerPed(source)
    return {
        health = GetEntityHealth(ped) or 0,
        armour = (GetPedArmour and GetPedArmour(ped)) or 0,
        at = GetGameTimer(),
    }
end

--- Record a damage event.
---
--- Only `sender` is engine-supplied. The entity list, weapon and damage
--- figure inside the payload are written by that client, so a claim is
--- corroborated here against the victim's health as the server reads it: a
--- player who never fired cannot produce a decrease, and a claim without one
--- is discarded.
---@param attackerSource number
---@param victimSource number
---@param weaponHash number|nil
function Death.recordDamage(attackerSource, victimSource, weaponHash)
    local attacker = Identity.resolve(attackerSource)
    local victim = Identity.resolve(victimSource)
    if not attacker or not victim then return end
    if attacker.cid == victim.cid then return end

    -- Corroboration: the victim must actually have lost condition. Without
    -- this, a hunter standing anywhere within weapon range can fabricate a
    -- hit and inherit attribution for a death they had no part in.
    local current = readCondition(victimSource)
    local previous = condition[victim.cid]
    condition[victim.cid] = current

    -- No baseline means nothing to corroborate against, and the baseline is
    -- established the moment a contract on this player is accepted. Failing
    -- closed here is what stops a forged first event from landing before any
    -- real damage has been observed.
    if not previous then
        Audit.rejected('damage_no_baseline', attacker.cid, nil, { victim = victim.cid })
        return
    end

    local lost = (previous.health - current.health) + (previous.armour - current.armour)
    if lost <= 0 then
        Audit.rejected('damage_unsupported', attacker.cid, nil,
            { victim = victim.cid, health = current.health, armour = current.armour })
        return
    end

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
        -- How much condition the server saw disappear, so the hunter who did
        -- the most damage wins attribution rather than whoever claimed last.
        damage = lost,
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

--- The best-supported attributable damage from any of the given hunters.
---
--- Chosen by how much health the server actually saw the victim lose, not by
--- who reported last: attributing to the latest claimant hands the kill to
--- whoever fires an event a second after someone else's real shot.
---@param victimCid string
---@param hunterCids table set of citizen ids
---@return table|nil
function Death.lastAttackerAmong(victimCid, hunterCids)
    Death.prune(victimCid)
    local list = damage[victimCid]
    if not list then return nil end

    local totals, latest = {}, {}
    for i = 1, #list do
        local record = list[i]
        if hunterCids[record.attackerCid] then
            totals[record.attackerCid] = (totals[record.attackerCid] or 0) + (record.damage or 0)
            if not latest[record.attackerCid] or record.at > latest[record.attackerCid].at then
                latest[record.attackerCid] = record
            end
        end
    end

    local bestCid, bestDamage
    for cid, total in pairs(totals) do
        if not bestDamage or total > bestDamage then bestCid, bestDamage = cid, total end
    end

    return bestCid and latest[bestCid] or nil
end

--- Begin watching a player's health, so damage claims against them can be
--- corroborated. Called when a contract naming them is accepted, and topped
--- up on the maintenance tick.
---@param cid string
---@param source number
--- @param refresh boolean|nil update an existing baseline as well as seeding one
function Death.watch(cid, source, refresh)
    if not cid or not source then return false end

    -- The baseline is refreshed, not merely seeded: health and armour both
    -- recover over time, and a stale low baseline would make every later
    -- hit look like an increase and be rejected as uncorroborated.
    --
    -- Refreshing is safe against a hit landing in between, because a damage
    -- event arrives within milliseconds while this runs on the tick.
    if condition[cid] == nil or refresh then
        condition[cid] = readCondition(source)
    end
    return true
end

--- Refresh baselines for every player who is the target of a live contract.
--- Bounded by the number of live contracts, not the player count.
function Death.watchTargets(contracts)
    local watched = 0
    for i = 1, #contracts do
        local c = contracts[i]
        if c.state == CB.STATE.ACTIVE or c.state == CB.STATE.ACCEPTED then
            local target = Identity.byCitizenId(c.target_cid)
            if target then
                Death.watch(target.cid, target.source, true)
                watched = watched + 1
            end
        end
    end
    return watched
end

--- Reset the health baseline for a player, so a respawn is not read as a
--- decrease and the next real hit is measured from full.
function Death.resetHealth(cid, source)
    if source then
        condition[cid] = readCondition(source)
    else
        condition[cid] = nil
    end
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
---
--- The claim is verified against the medical state before anything is
--- cleared. Taking it on trust would let a target's client void a hunter's
--- legitimate pending kill by asserting a revive that never happened.
function Death.onRevivedVerified(source, cid)
    if Identity.isTrulyDead(source) then
        Audit.rejected('revive_claim_while_dead', cid, nil, {})
        return 0
    end
    -- A revived player is back at full health; the next hit measures from
    -- there rather than being read as a decrease from their dying value.
    Death.resetHealth(cid, source)
    return Death.onRevived(cid)
end

function Death.onRevived(cid)
    -- A revive ends the fight. Damage recorded before it must not
    -- corroborate a death that happens afterwards, or a hunter who shot
    -- someone an hour ago inherits their next death.
    damage[cid] = nil

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
    condition[cid] = nil
    for key, record in pairs(pending) do
        if record.victimCid == cid or record.hunterCid == cid then pending[key] = nil end
    end
end

return Death
