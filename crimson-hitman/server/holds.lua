--- Holds: every reason a live contract stands still, in one service.
---
--- A contract is "on hold" when nothing on it may move: nothing accepted,
--- completed, paid out, handed over, bought out, informed on, tipped,
--- amended, cancelled with a refund or expired, and nothing charged,
--- refunded or moved. Four things hold contracts, each a kind here:
---
---   staff    a staff freeze on a party (Players, in /hitmanadmin): every
---            live contract (active or accepted) they are party to, as the
---            target, the placer or an active operative. Kept by the store
---            (crimson_freezes on mysql, records.json on json); no timer, it
---            ends only when staff unfreeze. While the store's freezes cannot
---            be read, every live contract is held this way through nobody
---            (`unread`), until a read succeeds.
---   restart  the last half hour before a scheduled txAdmin restart
---            (Holds.scheduledRestart, Config.Holds RestartPauseBeforeSeconds): every live
---            contract, at most RestartMaxHoldMinutes. Its start is kept in the
---            resource's KVP, so the start after the restart gives its time
---            back.
---   app      staff stop the whole app for an event (Config.Holds.AppPaused,
---            a switch under Features): every live contract, and nothing is
---            placed or accepted. Its start is kept by the store
---            (Storage.writeStaffMeta 'staff_pause_since').
---   presence nobody's absence: the deadline also stops while the placer,
---            the target (or a target in prison, PauseWhileTargetJailed) or
---            every operative is away. That judgement is the expiry pass's
---            own (server/main.lua, registered here with Holds.presence),
---            and Holds.clockMayRun asks it with the three above.
---
--- One API asks it: Holds.on (is this contract held, by which kinds),
--- Holds.since (since when), Holds.why and Holds.shown (what a player, a
--- stranger or a staff member may be told of why). Every clock consults it:
--- the deadline and lifetime (the expiry pass), the idle release, the
--- amendment proposals, the tips' and go-dark windows, decay, disposal, the
--- handover confirm and the kills pending a photo.
---
--- The clocks: the deadline stops the way a party logging off stops it
--- (Storage.startPause), and is banked when the hold ends (Storage.endPause,
--- by the expiry pass, which runs it again only once nothing at all stops
--- it). The lifetime runs through every other pause, so the time a hold
--- took is given back to it when it ends, by one give-back routine
--- (giveBack): never twice for a span another hold still on covers, which
--- that hold gives back at its own end. Every release goes one way
--- (release): the hold let go before the first await, and the expiry pass
--- leaves every contract alone until its time is all given back
--- (Holds.releasing).
---
--- Anonymity: nothing here says which party is frozen. The frozen player is
--- told their contracts are on hold; every other party of each contract is
--- told that contract is, in the same words whoever caused it; a card says
--- On hold and nothing else. A stranger is told only of the holds that stop
--- every contract alike (restart, app, freezes unread); staff are shown
--- which party only where they may see it (Holds.shown).

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')
local Text = CrimsonBoot.requireShared('text')
local Lock = CrimsonBoot.require('server.lib.lock')
local Db = CrimsonBoot.require('server.lib.db')
local L = CrimsonBoot.requireShared('locale').t

local Holds = {}

local Storage, Audit, Notify, Kidnap, Death

-- ============================================================================
--                              STATE
-- ============================================================================

local frozen = {}   -- [cid] = { cid, name, reason, by_cid, frozen_at }
--- How many are frozen: always counted from `frozen` (recount), never kept
--- as a running sum two interleaved requests could each move.
local count = 0
--- One freeze or release per player at a time, keyed by cid: another for
--- the same player while one is in flight is refused as busy, never run
--- alongside it. Each awaits the store, and a second one let in meanwhile
--- read the first's stale state.
local PlayerLock = Lock.new()

--- The restart hold now, or nil: { since }. Kept in memory only, so
--- the resource starting again after the restart is what ends it.
local restartHold = nil
--- Where the restart hold's start is kept across the restart it is for.
local RESTART_KVP = 'crimson_hitman:restart_hold_since'

--- The app pause now, or nil: { since }. Kept by the store, so it holds
--- across a restart (Holds.syncAppPause).
local appPause = nil
local PAUSE_META = 'staff_pause_since'

