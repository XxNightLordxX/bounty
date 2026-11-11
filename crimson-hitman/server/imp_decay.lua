--- Contract decay (Config.Improvements.ContractDecay, README, Optional
--- features). Off as shipped.
---
--- A contract nobody has taken yet (state 'active') changes every Hours it
--- waits, one step at a time, by Mode:
---   * 'rise': its reward goes up by Percent of the money it held at the
---     first step, never past MaxIncreasePercent of that in all. Each step
---     is charged to its placer from Account, through the placer's own
---     add-to-reward path (Amendments.addEscrow): the same checks, the same
---     escrow, charged last and audited, so nothing is made or lost. A step
---     waits while the placer is away (nobody can be charged who is not in
---     the city), and a refusal (they cannot pay, or a ceiling) stops the
---     rise on that contract for good, and they are told. Only a contract
---     placed under the placer's own name rises: a step that waits for its
---     placer to come back, then lands on the board, would tell anybody
---     watching the reward when an anonymous placer logged in, so an
---     anonymous contract never rises (its card says so).
---   * 'shorten': its deadline is brought in by Percent of the time it has
---     left (Contracts.bringDeadlineIn, never closer than the clock allows;
---     stopped once it is that close). Nothing is charged.
--- The placer is told at each step, their card says what it does and what
--- it has added, and they can turn it off for that contract (decayOff).
--- What each contract has had is kept in the store (crimson_rp_rows, kind
--- 'imp_decay'), so a restart neither repeats a step nor forgets an
--- opt-out. A contract already older than a step when it is first seen
--- (one placed before this was turned on) starts its count then, rather
--- than being stepped at once.
---
--- Only time spent waiting counts: while staff hold it (a freeze, the
--- restart hold, the app pause) or an operative holds it, its count stands
--- still (held_since on its row), and the time is added back when it is
--- untaken and free again, so no step falls due the moment a hold ends.
--- And while decay itself is switched off (off_since on its row): the
--- stretch it was off for is added back when it is switched on again, so
--- turning it off and on charges nothing for the time between. A contract
--- placed while it was off counts from when it went on (OnSince), not from
--- when it was placed: its first step falls a whole step of decay being on
--- after that, never sooner.

local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local Words = CrimsonBoot.requireShared('words')
local Feature = CrimsonBoot.require('server.lib.feature')
local L = CrimsonBoot.requireShared('locale').t

--- This feature's block of config (server/lib/feature.lua reads it).
local BLOCK = 'Improvements.ContractDecay'

local Decay = {}

local Storage, Identity, Notify, Audit, Escrow, Contracts, Amendments, Projection

local KIND = 'imp_decay'

--- The most steps one pass takes. Every untaken contract placed in the same
--- hour falls due on the same pass, and each 'rise' step is a charge with
--- its escrow, ledger and notice: a hundred of them were 1,951 statements
--- and a second of one frame on mysql in the harness. The rest wait for the
--- passes after, a minute apart; a step is counted in hours.
Decay.STEPS_PER_PASS = 25

--- The most rows of ended contracts one pass forgets while decay is off
--- (Decay.tick). Each is a contract read and a delete.
Decay.PRUNES_PER_PASS = 25

--- When the next pass has anything to do, os.time(): the soonest step due,
--- and never later than one step from the last pass, so a contract placed
--- while it sleeps is seen before its first step can fall due. 0: now.
local nextAt = 0
--- The Hours that nextAt was worked out with: a change wakes the next pass.
local nextHours = nil

--- [contractId] = row { id, kind, contract_id, steps, added, base, last_at, off, stopped,
---                      held_since, off_since }
local rows = {}

--- When decay last went on, os.time(), as this process saw it or the store
--- kept it (the ON_KIND row); nil where it has been on since before any of
--- that. And whether it has been seen off since, so the next pass that
--- finds it on records the moment.
local OnSince = nil
local SeenOff = false
local ON_KIND = 'imp_decay_on'

local num = Util.num

local function write(row)
    rows[row.contract_id] = row
    local ok, err = pcall(Storage.writeRpRow, row)
    if not ok then error(err, 0) end
end

local function forget(contractId)
    if not rows[contractId] then return end
    rows[contractId] = nil
    pcall(Storage.deleteRpRow, KIND .. ':' .. contractId)
end

