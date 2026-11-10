--[[
    ╔═══════════════════════════════════════════════════════════════════════════╗
    ║                 crimson-hitman - server/missionsteps.lua                  ║
    ║      Map markers for each step of a contract, to the party who acts       ║
    ╚═══════════════════════════════════════════════════════════════════════════╝
]]

--- One marker system for every step of a contract (Config.StepMarkers). Each
--- step says, from what the server already keeps in memory, which player
--- must act on it and where (a provider); this file works out what every
--- player's map should show, sends each change to that player's game alone
--- (crimson-hitman:client:StepMarker / StepMarkerClear, drawn by
--- client/missionsteps.lua) and nothing to the page.
---
--- The steps drawn here:
---   * kill    the hitman a kill was attributed to: where the body lay when
---             the server recorded the death, until it is verified, lapses,
---             the target is revived, the hitman leaves or the contract ends;
---   * handover the placer and the hitman who armed a live handover: a
---             circle of Config.Kidnap.Radius at the point it was armed, for
---             as long as the countdown runs;
---   * guard   a bodyguard holding a protection job: their client's meeting
---             pin, until the job ends (moved with the pin);
---   * disposal the hitman disposing of a body (server/disposal.lua): the
---             body, the vehicle's spawn spot and the drop-off.
--- The informant tip (server/locationtip.lua) and the meeting point
--- (server/meeting.lua) keep their own events, which the client draws with
--- the same system. Every marker is a fixed point the server recorded, never
--- anybody's live position, and none is ever sent to the target or to a
--- bystander. Players' games drop theirs at a logout and at a stop; the server
--- forgets a player when they leave and draws theirs again when their app asks
--- (MissionSteps.reshow). With nothing to draw nothing is sent and nothing
--- runs but one look on the maintenance tick.

local Util = CrimsonBoot.requireShared('util')
local Geo = CrimsonBoot.requireShared('geo')
local Log = CrimsonBoot.requireShared('log')
local Feature = CrimsonBoot.require('server.lib.feature')
local Markers = CrimsonBoot.require('server.lib.markers')

local MissionSteps = {}

local Deps = {}

--- What each player's game was last sent: [cid] = { [key] = marker }.
local Shown = {}
--- Where each running handover was armed: [contractId .. ':' .. hitmanCid] =
--- { contractId, hitmanCid, creatorCid, targetCid, x, y, radius }.
local Arms = {}

--- The steps' own providers by name, each fn(add) calling add(cid, key,
--- marker) for every marker it wants drawn now, and whether each has
--- anything to draw at all (busy). server/disposal.lua adds its
--- (MissionSteps.addProvider).
local Providers = {}  -- [name] = { fn = function(add), busy = function(): boolean }

--- The kinds a marker may be: the client has a style for each.
MissionSteps.KINDS = {
    kill = true, handover = true, guard = true,
    disposal_body = true, disposal_vehicle = true, disposal_drop = true,
}


-- ============================================================================
--                              SETTINGS
-- ============================================================================

local function Block()
    return type(Config.StepMarkers) == 'table' and Config.StepMarkers or {}
end

--- Whether the step markers are on, and this step's own switch.
---@param step string|nil 'KillScene' | 'Handover' | 'Protection'
---@return boolean
function MissionSteps.enabled(step)
    local block = Block()
    if block.Enabled ~= true then return false end
    if step == nil then return true end
    return block[step] ~= false
end

