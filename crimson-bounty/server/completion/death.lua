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

--- When each attacker last landed a corroborated hit on each victim:
--- [victimCid] = { [attackerCid] = os.time() }. What an idle hold is
--- measured against, alongside being seen near the target.
local hitBy = {}

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

--- How long a player has to stay up, neither dead nor in last stand, for it
--- to count as a revive on its own. A defibrillator takes them from dead to
--- last stand, and sc-ambulance clears isdead first, then waits a second and
--- up to five more for the body to settle before it writes inlaststand. Read
--- in that gap, a revive voided the kill that put them down and gave a
--- target still on the ground five minutes' immunity.
---
--- A revive cut short is still a revive when a hit cut it short: somebody
--- put them down again, which the gap never does. It counts from when they
--- stood up, so the kill before it is void and the one after it waits out
--- the protection a revive gives. Dropped instead, both kills paid.
Death.REVIVE_CONFIRM_MS = 8000

--- [cid] = Util.monotonicMs() the server first saw them up after a death,
--- and saw them nowhere else since.
local upSince = {}

--- [cid] = Util.monotonicMs() of the last corroborated hit that landed while
--- they were up. A hit on somebody already down or dead cannot be what put
--- them down, and counting one read a defibrillator's patient, shot where
--- they lay, as a revive cut short.
local lastHitAt = {}

--- [cid] = true while a revive the client claimed waits to be confirmed.
local reviveClaims = {}

--- [cid] = Util.monotonicMs() a medic used a defibrillator on them.
---
--- The time up that follows is sc-ambulance clearing isdead before it writes
--- last stand, and nothing in the medical state tells it from a real revive:
--- a hit landing in it, even the hunter's own, read as a revive cut short —
--- the kill void, and the target, still on the ground, protected.
local defibAt = {}

--- How long after a defibrillator its gap can run: a second's wait and up
--- to five more for the body to settle, and some to spare.
Death.DEFIB_GAP_MS = 7000

--- [cid] = when a time up began that has ended while a hit that may have
--- ended it was still being checked (see the hit checks below).
local lastUp = {}

--- Hits waiting for the server to see the damage they did. [cid] = list, in
--- the order they were reported.
local inflight = {}

--- [cid] = the lowest condition already credited to a hit, so one drop is
--- never credited twice. Cleared once a reading rises above it.
local credited = {}

--- A defibrillator's own gap, which is no revive whatever lands in it.
local function shocked(cid, since)
    local at = defibAt[cid]
    return at ~= nil and since >= at - 1000 and since - at <= Death.DEFIB_GAP_MS
end

--- The end of a time up after a death, read as down again: a revive if a
--- hit is what ended it, and nothing if not.
local function endUpPeriod(cid)
    local since = upSince[cid]
    if not since then return end
    upSince[cid] = nil
    if shocked(cid, since) then
        defibAt[cid] = nil
        return
    end
    if not seenDead[cid] then return end
    if (lastHitAt[cid] or -math.huge) > since then
        Death.onRevived(cid, since)
        return
    end
    -- A hit whose damage the server has not seen yet may still be what ended
    -- it: the check that confirms it decides.
    for _, hit in ipairs(inflight[cid] or {}) do
        if hit.up and hit.at > since then
            lastUp[cid] = since
            return
        end
    end
end

function Death.init(deps)
    Storage, Identity, Contracts, Audit, Photo =
        deps.storage, deps.identity, deps.contracts, deps.audit, deps.photo
    damage, pending, hitBy = {}, {}, {}
    upSince, reviveClaims, lastHitAt = {}, {}, {}
    defibAt, lastUp, inflight, credited = {}, {}, {}, {}
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
        at = Util.monotonicMs(),
    }
end

--- Health and armour as one figure: a shot into a vest costs no health.
local function total(c) return (c.health or 0) + (c.armour or 0) end

--- How long after a hit its damage is looked for, and when.
Death.HIT_WINDOW_MS = 1000
local HIT_CHECKS_MS = { 150, 300, 500, 750, 1000 }

