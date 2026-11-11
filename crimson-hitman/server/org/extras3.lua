--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                  crimson-hitman - server/org/extras3.lua                  ║
    ║   Reputation, dead drops, territory, garage, internal contracts, more     ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- The hitman organisation's third set of extras (plan §9 R14-R20), each its
--- own switch under Config.Organisation, off as shipped and each needing the
--- organisation on. Like server/org/extras.lua and extras2.lua, everything
--- the boss side may do is a row in Boss permissions, off until staff allow
--- it; staff do all of it from the panel; every write takes two clicks or
--- taps and is on the record; anonymity is never loosened.
---
---   R14 Reputation (Reputation): the organisation's standing, from the
---       record's outcomes of its members (RepCompletion up, RepFailure down)
---       and the heat they carry now (RepHeat a point), in tiers
---       (RepTiers: 'points, label, most an accept is worth'); a member's
---       accept above their tier's worth is refused. Staff adjust it.
---   R15 Dead drops (DeadDrops): with P4 set to 'deaddrop', a member's
---       payout waits in escrow (a payout check, server/payout.lua) until they
---       collect it at the organisation's staff-set dead drop within
---       DeadDropMinutes; unclaimed, DeadDropUnclaimed says: 'pay' (handed
---       over as always) or 'refund' (back to the placer). Only the escrow's
---       own paths move it, so what was escrowed is what is received.
---   R16 Territory (Territory, with OrgContracts): staff-drawn zones; a
---       contract placed on somebody inside one, while a member of that
---       organisation stands within TerritorySightMetres of them (and so can
---       already see where they are), is first held for it for
---       TerritoryMinutes, as a contract sent to it, then the open board.
---       Nobody is told why, nor the target's position: see below.
---   R17 Garage (Garage): staff-approved vehicles (GarageVehicles) a member
---       takes out at the organisation's garage spot, through the garage
---       adapter (server/adapters/garage/), keys from the keys adapter.
---   R18 Internal contracts (InternalContracts): a boss (K8) asks for a
---       contract on a rogue member; only staff approve it, and it is then
---       placed by that boss through the ordinary path, every limit applying.
---   R19 Handler (Handler): an NPC spot of the organisation briefs a member
---       in the world and, with HandlerAssigns, hands out the oldest contract
---       waiting for the organisation.
---   R20 Activity log (ActivityLog): what members and bosses did (accepts,
---       outcomes, money moves, grants, hires), for M12 holders: members by
---       the name the organisation shows, staff as Staff, no citizen id.
---
--- Territory and privacy. The only thing territory ever reads is where the
--- server sees the target as the contract is placed, and it acts on that
--- only when a member of the organisation is within TerritorySightMetres of
--- the target at that moment, in the same routing bucket: somebody who can
--- already see where the target is. The position is never stored, sent or
--- logged; the zones themselves are staff-only (never sent to a game). The
--- organisation is told exactly what it is told of a contract a placer sent
--- to it ("A contract was sent to the organisation"), so it cannot tell a
--- territory hold from a placer's choice, and the placer is told nothing
--- (not even when it goes on the open board), so the placer learns nothing
--- about where the target was. The hold is short (TerritoryMinutes) and
--- only ever delays the open board.

local Geo = CrimsonBoot.requireShared('geo')
local Window = CrimsonBoot.require('server.lib.window')
local Feature = CrimsonBoot.require('server.lib.feature')
local Integrations = CrimsonBoot.require('server.adapters.init')
local L = CrimsonBoot.requireShared('locale').t

local Extras3 = {}

--- What the organisation gains, copied onto it by Extras3.attach.
local Org = {}
Extras3.API = Org

-- ============================================================================
--                              STATE
-- ============================================================================

--- Dead drops waiting, every organisation's: [contractId:cid] = orgId. The
--- drops themselves are in each organisation's settings.drops, so a restart
--- keeps them. Empty: the escrow's gate pays one next().
local Drops = {}

--- Vehicles out of the garage: [cid] = { entity, org, model, plate, at }.
--- Kept in memory: a restart takes every one away (onResourceStop).
local Vehicles = {}

--- Garage moves each member made in the last hour (a flood guard).
local Moves = Window.new(3600)

--- Internal contract requests each boss made in the last day.
local Asked = Window.new(86400)

local Seq = 0

local O, kit

local function now() return os.time() end
local function deps() return kit.deps() end
local function fail(...) return kit.fail(...) end

--- Whether one of these extras is on: the organisation on, and its switch.
---@param name string a Config.Organisation key
---@return boolean
local function on(name)
    return Feature.on('Organisation') and Config.Organisation[name] == true
end
Extras3.on = on

local function whole(key, fallback, lo, hi)
    local n = math.floor(tonumber(Config.Organisation[key]) or fallback)
    return math.max(lo, math.min(hi, n))
end

local function distanceSetting(key, fallback, lo, hi)
    local n = tonumber(Config.Organisation[key]) or fallback
    return math.max(lo, math.min(hi, n))
end

local function tell(cid, text)
    local d = deps()
    if d.notify and d.notify.toCitizen and d.identity.byCitizenId(cid) then
        pcall(d.notify.toCitizen, cid, (O.current() and O.current().label) or L('org_extras3.organisation'), text)
    end
end

local function shownName(org, cid)
    local m = org.members[cid]
    if not m then return L('org_extras3.a_former_member') end
    return (O.codenamesOn() and m.codename) or m.name or L('org_extras3.a_member')
end

local function mayActOn(org, who, cid)
    if who.staff then return nil end
    local why = O.Engine.mayActOn(org, who.cid, cid)
    if not why then return nil end
    local ERR = O.ERR
    return why == 'self' and ERR.SELF or why == 'locked' and ERR.LOCKED or why == 'not_member' and ERR.NOT_FOUND
        or ERR.RANK