--- The row for a contract, made the first time it is seen.
local function rowFor(contract, now, hours)
    local row = rows[contract.id]
    if row then return row end
    local created = math.floor(num(contract.created_at, now))
    -- Placed while decay was off: counted from when it went on. Only the
    -- time it waited with decay on counts toward a step.
    local from = math.max(created, math.floor(num(OnSince, created)))
    row = { id = KIND .. ':' .. contract.id, kind = KIND, contract_id = contract.id,
            steps = 0, added = 0,
            last_at = (now - created) < hours * 3600 and math.min(from, now) or now }
    write(row)
    return row
end

--- Whether a contract was placed anonymously.
local function anonymous(contract)
    return contract.anon_creator ~= nil and contract.anon_creator ~= false and contract.anon_creator ~= 0
end

--- When whatever holds this contract now began (a staff freeze, the
--- restart hold, the app pause), or nil when nothing does.
local function heldSince(contract, hitmen, now)
    local since = Holds.since(contract, hitmen)
    if not since then return nil end
    return math.min(since, now)
end

--- When a taken contract was taken: the earliest acceptance among its
--- active operatives (the snapshot's rosters, else read), or now.
local function takenSince(contract, rosters, now)
    local roster = rosters and rosters[contract.id] or Storage.readHitmen(contract.id) or {}
    local since = now
    for _, h in ipairs(roster) do
        if h.state == 'active' and tonumber(h.accepted_at) then
            since = math.min(since, tonumber(h.accepted_at))
        end
    end
    return since
end

--- The count stands still from `since` (never before the count's own start).
local function pauseRow(row, since)
    if row.held_since then return end
    row.held_since = math.max(since, num(row.last_at, since))
    write(row)
end

--- When an untaken contract last stopped being held by an operative: the
--- latest an operative on it left, or nil when none left (the roster from
--- the snapshot, else read).
local function untakenSince(contract, rosters)
    local roster = rosters and rosters[contract.id] or Storage.readHitmen(contract.id) or {}
    local at
    for _, h in ipairs(roster) do
        local left = tonumber(h.left_at)
        if h.state ~= 'active' and left and (not at or left > at) then at = left end
    end
    return at
end

--- A held, untaken contract whose count already stands still: if it stood
--- still from a taking (an operative left after it began), the stretch it
--- has been untaken since, up to the hold's start, is waiting time and is
--- counted. The count then stands still from the hold's start. Kept from
--- the taking, the hold's release gave the whole span back as held, and
--- the untaken minutes between the walk-away and the freeze were lost.
local function holdAfterTaking(row, contract, rosters, since)
    local from = num(row.held_since, since)
    if since <= from then return end
    local left = untakenSince(contract, rosters)
    if not left or left <= from then return end
    local untaken = math.min(left, since)
    row.last_at = num(row.last_at, from) + (untaken - from)
    row.held_since = since
    write(row)
end

--- And runs again: the time it stood still is added to its start.
local function resumeRow(row, now)
    local since = row.held_since
    if not since then return end
    row.held_since = nil
    row.last_at = num(row.last_at, now) + math.max(0, now - num(since, now))
    write(row)
end

--- Stop the rise on a contract for good, and tell its placer why.
local function stop(row, contract, why, text)
    row.stopped = why
    write(row)
    Notify.toCitizen(contract.creator_cid, L('imp_decay.contract_reward'), text)
    Audit.action('imp_decay_stopped', contract.creator_cid, contract.id, { why = why })
end

--- One 'rise' step on one contract.
local function rise(cfg, row, contract, now)
    local base = row.base
    if not base then
        base = math.floor(num(Escrow.moneyValue(contract.id)))
        row.base = base
    end
    local cap = math.floor(base * num(cfg.MaxIncreasePercent) / 100)
    local amount = math.min(math.floor(base * num(cfg.Percent) / 100), cap - (row.added or 0))
    if amount <= 0 then
        return stop(row, contract, 'cap', L('imp_decay.your_untaken_contracts_reward_has_risen'))
    end
    -- Only a placer in the city can be charged; the step waits for them.
    local placer = Identity.byCitizenId(contract.creator_cid)
    if not placer then return end
    -- Still untaken, read again just before: the tick's list was read
    -- before every await since.
    local fresh = Storage.readContract(contract.id)
    if not fresh or fresh.state ~= CH.STATE.ACTIVE then return end
    local account = cfg.Account == 'cash' and 'cash' or 'bank'
    -- Written first, put back if the charge does not go through.
    local before = { added = row.added, steps = row.steps, last_at = row.last_at }
    -- What the contract held before the step, so a top-up that raised can
    -- be told from one that never went in (below).
    local readValue, valueBefore = pcall(Escrow.moneyValue, contract.id)
    valueBefore = readValue and tonumber(valueBefore) or nil
    row.added, row.steps, row.last_at = (row.added or 0) + amount, (row.steps or 0) + 1, now
    write(row)
    local ran, ok, err = pcall(Amendments.addEscrow, placer, contract.id,
        { baseline = { [account] = amount } }, { onlyActive = true })
    -- Raised after the charge landed: the money is in the contract, so the
    -- step counts. Put back, the next step charged again and the rise went
    -- past MaxIncreasePercent. Put back only where the escrow shows it did
    -- not go in; kept where that cannot be read either.
    if not ran then
        local readAfter, valueAfter = pcall(Escrow.moneyValue, contract.id)
        valueAfter = readAfter and tonumber(valueAfter) or nil
        if not valueBefore or not valueAfter or valueAfter >= valueBefore + amount then
            Audit.financial('imp_decay_rose', contract.creator_cid, contract.id,
                { amount = amount, account = account, step = row.steps, added = row.added,
                  raised = tostring(ok), unread = (not valueBefore or not valueAfter) or nil })
            error(ok, 0)
        end
    end
    if ran and ok then
        Notify.toCitizen(contract.creator_cid, L('imp_decay.contract_reward'),
            (L('imp_decay.nobody_has_taken_your_contract_yet'))
                :format(Words.dollars(amount), account))
        Audit.financial('imp_decay_rose', contract.creator_cid, contract.id,
            { amount = amount, account = account, step = row.steps, added = row.added })
        return
    end
    row.added, row.steps, row.last_at = before.added, before.steps, before.last_at
    if not ran then
        write(row)
        error(ok, 0)
    end
    -- Busy (a claim or another change on it): tried again next step.
    if err == CH.ERR.BUSY or err == CH.ERR.LOCKED then
        row.last_at = now
        return write(row)
    end
    -- On hold (a freeze, the restart hold or the app pause landed in the
    -- awaits): not the placer's doing, so nothing stops. The count stands
    -- still with the hold (Decay.tick) and the step is taken after it.
    if err == CH.ERR.CONTRACT_FROZEN or err == CH.ERR.RESTART_HOLD or err == CH.ERR.APP_PAUSED then
        return write(row)
    end
    -- Ended or taken since it was read: nothing to do.
    if err == CH.ERR.BAD_STATE or err == CH.ERR.NOT_FOUND then return write(row) end
    stop(row, contract, tostring(err),
        (L('imp_decay.your_untaken_contracts_reward_could_not')):format(Words.dollars(amount), account))
end

--- One 'shorten' step on one contract.
local function shorten(cfg, row, contract, now)
    if not contract.deadline_at then return end
    local percent = num(cfg.Percent)
    local moved, err = Contracts.bringDeadlineIn(contract.id, function(current)
        local from = current.paused_since or os.time()
        local left = (current.deadline_at or from) - from
        if left <= 0 then return current.deadline_at end
        return current.deadline_at - math.floor(left * percent / 100)
    end)
    if not moved then
        if err == CH.ERR.INVALID_INPUT then
            return stop(row, contract, 'shortest',
                L('imp_decay.nobody_has_taken_your_contract_and'))
        end
        row.last_at = now
        return write(row)
    end
    row.steps, row.last_at = (row.steps or 0) + 1, now
    write(row)
    Notify.toCitizen(contract.creator_cid, L('imp_decay.contract_time'),
        L('imp_decay.nobody_has_taken_your_contract_yet_2'))
    Audit.action('imp_decay_shortened', contract.creator_cid, contract.id, { step = row.steps })
end

--- While decay is off: the rows of contracts that have ended forgotten, at
--- most PRUNES_PER_PASS a pass. Nothing else forgot them while it was off,
--- so every contract that had a row kept it for good. A contract still
--- running keeps its row (turned on again, its count and its opt-out are
--- where they were), and so does one being paid, as below. Nothing is read
--- while no row is kept.
local function pruneWhileOff()
    if next(rows) == nil then return end
    local live = {}
    local list = Projection and Projection.liveSnapshot and Projection.liveSnapshot()
        or Storage.liveContracts() or {}
    for _, contract in ipairs(list) do live[contract.id] = true end
    local ended = {}
    for id in pairs(rows) do
        if not live[id] then ended[#ended + 1] = id end
    end
    table.sort(ended)
    local done = 0
    for i = 1, #ended do
        if done >= Decay.PRUNES_PER_PASS then break end
        local read, contract = pcall(Storage.readContract, ended[i])
        if read and not (contract and contract.state == CH.STATE.COMPLETING) then
            forget(ended[i])
            done = done + 1
        end
    end
end

--- While decay is off: every kept row marked with when it was switched off
--- (off_since), once, so the stretch it was off for is never counted as
--- waiting time. Kept by the store, so a restart while it is off loses
--- none of it. Nothing written while no row is kept, or every row is
--- marked already.
local function markOff(now)
    for _, row in pairs(rows) do
        if not row.off_since then
            row.off_since = now
            pcall(write, row)
        end
    end
end

--- Switched on again: each row marked off stood still from when it did
--- (or from the hold or taking it already stood still from, the earlier),
--- and that whole stretch is added to its start, as a hold's release adds
--- one (resumeRow). Its count then stands still from now, as if held, and
--- the pass below runs it on again only where nothing holds the contract
--- and nobody has taken it: a contract switched back on while taken waits
--- for the walk-away, and none of the time it was off, taken or held is
--- counted. Charged at once, the placer paid for hours of nobody waiting.
---
--- Each change is stored before it is kept: a row cleared in memory before
--- a write that failed lost its mark, while the store still had it. Where a
--- write fails the row stays marked, nothing more is done this pass
--- (false), and the next pass tries again.
---@return boolean stored
local function markOn(now)
    for id, row in pairs(rows) do
        local off = row.off_since
        if off then
            local from = math.min(num(row.held_since, off), num(off, now))
            local changed = Util.copy(row)
            changed.off_since = nil
            changed.last_at = num(row.last_at, from) + math.max(0, now - from)
            changed.held_since = now
            local ok, err = pcall(Storage.writeRpRow, changed)
            if not ok or err == false then return false end
            rows[id] = changed
        end
    end
    return true
end

--- The tick (once a minute, on a tick of its own): one step on each
--- untaken contract that is due one, at most STEPS_PER_PASS a pass, and the
--- rows of contracts that ended forgotten. The steps sleep until the
--- soonest is due; what is running comes from the snapshot the other loops
--- share (Projection.liveSnapshot), so a pass with no step due and no row
--- kept reads nothing, and one with rows kept reads nothing new while
--- nothing was written.
---@return integer stepped
function Decay.tick()
    local cfg = Feature.active(BLOCK)
    if not cfg then
        nextAt = 0
        SeenOff = true
        pruneWhileOff()
        markOff(os.time())
        return 0
    end
    local now = os.time()
    if SeenOff then
        -- On again: contracts first seen from now count from now. Kept in
        -- the store, once a switch, so a restart counts from it too.
        SeenOff, OnSince = false, now
        pcall(Storage.writeRpRow, { id = ON_KIND, kind = ON_KIND, on_since = now })
    end
    if not markOn(now) then return 0 end
    local hours = math.max(1, num(cfg.Hours, 1))
    if hours ~= nextHours then nextAt, nextHours = 0, hours end
    local stepping = now >= nextAt
    if not stepping and next(rows) == nil then return 0 end
    local every = hours * 3600
    local soonest, stepped, more = now + every, 0, false
    local list, rosters
    if Projection and Projection.liveSnapshot then
        list, rosters = Projection.liveSnapshot()
    else
        list = Storage.liveContracts()
    end
    local rising = cfg.Mode ~= 'shorten'
    local live = {}
    for _, contract in ipairs(list or {}) do
        live[contract.id] = true
        -- Never risen for an anonymous placer: see the top of this file.
        local skip = rising and anonymous(contract)
        local active = contract.state == CH.STATE.ACTIVE
        local kept = rows[contract.id]
        local since = nil
        if not skip and active and (stepping or kept) then
            since = heldSince(contract, rosters and rosters[contract.id], now)
        end
        if skip or not active then
            -- Taken: its count stands still from the acceptance.
            if not skip and kept and not kept.held_since then
                pauseRow(kept, takenSince(contract, rosters, now))
            end
        elseif since then
            -- Held: no step, its count stands still from the hold's start,
            -- and it is looked at again on the next pass. One already
            -- standing still from a taking counts the untaken time between
            -- the walk-away and this hold first.
            local row = kept or rowFor(contract, now, hours)
            if row.held_since then
                holdAfterTaking(row, contract, rosters, since)
            else
                pauseRow(row, since)
            end
            soonest = now
        elseif kept and kept.held_since then
            -- Free and untaken again: the count runs on from where it stood.
            resumeRow(kept, now)
            nextAt = math.min(nextAt, num(kept.last_at, now) + every)
        end
        if stepping and active and not skip and not since then
            local row = rowFor(contract, now, hours)
            if not row.off and not row.stopped then
                local dueAt = num(row.last_at, now) + every
                if now < dueAt then
                    soonest = math.min(soonest, dueAt)
                elseif stepped >= Decay.STEPS_PER_PASS then
                    more = true
                else
                    stepped = stepped + 1
                    if cfg.Mode == 'shorten' then
                        shorten(cfg, row, contract, now)
                    else
                        rise(cfg, row, contract, now)
                    end
                    -- One that waited (its placer away) is due again on
                    -- the next pass; one taken, a step from now.
                    if not row.stopped then
                        soonest = math.min(soonest, num(row.last_at, now) + every)
                    end
                end
            end
        end
    end
    for id in pairs(rows) do
        -- Not one being paid: a completion that fails goes back to
        -- accepted, and forgotten it would start its count, and its
        -- rise's ceiling, again from nothing.
        if not live[id] then
            local read, contract = pcall(Storage.readContract, id)
            if not (read and contract and contract.state == CH.STATE.COMPLETING) then forget(id) end
        end
    end
    if stepping then nextAt = more and 0 or soonest end
    return stepped
end

--- What the placer's card says of it, or nil.
---@param contract table
---@return table|nil
function Decay.cardFor(contract)
    local cfg = Feature.active(BLOCK)
    if not cfg or type(contract) ~= 'table' then return nil end
    local row = rows[contract.id]
    if contract.state ~= CH.STATE.ACTIVE and not row then return nil end
    if cfg.Mode ~= 'shorten' and anonymous(contract) then
        -- Placed anonymously: it never rises, and the card says why.
        return { mode = 'rise', anonymous = true }
    end
    return {
        mode = cfg.Mode == 'shorten' and 'shorten' or 'rise',
        percent = math.floor(num(cfg.Percent)),
        hours = math.floor(num(cfg.Hours, 1)),
        maxPercent = math.floor(num(cfg.MaxIncreasePercent)),
        account = cfg.Account == 'cash' and 'cash' or 'bank',
        added = row and math.floor(num(row.added)) or 0,
        steps = row and math.floor(num(row.steps)) or 0,
        off = row and row.off == true or nil,
        stopped = row and row.stopped ~= nil or nil,
        taken = contract.state ~= CH.STATE.ACTIVE or nil,
    }
end

--- The placer turns it off for one contract of theirs (decayOff).
---@return boolean ok
---@return string|table err or the card's new decay
function Decay.turnOff(actor, contractId)
    if not Feature.active(BLOCK) then return false, CH.ERR.FEATURE_OFF end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end
    local contract = Storage.readContract(contractId)
    if not contract or contract.creator_cid ~= actor.cid then return false, CH.ERR.NOT_PARTICIPANT end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    local now = os.time()
    local row = rowFor(contract, now, math.max(1, num(Feature.active(BLOCK).Hours, 1)))
    if not row.off then
        row.off = true
        write(row)
        Audit.action('imp_decay_off', actor.cid, contract.id, {})
    end
    return true, nil, Decay.cardFor(contract)
end

function Decay.init(deps)
    Storage, Identity, Notify, Audit = deps.storage, deps.identity, deps.notify, deps.audit
    Escrow, Contracts, Amendments = deps.escrow, deps.contracts, deps.amendments
    Projection = deps.projection
    rows, nextAt, nextHours = {}, 0, nil
    OnSince, SeenOff = nil, Feature.active(BLOCK) == nil
    if Storage and Storage.readRpRows then
        local ok, kept = pcall(Storage.readRpRows, KIND)
        for _, row in ipairs(ok and type(kept) == 'table' and kept or {}) do
            if type(row.contract_id) == 'string' then rows[row.contract_id] = row end
        end
        local okOn, on = pcall(Storage.readRpRows, ON_KIND)
        for _, row in ipairs(okOn and type(on) == 'table' and on or {}) do
            if row.id == ON_KIND and tonumber(row.on_since) then OnSince = tonumber(row.on_since) end
        end
    end
    local projection = deps.projection
    if projection and projection.extenders then
        projection.extenders.impDecay = function(out, contract, _, role)
            if role == 'creator' then out.decay = Decay.cardFor(contract) end
        end
        projection.settingsExtenders.impDecay = function(settings)
            local cfg = Feature.active(BLOCK)
            if not cfg then return end
            settings.contractDecay = {
                mode = cfg.Mode == 'shorten' and 'shorten' or 'rise',
                percent = math.floor(num(cfg.Percent)),
                hours = math.floor(num(cfg.Hours, 1)),
                maxPercent = math.floor(num(cfg.MaxIncreasePercent)),
                account = cfg.Account == 'cash' and 'cash' or 'bank',
            }
        end
    end
end

return Decay