--- Put a corroborated hit on the record.
local function credit(cid, hit, lost, reading)
    credited[cid] = reading

    local list = damage[cid]
    if not list then
        list = {}
        damage[cid] = list
    end

    -- Landing a hit is working the contract, from however far away.
    hitBy[cid] = hitBy[cid] or {}
    hitBy[cid][hit.attackerCid] = os.time()

    list[#list + 1] = {
        attackerCid = hit.attackerCid,
        at = hit.at,
        weapon = hit.weapon,
        distance = hit.distance,
        coords = hit.coords,
        -- How much condition the server saw disappear, so the hunter who did
        -- the most damage wins attribution rather than whoever claimed last.
        damage = lost,
    }

    if hit.up then
        lastHitAt[cid] = math.max(lastHitAt[cid] or -math.huge, hit.at)
        -- The time up it ended was over before its damage was seen: a revive
        -- cut short all the same.
        local since = lastUp[cid]
        if since and hit.at > since and seenDead[cid] then
            lastUp[cid] = nil
            Death.onRevived(cid, since)
            if Identity.isTrulyDead(hit.source) then Death.markDead(cid) end
        end
    end

    -- Keep the window small: old damage cannot corroborate a later death.
    Death.prune(cid)
end

--- Look for the damage of the hits waiting on it, oldest first. A later hit
--- waits for an earlier one, so a drop goes to the hit that caused it and
--- not to whichever check looked first.
local function checkHits(cid)
    local list = inflight[cid]
    if not list then return end
    local now = Util.monotonicMs()
    while list[1] do
        local hit = list[1]
        local reading = total(readCondition(hit.source))
        local base = math.min(hit.base, credited[cid] or math.huge)
        if reading < base then
            table.remove(list, 1)
            credit(cid, hit, base - reading, reading)
        elseif now - hit.at >= Death.HIT_WINDOW_MS then
            table.remove(list, 1)
            Audit.rejected('damage_unsupported', hit.attackerCid, nil, { victim = cid })
        else
            break
        end
    end
    if not list[1] then
        inflight[cid] = nil
        lastUp[cid] = nil
    end
end

--- Record a damage event.
---
--- Only `sender` is engine-supplied. The entity list, weapon and damage
--- figure inside the payload are written by that client, so a claim is
--- corroborated here against the victim's health as the server reads it: a
--- player who never fired cannot produce a decrease, and a claim without one
--- is discarded.
---
--- The event arrives before the damage does. weaponDamageEvent is the
--- shooter's game asking for the hit, raised before it is sent on to the
--- victim's, and the victim's health reaches the server only once their game
--- has applied it. Read at the event, a lone shot always looked like no
--- damage at all: a target downed with one aimed round and finished with
--- another opened no kill. So a hit whose damage is not already showing is
--- held for up to a second and credited when the drop appears.
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

    local attackerCoords = GetEntityCoords(GetPlayerPed(attackerSource))
    local victimCoords = GetEntityCoords(GetPlayerPed(victimSource))
    local distance = math.sqrt(Util.dist2(attackerCoords, victimCoords))

    -- A hit reported from further than any weapon reaches did not happen.
    if distance > Config.Completion.MaxWeaponRange then
        Audit.rejected('damage_out_of_range', attacker.cid, nil, { distance = math.floor(distance) })
        return
    end

    local dead, down, known = Identity.deathState(victimSource)
    local hit = {
        attackerCid = attacker.cid,
        weapon = weaponHash,
        distance = distance,
        coords = victimCoords,
        at = Util.monotonicMs(),
        up = not (known and (dead or down)),
        source = victimSource,
    }

    local now = total(current)
    if credited[victim.cid] and now > credited[victim.cid] then credited[victim.cid] = nil end

    -- Already showing: the damage reached the server before the event did,
    -- as a burst's later rounds find the earlier ones'. Taken now, unless
    -- earlier hits are still waiting on theirs.
    local floor = math.min(total(previous), credited[victim.cid] or math.huge)
    if not inflight[victim.cid] and now < floor then
        credit(victim.cid, hit, floor - now, now)
        return
    end

    hit.base = math.min(now, credited[victim.cid] or math.huge)
    inflight[victim.cid] = inflight[victim.cid] or {}
    table.insert(inflight[victim.cid], hit)
    local cid = victim.cid
    for _, ms in ipairs(HIT_CHECKS_MS) do
        SetTimeout(ms, function() checkHits(cid) end)
    end
