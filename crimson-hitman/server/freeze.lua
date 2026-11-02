--- Staff freezes: a player's contracts put on hold from the admin panel.
---
--- Staff freeze a player (Players, in /hitmanadmin) for a staff situation or
--- an RP dispute. While they are frozen, every live contract (active or
--- accepted) they are party to, as the target, the placer or an active
--- operative, is on hold: nothing on it is accepted, completed, paid out,
--- handed over, bought out, informed on, tipped, amended, cancelled with a
--- refund or expired, and nothing is charged, refunded or moved. Each is
--- refused with CH.ERR.CONTRACT_FROZEN. A frozen player cannot place or take
--- a contract, and a contract on them cannot be placed.
---
--- The clocks reuse the pause every contract already has. The deadline
--- stops the way a party logging off stops it (Storage.startPause), and is
--- banked when the hold ends (Storage.endPause), as the expiry pass banks
--- one. The lifetime, which runs through every other pause, stops too: the
--- time a contract was on hold is added back to it when the hold ends. A
--- contract two frozen players are party to is on hold until the last of
--- them is released, and its lifetime is given back the whole span once.
---
--- There is no timer: a freeze ends only when staff unfreeze. It is kept by
--- the store (crimson_freezes on mysql, records.json on json), so it holds
--- across a restart.
---
--- The restart hold lives here too: every live contract held for the last
--- half hour before a scheduled txAdmin restart (Freeze.scheduledRestart).
--- It reuses the same pause, and no hold ends another's: a contract's clock
--- runs again only once no staff freeze, no restart hold and nobody's
--- absence still stops it (the expiry pass in server/main.lua decides). Its
--- lifetime is given back the time on hold too, as a freeze's is: when the
--- hold is released, or at the start after the restart it was for (its
--- start kept in the resource's KVP for that), never twice for a span a
--- staff freeze also covered.
---
--- The app pause lives here too (Config.Staff.AppPaused, a switch under
--- Features): staff stop the whole app for an event. No contract is placed
--- or accepted (Contracts.create and accept ask Freeze.appPaused), and every
--- live contract is held as the restart hold holds it: its deadline stops
--- (Storage.startPause) and its lifetime is given back the time paused,
--- never twice for a span another hold also covers. Its start is kept by the
--- store (Storage.writeStaffMeta 'staff_pause_since'), so a pause outlives a
--- restart and its lifetime is still given back once it ends.
---
--- Anonymity: nothing here says which party is frozen. The frozen player is
--- told their contracts are on hold; every other party of each contract is
--- told that contract is, in the same words whoever caused it; a card says
--- On hold and nothing else.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local Freeze = {}

local Storage, Audit, Notify, Kidnap, Contracts

local frozen = {}   -- [cid] = { cid, name, reason, by_cid, frozen_at }
--- How many are frozen: always counted from `frozen` (recount), never kept
--- as a running sum two interleaved requests could each move.
local count = 0
--- A freeze or release of a player in flight: [cid] = true. Each awaits the
--- store, and a second one let in meanwhile read the first's stale state.
local inFlight = {}

local function recount()
    local n = 0
    for _ in pairs(frozen) do n = n + 1 end
    count = n
end

--- One freeze or release per player at a time: another for the same player
--- while one is in flight is refused as busy, never run alongside it.
local function oneAtATime(cid, fn, ...)
    if inFlight[cid] then return false, CH.ERR.BUSY end
    inFlight[cid] = true
    local out = table.pack(pcall(fn, ...))
    inFlight[cid] = nil
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
end

--- The restart hold now, or nil: { since }. Kept in memory only, so
--- the resource starting again after the restart is what ends it.
local restartHold = nil
--- Where the restart hold's start is kept across the restart it is for.
local RESTART_KVP = 'crimson_hitman:restart_hold_since'

--- What players are told. Plain, and never which party.
Freeze.TEXT = {
    title       = 'On hold',
    held        = 'This contract is on hold by staff.',
    released    = 'This contract is no longer on hold.',
    you         = 'Staff have put your contracts on hold.',
    youReleased = 'Your contracts are no longer on hold.',
}

--- The states a hold applies to. A contract mid-completion finishes as it
--- began: it is already being paid, and stopping there strands the money.
local LIVE = { [CH.STATE.ACTIVE] = true, [CH.STATE.ACCEPTED] = true }

--- Give a contract's lifetime `back` seconds, added to the expiry as it is
--- right now: read again under the contract's lock (Contracts.serialized)
--- just before the write. Added to a copy read before a pass's awaits, the
--- write put back whatever a staff deadline or lifetime change had written
--- in between. A lock another call holds is not waited for: the contract is
--- still read again, just before the write, rather than not given back.
---@param contractId string
---@param back integer seconds
local function giveBack(contractId, back)
    if not back or back <= 0 then return end
    local function apply()
        local fresh = Storage.readContract(contractId)
        if not fresh or not LIVE[fresh.state] or not fresh.expires_at then return true end
        Storage.setContractFields(contractId, { expires_at = (tonumber(fresh.expires_at) or 0) + back })
        return true
    end
    if Contracts and Contracts.serialized then
        local ran, done = pcall(Contracts.serialized, { 'contract:' .. contractId }, apply)
        if ran and done == true then return end
    end
    pcall(apply)
end

local REASON_MAX = 120

--- The app pause now, or nil: { since }. Kept by the store, so it holds
--- across a restart (Freeze.syncAppPause).
local appPause = nil
local PAUSE_META = 'staff_pause_since'

---@param deps table { storage, audit, notify, kidnap, contracts }
local giveBackRestart
local loadAppPause

function Freeze.init(deps)
    Storage, Audit, Notify, Kidnap = deps.storage, deps.audit, deps.notify, deps.kidnap
    Contracts = deps.contracts
    -- A restart hold ends with the restart: this start is it.
    restartHold = nil
    Freeze.reload()
    -- An app pause from before the restart is still on: read before the
    -- restart hold's lifetime is given back, which leaves out what it covers.
    loadAppPause()
    -- And the lifetime the hold and the restart took is given back, once.
    local ok, since = pcall(GetResourceKvpInt, RESTART_KVP)
    since = ok and tonumber(since) or 0
    if since > 0 then
        pcall(DeleteResourceKvp, RESTART_KVP)
        local gave, err = pcall(giveBackRestart, since, os.time())
        if not gave then
            Log.always(('the lifetime the restart hold took could not be given back (%s)')
                :format(Util.dbError(err)))
        end
    end
    -- And the switch as it is now (a config.lua edit while it was down).
    local synced, syncErr = pcall(Freeze.syncAppPause)
    if not synced then
        Log.always(('the app pause could not be brought in line with its switch (%s)')
            :format(Util.dbError(syncErr)))
    end
end

--- Read every freeze from the store again. Done once at the start.
function Freeze.reload()
    frozen, count, inFlight = {}, 0, {}
    if not (Storage and Storage.readFreezes) then return end
    local ok, rows = pcall(Storage.readFreezes)
    if not ok then
        Log.always(('staff freezes could not be read from the store (%s); nobody reads as frozen '
            .. 'until the next start'):format(Util.dbError(rows)))
        return
    end
    for _, row in ipairs(rows or {}) do
        if row.cid then
            row.frozen_at = tonumber(row.frozen_at) or os.time()
            frozen[row.cid] = row
        end
    end
    recount()
end

--- The freeze on a player, or nil.
---@param cid string|nil
---@return table|nil
function Freeze.of(cid)
    if cid == nil or count == 0 then return nil end
    return frozen[cid]
end

---@return integer
function Freeze.count() return count end

--- Every freeze, oldest first.
---@return table[]
function Freeze.list()
    local out = {}
    for _, row in pairs(frozen) do out[#out + 1] = row end
    table.sort(out, function(a, b)
        if a.frozen_at ~= b.frozen_at then return a.frozen_at < b.frozen_at end
        return tostring(a.cid) < tostring(b.cid)
    end)
    return out
end

--- The frozen parties of a live contract, or nil when it is not on hold:
--- { { cid, row, role = 'target' | 'client' | 'operative', anonymous } }.
--- Free while nobody is frozen; otherwise one read of its operatives unless
--- the caller has them.
---@param contract table|nil
---@param hitmen table[]|nil
---@return table[]|nil
function Freeze.partiesOf(contract, hitmen)
    if count == 0 or not contract or not LIVE[contract.state] then return nil end
    local out, seen = {}, {}
    local function take(cid, role, anonymous)
        if cid and frozen[cid] and not seen[cid] then
            seen[cid] = true
            out[#out + 1] = { cid = cid, row = frozen[cid], role = role, anonymous = anonymous }
        end
    end
    take(contract.target_cid, 'target', false)
    take(contract.creator_cid, 'client', contract.anon_creator == true)
    hitmen = hitmen or Storage.readHitmen(contract.id) or {}
    for i = 1, #hitmen do
        local hitman = hitmen[i]
        if hitman.state == 'active' then take(hitman.hitman_cid, 'operative', hitman.anon == true) end
    end
    return #out > 0 and out or nil
end

--- Whether a contract is on hold.
---@param contract table|nil
---@param hitmen table[]|nil
---@return boolean
function Freeze.holds(contract, hitmen)
    return Freeze.partiesOf(contract, hitmen) ~= nil
end

--- When a contract's hold began (os.time()), or nil when it is not on hold.
---@return integer|nil
function Freeze.heldSince(contract, hitmen)
    local parties = Freeze.partiesOf(contract, hitmen)
    if not parties then return nil end
    local since
    for i = 1, #parties do
        local at = parties[i].row.frozen_at
        if not since or at < since then since = at end
    end
    return since
end

--- The live contracts a player is party to as the target, the placer or an
--- active operative, each read afresh.
---@param cid string
---@return table[]
local function liveOf(cid)
    local out = {}
    for _, listed in ipairs(Storage.contractsInvolving(cid) or {}) do
        if LIVE[listed.state] then
            local party = listed.target_cid == cid or listed.creator_cid == cid
            if not party then
                local hitman = Storage.readHitman(listed.id, cid)
                party = hitman ~= nil and hitman.state == 'active'
            end
            local contract = party and Storage.readContract(listed.id) or nil
            if contract and LIVE[contract.state] then out[#out + 1] = contract end
        end
    end
    return out
end

--- Tell every party of a contract but the frozen ones, in the same words
--- whoever caused it. The target only once they are shown the contract.
local function tellParties(contract, text, skip)
    local hitmen = Storage.readHitmen(contract.id) or {}
    local told = { [skip or false] = true }
    local function tell(cid, named)
        if not cid or told[cid] or frozen[cid] then return end
        told[cid] = true
        Notify.toCitizen(cid, Freeze.TEXT.title, text,
            { bypassBudget = true, contractId = named and contract.id or nil })
        Notify.push(cid, 'hold', named and contract.id or nil)
    end
    tell(contract.creator_cid, true)
    if Notify.shownToTarget(contract) then tell(contract.target_cid, false) end
    for i = 1, #hitmen do
        if hitmen[i].state == 'active' then tell(hitmen[i].hitman_cid, true) end
    end
end

local function cleanReason(reason)
    if type(reason) ~= 'string' then return nil end
    -- By characters, never through one: a cut UTF-8 character is refused
    -- by utf8mb4 (error 1366), and the whole write with it.
    return Util.sanitizeText(reason, REASON_MAX)
end

--- Freeze a player. Every live contract they are party to goes on hold now.
---@param staffCid string|nil who froze them, for the audit row
---@param cid string the player
---@param reason string|nil
---@param name string|nil how staff know them, for the list
---@return boolean ok
---@return string|nil err 'already_frozen' | CH.ERR.SERVER_ERROR
local freezeUnlocked
function Freeze.freeze(staffCid, cid, reason, name)
    if type(cid) ~= 'string' or cid == '' then return false, CH.ERR.INVALID_INPUT end
    return oneAtATime(cid, freezeUnlocked, staffCid, cid, reason, name)
end

freezeUnlocked = function(staffCid, cid, reason, name)
    if frozen[cid] then return false, 'already_frozen' end
    reason = cleanReason(reason)
    local now = os.time()

    -- Which of their contracts were on hold already, through somebody else:
    -- their parties were told then, and are not told again.
    local contracts = liveOf(cid)
    local already = {}
    for i = 1, #contracts do already[contracts[i].id] = Freeze.holds(contracts[i]) end

    local row = { cid = cid, name = Util.sanitizeText(name, 128),
                  reason = reason, by_cid = staffCid, frozen_at = now }
    local wrote, err = pcall(Storage.writeFreeze, row)
    if not wrote then
        Log.always(('a staff freeze could not be written (%s); nothing was put on hold')
            :format(Util.dbError(err)))
        return false, CH.ERR.SERVER_ERROR
    end
    frozen[cid] = row
    recount()

    for i = 1, #contracts do
        local contract = contracts[i]
        -- The deadline stops as a party logging off stops it. Not one that
        -- has already gone with the clock running: that contract is late
        -- already, and pausing it would give the time back.
        local overdue = not contract.paused_since and contract.deadline_at ~= nil
            and now > contract.deadline_at
        if not contract.paused_since and not overdue then
            pcall(Storage.startPause, contract.id, now)
        end
        -- A handover counting on it would end in a payout that is refused:
        -- stopped now instead, with nothing paid.
        if Kidnap and Kidnap.cancel then
            for _, hitman in ipairs(Storage.readHitmen(contract.id) or {}) do
                if hitman.state == 'active' then pcall(Kidnap.cancel, contract.id, hitman.hitman_cid, 'on_hold') end
            end
        end
    end

    Audit.staff('freeze_player', staffCid, nil, { subject = cid, reason = reason })
    Audit.flush()

    Notify.toCitizen(cid, Freeze.TEXT.title, Freeze.TEXT.you, { bypassBudget = true })
    Notify.push(cid, 'hold')
    for i = 1, #contracts do
        if not already[contracts[i].id] then tellParties(contracts[i], Freeze.TEXT.held) end
    end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

--- Release a player. Each contract no longer on hold through anybody gets
--- its deadline banked (the pause ended, as the expiry pass ends one) and
--- its lifetime given back the time it was on hold.
---@param staffCid string|nil
---@param cid string
---@param reason string|nil
---@return boolean ok
---@return string|nil err 'not_frozen' | CH.ERR.SERVER_ERROR
local unfreezeUnlocked
function Freeze.unfreeze(staffCid, cid, reason)
    if type(cid) ~= 'string' then return false, 'not_frozen' end
    return oneAtATime(cid, unfreezeUnlocked, staffCid, cid, reason)
end

unfreezeUnlocked = function(staffCid, cid, reason)
    local row = frozen[cid]
    if not row then return false, 'not_frozen' end
    reason = cleanReason(reason)
    local now = os.time()

    local removed, err = pcall(Storage.deleteFreeze, cid)
    if not removed then
        Log.always(('a staff freeze could not be removed (%s); the player stays on hold')
            :format(Util.dbError(err)))
        return false, CH.ERR.SERVER_ERROR
    end
    frozen[cid] = nil
    recount()

    local released = {}
    for _, contract in ipairs(liveOf(cid)) do
        local others = Freeze.heldSince(contract)
        -- The part of this player's hold no other hold still covers: all of
        -- it when nobody else holds the contract, and otherwise only what
        -- came before the earliest one left, which is given back with that.
        -- Never past the restart hold's start while it is on: its release
        -- gives back what it covers (giveBackRestart), and once is enough.
        local stop = others or now
        if restartHold then stop = math.min(stop, restartHold.since) end
        -- Nor past the app pause's: its end gives that back.
        if appPause then stop = math.min(stop, appPause.since) end
        local back = math.max(0, stop - row.frozen_at)
        if back > 0 and contract.expires_at then giveBack(contract.id, back) end
        -- And every open amendment proposal on it the same time: none could
        -- be answered while it was held, and none ran out meanwhile
        -- (Amendments.expire), so each is given the hold back to be answered.
        if back > 0 and Storage.readOpenAmendments and Storage.writeAmendment then
            pcall(function()
                for _, proposal in ipairs(Storage.readOpenAmendments(contract.id) or {}) do
                    if proposal.expires_at then
                        proposal.expires_at = (tonumber(proposal.expires_at) or now) + back
                        Storage.writeAmendment(proposal)
                    end
                end
            end)
        end
        if not others then
            -- Banked now only where nothing else stops it: not while the
            -- restart hold is on, and not while a party is away (the expiry
            -- pass's own judgement). Either keeps the pause going, and the
            -- pass banks all of it when the last one ends.
            local since = contract.paused_since
            if since and Freeze.clockMayRun(contract) then
                pcall(Storage.endPause, contract.id, since, math.max(0, now - since))
            end
            released[#released + 1] = contract
        end
    end

    Audit.staff('unfreeze_player', staffCid, nil, { subject = cid, reason = reason })
    Audit.flush()

    Notify.toCitizen(cid, Freeze.TEXT.title, Freeze.TEXT.youReleased, { bypassBudget = true })
    Notify.push(cid, 'hold')
    for i = 1, #released do tellParties(released[i], Freeze.TEXT.released, cid) end
    -- A party away now starts the presence pause again on the next pass.
    if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

--------------------------------------------------------------------------
-- The restart hold
--------------------------------------------------------------------------

--- Give every live contract's lifetime back the time the restart hold took,
--- from its start (or the contract's placing, if later) to `now`: as a
--- freeze's is given back. Not the part a staff freeze still holding it
--- covers, which that freeze's release gives back.
---@param since integer when the hold began
---@param now integer
giveBackRestart = function(since, now)
    for _, contract in ipairs(Storage.liveContracts() or {}) do
        if LIVE[contract.state] and contract.expires_at then
            local from = math.max(since, tonumber(contract.created_at) or since)
            local stop = math.min(now, Freeze.heldSince(contract) or now)
            -- Nor the part the app pause covers, which its end gives back.
            if appPause then stop = math.min(stop, appPause.since) end
            local back = stop - from
            if back > 0 then giveBack(contract.id, back) end
        end
    end
end

--- What every player with a live contract is told, once.
Freeze.TEXT.restartTitle = 'Server restart'
Freeze.TEXT.restart = 'Contracts are paused until the server restart.'

--- Whether the deadline of a contract no freeze holds may run again now:
--- asked of the expiry pass's own judgement (ContractClockMayRun, in
--- server/main.lua), and never while the restart hold is on.
---@param contract table
---@return boolean
function Freeze.clockMayRun(contract)
    if Freeze.restartHeld() or appPause ~= nil then return false end
    if type(ContractClockMayRun) ~= 'function' then return true end
    local ok, may = pcall(ContractClockMayRun, contract)
    return not ok or may ~= false
end

--- Whether the restart hold is on. Not once Config.Restart.MaxHoldMinutes
--- has passed, even before the tick has released it.
---@return boolean
function Freeze.restartHeld()
    return restartHold ~= nil and os.time() < Freeze.restartHoldEnds()
end

--- When the restart hold ends if the restart has not come: its start and
--- Config.Restart.MaxHoldMinutes as it is set now. nil with no hold.
---@return integer|nil
function Freeze.restartHoldEnds()
    if not restartHold then return nil end
    local minutes = math.max(1, tonumber(Config.Restart and Config.Restart.MaxHoldMinutes) or 45)
    return restartHold.since + minutes * 60
end

--- txAdmin's 'txAdmin:events:scheduledRestart' ({ secondsRemaining }), sent
--- 30, 15, 10, 5, 4, 3, 2 and 1 minutes before a scheduled restart. The
--- first one inside Config.Restart.PauseBeforeSeconds starts the hold on
--- every live contract: its deadline stops (the pause every contract has),
--- and nothing ends it, pays out a queued buyout or finishes a handover
--- until the hold ends. The ones after it change nothing.
---@param data table|nil
---@return boolean started
function Freeze.scheduledRestart(data)
    local seconds = type(data) == 'table' and tonumber(data.secondsRemaining) or nil
    if not seconds then return false end
    local within = tonumber(Config.Restart and Config.Restart.PauseBeforeSeconds) or 0
    if within <= 0 or seconds > within then return false end
    if Freeze.restartHeld() then return false end
    -- A hold past Config.Restart.MaxHoldMinutes that the tick has not
    -- released yet is released first, giving back the time it took: the
    -- new one taking its place lost that span.
    if restartHold then Freeze.releaseRestart('max_hold') end

    local now = os.time()
    restartHold = { since = now }
    pcall(SetResourceKvpInt, RESTART_KVP, now)
    local hold = Freeze.restartHoldEnds() - now

    local told = {}
    local live = Storage.liveContracts() or {}
    for i = 1, #live do
        local contract = live[i]
        if LIVE[contract.state] then
            local overdue = not contract.paused_since and contract.deadline_at ~= nil
                and now > contract.deadline_at
            if not contract.paused_since and not overdue then
                pcall(Storage.startPause, contract.id, now)
            end
            told[contract.creator_cid or false] = true
            if Notify.shownToTarget(contract) then told[contract.target_cid or false] = true end
            for _, hitman in ipairs(Storage.readHitmen(contract.id) or {}) do
                if hitman.state == 'active' then told[hitman.hitman_cid] = true end
            end
        end
    end
    told[false] = nil
    for cid in pairs(told) do
        Notify.toCitizen(cid, Freeze.TEXT.restartTitle, Freeze.TEXT.restart, { bypassBudget = true })
        Notify.push(cid, 'hold')
    end
    Log.always(('a scheduled restart is %d second(s) away: every live contract is paused until '
        .. 'the restart, for at most %d minute(s)'):format(seconds, hold // 60))
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

--- End the restart hold without a restart: txAdmin's skip, or
--- Config.Restart.MaxHoldMinutes passing. The next expiry pass lets every
--- clock nothing else stops run again, banking the time on hold.
---@param why string 'skipped' | 'max_hold'
---@return boolean released
function Freeze.releaseRestart(why)
    if not restartHold then return false end
    local since = restartHold.since
    restartHold = nil
    pcall(DeleteResourceKvp, RESTART_KVP)
    local gave, err = pcall(giveBackRestart, since, os.time())
    if not gave then
        Log.always(('the lifetime the restart hold took could not be given back (%s)')
            :format(Util.dbError(err)))
    end
    Log.always(('the restart hold on contracts has ended (%s): their clocks run again where '
        .. 'nothing else stops them'):format(tostring(why)))
    if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

--- From the maintenance tick: a hold the restart never came for ends at
--- Config.Restart.MaxHoldMinutes.
function Freeze.restartTick()
    if restartHold and os.time() >= Freeze.restartHoldEnds() then Freeze.releaseRestart('max_hold') end
end

--------------------------------------------------------------------------
-- The app pause (Config.Staff.AppPaused)
--------------------------------------------------------------------------

Freeze.TEXT.pausedTitle = 'Paused'
Freeze.TEXT.paused = 'Contracts are paused by staff.'
Freeze.TEXT.resumed = 'Contracts are no longer paused.'

--- Whether staff have paused the whole app.
---@return boolean
function Freeze.appPaused() return appPause ~= nil end

--- When the app pause began (os.time()), or nil.
---@return integer|nil
function Freeze.appPausedSince() return appPause and appPause.since or nil end

--- Every party a live contract is shown to, once each: the placer, the
--- target once shown it, and its active operatives. Never which party.
---@return table [cid] = true
local function everyLiveParty(live)
    local told = {}
    for i = 1, #live do
        local contract = live[i]
        if LIVE[contract.state] then
            if contract.creator_cid then told[contract.creator_cid] = true end
            if contract.target_cid and Notify.shownToTarget(contract) then told[contract.target_cid] = true end
            for _, hitman in ipairs(Storage.readHitmen(contract.id) or {}) do
                if hitman.state == 'active' then told[hitman.hitman_cid] = true end
            end
        end
    end
    return told
end

--- Give every live contract's lifetime back the time the app pause took,
--- from its start (or the contract's placing, if later) to `now`: not the
--- part a staff freeze or the restart hold still holding it covers, which
--- their own ends give back.
---@param since integer
---@param now integer
local function giveBackApp(since, now)
    for _, contract in ipairs(Storage.liveContracts() or {}) do
        if LIVE[contract.state] and contract.expires_at then
            local from = math.max(since, tonumber(contract.created_at) or since)
            local stop = math.min(now, Freeze.heldSince(contract) or now)
            if restartHold then stop = math.min(stop, restartHold.since) end
            local back = stop - from
            if back > 0 then giveBack(contract.id, back) end
        end
    end
end

--- What the store kept of a pause from before this start.
loadAppPause = function()
    appPause = nil
    if not (Storage and Storage.readStaffMeta) then return end
    local ok, meta = pcall(Storage.readStaffMeta)
    if not ok then
        Log.always(('the app pause could not be read from the store (%s)'):format(Util.dbError(meta)))
        return
    end
    local since = tonumber(type(meta) == 'table' and meta[PAUSE_META]) or 0
    if since > 0 then appPause = { since = since } end
end

--- Start the pause: every live contract's deadline stops now, and every
--- party is told once.
local function startAppPause()
    local now = os.time()
    -- Taken in this process before the first await: a second sync landing
    -- in the write (the panel's watcher and the tick) finds it on.
    appPause = { since = now }
    local wrote, err = pcall(Storage.writeStaffMeta, PAUSE_META, now)
    if not wrote then
        Log.always(('the app pause could not be kept by the store (%s); it is on until the next '
            .. 'start'):format(Util.dbError(err)))
    end
    local live = Storage.liveContracts() or {}
    for i = 1, #live do
        local contract = live[i]
        if LIVE[contract.state] then
            local overdue = not contract.paused_since and contract.deadline_at ~= nil
                and now > contract.deadline_at
            if not contract.paused_since and not overdue then
                pcall(Storage.startPause, contract.id, now)
            end
        end
    end
    for cid in pairs(everyLiveParty(live)) do
        Notify.toCitizen(cid, Freeze.TEXT.pausedTitle, Freeze.TEXT.paused, { bypassBudget = true })
        Notify.push(cid, 'hold')
    end
    Log.always('staff paused the app: no contract is placed or accepted, and every live '
        .. 'contract\'s clocks are held until it is switched off (Staff.AppPaused)')
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
end

--- End the pause: the lifetime given back, and the next expiry pass lets
--- each clock nothing else stops run again, banking the time paused.
local function endAppPause()
    local since = appPause.since
    local now = os.time()
    -- Taken in this process before the first await: a second sync landing
    -- in the write finds it off, and gives nothing back a second time.
    appPause = nil
    local wrote, err = pcall(Storage.writeStaffMeta, PAUSE_META, 0)
    if not wrote then
        Log.always(('the end of the app pause could not be kept by the store (%s)')
            :format(Util.dbError(err)))
    end
    local gave, giveErr = pcall(giveBackApp, since, now)
    if not gave then
        Log.always(('the lifetime the app pause took could not be given back (%s)')
            :format(Util.dbError(giveErr)))
    end
    for cid in pairs(everyLiveParty(Storage.liveContracts() or {})) do
        Notify.toCitizen(cid, Freeze.TEXT.pausedTitle, Freeze.TEXT.resumed, { bypassBudget = true })
        Notify.push(cid, 'hold')
    end
    Log.always('staff ended the app pause: contracts run again where nothing else stops them')
    if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
end

--- Bring the pause in line with its switch (Config.Staff.AppPaused): run
--- when the setting changes (Settings.watch), at the start, and on every
--- maintenance tick for a change made any other way.
---@return string|nil what 'paused' | 'resumed', or nil when nothing changed
function Freeze.syncAppPause()
    if not Storage then return nil end
    local want = type(Config.Staff) == 'table' and Config.Staff.AppPaused == true
    if want and not appPause then
        startAppPause()
        return 'paused'
    end
    if not want and appPause then
        endAppPause()
        return 'resumed'
    end
    return nil
end

return Freeze
