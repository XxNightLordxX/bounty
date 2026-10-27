--- The built-in playtime tracker: how long each character has been in the
--- city, for the new-player rule (Config.Immunity.MinTargetPlaytimeHours).
---
--- The rule asks Identity.playtimeHours, which asks, in order: the export a
--- server configures (Config.Immunity.PlaytimeProvider); a playtime figure in
--- the character's QBox metadata (metadata.playtime, in minutes), which some
--- builds keep and qbx_core 1.24 does not; and then this.
---
--- What it counts: each character's time in the city, by citizen id, from
--- the moment they are seen (a login, or the first pass after this resource
--- started with them already here) to the moment they go (a disconnect or a
--- character switch) or the resource stops. Counted on the maintenance tick,
--- once a minute (Playtime.PASS_SECONDS), on a drop and at the stop, each time
--- from where the last count ended, so no stretch is counted twice. Time
--- while the resource is stopped is not counted, and a crash loses what was
--- counted since the last pass, a minute at most.
---
--- Written in batches: the rows that changed since the last pass, in one
--- write a pass (one transaction on mysql), never once a player. Each is the
--- whole figure, never an amount to add, so a batch written again after one
--- that went unanswered counts nothing twice. json keeps them in
--- data/playtime.json, written by the store's flush; mysql in
--- crimson_playtime; memory only until the resource stops.
---
--- Characters from before. A server that installs this has players who have
--- played for months with no time counted here, and the floor must not
--- suddenly protect them. qbx_core's players table (qbx_core.sql, 1.24)
--- numbers every character it saves with an AUTO_INCREMENT `id`, which only
--- grows, and keeps no creation date. So at the tracker's first start the
--- highest number there is recorded once (crimson_meta, or playtime.json),
--- and a character whose number is at or under it existed before:
--- grandfathered, counted as having played enough whatever their hours say.
--- Read through oxmysql, which qbx_core always has, on json too. Where that
--- table cannot be read, characters first seen in the
--- Config.Immunity.GrandfatherDays days after the first start are
--- grandfathered instead, and a brand-new one made in those days is too.
---
--- Decided once a character, the first time a pass sees them in the city,
--- and kept with their row. Until it is decided (qbx_core's table not
--- answering yet) the tracker has no answer for them and the rule is skipped,
--- as for a player nothing can answer for: a figure nobody can read never
--- protects anybody.
---
--- Staff set or reset one character's hours from the admin panel (Players).

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Playtime = {}

--- The maintenance tick counts at most this often.
Playtime.PASS_SECONDS = 60

local deps, Storage
--- The mysql store, for qbx_core's players table: read through its bounded
--- awaits in any storage mode (MySQLStore.playersTopId and playerNumber).
local MySQLStore

local rows = {}      -- [cid] = { seconds, grandfathered = true|false|nil, first_seen }, once read
local pending = {}   -- [cid] = seconds counted before their row was read
local dirty = {}     -- [cid] = true: counted, set or decided since its last write
local online = {}    -- [cid] = { since = Util.monotonicMs() where the last count ended }
local install = nil  -- { since = os.time(), playersId = integer|nil } once known
local nextPass, passing, waitingSaid = 0, false, false

--- Count one character's time up to `nowMs`, from where the last count
--- ended, in whole seconds: what is left of a second is counted next time.
---@param cid string
---@param nowMs integer
local function count(cid, nowMs)
    local on = online[cid]
    if not on then return end
    local whole = math.floor((nowMs - on.since) / 1000)
    if whole <= 0 then return end
    on.since = on.since + whole * 1000
    local row = rows[cid]
    if row then
        row.seconds = row.seconds + whole
        dirty[cid] = true
    else
        pending[cid] = (pending[cid] or 0) + whole
    end
end

--- Seconds counted for a row, the stretch since the last count included.
local function secondsOf(cid, row)
    local seconds = row.seconds
    local on = online[cid]
    if on then seconds = seconds + math.max(0, math.floor((Util.monotonicMs() - on.since) / 1000)) end
    return seconds
end

--- One character's row, read from the store the first time it is needed,
--- and a new one where the store has none. `peek` reads without making one:
--- nil for a character the tracker has never counted. Raises when the store
--- does not answer; read again next time.
---@param cid string
---@param peek boolean|nil
---@return table|nil row
local function rowOf(cid, peek)
    local row = rows[cid]
    if row then return row end
    local stored = Storage.readPlaytime(cid)
    -- Read meanwhile by somebody else (mysql waits): theirs stands.
    if rows[cid] then return rows[cid] end
    if type(stored) == 'table' then
        local grandfathered = nil
        if stored.grandfathered ~= nil then grandfathered = stored.grandfathered == true end
        row = {
            seconds = math.max(0, math.floor(tonumber(stored.played_seconds) or 0)),
            grandfathered = grandfathered,
            first_seen = tonumber(stored.first_seen) or os.time(),
        }
    elseif peek and not pending[cid] then
        return nil
    else
        row = { seconds = 0, first_seen = os.time() }
        dirty[cid] = true
    end
    if pending[cid] then
        row.seconds = row.seconds + pending[cid]
        pending[cid] = nil
        dirty[cid] = true
    end
    rows[cid] = row
    return row
