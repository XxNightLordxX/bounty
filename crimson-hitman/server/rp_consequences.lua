--- Roleplay consequences of a completed contract (README, Optional features).
---
--- Four features, each off as shipped and each its own block of
--- Config.Roleplay, all of them changed live from the admin panel:
---
---   * Witness heat (WitnessHeat): a completion seen by bystanders, players
---     near the hitman who are no party to the contract, sends the police a
---     vague witness report over their phones and sc-dispatch. Never a name.
---   * EMS before re-listing (EmsRelisting): a target killed on a contract
---     cannot have a new one placed on them until they have been up for
---     TreatedMinutes, or, with RequireEMS, until a medic's defibrillator has
---     brought them back (sc-ambulance's own event, checked by
---     Death.noteDefib). The placer is told "They are still recovering."
---   * City news (CityNews): an anonymous post on lb-phone's Birdy
---     (PostBirdy), or a server event for another resource to post, from a
---     template with the target's job, the area and the time.
---   * Dirty money payouts (DirtyPayouts): a hitman's cash or bank payout
---     handed over as an ox_inventory item (Escrow.deliver), at a rate that
---     loses nothing. Escrow keeps the money it took; a payout that does not
---     fit is owed through the existing owed path.
---
--- What EMS before re-listing has seen of a recovering target (the kill,
--- since when they have been up, a medic's revive) is kept in the store
--- (crimson_rp_rows, kind 'ems'), written when it changes, so a restart
--- does not start the count again: a target up when the server stopped is
--- still up from then once they are seen up again. The kill is also read
--- back from the Ledger (every backend keeps it), so one from before this
--- was kept still holds; for that one the timer decides, and never past
--- MaxHoldMinutes after the kill.

local Util = CrimsonBoot.requireShared('util')
local Geo = CrimsonBoot.requireShared('geo')
local Feature = CrimsonBoot.require('server.lib.feature')
--- The named-area parser both roleplay area lists share.
local Places = CrimsonBoot.require('server.rp_places')
local Police = CrimsonBoot.require('server.police')
local Integrations = CrimsonBoot.require('server.adapters.init')

local RpConsequences = {}

local Storage, Identity, Audit, Ledger

--- The target's last kill on a contract, seen in this process: [cid] = os.time().
local killedAt = {}
--- Since when each recovering target has been seen up, neither dead nor
--- downed, without a break: [cid] = os.time().
local upSince = {}
--- When a medic's defibrillator was last heard on them: [cid] = os.time().
local medicAt = {}
--- Targets whose up-count was read back from the store at this start and
--- who have not been seen since: their absence is the restart, not a break
--- of theirs. [cid] = true
local carried = {}
--- The kill each target's kept row was written for: [cid] = os.time(). A
--- medic's revive is asked for only where what was heard since is known.
local tracked = {}

local EMS_KIND = 'ems'
--- When this process started, os.time(): a kill from before it has lost what
--- was seen of the target since (a medic's revive), so the timer decides.
local startedAt = 0

--------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------

--- What each setting must be, as the start holds config.lua to it
--- (Feature.check, server/lib/feature.lua) and the panel's catalogue
--- (server/settings.lua) offers it: a number's range, a text's pattern, a
--- list's item pattern, a choice's values.
local TEXT = '^[^%c<>]+$'
local RULES = {
    WitnessHeat = {
        Enabled = { kind = 'switch' }, AlwaysAlert = { kind = 'switch' }, SendCoords = { kind = 'switch' },
        WitnessRadius = { kind = 'number', min = 1, max = 500 },
        MinWitnesses = { kind = 'number', integer = true, min = 1, max = 50 },
        FuzzMeters = { kind = 'number', min = 0, max = 1000 },
        DispatchPriority = { kind = 'number', integer = true, min = 1, max = 5 },
        Title = { kind = 'text', pattern = TEXT, max = 60, says = 'text up to 60 characters, no < or >' },
        Phrases = { kind = 'list', pattern = TEXT, max = 60 },
        Areas = { kind = 'list', each = Places.parseArea, says = "a list of areas, each 'Name@x,y'" },
    },
    EmsRelisting = {
        Enabled = { kind = 'switch' }, RequireEMS = { kind = 'switch' },
        TreatedMinutes = { kind = 'number', integer = true, min = 0, max = 240 },
        MaxHoldMinutes = { kind = 'number', integer = true, min = 1, max = 1440 },
    },
    CityNews = {
        Enabled = { kind = 'switch' }, AllTargets = { kind = 'switch' }, NameTarget = { kind = 'switch' },
        App = { kind = 'choice', choices = { 'birdy', 'event' } },
        Account = { kind = 'text', pattern = '^[%w_%-%.]+$', max = 32 },
        Event = { kind = 'text', pattern = '^[%w_%-%.:]+$', max = 64, says = 'an event name' },
        Templates = { kind = 'list', pattern = TEXT, max = 160,
            says = 'a list of sentences up to 160 characters, no < or >' },
    },
    DirtyPayouts = {
        Enabled = { kind = 'switch' },
        Item = { kind = 'text', pattern = '^[%w_%-]+$', max = 64 },
        Mode = { kind = 'choice', choices = { 'count', 'worth' } },
        WorthKey = { kind = 'text', pattern = '^[%w_%-]+$', max = 32 },
        Rate = { kind = 'number', integer = true, min = 1, max = 100 },
    },
}
RpConsequences.RULES = RULES

--- The start-up checks for these four blocks, against the global Config
--- (main.lua's validateConfig, which the admin panel also runs against a
--- copy with a change in it). A block or a setting missing is filled from
--- defaults.lua; one that breaks its rule is put back to the shipped value,
--- and said. A feature that cannot work is never refused a start: it is off.
---@param warn string[] where each correction is said
---@param filled string[] where each setting filled in is named
function RpConsequences.checkConfig(warn, filled)
    local names = {}
    for name in pairs(RULES) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        Feature.check('Roleplay.' .. name, RULES[name], warn, filled)
    end
end

--------------------------------------------------------------------------
-- Positions and words
--------------------------------------------------------------------------

local function coordsOf(src)
    local ok, at = pcall(function() return GetEntityCoords(GetPlayerPed(src)) end)
    if not ok or not at then return nil end
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if not x or not y then return nil end
    return { x = x, y = y, z = z or 0.0 }
end

local COMPASS = { 'north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west' }

--- Where somebody is going, as a compass point: from how they are moving
--- when they are (faster than a walk), and from the way they face when they
--- are not. GTA headings turn anticlockwise from north.
---@param src integer
---@return string
function RpConsequences.directionOf(src)
    local ped = GetPlayerPed(src)
    local bearing
    local okV, v = pcall(GetEntityVelocity, ped)
    local vx, vy = okV and v and tonumber(v.x), okV and v and tonumber(v.y)
    if vx and vy and (vx * vx + vy * vy) > 2.25 then
        bearing = math.deg(math.atan(vx, vy))
    else
        local okH, heading = pcall(GetEntityHeading, ped)
        bearing = 360 - ((okH and tonumber(heading)) or 0)
    end
    bearing = bearing % 360
    return COMPASS[(math.floor((bearing + 22.5) / 45) % 8) + 1]
end

--- The area list, parsed once per list it is given.
local parsedFrom, parsed = nil, {}
local function areas()
    local list = Feature.block('Roleplay.WitnessHeat').Areas
    if list ~= parsedFrom then
        parsedFrom, parsed = list, {}
        for _, entry in ipairs(type(list) == 'table' and list or {}) do
            local spot = Places.parseArea(entry)
            if spot then parsed[#parsed + 1] = spot end
        end
    end
    return parsed
end

--- The named area nearest a position (Config.Roleplay.WitnessHeat.Areas),
--- or 'the city' with none listed. The server has no street names (those
--- natives are the client's), so this is as precise as it says.
---@param at table|nil { x, y }
---@return string
function RpConsequences.areaOf(at)
    local best, bestD
    if at then
        for _, area in ipairs(areas()) do
            local dx, dy = area.x - at.x, area.y - at.y
            local d = dx * dx + dy * dy
            if not bestD or d < bestD then best, bestD = area.name, d end
        end
    end
    return best or 'the city'
end

local function pick(list)
    if type(list) ~= 'table' or #list == 0 then return nil end
    return list[math.random(1, #list)]
end

--- Text for a phone or a post: one line, no markup, at most `max` long.
local function clean(text, max)
    text = tostring(text):gsub('[%c<>]', ' ')
    -- Cut by characters, never through one (Util.sanitizeText).
    return Util.sanitizeText(text, max) or ''
end

--------------------------------------------------------------------------
-- Witness heat
--------------------------------------------------------------------------

--- Every citizen id party to a contract: placer, target and each hitman.
local function partiesOf(contract)
    local parties = { [contract.creator_cid] = true, [contract.target_cid] = true }
    for _, row in ipairs(Storage.readHitmen(contract.id) or {}) do parties[row.hitman_cid] = true end
    return parties
end

--- How many players saw it: within WitnessRadius of the hitman, in the same
--- routing bucket, visible, and party to nothing in the contract. Positions
--- are the server's, never a client's word.
---@return integer count
---@return table|nil at the hitman's position
function RpConsequences.witnesses(contract, hitmanSrc, radius)
    local at = coordsOf(hitmanSrc)
    if not at then return 0, nil end
    local parties = partiesOf(contract)
    local bucket = GetPlayerRoutingBucket(hitmanSrc)
    local reach = radius * radius
    local count = 0
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        if src and src ~= hitmanSrc and GetPlayerRoutingBucket(src) == bucket then
            local there = coordsOf(src)
            if there and Geo.dist2(at, there) <= reach and IsEntityVisible(GetPlayerPed(src)) then
                local actor = Identity.resolve(src)
                if actor and not parties[actor.cid] then count = count + 1 end
            end
        end
    end
    return count, at
end

--- The report, sent: to every officer online (Advisory.RecipientJob*)
--- who is no party to the contract, and to sc-dispatch. It names nobody:
--- a phrase, a direction, an area, and a position only when SendCoords is
--- on, moved by up to FuzzMeters.
local function witnessAlert(contract, hitmanCid, slot)
    local cfg = Feature.active('Roleplay.WitnessHeat')
    if not cfg then return false end
    local hitman = Identity.byCitizenId(hitmanCid)
    if not hitman then return false end
    local seen, at = RpConsequences.witnesses(contract, hitman.source, tonumber(cfg.WitnessRadius) or 60)
    if not at then return false end
    if seen < (tonumber(cfg.MinWitnesses) or 1) and cfg.AlwaysAlert ~= true then return false end

    local area = RpConsequences.areaOf(at)
    local phrase = pick(cfg.Phrases) or 'a person was seen leaving {direction}'
    local said = phrase:gsub('{direction}', RpConsequences.directionOf(hitman.source))
    said = clean(('%s%s near %s.'):format(said:sub(1, 1):upper(), said:sub(2), area), 200)
    local title = clean(cfg.Title or 'Witness report', 60)

    local parties = partiesOf(contract)
    local told = Police.tell(title, said, function(actor) return parties[actor.cid] end)

    local dispatched = false
    if Integrations.has('dispatch') then
        local coords
        if cfg.SendCoords == true then
            local fuzz = math.max(0, tonumber(cfg.FuzzMeters) or 0)
            local angle, dist = math.random() * 2 * math.pi, math.random() * fuzz
            local x = math.floor((at.x + math.cos(angle) * dist) * 10 + 0.5) / 10
            local y = math.floor((at.y + math.sin(angle) * dist) * 10 + 0.5) / 10
            coords = vector3 and vector3(x, y, at.z) or { x = x, y = y, z = at.z }
        end
        dispatched = Police.dispatch({
            title = title, message = said, coords = coords, street = clean(area, 100),
            caller = 'Witness', priority = math.floor(tonumber(cfg.DispatchPriority) or 2),
            unique_id = ('ch-wit-%s-%s'):format(tostring(contract.id), tostring(slot or 1)),
        })
    end
    Audit.action('rp_witness_alert', nil, contract.id, { witnesses = seen, told = told,
        dispatched = dispatched or nil })
    return true
end
RpConsequences.witnessAlert = witnessAlert

--------------------------------------------------------------------------
-- EMS before re-listing
--------------------------------------------------------------------------

--- The target's last kill on a contract: this process's own record, or the
--- target's Ledger row of it (kept by every backend), whichever is later.
local function lastKill(cid)
    local at = killedAt[cid]
    if Ledger then
        local ok, rows = pcall(Ledger.read, cid)
        for _, row in ipairs(ok and type(rows) == 'table' and rows or {}) do
            if row.role == 'target' and row.fulfilment == CH.FULFILMENT.ELIMINATION then
                local when = tonumber(row.resolved_at)
                if when and (not at or when > at) then at = when end
            end
        end
    end
    return at
end

--- Keep what is known of one recovering target in the store, or take it
--- away once nothing is. Only when it changed: never on every tick.
local function keep(cid)
    if not Storage or not Storage.writeRpRow then return end
    local id = EMS_KIND .. ':' .. tostring(cid)
    if not killedAt[cid] then
        tracked[cid], carried[cid] = nil, nil
        pcall(Storage.deleteRpRow, id)
        return
    end
    tracked[cid] = killedAt[cid]
    pcall(Storage.writeRpRow, { id = id, kind = EMS_KIND, cid = cid, killed_at = killedAt[cid],
                                up_since = upSince[cid], medic_at = medicAt[cid] })
end

--- Forget a target who has recovered, here and in the store.
local function forget(cid)
    local had = killedAt[cid] ~= nil or tracked[cid] ~= nil
    killedAt[cid], upSince[cid], medicAt[cid] = nil, nil, nil
    if had then keep(cid) end
end

--- Look at one recovering target now: up, or not, since when.
local function observe(cid, now)
    local before = upSince[cid]
    local actor = Identity.byCitizenId(cid)
    if not actor then
        -- Away since the restart: the count kept from before it waits for
        -- them to be seen again.
        if not carried[cid] then upSince[cid] = nil end
    else
        carried[cid] = nil
        local dead, downed, known = Identity.deathState(actor.source)
        if not known or dead or downed then
            upSince[cid] = nil
        else
            upSince[cid] = upSince[cid] or now
        end
    end
    if upSince[cid] ~= before then keep(cid) end
end

--- Whether a new contract on this target waits for them to be treated
--- (Contracts.relistHold). Read now, so what the placer is told is current.
---@param targetActor table
---@return boolean held
function RpConsequences.relistHold(targetActor)
    local cfg = Feature.active('Roleplay.EmsRelisting')
    if not cfg or not targetActor then return false end
    local cid = targetActor.cid
    local kill = lastKill(cid)
    if not kill then return false end
    local now = os.time()
    if now - kill >= (tonumber(cfg.MaxHoldMinutes) or 120) * 60 then
        forget(cid)
        return false
    end
    if killedAt[cid] ~= kill then
        -- A kill not seen here before (the Ledger's, or a newer one): what
        -- was seen of them belonged to the last one.
        if killedAt[cid] and killedAt[cid] < kill then upSince[cid], medicAt[cid] = nil, nil end
        killedAt[cid] = kill
        keep(cid)
    end
    observe(cid, now)
    local up = upSince[cid]
    if not up then return true end
    -- A medic's revive, where one is asked for and what was heard since the
    -- kill is known: seen by this process, or kept in the store for this
    -- kill. One from before either, and the timer decides.
    if cfg.RequireEMS == true and (kill >= startedAt or tracked[cid] == kill) then
        return not (medicAt[cid] and medicAt[cid] >= kill)
    end
    return (now - math.max(up, kill)) < (tonumber(cfg.TreatedMinutes) or 10) * 60
end

--- A medic's defibrillator on a player, heard and checked as Death.noteDefib
--- checks it (server/bridges.lua).
---@param targetSource any
function RpConsequences.noteMedicRevive(targetSource)
    local actor = Identity.resolve(tonumber(targetSource))
    if actor then
        medicAt[actor.cid] = os.time()
        if killedAt[actor.cid] then keep(actor.cid) end
    end
end

--- From the maintenance tick: each target still recovering looked at, so
--- the time they have been up is counted while nobody asks.
function RpConsequences.tick()
    local cfg = Feature.active('Roleplay.EmsRelisting')
    if not cfg then
        if next(killedAt) then
            local cids = {}
            for cid in pairs(killedAt) do cids[#cids + 1] = cid end
            for i = 1, #cids do forget(cids[i]) end
        end
        return
    end
    local now = os.time()
    local hold = (tonumber(cfg.MaxHoldMinutes) or 120) * 60
    local cids = {}
    for cid in pairs(killedAt) do cids[#cids + 1] = cid end
    for i = 1, #cids do
        local cid = cids[i]
        if now - killedAt[cid] >= hold then
            forget(cid)
        else
            observe(cid, now)
        end
    end
end

--------------------------------------------------------------------------
-- City news
--------------------------------------------------------------------------

--- The words of one post, or nil where this contract is not news.
---@return string|nil
function RpConsequences.newsText(contract, hitmanCid)
    local cfg = Feature.active('Roleplay.CityNews')
    if not cfg then return nil end
    local whitelisted, shown = Identity.whitelistedTarget(contract)
    if not whitelisted and cfg.AllTargets ~= true then return nil end
    local job = whitelisted and (shown or contract.target_job) or contract.target_job
    if type(job) ~= 'string' or job == '' or job == 'unemployed' then job = 'resident' end
    -- Where the target is, never where the hitman is: the post would say
    -- where the hitman went next. Nobody in the city: 'the city'.
    local target = Identity.byCitizenId(contract.target_cid)
    local at = target and coordsOf(target.source) or nil
    local name = cfg.NameTarget == true and contract.target_name or 'a resident'
    local text = pick(cfg.Templates)
    if not text then return nil end
    local fill = { job = job, zone = RpConsequences.areaOf(at), time = os.date('%H:%M'), name = tostring(name) }
    text = text:gsub('{(%a+)}', function(key) return fill[key] end)
    return clean(text, 280)
end

--- Post it, through Police & press (Police.press, server/police.lua).
local function postNews(contract, hitmanCid)
    local cfg = Feature.active('Roleplay.CityNews')
    if not cfg then return false end
    local text = RpConsequences.newsText(contract, hitmanCid)
    if not text then return false end
    local posted = Police.press(cfg, text)
    Audit.action('rp_city_news', nil, contract.id, { app = cfg.App, posted = posted })
    return posted
end
RpConsequences.postNews = postNews

--------------------------------------------------------------------------
-- Dirty money payouts
--------------------------------------------------------------------------

--- For Escrow.deliver: whether this cash or bank give is a hitman's payout
--- to pay as the item. Only a baseline or bonus line, to a hitman on the
--- contract who did not put it up: a refund, a stake or a returned bonus
--- goes back as it was taken.
---@return table|nil { item, rate } or { item, worth }
function RpConsequences.payoutAs(recipientCid, line)
    local cfg = Feature.active('Roleplay.DirtyPayouts')
    if not cfg or type(line) ~= 'table' then return nil end
    if line.source ~= 'cash' and line.source ~= 'bank' then return nil end
    if line.portion ~= CH.PORTION.BASELINE and line.portion ~= CH.PORTION.BONUS then return nil end
    if line.taken_from ~= nil and line.taken_from == recipientCid then return nil end
    if not Storage.readHitman(line.contract_id, recipientCid) then return nil end
    if cfg.Mode == 'worth' then
        return { item = cfg.Item, worth = cfg.WorthKey or 'worth' }
    end
    return { item = cfg.Item, rate = math.max(1, math.floor(tonumber(cfg.Rate) or 1)) }
end

--------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------

--- After every claim that paid (Contracts.afterClaim).
function RpConsequences.onClaimed(contractId, hitmanCid, fulfilment, result)
    if not (Feature.active('Roleplay.WitnessHeat') or Feature.active('Roleplay.EmsRelisting') or Feature.active('Roleplay.CityNews')) then return end
    -- A proof item handed to the placer (server/imp_proof.lua): nobody was
    -- seen killed, so no EMS hold, and no news of an attack. Nor a witness
    -- report: it would say where the hitman stood, beside the placer.
    if fulfilment == CH.FULFILMENT.PROOF then return end
    local contract = Storage.readContract(contractId)
    if not contract then return end
    if fulfilment == CH.FULFILMENT.ELIMINATION and Feature.active('Roleplay.EmsRelisting') then
        killedAt[contract.target_cid] = os.time()
        upSince[contract.target_cid], medicAt[contract.target_cid] = nil, nil
        carried[contract.target_cid] = nil
        keep(contract.target_cid)
    end
    local _, alerted = pcall(witnessAlert, contract, hitmanCid, result and result.slot)
    -- A report went: the hitman's heat (server/record/heat.lua), when on.
    if alerted == true and RpConsequences.afterWitness then
        pcall(RpConsequences.afterWitness, contract, hitmanCid)
    end
    pcall(postNews, contract, hitmanCid)
end

---@param deps table { storage, identity, notify, audit, ledger, contracts, escrow }
function RpConsequences.init(deps)
    Storage, Identity = deps.storage, deps.identity
    Audit, Ledger = deps.audit, deps.ledger
    killedAt, upSince, medicAt, carried, tracked = {}, {}, {}, {}, {}
    startedAt = os.time()
    -- What the last run kept of each recovering target, so the tick goes
    -- on counting from where it was.
    if Storage and Storage.readRpRows then
        local ok, rows = pcall(Storage.readRpRows, EMS_KIND)
        for _, row in ipairs(ok and type(rows) == 'table' and rows or {}) do
            local cid, kill = row.cid, tonumber(row.killed_at)
            if type(cid) == 'string' and kill then
                killedAt[cid], tracked[cid] = kill, kill
                upSince[cid] = tonumber(row.up_since)
                medicAt[cid] = tonumber(row.medic_at)
                carried[cid] = upSince[cid] ~= nil or nil
            end
        end
    end
    if deps.contracts then
        deps.contracts.afterClaim.rpConsequences = RpConsequences.onClaimed
        deps.contracts.relistHold = RpConsequences.relistHold
    end
    if deps.escrow then deps.escrow.payoutAs = RpConsequences.payoutAs end
end

return RpConsequences