end

function Death.prune(victimCid)
    local list = damage[victimCid]
    if not list then return end
    local cutoff = Util.monotonicMs() - Config.Completion.DeathReportWindowMs
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
    -- hit look like an increase and be rejected as uncorroborated. A hit
    -- whose damage lands after a refresh is not lost to it: the check for
    -- it measures from the hit, not from the baseline.
    if condition[cid] == nil or refresh then
        condition[cid] = readCondition(source)
        -- Healed, armoured up or revived past what was credited: the next
        -- drop is measured from here.
        if credited[cid] and total(condition[cid]) > credited[cid] then credited[cid] = nil end
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
                -- And the revive after it: the client's own report can come
                -- too early (a medical script resurrects the ped while the
                -- player is still down) and be refused, and then never comes
                -- again. Up and alive by the medical state is the revive.
                -- Up means neither dead nor in last stand: a defibrillator
                -- takes a player from dead to last stand, and reading that
                -- as a revive voided the kill and gave a target still on
                -- the ground five minutes' immunity.
                -- And up for a while, not for one reading, or put down
                -- again by a hit: see REVIVE_CONFIRM_MS.
                local dead, lastStand, resolved = Identity.deathState(target.source)
                if resolved and not dead and not lastStand and Death.wasSeenDead(target.cid) then
                    local at = Util.monotonicMs()
                    -- Killed where they stood: the ped is dead and the
                    -- medical resource has not yet put them in last stand.
                    -- A blast, a fire, a car or a fall ends a revive with
                    -- no weapon event to say so. A defibrillator's gap never
                    -- reads like this: the body it works on was raised at
                    -- full health when it died.
                    local health = GetEntityHealth(GetPlayerPed(target.source)) or 0
                    if upSince[target.cid] and health <= 100
                        and not shocked(target.cid, upSince[target.cid]) then
                        Death.onRevived(target.cid, upSince[target.cid])
                    else
                        upSince[target.cid] = upSince[target.cid] or at
                        if at - upSince[target.cid] >= Death.REVIVE_CONFIRM_MS then
                            Death.onRevived(target.cid, upSince[target.cid])
                        end
                    end
                else
                    endUpPeriod(target.cid)
                end
                if Identity.isTrulyDead(target.source) then
                    Death.markDead(target.cid)
                end

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

--- The last time the server saw this hunter work this contract: near its
--- target, or landing a hit on them. nil when it never has.
---@param contractId string
---@param hunterCid string
---@param targetCid string
---@return integer|nil os.time()
function Death.lastEngaged(contractId, hunterCid, targetCid)
    local near = seenNear[contractId] and seenNear[contractId][hunterCid] or nil
    local hit = targetCid and hitBy[targetCid] and hitBy[targetCid][hunterCid] or nil
    if near and hit then return math.max(near, hit) end
    return near or hit
end

--- The last time this hunter landed a hit on this target. nil when never.
--- An attempt, where lastEngaged also counts merely being near.
---@param hunterCid string
---@param targetCid string
---@return integer|nil os.time()
function Death.lastHit(hunterCid, targetCid)
    return targetCid and hitBy[targetCid] and hitBy[targetCid][hunterCid] or nil
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
    credited[cid] = nil
    if source then
        condition[cid] = readCondition(source)
    else
        condition[cid] = nil
    end
end