end

--- Whether a character existed before the tracker first started, decided
--- once and kept with their row. Raises when qbx_core's players table does
--- not answer; decided at a later pass.
---@param cid string
---@param row table
local function decide(cid, row)
    if row.grandfathered ~= nil or not install then return end
    if install.playersId == nil then
        local days = tonumber(Config.Immunity.GrandfatherDays) or 0
        row.grandfathered = row.first_seen < install.since + days * 86400
    else
        local number = MySQLStore.playerNumber(cid)
        if row.grandfathered ~= nil then return end
        -- No row in qbx_core's table is a character it has not saved yet:
        -- a new one, as is any numbered after the first start.
        row.grandfathered = number ~= nil and number <= install.playersId
    end
    dirty[cid] = true
end

--- When the tracker first started on this store: read, or, at its first
--- start, recorded now with the highest number in qbx_core's players table.
--- Raises when the store does not answer.
---@return boolean known
local function knowInstall()
    if install then return true end
    local kept = Storage.readPlaytimeInstall()
    if type(kept) == 'table' and tonumber(kept.since) then
        install = { since = tonumber(kept.since), playersId = tonumber(kept.players_id) }
        return true
    end
    if not (GetResourceState('oxmysql') == 'started' and MySQL) then
        if not waitingSaid then
            waitingSaid = true
            Log.debug('playtime: waiting for oxmysql to start before reading qbx_core\'s players '
                .. 'table; until then the playtime rule is skipped for every character this '
                .. 'tracker has not decided')
        end
        return false
    end
    local asked, top = pcall(MySQLStore.playersTopId)
    local playersId = nil
    if asked then
        playersId = top
    elseif MySQLStore.timedOut(top) then
        -- Not answered: asked again at the next pass.
        return false
    else
        Log.problem(('playtime: qbx_core\'s players table could not be read (%s), so a character '
            .. 'from before the playtime tracker cannot be told from a new one. Characters first '
            .. 'seen in the next %s day(s) (Config.Immunity.GrandfatherDays) count as having played '
            .. 'enough, a brand-new one among them.')
            :format(Util.dbError(top), tostring(tonumber(Config.Immunity.GrandfatherDays) or 0)))
    end
    local since = os.time()
    Storage.writePlaytimeInstall(since, playersId)
    install = { since = since, playersId = playersId }
    Log.debug(playersId
        and ('playtime: the tracker started; characters numbered up to %d in qbx_core\'s players '
            .. 'table existed before it and are grandfathered'):format(playersId)
        or 'playtime: the tracker started, grandfathering by the days after its first start')
    return true
end

