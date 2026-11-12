CrimsonBoot.define('server.meeting', function() --- The handover's meeting point (Config.Kidnap.MeetingPoint).
---
--- On a contract only a live handover completes, the person who placed it
--- can drop a point on the map for the hitmen on it to bring the target to:
--- where they are standing when they tap Set meeting point here, read by
--- their own game and checked here against where the server sees their
--- character. Coordinates only, to the metre: no name, no street, nothing a
--- player types.
---
--- Who sees it: the hitmen active on the contract, and nobody else. Their
--- card says one is set (Projection.contract, `meetingSet`), and Set GPS asks
--- for it here (Meeting.waypoint) and their game marks it on their map. The
--- coordinates are on no card, no board, no target's view, no
--- whitelisted-job view, no advisory, and no staff view but the contract's,
--- to staff with the identity ACE. It says where the placer stood, never
--- who they are: an anonymous placer stays anonymous, and their card tells
--- them the hitmen will see the spot.
---
--- It goes when the contract ends in any way, when the last active hitman
--- leaves it (Contracts' dropMeeting, in the store at that moment), and when
--- the placer clears it. Turning the feature off hides it and refuses
--- changes, and takes no point off any contract.
---
--- The map marker: while one is set, the placer and every active hitman of
--- the contract have a marker on their map at it (key 'meeting:<contract>',
--- through server/lib/markers.lua to their game alone, never to the page), and each is told on their phone
--- what to do to finish the handover (Meeting.steps, the same words as the
--- 'What to do' line on their card). Who has it is worked out again from the
--- store at every change (Meeting.sync): the point set, moved or cleared, a
--- hitman joining or leaving, the contract ending, the switch turned. Anybody
--- no longer a party has it taken off (Markers.clear); a
--- party who comes back to the city has it drawn again (Meeting.reshow). The
--- target, bystanders and staff who are not a party are never sent it.

local Util = CrimsonBoot.requireShared('util')
local Geo = CrimsonBoot.requireShared('geo')
local Words = CrimsonBoot.requireShared('words')
local Log = CrimsonBoot.requireShared('log')
local Feature = CrimsonBoot.require('server.lib.feature')
local Markers = CrimsonBoot.require('server.lib.markers')
local L = CrimsonBoot.requireShared('locale').t

local Meeting = {}

local Storage, Notify, Audit, Identity

--- Who has the marker on their map now, by contract:
--- [contractId] = { x, y, cids = { [cid] = true } }. Only parties who were
--- in the city when it was sent; one who comes back is sent it then
--- (Meeting.reshow). Forgotten with the point, and per player as they leave.
local shown = {}

--- At most one change on a contract this often, in seconds: a point set, a
--- point moved or a point cleared by the placer. Kept by the store's own
--- write (setMeeting, clearMeeting), so it holds across a restart and
--- between two requests read at the same moment.
Meeting.EVERY_SECONDS = 30

--- How far apart, in metres, where the placer's game says they stand and
--- where the server sees their character may be. The two are read a moment
--- apart, and the server's lags a little behind a player on the move.
Meeting.TOLERANCE = 5.0

--- The map: Los Santos, Blaine County and the island off the south coast,
--- with room around them. A point outside it is nowhere a hitman can go.
Meeting.BOUNDS = {
    minX = -4500.0, maxX = 6000.0,
    minY = -6500.0, maxY = 8500.0,
    minZ = -200.0, maxZ = 2000.0,
}

function Meeting.init(deps)
    Storage, Notify, Audit, Identity = deps.storage, deps.notify, deps.audit, deps.identity
    shown = {}
    -- The 'What to do' line on each side's card says what their phone was
    -- told, word for word.
    if deps.projection then deps.projection.meetingSteps = function(role) return Meeting.steps(role) end end
end

--- The citizen ids of the hitmen holding the contract now.
---@param contractId string
---@return string[]
local function activeHitmen(contractId)
    local out = {}
    for _, row in ipairs(Storage.readHitmen(contractId) or {}) do
        if row.state == 'active' then out[#out + 1] = row.hitman_cid end
    end
    return out
end

--- Whether a point is on the map (Meeting.BOUNDS).
local function onMap(x, y, z)
    local b = Meeting.BOUNDS
    return x >= b.minX and x <= b.maxX and y >= b.minY and y <= b.maxY
        and z >= b.minZ and z <= b.maxZ
end

--- Whether the server sees this player's character within Meeting.TOLERANCE
--- of the point their game read. A position it cannot read is not one, nor
--- is a character it has no ped for (ped 0, whose coordinates read as the
--- middle of the map).
---@param actor table
---@param point table { x, y, z }
---@return boolean
local function standsAt(actor, point)
    local ok, near = pcall(function()
        local ped = GetPlayerPed(actor.source)
        if not ped or ped == 0 then return false end
        local coords = GetEntityCoords(ped)
        return coords ~= nil and tonumber(coords.x) ~= nil
            and Geo.dist2(coords, point) <= Meeting.TOLERANCE * Meeting.TOLERANCE
    end)
    return ok and near == true
end

--- The contract, when it is this player's own: not found and not theirs
--- are the same answer, so an id cannot be tried for whether it exists.
---@return table|nil contract
local function placedBy(actor, id)
    local contract = id and Storage.readContract(id) or nil
    if not contract or contract.creator_cid ~= actor.cid then return nil end
    return contract
end

--- How long until the rule allows another change, in seconds; 0 now.
local function waitLeft(contract, now)
    local at = tonumber(contract.meeting_at)
    if not at then return 0 end
    return math.max(0, at + Meeting.EVERY_SECONDS - now)
end

--- What a refused store write means, read again from the store.
local function refusedAs(id, now)
    local contract = Storage.readContract(id)
    if not contract or CH.TERMINAL[contract.state] then return CH.ERR.BAD_STATE end
    local wait = waitLeft(contract, now)
    if wait > 0 then return CH.ERR.MEETING_TOO_SOON, { retryAfter = wait } end
    if contract.state ~= CH.STATE.ACCEPTED then return CH.ERR.MEETING_NO_HITMAN end
    return CH.ERR.BAD_STATE
end

--------------------------------------------------------------------------
-- What each side does, in words
--------------------------------------------------------------------------

--- What a party does to finish a live handover at the meeting point, in the
--- app's own words (its button is Deliver alive, the contract is under
--- Mine): the placer stands there and keeps still, and taps nothing (the
--- handover is the hitman's to start, Kidnap.arm); the hitman brings the
--- target there and taps Deliver alive. From Config.Kidnap at every use, so
--- the figures are the server's. Names nobody: the hitman is told of "the
--- person who placed the contract", the placer of "the hitman".
---@param role 'placer'|'hitman'
---@return string
function Meeting.steps(role)
    local kidnap = Config.Kidnap or {}
    local seconds = tonumber(kidnap.CountdownSeconds) or 0
    local hold = seconds > 0 and (L('meeting.seconds')):format(math.floor(seconds)) or L('meeting.until_it_finishes')
    -- With the placer's Confirm handover on (Config.Kidnap.PlacerConfirms),
    -- the hold is followed by their tap, within the window.
    local confirms = kidnap.PlacerConfirms == true
    local window = math.max(10, math.floor(tonumber(kidnap.ConfirmSeconds) or 60))
    if role == 'placer' then
        if confirms then
            return (L('meeting.be_at_the_meeting_point_marked')):format(Words.metres(Config.Kidnap and Config.Kidnap.Radius), hold, window)
        end
        return (L('meeting.be_at_the_meeting_point_marked_2')):format(Words.metres(Config.Kidnap and Config.Kidnap.Radius), hold)
    end
    return (L('meeting.bring_the_target_alive_to_the')):format(kidnap.RequireCoercion and L('meeting.cuffed_or_in_your_vehicle') or '',
        Words.metres(Config.Kidnap and Config.Kidnap.Radius), hold, confirms and L('meeting.then_the_person_who_placed_it') or '')
end

--- Tell one party, on their phone, that a point was set or moved and what
--- to do. The hitman's words never say who placed it.
local function tell(cid, role, contract, moved)
    local target = contract.target_name or L('meeting.your_target')
    local intro
    if role == 'placer' then
        intro = (L('meeting.your_meeting_point_for_the_contract')):format(target,
            moved and 'moved' or 'set')
    else
        intro = (L('meeting.the_person_who_placed_your_contract')):format(target, moved and 'moved' or 'set')
    end
    Notify.toCitizen(cid, moved and L('meeting.meeting_point_moved') or L('meeting.meeting_point_set'),
        intro .. ' ' .. Meeting.steps(role), { contractId = contract.id })
end

--------------------------------------------------------------------------
-- The map marker
--------------------------------------------------------------------------

--- The parties who need the marker on this contract now, from the store:
--- the placer and each active hitman, while the feature is on and a point
--- is set on a live contract only a live handover completes. Never the
--- target. [cid] = 'placer' | 'hitman'.
---@return table
local function partiesOf(contract)
    local want = {}
    if not Feature.on('Kidnap.MeetingPoint') or not contract or CH.TERMINAL[contract.state]
        or contract.meeting_x == nil or contract.meeting_y == nil
        or Util.fulfilmentRule(contract) ~= CH.FULFILMENT_RULE.ALIVE then
        return want
    end
    local hitmen = activeHitmen(contract.id)
    if #hitmen == 0 then return want end
    if contract.creator_cid then want[contract.creator_cid] = 'placer' end
    for i = 1, #hitmen do want[hitmen[i]] = want[hitmen[i]] or 'hitman' end
    if contract.target_cid then want[contract.target_cid] = nil end
    return want
end

--- Draw the marker on one party's map: the contract id and the point, to
--- their game alone.
local function draw(cid, contractId, x, y)
    local game = Identity and Identity.sourceOf(cid)
    if not game then return false end
    return Markers.show(game, 'meeting:' .. contractId, { kind = 'meeting', x = x, y = y })
end

local function erase(cid, contractId)
    Markers.clear(Identity and Identity.sourceOf(cid), 'meeting:' .. contractId)
end

--- Bring every map in line with the store for one contract: drawn for each
--- party who has not got it (or all of them where the point moved), taken
--- off each who is no longer a party. Never raises: nothing here may stop a
--- set, a walk-away or an ending.
---
--- `opts.tellNew`: a party drawn for the first time on a point that did not
--- move (a hitman who took the contract after it was set) is told what to
--- do as well.
---@param contractId string
---@param opts table|nil { tellNew = boolean }
function Meeting.sync(contractId, opts)
    if not contractId then return end
    local ok, err = pcall(function()
        local contract = Storage.readContract(contractId)
        local want = partiesOf(contract)
        local was = shown[contractId]
        local x = contract and tonumber(contract.meeting_x)
        local y = contract and tonumber(contract.meeting_y)
        local moved = was ~= nil and (was.x ~= x or was.y ~= y)

        if was then
            for cid in pairs(was.cids) do
                if not want[cid] then erase(cid, contractId) end
            end
        end
        if next(want) == nil then
            shown[contractId] = nil
            return
        end

        local now = { x = x, y = y, cids = {} }
        for cid, role in pairs(want) do
            if was and was.cids[cid] and not moved then
                now.cids[cid] = true
            elseif draw(cid, contractId, x, y) then
                now.cids[cid] = true
                if opts and opts.tellNew and not moved then tell(cid, role, contract, false) end
            end
        end
        shown[contractId] = now
    end)
    if not ok then
        Log.debug(('meeting point %s: the map markers could not be brought up to '
            .. 'date: %s'):format(tostring(contractId), tostring(err)))
    end
end

--- Every contract the marker is drawn on, and every live one with a point:
--- for the switch (Config.Kidnap.MeetingPoint), turned off (off every map)
--- or on (back on the parties').
function Meeting.syncAll()
    local ids = {}
    for id in pairs(shown) do ids[id] = true end
    if Feature.on('Kidnap.MeetingPoint') and Storage.liveContracts then
        for _, c in ipairs(Storage.liveContracts() or {}) do
            if c.meeting_x ~= nil then ids[c.id] = true end
        end
    end
    for id in pairs(ids) do Meeting.sync(id) end
end

--- A hitman took the contract up: drawn on their map, and they are told
--- what to do, where a point is already set.
function Meeting.joined(contractId)
    Meeting.sync(contractId, { tellNew = true })
end

--- Draw again, on this player's map, the marker of every live contract they
--- are a party to with a point set: after the resource restarts, or when
--- they come back to the city. Only theirs, and only where they are a party.
---@param actor table
---@return table result { shown = integer }
function Meeting.reshow(actor)
    local drawn = 0
    if not Feature.on('Kidnap.MeetingPoint') or not actor or not actor.cid then return { shown = 0 } end
    local involved = Storage.contractsInvolving and Storage.contractsInvolving(actor.cid, true) or {}
    for _, contract in ipairs(involved) do
        if contract.meeting_x ~= nil and partiesOf(contract)[actor.cid] then
            local x, y = tonumber(contract.meeting_x), tonumber(contract.meeting_y)
            Markers.show(actor.source, 'meeting:' .. contract.id, { kind = 'meeting', x = x, y = y })
            local entry = shown[contract.id]
            if not entry or entry.x ~= x or entry.y ~= y then
                entry = { x = x, y = y, cids = entry and entry.cids or {} }
                shown[contract.id] = entry
            end
            entry.cids[actor.cid] = true
            drawn = drawn + 1
        end
    end
    return { shown = drawn }
end

--- This player has left the city or the character: their game took its own
--- markers off (client/main.lua), so nothing is sent; forgotten, so the next
--- change or their return draws it for them again.
function Meeting.forget(cid)
    if not cid then return end
    for id, entry in pairs(shown) do
        entry.cids[cid] = nil
        if next(entry.cids) == nil then shown[id] = nil end
    end
end

--------------------------------------------------------------------------
-- The placer
--------------------------------------------------------------------------

--- Set the meeting point where the placer stands, or move it there.
---
--- `payload` is { id, x, y, z }: x, y and z read by their own game
--- (client/main.lua, crimson:setMeeting), never by the page, and believed
--- only within Meeting.TOLERANCE of where the server sees them. Kept to the
--- metre, x and y alone: the map's waypoint is flat.
---
--- The placer and each hitman on it get the marker on their map and are
--- told, in the notice budget, that a point was set or moved and what to
--- do (Meeting.steps); the hitmen nothing about who set it. Audited without
--- the point.
---@param actor table
---@param payload table
---@return table|false result { set = true, moved = boolean }
---@return string|nil err
---@return table|nil data { retryAfter } on MEETING_TOO_SOON
function Meeting.set(actor, payload)
    if not Feature.on('Kidnap.MeetingPoint') then return false, CH.ERR.FEATURE_OFF end
    local id = Util.toId(payload.id)
    local x, y, z = Geo.finite(payload.x, true), Geo.finite(payload.y, true), Geo.finite(payload.z, true)
    if not id or not x or not y or not z then return false, CH.ERR.INVALID_INPUT end

    local contract = placedBy(actor, id)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if Util.fulfilmentRule(contract) ~= CH.FULFILMENT_RULE.ALIVE then
        return false, CH.ERR.BAD_STATE
    end
    if CH.TERMINAL[contract.state] or contract.state == CH.STATE.COMPLETING then
        return false, CH.ERR.BAD_STATE
    end
    local hitmen = activeHitmen(id)
    if contract.state ~= CH.STATE.ACCEPTED or #hitmen == 0 then
        return false, CH.ERR.MEETING_NO_HITMAN
    end

    -- Plausibility, after every rule that says who may: off the map, or
    -- not where the server sees them (a car on the move, a client that
    -- made the figures up), and nothing is set.
    if not onMap(x, y, z) or not standsAt(actor, { x = x, y = y, z = z }) then
        return false, CH.ERR.MEETING_NOT_HERE
    end

    local now = os.time()
    local wait = waitLeft(contract, now)
    if wait > 0 then return false, CH.ERR.MEETING_TOO_SOON, { retryAfter = wait } end

    local moved = contract.meeting_x ~= nil
    if not Storage.setMeeting(id, math.floor(x + 0.5), math.floor(y + 0.5), now,
        now - Meeting.EVERY_SECONDS) then
        local err, data = refusedAs(id, now)
        return false, err, data
    end

    Audit.action(moved and 'meeting_moved' or 'meeting_set', actor.cid, id, {})

    -- Who it is for, and nobody else: the placer and the hitmen holding it
    -- now, each with the marker on their map and told what to do. Worded the
    -- same whoever placed it, so the notice names nobody.
    Meeting.sync(id)
    tell(actor.cid, 'placer', contract, moved)
    for i = 1, #hitmen do
        tell(hitmen[i], 'hitman', contract, moved)
        Notify.push(hitmen[i], 'meeting', id)
    end
    return { set = true, moved = moved }
end

--- Clear the meeting point. It comes off every party's map and the hitmen's
--- cards are moved on; nobody's phone rings for it.
---@param actor table
---@param payload table { id }
---@return table|false result { cleared = true }
---@return string|nil err
---@return table|nil data
function Meeting.clear(actor, payload)
    if not Feature.on('Kidnap.MeetingPoint') then return false, CH.ERR.FEATURE_OFF end
    local id = Util.toId(payload.id)
    if not id then return false, CH.ERR.INVALID_INPUT end

    local contract = placedBy(actor, id)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if contract.meeting_x == nil then return false, CH.ERR.NO_MEETING end

    local now = os.time()
    local wait = waitLeft(contract, now)
    if wait > 0 then return false, CH.ERR.MEETING_TOO_SOON, { retryAfter = wait } end

    if not Storage.clearMeeting(id, now, now - Meeting.EVERY_SECONDS) then
        local after = Storage.readContract(id)
        if not after or after.meeting_x == nil then return false, CH.ERR.NO_MEETING end
        local err, data = refusedAs(id, now)
        return false, err, data
    end

    Audit.action('meeting_cleared', actor.cid, id, {})
    -- Off every map it was on.
    Meeting.sync(id)
    local hitmen = activeHitmen(id)
    for i = 1, #hitmen do Notify.push(hitmen[i], 'meeting', id) end
    return { cleared = true }
end

--------------------------------------------------------------------------
-- The hitman
--------------------------------------------------------------------------

--- The meeting point, for an active hitman's Set GPS: their game marks it
--- on their map (client/main.lua, crimson:gps) and hands the page
--- nothing but that it did.
---
--- Anybody else is told there is no such contract, as for one that does
--- not exist: a former hitman, the target, the placer themselves.
---@param actor table
---@param payload table { id }
---@return table|false result { x, y }
---@return string|nil err
function Meeting.waypoint(actor, payload)
    if not Feature.on('Kidnap.MeetingPoint') then return false, CH.ERR.FEATURE_OFF end
    local id = Util.toId(payload.id)
    if not id then return false, CH.ERR.INVALID_INPUT end

    local contract = Storage.readContract(id)
    local mine = contract and Storage.readHitman(id, actor.cid)
    if not contract or CH.TERMINAL[contract.state] or not mine or mine.state ~= 'active' then
        return false, CH.ERR.NOT_FOUND
    end
    if contract.meeting_x == nil or contract.meeting_y == nil then
        return false, CH.ERR.NO_MEETING
    end
    return { x = tonumber(contract.meeting_x), y = tonumber(contract.meeting_y) }
end

return Meeting
end)
