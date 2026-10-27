--- The handover's meeting point (Config.Kidnap.MeetingPoint).
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

local Util = CrimsonBoot.requireShared('util')

local Meeting = {}

local Storage, Notify, Audit

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
    Storage, Notify, Audit = deps.storage, deps.notify, deps.audit
end

--- Whether the feature is on (Config.Kidnap.MeetingPoint), read at every
--- use, so the admin panel's switch applies at once.
---@return boolean
function Meeting.enabled()
    return type(Config.Kidnap) == 'table' and Config.Kidnap.MeetingPoint == true
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

--- A coordinate from the client: a finite number, or nil.
---@return number|nil
local function finite(value)
    if type(value) ~= 'number' or value ~= value
        or value == math.huge or value == -math.huge then
        return nil
    end
    return value
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
            and Util.dist2(coords, point) <= Meeting.TOLERANCE * Meeting.TOLERANCE
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
-- The placer
--------------------------------------------------------------------------

--- Set the meeting point where the placer stands, or move it there.
---
--- `payload` is { id, x, y, z }: x, y and z read by their own game
--- (client/main.lua, crimson:setMeeting), never by the page, and believed
--- only within Meeting.TOLERANCE of where the server sees them. Kept to the
--- metre, x and y alone: the map's waypoint is flat.
---
--- Each hitman on it is told, in the notice budget, that a point was set or
--- moved, and nothing about who set it. Audited without the point.
---@param actor table
---@param payload table
---@return table|false result { set = true, moved = boolean }
---@return string|nil err
---@return table|nil data { retryAfter } on MEETING_TOO_SOON
function Meeting.set(actor, payload)
    if not Meeting.enabled() then return false, CH.ERR.FEATURE_OFF end
    local id = Util.toId(payload.id)
    local x, y, z = finite(payload.x), finite(payload.y), finite(payload.z)
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

    -- Who it is for, and nobody else: the hitmen holding it now. Worded the
    -- same whoever placed it, so the notice names nobody.
    local target = contract.target_name or 'your target'
    for i = 1, #hitmen do
        Notify.toCitizen(hitmen[i], moved and 'Meeting point moved' or 'Meeting point set',
            ('The person who placed your contract on %s %s the meeting point for the handover. '
                .. 'Open it under Mine and tap Set GPS.'):format(target, moved and 'moved' or 'set'),
            { contractId = id })
        Notify.push(hitmen[i], 'meeting', id)
    end
    return { set = true, moved = moved }
end

--- Clear the meeting point. The hitmen's cards are moved on; nobody's phone
--- rings for it.
---@param actor table
---@param payload table { id }
---@return table|false result { cleared = true }
---@return string|nil err
---@return table|nil data
function Meeting.clear(actor, payload)
    if not Meeting.enabled() then return false, CH.ERR.FEATURE_OFF end
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
    local hitmen = activeHitmen(id)
    for i = 1, #hitmen do Notify.push(hitmen[i], 'meeting', id) end
    return { cleared = true }
end

--------------------------------------------------------------------------
-- The hitman
--------------------------------------------------------------------------

--- The meeting point, for an active hitman's Set GPS: their game marks it
--- on their map (client/main.lua, crimson:meetingGps) and hands the page
--- nothing but that it did.
---
--- Anybody else is told there is no such contract, as for one that does
--- not exist: a former hitman, the target, the placer themselves.
---@param actor table
---@param payload table { id }
---@return table|false result { x, y }
---@return string|nil err
function Meeting.waypoint(actor, payload)
    if not Meeting.enabled() then return false, CH.ERR.FEATURE_OFF end
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