--- Since when the store's freezes could not be read (os.time()), or nil.
--- Read as nobody frozen, a frozen player's contracts ran their clocks and
--- banked their deadlines, and the real unfreeze later gave the whole span
--- back again. So, until a read succeeds (tried again from the maintenance
--- tick, Holds.tick), every live contract is held as if a party to it were
--- frozen, without saying which, and the first read that succeeds gives
--- each the lifetime the outage took.
local unread = nil
--- The outage's retries: { failures, retryAt, saidAt }. Tried again after
--- a wait that doubles from UNREAD_FIRST_WAIT up to UNREAD_MAX_WAIT, and
--- said in the console the first time and then at most every
--- UNREAD_SAY_EVERY seconds: tried and said on every tick, a store down for
--- an evening filled the console and the alerts with one line.
local unreadRetry = nil
local UNREAD_FIRST_WAIT = 5
local UNREAD_MAX_WAIT = 300
local UNREAD_SAY_EVERY = 300

--- Releases still giving back what their hold took. Each lets go of its
--- hold before its first await (so a second one landing finds it gone and
--- gives nothing back twice), and gives each contract its time back after
--- it: an expiry pass run in between found no hold, and ended a contract
--- whose lifetime ran out while it was held, just before it was given that
--- time back. So the pass leaves every contract alone while one runs
--- (Holds.releasing).
local releasing = 0

--- The expiry pass's judgement of whether a contract's deadline stops for
--- somebody's absence (server/main.lua): fn(contract, hitmen) -> paused.
local presence = nil

--- The states a hold applies to. A contract mid-completion finishes as it
--- began: it is already being paid, and stopping there strands the money.
local LIVE = { [CH.STATE.ACTIVE] = true, [CH.STATE.ACCEPTED] = true }

--- What players are told. Plain, and never which party.
Holds.TEXT = {
    title        = L('holds.on_hold'),
    held         = L('holds.this_contract_is_on_hold_by'),
    released     = L('holds.this_contract_is_no_longer_on'),
    you          = L('holds.staff_have_put_your_contracts_on'),
    youReleased  = L('holds.your_contracts_are_no_longer_on'),
    restartTitle = L('holds.server_restart'),
    restart      = L('holds.contracts_are_paused_until_the_server'),
    restartOver  = L('holds.contracts_are_no_longer_paused_for'),
    pausedTitle  = L('holds.paused'),
    paused       = L('holds.contracts_are_paused_by_staff'),
    resumed      = L('holds.contracts_are_no_longer_paused'),
}

--- The kinds a contract is held by, as Holds.on / Holds.since take them.
--- `all`: it holds every live contract alike, so a stranger may be told of
--- it (it names nobody). `staff` covers the freezes that could not be read.
Holds.KINDS = {
    staff   = { all = false },
    restart = { all = true },
    app     = { all = true },
}
local EVERY = { 'restart', 'app', 'staff' }

local function recount()
    local n = 0
    for _ in pairs(frozen) do n = n + 1 end
    count = n
end

local function earliest(since, at)
    at = tonumber(at)
    if at and (not since or at < since) then return at end
    return since
end

-- ============================================================================
--                              IS IT HELD, SINCE WHEN
-- ============================================================================

--- The frozen parties of a live contract, or nil when no staff freeze holds
--- it: { { cid, row, role = 'target' | 'client' | 'operative' | 'unknown',
--- anonymous } }. Free while nobody is frozen; otherwise one read of its
--- operatives unless the caller has them.
---@param contract table|nil
---@param hitmen table[]|nil
---@return table[]|nil
function Holds.partiesOf(contract, hitmen)
    if unread and contract and LIVE[contract.state] then
        return { { cid = false, row = { frozen_at = unread }, role = 'unknown', anonymous = true } }
    end
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

--- When the earliest staff freeze holding a contract began, or nil.
local function staffSince(contract, hitmen)
    local parties = Holds.partiesOf(contract, hitmen)
    if not parties then return nil end
    local since
    for i = 1, #parties do since = earliest(since, parties[i].row.frozen_at) end
    return since
end

--- Whether the restart hold is on. Not once Config.Holds.RestartMaxHoldMinutes
--- has passed, even before the tick has released it.
local function restartOn()
    return restartHold ~= nil and os.time() < Holds.restartHoldEnds()
end