--- A medic used a defibrillator on this player: the time up that follows is
--- its gap, not a revive (see defibAt).
---
--- Heard from sc-ambulance's own net event, so the same checks it makes are
--- made here: the sender is an on-duty medic standing over a patient who is
--- dead. Anyone else could otherwise mark a player, and have a revive cut
--- short read as the gap.
---@param medicSource number the sender, engine-supplied
---@param targetSource any the patient's server id, from the medic's client
---@return boolean noted
function Death.noteDefib(medicSource, targetSource)
    local patientSource = tonumber(targetSource)
    if not patientSource then return false end
    local medic = Identity.resolve(medicSource)
    local patient = Identity.resolve(patientSource)
    if not medic or not patient or medic.cid == patient.cid then return false end

    local jobs = (Config.Completion and Config.Completion.MedicJobs) or { ambulance = true }
    local job = medic.job or {}
    if not jobs[job.name] or job.onduty == false then return false end

    local dead = Identity.deathState(patientSource)
    if not dead then return false end

    local reach = ((Config.Completion and Config.Completion.DefibRange) or 3.0) + 2.0
    local gap = Util.dist2(GetEntityCoords(GetPlayerPed(medicSource)),
        GetEntityCoords(GetPlayerPed(patientSource)))
    if gap > reach * reach then return false end

    defibAt[patient.cid] = Util.monotonicMs()
    return true
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

    -- A time up before this death, ended by the hit that caused it, was a
    -- revive: settled first, so it cannot touch the kill opened below.
    endUpPeriod(victim.cid)

    -- The server has now seen this player dead, which is what a later
    -- revive claim from them is checked against.
    Death.markDead(victim.cid)

    local reportedAt = Util.monotonicMs()

    -- The finishing shot's damage can still be on its way to the server,
    -- and attributing now would give the kill to nobody, or to whoever hit
    -- them earlier. Once the hits have been checked, then.
    local waiting = inflight[victim.cid]
    if waiting and waiting[1] then
        local last = reportedAt
        for i = 1, #waiting do last = math.max(last, waiting[i].at + Death.HIT_WINDOW_MS) end
        SetTimeout(math.max(0, last - reportedAt) + 50, function()
            checkHits(victim.cid)
            local still = Identity.resolve(victimSource)
            if still and still.cid == victim.cid then
                Death.attributeDeath(victim, victimSource, named, reportedAt)
            end
        end)
        return 0
    end

    return Death.attributeDeath(victim, victimSource, named, reportedAt)
end

--- Open a pending kill on every live contract naming this victim, for the
--- hunter the death is credited to.
---@return integer opened
function Death.attributeDeath(victim, victimSource, named, reportedAt)
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
                    at         = reportedAt or Util.monotonicMs(),
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
--- Whether a pending kill has aged out: past its own lifetime and past any
--- photo token issued against it. A token is good for its whole lifetime
--- from issue, and the kill it proves used to lapse lifetime-from-death,
--- so a hunter who took their photo late in that window was told the
--- target had been revived.
local function aged(record, now)
    local lifetime = Config.Completion.PhotoTokenLifetimeSeconds * 1000
    if now - record.at <= lifetime then return false end
    return not (record.heldUntil and now <= record.heldUntil)
end

function Death.getPending(contractId, hunterCid)
    local record = pending[contractId .. ':' .. hunterCid]
    if not record then return nil end
    if aged(record, Util.monotonicMs()) then
        pending[contractId .. ':' .. hunterCid] = nil
        return nil
    end
    return record
end

--- Keep a pending kill for as long as a photo token issued against it. A
--- revive still clears it, since that clears the record outright.
---
--- Never past two lifetimes from the death itself. Each token the kill
--- still stood for extended it, and a token can be asked for while the
--- kill is held, so asking again every few minutes kept it alive for good:
--- a target revived out of sight of the watcher, or back after a restart
--- the revive was lost in, could be claimed an hour later.
---@return integer|nil heldUntil how long this hold keeps it, for the token to match
function Death.holdPending(contractId, hunterCid, untilMs)
    local record = pending[contractId .. ':' .. hunterCid]
    if not record then return nil end
    local cap = record.at + 2 * Config.Completion.PhotoTokenLifetimeSeconds * 1000
    local held = math.min(untilMs, cap)
    record.heldUntil = math.max(record.heldUntil or 0, held)
    return held
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
    -- Nor while still on the ground. A target shocked back into last stand
    -- claiming the revive voided the kill that put them there, and took the
    -- immunity with them.
    local _, lastStand, resolved = Identity.deathState(source)
    if resolved and lastStand then
        Audit.rejected('revive_claim_while_down', cid, nil, {})
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
    local function revive(since)
        Death.resetHealth(cid, source)
        return Death.onRevived(cid, since)
    end

    -- Up for long enough, by the server's own watch: taken at once.
    local at = Util.monotonicMs()
    if upSince[cid] and at - upSince[cid] >= Death.REVIVE_CONFIRM_MS then
        return revive(upSince[cid])
    end

    -- Otherwise asked again once a revive would have had to last. The client
    -- can see its own metadata, and a claim fired in the moment between a
    -- defibrillator clearing isdead and last stand being written passed
    -- every check above.
    if reviveClaims[cid] then return 0 end
    reviveClaims[cid] = true
    upSince[cid] = upSince[cid] or at
    SetTimeout(Death.REVIVE_CONFIRM_MS, function()
        reviveClaims[cid] = nil
        local actor = Identity.resolve(source)
        if not actor or actor.cid ~= cid or not seenDead[cid] then return end
        local dead, down, known = Identity.deathState(source)
        if known and (dead or down) then
            -- Down again: a revive only if a hit put them there.
            endUpPeriod(cid)
            if seenDead[cid] then Audit.rejected('revive_claim_not_up', cid, nil, {}) end
            return
        end
        -- Down and up again since the claim, by the watch: it is still
        -- waiting on this time up, and will decide it.
        if not upSince[cid] or upSince[cid] > at then
            Audit.rejected('revive_claim_not_up', cid, nil, {})
            return
        end
        revive(upSince[cid])
    end)
    return 0
