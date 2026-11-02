--- Rumours and the broker (Config.Roleplay.Rumours, README, Optional
--- features). Off as shipped, and off it changes nothing.
---
--- On, the board shows a contract to a hitman who is not party to it only
--- as a rumour: a rough area (the district the target was in when the
--- rumour first went round, or a name from Zones) and a reward band. No
--- target name, no headshot, no reason, no exact figure, no Accept. The
--- full card, and Accept, come with a briefing: by the broker NPC (the
--- hitman asks from the app while standing within Radius of where the NPC
--- is now, server/rp_places.lua), or by a player on a broker job, who picks
--- somebody standing within Radius of them from their own app.
---
--- Every distance is read on the server, from the players' peds. A briefing
--- is kept per hitman per contract for BriefValidMinutes, in this process
--- only: a restart forgets it, and the hitman asks the broker again (the
--- clocks of every contract are held over a restart anyway). Accept is
--- refused without one (not_briefed), before anything is taken.

local Util = CrimsonBoot.requireShared('util')
local Places = CrimsonBoot.require('server.rp_places')

local Rumours = {}

local deps

--- [contractId] = { [cid] = expires at (os.time) }
local briefed = {}
--- [contractId] = the area its rumour names, fixed the first time it is told.
local areaOf = {}
--- The people a broker player was shown, by an opaque handle that means
--- nothing to anybody else: [brokerCid] = { [handle] = { cid, at } }.
local shownTo = {}

local HANDLE_SECONDS = 120

function Rumours.init(d)
    deps = d
end

function Rumours.on()
    return Places.on('Rumours')
end

local function rules()
    return Places.block('Rumours')
end

--- Whether this player is briefed on this contract now.
---@param contractId string
---@param cid string
---@return boolean
function Rumours.isBriefed(contractId, cid)
    local list = briefed[contractId]
    local untilAt = list and list[cid]
    if not untilAt then return false end
    if untilAt <= os.time() then
        list[cid] = nil
        return false
    end
    return true
end

local function record(contractId, cid)
    local minutes = tonumber(rules().BriefValidMinutes) or 30
    -- Briefings run out on their own: the ones that have are dropped here,
    -- so the table holds only what is still worth something.
    local now = os.time()
    for id, list in pairs(briefed) do
        for who, untilAt in pairs(list) do
            if untilAt <= now then list[who] = nil end
        end
        if next(list) == nil then briefed[id] = nil end
    end
    briefed[contractId] = briefed[contractId] or {}
    briefed[contractId][cid] = os.time() + math.floor(minutes * 60)
    return minutes
end

--- A contract that is on the board: live, and not one of the viewer's own
--- as its target. Nil for anything else, the same for every kind of miss.
local function listed(contractId, viewerCid)
    local contract = deps.storage.readContract(Util.toId(contractId))
    if not contract then return nil end
    if contract.state ~= CH.STATE.ACTIVE and contract.state ~= CH.STATE.ACCEPTED then return nil end
    if contract.target_cid == viewerCid then return nil end
    return contract
end

--- Whether a player is on one of the broker jobs.
---@param actor table
---@return boolean
function Rumours.isBroker(actor)
    local jobs = rules().BrokerJobs
    local job = actor and type(actor.job) == 'table' and actor.job.name
    if type(jobs) ~= 'table' or type(job) ~= 'string' then return false end
    return jobs[job:lower()] == true or jobs[job] == true
end

--------------------------------------------------------------------------
-- What a rumour says
--------------------------------------------------------------------------

local function hashOf(text)
    local n = 0
    for i = 1, #text do n = (n * 31 + text:byte(i)) % 2147483647 end
    return n
end