end

local function spotOf(org, kind)
    local best
    for _, l in pairs(org.locations) do
        if l.kind == kind and l.enabled ~= false and (not best or l.id < best.id) then best = l end
    end
    return best
end

-- ============================================================================
--                              R20: THE ACTIVITY LOG
-- ============================================================================

--- What the log keeps of a boss's or staff's write (Org.record), by action.
local LOGGED = {
    org_member_hired = L('org_extras3.hired'), org_member_fired = L('org_extras3.fired'), org_member_role = L('org_extras3.role_changed'),
    org_member_suspended = L('org_extras3.suspended'), org_role_power = L('org_extras3.role_power_set'), org_member_grant = L('org_extras3.member_grant_set'),
    org_grant = L('org_extras3.boss_permission_set_by_staff'), org_funds_deposit = L('org_extras3.deposit_to_funds'),
    org_funds_withdraw = L('org_extras3.withdrawal_from_funds'), org_funds_staff_deposit = L('org_extras3.deposit_to_funds'), org_bonus = L('org_extras3.bonus_paid'),
    org_armory_deposit = L('org_extras3.armory_put_in'), org_armory_withdraw = L('org_extras3.armory_taken_out'),
    org_contract_assigned = L('org_extras3.contract_assigned'), org_contract_reassigned = L('org_extras3.contract_reassigned'),
    org_strike = L('org_extras3.strike_given'), org_warning = L('org_extras3.warning_given'), org_payout_method = L('org_extras3.payout_method_set'),
    org_vehicle_out = L('org_extras3.vehicle_taken_out'), org_vehicle_returned = L('org_extras3.vehicle_returned'),
    accepted = L('org_extras3.contract_accepted'), completed = L('org_extras3.contract_completed'), failed = L('org_extras3.contract_failed'),
}