end

---@param cid string
---@param since integer|nil Util.monotonicMs() they stood up; now when omitted
function Death.onRevived(cid, since)
    local now = Util.monotonicMs()
    since = math.min(since or now, now)
    -- From when they stood up, not from when that was confirmed: the
    -- protection a revive gives starts with the revive.
    respawnedAt[cid] = os.time() - math.floor((now - since) / 1000)
    -- One death, one revive. A second claim has to wait for a second death.
    seenDead[cid] = nil
    upSince[cid] = nil
    lastUp[cid] = nil
    defibAt[cid] = nil

    -- A revive ends the fight. Damage recorded before it must not
    -- corroborate a death that happens afterwards, or a hunter who shot
    -- someone an hour ago inherits their next death. What came after it,
    -- the hits of a revive cut short, is the next fight's.
    local list = damage[cid]
    if list then
        for i = #list, 1, -1 do
            if list[i].at <= since then table.remove(list, i) end
        end
        if #list == 0 then damage[cid] = nil end
    end

    local window = (Config.Completion.ProofWindowSeconds or 0) * 1000

    local cleared = 0
    for key, record in pairs(pending) do
        -- A pending completion inside the proof window survives: the kill
        -- happened, and a target respawning must not erase it from under the
        -- hunter standing over the body. Nor does one made after the revive.
        if record.victimCid == cid and record.at < since and (since - record.at) > window then
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
--- Forget when everyone last respawned, for the staff timer refresh.
---
--- Post-respawn immunity is a wait like any other, and it is the one that
--- makes testing the kill path slow: a tester who has just been revived
--- cannot be a valid target again until it lapses.
---@return integer cleared
function Death.clearRespawnImmunity()
    local cleared = 0
    for cid in pairs(respawnedAt) do
        respawnedAt[cid] = nil
        cleared = cleared + 1
    end
    return cleared
end

function Death.sweep()
    local now = Util.monotonicMs()
    local removed = 0

    for key, record in pairs(pending) do
        if aged(record, now) then
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

--- Forget a player who disconnected.
---
--- A pending kill goes with its HUNTER, not with its victim. It used to go
--- with either, so a target who closed the game while lying dead destroyed a
--- kill the server itself had attributed: the hunter, standing over the body,
--- was told there was no kill to verify. Nothing in the proof needs the victim
--- online — the body's position is recorded with the death, and the revive
--- check only applies to a victim who is still here to be revived. Quitting
--- is not a way out of a contract.
---
--- Nothing accumulates: a pending kill ages out of getPending and sweep on
--- the photo token lifetime, whoever is online.
function Death.clearPlayer(cid)
    damage[cid] = nil
    hitBy[cid] = nil
    condition[cid] = nil
    respawnedAt[cid] = nil
    seenDead[cid] = nil
    upSince[cid] = nil
    reviveClaims[cid] = nil
    lastHitAt[cid] = nil
    defibAt[cid] = nil
    lastUp[cid] = nil
    inflight[cid] = nil
    credited[cid] = nil
    for key, record in pairs(pending) do
        if record.hunterCid == cid then pending[key] = nil end
    end
end

return Death