local function zoneFor(contract)
    local zones = rules().Zones
    if type(zones) ~= 'table' or #zones == 0 then return 'somewhere in the city' end
    return tostring(zones[(hashOf(tostring(contract.id)) % #zones) + 1])
end

--- The name in Districts nearest a point, or nil with none listed.
---@param coords table { x, y }
---@return string|nil
local function nearestDistrict(coords)
    local best, bestD
    for _, text in ipairs(type(rules().Districts) == 'table' and rules().Districts or {}) do
        local spot = Places.parseArea(text)
        if spot then
            local d = (spot.x - (coords.x or 0)) ^ 2 + (spot.y - (coords.y or 0)) ^ 2
            if not bestD or d < bestD then best, bestD = spot.name, d end
        end
    end
    return best
end

--- The district nearest where the target stood the first time the rumour
--- was told, or a zone name where that cannot be read.
local function areaFor(contract)
    if areaOf[contract.id] then return areaOf[contract.id] end
    local area
    if rules().AreaMode == 'district' then
        local target = deps.identity.byCitizenId(contract.target_cid)
        local coords = target and target.source and Places.coordsOf(target.source)
        if coords then area = nearestDistrict(coords) end
    end
    area = area or zoneFor(contract)
    areaOf[contract.id] = area
    return area
end

--- A figure rounded to something a rumour would say.
local function rough(n, up)
    local step = n >= 100000 and 10000 or n >= 10000 and 1000 or 100
    if up then return math.ceil(n / step) * step end
    return math.floor(n / step) * step
end

--- The row a hitman not briefed on it sees in place of the card.
local function rumourRow(row, contract)
    local reward = type(row.reward) == 'table' and row.reward or {}
    local value = (tonumber(reward.baseline) or 0) + (tonumber(reward.bonus) or 0)
    local spread = (tonumber(rules().BandPercent) or 25) / 100
    local goods = type(reward.goods) == 'table'
        and ((tonumber(reward.goods.items) or 0) + (tonumber(reward.goods.weapons) or 0)) > 0
    return {
        id = row.id, mode = row.mode, state = row.state, role = row.role,
        fulfilment = row.fulfilment, slots = row.slots, slotsClaimed = row.slotsClaimed,
        currentSlot = row.currentSlot, hitmenActive = row.hitmenActive, hitmenMax = row.hitmenMax,
        timeLeft = row.timeLeft, barred = row.barred,
        rumour = {
            area = areaFor(contract),
            low = value > 0 and rough(value * (1 - spread), false) or 0,
            high = value > 0 and rough(value * (1 + spread), true) or 0,
            goods = goods or nil,
        },
    }
end

--- The board as a viewer may see it with rumours on: every row they are
--- no party to and not briefed on, as a rumour. Called on the 'list'
--- reply (App.shapes).
---@param listing table Projection.listing's
---@param actor table
---@return table listing
function Rumours.shapeListing(listing, actor)
    if not Rumours.on() or type(listing) ~= 'table' then return listing end
    local rows = type(listing.contracts) == 'table' and listing.contracts or {}
    for i, row in ipairs(rows) do
        if type(row) == 'table' and row.role == 'public' and not Rumours.isBriefed(row.id, actor.cid) then
            local contract = deps.storage.readContract(row.id)
            if contract then rows[i] = rumourRow(row, contract) end
        end
    end
    local broker = Places.current('broker')
    listing.rumours = {
        npc = broker ~= nil,
        -- Where to ask around for the broker, as a district name only, on a
        -- server that does not mark them on the map (Blip off): never the
        -- spot. Marked on the map, the map says it.
        brokerArea = (broker and rules().Blip ~= true and type(broker.x) == 'number')
            and nearestDistrict(broker) or nil,
        blip = (broker and rules().Blip == true) or nil,
        players = type(rules().BrokerJobs) == 'table' and next(rules().BrokerJobs) ~= nil,
        broker = Rumours.isBroker(actor) or nil,
        minutes = tonumber(rules().BriefValidMinutes) or 30,
    }
    return listing
end

--- The app's answers this reshapes (App's roleplay steps): the board only.
function Rumours.shape(name, actor, result)
    if name ~= 'list' then return nil end
    return Rumours.shapeListing(result, actor)
end

--- Accept, refused without a briefing. A hitman already on the contract
--- (an abandoned one coming back is not) needs none.
---@return string|nil err
function Rumours.gate(name, actor, payload)
    if name ~= 'accept' or not Rumours.on() then return nil end
    local contract = deps.storage.readContract(Util.toId(payload.id))
    -- Anything that is not a contract is the handler's to refuse, in its words.
    if not contract then return nil end
    if contract.creator_cid == actor.cid then return nil end
    local mine = deps.storage.readHitman(contract.id, actor.cid)
    if mine and mine.state == 'active' then return nil end
    if Rumours.isBriefed(contract.id, actor.cid) then return nil end
    deps.audit.rejected('rumour_not_briefed', actor.cid, contract.id, {})
    return CH.ERR.NOT_BRIEFED
end

--------------------------------------------------------------------------
-- The two ways to be briefed
--------------------------------------------------------------------------

--- The broker NPC: the hitman asks about one rumour while standing beside
--- it. The full card is in the reply.
function Rumours.askBroker(actor, contractId)
    if not Rumours.on() then return false, CH.ERR.FEATURE_OFF end
    local contract = listed(contractId, actor.cid)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if not Places.near('broker', actor.source) then return false, CH.ERR.FIND_BROKER end
    local minutes = record(contract.id, actor.cid)
    deps.audit.action('rumour_briefed', actor.cid, contract.id, { via = 'npc' })
    local row = deps.projection.contract(contract, actor.cid)
    if row then row.meetingSet, row.locationTip = nil, nil end
    return { briefed = true, minutes = minutes, contract = row }
end

local function nearby(actor)
    local mine = Places.coordsOf(actor.source)
    if not mine then return {} end
    local radius = tonumber(rules().Radius) or 0
    local okB, bucket = pcall(GetPlayerRoutingBucket, actor.source)
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src and src ~= actor.source then
            local okT, theirs = pcall(GetPlayerRoutingBucket, src)
            local coords = Places.coordsOf(src)
            local listable = not (deps.app and deps.app.brokerMayList) or deps.app.brokerMayList(src)
            if coords and listable and (not okB or not okT or theirs == bucket) then
                local d2 = Util.dist2(mine, coords)
                if d2 <= radius * radius then
                    local person = deps.identity.resolve(src)
                    if person and person.cid then
                        out[#out + 1] = { cid = person.cid, metres = math.floor(math.sqrt(d2) + 0.5) }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.metres < b.metres end)
    return out
end

--- A broker player: who stands within Radius of them, by a handle that
--- names nobody, nearest first. Never a name, an id or a source.
function Rumours.brokerNearby(actor)
    if not Rumours.on() then return false, CH.ERR.FEATURE_OFF end
    if not Rumours.isBroker(actor) then return false, CH.ERR.NOT_BROKER end
    local now = os.time()
    local mine = {}
    local people = {}
    for i, person in ipairs(nearby(actor)) do
        if i > 10 then break end
        local handle = Util.randomId('bp')
        mine[handle] = { cid = person.cid, at = now }
        people[#people + 1] = { handle = handle, metres = person.metres }
    end
    shownTo[actor.cid] = mine
    return { people = people, radius = tonumber(rules().Radius) or 0 }
end

--- A broker player briefs the person they picked on one rumour, if that
--- person still stands within Radius of them.
function Rumours.brokerBrief(actor, contractId, who)
    if not Rumours.on() then return false, CH.ERR.FEATURE_OFF end
    if not Rumours.isBroker(actor) then return false, CH.ERR.NOT_BROKER end
    local contract = listed(contractId, actor.cid)
    if not contract then return false, CH.ERR.NOT_FOUND end
    local picked = type(who) == 'string' and shownTo[actor.cid]
        and shownTo[actor.cid][who] or nil
    if not picked or os.time() - picked.at > HANDLE_SECONDS then return false, CH.ERR.NOT_FOUND end
    local person = deps.identity.byCitizenId(picked.cid)
    local theirs = person and person.source and Places.coordsOf(person.source)
    local mine = Places.coordsOf(actor.source)
    local radius = tonumber(rules().Radius) or 0
    if not theirs or not mine or Util.dist2(mine, theirs) > radius * radius then
        return false, CH.ERR.BROKER_TOO_FAR
    end
    -- Never the person the contract is on: briefed, they learnt of it before
    -- their own alert (and On me) would tell them. Answered as any other
    -- briefing, so the broker learns nothing of who they picked.
    if picked.cid == contract.target_cid then return { briefed = true } end
    record(contract.id, picked.cid)
    deps.audit.action('rumour_briefed', picked.cid, contract.id, { via = 'broker', broker = actor.cid })
    pcall(deps.notify.toCitizen, picked.cid, 'Crimson-Hitman',
        'A broker filled you in on a contract. Check the board.')
    pcall(deps.notify.push, picked.cid, 'briefed', contract.id)
    return { briefed = true }
end

--------------------------------------------------------------------------
-- The start-up check
--------------------------------------------------------------------------

Rumours.RULES = {
    Enabled = { kind = 'switch', default = false },
    AreaMode = { kind = 'choice', choices = { 'district', 'zones' }, default = 'district' },
    Zones = { kind = 'phrases', default = {} },
    Districts = { kind = 'areas', default = {} },
    BandPercent = { kind = 'number', min = 0, max = 100, integer = true, default = 25 },
    Radius = { kind = 'number', min = 1, max = 100, default = 5.0 },
    BriefValidMinutes = { kind = 'number', min = 1, max = 1440, integer = true, default = 30 },
    Locations = { kind = 'points', default = {} },
    RotateHours = { kind = 'number', min = 1, max = 168, integer = true, default = 4 },
    Model = { kind = 'text', default = 'g_m_m_armboss_01' },
    Scenario = { kind = 'text', default = 'WORLD_HUMAN_SMOKING' },
    Blip = { kind = 'switch', default = false },
    BrokerJobs = { kind = 'set', default = {} },
}

---@param warn string[]
function Rumours.validate(warn)
    Places.checkBlock('Rumours', Rumours.RULES, warn)
end

return Rumours