--- Since when a hold on every contract alike is on (os.time()), or nil:
--- 'restart' (not past its longest hold), 'app', or 'unread' (the store's
--- freezes could not be read).
---@param kind string
---@return integer|nil
function Holds.global(kind)
    if kind == 'restart' then return restartOn() and restartHold.since or nil end
    if kind == 'app' then return appPause and appPause.since or nil end
    if kind == 'unread' then return unread end
    return nil
end

--- The kinds asked for, as a list: nil for every kind, a name, or a list.
local function kindsOf(kinds)
    if kinds == nil then return EVERY end
    if type(kinds) == 'string' then return { kinds } end
    return kinds
end

--- Whether a contract is on hold, by any of `kinds` (nil: every kind;
--- 'staff' | 'restart' | 'app' or a list of them). A staff freeze holds
--- only a live contract (active or accepted); the restart hold and the app
--- pause hold every contract alike, so they are asked with no contract too.
--- The holds on every contract are asked first: they read nothing.
---@param contract table|nil
---@param hitmen table[]|nil its operatives, when the caller has them
---@param kinds string|string[]|nil
---@return boolean
function Holds.on(contract, hitmen, kinds)
    local list = kindsOf(kinds)
    for i = 1, #list do
        local kind = list[i]
        if kind ~= 'staff' and Holds.global(kind) then return true end
    end
    for i = 1, #list do
        if list[i] == 'staff' then return Holds.partiesOf(contract, hitmen) ~= nil end
    end
    return false
end

--- When the earliest of `kinds` holding a contract now began (os.time()),
--- or nil when none does. As Holds.on asks them.
---@param contract table|nil
---@param hitmen table[]|nil
---@param kinds string|string[]|nil
---@return integer|nil
function Holds.since(contract, hitmen, kinds)
    local list = kindsOf(kinds)
    local since
    for i = 1, #list do
        local kind = list[i]
        if kind == 'staff' then
            since = earliest(since, staffSince(contract, hitmen))
        else
            since = earliest(since, Holds.global(kind))
        end
    end
    return since
end

--- The freeze on a player, or nil.
---@param cid string|nil
---@return table|nil
function Holds.of(cid)
    if cid == nil or count == 0 then return nil end
    return frozen[cid]
end

--- How many are frozen, and whether that is unknown: while the store's
--- freezes cannot be read (`unread`) the count is 0 of nobody known, never
--- 0 frozen.
---@return integer count
---@return boolean unknown
function Holds.count() return count, unread ~= nil end

--- Every freeze, oldest first.
---@return table[]
function Holds.list()
    local out = {}
    for _, row in pairs(frozen) do out[#out + 1] = row end
    table.sort(out, function(a, b)
        if a.frozen_at ~= b.frozen_at then return a.frozen_at < b.frozen_at end
        return tostring(a.cid) < tostring(b.cid)
    end)
    return out
end

--- Whether a hold is being released now, its time not all given back yet.
---@return boolean
function Holds.releasing() return releasing > 0 end

--- Register the expiry pass's judgement of a contract's presence pause
--- (server/main.lua): fn(contract, hitmen) -> true when somebody's absence
--- (or a target in prison) stops its deadline.
---@param fn function|nil
function Holds.presence(fn) presence = fn end

--- Whether a contract's deadline may run now: no hold of any kind on it,
--- and nobody's absence stopping it (the expiry pass's own judgement).
--- Asked by an unfreeze, which banks a hold's pause itself only where
--- nothing else would keep it stopped.
---@param contract table
---@return boolean
function Holds.clockMayRun(contract)
    if not contract then return true end
    if Holds.global('restart') or Holds.global('app') then return false end
    -- Its operatives read once, for the freeze and the presence both:
    -- asked without them, a freeze on anybody read the roster again.
    local hitmen = presence and (Storage.readHitmen(contract.id) or {}) or nil
    if Holds.partiesOf(contract, hitmen) then return false end
    if not presence then return true end
    local ok, paused = pcall(presence, contract, hitmen)
    return not ok or paused ~= true
end

-- ============================================================================
--                              WHO MAY SEE WHY
-- ============================================================================