--- Write every row counted, set or decided since its last write, in one
--- batch. A batch the store refuses stays to be written by the next pass.
--- `stopping` hands it over without waiting, as the resource goes.
---@param stopping boolean|nil
---@return integer written
function Playtime.flush(stopping)
    if not Storage then return 0 end
    local cids, at = {}, os.time()
    for cid in pairs(dirty) do
        if rows[cid] then cids[#cids + 1] = cid end
    end
    if #cids == 0 then return 0 end
    table.sort(cids)
    local batch = {}
    for i = 1, #cids do
        local row = rows[cids[i]]
        batch[i] = { cid = cids[i], played_seconds = row.seconds, grandfathered = row.grandfathered,
                     first_seen = row.first_seen, updated_at = at }
        dirty[cids[i]] = nil
    end
    local write = (stopping and Storage.writePlaytimeNoWait) or Storage.writePlaytime
    local ok, err = pcall(write, batch)
    if not ok then
        for i = 1, #cids do dirty[cids[i]] = true end
        if stopping then return 0 end
        error(err, 0)
    end
    return #batch
end

--- One pass: everybody in the city counted up to now, the rows of those not
--- read yet read, who is grandfathered decided, and what changed written in
--- one batch. Raises when the store did not read or write; what it counted
--- is kept for the next pass.
---@return integer written
local function passNow()
    local nowMs = Util.monotonicMs()
    local here = {}
    for _, actor in ipairs(deps.identity.online()) do
        here[actor.cid] = true
        if online[actor.cid] then count(actor.cid, nowMs) else online[actor.cid] = { since = nowMs } end
    end
    -- Gone without a drop this resource heard: what was counted up to the
    -- last pass stands, and nothing after it is guessed.
    for cid in pairs(online) do
        if not here[cid] then online[cid] = nil end
    end

    local failure
    local asked, known = pcall(knowInstall)
    if not asked then failure = known end
    local deciding = asked and known == true
    local cids = {}
    for cid in pairs(here) do cids[#cids + 1] = cid end
    table.sort(cids)
    for _, cid in ipairs(cids) do
        local read, row = pcall(rowOf, cid)
        if not read then
            failure = failure or row
            break
        end
        if deciding then
            local decided, why = pcall(decide, cid, row)
            if not decided then
                -- Asked again at the next pass; the rule is skipped for them
                -- meanwhile, as for anybody nothing can answer for.
                deciding = false
                Log.debug(('playtime: qbx_core\'s players table did not say whether %s existed '
                    .. 'before the tracker (%s); asked again at the next pass')
                    :format(cid, Util.dbError(why)))
            end
        end
    end

    local wrote, written = pcall(Playtime.flush)
    if not wrote then failure = failure or written end
    if failure then error(failure, 0) end
    return written
end

--- The maintenance tick's pass, at most every PASS_SECONDS.
---@return integer written
function Playtime.pass()
    local now = os.time()
    if not Storage or passing or now < nextPass then return 0 end
    nextPass = now + Playtime.PASS_SECONDS
    passing = true
    local ok, result = pcall(passNow)
    passing = false
    if not ok then error(result, 0) end
    return result
end

--- A character has come into the city (a login): counted from now. Their
--- row is read in a thread of its own, so a store that waits never holds up
--- the login it was called from.
---@param cid string
function Playtime.arrive(cid)
    cid = Util.toCitizenId(cid)
    if not cid or not Storage or online[cid] then return end
    online[cid] = { since = Util.monotonicMs() }
    if rows[cid] then return end
    CreateThread(function()
        local ok, err = pcall(rowOf, cid)
        if not ok then
            Log.debug(('playtime: %s\'s counted time could not be read at their login (%s); read '
                .. 'again at the next pass'):format(cid, Util.dbError(err)))
        end
    end)
end

--- A character has left the city (a disconnect, a character switch):
--- counted up to now, and written with the next pass's batch.
---@param cid string
function Playtime.leave(cid)
    if not cid or not online[cid] then return end
    count(cid, Util.monotonicMs())
    online[cid] = nil
end

--- The resource is stopping: everybody in the city counted up to now, and
--- what is not written yet handed to the store without waiting. Nothing
--- counted here is counted again: the next start counts from its own first
--- pass, and the time between is not counted at all.
---@return integer written
function Playtime.stop()
    if not Storage then return 0 end
    local nowMs = Util.monotonicMs()
    for cid in pairs(online) do count(cid, nowMs) end
    online = {}
    -- json and memory read without waiting: a row not read yet is read now,
    -- so what was counted before it is kept.
    if not Storage.remote then
        for cid in pairs(pending) do pcall(rowOf, cid) end
    end
    return Playtime.flush(true)
end

--- What the rule reads: hours counted, the stretch since the last count
--- included, and whether they are grandfathered. nil while the tracker
--- cannot say: their row not read yet, or not decided.
---@param cid string
---@return number|nil hours
---@return boolean|nil grandfathered
function Playtime.answer(cid)
    local row = cid and rows[cid]
    if not row or row.grandfathered == nil then return nil end
    return secondsOf(cid, row) / 3600, row.grandfathered
end

--- One character as staff see it (the admin panel's Players, the
--- diagnosis). A read: nothing is written for a character looked up.
---@param cid string
---@return table { hours, grandfathered, counting, counted, unread }
function Playtime.view(cid)
    local out = { counting = online[cid] ~= nil }
    local read, row = pcall(rowOf, cid, true)
    if not read then
        out.unread = true
        return out
    end
    out.counted = row ~= nil
    out.hours = row and math.floor(secondsOf(cid, row) / 360 + 0.5) / 10 or 0
    if row then out.grandfathered = row.grandfathered end
    return out
end

--- Staff set one character's counted time (the admin panel's Players),
--- written at once and counted on from now if they are in the city. Raises
--- when their row cannot be read.
---@param cid string
---@param seconds integer
---@return number before hours counted before, to one decimal
---@return boolean written false when the store did not take it yet: the
--- next pass writes it
function Playtime.set(cid, seconds)
    local row = rowOf(cid)
    local before = math.floor(secondsOf(cid, row) / 360 + 0.5) / 10
    row.seconds = math.max(0, math.floor(seconds))
    if online[cid] then online[cid].since = Util.monotonicMs() end
    dirty[cid] = true
    local written = pcall(Playtime.flush)
    return before, written
end

--- What the tracker knows of itself, for the diagnosis: when it first
--- started, how characters from before are told, how many are counted now.
---@return table { since, playersId, grace, counting, unwritten }
function Playtime.state()
    local counting, unwritten = 0, 0
    for _ in pairs(online) do counting = counting + 1 end
    for _ in pairs(dirty) do unwritten = unwritten + 1 end
    return {
        since = install and install.since or nil,
        playersId = install and install.playersId or nil,
        grace = install ~= nil and install.playersId == nil,
        counting = counting, unwritten = unwritten,
    }
end

--- Wire the tracker, and make it the playtime rule's last answer
--- (Identity.playtimeHours). Nothing is read until the first pass.
---@param d table { storage, identity }
function Playtime.init(d)
    deps = d
    Storage = d.storage
    MySQLStore = CrimsonBoot.require('server.storage.mysql')
    rows, pending, dirty, online = {}, {}, {}, {}
    install, nextPass, passing, waitingSaid = nil, 0, false, false
    if d.identity and d.identity.setTracker then d.identity.setTracker(Playtime) end
end

return Playtime
