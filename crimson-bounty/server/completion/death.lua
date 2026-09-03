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

--- When each player was last back on their feet, so a target cannot be
--- re-listed or re-claimed the instant they respawn (§14.39).
local respawnedAt = {}

--- Players the server has actually seen dead, and has not yet seen revived.
---
--- A revive is claimed by the reviving player's own client, and the only
--- check was that they are not dead *now* — which every living player
--- passes. Claiming one grants post-respawn immunity and wipes the damage
--- log, so anyone could stay permanently untargetable and erase the
--- attribution for a hunter who had just shot them, by claiming to have
--- come back from a death that never happened.
local seenDead = {}

--- Record that the server itself observed this player die.
function Death.markDead(cid)
    if cid then seenDead[cid] = os.time() end
end

function Death.wasSeenDead(cid)
    return cid ~= nil and seenDead[cid] ~= nil
end

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

--- Sample the condition of every live contract's target on its own clock.
---
--- Each damage event is credited with the drop since the last sample. On
--- the ten-second maintenance tick that meant a hunter who landed one shot
--- inherited whatever else had happened to the target in the meantime — an
--- explosion, a fall, someone else's firefight — none of which raise a
--- weapon damage event of their own to consume it first.
---
--- The cost is a narrow race: a sample landing between a shot connecting
--- and its event arriving erases that shot's evidence. The window is a few
--- milliseconds against a one-second period, the hunter's other shots still
--- register, and the alternative is crediting damage nobody can attribute.
local sampling = false

function Death.startSampler()
    if sampling then return false end
    sampling = true

    CreateThread(function()
        while true do
            Wait(Config.Completion.ConditionSampleMs or 1000)
            local ok = pcall(function()
                Death.watchTargets(Storage.allContracts())
            end)
            -- A sampler that dies takes attribution with it, and silently.
            if not ok then
                print('[crimson-bounty] condition sampler errored; retrying next tick')
            end
        end
    end)

    return true
end

--- When the server last saw a hunter close to their target.
---
--- [contractId] = { [hunterCid] = os.time() }
---
--- Observed here rather than claimed anywhere: this is what makes "a hunter
--- currently tracking you" (§6.1) a thing the server knows rather than a
--- synonym for "a hunter who accepted".
local seenNear = {}

--- Refresh baselines for every player who is the target of a live contract,
--- and note which of its hunters are near them.
--- Bounded by the number of live contracts, not the player count.
function Death.watchTargets(contracts)
    local watched = 0
    local radius = (Config.Informant.ProximityRadius or 120.0)
    local radius2 = radius * radius
    local now = os.time()

    for i = 1, #contracts do
        local c = contracts[i]
        if c.state == CB.STATE.ACTIVE or c.state == CB.STATE.ACCEPTED then
            local target = Identity.byCitizenId(c.target_cid)
            if target then
                Death.watch(target.cid, target.source, true)
                watched = watched + 1

                -- A target may die to something no hunter reported — a fall,
                -- a car, another player. Noting it here is what lets them
                -- claim the revive afterwards.
                if Identity.isTrulyDead(target.source) then Death.markDead(target.cid) end

                local targetCoords = GetEntityCoords(GetPlayerPed(target.source))
                local hunters = Storage.readHunters(c.id)
                for j = 1, #hunters do
                    local hunter = hunters[j]
                    if hunter.state == 'active' then
                        local actor = Identity.byCitizenId(hunter.hunter_cid)
                        if actor then
                            local distance2 = Util.dist2(
                                GetEntityCoords(GetPlayerPed(actor.source)), targetCoords)
                            if distance2 <= radius2 then
                                seenNear[c.id] = seenNear[c.id] or {}
                                seenNear[c.id][hunter.hunter_cid] = now
                            end
                        end
                    end
                end
            end
        end
    end

    return watched
end

--- Hunters the server has seen near this target recently.
---@param contractId string
---@return table set of hunter citizen ids
function Death.seenNear(contractId)
    local out = {}
    local window = (Config.Informant.ProximityWindowMinutes or 10) * 60
    local now = os.time()

    for hunterCid, at in pairs(seenNear[contractId] or {}) do
        if (now - at) <= window then out[hunterCid] = true end
    end
    return out
end

function Death.clearProximity(contractId)
    seenNear[contractId] = nil
end

--- Seconds since this player was last revived, or nil if never seen.
function Death.sinceRespawn(cid)
    local at = respawnedAt[cid]
    if not at then return nil end
    return os.time() - at
end

