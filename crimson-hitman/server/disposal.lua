--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                   crimson-hitman - server/disposal.lua                    ║
    ║      Body disposal: a verified kill pays once the body is dropped off     ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- Config.Disposal, off as shipped; off, nothing here reads, writes or sends
--- anything, and every hook below answers as if it were not there.
---
--- On, a verified kill (never a live handover, never a proof item, only on a
--- contract a kill may complete) claims its payout as always, and the
--- payout waits in escrow, owed to the hitman and queued, until the body is
--- dropped off: a gate on the escrow's own give (Escrow.holdBack), exactly as
--- a payout held for proof of intent waits (server/rp_intent.lua). Nothing
--- here moves money but the timeout's 'reduced' and 'refund', and the
--- optional part paid at once; each goes through the escrow's own paths
--- (Escrow.reduceStake, Escrow.release), so what was escrowed is what the
--- hitman and the placer receive between them.
---
--- The step: the hitman gets a map marker at the body (where the server
--- recorded the death), the disposal vehicle (Config.Disposal.VehicleModel)
--- is made by the server at the staff-set spawn spot, with a marker of its
--- own, locked, with keys for the hitman alone (qbx_vehiclekeys). The hitman
--- brings it to the body and loads it (ox_target at the body: the server
--- checks that both the hitman and the vehicle are there), drives to the
--- staff-set drop-off and drops it (the same check there); the payout is
--- released and the vehicle taken away. The body is a stage on the step
--- the server keeps (body, then loaded), never an item or a prop a player
--- holds: nothing to drop, trade, stash or duplicate, and nothing lost to a
--- death or a full inventory.
---
--- Its clock runs only while the hitman is in the city and nothing holds it
--- (a staff freeze on a party, the app pause, the restart hold), up to
--- TimeLimitMinutes; the hitman is told the time left as a band, staff the
--- exact figure. And it never stands for longer than MaxHoldMinutes of real
--- time from the kill, away or not (120 as shipped): past that it times out
--- as below even while the hitman is away, unless staff hold it, and from
--- then on it no longer keeps the target off the board (Contracts
--- .relistHold), so a hitman who logs off over a body cannot shield its
--- target from every new contract. On timeout: 'pay' (as shipped: nobody can grief the hitman
--- out of a kill), 'reduced' (the hitman keeps ReducedPercent of the money,
--- the rest goes back to the placer) or 'refund' (back to the placer). Kept
--- in the store (crimson_rp_rows, kind 'disposal') so a restart resumes it
--- where it was; the vehicle is made again once the hitman is in the city.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Log = CrimsonBoot.requireShared('log')
local Payout = CrimsonBoot.require('server.payout')
local Text = CrimsonBoot.requireShared('text')
local Geo = CrimsonBoot.requireShared('geo')
local Feature = CrimsonBoot.require('server.lib.feature')
local Registry = CrimsonBoot.require('server.places')

local Disposal = {}

local Deps = {}

local KIND = 'disposal'
--- The two staff-set spots, kinds of the one registry of map spots
--- (server/places.lua).
local SPOTS = { vehicle = 'disposal_vehicle', drop = 'disposal_drop' }

--- Steps in force: [id] = row { id, kind, contract_id, slot, hitman_cid,
--- creator_cid, target_cid, stage = 'body' | 'loaded', body = { x, y, z },
--- started_at, spent, respawns, paid_now }.
local Steps = {}
--- What is not kept in the store, by step id: { vehicle, reached, farSince,
--- countedAt, wroteAt, unwritten, plate, removedByUs }. removedByUs: the last
--- vehicle was taken away by this file (the hitman left, it was abandoned,
--- the stop), so the next one made is not a respawn; any other loss is.
local Runtime = {}
local loaded = false
--- When a missing setting was last said, so it is said once a minute.
local saidAt = {}

-- ============================================================================
--                              SETTINGS
-- ============================================================================

local function Cfg()
    return type(Config.Disposal) == 'table' and Config.Disposal or {}
end

local function Num(key, default)
    local v = tonumber(Cfg()[key])
    if not v or v ~= v then return default end
    return v
end

Disposal.RULES = {
    VehicleModel = { kind = 'text', pattern = '^[%w_]+$', max = 32 },
    PayNowPercent = { kind = 'number', min = 0, max = 90 },
    TimeLimitMinutes = { kind = 'number', min = 1, max = 240 },
    OnTimeout = { kind = 'choice', choices = { pay = true, reduced = true, refund = true } },
    ReducedPercent = { kind = 'number', min = 0, max = 100 },
    LoadMetres = { kind = 'number', min = 1, max = 25 },
    DropMetres = { kind = 'number', min = 1, max = 50 },
    VehicleMetres = { kind = 'number', min = 2, max = 50 },
    AbandonMetres = { kind = 'number', min = 50, max = 5000 },
    AbandonMinutes = { kind = 'number', min = 1, max = 60 },
    MaxRespawns = { kind = 'number', min = 0, max = 10 },
    DespawnSeconds = { kind = 'number', min = 0, max = 300 },
    MaxHoldMinutes = { kind = 'number', min = 10, max = 2880 },
}