--- What a player may be told of a contract's hold: nil when none, else
--- { since, staff }. `since` is what its time band stands still from
--- (Util.bandLeft), the one start the card (server/projection.lua) and the
--- stake's check at an acceptance both ask; `staff` is when a staff freeze
--- on it began, the card's On hold. A viewer who is not a party ('public')
--- is told only of the holds that stop every contract alike (the restart
--- hold, the app pause, freezes that could not be read), and never On hold:
--- a staff freeze on one of its parties stood the stranger's card still
--- too, and told them it was held.
---@param contract table|nil
---@param hitmen table[]|nil
---@param viewer 'party'|'public'
---@return table|nil
function Holds.why(contract, hitmen, viewer)
    if not (contract and LIVE[contract.state]) then return nil end
    local since, staff
    if viewer == 'public' then
        since = earliest(since, unread)
    else
        staff = staffSince(contract, hitmen)
        since = staff
    end
    since = earliest(since, Holds.global('restart'))
    since = earliest(since, Holds.global('app'))
    if not since then return nil end
    return { since = since, staff = staff }
end

--- Which of a contract's parties a staff member may be shown has put it on
--- hold: its frozen parties, each as their place on it, leaving out an
--- anonymous one for staff without IdentityAce. Empty is shown as not
--- frozen at all: a badge on a contract whose visible parties are none of
--- them frozen said that its anonymous party was the player just frozen.
---@param contract table|nil
---@param hitmen table[]|nil
---@param canIdentify boolean|nil
---@return string[]|nil places, nil when none may be shown
function Holds.shown(contract, hitmen, canIdentify)
    if not contract then return nil end
    -- Nobody frozen and the freezes read: nothing is on hold, and nothing
    -- is read to find that out.
    if count == 0 and not unread then return nil end
    if not LIVE[contract.state] then return nil end
    -- The roster read once, for the parties and their aliases both: read
    -- in partiesOf and then again here, a page of 28 rows with anybody
    -- frozen was 56 statements on mysql.
    if hitmen == nil and count > 0 then
        hitmen = Storage.readHitmen(contract.id) or {}
    end
    local parties = Holds.partiesOf(contract, hitmen)
    if not parties then return nil end
    local aliases = {}
    for _, hitman in ipairs(hitmen or {}) do
        aliases[hitman.hitman_cid] = hitman.alias
    end
    local out = {}
    for _, party in ipairs(parties) do
        if party.role == 'unknown' then
            -- The store's freezes could not be read: every live contract is
            -- held alike, through nobody. Said as that with IdentityAce, and
            -- to everybody else as held, which names nobody either.
            out[#out + 1] = canIdentify and L('holds.store_unreadable') or 'held'
        elseif canIdentify or not party.anonymous then
            out[#out + 1] = party.role == 'target' and L('holds.the_target')
                or party.role == 'client' and L('holds.the_placer')
                or (L('holds.operative')):format(tostring(aliases[party.cid] or '?'))
        end
    end
    table.sort(out)
    return #out > 0 and out or nil
end

-- ============================================================================
--                              GIVE-BACK AND RELEASE
-- ============================================================================

--- Give a contract's lifetime `back` seconds, added to the expiry in the
--- store's own statement (Storage.addToExpires). Read here and written back,
--- even under the contract's lock, the write put back whatever a staff
--- extension added in between: that lock is refused as busy rather than
--- waited for, so the extension ran beside it.
---
--- And the paid windows on it the same span (`from` to `from + back`): a
--- target's go-dark and the informant tips' show and wait
--- (server/intel/rules.lua, IntelRules.heldBack). Each ran on the wall clock
--- through the hold, and a window bought for 30 minutes was gone after a
--- 40-minute freeze.
---@param contractId string
---@param back integer seconds
---@param from integer|nil when the span given back began, os.time()
local function giveBack(contractId, back, from)
    if not back or back <= 0 then return end
    local live = false
    local ok, err = pcall(function()
        local fresh = Storage.readContract(contractId)
        if not fresh or not LIVE[fresh.state] then return end
        live = true
        if not fresh.expires_at then return end
        Storage.addToExpires(contractId, back)
    end)
    if not ok then
        Log.always(('contract %s: the lifetime a hold took could not be given back (%s)')
            :format(contractId, Util.dbError(err)))
    end
    if live and from then
        local tips = CrimsonBoot.require('server.intel.rules')
        if tips and tips.heldBack then
            local gave, why = pcall(tips.heldBack, contractId, from, from + back)
            if not gave then
                Log.always(('contract %s: the paid windows a hold took could not be given back (%s)')
                    :format(contractId, Util.dbError(why)))
            end
        end
    end
end

--- When the earliest hold still on a contract began, of every kind, as the
--- state stands (the restart hold until it is released, even past its
--- longest hold): what a released hold gives back up to, and no further,
--- since that hold gives the rest back at its own end. `staff` is the
--- staff freezes' start when the caller has it.
local function othersSince(contract, staff)
    if staff == nil then staff = staffSince(contract) end
    local since = staff or nil
    since = earliest(since, restartHold and restartHold.since or nil)
    since = earliest(since, appPause and appPause.since or nil)
    return since
end

--- The one give-back for a hold on every contract alike: each live
--- contract's lifetime the time it took, from its start (or the contract's
--- placing, if later) to `now`, never past the earliest hold still on it.
---@param since integer when the hold began
---@param now integer
local function giveBackLive(since, now)
    for _, contract in ipairs(Storage.liveContracts() or {}) do
        if LIVE[contract.state] and contract.expires_at then
            local from = math.max(since, tonumber(contract.created_at) or since)
            local stop = math.min(now, othersSince(contract) or now)
            local back = stop - from
            if back > 0 then giveBack(contract.id, back, from) end
        end
    end
end

--- The one release path: run `fn` with the releasing guard up, so the
--- expiry pass leaves every contract alone until its time is given back.
local function release(fn, ...)
    releasing = releasing + 1
    local out = table.pack(pcall(fn, ...))
    releasing = releasing - 1
    if not out[1] then error(out[2], 0) end
    return table.unpack(out, 2, out.n)
end

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

--- Tell each of `cids` ([cid] = true) one notice and refresh their page.
local function tellEach(cids, title, text)
    for cid in pairs(cids) do
        Notify.toCitizen(cid, title, text, { bypassBudget = true })
        Notify.push(cid, 'hold')
    end
end

--- Stop a contract's deadline now, as a party logging off stops it. Not
--- one that has already gone with the clock running: that contract is late
--- already, and pausing it would give the time back.
local function stopClock(contract, now)
    local overdue = not contract.paused_since and contract.deadline_at ~= nil
        and now > contract.deadline_at
    if not contract.paused_since and not overdue then
        pcall(Storage.startPause, contract.id, now)
    end
end

--- Start a hold on every contract alike: each live one's deadline stops
--- now, and every party is told once (unless `quiet`). Returns the list.
local function holdEveryLive(now, title, text)
    local live = Storage.liveContracts() or {}
    for i = 1, #live do
        if LIVE[live[i].state] then stopClock(live[i], now) end
    end
    if title then tellEach(everyLiveParty(live), title, text) end
    return live
end

--- End a hold on every contract alike, whose state the caller has already
--- let go of (before its first await): each live contract's lifetime given
--- back the time it took (giveBackLive), every party told once (unless
--- `title` is nil), and the next expiry pass lets each clock nothing else
--- stops run again, banking the time on hold.
---@param what string the hold, for the console
local function endEveryLive(what, since, now, title, text)
    local gave, err = pcall(giveBackLive, since, now)
    if not gave then
        Log.always(('the lifetime the %s took could not be given back (%s)'):format(what, Util.dbError(err)))
    end
    if title then
        local ok, told = pcall(function() return everyLiveParty(Storage.liveContracts() or {}) end)
        tellEach(ok and told or {}, title, text)
    end
    if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
end

-- ============================================================================
--                              STAFF FREEZES
-- ============================================================================

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
--- whoever caused it (Notify.parties). The target only once they are shown
--- the contract.
local function isFrozen(cid) return frozen[cid] ~= nil end
local function tellParties(contract, text, skip)
    Notify.parties(contract, Holds.TEXT.title, text, 'hold', { skip = skip, except = isFrozen })
end

--- Freeze a player. Every live contract they are party to goes on hold now.
---@param staffCid string|nil who froze them, for the audit row
---@param cid string the player
---@param reason string|nil
---@param name string|nil how staff know them, for the list
---@return boolean ok
---@return string|nil err 'already_frozen' | CH.ERR.SERVER_ERROR
local freezeUnlocked
function Holds.freeze(staffCid, cid, reason, name)
    if type(cid) ~= 'string' or cid == '' then return false, CH.ERR.INVALID_INPUT end
    return PlayerLock.run(cid, freezeUnlocked, staffCid, cid, reason, name)
end

freezeUnlocked = function(staffCid, cid, reason, name)
    if frozen[cid] then return false, 'already_frozen' end
    reason = Text.reason(reason)
    local now = os.time()

    -- Which of their contracts were on hold already, through somebody else:
    -- their parties were told then, and are not told again.
    local contracts = liveOf(cid)
    local already = {}
    for i = 1, #contracts do already[contracts[i].id] = Holds.on(contracts[i], nil, 'staff') end

    local row = { cid = cid, name = Util.sanitizeText(name, 128),
                  reason = reason, by_cid = staffCid, frozen_at = now }
    if not Db.try('a staff freeze could not be written (%s); nothing was put on hold',
        Storage.writeFreeze, row) then
        return false, CH.ERR.SERVER_ERROR
    end
    frozen[cid] = row
    recount()

    for i = 1, #contracts do
        local contract = contracts[i]
        stopClock(contract, now)
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

    Notify.toCitizen(cid, Holds.TEXT.title, Holds.TEXT.you, { bypassBudget = true })
    Notify.push(cid, 'hold')
    for i = 1, #contracts do
        if not already[contracts[i].id] then tellParties(contracts[i], Holds.TEXT.held) end
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
function Holds.unfreeze(staffCid, cid, reason)
    if type(cid) ~= 'string' then return false, 'not_frozen' end
    return PlayerLock.run(cid, release, unfreezeUnlocked, staffCid, cid, reason)
end

unfreezeUnlocked = function(staffCid, cid, reason)
    local row = frozen[cid]
    if not row then return false, 'not_frozen' end
    reason = Text.reason(reason)
    local now = os.time()

    if not Db.try('a staff freeze could not be removed (%s); the player stays on hold',
        Storage.deleteFreeze, cid) then
        return false, CH.ERR.SERVER_ERROR
    end
    frozen[cid] = nil
    recount()

    local released = {}
    for _, contract in ipairs(liveOf(cid)) do
        local others = staffSince(contract)
        -- The part of this player's hold no other hold still covers: all of
        -- it when nobody else holds the contract, and otherwise only what
        -- came before the earliest one left, which is given back with that.
        -- Never past the restart hold's or the app pause's start while it
        -- is on: its release gives back what it covers, and once is enough.
        local stop = othersSince(contract, others or false) or now
        local back = math.max(0, stop - row.frozen_at)
        if back > 0 and contract.expires_at then giveBack(contract.id, back, row.frozen_at) end
        -- And every open amendment proposal on it the time this freeze held
        -- it: none could be answered while it was held, and none ran out
        -- meanwhile (Amendments.expire), so each is given the hold back to
        -- be answered. Only a staff freeze holds a proposal: one can be
        -- answered, and runs out, under the restart hold and the app pause,
        -- and neither end gives one anything. So the time is this freeze's
        -- up to the earliest other freeze still on it (which gives the rest
        -- back at its own release), never cut at the restart hold's or the
        -- app pause's start: cut there, a freeze inside the app pause gave
        -- nothing back, and a proposal due meanwhile ran out the moment it
        -- ended.
        local held = math.max(0, (others or now) - row.frozen_at)
        if held > 0 and Storage.readOpenAmendments and Storage.writeAmendment then
            pcall(function()
                for _, proposal in ipairs(Storage.readOpenAmendments(contract.id) or {}) do
                    if proposal.expires_at then
                        proposal.expires_at = (tonumber(proposal.expires_at) or now) + held
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
            if since and Holds.clockMayRun(contract) then
                pcall(Storage.endPause, contract.id, since, math.max(0, now - since))
            end
            released[#released + 1] = contract
        end
    end

    Audit.staff('unfreeze_player', staffCid, nil, { subject = cid, reason = reason })
    Audit.flush()

    Notify.toCitizen(cid, Holds.TEXT.title, Holds.TEXT.youReleased, { bypassBudget = true })
    Notify.push(cid, 'hold')
    for i = 1, #released do tellParties(released[i], Holds.TEXT.released, cid) end
    -- A party away now starts the presence pause again on the next pass.
    if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

--- Read every freeze from the store again. Done at the start, and again
--- from the tick while the start's read failed.
---@return boolean read
function Holds.reload()
    frozen, count = {}, 0
    if not (Storage and Storage.readFreezes) then
        unread, unreadRetry = nil, nil
        return true
    end
    local ok, rows = pcall(Storage.readFreezes)
    local now = os.time()
    if not ok then
        unread = unread or now
        local retry = unreadRetry or { failures = 0 }
        unreadRetry = retry
        retry.failures = retry.failures + 1
        local wait = math.min(UNREAD_MAX_WAIT, UNREAD_FIRST_WAIT * 2 ^ math.min(16, retry.failures - 1))
        retry.retryAt = now + math.floor(wait)
        if not retry.saidAt or now - retry.saidAt >= UNREAD_SAY_EVERY then
            retry.saidAt = now
            Log.always(('staff freezes could not be read from the store (%s); every live contract is '
                .. 'held until they can be (tried %d time(s) since %s, next in %d second(s))')
                :format(Util.dbError(rows), retry.failures, os.date('%H:%M:%S', unread), math.floor(wait)))
        end
        return false
    end
    for _, row in ipairs(rows or {}) do
        if row.cid then
            row.frozen_at = tonumber(row.frozen_at) or now
            frozen[row.cid] = row
        end
    end
    recount()
    local since = unread
    if since then
        -- Let go of the outage's hold before the first await, under the
        -- release guard, and give each contract back what it took.
        unread, unreadRetry = nil, nil
        local gave, err = pcall(release, giveBackLive, since, now)
        if not gave then
            Log.always(('the lifetime the unreadable freezes took could not be given back (%s)')
                :format(Util.dbError(err)))
        end
        Log.always('staff freezes have been read from the store: contracts nobody frozen is party to '
            .. 'run again, with the time they were held given back')
        if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
        if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    end
    return true
end

-- ============================================================================
--                              THE RESTART HOLD
-- ============================================================================

--- When the restart hold ends if the restart has not come: its start and
--- Config.Holds.RestartMaxHoldMinutes as it is set now. nil with no hold.
---@return integer|nil
function Holds.restartHoldEnds()
    if not restartHold then return nil end
    local block = Config.Holds
    local minutes = math.max(1, tonumber(block and block.RestartMaxHoldMinutes) or 45)
    return restartHold.since + minutes * 60
end

--- txAdmin's 'txAdmin:events:scheduledRestart' ({ secondsRemaining }), sent
--- 30, 15, 10, 5, 4, 3, 2 and 1 minutes before a scheduled restart. The
--- first one inside Config.Holds.RestartPauseBeforeSeconds starts the hold
--- on every live contract: its deadline stops (the pause every contract
--- has), and nothing ends it, pays out a queued buyout or finishes a
--- handover until the hold ends. The ones after it change nothing.
---@param data table|nil
---@return boolean started
function Holds.scheduledRestart(data)
    local seconds = type(data) == 'table' and tonumber(data.secondsRemaining) or nil
    if not seconds then return false end
    local block = Config.Holds
    local within = tonumber(block and block.RestartPauseBeforeSeconds) or 0
    if within <= 0 or seconds > within then return false end
    if restartOn() then return false end
    -- A hold past RestartMaxHoldMinutes that the tick has not released yet is
    -- released first, giving back the time it took: the new one taking its
    -- place lost that span.
    if restartHold then Holds.releaseRestart('max_hold', true) end

    local now = os.time()
    restartHold = { since = now }
    pcall(SetResourceKvpInt, RESTART_KVP, now)
    local hold = Holds.restartHoldEnds() - now
    holdEveryLive(now, Holds.TEXT.restartTitle, Holds.TEXT.restart)
    Log.always(('a scheduled restart is %d second(s) away: every live contract is paused until '
        .. 'the restart, for at most %d minute(s)'):format(seconds, hold // 60))
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

--- End the restart hold without a restart: txAdmin's skip, or
--- RestartMaxHoldMinutes passing.
---@param why string 'skipped' | 'max_hold'
---@param quiet boolean|nil a new hold takes its place at once, and says so itself
---@return boolean released
local releaseRestartNow
function Holds.releaseRestart(why, quiet)
    if not restartHold then return false end
    return release(releaseRestartNow, why, quiet)
end

releaseRestartNow = function(why, quiet)
    local since = restartHold.since
    local now = os.time()
    restartHold = nil
    -- A kill made before the hold waited for its Verify through it
    -- (Death.carryOverRestartHold): the time it had left is given back.
    -- At once, before the first await: a death sweep landing in the
    -- give-back below found no hold and dropped every such kill.
    if Death and Death.carryOverRestartHold then
        local carried, carryErr = pcall(Death.carryOverRestartHold, since, now)
        if not carried then
            Log.always(('the kills waiting through the restart hold could not be kept (%s)')
                :format(tostring(carryErr)))
        end
    end
    pcall(DeleteResourceKvp, RESTART_KVP)
    -- Everybody told at the start is told it is over: open pages kept
    -- "paused for the server restart" and its buttons off until the player
    -- went elsewhere. Not when a new hold takes its place at once.
    endEveryLive(L('holds.restart_hold'), since, now,
        not quiet and Holds.TEXT.restartTitle or nil, Holds.TEXT.restartOver)
    Log.always(('the restart hold on contracts has ended (%s): their clocks run again where '
        .. 'nothing else stops them'):format(tostring(why)))
    return true
end

-- ============================================================================
--                              THE APP PAUSE (Config.Holds.AppPaused)
-- ============================================================================

--- What the store kept of a pause from before this start.
local function loadAppPause()
    appPause = nil
    if not (Storage and Storage.readStaffMeta) then return end
    local ok, meta = Db.try('the app pause could not be read from the store (%s)', Storage.readStaffMeta)
    if not ok then return end
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
    Db.try('the app pause could not be kept by the store (%s); it is on until the next start',
        Storage.writeStaffMeta, PAUSE_META, now)
    holdEveryLive(now, Holds.TEXT.pausedTitle, Holds.TEXT.paused)
    Log.always('staff paused the app: no contract is placed or accepted, and every live '
        .. 'contract\'s clocks are held until it is switched off (Holds.AppPaused)')
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
    Db.try('the end of the app pause could not be kept by the store (%s)', Storage.writeStaffMeta, PAUSE_META, 0)
    endEveryLive(L('holds.app_pause'), since, now, Holds.TEXT.pausedTitle, Holds.TEXT.resumed)
    Log.always('staff ended the app pause: contracts run again where nothing else stops them')
end

--- Bring the pause in line with its switch (Config.Holds.AppPaused): run
--- when the setting changes (Settings.watch), at the start, and on every
--- maintenance tick for a change made any other way.
---@return string|nil what 'paused' | 'resumed', or nil when nothing changed
function Holds.syncAppPause()
    if not Storage then return nil end
    local want = type(Config.Holds) == 'table' and Config.Holds.AppPaused == true
    if want and not appPause then
        startAppPause()
        return 'paused'
    end
    if not want and appPause then
        release(endAppPause)
        return 'resumed'
    end
    return nil
end

-- ============================================================================
--                              START AND TICK
-- ============================================================================

---@param deps table { storage, audit, notify, kidnap, death }
function Holds.init(deps)
    Storage, Audit, Notify, Kidnap, Death = deps.storage, deps.audit, deps.notify, deps.kidnap, deps.death
    -- A restart hold ends with the restart: this start is it.
    restartHold = nil
    -- The presence judgement is the expiry pass's, registered after this.
    presence = nil
    PlayerLock.reset()
    unread, unreadRetry = nil, nil
    Holds.reload()
    -- An app pause from before the restart is still on: read before the
    -- restart hold's lifetime is given back, which leaves out what it covers.
    loadAppPause()
    -- And the lifetime the hold and the restart took is given back, once.
    local ok, since = pcall(GetResourceKvpInt, RESTART_KVP)
    since = ok and tonumber(since) or 0
    if since > 0 then
        pcall(DeleteResourceKvp, RESTART_KVP)
        local gave, err = pcall(giveBackLive, since, os.time())
        if not gave then
            Log.always(('the lifetime the restart hold took could not be given back (%s)')
                :format(Util.dbError(err)))
        end
    end
    -- And the switch as it is now (a config.lua edit while it was down).
    local synced, syncErr = pcall(Holds.syncAppPause)
    if not synced then
        Log.always(('the app pause could not be brought in line with its switch (%s)')
            :format(Util.dbError(syncErr)))
    end
end

--- From the maintenance tick: the freezes the start could not read, tried
--- again after the outage's wait (never on every tick), and a restart hold
--- the restart never came for, ended at RestartMaxHoldMinutes.
function Holds.tick()
    if unread and (not unreadRetry or os.time() >= (unreadRetry.retryAt or 0)) then pcall(Holds.reload) end
    if restartHold and os.time() >= Holds.restartHoldEnds() then Holds.releaseRestart('max_hold') end
end

return Holds