--- The detail fields the log keeps, and nothing else (never a citizen id
--- but the member's own, read back as their name).
local KEPT = { amount = true, grade = true, power = true, kind = true, to = true, from = true, model = true,
    method = true, count = true, state = true }

local function keep(org, action, by, member, detail)
    local log = org.settings.activity
    local entry = { at = now(), a = action, by = by, m = member }
    for k, v in pairs(type(detail) == 'table' and detail or {}) do
        if KEPT[k] and (type(v) == 'number' or type(v) == 'string' or type(v) == 'boolean') then
            entry[k] = type(v) == 'string' and v:sub(1, 40) or v
        end
    end
    log[#log + 1] = entry
    local most = whole('ActivityKeep', 200, 10, 1000)
    while #log > most do table.remove(log, 1) end
end

--- A write on the record (Org.record): kept where the log keeps it.
function Extras3.logAction(action, who, detail)
    if not on('ActivityLog') or not LOGGED[action] then return end
    local org = O.current()
    if not org then return end
    local by = who.staff and 'staff' or who.cid
    local member = type(detail) == 'table' and type(detail.member) == 'string' and detail.member or nil
    keep(org, action, by, member, detail)
    kit.save()
end

--- An accept by a member (Org.afterAccept).
function Extras3.accepted(org, actor)
    if not on('ActivityLog') or not org.members[actor.cid] then return end
    keep(org, 'accepted', actor.cid, nil, nil)
    kit.save()
end

--- The log for M12 (and staff): newest first, members by name.
function Org.activity(who, limit)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('ActivityLog') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'M12')
    if err then return fail(err) end
    limit = math.max(1, math.min(200, math.floor(tonumber(limit) or 100)))
    local log, rows = org.settings.activity, {}
    for i = #log, math.max(1, #log - limit + 1), -1 do
        local e = log[i]
        local row = { at = e.at, what = LOGGED[e.a] or L('org_extras3.done'), action = e.a,
            by = e.by == 'staff' and L('org_extras3.staff') or shownName(org, e.by),
            member = e.m and shownName(org, e.m) or nil }
        for k in pairs(KEPT) do row[k] = e[k] end
        rows[#rows + 1] = row
    end
    return true, nil, { rows = rows }
end

-- ============================================================================
--                              R14: REPUTATION AND TIERS
-- ============================================================================

--- The tiers, lowest first: { points, label, max } from RepTiers.
local function tiers()
    local out = {}
    for _, text in ipairs(type(Config.Organisation.RepTiers) == 'table' and Config.Organisation.RepTiers or {}) do
        local p, label, max = tostring(text):match('^%s*(%d+)%s*,%s*([^,]+),%s*(%d+)%s*$')
        if p then out[#out + 1] = { points = tonumber(p), label = label:gsub('%s+$', ''):sub(1, 32), max = tonumber(max) } end
    end
    table.sort(out, function(a, b) return a.points < b.points end)
    return out
end

local function heatOf(cid)
    local ok, Heat = pcall(CrimsonBoot.require, 'server.record.heat')
    if not ok or type(Heat) ~= 'table' or type(Heat.of) ~= 'function' then return 0 end
    local okH, points = pcall(Heat.of, cid)
    return okH and math.max(0, tonumber(points) or 0) or 0
end

--- The organisation's standing now: its points less the heat its members
--- carry, its tier and the next one.
---@return table { points, earned, heat, tier, next }
function Extras3.standing(org)
    local rep = org.settings.rep
    local heat = 0
    local weight = whole('RepHeat', 2, 0, 1000)
    if weight > 0 then
        for cid in pairs(org.members) do heat = heat + heatOf(cid) end
    end
    local earned = math.max(0, math.floor(tonumber(rep.points) or 0))
    local points = math.max(0, earned - heat * weight)
    local list, tier, nextTier = tiers(), nil, nil
    for _, t in ipairs(list) do
        if points >= t.points then tier = t elseif not nextTier then nextTier = t end
    end
    return { points = points, earned = earned, heat = heat * weight, tier = tier, next = nextTier,
        completed = math.floor(tonumber(rep.c) or 0), failed = math.floor(tonumber(rep.f) or 0) }
end

--- The accept gate's question: refused above the tier's worth.
---@return string|nil err
---@return table|nil data
function Extras3.tierGate(org, member, contractId)
    if not on('Reputation') or not member then return nil end
    local s = Extras3.standing(org)
    local cap = s.tier and s.tier.max or 0
    if not s.tier then
        local first = tiers()[1]
        cap = first and first.max or 0
    end
    if cap <= 0 then return nil end
    local d = deps()
    if not (d.escrow and d.escrow.moneyValue) then return nil end
    local ok, worth = pcall(d.escrow.moneyValue, contractId)
    if ok and tonumber(worth) and worth > cap then
        return 'org_tier', { message = O.message('org_tier'), max = cap, tier = s.tier and s.tier.label or nil }
    end
    return nil
end

--- An outcome on the record (Record.observer), for the organisation the
--- member is in: reputation, and the activity log.
function Extras3.observe(kind, cid, info)
    if not (on('Reputation') or on('ActivityLog')) then return end
    local org = O.current()
    if not org or type(cid) ~= 'string' or not org.members[cid] then return end
    if kind ~= 'completed' and kind ~= 'failed' then return end
    if on('Reputation') then
        local rep = org.settings.rep
        if kind == 'completed' then
            rep.points = math.floor(tonumber(rep.points) or 0) + whole('RepCompletion', 10, 0, 100000)
            rep.c = math.floor(tonumber(rep.c) or 0) + 1
        else
            rep.points = math.max(0, math.floor(tonumber(rep.points) or 0) - whole('RepFailure', 15, 0, 100000))
            rep.f = math.floor(tonumber(rep.f) or 0) + 1
        end
    end
    if on('ActivityLog') then
        local earned = type(info) == 'table' and tonumber(info.earned) or nil
        keep(org, kind, cid, nil, earned and { amount = math.floor(earned) } or nil)
    end
    kit.save()
end

--- Staff move the points by `points` (either way), with a reason.
function Org.repAdjust(who, points, reason)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    if not on('Reputation') then return fail(ERR.FEATURE_OFF) end
    points = tonumber(points)
    if not points or points ~= math.floor(points) or points == 0 or math.abs(points) > 100000 then
        return fail(ERR.INVALID, { message = L('org_extras3.a_whole_number_of_points_up') })
    end
    reason = O.Extras.plain(reason, 200)
    if not reason then return fail(ERR.INVALID, { message = L('org_extras3.give_a_reason') }) end
    local rep = org.settings.rep
    local before = math.floor(tonumber(rep.points) or 0)
    rep.points = math.max(0, before + points)
    kit.save()
    kit.record('org_rep_adjusted', who, { from = before, to = rep.points, reason = reason })
    return true, nil, Extras3.standing(org)
end

-- ============================================================================
--                              R15: DEAD DROPS
-- ============================================================================

local function dropKey(contractId, cid) return tostring(contractId) .. ':' .. tostring(cid) end

--- Choose how members' payouts are handed over (P4): 'bank' as always, or
--- 'deaddrop' (at the organisation's dead drop, set by staff).
function Org.setPayoutMethod(who, method)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('DeadDrops') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'P4')
    if err then return fail(err) end
    if method ~= 'bank' and method ~= 'deaddrop' then return fail(ERR.INVALID) end
    if method == 'deaddrop' and not spotOf(org, 'deaddrop') then
        return fail(ERR.RULE, { message = L('org_extras3.staff_have_not_set_a_dead') })
    end
    if (org.settings.payoutMethod or 'bank') == method then return fail(ERR.ALREADY) end
    org.settings.payoutMethod = method
    kit.save()
    kit.record('org_payout_method', who, { method = method })
    return true, nil, { method = method }
end

--- The claim is releasing a payout (Payout.onClaim): a member of an
--- organisation paying at its dead drop gets a drop to collect.
local function onClaim(contract, hitmanCid)
    if not on('DeadDrops') or type(contract) ~= 'table' or type(hitmanCid) ~= 'string' then return nil end
    local org = O.orgOf(hitmanCid)
    if not org or org.settings.payoutMethod ~= 'deaddrop' then return nil end
    local spot = spotOf(org, 'deaddrop')
    if not spot then return nil end
    local key = dropKey(contract.id, hitmanCid)
    if org.settings.drops[key] then return nil end
    local wait = whole('DeadDropMinutes', 60, 1, 10080)
    org.settings.drops[key] = { contract = contract.id, cid = hitmanCid, creator = contract.creator_cid,
        spot = spot.id, at = now(), expires = now() + wait * 60 }
    Drops[key] = org.id
    O.within(org, kit.save)
    deps().audit.financial('org_drop_left', hitmanCid, contract.id, { org = org.id, minutes = wait })
    O.within(org, tell, hitmanCid, (L('org_extras3.your_payout_is_left_at_the'))
        :format(spot.label or L('org_extras3.dead_drop'), wait))
    return nil
end

--- The escrow's gate (Escrow.holdBack): the payout of a drop not yet
--- collected waits. One next() while none waits.
---@return boolean
local function holds(recipientCid, line)
    if next(Drops) == nil or type(line) ~= 'table' then return false end
    if line.portion ~= CH.PORTION.BASELINE and line.portion ~= CH.PORTION.BONUS then return false end
    return Drops[dropKey(line.contract_id, recipientCid)] ~= nil
end

local function releasesAt(recipientCid, line)
    local id = type(line) == 'table' and Drops[dropKey(line.contract_id, recipientCid)]
    local org = id and O.byId(id)
    local drop = org and org.settings.drops[dropKey(line.contract_id, recipientCid)]
    return drop and drop.expires or nil
end

--- Every line of a drop's payout back to the placer (the 'refund' rule),
--- as body disposal's refund does: the escrow's own release.
local function refund(drop)
    local d = deps()
    local back = 0
    local ok, lines = pcall(d.storage.readEscrow, drop.contract)
    for _, line in ipairs(ok and lines or {}) do
        if (line.portion == CH.PORTION.BASELINE or line.portion == CH.PORTION.BONUS) and line.owed_to == drop.cid
            and line.state == CH.ESCROW_STATE.HELD and not (d.escrow.parked and d.escrow.parked(line)) then
            local okR, _, result = pcall(d.escrow.release, drop.contract, drop.creator, { line = line.id },
                'deaddrop_refund', function(claimed) return claimed.owed_to == drop.cid end)
            if okR then
                local fresh = d.storage.readEscrowLine(line.id)
                if fresh and fresh.owed_to ~= drop.cid then
                    for _, entry in ipairs(d.storage.readPending(drop.cid) or {}) do
                        if entry.line_id == line.id then d.storage.clearPending(entry.id) end
                    end
                    back = back + 1
                end
                if result and (result.pending or 0) > 0 then d.escrow.noteWaiting(drop.creator, true) end
            end
        end
    end
    return back
end

--- End a drop: the hold lifts and the escrow's retry hands the payout over
--- (at once where the member is in the city, else at their login).
local function finish(org, key, why)
    local drop = org.settings.drops[key]
    if not drop then return false end
    if why == 'refund' then refund(drop) end
    org.settings.drops[key] = nil
    Drops[key] = nil
    kit.save()
    local d = deps()
    d.audit.financial(why == 'collected' and 'org_drop_collected' or 'org_drop_expired', drop.cid, drop.contract,
        { org = org.id, why = why })
    pcall(d.escrow.noteWaiting, drop.cid, true)
    if d.identity.byCitizenId(drop.cid) then pcall(d.escrow.retryPending, drop.cid) end
    return true
end

--- A member at the dead drop: every drop of theirs collected.
local function collect(org, actor, loc)
    local n = 0
    local keys = {}
    for key, drop in pairs(org.settings.drops) do
        if drop.cid == actor.cid and drop.spot == loc.id then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do
        if finish(org, key, 'collected') then n = n + 1 end
    end
    tell(actor.cid, n > 0 and (L('org_extras3.you_collected_payout_from_the_dead')):format(n)
        or L('org_extras3.nothing_is_waiting_for_you_at'))
    return n
end

--- Staff settle a drop now: 'release' (handed over) or 'refund'.
function Org.dropSettle(who, key, how)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    if type(key) ~= 'string' or not org.settings.drops[key] then return fail(ERR.NOT_FOUND) end
    if how ~= 'release' and how ~= 'refund' then return fail(ERR.INVALID) end
    local drop = org.settings.drops[key]
    finish(org, key, how == 'refund' and 'refund' or 'staff')
    kit.record('org_drop_settled', who, { how = how }, drop.contract)
    return true
end

-- ============================================================================
--                              R16: TERRITORY
-- ============================================================================

--- A contract just placed and not sent anywhere (Contracts' create in
--- server/app.lua): held first for the organisation whose territory the
--- target stands in, where one of its members can see them. See the top of
--- this file for why nothing here tells anybody where anybody is.
---@param contractId string
---@param targetCid string
---@return string|nil the organisation's id it was held for
function Org.territoryClaim(contractId, targetCid)
    if not on('Territory') or not on('OrgContracts') then return nil end
    if type(contractId) ~= 'string' or type(targetCid) ~= 'string' then return nil end
    local d = deps()
    local target = d.identity.byCitizenId(targetCid)
    if not target or not target.source then return nil end
    local at = Geo.position(target.source)
    if not at then return nil end
    local bucket = GetPlayerRoutingBucket(target.source)
    local sight = distanceSetting('TerritorySightMetres', 75.0, 5.0, 500.0)
    for _, org in ipairs(O.all()) do
        local inside = false
        for _, l in pairs(org.locations) do
            if l.kind == 'territory' and l.enabled ~= false and Geo.near(at, { x = l.x, y = l.y, z = at.z }, l.radius or 0) then
                inside = true
            end
        end
        if inside and not org.settings.orgContracts[contractId] and not org.members[targetCid] then
            local seen = false
            for cid in pairs(org.members) do
                local m = cid ~= targetCid and d.identity.byCitizenId(cid)
                if m and m.source and GetPlayerRoutingBucket(m.source) == bucket
                    and Geo.near(Geo.position(m.source), at, sight) then
                    seen = true
                    break
                end
            end
            if seen then
                local wait = whole('TerritoryMinutes', 5, 1, 60)
                org.settings.orgContracts[contractId] = { state = 'waiting', at = now(), expires = now() + wait * 60,
                    territory = true }
                O.within(org, kit.save)
                O.Extras.rebuild()
                -- On the staff log only, and with no position.
                d.audit.staff('org_territory_hold', nil, contractId, { org = org.id, minutes = wait })
                for cid in pairs(org.members) do
                    if O.Engine.holds(org, cid, 'K4') then
                        O.within(org, tell, cid,
                            (L('org_extras3.a_contract_was_sent_to_the')):format(wait))
                    end
                end
                return org.id
            end
        end
    end
    return nil
end

-- ============================================================================
--                              R17: THE GARAGE
-- ============================================================================

local function garage() return Integrations.get('garage') end
local function keys() return Integrations.get('keys') end

local function approved()
    local out, list = {}, {}
    for _, model in ipairs(type(Config.Organisation.GarageVehicles) == 'table' and Config.Organisation.GarageVehicles or {}) do
        if type(model) == 'string' and model:match('^[%w_]+$') and not out[model] then
            out[model] = true
            list[#list + 1] = model
        end
    end
    return out, list
end

--- The models this organisation offers: staff's approved list, less what
--- a boss (V1) took off it.
local function offered(org)
    local ok, list = approved()
    local out = {}
    local off = org.settings.garage.off
    for _, model in ipairs(list) do
        if ok[model] and not off[model] then out[#out + 1] = model end
    end
    return out
end

local function outCount(org)
    local n = 0
    for _, v in pairs(Vehicles) do if v.org == org.id then n = n + 1 end end
    return n
end

local PLATE = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
local function plate()
    local s = 'CO'
    for _ = 1, 6 do
        local i = math.random(1, #PLATE)
        s = s .. PLATE:sub(i, i)
    end
    return s
end

local function removeVehicle(cid)
    local v = Vehicles[cid]
    if not v then return end
    Vehicles[cid] = nil
    local g = garage()
    if g and v.entity then pcall(g.remove, v.entity) end
end

local function atGarage(org, src, extra)
    local spot = spotOf(org, 'garage')
    if not spot then return nil end
    local at = Geo.position(src)
    if not at or not Geo.near(at, spot, (spot.radius or 2.0) + (extra or 3.0)) then return false, spot end
    return true, spot
end

--- What a member is shown of the garage.
function Org.garageView(who)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Garage') then return fail(ERR.FEATURE_OFF) end
    if not who.staff and not org.members[who.cid] then return fail(ERR.NOT_MEMBER) end
    local all = {}
    local ok, list = approved()
    for _, model in ipairs(list) do
        all[#all + 1] = { model = model, offered = ok[model] and not org.settings.garage.off[model] or nil }
    end
    local mine = not who.staff and Vehicles[who.cid] or nil
    local out = {}
    for cid, v in pairs(Vehicles) do
        if v.org == org.id then out[#out + 1] = { name = shownName(org, cid), model = v.model, at = v.at,
            ref = who.staff and O.refFor(who.cid, cid) or nil } end
    end
    return true, nil, { models = offered(org), all = all, out = out, max = whole('GarageMaxOut', 3, 1, 50),
        mine = mine and { model = mine.model, plate = mine.plate, at = mine.at } or nil,
        ready = garage() ~= nil or nil, hasSpot = spotOf(org, 'garage') ~= nil or nil,
        manage = (who.staff or O.Engine.holds(org, who.cid, 'V1')) or nil }
end

--- Take a vehicle out at the garage spot: one a member at a time, at most
--- GarageMaxOut for the organisation, only an offered model.
function Org.garageTake(who, model)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Garage') then return fail(ERR.FEATURE_OFF) end
    local member = org.members[who.cid]
    if not member then return fail(ERR.NOT_MEMBER) end
    local g = garage()
    if not g then return fail(ERR.RULE, { message = L('org_extras3.the_garage_needs_a_vehicle_adapter') }) end
    if type(model) ~= 'string' then return fail(ERR.INVALID) end
    local fine = false
    for _, m in ipairs(offered(org)) do if m == model then fine = true end end
    if not fine then return fail(ERR.NOT_FOUND) end
    if member.suspended_until and member.suspended_until > now() then
        return fail(ERR.RULE, { message = L('org_extras3.a_suspended_member_takes_nothing_out') })
    end
    if Vehicles[who.cid] then return fail(ERR.ALREADY, { message = L('org_extras3.you_have_one_out_already_return') }) end
    if outCount(org) >= whole('GarageMaxOut', 3, 1, 50) then return fail(ERR.LIMIT) end
    if Moves.count(who.cid, now()) >= 10 then return fail(ERR.COOLDOWN) end
    local there, spot = atGarage(org, who.source, 3.0)
    if there == nil then return fail(ERR.RULE, { message = L('org_extras3.staff_have_not_set_a_garage') }) end
    if not there then return fail(ERR.RULE, { message = L('org_extras3.stand_at_the_organisations_garage_spot') }) end
    local ok, entity = pcall(g.spawn, model, { x = spot.x, y = spot.y, z = spot.z, h = spot.h or 0.0 })
    if not ok or not entity or entity == 0 then
        return fail(ERR.REFUSED, { message = L('org_extras3.the_vehicle_could_not_be_made') })
    end
    local p = plate()
    pcall(g.prepare, entity, p, who.source)
    local k = keys()
    if k and k.GiveKeys then pcall(k.GiveKeys, who.source, entity) end
    Vehicles[who.cid] = { entity = entity, org = org.id, model = model, plate = p, at = now() }
    Moves.add(who.cid, now())
    kit.record('org_vehicle_out', { cid = who.cid }, { model = model })
    return true, nil, { model = model, plate = p }
end

--- Bring it back to the garage spot: taken away.
function Org.garageReturn(who)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Garage') then return fail(ERR.FEATURE_OFF) end
    local v = Vehicles[who.cid]
    if not v or v.org ~= org.id then return fail(ERR.NOT_FOUND) end
    local g = garage()
    local spot = spotOf(org, 'garage')
    local reach = distanceSetting('GarageReturnMetres', 15.0, 2.0, 200.0)
    if spot and g then
        local okC, at = pcall(g.coords, v.entity)
        local exists = select(2, pcall(g.exists, v.entity))
        if exists and (not okC or not Geo.near(at, spot, reach)) then
            return fail(ERR.RULE, { message = (L('org_extras3.bring_it_within_m_of_the')):format(reach) })
        end
    end
    removeVehicle(who.cid)
    kit.record('org_vehicle_returned', { cid = who.cid }, { model = v.model })
    return true
end

--- Which of staff's approved models the organisation offers (V1).
---@param models table [model] = true for offered
function Org.garageOffer(who, models)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('Garage') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'V1')
    if err then return fail(err) end
    if type(models) ~= 'table' then return fail(ERR.INVALID) end
    local ok, list = approved()
    local off = {}
    for _, model in ipairs(list) do
        if ok[model] and models[model] ~= true then off[model] = true end
    end
    org.settings.garage.off = off
    kit.save()
    kit.record('org_garage_offer', who, { count = #offered(org) })
    return true, nil, { models = offered(org) }
end

--- Staff take a member's vehicle away.
function Org.garageRemove(who, cid)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    local v = type(cid) == 'string' and Vehicles[cid]
    if not v or v.org ~= org.id then return fail(ERR.NOT_FOUND) end
    removeVehicle(cid)
    kit.record('org_vehicle_removed', who, { member = cid, model = v.model })
    return true
end

-- ============================================================================
--                              R18: INTERNAL CONTRACTS
-- ============================================================================

local function internalOf(org, id)
    if type(id) ~= 'string' or #id > 32 then return nil end
    return org.settings.internal[id]
end

--- A boss (K8) asks staff for a contract on a member below them who went
--- rogue: a reason, the cash reward they will put up, placed anonymously or
--- not as they choose (the server's anonymity rules still decide). Nothing
--- is placed or taken until staff approve it.
---@param spec table { reason, amount, anonymous }
function Org.internalRequest(who, cid, spec)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not on('InternalContracts') then return fail(ERR.FEATURE_OFF) end
    local err = O.authorize(org, who, 'K8')
    if err then return fail(err) end
    if type(cid) ~= 'string' or not org.members[cid] then return fail(ERR.NOT_FOUND) end
    local why = mayActOn(org, who, cid)
    if why then return fail(why) end
    if type(spec) ~= 'table' then return fail(ERR.INVALID) end
    local reason = O.Extras.plain(spec.reason, 200)
    if not reason then return fail(ERR.INVALID, { message = L('org_extras3.say_why_in_plain_words') }) end
    local amount = tonumber(spec.amount)
    if not amount or amount ~= math.floor(amount) or amount < 1 or amount > 100000000 then
        return fail(ERR.INVALID, { message = L('org_extras3.a_whole_number_of_dollars_for') })
    end
    local open = 0
    for _, r in pairs(org.settings.internal) do
        if r.state == 'pending' then
            open = open + 1
            if r.target == cid then return fail(ERR.ALREADY) end
        end
    end
    if open >= 5 then return fail(ERR.LIMIT) end
    if not who.staff and Asked.count(who.cid, now()) >= 3 then return fail(ERR.COOLDOWN) end
    Seq = Seq + 1
    local id = ('ic%d_%d'):format(now() % 100000000, Seq)
    org.settings.internal[id] = { id = id, target = cid, by = who.cid, reason = reason, amount = amount,
        anonymous = spec.anonymous == true or nil, state = 'pending', at = now(),
        expires = now() + whole('InternalExpireHours', 24, 1, 720) * 3600 }
    if not who.staff then Asked.add(who.cid, now()) end
    kit.save()
    kit.record('org_internal_requested', who, { member = cid, amount = amount })
    return true, nil, { id = id }
end

--- Staff approve (placed now by the boss who asked, through the ordinary
--- path: their own money, every limit) or decline one.
function Org.internalDecide(who, id, approve)
    local org = O.current()
    local ERR = O.ERR
    if not org then return fail(ERR.OFF) end
    if not who.staff then return fail(ERR.NO_POWER) end
    if not on('InternalContracts') then return fail(ERR.FEATURE_OFF) end
    if type(approve) ~= 'boolean' then return fail(ERR.INVALID) end
    local r = internalOf(org, id)
    if not r or r.state ~= 'pending' then return fail(ERR.NOT_FOUND) end
    if not approve then
        r.state, r.decided = 'declined', now()
        kit.save()
        kit.record('org_internal_decided', who, { member = r.target, state = 'declined' })
        tell(r.by, L('org_extras3.staff_declined_your_request_for_an'))
        return true, nil, { state = 'declined' }
    end
    local d = deps()
    local boss = d.identity.byCitizenId(r.by)
    if not boss then
        return fail(ERR.RULE, { message = L('org_extras3.the_boss_who_asked_is_not') })
    end
    if not org.members[r.target] then
        r.state, r.decided = 'declined', now()
        kit.save()
        return fail(ERR.RULE, { message = L('org_extras3.they_are_no_longer_a_member') })
    end
    local okC, contract, cerr, refusal = pcall(d.contracts.create, boss, { targetCid = r.target,
        reason = 'Internal: ' .. r.reason, mode = CH.MODE.COMPETITIVE,
        reward = { baseline = { cash = r.amount } }, anonymous = r.anonymous == true })
    if not okC or not contract then
        local code = okC and cerr or 'server_error'
        kit.record('org_internal_decided', who, { member = r.target, state = 'refused', kind = tostring(code) })
        return fail(ERR.RULE, { message = (L('org_extras3.approved_but_the_contract_could_not')):format(tostring(code)), refusal = refusal })
    end
    r.state, r.decided, r.contract = 'placed', now(), contract.id
    kit.save()
    kit.record('org_internal_decided', who, { member = r.target, state = 'placed' }, contract.id)
    tell(r.by, L('org_extras3.staff_approved_your_request_the_internal'))
    return true, nil, { state = 'placed', contract = contract.id }
end

-- ============================================================================
--                              R19: THE HANDLER
-- ============================================================================

--- A member talked to the handler (an NPC spot): a briefing, and with
--- HandlerAssigns the oldest contract waiting for the organisation.
local function handler(org, actor)
    local member = org.members[actor.cid]
    if not member then return false end
    local lines = {}
    local mineId
    for id, entry in pairs(org.settings.orgContracts) do
        if entry.state == 'assigned' and entry.cid == actor.cid then mineId = id end
    end
    local onDuty = O.Extras.onDuty(actor.cid)
    local suspended = member.suspended_until and member.suspended_until > now()
    if not mineId and Config.Organisation.HandlerAssigns ~= false and on('OrgContracts') and onDuty and not suspended then
        local oldest, oldestAt
        for id, entry in pairs(org.settings.orgContracts) do
            if entry.state == 'waiting' and (not oldestAt or entry.at < oldestAt) then oldest, oldestAt = id, entry.at end
        end
        if oldest then
            -- As a boss's K4 would, by the handler: the member then has
            -- AssignMinutes to take it.
            local entry = org.settings.orgContracts[oldest]
            local wait = whole('AssignMinutes', 30, 1, 1440)
            entry.state, entry.cid, entry.by, entry.assignedAt = 'assigned', actor.cid, 'handler', now()
            entry.expires = now() + wait * 60
            kit.save()
            O.Extras.rebuild()
            deps().audit.action('org_contract_assigned', actor.cid, oldest, { org = org.id, by = 'handler',
                member = actor.cid })
            mineId = oldest
        end
    end
    if mineId then
        local entry = org.settings.orgContracts[mineId]
        lines[#lines + 1] = L('org_extras3.you_have_a_contract_assigned_take')
        if entry.dossier and type(entry.dossier.notes) == 'string' then
            lines[#lines + 1] = 'Briefing: ' .. entry.dossier.notes:sub(1, 300)
        end
    else
        lines[#lines + 1] = L('org_extras3.nothing_for_you_right_now')
    end
    if org.settings.notice and org.settings.notice.text then
        lines[#lines + 1] = 'Notice: ' .. tostring(org.settings.notice.text):sub(1, 200)
    end
    tell(actor.cid, table.concat(lines, ' '))
    return true
end

--- A member used one of the organisation's spots (Org.useSpot): the dead
--- drop, the garage or the handler, where its switch is on. true: handled.
function Extras3.useSpot(org, actor, loc)
    if loc.kind == 'deaddrop' and on('DeadDrops') and org.members[actor.cid] then
        collect(org, actor, loc)
        return true
    end
    if loc.kind == 'garage' and on('Garage') and org.members[actor.cid] then
        tell(actor.cid, Vehicles[actor.cid] and L('org_extras3.return_your_vehicle_in_the_apps')
            or L('org_extras3.take_a_vehicle_out_in_the'))
        return true
    end
    if loc.kind == 'npc' and on('Handler') and org.members[actor.cid] then
        return handler(org, actor)
    end
    return false
end

-- ============================================================================
--                              READS
-- ============================================================================

--- What a member's own tab adds, each only while its switch is on.
function Extras3.mine(org, member, out)
    if not member then return end
    local cid = member.cid
    if on('Reputation') then
        local s = Extras3.standing(org)
        out.reputation = { points = s.points, tier = s.tier and s.tier.label or nil,
            next = s.next and s.next.label or nil, toNext = s.next and (s.next.points - s.points) or nil,
            max = s.tier and s.tier.max or nil }
    end
    if on('DeadDrops') then
        local spot = spotOf(org, 'deaddrop')
        local waiting = 0
        for _, drop in pairs(org.settings.drops) do if drop.cid == cid then waiting = waiting + 1 end end
        out.deadDrops = { method = org.settings.payoutMethod or 'bank', waiting = waiting,
            spot = spot and spot.label or nil, choose = O.Engine.holds(org, cid, 'P4') or nil }
    end
    if on('Garage') then out.garage = true end
    if on('InternalContracts') and O.Engine.holds(org, cid, 'K8') then
        local rows = {}
        for _, r in pairs(org.settings.internal) do
            if r.by == cid then rows[#rows + 1] = { id = r.id, name = shownName(org, r.target), state = r.state, at = r.at } end
        end
        table.sort(rows, function(a, b) return (a.at or 0) > (b.at or 0) end)
        local targets = {}
        for other in pairs(org.members) do
            if not mayActOn(org, { cid = cid }, other) then
                targets[#targets + 1] = { ref = O.refFor(cid, other), name = shownName(org, other) }
            end
        end
        table.sort(targets, function(a, b) return a.name < b.name end)
        out.internal = { rows = rows, targets = targets }
    end
    if on('ActivityLog') and O.Engine.holds(org, cid, 'M12') then out.activity = true end
    if on('Handler') then out.handler = true end
end

--- What the panel's orgGet adds: each feature on, and its state.
function Extras3.staffView(org, viewer, out)
    local view, any = {}, false
    for _, name in ipairs({ 'Reputation', 'DeadDrops', 'Territory', 'Garage', 'InternalContracts', 'Handler',
        'ActivityLog' }) do
        view[name] = on(name) or nil
        any = any or on(name)
    end
    if not any then return end
    local who = { staff = true, cid = viewer }
    if on('Reputation') then
        local s = Extras3.standing(org)
        view.reputation = { points = s.points, earned = s.earned, heat = s.heat, completed = s.completed,
            failed = s.failed, tier = s.tier, next = s.next, tiers = tiers() }
    end
    if on('DeadDrops') then
        local rows = {}
        for key, drop in pairs(org.settings.drops) do
            rows[#rows + 1] = { key = key, name = shownName(org, drop.cid), contract = drop.contract,
                expires = drop.expires, at = drop.at }
        end
        table.sort(rows, function(a, b) return a.at < b.at end)
        view.deadDrops = { method = org.settings.payoutMethod or 'bank', rows = rows,
            spot = spotOf(org, 'deaddrop') ~= nil or nil, unclaimed = Config.Organisation.DeadDropUnclaimed }
    end
    if on('Territory') then
        local n = 0
        for _, l in pairs(org.locations) do if l.kind == 'territory' then n = n + 1 end end
        view.territory = { zones = n, needsOrgContracts = not on('OrgContracts') or nil }
    end
    if on('Garage') then
        local _, _, g = Org.garageView(who)
        view.garage = g
    end
    if on('InternalContracts') then
        local rows = {}
        for _, r in pairs(org.settings.internal) do
            rows[#rows + 1] = { id = r.id, name = shownName(org, r.target), by = shownName(org, r.by),
                reason = r.reason, amount = r.amount, anonymous = r.anonymous, state = r.state, at = r.at,
                contract = r.contract }
        end
        table.sort(rows, function(a, b) return (a.at or 0) > (b.at or 0) end)
        view.internal = rows
    end
    if on('ActivityLog') then
        local _, _, log = Org.activity(who, 50)
        view.activity = log and log.rows or {}
    end
    out.extras3 = view
end

-- ============================================================================
--                              THE TICK
-- ============================================================================

--- Each organisation in turn (Org.extrasTick): drops run out, vehicles of
--- members gone or out too long are taken away, requests run out.
function Extras3.tick(org, at)
    if next(org.settings.drops) then
        local rule = Config.Organisation.DeadDropUnclaimed == 'refund' and 'refund' or 'pay'
        local due = {}
        for key, drop in pairs(org.settings.drops) do
            if not on('DeadDrops') or drop.expires <= at then due[#due + 1] = key end
        end
        for _, key in ipairs(due) do
            local drop = org.settings.drops[key]
            finish(org, key, on('DeadDrops') and rule or 'pay')
            tell(drop.cid, rule == 'refund' and on('DeadDrops')
                and L('org_extras3.you_did_not_collect_your_payout')
                or L('org_extras3.your_payout_at_the_dead_drop'))
        end
    end
    if next(Vehicles) then
        local keepFor = whole('GarageKeepMinutes', 60, 5, 1440) * 60
        local d = deps()
        local gone = {}
        for cid, v in pairs(Vehicles) do
            if v.org == org.id and (not on('Garage') or at - v.at >= keepFor or not d.identity.byCitizenId(cid)
                or not org.members[cid]) then
                gone[#gone + 1] = cid
            end
        end
        for _, cid in ipairs(gone) do removeVehicle(cid) end
    end
    if next(org.settings.internal) then
        local changed = false
        for id, r in pairs(org.settings.internal) do
            if r.state == 'pending' and (r.expires or 0) <= at then
                r.state = 'expired'
                changed = true
            elseif r.state ~= 'pending' and at - (r.decided or r.at or at) > 7 * 86400 then
                org.settings.internal[id] = nil
                changed = true
            end
        end
        if changed then kit.save() end
    end
end

-- ============================================================================
--                              WIRING
-- ============================================================================

function Extras3.attach(o, k)
    O, kit = o, k
    for name, fn in pairs(Org) do o[name] = fn end
end

--- A fresh start (Org.init): the dead drops' payout check, and the garage's
--- vehicles taken away at the stop.
function Extras3.init(d)
    Drops, Vehicles, Seq = {}, {}, 0
    Moves.reset()
    Asked.reset()
    -- Asked for here, at every start, not kept from when this file was read.
    CrimsonBoot.require('server.payout').add('deaddrop', { holds = holds, releasesAt = releasesAt, onClaim = onClaim },
        { escrow = d.escrow, contracts = d.contracts })
end

--- Every organisation (re)loaded: the drops waiting, from their settings.
function Extras3.loaded()
    Drops = {}
    for _, org in ipairs(O.all()) do
        for key in pairs(org.settings.drops) do Drops[key] = org.id end
    end
end

--- Everything out of the garage taken away (the resource stopping:
--- main.lua's onResourceStop).
function Extras3.stop()
    for cid in pairs(Vehicles) do removeVehicle(cid) end
end

--- The start-up check of these settings (Feature.check).
Extras3.CHECKS = {
    Reputation = { kind = 'switch' }, RepCompletion = { kind = 'number', integer = true, min = 0, max = 100000 },
    RepFailure = { kind = 'number', integer = true, min = 0, max = 100000 },
    RepHeat = { kind = 'number', integer = true, min = 0, max = 1000 },
    RepTiers = { kind = 'list', pattern = '^%s*%d+%s*,%s*[^,<>]+,%s*%d+%s*$', max = 80, most = 20,
        says = L('org_extras3.a_list_of_points_label_most') },
    DeadDrops = { kind = 'switch' }, DeadDropMinutes = { kind = 'number', integer = true, min = 1, max = 10080 },
    DeadDropUnclaimed = { kind = 'choice', choices = { 'pay', 'refund' } },
    Territory = { kind = 'switch' }, TerritoryMinutes = { kind = 'number', integer = true, min = 1, max = 60 },
    TerritorySightMetres = { kind = 'number', min = 5, max = 500 },
    Garage = { kind = 'switch' },
    GarageVehicles = { kind = 'list', pattern = '^[%w_]+$', max = 32, most = 50,
        says = L('org_extras3.a_list_of_vehicle_model_names') },
    GarageMaxOut = { kind = 'number', integer = true, min = 1, max = 50 },
    GarageKeepMinutes = { kind = 'number', integer = true, min = 5, max = 1440 },
    GarageReturnMetres = { kind = 'number', min = 2, max = 200 },
    InternalContracts = { kind = 'switch' },
    InternalExpireHours = { kind = 'number', integer = true, min = 1, max = 720 },
    Handler = { kind = 'switch' }, HandlerAssigns = { kind = 'switch' },
    ActivityLog = { kind = 'switch' }, ActivityKeep = { kind = 'number', integer = true, min = 10, max = 1000 },
}

---@param warn string[]
function Extras3.validate(warn)
    Feature.check('Organisation', Extras3.CHECKS, warn)
end

return Extras3
