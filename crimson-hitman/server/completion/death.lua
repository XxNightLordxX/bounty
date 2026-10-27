--- Death attribution (§7.4, §14.2).
---
--- Two independent signals must agree before a pending completion opens:
---   1. A damage record the server observed itself, via weaponDamageEvent.
---   2. The victim's death, read from the server-side medical state.
---
--- The hitman is never the source of either. A killer asserting "I killed
--- them" is not evidence and is dropped.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Death = {}

local Storage, Identity, Audit, Timing

--- Recent damage the server saw for itself: [victimCid] = { attackerCid, at, weapon, distance }
local damage = {}
--- Open pending completions: [contractId .. ':' .. hitmanCid] = record
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
--- attribution for a hitman who had just shot them, by claiming to have
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
--- a hit landing in it, even the hitman's own, read as a revive cut short —
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
--- never credited twice. Raised to a reading that rises above it: cleared,
--- a heal let a hit queued before it be credited with the drop another hit
--- had already been paid for.
local credited = {}

--- [cid] = when a hit was last credited with a lethal reading, so one death
--- is never credited twice.
local lethalAt = {}

--- [cid] = hits that landed on them while they were down and whose damage
--- never showed, kept a few seconds in case the victim's own report names
--- the shooter as their killer (see Death.attributeDeath).
local downHits = {}

--- [cid] = true while a check of their waiting hits is scheduled.
local polling = {}

--- [cid] = Util.monotonicMs() the server last read them as not dead: up, or
--- in last stand. A death report with nothing of the kind since the kill it
--- would open is the same death told again (see Death.attributeDeath).
local aliveAt = {}

--- [cid] = a death report waiting on its hits to be checked, so a victim
--- who leaves meanwhile is attributed with what is known rather than not
--- at all.
local deferred = {}

--- [cid] = a death the server saw for itself, waiting for the victim's own
--- report of it (see awaitReport). The report used to be the only way a
--- kill was ever opened, and it is the victim's client that sends it: a game
--- that crashed or quit in the second after the death, a report the flood
--- guard dropped, or a client that simply never sends it, and the hitman
--- standing over the body was told there was no kill to verify.
local unreported = {}

--- [contractId .. ':' .. hitmanCid] = { at, victimCid, hitmanCid }: the victim's own
--- game named this hitman as their killer, and the server never saw a hit
--- of theirs land (a blast, fire, a car). Kept a short while so Verify kill
--- can say so, rather than talk about a target who is only down.
local unobserved = {}

--- When this process started taking deaths (Death.noteStarted), on the
--- monotonic clock; nil until it has. Pending kills and the damage log are
--- held in memory only, so a restart between a kill and its proof loses
--- the kill, and the target's restarted game reports the death again
--- naming the killer, with no hit of theirs the server ever saw.
local startedAt = nil

--- How long after a start a death reported with its proof lost is put down
--- to the restart (KILL_LOST_RESTART), at least: long enough for a target's
--- game to load the restarted resource and report it. Never less than
--- Config.Completion.PhotoTokenLifetimeSeconds, past which a kill from
--- before the restart would have lapsed anyway.
local RESTART_REPORT_SECONDS = 60

--- A defibrillator's own gap, which is no revive whatever lands in it. The
--- gap is first seen within one sample of the shock; a time up that begins
--- later is not the gap, and taken for it, a real revive a hitman cut short
--- went unrecorded.
local function shocked(cid, since)
    local at = defibAt[cid]
    if at == nil then return false end
    local window = math.min(Death.DEFIB_GAP_MS,
        1000 + 2 * ((Config.Completion and Config.Completion.ConditionSampleMs) or 1000))
    return since >= at - 1000 and since - at <= window
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
    Storage, Identity, Audit =
        deps.storage, deps.identity, deps.audit
    -- Optional: times each sampler pass for /ch-diag (server/timing.lua).
    Timing = deps.timing
    damage, pending, hitBy = {}, {}, {}
    upSince, reviveClaims, lastHitAt = {}, {}, {}
    defibAt, lastUp, inflight, credited = {}, {}, {}, {}
    lethalAt, deferred, downHits, polling = {}, {}, {}, {}
    aliveAt, unreported, unobserved = {}, {}, {}
    startedAt = nil
end