--- The most recent damage record from one specific attacker.
function Death.recordFor(victimCid, attackerCid)
    Death.prune(victimCid)
    local list = damage[victimCid]
    if not list then return nil end

    local best
    for i = 1, #list do
        if list[i].attackerCid == attackerCid then
            if not best or list[i].at > best.at then best = list[i] end
        end
    end
    return best
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
---@param killerServerId number|nil who the victim's own game says killed them
---@return integer opened number of pending completions opened
function Death.onVictimReport(victimSource, killerServerId)
    local victim = Identity.resolve(victimSource)
    if not victim then return 0 end

    -- The victim's account of who killed them, resolved and range-checked
    -- server-side. It is preferred over the damage log because a killer
    -- describing their own kill is the claim an attacker forges, while a
    -- victim has no reason to credit their killer falsely.
    local named
    if killerServerId then
        local killer = Identity.resolve(killerServerId)
        if killer and killer.cid ~= victim.cid then
            local distance = math.sqrt(Util.dist2(
                GetEntityCoords(GetPlayerPed(killerServerId)),
                GetEntityCoords(GetPlayerPed(victimSource))))
            if distance <= Config.Completion.MaxWeaponRange then
                named = killer.cid
            else
                Audit.rejected('killer_out_of_range', killer.cid, nil,
                    { victim = victim.cid, distance = math.floor(distance) })
            end
        end
    end

    -- The victim must actually be dead by the medical resource's own reading,
    -- not merely claiming to be, and a downed player is not a kill.
    if not Identity.isTrulyDead(victimSource) then
        Audit.rejected('death_report_not_dead', victim.cid, nil, {})
        return 0
    end

    -- The server has now seen this player dead, which is what a later
    -- revive claim from them is checked against.
    Death.markDead(victim.cid)

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

            -- Prefer the killer the victim named, when they are on this
            -- contract; otherwise fall back to the observed damage log.
            local hit
            if named and active[named] then
                -- The victim's word plus the server's own observation. A
                -- record was synthesised here when the damage log held
                -- nothing for the named killer, which credits a hunter the
                -- server never saw touch the target — the victim's client
                -- is the one naming them, and it is a client.
                hit = Death.recordFor(victim.cid, named)

                if not hit and not Config.Completion.RequireObservedDamage then
                    hit = {
                        attackerCid = named,
                        coords = GetEntityCoords(GetPlayerPed(victimSource)),
                    }
                elseif not hit then
                    Audit.rejected('named_killer_unobserved', named, contract.id,
                        { victim = victim.cid })
                end

                -- Falling back to the damage log would hand the kill to
                -- whoever else happened to be shooting, which is worse than
                -- paying nobody.
            else
                hit = Death.lastAttackerAmong(victim.cid, active)
            end

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
                    victim = victim.cid,
                    distance = hit.distance and math.floor(hit.distance) or nil,
                    source = named == hit.attackerCid and 'victim_report' or 'damage_log',
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

    -- Coming back requires having gone. Without this any living player can
    -- claim a revive, and each claim renews their post-respawn immunity and
    -- clears the damage recorded against them.
    if not seenDead[cid] then
        Audit.rejected('revive_claim_without_death', cid, nil, {})
        return 0
    end
    -- A revived player is back at full health; the next hit measures from
    -- there rather than being read as a decrease from their dying value.
    Death.resetHealth(cid, source)
    return Death.onRevived(cid)
end

function Death.onRevived(cid)
    respawnedAt[cid] = os.time()
    -- One death, one revive. A second claim has to wait for a second death.
    seenDead[cid] = nil

    -- A revive ends the fight. Damage recorded before it must not
    -- corroborate a death that happens afterwards, or a hunter who shot
    -- someone an hour ago inherits their next death.
    damage[cid] = nil

    local window = (Config.Completion.ProofWindowSeconds or 0) * 1000
    local now = GetGameTimer()

    local cleared = 0
    for key, record in pairs(pending) do
        -- A pending completion inside the proof window survives: the kill
        -- happened, and a target respawning must not erase it from under the
        -- hunter standing over the body.
        if record.victimCid == cid and (now - record.at) > window then
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

function Death.clearSeenDead(cid)
    seenDead[cid] = nil
end

function Death.clearPlayer(cid)
    damage[cid] = nil
    condition[cid] = nil
    respawnedAt[cid] = nil
    seenDead[cid] = nil
    for key, record in pairs(pending) do
        if record.victimCid == cid or record.hunterCid == cid then pending[key] = nil end
    end
end

return Death