--- Held to its rules at start, and against a copy on every panel change.
---@param warn string[]
function Disposal.validate(warn)
    local block = Config.Disposal
    if block == nil then return end
    if type(block) ~= 'table' then
        warn[#warn + 1] = 'Config.Disposal must be a table'
        return
    end
    if block.Enabled ~= nil and type(block.Enabled) ~= 'boolean' then
        warn[#warn + 1] = 'Config.Disposal.Enabled must be true or false'
    end
    for key, rule in pairs(Disposal.RULES) do
        local v = block[key]
        if v ~= nil then
            if rule.kind == 'number' then
                if type(v) ~= 'number' or v ~= v or v < rule.min or v > rule.max then
                    warn[#warn + 1] = ('Config.Disposal.%s must be a number from %s to %s')
                        :format(key, rule.min, rule.max)
                end
            elseif rule.kind == 'choice' then
                if not rule.choices[v] then
                    warn[#warn + 1] = ('Config.Disposal.%s must be \'pay\', \'reduced\' or \'refund\''):format(key)
                end
            elseif type(v) ~= 'string' or #v > rule.max or not v:match(rule.pattern) then
                warn[#warn + 1] = ('Config.Disposal.%s must be a vehicle model name'):format(key)
            end
        end
    end
    for _, key in ipairs({ 'VehicleSpawn', 'DropOff' }) do
        local v = block[key]
        local empty = type(v) == 'table' and next(v) == nil
        if v ~= nil and v ~= false and not empty and (type(v) ~= 'table' or not tonumber(v.x)
            or not tonumber(v.y) or not tonumber(v.z)) then
            warn[#warn + 1] = ('Config.Disposal.%s must be {} or { x = , y = , z = , h = }'):format(key)
        end
    end
end

-- ============================================================================
--                              HELPERS
-- ============================================================================

local function Say(key, text)
    local now = os.time()
    if saidAt[key] and now - saidAt[key] < 60 then return end
    saidAt[key] = now
    Log.always(text)
end

local function Point(v)
    if type(v) ~= 'table' then return nil end
    local x, y, z = Geo.finite(v.x), Geo.finite(v.y), Geo.finite(v.z)
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z, h = Geo.finite(v.h or v.heading) or 0.0 }
end

local function Dist2(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function Near(a, b, metres)
    return a ~= nil and b ~= nil and Dist2(a, b) <= metres * metres
end

local function ActorOf(cid)
    return Deps.identity and Deps.identity.byCitizenId(cid) or nil
end

--- Where the server sees a player's character, or nil.
local function PositionOf(src)
    local ok, at = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        return Point(GetEntityCoords(ped))
    end)
    return ok and at or nil
end

local function Tell(cid, title, text)
    if Deps.notify and Deps.notify.toCitizen then
        pcall(Deps.notify.toCitizen, cid, title, text, { bypassBudget = true })
    end
end

local function Refresh()
    if Deps.missionSteps then Deps.missionSteps.refresh() end
end

--- The time left as the hitman is told it: a band, never the figure.
---@param seconds number
---@return string
function Disposal.band(seconds)
    seconds = tonumber(seconds) or 0
    if seconds >= 20 * 60 then return 'plenty of time (over 20 minutes)' end
    if seconds >= 10 * 60 then return 'between 10 and 20 minutes' end
    if seconds >= 5 * 60 then return 'between 5 and 10 minutes' end
    return 'under 5 minutes'
end

local function LimitSeconds()
    return math.floor(Num('TimeLimitMinutes', 30) * 60)
end

local function LeftOf(step)
    return math.max(0, LimitSeconds() - (tonumber(step.spent) or 0))
end

--- The most real time a step may stand from the kill, in seconds
--- (MaxHoldMinutes, 120 as shipped; never below the time limit itself).
local function MaxHoldSeconds()
    return math.floor(math.max(Num('MaxHoldMinutes', 120), Num('TimeLimitMinutes', 30)) * 60)
end

--- Whether a step has stood past MaxHoldMinutes of real time.
local function PastHold(step, now)
    local started = tonumber(step.started_at)
    return started ~= nil and (now or os.time()) - started >= MaxHoldSeconds()
end

--- Whether anything holds this step's clock now: a staff freeze on one of
--- its parties, the app pause or the restart hold.
local function Held(step)
    if Holds.on(nil, nil, { 'restart', 'app' }) then return true end
    for _, cid in ipairs({ step.hitman_cid, step.creator_cid, step.target_cid }) do
        if cid and Holds.of(cid) then return true end
    end
    return false
end
Disposal.held = Held

--- Whether a step is shown held to staff who may not see who is behind an
--- anonymous party: the restart hold and the app pause, which name nobody,
--- and a freeze only through a party they may see (the target, the placer
--- unless placed anonymously, the hitman unless on it anonymously), as the
--- panel shows a contract's own hold (Holds.shown). "Held" through an
--- anonymous party, beside the measures list every reader sees, narrowed down
--- who that party was.
local function HeldShown(step)
    if Holds.on(nil, nil, { 'restart', 'app' }) then return true end
    if step.target_cid and Holds.of(step.target_cid) then return true end
    local okC, contract = pcall(Deps.storage.readContract, step.contract_id)
    contract = okC and contract or nil
    if step.creator_cid and Holds.of(step.creator_cid) and contract and contract.anon_creator ~= true then
        return true
    end
    if step.hitman_cid and Holds.of(step.hitman_cid) then
        local okH, row = pcall(Deps.storage.readHitman, step.contract_id, step.hitman_cid)
        if okH and row and row.anon ~= true then return true end
    end
    return false
end

local function Write(step)
    local rt = Runtime[step.id]
    if rt then rt.wroteAt = os.time() end
    local ok, err = pcall(Deps.storage.writeRpRow, step)
    if not ok then
        Deps.audit.rejected('disposal_not_written', step.hitman_cid, step.contract_id, { error = tostring(err) })
    end
    return ok
end

local function Load()
    if loaded then return true end
    local ok, rows = pcall(Deps.storage.readRpRows, KIND)
    if not ok or type(rows) ~= 'table' then return false end
    loaded = true
    for i = 1, #rows do
        local row = rows[i]
        if type(row.id) == 'string' and row.contract_id and row.hitman_cid then
            Steps[row.id] = row
            Runtime[row.id] = Runtime[row.id] or {}
        end
    end
    return true
end
Disposal.load = Load

--- A staff-set spot, or config.lua's, or nil.
---@param name 'vehicle'|'drop'
---@return table|nil { x, y, z, h }
function Disposal.spot(name)
    local row = SPOTS[name] and (Registry.rows(SPOTS[name]) or {})[1]
    if row then return { x = row.x, y = row.y, z = row.z, h = row.h or 0.0 } end
    return Point(name == 'vehicle' and Cfg().VehicleSpawn or Cfg().DropOff)
end

-- ============================================================================
--                              THE VEHICLE
-- ============================================================================

--- The game calls, kept apart so the tests can stand in for the world.
--- Every one is a server native or a server export, each inside pcall.
Disposal.world = {
    spawn = function(model, at)
        -- A server-made networked vehicle (OneSync): nobody's own car, with
        -- no row in any garage's table, so nothing can store or sell it.
        return CreateVehicleServerSetter(GetHashKey(model), 'automobile', at.x, at.y, at.z, at.h or 0.0)
    end,
    -- Kept by the server whoever owns it or is near it: a server-made
    -- entity is otherwise deleted by OneSync once nobody is in scope of it
    -- (orphan mode 0, DeleteWhenNotRelevant), which a hitman driving off
    -- for the body did; 2 is KeepEntity. Only this file deletes it. Guarded
    -- on an artifact without the native. And in the hitman's routing
    -- bucket (an instance they are in), or they never see it.
    keep = function(vehicle, hitmanSource)
        if type(SetEntityOrphanMode) == 'function' then SetEntityOrphanMode(vehicle, 2) end
        if hitmanSource and type(SetEntityRoutingBucket) == 'function' and type(GetPlayerRoutingBucket) == 'function' then
            local bucket = tonumber(GetPlayerRoutingBucket(hitmanSource)) or 0
            local now = type(GetEntityRoutingBucket) == 'function' and tonumber(GetEntityRoutingBucket(vehicle)) or nil
            if now ~= bucket then SetEntityRoutingBucket(vehicle, bucket) end
        end
    end,
    exists = function(vehicle)
        return vehicle ~= nil and vehicle ~= 0 and DoesEntityExist(vehicle) and true or false
    end,
    coords = function(vehicle) return Point(GetEntityCoords(vehicle)) end,
    remove = function(vehicle) DeleteEntity(vehicle) end,
    prepare = function(vehicle, plate, hitmanSource)
        Disposal.world.keep(vehicle, hitmanSource)
        SetVehicleNumberPlateText(vehicle, plate)
        -- Marked, so another resource can tell it is not a player's.
        Entity(vehicle).state:set('crimsonDisposal', true, true)
        -- Locked, the keys the hitman's alone. Without qbx_vehiclekeys it
        -- cannot be opened by keys, so it is left unlocked (and said).
        if GetResourceState('qbx_vehiclekeys') == 'started' then
            SetVehicleDoorsLocked(vehicle, 2)
            exports.qbx_vehiclekeys:GiveKeys(hitmanSource, vehicle)
        else
            SetVehicleDoorsLocked(vehicle, 1)
            return false
        end
        return true
    end,
}

local function VehicleThere(rt)
    if not rt or not rt.vehicle then return false end
    local ok, there = pcall(Disposal.world.exists, rt.vehicle)
    return ok and there == true
end

--- Take the vehicle away. Only one still there counts as taken away by
--- this file (removedByUs): a handle to a vehicle already lost, destroyed
--- or deleted by something else is a loss, and the next one made is a
--- respawn, counted, whatever happens to the hitman in between.
local function RemoveVehicle(step)
    local rt = Runtime[step.id]
    if not rt or not rt.vehicle then return end
    local vehicle = rt.vehicle
    if VehicleThere(rt) then rt.removedByUs = true end
    rt.vehicle, rt.reached, rt.farSince = nil, nil, nil
    pcall(Disposal.world.remove, vehicle)
end

--- A plate nobody can guess: two letters and six random characters, never
--- one a vehicle of a step in force has. qbx_vehiclekeys knows a key by its
--- plate, so a sequence (CHD0001, CHD0002, ...) starting again at every
--- start let a hitman holding an old key open a later disposal vehicle.
local PLATE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
local function NewPlate()
    local taken = {}
    for _, rt in pairs(Runtime) do if rt.plate then taken[rt.plate] = true end end
    for _ = 1, 20 do
        local out = { 'C', 'H' }
        for i = 3, 8 do
            local n = math.random(1, #PLATE_CHARS)
            out[i] = PLATE_CHARS:sub(n, n)
        end
        local plate = table.concat(out)
        if not taken[plate] then return plate end
    end
    return ('CH%06d'):format(math.random(0, 999999))
end
Disposal.newPlate = NewPlate

--- Make the vehicle at the spawn spot for an online hitman. A respawn counts
--- towards MaxRespawns unless staff asked for it.
---@return boolean made
local function SpawnVehicle(step, why)
    local rt = Runtime[step.id] or {}
    Runtime[step.id] = rt
    local actor = ActorOf(step.hitman_cid)
    local at = Disposal.spot('vehicle')
    if not actor or not at then return false end
    if VehicleThere(rt) then return true end
    if why ~= 'start' and why ~= 'staff' and why ~= 'rejoin' then
        if (tonumber(step.respawns) or 0) >= math.floor(Num('MaxRespawns', 3)) then return false end
        step.respawns = (tonumber(step.respawns) or 0) + 1
        Write(step)
    end
    local model = type(Cfg().VehicleModel) == 'string' and Cfg().VehicleModel or 'romero'
    local ok, vehicle = pcall(Disposal.world.spawn, model, at)
    if not ok or not vehicle or vehicle == 0 then
        Say('spawn', ('body disposal: the vehicle %s could not be made at the spawn spot (%s); check '
            .. 'Config.Disposal.VehicleModel'):format(tostring(model), tostring(vehicle)))
        return false
    end
    local plate = NewPlate()
    local prepared, keyed = pcall(Disposal.world.prepare, vehicle, plate, actor.source)
    if prepared and keyed == false then
        Say('keys', 'body disposal: qbx_vehiclekeys is not started, so the disposal vehicle is left '
            .. 'unlocked for anybody to drive')
    end
    rt.vehicle, rt.reached, rt.farSince, rt.spawnedOnce, rt.plate, rt.removedByUs = vehicle, nil, nil, true, plate, nil
    Deps.audit.action('disposal_vehicle', step.hitman_cid, step.contract_id, { why = why, plate = plate })
    return true
end

-- ============================================================================
--                              THE PAYOUT
-- ============================================================================

--- The step holding this line, if any: a baseline of its slot, to its hitman.
local function StepOf(recipientCid, line)
    if type(line) ~= 'table' or line.portion ~= CH.PORTION.BASELINE then return nil end
    for _, step in pairs(Steps) do
        if step.contract_id == line.contract_id and step.hitman_cid == recipientCid
            and tonumber(step.slot) == tonumber(line.slot) then
            return step
        end
    end
    return nil
end

--- The escrow's gate (Escrow.holdBack): whether this give waits for the
--- body. Only the hitman's baseline of the slot the kill paid.
---@return boolean wait
function Disposal.holds(recipientCid, line)
    if not loaded then
        -- Off and never read: nothing is read for it, and nothing is held.
        if not Feature.on('Disposal') then return false end
        -- Unread: whether a step stands is unknown, so a payout waits while
        -- the feature is on rather than pay out one held before a restart.
        if not Load() then return type(line) == 'table' and line.portion == CH.PORTION.BASELINE end
    end
    if next(Steps) == nil then return false end
    return StepOf(recipientCid, line) ~= nil
end

--- The lines of this step's payout still held, owed to the hitman.
local function HeldLines(step)
    local out = {}
    local ok, lines = pcall(Deps.storage.readEscrow, step.contract_id)
    if not ok then return out end
    for _, line in ipairs(lines or {}) do
        if line.portion == CH.PORTION.BASELINE and tonumber(line.slot) == tonumber(step.slot)
            and line.owed_to == step.hitman_cid and line.state == CH.ESCROW_STATE.HELD
            and not (Deps.escrow.parked and Deps.escrow.parked(line)) then
            out[#out + 1] = line
        end
    end
    return out, lines or {}
end

--- Whether a split of this line to `cid` was already made (a retry after a
--- restart makes none twice).
local function SplitTo(lines, lineId, cid)
    for _, l in ipairs(lines) do
        local mark = type(l.metadata) == 'table' and l.metadata or nil
        if l.portion == CH.PORTION.OWED and mark and mark.splitFrom == lineId and l.owed_to == cid then
            return true
        end
    end
    return false
end

--- Hand `cid` this share of each cash or bank line of the payout now, the
--- rest left on the line (Escrow.reduceStake: the owed share is written
--- before the line is lowered, and boot recovery finishes one cut off).
---@param keepPercent number what stays on each line, of 100
---@return integer moved dollars
local function SplitMoney(step, cid, keepPercent, reason)
    local moved = 0
    local held, all = HeldLines(step)
    for _, line in ipairs(held) do
        if (line.source == 'cash' or line.source == 'bank') and not SplitTo(all, line.id, cid) then
            local amount = math.floor(tonumber(line.amount) or 0) - math.max(0, math.floor(tonumber(line.deliver_arrived) or 0))
            local keep = math.floor(amount * keepPercent / 100)
            if amount > 0 and keep < amount then
                local proxy = setmetatable({ staker = cid }, { __index = line })
                local ok, owed = pcall(Deps.escrow.reduceStake, step.contract_id, proxy,
                    keep + (math.floor(tonumber(line.amount) or 0) - amount), reason)
                if ok and owed then moved = moved + (amount - keep) end
            end
        end
    end
    return moved
end

--- Every line of the payout back to the placer (the 'refund' timeout).
local function RefundAll(step)
    local back = 0
    local escrow, storage = Deps.escrow, Deps.storage
    for _, line in ipairs((HeldLines(step))) do
        local ok, _, result = pcall(escrow.release, step.contract_id, step.creator_cid, { line = line.id },
            'disposal_refund', function(claimed) return claimed.owed_to == step.hitman_cid end)
        if ok then
            local now = storage.readEscrowLine(line.id)
            if now and now.owed_to ~= step.hitman_cid then
                for _, entry in ipairs(storage.readPending(step.hitman_cid) or {}) do
                    if entry.line_id == line.id then storage.clearPending(entry.id) end
                end
                back = back + 1
            end
            if result and (result.pending or 0) > 0 then escrow.noteWaiting(step.creator_cid, true) end
        end
    end
    return back
end

-- ============================================================================
--                              THE STEP
-- ============================================================================

--- End a step: the hold lifts (the payout follows at once where the hitman
--- is in the city, else at their login), the vehicle goes, the hitman is
--- told. `why`: delivered | timeout_pay | timeout_reduced | timeout_refund |
--- staff_skip | switched_off.
local function Finish(step, why)
    if not Steps[step.id] then return false end
    Steps[step.id] = nil
    local rt = Runtime[step.id]
    Runtime[step.id] = nil
    pcall(Deps.storage.deleteRpRow, step.id)
    Deps.audit.financial('disposal_done', step.hitman_cid, step.contract_id,
        { why = why, spent = tonumber(step.spent) or 0, slot = step.slot })
    if rt and rt.vehicle then
        local vehicle = rt.vehicle
        local wait = math.floor(Num('DespawnSeconds', 10) * 1000)
        if why == 'delivered' and wait > 0 then
            SetTimeout(wait, function() pcall(Disposal.world.remove, vehicle) end)
        else
            pcall(Disposal.world.remove, vehicle)
        end
    end
    local escrow = Deps.escrow
    escrow.noteWaiting(step.hitman_cid, true)
    if ActorOf(step.hitman_cid) then pcall(escrow.retryPending, step.hitman_cid) end
    local words = {
        delivered = 'The body is dropped off: your payout is being handed over.',
        timeout_pay = 'Time ran out on the body, but your payout is being handed over.',
        timeout_reduced = 'Time ran out on the body: part of your payout went back to the placer, '
            .. 'and the rest is being handed over.',
        timeout_refund = 'Time ran out on the body: your payout went back to the placer.',
        staff_skip = 'Staff finished the disposal for you: your payout is being handed over.',
        switched_off = 'Body disposal is switched off: your payout is being handed over.',
    }
    Tell(step.hitman_cid, 'Body disposal', words[why] or words.timeout_pay)
    Refresh()
    return true
end

--- Time ran out.
local function TimedOut(step)
    local mode = Cfg().OnTimeout
    if mode == 'refund' then
        RefundAll(step)
    elseif mode == 'reduced' then
        SplitMoney(step, step.creator_cid, math.max(0, math.min(100, Num('ReducedPercent', 50))),
            'disposal_reduced')
    else
        mode = 'pay'
    end
    return Finish(step, 'timeout_' .. mode)
end

--- The part paid at once (PayNowPercent), once.
local function PayNow(step)
    if step.paid_now then return end
    local pct = math.max(0, math.min(90, Num('PayNowPercent', 0)))
    if pct > 0 then
        SplitMoney(step, step.hitman_cid, 100 - pct, 'disposal_pay_now')
    end
    step.paid_now = true
    Write(step)
end

local function Instructions(step)
    return ('Get rid of the body. A disposal vehicle is waiting at the spot marked on your map: take '
        .. 'it to the body (marked), load it, and drive it to the drop-off (marked once it is loaded). '
        .. 'You are paid at the drop-off. Time left: %s.'):format(Disposal.band(LeftOf(step)))
end

--- A claim is about to release a payout (Contracts.claimSlot, under its
--- lock; the 'disposal' payout check, asked ahead of proof of intent). A verified kill on a
--- contract a kill may complete, with both spots set, starts a step here,
--- written down once the claim has gone through (Disposal.afterClaim).
function Disposal.onClaim(contract, hitmanCid, fulfilment, opts)
    if not Feature.on('Disposal') or type(contract) ~= 'table' or not hitmanCid then return end
    if fulfilment ~= CH.FULFILMENT.ELIMINATION then return end
    if type(opts) == 'table' and opts.outcome ~= nil and opts.outcome ~= CH.FULFILMENT.ELIMINATION then return end
    if Util.fulfilmentRule(contract) ~= CH.FULFILMENT_RULE.EITHER then return end
    local kill = Deps.death and Deps.death.getPending and Deps.death.getPending(contract.id, hitmanCid)
    local body = kill and Point(kill.coords)
    if not body then return end
    if not Load() then return end
    if not Disposal.spot('vehicle') or not Disposal.spot('drop') then
        Say('spots', 'body disposal is on but its vehicle spawn spot or its drop-off is not set, so kills '
            .. 'pay at once (admin panel: Locations, placeSet)')
        return
    end
    local slot = tonumber(contract.next_slot) or 1
    local id = ('disposal:%s:%d'):format(contract.id, slot)
    if Steps[id] then return end
    Steps[id] = { id = id, kind = KIND, contract_id = contract.id, slot = slot, hitman_cid = hitmanCid,
        creator_cid = contract.creator_cid, target_cid = contract.target_cid, stage = 'body',
        body = { x = body.x, y = body.y, z = body.z }, started_at = os.time(), spent = 0, respawns = 0 }
    Runtime[id] = { unwritten = true }
end

--- The claim a step was started for has ended. Gone through (or raised
--- part-way, its payout possibly owed): written down, the part paid at once
--- handed over, the vehicle made and the hitman told. Refused: forgotten.
function Disposal.afterClaim(contractId, hitmanCid, claimed)
    for id, step in pairs(Steps) do
        local rt = Runtime[id]
        if step.contract_id == contractId and step.hitman_cid == hitmanCid and rt and rt.unwritten then
            rt.unwritten = nil
            if not claimed then
                Steps[id], Runtime[id] = nil, nil
            else
                Write(step)
                Deps.audit.financial('disposal_started', hitmanCid, contractId,
                    { slot = step.slot, limit = LimitSeconds() })
                PayNow(step)
                SpawnVehicle(step, 'start')
                Tell(hitmanCid, 'Body disposal', Instructions(step))
                Refresh()
            end
        end
    end
end

--- Whether a body on this target is still being disposed of: no new
--- contract on them meanwhile (chained ahead of Contracts.relistHold, with
--- the roleplay consequences' EMS rule).
function Disposal.namesTarget(cid)
    if next(Steps) == nil then return false end
    local now = os.time()
    for _, step in pairs(Steps) do
        -- Not past MaxHoldMinutes of real time: a step left standing (the
        -- hitman away, or staff holding it) stops shielding its target then.
        if step.target_cid == cid and not PastHold(step, now) then return true end
    end
    return false
end

-- ============================================================================
--                              THE HITMAN'S ACTIONS
-- ============================================================================

local function StepFor(cid, contractId)
    local best
    for _, step in pairs(Steps) do
        if step.hitman_cid == cid and step.contract_id == contractId and not (Runtime[step.id] or {}).unwritten
            and (not best or step.slot < best.slot) then
            best = step
        end
    end
    return best
end

--- Load the body, or drop it off: everything read on the server.
---@param actor table
---@param action 'load'|'drop'
---@param contractId string
---@return boolean ok
---@return string|nil why
function Disposal.act(actor, action, contractId)
    local step = StepFor(actor.cid, contractId)
    if not step then return false, 'no_step' end
    if Held(step) then
        Tell(actor.cid, 'Body disposal', 'The contract is on hold: nothing can be done with the body until it is lifted.')
        return false, 'held'
    end
    local rt = Runtime[step.id] or {}
    local me = PositionOf(actor.source)
    local vehicleAt = VehicleThere(rt) and Disposal.world.coords(rt.vehicle) or nil
    local vehicleMetres = Num('VehicleMetres', 10)
    if action == 'load' then
        if step.stage ~= 'body' then return false, 'stage' end
        if not Near(me, step.body, Num('LoadMetres', 3)) then return false, 'far' end
        if not Near(vehicleAt, step.body, vehicleMetres) then
            Tell(actor.cid, 'Body disposal', 'Bring the disposal vehicle up to the body first.')
            return false, 'no_vehicle'
        end
        step.stage = 'loaded'
        Write(step)
        Deps.audit.action('disposal_loaded', actor.cid, step.contract_id, {})
        Tell(actor.cid, 'Body disposal', ('The body is loaded. Drive it to the drop-off marked on your map. '
            .. 'Time left: %s.'):format(Disposal.band(LeftOf(step))))
        Refresh()
        return true
    elseif action == 'drop' then
        local drop = Disposal.spot('drop')
        if step.stage ~= 'loaded' or not drop then return false, 'stage' end
        if not Near(me, drop, Num('DropMetres', 8)) then return false, 'far' end
        if not Near(vehicleAt, drop, vehicleMetres) then
            Tell(actor.cid, 'Body disposal', 'The body is in the disposal vehicle: bring the vehicle here.')
            return false, 'no_vehicle'
        end
        Finish(step, 'delivered')
        return true
    end
    return false, 'bad_action'
end

-- ============================================================================
--                              THE TICK
-- ============================================================================

--- From the maintenance tick: each step's clock counted, its timeout, the
--- vehicle made for an online hitman, taken away when they are gone or have
--- left it. Nothing at all with no step.
---@return integer finished
function Disposal.tick()
    if not loaded then
        -- Off and never read: nothing at all. A step kept from when it was on
        -- holds nothing meanwhile (Disposal.holds), and is finished once it
        -- is on again.
        if not Feature.on('Disposal') or not Load() then return 0 end
    end
    if next(Steps) == nil then return 0 end
    local now, finished = os.time(), 0
    local ids = {}
    for id in pairs(Steps) do ids[#ids + 1] = id end
    table.sort(ids)
    local changed = false
    for _, id in ipairs(ids) do
        local step, rt = Steps[id], Runtime[id] or {}
        Runtime[id] = rt
        if step and not rt.unwritten then
            local actor = ActorOf(step.hitman_cid)
            local was = rt.countedAt or now
            rt.countedAt = now
            if not Feature.on('Disposal') then
                if Finish(step, 'switched_off') then finished = finished + 1 end
            elseif PastHold(step, now) and not Held(step) then
                -- Stood past MaxHoldMinutes of real time, the hitman in the
                -- city or not: timed out as OnTimeout says.
                Deps.audit.action('disposal_hold_capped', step.hitman_cid, step.contract_id,
                    { away = actor == nil or nil })
                if TimedOut(step) then finished = finished + 1 end
            elseif not actor then
                -- Away: the clock stands, the vehicle goes, the stage stays.
                if rt.vehicle then
                    RemoveVehicle(step)
                    changed = true
                end
            elseif Held(step) then
                -- On hold: the clock stands, the vehicle stays where it is.
                rt.farSince = nil
            else
                step.spent = (tonumber(step.spent) or 0) + math.max(0, now - was)
                if step.spent >= LimitSeconds() then
                    if TimedOut(step) then finished = finished + 1 end
                else
                    if now - (rt.wroteAt or 0) >= 60 then Write(step) end
                    if not VehicleThere(rt) then
                        if rt.vehicle then rt.vehicle = nil end
                        -- Taken away by this file (the hitman left), or after
                        -- a restart: not counted. Any other loss is, a relog
                        -- in between or not.
                        local why = (rt.removedByUs or not rt.spawnedOnce) and 'rejoin' or 'lost'
                        if SpawnVehicle(step, why) then changed = true end
                    else
                        -- Into whatever routing bucket the hitman moved to.
                        pcall(Disposal.world.keep, rt.vehicle, actor.source)
                        local me = PositionOf(actor.source)
                        local at = Disposal.world.coords(rt.vehicle)
                        if me and at then
                            if Near(me, at, 15) then
                                if not rt.reached then changed = true end
                                rt.reached, rt.farSince = true, nil
                            elseif rt.reached and not Near(me, at, Num('AbandonMetres', 300)) then
                                rt.farSince = rt.farSince or now
                                if now - rt.farSince >= Num('AbandonMinutes', 5) * 60 then
                                    -- Left behind: taken away, and made again at the spawn spot.
                                    Deps.audit.action('disposal_abandoned', step.hitman_cid, step.contract_id, {})
                                    RemoveVehicle(step)
                                    SpawnVehicle(step, 'abandoned')
                                    changed = true
                                end
                            else
                                rt.farSince = nil
                            end
                        end
                    end
                end
            end
        end
    end
    if changed then Refresh() end
    return finished
end

--- A player left the city: their vehicle goes (made again when they are
--- back), the step and its clock stand.
---@param cid string
function Disposal.playerLeft(cid)
    if not cid or next(Steps) == nil then return end
    for _, step in pairs(Steps) do
        if step.hitman_cid == cid then RemoveVehicle(step) end
    end
end

--- The resource stops: every vehicle goes, and every step stays in the
--- store. In memory mode nothing outlives the stop, so each hold is lifted
--- (the stop's release then hands the payout over).
---@param lift boolean|nil
function Disposal.stop(lift)
    for _, step in pairs(Steps) do RemoveVehicle(step) end
    if lift then Steps, Runtime = {}, {} end
end

-- ============================================================================
--                              MARKERS
-- ============================================================================

--- The step's markers (server/missionsteps.lua), to the hitman alone: the
--- body (until loaded), the vehicle's spawn spot (until they reach it), the
--- drop-off (once loaded).
local function Markers(add)
    for _, step in pairs(Steps) do
        local rt = Runtime[step.id] or {}
        if not rt.unwritten and step.hitman_cid ~= step.target_cid then
            local cid, ref = step.hitman_cid, step.contract_id
            if step.stage == 'body' then
                add(cid, 'disposal_body:' .. ref, { kind = 'disposal_body', x = step.body.x, y = step.body.y,
                    z = step.body.z, act = 'load', ref = ref })
            else
                local drop = Disposal.spot('drop')
                if drop then
                    add(cid, 'disposal_drop:' .. ref, { kind = 'disposal_drop', x = drop.x, y = drop.y,
                        z = drop.z, act = 'drop', ref = ref })
                end
            end
            local spawn = Disposal.spot('vehicle')
            if spawn and rt.vehicle and not rt.reached then
                add(cid, 'disposal_vehicle:' .. ref, { kind = 'disposal_vehicle', x = spawn.x, y = spawn.y, z = spawn.z })
            end
        end
    end
end

-- ============================================================================
--                              STAFF
-- ============================================================================

--- Every step, as staff see it: the exact time left.
---@return table[]
function Disposal.list()
    Load()
    local out = {}
    for _, step in pairs(Steps) do
        local rt = Runtime[step.id] or {}
        out[#out + 1] = { id = step.id, contract = step.contract_id, slot = step.slot, hitman = step.hitman_cid,
            stage = step.stage, secondsLeft = LeftOf(step), spent = tonumber(step.spent) or 0,
            held = Held(step), vehicle = VehicleThere(rt), respawns = tonumber(step.respawns) or 0,
            startedAt = step.started_at }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function StepById(id)
    Load()
    if type(id) ~= 'string' then return nil end
    local step = Steps[id]
    if step then return step end
    -- A contract id: its first step.
    local best
    for _, s in pairs(Steps) do
        if s.contract_id == id and (not best or s.slot < best.slot) then best = s end
    end
    return best
end

--- Finish a step as if the body had been dropped off.
function Disposal.skip(staffCid, id)
    local step = StepById(id)
    if not step or (Runtime[step.id] or {}).unwritten then return false, 'not_found' end
    Deps.audit.action('disposal_staff_skip', staffCid, step.contract_id, { step = step.id })
    Finish(step, 'staff_skip')
    return true
end

--- Make the vehicle again at the spawn spot (not counted as a respawn).
function Disposal.respawn(staffCid, id)
    local step = StepById(id)
    if not step or (Runtime[step.id] or {}).unwritten then return false, 'not_found' end
    if not ActorOf(step.hitman_cid) then return false, 'away' end
    RemoveVehicle(step)
    if not SpawnVehicle(step, 'staff') then return false, 'no_spot' end
    Deps.audit.action('disposal_staff_respawn', staffCid, step.contract_id, { step = step.id })
    Refresh()
    return true
end

--- How many steps are in force (the diagnosis, the tests).
function Disposal.count()
    local n = 0
    for _ in pairs(Steps) do n = n + 1 end
    return n
end

--- A step's runtime (its vehicle, whether it was reached), for the tests.
function Disposal.runtime(id) return Runtime[id] end

-- ============================================================================
--                              WIRING
-- ============================================================================

--- The vehicle spawn and the drop-off as kinds of the registry: staff only,
--- one each, set whether disposal is on or off (config.lua's VehicleSpawn
--- and DropOff apply while one is not set); audited disposal_spot_set /
--- disposal_spot_cleared.
local function RegisterSpots()
    for _, name in ipairs({ 'vehicle', 'drop' }) do
        local kindName = SPOTS[name]
        Registry.kind(kindName, {
            group = 'disposal', icon = name == 'vehicle' and 'truck' or 'flag-checkered',
            label = name == 'vehicle' and 'Disposal vehicle spawn' or 'Body drop-off',
            one = name == 'vehicle' and 'the vehicle spawn' or 'the drop-off', single = true,
            max = function() return 1 end,
            says = { invalid_input = 'Give the spot (vehicle or drop) and a point on the map.' },
            after = function(who, row)
                Deps.audit.action('disposal_spot_set', who.cid, nil, { spot = name })
                Refresh()
            end,
            removed = function(who)
                Deps.audit.action('disposal_spot_cleared', who.cid, nil, { spot = name })
                Refresh()
            end,
            view = function()
                local cfg = Point(name == 'vehicle' and Cfg().VehicleSpawn or Cfg().DropOff)
                return { on = Feature.on('Disposal'), switch = 'Disposal.Enabled', defaults = cfg and { cfg } or {},
                    using = (Registry.rows(kindName) or {})[1] and 'panel' or 'config',
                    note = 'Body disposal cannot start a step until both are set.' }
            end,
        })
    end
end

local function AddOps(panel)
    if not (panel and panel.extend and panel.LEVELS) then return end
    local READ, WRITE = panel.LEVELS.READ, panel.LEVELS.WRITE
    local function staffCid(src) return panel.staffOf and panel.staffOf(src) or ('player ' .. tostring(src)) end
    Disposal.OPS = {
        disposalList = READ, disposalSkip = WRITE, disposalRespawn = WRITE,
    }
    panel.extend('disposalList', READ, function(src)
        -- Who the hitman is goes only to staff with the identity ACE, as
        -- every other list of the panel's names them.
        local steps = Disposal.list()
        if not (panel.identifies and panel.identifies(src)) then
            for _, step in ipairs(steps) do
                step.hitman = nil
                step.held = Steps[step.id] ~= nil and HeldShown(Steps[step.id]) or false
            end
        end
        return true, nil, nil, { enabled = Feature.on('Disposal'), steps = steps,
            spots = { vehicle = Disposal.spot('vehicle'), drop = Disposal.spot('drop') },
            limitSeconds = LimitSeconds(), onTimeout = Cfg().OnTimeout or 'pay' }
    end)
    panel.extend('disposalSkip', WRITE, function(src, data)
        local ok, err = Disposal.skip(staffCid(src), Text.field(data.id, 64))
        if not ok then return false, err, 'No disposal step by that id.' end
        return true, nil, 'Finished: the payout is being handed over.'
    end)
    panel.extend('disposalRespawn', WRITE, function(src, data)
        local ok, err = Disposal.respawn(staffCid(src), Text.field(data.id, 64))
        if not ok then
            return false, err, err == 'away' and 'The hitman is not in the city: the vehicle is made when they are back.'
                or err == 'no_spot' and 'The vehicle could not be made: set the spawn spot and check the model.'
                or 'No disposal step by that id.'
        end
        return true, nil, 'The vehicle is back at the spawn spot.'
    end)
end

--- The hitman's two actions, from their ox_target options
--- (client/missionsteps.lua), through the app's own gate (App.addHandler:
--- the event's source resolved there, the flood guard, the 'disposal'
--- bucket), then the payload's two fields, and every position read here.
local function AddEvent()
    local app = Deps.app
    if not (app and app.addHandler) then return end
    app.addHandler('disposalAct', 'disposal', function(actor, payload)
        if next(Steps) == nil then return false, CH.ERR.NOT_FOUND end
        local action = type(payload) == 'table' and payload.action or nil
        local contractId = type(payload) == 'table' and Util.toId(payload.id) or nil
        if (action ~= 'load' and action ~= 'drop') or not contractId then
            Deps.audit.rejected('disposal_bad_payload', actor.cid, nil, {})
            return false, CH.ERR.INVALID_INPUT
        end
        if not Disposal.act(actor, action, contractId) then return false, CH.ERR.NOT_FOUND end
        return true
    end)
end

---@param deps table { storage, identity, audit, notify, escrow, contracts, death, freeze, missionSteps, ratelimit, app, panel }
function Disposal.init(deps)
    Deps = deps or {}
    -- Read lazily, at the first give or tick that asks: nothing at start.
    Steps, Runtime, loaded, saidAt = {}, {}, false, {}
    Registry.attach(Deps.storage)
    RegisterSpots()
    local escrow, contracts = Deps.escrow, Deps.contracts
    -- One of the payout checks (server/payout.lua), asked ahead of the
    -- proof-of-intent hold: the escrow's gate, and the claim's two hooks.
    Payout.add('disposal', { holds = Disposal.holds, onClaim = Disposal.onClaim,
        afterClaim = Disposal.afterClaim }, { escrow = escrow, contracts = contracts })
    if contracts then
        local relist = contracts.relistHold
        contracts.relistHold = function(targetActor)
            if targetActor and Disposal.namesTarget(targetActor.cid) then return true end
            if relist then return relist(targetActor) end
            return false
        end
    end
    if Deps.missionSteps then
        Deps.missionSteps.addProvider('disposal', Markers, function() return next(Steps) ~= nil end)
    end
    AddOps(Deps.panel)
    AddEvent()
end

return Disposal