--- Note that this process has started taking deaths (main.lua's start).
function Death.noteStarted()
    startedAt = Util.monotonicMs()
end

--- Whether a death reported now, with no hit of the named killer's seen,
--- is one whose proof a restart lost: reported in the window after this
--- start, of somebody this process has never seen alive. A death after
--- the start follows a time alive the sampler or a hit saw, and is
--- refused as unseen like any other.
---@param victimCid string
---@return boolean
local function lostToRestart(victimCid)
    if not startedAt or aliveAt[victimCid] then return false end
    local window = math.max(RESTART_REPORT_SECONDS,
        tonumber(Config.Completion.PhotoTokenLifetimeSeconds) or 0) * 1000
    return Util.monotonicMs() - startedAt <= window
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

--- Players some live contract names as its target, by server id:
--- [source] = cid. Rebuilt by every sampler pass (watchTargets), and added
--- to by Death.watch the moment a contract is accepted, so a hit in the
--- second before the next pass still counts.
---
--- What decides whether a hit is looked at at all. Every hit between any
--- two players reached recordDamage: two framework lookups and a death-state
--- read per round, a 50 ms poll on the victim, and 'rejected' audit rows,
--- mirrored to the staff webhook, for every police shootout and gang fight
--- in the city. Nothing reads damage on anybody no contract names.
local watching = {}

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

--- How long after a hit its damage is looked for, and how often. Often:
--- sc-ambulance clears the record of who last damaged its player within a
--- tenth of a second of every hit, and that record is what says whose a
--- drop is.
Death.HIT_WINDOW_MS = 1000
Death.HIT_POLL_MS = 50

--- How many of one attacker's hits may wait on one victim. A client can send
--- damage events as fast as it likes, and each waiting hit is looked at on
--- every check.
Death.MAX_WAITING_PER_ATTACKER = 24

--- How long a hit on somebody down, whose damage never showed, is kept for
--- their death report.
Death.DOWN_HIT_KEEP_MS = 10000

--- A hit that landed while they were up ended that time up: if it was over
--- before the damage was seen, it was a revive cut short all the same. True
--- whoever fired, so it holds for a drop nobody is credited with, too.
local function cutShort(cid, hit)
    if not hit.up then return end
    lastHitAt[cid] = math.max(lastHitAt[cid] or -math.huge, hit.at)
    local since = lastUp[cid]
    if since and hit.at > since and seenDead[cid] then
        lastUp[cid] = nil
        Death.onRevived(cid, since)
        if Identity.isTrulyDead(hit.source) then Death.markDead(cid) end
    end
end

--- Put a corroborated hit on the record.
local function credit(cid, hit, lost, reading)
    credited[cid] = reading
    if reading <= 100 then lethalAt[cid] = Util.monotonicMs() end

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
        -- How much condition the server saw disappear, so the hitman who did
        -- the most damage wins attribution rather than whoever claimed last.
        damage = lost,
    }

    cutShort(cid, hit)

    -- Keep the window small: old damage cannot corroborate a later death.
    Death.prune(cid)
end

--- Who the victim's own game says last damaged them, as the entity that
--- did it; nil where this server cannot say. Synced with the health it
--- explains, from the victim's side, so a shooter cannot write it. 0 is
--- "cannot say" too: sc-ambulance clears it within a tenth of a second of
--- every hit, so 0 is what it reads nearly all the time, whoever fired.
local function damageSource(victimSource)
    if type(GetPedSourceOfDamage) ~= 'function' then return nil end
    local ok, src = pcall(function() return GetPedSourceOfDamage(GetPlayerPed(victimSource)) end)
    if not ok or src == 0 then return nil end
    return src
end

local function pedOf(source)
    local ok, ped = pcall(GetPlayerPed, source)
    return ok and ped or nil
end

--- Whether the entity the victim's game names is this attacker: their ped,
--- or the vehicle they are in.
local function isAttacker(hit, src)
    local ped = pedOf(hit.attackerSource)
    if not ped or ped == 0 then return false end
    if ped == src then return true end
    local ok, vehicle = pcall(GetVehiclePedIsIn, ped, false)
    return ok and vehicle ~= nil and vehicle ~= 0 and vehicle == src
end

--- Which of the waiting hits a drop belongs to: the oldest by the attacker
--- the victim's game names, or the oldest of all where it cannot say. nil:
--- it names somebody none of them is — an NPC, another player.
---
--- Oldest-first alone gave a drop to whichever hit was at the head of the
--- queue, whether it had done damage or not: a round into the target's car,
--- a pellet that missed, or an event a rival sent a moment before a real
--- shot took that shot's damage, and the kill with it.
---
--- Where the victim's game cannot say (sc-ambulance has cleared it, as it
--- nearly always has), the oldest takes it only if every hit waiting on it is
--- one attacker's. Between two attackers it is nobody's: a rival sending an
--- event a moment before an honest shot took that shot's damage and the kill.
---@return integer|nil index
---@return boolean|nil ambiguous
local function ownerOf(list, candidates, src)
    if src == nil then
        local first = list[candidates[1]].attackerCid
        for k = 2, #candidates do
            if list[candidates[k]].attackerCid ~= first then return nil, true end
        end
        return candidates[1]
    end
    for _, i in ipairs(candidates) do
        if isAttacker(list[i], src) then return i end
    end
    return nil
end