--- Held to its rules at start and on every panel change.
---@param warn string[]
function MissionSteps.validate(warn)
    local block = Config.StepMarkers
    if block == nil then return end
    if type(block) ~= 'table' then
        warn[#warn + 1] = 'Config.StepMarkers must be a table'
        return
    end
    for _, key in ipairs({ 'Enabled', 'KillScene', 'Handover', 'Protection' }) do
        if block[key] ~= nil and type(block[key]) ~= 'boolean' then
            warn[#warn + 1] = ('Config.StepMarkers.%s must be true or false'):format(key)
        end
    end
end

-- ============================================================================
--                              HELPERS
-- ============================================================================

--- A point as the client is sent it, to a tenth of a metre.
local function Round(v) return math.floor(v * 10 + 0.5) / 10 end

--- Two markers the same, as far as the player's map is concerned.
local function Same(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for _, k in ipairs({ 'kind', 'x', 'y', 'z', 'radius', 'act', 'ref' }) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

--- A marker made well: a known kind and a finite point, or nil.
---@return table|nil
local function Clean(marker)
    if type(marker) ~= 'table' or not MissionSteps.KINDS[marker.kind] then return nil end
    local x, y = Geo.finite(marker.x), Geo.finite(marker.y)
    if not x or not y then return nil end
    local out = { kind = marker.kind, x = Round(x), y = Round(y) }
    local z = Geo.finite(marker.z)
    if z then out.z = Round(z) end
    local r = Geo.finite(marker.radius)
    if r and r > 0 then out.radius = math.min(2000, Round(r)) end
    if marker.act == 'load' or marker.act == 'drop' then out.act = marker.act end
    if type(marker.ref) == 'string' then out.ref = Util.toId(marker.ref) end
    return out
end

-- ============================================================================
--                              THE STEPS
-- ============================================================================

--- The kill to verify: the hitman it was attributed to, at the body.
local function KillScene(add)
    if not MissionSteps.enabled('KillScene') or not Deps.death or not Deps.death.pendingKills then return end
    for _, kill in ipairs(Deps.death.pendingKills()) do
        local at = kill.coords
        if at and kill.hitmanCid ~= kill.victimCid then
            add(kill.hitmanCid, 'kill:' .. kill.contractId, { kind = 'kill', x = at.x, y = at.y, z = at.z })
        end
    end
end

--- A handover counting down: the placer and the hitman, a circle at the
--- point it was armed. A countdown no longer running is forgotten.
local function Handover(add)
    if next(Arms) == nil then return end
    local armedAt = Deps.kidnap and Deps.kidnap.armedAt
    local on = MissionSteps.enabled('Handover')
    for k, arm in pairs(Arms) do
        if not armedAt or not armedAt(arm.contractId, arm.hitmanCid) then
            Arms[k] = nil
        elseif on then
            local marker = { kind = 'handover', x = arm.x, y = arm.y, radius = arm.radius }
            local key = 'handover:' .. arm.contractId
            if arm.hitmanCid ~= arm.targetCid then add(arm.hitmanCid, key, marker) end
            if arm.creatorCid and arm.creatorCid ~= arm.targetCid then add(arm.creatorCid, key, marker) end
        end
    end
end

--- A protection job held: the guard, at their client's meeting pin.
local function Guard(add)
    local protection = Deps.rpProtection
    if not MissionSteps.enabled('Protection') or not protection or not protection.all
        or not Feature.on('Roleplay.Protection') then
        return
    end
    for _, job in ipairs(protection.all() or {}) do
        local pin = job.pin
        if job.state == 'taken' and job.guard_cid and type(pin) == 'table'
            and job.guard_cid ~= job.target_cid then
            add(job.guard_cid, 'guard:' .. tostring(job.id), { kind = 'guard', x = pin.x, y = pin.y })
        end
    end
end

local BUILT_IN = { kill = KillScene, handover = Handover, guard = Guard }

--- Every marker every player should have now: [cid] = { [key] = marker }.
local function Wanted()
    local want = {}
    local function add(cid, key, marker)
        if type(cid) ~= 'string' or type(key) ~= 'string' then return end
        local clean = Clean(marker)
        if not clean then return end
        want[cid] = want[cid] or {}
        want[cid][key] = clean
    end
    for name, fn in pairs(BUILT_IN) do
        local ok, err = pcall(fn, add)
        if not ok then Log.debug(('step markers: %s raised: %s'):format(name, tostring(err))) end
    end
    for name, provider in pairs(Providers) do
        local ok, err = pcall(provider.fn, add)
        if not ok then Log.debug(('step markers: %s raised: %s'):format(name, tostring(err))) end
    end
    return want
end

-- ============================================================================
--                              SENDING
-- ============================================================================

--- Bring every map in line with the steps: each marker no longer wanted
--- taken off, each new or moved one drawn, to that player's game alone.
--- Never raises.
---@return integer sent events sent
function MissionSteps.refresh()
    local ok, sent = pcall(function()
        local want = Wanted()
        local n = 0
        for cid, keys in pairs(Shown) do
            local wanted = want[cid]
            for key in pairs(keys) do
                if not (wanted and wanted[key]) then
                    keys[key] = nil
                    local src = Deps.identity and Deps.identity.sourceOf(cid)
                    if Markers.clear(src, key) then n = n + 1 end
                end
            end
            if next(keys) == nil then Shown[cid] = nil end
        end
        for cid, keys in pairs(want) do
            local src
            for key, marker in pairs(keys) do
                local had = Shown[cid] and Shown[cid][key]
                if not Same(had, marker) then
                    src = src or (Deps.identity and Deps.identity.sourceOf(cid))
                    if not src then break end
                    Markers.show(src, key, marker)
                    Shown[cid] = Shown[cid] or {}
                    Shown[cid][key] = marker
                    n = n + 1
                end
            end
        end
        return n
    end)
    if not ok then
        Log.debug(('step markers could not be brought up to date: %s'):format(tostring(sent)))
        return 0
    end
    return sent
end

--- This player's game asked for its markers again (their app is theirs once
--- more: a restart, a login): every one they should have is drawn again.
---@param actor table
---@return integer drawn
function MissionSteps.reshow(actor)
    if not actor or not actor.cid then return 0 end
    Shown[actor.cid] = nil
    MissionSteps.refresh()
    local n = 0
    for _ in pairs(Shown[actor.cid] or {}) do n = n + 1 end
    return n
end

--- This player has left the city or the character: their game took its
--- markers off itself, so nothing is sent.
---@param cid string
function MissionSteps.forget(cid)
    if cid then Shown[cid] = nil end
end

--- From the maintenance tick: steps that lapsed on their own (a kill aged
--- out) taken off. Nothing at all while nothing is drawn or waiting.
function MissionSteps.tick()
    local busy = next(Shown) ~= nil or next(Arms) ~= nil
        or (Deps.death and Deps.death.pendingCount and Deps.death.pendingCount() > 0)
        or (MissionSteps.enabled('Protection') and Deps.rpProtection
            and Feature.on('Roleplay.Protection'))
    if not busy then
        for _, provider in pairs(Providers) do
            local ok, has = pcall(provider.busy)
            if ok and has then
                busy = true
                break
            end
        end
    end
    if busy then MissionSteps.refresh() end
    return busy
end

--- Add a step's markers (server/disposal.lua).
---@param name string
---@param fn function(add) add(cid, key, marker) for each marker wanted now
---@param busy function(): boolean whether it has anything to draw at all
function MissionSteps.addProvider(name, fn, busy)
    if type(name) == 'string' and type(fn) == 'function' then
        Providers[name] = { fn = fn, busy = type(busy) == 'function' and busy or function() return true end }
    end
end

--- What each player has drawn now, for the tests and /ch-diag.
---@return table [cid] = { [key] = marker }
function MissionSteps.shown()
    return Util.copy(Shown)
end

-- ============================================================================
--                              WIRING
-- ============================================================================

--- Run fn after module[name] each time it is called, whatever it answered.
--- Once per module table, however often init runs.
local function After(module, name, fn)
    if type(module) ~= 'table' or type(module[name]) ~= 'function' then return end
    local marks = rawget(module, '__stepMarkers') or {}
    rawset(module, '__stepMarkers', marks)
    if marks[name] then
        marks[name].fn = fn
        return
    end
    local real = module[name]
    local entry = { fn = fn }
    marks[name] = entry
    module[name] = function(...)
        local out = table.pack(real(...))
        local ok, err = pcall(entry.fn, out, ...)
        if not ok then Log.debug(('step markers after %s: %s'):format(name, tostring(err))) end
        return table.unpack(out, 1, out.n)
    end
end

--- The point a handover was armed at: where the server sees the hitman.
local function NoteArm(out, contractId, hitmanCid)
    if out[1] ~= true then return end
    contractId = Util.toId(contractId)
    if not contractId or not hitmanCid then return end
    local k = contractId .. ':' .. hitmanCid
    if not Arms[k] then
        local src = Deps.identity and Deps.identity.sourceOf(hitmanCid)
        local coords = src and GetEntityCoords(GetPlayerPed(src))
        local x, y = coords and Geo.finite(coords.x), coords and Geo.finite(coords.y)
        local contract = Deps.storage and Deps.storage.readContract(contractId)
        if x and y and contract then
            Arms[k] = { contractId = contractId, hitmanCid = hitmanCid, creatorCid = contract.creator_cid,
                        targetCid = contract.target_cid, x = x, y = y,
                        radius = tonumber(Config.Kidnap and Config.Kidnap.Radius) or 10 }
        end
    end
    MissionSteps.refresh()
end

---@param deps table { identity, storage, death, kidnap, rpProtection }
function MissionSteps.init(deps)
    Deps = deps or {}
    Shown, Arms, Providers = {}, {}, {}
    local refresh = function() MissionSteps.refresh() end
    local death, kidnap, protection = Deps.death, Deps.kidnap, Deps.rpProtection
    -- The kill scene: drawn as the kill is attributed, off as it is verified,
    -- revived, dropped with the hitman or the contract.
    for _, name in ipairs({ 'attributeDeath', 'clearPending', 'clearContract', 'onRevived', 'sweep' }) do
        After(death, name, refresh)
    end
    -- The handover: drawn as it is armed, off as it ends.
    After(kidnap, 'arm', function(out, contractId, hitmanCid) NoteArm(out, contractId, hitmanCid) end)
    -- And a handover the placer declined, or did not confirm in time
    -- (Config.Kidnap.PlacerConfirms): the countdown is gone with no tick
    -- after it, so its circle is taken off here.
    for _, name in ipairs({ 'cancel', 'clearContract', 'clearPlayer', 'answer', 'notConfirmed' }) do
        After(kidnap, name, refresh)
    end
    After(kidnap, 'tick', function() if next(Arms) ~= nil then MissionSteps.refresh() end end)
    -- The guard's pin: drawn as the job is taken, moved with it, off as it ends.
    for _, name in ipairs({ 'accept', 'movePin', 'cancel', 'sweep', 'prune' }) do After(protection, name, refresh) end
end

-- ============================================================================
--                              PANEL SETTINGS
-- ============================================================================

--- The admin panel's settings for both (server/settings.lua adds them, in
--- their own category, 'mission-steps'). The disposal spots are not here:
--- they are set with the panel's disposalSpotSet, as places are.
local GROUP, DISPOSAL = 'Step markers', 'Body disposal'
local AT_USE = 'Read each time it is used.'
local NEXT = 'Read at the next verified kill: a disposal already under way finishes as it started.'
local function Row(key, kind, label, about, inflight, extra)
    local entry = { key = key, section = kind == 'switch' and 'features' or 'limits', category = 'mission-steps',
        group = key:match('^StepMarkers') and GROUP or DISPOSAL, kind = kind, label = label, about = about,
        inflight = inflight }
    for k, v in pairs(extra or {}) do entry[k] = v end
    return entry
end
MissionSteps.CATALOGUE = {
    Row('StepMarkers.Enabled', 'switch', 'Map markers for each step',
        'Each step of a contract is marked on the map of the one party who acts on it, never the target\'s.',
        'Markers already drawn come off, or go on, within one maintenance tick.'),
    Row('StepMarkers.KillScene', 'switch', 'Mark the kill to verify',
        'The hitman sees where the body lies until the kill is verified or lapses.', AT_USE),
    Row('StepMarkers.Handover', 'switch', 'Mark the handover circle',
        'The placer and the hitman see the handover circle while it counts down.', AT_USE),
    Row('StepMarkers.Protection', 'switch', 'Mark the guard\'s pin',
        'A bodyguard on a job sees their client\'s meeting pin.', AT_USE),
    Row('Disposal.Enabled', 'switch', 'Body disposal',
        'A verified kill pays once the hitman has taken the body to the drop-off in the disposal vehicle. '
            .. 'Needs both spots set.',
        'Off: every disposal under way finishes and pays at the next tick. On: from the next verified kill.'),
    Row('Disposal.VehicleModel', 'text', 'Disposal vehicle model', 'A vehicle model the game knows by name.',
        'Read when a vehicle is made.', { pattern = '^[%w_]+$', maxLength = 32 }),
    Row('Disposal.PayNowPercent', 'number', 'Paid at the kill (%)',
        'This much of a cash or bank payout is handed over at the kill; the rest at the drop-off.', NEXT,
        { integer = true, min = 0, max = 90 }),
    Row('Disposal.TimeLimitMinutes', 'number', 'Time to dispose of the body (minutes)',
        'Counted only while the hitman is in the city and nothing holds the contract. The hitman is told a band.',
        AT_USE, { integer = true, min = 1, max = 240 }),
    Row('Disposal.OnTimeout', 'choice', 'When time runs out',
        '"pay": the hitman is paid anyway. "reduced": they keep the share below. "refund": it goes back to the placer.',
        AT_USE, { choices = { 'pay', 'reduced', 'refund' } }),
    Row('Disposal.ReducedPercent', 'number', 'Kept on a late disposal (%)',
        'With "reduced", what the hitman keeps of the money; items are paid whole.', AT_USE,
        { integer = true, min = 0, max = 100 }),
    Row('Disposal.LoadMetres', 'number', 'Load range (m)', 'How near the body the hitman stands to load it.',
        AT_USE, { min = 1, max = 25 }),
    Row('Disposal.DropMetres', 'number', 'Drop-off range (m)', 'How near the drop-off the hitman stands.',
        AT_USE, { min = 1, max = 50 }),
    Row('Disposal.VehicleMetres', 'number', 'Vehicle range (m)',
        'How near the body, and the drop-off, the disposal vehicle must be.', AT_USE, { min = 2, max = 50 }),
    Row('Disposal.AbandonMetres', 'number', 'Abandoned beyond (m)',
        'A vehicle the hitman leaves this far behind, for the minutes below, is taken back to the spawn spot.',
        AT_USE, { min = 50, max = 5000 }),
    Row('Disposal.AbandonMinutes', 'number', 'Abandoned after (minutes)', 'See the row above.', AT_USE,
        { integer = true, min = 1, max = 60 }),
    Row('Disposal.MaxRespawns', 'number', 'Times the vehicle is made again',
        'When it is lost, destroyed or abandoned. Staff can always make it again.', AT_USE,
        { integer = true, min = 0, max = 10 }),
    Row('Disposal.MaxHoldMinutes', 'number', 'Longest a disposal may stand (real minutes)',
        'From the kill, the hitman in the city or not. Past it the step times out as "When time runs out" says, '
            .. 'and its target may be listed again. Never shorter than the time to dispose of the body.', AT_USE,
        { integer = true, min = 10, max = 2880 }),
    Row('Disposal.DespawnSeconds', 'number', 'Taken away after the drop-off (s)',
        'Time to get out before the vehicle goes.', AT_USE, { integer = true, min = 0, max = 300 }),
}

return MissionSteps