--- Keep a hit on a downed victim for their death report (see checkHits).
--- In the order they landed, so the ones past keeping come off the front:
--- a client sending events at somebody down for minutes grew this without
--- end.
local function keepDownHit(cid, hit, now)
    local kept = downHits[cid] or {}
    downHits[cid] = kept
    while kept[1] and now - kept[1].at > Death.DOWN_HIT_KEEP_MS do table.remove(kept, 1) end
    kept[#kept + 1] = hit
end

--- Look for the damage of the hits waiting on it.
local function checkHits(cid)
    local list = inflight[cid]
    if not list or not list[1] then
        inflight[cid] = nil
        return
    end
    local now = Util.monotonicMs()
    local victimSource = list[1].source
    local reading = total(readCondition(victimSource))

    -- A drop some waiting hit has not had yet.
    local candidates = {}
    for i = 1, #list do
        if reading < math.min(list[i].base, credited[cid] or math.huge) then
            candidates[#candidates + 1] = i
        end
    end
    if candidates[1] then
        local i, ambiguous = ownerOf(list, candidates, damageSource(victimSource))
        if i then
            local hit = table.remove(list, i)
            credit(cid, hit, math.min(hit.base, credited[cid] or math.huge) - reading, reading)
        elseif ambiguous then
            -- Nobody's for certain. Consumed, so no later check hands it to
            -- one of them; the hits stay waiting, and a finishing one is
            -- still kept for the victim's report to name. Whoever fired, a
            -- hit that landed on them standing ended that time up: left
            -- unrecorded, a second shooter's event beside the real one kept
            -- the kill the revive undid and lifted the revive's protection.
            credited[cid] = reading
            for _, k in ipairs(candidates) do cutShort(cid, list[k]) end
            Audit.rejected('damage_ambiguous', nil, nil, { victim = cid })
        else
            -- Damage the victim's game puts down to somebody none of the
            -- waiting hits is. Theirs, and no hit still waiting takes it.
            credited[cid] = reading
            if reading <= 100 then lethalAt[cid] = now end
            Audit.rejected('damage_unattributed', nil, nil, { victim = cid })
        end
    end

    -- Hits whose damage never showed. They are in the order they came, so
    -- the ones past their window are at the front.
    while list[1] and now - list[1].at >= Death.HIT_WINDOW_MS do
        local hit = table.remove(list, 1)
        Audit.rejected('damage_unsupported', hit.attackerCid, nil, { victim = cid })
        -- Landed on somebody down who is dead now: it may be the shot that
        -- finished them, on a body sc-ambulance raised at full health in the
        -- same frame — in a car, on a stretcher — so the lethal reading never
        -- reached the server. A bleed-out reads exactly the same from here,
        -- so it is kept for the victim's own report to say which.
        if hit.down and (lethalAt[cid] or -math.huge) < hit.at then
            keepDownHit(cid, hit, now)
        end
    end

    if not list[1] then
        inflight[cid] = nil
        lastUp[cid] = nil
    end
end

--- Check a victim's waiting hits until none are left.
local function poll(cid)
    if polling[cid] then return end
    polling[cid] = true
    local function tick()
        polling[cid] = nil
        local ok, err = pcall(checkHits, cid)
        if not ok then
            inflight[cid] = nil
            Audit.rejected('error_checkHits', nil, nil, { victim = cid, error = tostring(err) })
            return
        end
        if inflight[cid] then
            polling[cid] = true
            SetTimeout(Death.HIT_POLL_MS, tick)
        end
    end
    SetTimeout(Death.HIT_POLL_MS, tick)
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
    -- Nobody a live contract names: left alone, before anything is asked of
    -- the framework. Unless the server is watching them come back from a
    -- death (a revive cut short is a revive, which their next contract's
    -- respawn protection is measured from), and that is asked only while
    -- somebody is.
    if not watching[victimSource] then
        if next(seenDead) == nil and next(upSince) == nil then return end
        local who = Identity.resolve(victimSource)
        if not who or not (seenDead[who.cid] or upSince[who.cid]) then return end
    end

    local attacker = Identity.resolve(attackerSource)
    local victim = Identity.resolve(victimSource)
    if not attacker or not victim then return end
    if attacker.cid == victim.cid then return end

    -- Corroboration: the victim must actually have lost condition. Without
    -- this, a hitman standing anywhere within weapon range can fabricate a
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
    if known and not dead then aliveAt[victim.cid] = Util.monotonicMs() end
    local hit = {
        attackerCid = attacker.cid,
        attackerSource = attackerSource,
        weapon = weaponHash,
        distance = distance,
        coords = victimCoords,
        at = Util.monotonicMs(),
        up = not (known and (dead or down)),
        down = known and down and not dead,
        source = victimSource,
    }

    local now = total(current)
    if credited[victim.cid] and now > credited[victim.cid] then credited[victim.cid] = now end

    -- Every event is a reading: a drop that landed before it is settled now,
    -- while the victim's game still names who did it, and before this hit
    -- could be mistaken for it.
    if inflight[victim.cid] then
        checkHits(victim.cid)
        now = total(readCondition(victimSource))
        if credited[victim.cid] and now > credited[victim.cid] then credited[victim.cid] = now end
    end

    -- Already showing: the damage reached the server before the event did,
    -- as a burst's later rounds find the earlier ones'. Taken now, unless
    -- earlier hits are still waiting on theirs — and only if the victim's
    -- game does not put it down to somebody else. If it does, that drop is
    -- theirs, and this hit waits for its own.
    local floor = math.min(total(previous), credited[victim.cid] or math.huge)
    if not inflight[victim.cid] and now < floor then
        local src = damageSource(victimSource)
        if src == nil or isAttacker(hit, src) then
            credit(victim.cid, hit, floor - now, now)
            return
        end
        credited[victim.cid] = now
        Audit.rejected('damage_unattributed', nil, nil, { victim = victim.cid })
    end

    hit.base = math.min(now, credited[victim.cid] or math.huge)
    local list = inflight[victim.cid] or {}
    inflight[victim.cid] = list

    -- One attacker's flood: the oldest of theirs gives way. The newest is kept,
    -- as it carries the victim's state now.
    local mine, oldest = 0, nil
    for i = 1, #list do
        if list[i].attackerCid == attacker.cid then
            mine = mine + 1
            oldest = oldest or i
        end
    end
    if mine >= Death.MAX_WAITING_PER_ATTACKER and oldest then
        table.remove(list, oldest)
        if mine == Death.MAX_WAITING_PER_ATTACKER then
            Audit.rejected('flood_damage', attacker.cid, nil, { victim = victim.cid })
        end
    end

    table.insert(list, hit)
    poll(victim.cid)
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

--- The best-supported attributable damage from any of the given hitmen.
---
--- Chosen by how much health the server actually saw the victim lose, not by
--- who reported last: attributing to the latest claimant hands the kill to
--- whoever fires an event a second after someone else's real shot.
---@param victimCid string
---@param hitmanCids table set of citizen ids
---@return table|nil
function Death.lastAttackerAmong(victimCid, hitmanCids)
    Death.prune(victimCid)
    local list = damage[victimCid]
    if not list then return nil end

    local totals, latest = {}, {}
    for i = 1, #list do
        local record = list[i]
        if hitmanCids[record.attackerCid] then
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
    watching[source] = cid

    -- The baseline is refreshed, not merely seeded: health and armour both
    -- recover over time, and a stale low baseline would make every later
    -- hit look like an increase and be rejected as uncorroborated. A hit
    -- whose damage lands after a refresh is not lost to it: the check for
    -- it measures from the hit, not from the baseline.
    if condition[cid] == nil or refresh then
        condition[cid] = readCondition(source)
        -- Healed, armoured up or revived past what was credited: the next
        -- drop is measured from here.
        if credited[cid] and total(condition[cid]) > credited[cid] then credited[cid] = total(condition[cid]) end
    end
    return true
end

--- Sample the condition of every live contract's target on its own clock.
---
--- A hit whose damage is already showing is credited with the drop since
--- the last sample. On the ten-second maintenance tick that meant a hitman
--- who landed one shot inherited whatever else had happened to the target in
--- the meantime — an explosion, a fall, someone else's firefight — none of
--- which raise a weapon damage event of their own to consume it first. The
--- victim's own game naming who damaged them now keeps those out wherever
--- the server can read it.
---
--- A sample landing between a hit's event and its damage no longer erases
--- the hit: the check for it measures from the hit, not from the sample.
local sampling = false

function Death.startSampler()
    if sampling then return false end
    sampling = true

    -- Live contracts only: the pass looks at nothing else, and the whole
    -- table holds every finished contract the retention keeps (thirty days
    -- of them as shipped). On mysql that was every row of it, every second.
    --
    -- And every roster in one read alongside: one each was 1 + N awaited
    -- queries a second on mysql, for as long as the server ran.
    local function pass()
        local live = Storage.liveContracts()
        Death.watchTargets(live, Storage.liveHitmen and Storage.liveHitmen() or nil)
    end

    CreateThread(function()
        while true do
            Wait(Config.Completion.ConditionSampleMs or 1000)
            local ok
            if Timing then
                ok = Timing.run('death.sampler', pass)
            else
                ok = pcall(pass)
            end
            -- A sampler that dies takes attribution with it, and silently.
            if not ok then
                Log.debug('condition sampler errored; retrying next tick')
            end
        end
    end)

    return true
end

--- When the server last saw a hitman close to their target, within
--- Config.Informant.ProximityRadius.
---
--- [contractId] = { [hitmanCid] = os.time() }
---
--- Observed here rather than claimed anywhere: an idle hold's clock is reset
--- by a hitman working the contract (Death.lastEngaged), and being near the
--- target is half of what working it means.
local seenNear = {}

--- How long a death the server saw for itself waits for the victim's own
--- report before it is attributed without one. The client looks once a
--- second and its report is on the wire a moment later, so an honest report
--- has long arrived by then, and wins: it is the one that can name the
--- killer. The hits are settled by then too (HIT_WINDOW_MS).
Death.UNREPORTED_WAIT_MS = Death.HIT_WINDOW_MS + 3000

--- The server saw this target die and nobody has reported it yet.
---
--- The report is the victim's client, and the victim is the hitman's
--- adversary: a client that never sends it (a cheat menu stopping this
--- resource, one blocked event), a game that crashed or quit in the second
--- after the death, a report the flood guard dropped, and the kill paid
--- nobody however clean it was. So the death is attributed without it, the
--- way a report naming nobody is: from the damage log the server built for
--- itself, to whoever on the contract it saw do the most damage. A hitman
--- is still never the source of either signal.
---
--- Once per death. Only the first sighting of one waits (the sampler asks
--- wasSeenDead, which a report also sets and only a revive clears), a report
--- arriving in the wait stands it down, and one arriving after it finds the
--- kill already open (attributeDeath, the same death told again).
---@param victim table the target, resolved
local function awaitReport(victim)
    local cid = victim.cid
    local entry = {
        victim = victim, source = victim.source, at = Util.monotonicMs(),
        -- Where the body is, as a report would have said.
        coords = GetEntityCoords(GetPlayerPed(victim.source)),
    }
    unreported[cid] = entry
    SetTimeout(Death.UNREPORTED_WAIT_MS, function()
        if unreported[cid] ~= entry then return end
        unreported[cid] = nil
        local ok, err = pcall(function()
            -- Still this death: never revived since (onRevived clears the
            -- wait, and seenDead), still dead, and still the same player
            -- behind the source.
            if not seenDead[cid] then return end
            local actor = Identity.resolve(entry.source)
            if not actor or actor.cid ~= cid or not Identity.isTrulyDead(entry.source) then return end
            -- Staff can see which kills opened with no word from the victim.
            Audit.action('death_unreported', nil, nil, { victim = cid })
            checkHits(cid)
            Death.attributeDeath(victim, entry.source, nil, entry.at, entry.coords)
        end)
        if not ok then
            Audit.rejected('error_unreported_death', cid, nil, { error = tostring(err) })
        end
    end)
end

--- Who is in the city as whom: [cid] -> server id, from the map the bridges
--- keep of every loaded character (Bridges.install sets it). Nil without the
--- bridges, as on a test's own stack.
---@type fun(cid: string): number|nil
Death.sourceOf = nil

--- The server id a party to a live contract is in the city as, or nil.
---
--- From the bridges' map: free. The sampler used to ask qbx_core for the
--- whole player record of every target and every active hitman, once a
--- second each, only to read the server id out of it. Somebody the map does
--- not have is asked of qbx_core's own lookup: for a party who is offline,
--- which is a contract's ordinary state while it waits for them, that
--- answers nil and carries nothing; one it does find is a login the map has
--- not heard of yet, and is watched all the same, so no hit on a target
--- waits on the map. Not through Identity.byCitizenId, whose fallback asks
--- for every player online until its lookup has once been seen to work.
---@param cid string|nil
---@return number|nil
local function inCity(cid)
    cid = Util.toCitizenId(cid)
    if not cid then return nil end
    if not Death.sourceOf then
        local actor = Identity.byCitizenId(cid)
        return actor and actor.source or nil
    end
    local src = Death.sourceOf(cid)
    if src then return src end
    local ok, player = pcall(function() return exports.qbx_core:GetPlayerByCitizenId(cid) end)
    local record = ok and type(player) == 'table' and player.PlayerData or nil
    local found = record and record.citizenid == cid and tonumber(record.source) or nil
    return (found and found > 0) and found or nil
end

--- Refresh baselines for every player who is the target of a live contract,
--- and note which of its hitmen are near them.
--- Bounded by the number of live contracts, not the player count.
---
--- It needs only who is where: a citizen id and the server id they are on.
--- The record qbx_core would hand over for each is not read at all; the
--- death state comes from the medical resource, or field by field from the
--- metadata (Identity.deathState).
---@param contracts table[]
---@param rosters table<string, table[]>|nil each contract's hitmen, read
---   once for the pass (Storage.liveHitmen); read per contract without it
function Death.watchTargets(contracts, rosters)
    local watched = 0
    local radius = (Config.Informant.ProximityRadius or 120.0)
    local radius2 = radius * radius
    local now = os.time()
    -- Who is a target now. Swapped in whole at the end, so a pass that
    -- throws part-way leaves the last complete one standing.
    local targets = {}

    -- Whose death a kill could complete a contract on: named by a live one
    -- placed under 'either'. Asked before the walk, because one target can
    -- be named by several, and the first of them to mark the death seen
    -- would leave nothing fresh for the second.
    local killable = {}
    for i = 1, #contracts do
        local c = contracts[i]
        if (c.state == CH.STATE.ACTIVE or c.state == CH.STATE.ACCEPTED)
            and Util.fulfilmentRule(c) == CH.FULFILMENT_RULE.EITHER then
            killable[c.target_cid] = true
        end
    end

    for i = 1, #contracts do
        local c = contracts[i]
        if c.state == CH.STATE.ACTIVE or c.state == CH.STATE.ACCEPTED then
            local targetSource = inCity(c.target_cid)
            -- What awaitReport needs, and all attributeDeath reads: who and
            -- where. awaitReport resolves the source again before it acts.
            local target = targetSource and { cid = c.target_cid, source = targetSource } or nil
            if target then
                Death.watch(target.cid, target.source, true)
                targets[target.source] = target.cid
                watched = watched + 1

                -- A target may die to something no hitman reported — a fall,
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
                if resolved and not dead then aliveAt[target.cid] = Util.monotonicMs() end
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
                    -- Last stand is where a defibrillator leaves them: its
                    -- mark has done its work, and must not hide a revive
                    -- from there.
                    if resolved and lastStand and not dead then defibAt[target.cid] = nil end
                end
                -- isTrulyDead, from the reading above rather than a second
                -- one: nothing yields in between, so it could only agree.
                if resolved and dead and not (Config.Completion.RejectLastStand and lastStand) then
                    -- Seen dead before this is the same death: reported, or
                    -- already waiting on its report.
                    --
                    -- Marked whatever the contract, since the revive that
                    -- follows is what a new contract's respawn protection
                    -- is measured from. Attributed without a report only
                    -- where a kill could complete something: a target named
                    -- only by live transfers has no kill to open.
                    local fresh = not Death.wasSeenDead(target.cid)
                    Death.markDead(target.cid)
                    if fresh and killable[target.cid] then awaitReport(target) end
                end

                local targetCoords = GetEntityCoords(GetPlayerPed(target.source))
                local hitmen = rosters and (rosters[c.id] or {}) or Storage.readHitmen(c.id)
                for j = 1, #hitmen do
                    local hitman = hitmen[j]
                    if hitman.state == 'active' then
                        local hitmanSource = inCity(hitman.hitman_cid)
                        if hitmanSource then
                            local distance2 = Util.dist2(
                                GetEntityCoords(GetPlayerPed(hitmanSource)), targetCoords)
                            if distance2 <= radius2 then
                                seenNear[c.id] = seenNear[c.id] or {}
                                seenNear[c.id][hitman.hitman_cid] = now
                            end
                        end
                    end
                end
            end
        end
    end

    -- Death.watch added each of these as it went, and a contract accepted
    -- while this pass ran is added by its own watch after the swap.
    watching = targets
    return watched
end

function Death.clearProximity(contractId)
    seenNear[contractId] = nil
end

--- The last time the server saw this hitman work this contract: near its
--- target, or landing a hit on them. nil when it never has.
---@param contractId string
---@param hitmanCid string
---@param targetCid string
---@return integer|nil os.time()
function Death.lastEngaged(contractId, hitmanCid, targetCid)
    local near = seenNear[contractId] and seenNear[contractId][hitmanCid] or nil
    local hit = targetCid and hitBy[targetCid] and hitBy[targetCid][hitmanCid] or nil
    if near and hit then return math.max(near, hit) end
    return near or hit
end

--- The last time this hitman landed a hit on this target. nil when never.
--- An attempt, where lastEngaged also counts merely being near.
---@param hitmanCid string
---@param targetCid string
---@return integer|nil os.time()
function Death.lastHit(hitmanCid, targetCid)
    return targetCid and hitBy[targetCid] and hitBy[targetCid][hitmanCid] or nil
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

    -- As sc-ambulance asks: an on-duty medic (MedicJobs = false for its
    -- RequireEMS = false), holding the device, over a patient who is dead.
    local jobs = Config.Completion and Config.Completion.MedicJobs
    if jobs == nil then jobs = { ambulance = true } end
    if jobs ~= false then
        local job = medic.job or {}
        if type(jobs) ~= 'table' or not jobs[job.name] or job.onduty ~= true then return false end
    end

    local device = (Config.Completion and Config.Completion.DefibItem) or 'defibrillator'
    local okItem, held = pcall(function()
        return exports.ox_inventory:GetItem(medicSource, device, nil, true)
    end)
    if not okItem or (tonumber(held) or 0) < 1 then return false end

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

    -- Their own word, which can name the killer, takes the place of the
    -- server's attributing this death without it (awaitReport).
    unreported[victim.cid] = nil

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
    local victimCoords = GetEntityCoords(GetPlayerPed(victimSource))
    local waiting = inflight[victim.cid]
    if waiting and waiting[1] then
        local last = reportedAt
        for i = 1, #waiting do last = math.max(last, waiting[i].at + Death.HIT_WINDOW_MS) end
        -- Kept where Death.clearPlayer can find it: a victim who leaves
        -- before the check is attributed with what is known by then.
        -- Quitting is not a way out of a contract.
        local entry = { victim = victim, source = victimSource, named = named,
            at = reportedAt, coords = victimCoords }
        deferred[victim.cid] = entry
        SetTimeout(math.max(0, last - reportedAt) + 50, function()
            if deferred[victim.cid] ~= entry then return end
            deferred[victim.cid] = nil
            -- Outside the report's own guard now, so given one of its own.
            local ok, err = pcall(function()
                checkHits(victim.cid)
                Death.attributeDeath(victim, victimSource, named, reportedAt, victimCoords)
            end)
            if not ok then
                Audit.rejected('error_iDied', victim.cid, nil, { error = tostring(err), deferred = true })
            end
        end)
        return 0
    end

    return Death.attributeDeath(victim, victimSource, named, reportedAt, victimCoords)
end

--- The kept hit on a downed victim by this attacker, credited as the one
--- that killed them. Only on the victim's own word (see checkHits).
---@return table|nil record the damage record it made
function Death.takeDownHit(victimCid, attackerCid)
    local list = downHits[victimCid]
    if not list then return nil end
    local now = Util.monotonicMs()
    local found
    for i = #list, 1, -1 do
        local hit = list[i]
        if now - hit.at > Death.DOWN_HIT_KEEP_MS then
            table.remove(list, i)
        elseif not found and hit.attackerCid == attackerCid
            and (lethalAt[victimCid] or -math.huge) < hit.at then
            found = table.remove(list, i)
        end
    end
    if not list[1] then downHits[victimCid] = nil end
    if not found then return nil end
    credit(victimCid, found, math.max(1, math.min(found.base, credited[victimCid] or math.huge)), 0)
    return Death.recordFor(victimCid, attackerCid)
end

--- Open a pending kill on every live contract naming this victim, for the
--- hitman the death is credited to.
---@return integer opened
function Death.attributeDeath(victim, victimSource, named, reportedAt, victimCoords)
    local opened = 0
    -- The contracts naming this victim, by the store's own index: every
    -- death on the server came here, and it read the whole table.
    local contracts = Storage.contractsNaming(victim.cid)

    for i = 1, #contracts do
        local contract = contracts[i]
        -- Only a contract a kill completes. One placed for a live delivery
        -- only is left as it was: the target died, will respawn, and is
        -- still to be delivered. No kill is opened on it from the victim's
        -- report or from the server's own sighting, both of which end here.
        if contract.target_cid == victim.cid and contract.state == CH.STATE.ACCEPTED
            and Util.fulfilmentRule(contract) == CH.FULFILMENT_RULE.EITHER then
            local hitmen = Storage.readHitmen(contract.id)
            local active = {}
            for j = 1, #hitmen do
                if hitmen[j].state == 'active' then active[hitmen[j].hitman_cid] = true end
            end

            -- Prefer the killer the victim named, when they are on this
            -- contract; otherwise fall back to the observed damage log.
            local hit
            if named and active[named] then
                -- The victim's word plus the server's own observation. A
                -- record was synthesised here when the damage log held
                -- nothing for the named killer, which credits a hitman the
                -- server never saw touch the target — the victim's client
                -- is the one naming them, and it is a client.
                hit = Death.recordFor(victim.cid, named)

                -- No damage of theirs showed, but the victim's own game says
                -- they are the one who killed them, and a hit of theirs landed
                -- while the victim was down: the shot that finished them, on a
                -- body raised in the same frame. A bleed-out names nobody, so
                -- it is never taken for one.
                if not hit then hit = Death.takeDownHit(victim.cid, named) end

                if not hit and not Config.Completion.RequireObservedDamage then
                    hit = {
                        attackerCid = named,
                        coords = victimCoords or GetEntityCoords(GetPlayerPed(victimSource)),
                    }
                elseif not hit then
                    -- Or a restart lost the hits that would have shown: the
                    -- report of a death from before it, which the target's
                    -- restarted game sends again. Blaming the weapon then
                    -- was untrue of a hitman who had shot them.
                    local lost = lostToRestart(victim.cid)
                    Audit.rejected(lost and 'named_killer_lost_restart' or 'named_killer_unobserved',
                        named, contract.id, { victim = victim.cid })
                    -- So Verify kill can tell them why: a bomb, a fire or a
                    -- car raises no weapon event, and "down is not dead"
                    -- said nothing to somebody who had just blown them up.
                    unobserved[contract.id .. ':' .. named] =
                        { at = Util.monotonicMs(), victimCid = victim.cid, hitmanCid = named,
                          restart = lost or nil }
                end

                -- Falling back to the damage log would hand the kill to
                -- whoever else happened to be shooting, which is worse than
                -- paying nobody.
            else
                hit = Death.lastAttackerAmong(victim.cid, active)
            end

            -- The same death told again: never seen anything but dead since
            -- this hitman's kill opened. Replaced, its new time made the
            -- photo token in the hitman's hand stale, and a dead target
            -- resending the report could keep doing so.
            local same = hit and Death.getPending(contract.id, hit.attackerCid)
            if same and (aliveAt[victim.cid] or -math.huge) > same.at then same = nil end
            -- Or opened for another hitman on it. A report that came after
            -- the server attributed the death without one (awaitReport), and
            -- named somebody else, opened a second kill for the one death,
            -- and both could be paid.
            if hit and not same then
                for cid in pairs(active) do
                    local other = cid ~= hit.attackerCid and Death.getPending(contract.id, cid)
                    if other and other.victimCid == victim.cid
                        and (aliveAt[victim.cid] or -math.huge) <= other.at then
                        same = other
                        break
                    end
                end
            end

            if same then
                opened = opened + 1
            elseif hit then
                local at = reportedAt or Util.monotonicMs()
                pending[contract.id .. ':' .. hit.attackerCid] = {
                    contractId = contract.id,
                    hitmanCid  = hit.attackerCid,
                    victimCid  = victim.cid,
                    at         = at,
                    -- The same moment on the clock deadlines are kept in,
                    -- so a deadline or a buyout's delay that ran out before
                    -- it is not held open for its photo (Bailout.finishing).
                    wallAt     = os.time() - math.max(0, (Util.monotonicMs() - at) // 1000),
                    -- Where the body is, which the photograph is taken
                    -- beside: the hit may have landed on a moving car, or
                    -- the body been dragged since.
                    coords     = victimCoords or hit.coords,
                    weapon     = hit.weapon,
                }
                Audit.action('death_attributed', hit.attackerCid, contract.id, {
                    victim = victim.cid,
                    distance = hit.distance and math.floor(hit.distance) or nil,
                    source = named == hit.attackerCid and 'victim_report' or 'damage_log',
                })
                opened = opened + 1
            else
                -- Died on a live contract, but not to a hitman. No payout,
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
--- so a hitman who took their photo late in that window was told the
--- target had been revived.
local function aged(record, now)
    local lifetime = Config.Completion.PhotoTokenLifetimeSeconds * 1000
    if now - record.at <= lifetime then return false end
    return not (record.heldUntil and now <= record.heldUntil)
end

function Death.getPending(contractId, hitmanCid)
    local record = pending[contractId .. ':' .. hitmanCid]
    if not record then return nil end
    if aged(record, Util.monotonicMs()) then
        pending[contractId .. ':' .. hitmanCid] = nil
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
function Death.holdPending(contractId, hitmanCid, untilMs)
    local record = pending[contractId .. ':' .. hitmanCid]
    if not record then return nil end
    local cap = record.at + 2 * Config.Completion.PhotoTokenLifetimeSeconds * 1000
    local held = math.min(untilMs, cap)
    record.heldUntil = math.max(record.heldUntil or 0, held)
    return held
end

function Death.clearPending(contractId, hitmanCid)
    pending[contractId .. ':' .. hitmanCid] = nil
end

--- How many seconds from now a pending kill can still be verified, as it
--- stands (aged): its lifetime from the death, or the photo token holding
--- it, whichever is later. Asked when a claim on it is refused for a
--- protection still running on the target, to say whether the kill
--- outlasts that protection (Photo.verifyAtScene).
---@param record table a pending kill (Death.getPending)
---@return number seconds
function Death.lastsFor(record)
    local untilMs = record.at + Config.Completion.PhotoTokenLifetimeSeconds * 1000
    if record.heldUntil and record.heldUntil > untilMs then untilMs = record.heldUntil end
    return math.max(0, (untilMs - Util.monotonicMs()) / 1000)
end

--- Drop every kill pending on a contract that has closed, and what was seen
--- of one: nothing can claim them any more (Contracts.onResolved), and a
--- pending kill outlived a staff void, minting photo tokens for a contract
--- that was over.
---@param contractId string
function Death.clearContract(contractId)
    local prefix = contractId .. ':'
    for key in pairs(pending) do
        if key:sub(1, #prefix) == prefix then pending[key] = nil end
    end
    for key in pairs(unobserved) do
        if key:sub(1, #prefix) == prefix then unobserved[key] = nil end
    end
end

--- Whether this hitman's last kill on this contract went unseen: their
--- target's own game named them as the killer, and the server never saw a
--- hit of theirs land. Only for as long as a kill would wait for its photo.
---@param contractId string
---@param hitmanCid string
---@return boolean
---@return boolean restart the death was reported again after a start, its proof
--- lost with the process before it (lostToRestart)
function Death.unobservedKill(contractId, hitmanCid)
    local key = contractId .. ':' .. hitmanCid
    local record = unobserved[key]
    if not record then return false, false end
    if Util.monotonicMs() - record.at > Config.Completion.PhotoTokenLifetimeSeconds * 1000 then
        unobserved[key] = nil
        return false, false
    end
    return true, record.restart == true
end

--- A revive invalidates every pending completion for that player: a target
--- who is back on their feet was not eliminated (§7.4).
---
--- The claim is verified against the medical state before anything is
--- cleared. Taking it on trust would let a target's client void a hitman's
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
    aliveAt[cid] = now
    -- One death, one revive. A second claim has to wait for a second death.
    seenDead[cid] = nil
    upSince[cid] = nil
    lastUp[cid] = nil
    defibAt[cid] = nil
    downHits[cid] = nil
    -- The death a wait was for is undone, and so is one that went unseen.
    unreported[cid] = nil
    for key, record in pairs(unobserved) do
        if record.victimCid == cid then unobserved[key] = nil end
    end

    -- A revive ends the fight. Damage recorded before it must not
    -- corroborate a death that happens afterwards, or a hitman who shot
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
        -- hitman standing over the body. Nor does one made after the revive.
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

    -- Kept hits on somebody picked up from last stand, or never reported.
    for cid, kept in pairs(downHits) do
        while kept[1] and now - kept[1].at > Death.DOWN_HIT_KEEP_MS do table.remove(kept, 1) end
        if not kept[1] then downHits[cid] = nil end
    end

    local unseenFor = Config.Completion.PhotoTokenLifetimeSeconds * 1000
    for key, record in pairs(unobserved) do
        if now - record.at > unseenFor then unobserved[key] = nil end
    end

    return removed
end

--- How many hits on downed players are being kept, for tests and the
--- diagnosis.
function Death.keptDownHits()
    local n = 0
    for _, kept in pairs(downHits) do n = n + #kept end
    return n
end

function Death.pendingCount()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

--- Forget a player who disconnected.
---
--- A pending kill goes with its HITMAN, not with its victim. It used to go
--- with either, so a target who closed the game while lying dead destroyed a
--- kill the server itself had attributed: the hitman, standing over the body,
--- was told there was no kill to verify. Nothing in the proof needs the victim
--- online — the body's position is recorded with the death, and the revive
--- check only applies to a victim who is still here to be revived. Quitting
--- is not a way out of a contract.
---
--- Nothing accumulates: a pending kill ages out of getPending and sweep on
--- the photo token lifetime, whoever is online.
function Death.clearPlayer(cid)
    -- A death report still waiting on its hits: attributed now, with the
    -- hits already confirmed. Checking the rest would read a ped that is
    -- leaving.
    local d = deferred[cid]
    if d then
        deferred[cid] = nil
        -- Hits still waiting that landed while they were down are kept, as
        -- they would have been had the victim stayed: the report may name
        -- one of them as the shot that finished them.
        local now = Util.monotonicMs()
        for _, hit in ipairs(inflight[cid] or {}) do
            if hit.down and (lethalAt[cid] or -math.huge) < hit.at then keepDownHit(cid, hit, now) end
        end
        inflight[cid] = nil
        local ok, err = pcall(Death.attributeDeath, d.victim, d.source, d.named, d.at, d.coords)
        if not ok then
            Audit.rejected('error_iDied', cid, nil, { error = tostring(err), deferred = true })
        end
    end
    -- A death the server saw and nobody reported, the victim gone before the
    -- wait for their report ran out: attributed now, the way the wait would
    -- have, with what the damage log holds.
    local u = unreported[cid]
    if u then
        unreported[cid] = nil
        local ok, err = pcall(function()
            Audit.action('death_unreported', nil, nil, { victim = cid })
            Death.attributeDeath(u.victim, u.source, nil, u.at, u.coords)
        end)
        if not ok then
            Audit.rejected('error_unreported_death', cid, nil, { error = tostring(err) })
        end
    end
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
    lethalAt[cid] = nil
    downHits[cid] = nil
    polling[cid] = nil
    aliveAt[cid] = nil
    for src, watchedCid in pairs(watching) do
        if watchedCid == cid then watching[src] = nil end
    end
    for key, record in pairs(pending) do
        if record.hitmanCid == cid then pending[key] = nil end
    end
    for key, record in pairs(unobserved) do
        if record.hitmanCid == cid or record.victimCid == cid then unobserved[key] = nil end
    end
end

return Death
