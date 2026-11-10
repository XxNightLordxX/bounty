--- Target counterplay (README, Optional features): bodyguard contracts
--- (Config.Roleplay.Protection) and the hit on the hitman
--- (Config.Roleplay.HitOnHitman). Both off as shipped.
---
--- Bodyguards. A target with a live contract on them, shown to them on On me,
--- may post one anonymous protection job on it: a reward, taken from them at
--- once (Config.Roleplay.Protection.Account), and a meeting pin where they
--- stand. Other players see it on the board's Protection tab as a reward and
--- nothing else, and one of them may take it: not the target, not whoever
--- placed the contract, and nobody who holds or ever held it. The guard is
--- then given the target's name and the pin, and never the contract, who
--- placed it or who is on it. When the contract ends the money goes:
---   * ended without a completion (expired, cancelled, bought out) and a
---     guard took it: all of it to the guard;
---   * completed anyway (any payout collected on it): PayOnCompletionPercent
---     to the guard, the rest back to the target;
---   * nobody took it, or staff voided the contract: all back to the target.
--- Until a guard takes it, the target may cancel it and have it back; once
--- taken it stands, as a contract does.
---
--- The money is held in this module's own rows (crimson_rp_rows, kind
--- 'protection'), not among the contract's escrow lines: those are the
--- reward the board shows, the placer's to withdraw, and swept back to the
--- placer when the contract ends, none of which may touch a target's money.
--- It moves by the escrow's rules all the same: the reward is charged last,
--- after every check, through Util.charge (which reads the balance first);
--- the row is written before the charge and dropped if the charge fails, so
--- a refusal costs nothing; a payout claims its share on the row, and that
--- claim is written (paying) before anything moves, so a restart part-way
--- finds it and leaves it for staff rather than paying it again; it is paid
--- through Util.credit, and one that cannot be given (the player away, or
--- their account refused) stays owed on the row and is tried again on the
--- tick while they are in the city. A give that raised with nothing arriving
--- is tried again; one that cannot be told apart from a payment is left for
--- staff, never paid twice. Whatever is left for staff is an item in the
--- review queue (server/review.lua: /ch-stuck, the panel's Review), settled
--- by its own Refund, Pay or Dismiss. A row the store would not take is
--- written again on the tick. Every step is audited.
---
--- Nothing is posted, taken or cancelled on a contract staff put on hold
--- (Contracts.heldByStaff), and nothing posted or taken while staff pause
--- the app (Contracts.appPaused). A guard may not take a contract on the
--- person they guard (Contracts.guardsTarget), and one who holds or held
--- the contract is paid no share of the job.
---
--- The hit on the hitman. A target whose informant found out who an
--- operative is (server/informant.lua) is offered, on that card, to place a
--- contract on them: the Place form opens with them chosen, through the
--- same target handle the form's own list mints (App.mintTargetHandle), and
--- everything after is the normal place flow and its rules.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')
local Lock = CrimsonBoot.require('server.lib.lock')

local Protection = {}

local Storage, Identity, Audit, Notify, App, Informant, Review, Contracts, Projection

local KIND = 'protection'

--- Every job, by id, as kept in the store. Read once.
local jobs = {}
local loaded = false

--- Jobs being worked on right now (posting, taking, cancelling, paying),
--- so two requests never act on one at once, keyed by job id (and
--- 'protection:' .. contractId while one is bought).
local JobLock = Lock.new()

--- How often settled jobs are looked at for removal, in seconds, and when
--- that last ran (os.time()). See Protection.prune.
local PRUNE_EVERY = 600
local prunedAt = 0

local function rp()
    return type(Config.Roleplay) == 'table' and Config.Roleplay or {}
end

local function cfg()
    return type(rp().Protection) == 'table' and rp().Protection or {}
end

function Protection.enabled()
    return cfg().Enabled == true
end

function Protection.hitOnHitmanEnabled()
    return type(rp().HitOnHitman) == 'table' and rp().HitOnHitman.Enabled == true
end

function Protection.init(deps)
    Storage, Identity, Audit, Notify = deps.storage, deps.identity, deps.audit, deps.notify
    App, Informant = deps.app, deps.informant
    Review, Contracts = deps.review, deps.contracts
    Projection = deps.projection
    jobs, loaded = {}, false
    JobLock.reset()
    prunedAt = 0
    -- Asked by Contracts' acceptance: a guard may not take a contract on
    -- the person they guard.
    if Contracts then Contracts.guardsTarget = Protection.guardsTarget end
    -- The target's card, and the board's settings (Projection.extenders).
    if deps.projection and deps.projection.extenders then
        deps.projection.extenders.protection = Protection.extend
        deps.projection.settingsExtenders.protection = Protection.settings
    end
end

local function load()
    if loaded then return end
    local ok, rows = pcall(Storage.readRpRows, KIND)
    if not ok or type(rows) ~= 'table' then return end
    loaded = true
    for i = 1, #rows do
        local row = rows[i]
        if row.id and not jobs[row.id] then jobs[row.id] = row end
    end
end
Protection.load = load

--- Write a job's row. One the store would not take is marked (unsaved) and
--- written again by the tick (Protection.sweep), so what this process knows
--- reaches the store once it answers.
local function save(job)
    local again = job.unsaved == true
    job.unsaved = nil
    local ok, err = pcall(Storage.writeRpRow, job)
    if not ok then
        job.unsaved = true
        if not again then
            Audit.rejected('protection_not_written', job.target_cid, job.contract_id,
                { job = job.id, error = tostring(err) })
        end
        return false
    end
    return true
end

--- Whether staff put this contract on hold, or paused the app.
local function heldByStaff(contract)
    return Contracts ~= nil and Contracts.heldByStaff ~= nil and Contracts.heldByStaff(contract) == true
end

local function appPaused()
    return Contracts ~= nil and Contracts.appPaused ~= nil and Contracts.appPaused() == true
end

--- Leave a job's money for staff: an item in the review queue, settled by
--- its own Refund, Pay or Dismiss (Review.resolve). Its id comes from the
--- job and the share, and one already opened is never opened again: a
--- second item for the same money is a second chance to pay it.
---@param job table
---@param part string 'charge' | 'guard' | 'target'
---@param kind string 'protection_charge_unknown' | 'protection_payout_unconfirmed'
---@param amount integer
---@param known table|nil what could be told (arrived, error)
---@return string|nil id
local function leaveForStaff(job, part, kind, amount, known)
    if not Review or not Review.open then return nil end
    local id = 'rv' .. tostring(job.id) .. '-' .. part
    if Review.stateOf and Review.stateOf(id) ~= nil then return id end
    local cid = part == 'guard' and job.guard_cid or job.target_cid
    local detail = { job = job.id, share = part ~= 'charge' and part or nil }
    for k, v in pairs(known or {}) do detail[k] = v end
    local ok, opened = pcall(Review.open, {
        prepared = true, id = id, kind = kind, contract_id = job.contract_id,
        cids = { [part == 'guard' and 'guard' or 'target'] = cid },
        amount = amount, account = job.account, known = detail,
    })
    if not ok then
        Log.always(('protection job %s: the review item for its %s could not be opened (%s)')
            :format(tostring(job.id), part, tostring(opened)))
        return nil
    end
    return opened
end

--- Whether a job's money is still held by it: posted and not yet settled.
local function live(job)
    return job.state == 'open' or job.state == 'taken'
end

--- The job on this contract that still holds money, or nil.
local function jobOn(contractId)
    for _, job in pairs(jobs) do
        if job.contract_id == contractId and (live(job) or job.state == 'charging') then return job end
    end
    return nil
end

--- Whether this target is still owed money back from a job on this
--- contract: one ended (a row that could not be written after the charge,
--- one cancelled) whose refund has not reached them yet. A new job on it
--- waits for that: posted meanwhile, they were charged again while the
--- first money was still on its way back.
local function refundOwed(contractId, cid)
    for _, job in pairs(jobs) do
        if job.contract_id == contractId and job.target_cid == cid and job.state == 'settling'
            and not job.target_paid and (tonumber(job.target_due) or 0) > 0 then
            return true
        end
    end
    return false
end

--- How many live jobs this player guards.
local function guarding(cid)
    local n = 0
    for _, job in pairs(jobs) do
        if job.guard_cid == cid and job.state == 'taken' then n = n + 1 end
    end
    return n
end

--- Whether this player guards the person a contract is on, on any job
--- (Contracts.guardsTarget): they may not take that contract.
---@param contract table
---@param cid string
---@return boolean
function Protection.guardsTarget(contract, cid)
    if type(contract) ~= 'table' or not cid then return false end
    load()
    for _, job in pairs(jobs) do
        if job.state == 'taken' and job.guard_cid == cid and job.target_cid == contract.target_cid then
            return true
        end
    end
    return false
end

--- Where the server sees a player stand: x, y, z, or nil.
local function standing(src)
    local ok, coords = pcall(function() return GetEntityCoords(GetPlayerPed(src)) end)
    if not ok or not coords then return nil end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y then return nil end
    return { x = math.floor(x * 10 + 0.5) / 10, y = math.floor(y * 10 + 0.5) / 10,
             z = math.floor((z or 0) * 10 + 0.5) / 10 }
end

--- Whether a player is on a contract as anything but its target: placed it,
--- or holds or ever held it.
local function partyTo(contract, cid)
    if contract.creator_cid == cid then return true end
    local row = Storage.readHitman(contract.id, cid)
    return row ~= nil
end

--------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------

--- Pay one share of a job: the guard's (`guard`) or the target's
--- (`target`). Claimed on the row first (paying), so a second pass cannot
--- pay it again; settled on the row once it arrived. Away, or the account
--- refused: owed, tried again on the tick. Raised with nothing arriving:
--- owed too. Raised and cannot be told apart from a payment: left for staff.
---@return boolean paid
local function payShare(job, who)
    local dueKey, paidKey, stuckKey = who .. '_due', who .. '_paid', who .. '_stuck'
    local payingKey = who .. '_paying'
    local amount = math.floor(tonumber(job[dueKey]) or 0)
    if amount <= 0 or job[paidKey] or job[stuckKey] or job[payingKey] then
        return job[paidKey] == true or amount <= 0
    end
    local cid = who == 'guard' and job.guard_cid or job.target_cid
    local actor = Identity.byCitizenId(cid)
    if not actor or not actor.player then return false end

    -- The claim is written before anything moves: a restart between the
    -- give and the write that records it finds the claim (Protection.boot)
    -- and leaves the share for staff, never pays it again. A store that
    -- will not take the claim moves nothing; tried again on the tick.
    job[payingKey] = true
    if not save(job) then
        job[payingKey] = nil
        return false
    end
    local credited, raised, arrived = Util.credit(actor.player, job.account, amount)
    job[payingKey] = nil
    if credited then
        job[paidKey] = true
        if not save(job) then
            Log.always(('protection job %s: %s %d was paid and the row could not be written; it '
                .. 'is written again on the tick, and a restart before then leaves it for staff '
                .. '(review protection_payout_unconfirmed), never paid again.')
                :format(tostring(job.id), job.account, amount))
        end
        Audit.financial(who == 'guard' and 'protection_paid' or 'protection_refunded', cid, job.contract_id,
            { job = job.id, amount = amount, account = job.account })
        -- The guard's money arriving, on their phone, when it does: the
        -- settle said what the job paid, and a guard who was away is paid
        -- later, on the tick.
        if who == 'guard' then
            pcall(Notify.tellOrKeep, cid, 'Protection job paid',
                ('$%d from the protection job is in your %s.'):format(amount,
                    job.account == 'cash' and 'cash' or 'bank'), { bypassBudget = true })
        end
        return true
    end
    if raised and not (arrived == 0) then
        -- Part of it, or no way to tell: never given again blind.
        job[stuckKey] = true
        job[who .. '_review'] = leaveForStaff(job, who, 'protection_payout_unconfirmed', amount,
            { arrived = tonumber(arrived), error = tostring(raised) })
        save(job)
        Audit.financial('protection_payout_unconfirmed', cid, job.contract_id,
            { job = job.id, amount = amount, account = job.account, arrived = arrived, error = raised })
        Log.always(('protection job %s: paying %s %d raised and could not be checked; left for '
            .. 'staff in the review queue (audit protection_payout_unconfirmed).')
            :format(tostring(job.id), job.account, amount))
        return false
    end
    -- Nothing moved: the claim is taken back on the row too.
    if not job[who .. '_owed_said'] then
        job[who .. '_owed_said'] = true
        Audit.financial('protection_owed', cid, job.contract_id,
            { job = job.id, amount = amount, account = job.account })
    end
    save(job)
    return false
end

--- Pay what a settled job still owes, and close it once nothing is owed.
local function payOut(job)
    if job.state ~= 'settling' then return end
    if JobLock.held(job.id) then return end
    local ok, err = pcall(JobLock.run, job.id, function()
        -- A share left for staff (stuck) is the review queue's now.
        local guardDone = payShare(job, 'guard') or job.guard_stuck == true
        local targetDone = payShare(job, 'target') or job.target_stuck == true
        if guardDone and targetDone then
            job.state = 'settled'
            job.settled_at = os.time()
            save(job)
        end
    end)
    if not ok then
        Audit.rejected('protection_payout_raised', job.target_cid, job.contract_id,
            { job = job.id, error = tostring(err) })
    end
end

--- Decide where a job's money goes, once, and pay it.
---@param job table
---@param outcome string 'completed' | 'survived' | 'refund'
local function settle(job, outcome, why)
    if not live(job) then return end
    -- A guard who holds or held the contract is paid nothing of it
    -- (Contracts.guardsTarget refuses the taking; this is the backstop).
    local guardOnIt = false
    if job.state == 'taken' and job.guard_cid then
        local ok, row = pcall(Storage.readHitman, job.contract_id, job.guard_cid)
        guardOnIt = ok and row ~= nil
        if not live(job) then return end
    end
    local amount = math.floor(tonumber(job.amount) or 0)
    local guardDue = 0
    if job.state == 'taken' and job.guard_cid and not guardOnIt then
        if outcome == 'survived' then
            guardDue = amount
        elseif outcome == 'completed' then
            local percent = math.floor(tonumber(cfg().PayOnCompletionPercent) or 0)
            percent = math.max(0, math.min(100, percent))
            guardDue = math.floor(amount * percent / 100)
        end
    end
    job.guard_due = guardDue
    job.target_due = amount - guardDue
    job.guard_on_contract = guardOnIt or nil
    job.outcome = outcome
    job.ended_why = why
    job.state = 'settling'
    job.ended_at = os.time()
    save(job)
    Audit.financial('protection_settled', job.target_cid, job.contract_id,
        { job = job.id, outcome = outcome, why = why, guard_due = guardDue, target_due = amount - guardDue })

    if job.guard_cid then
        local words = guardDue > 0 and ('The job is over. It pays you $%d.'):format(guardDue)
            or 'The job is over. It paid you nothing.'
        if outcome == 'completed' and guardDue > 0 then
            words = ('The job is over: the contract on them was carried out. It pays you $%d of it.')
                :format(guardDue)
        elseif outcome == 'completed' then
            words = 'The job is over: the contract on them was carried out. It paid you nothing.'
        elseif outcome == 'survived' and guardDue > 0 then
            words = ('The job is over: they made it. It pays you $%d.'):format(guardDue)
        end
        pcall(Notify.tellOrKeep, job.guard_cid, 'Protection job', words, { bypassBudget = true })
    end
    if job.target_due > 0 then
        pcall(Notify.tellOrKeep, job.target_cid, 'Protection',
            ('Your protection job is over. $%d of it comes back to you.'):format(job.target_due),
            { bypassBudget = true })
    end
    payOut(job)
end

--- How a contract's end decides a job: carried out (any payout collected),
--- survived (expired, cancelled, bought out), or the money back (voided by
--- staff, or the contract gone from the store).
---@return string|nil outcome while it is still running
local function outcomeOf(contract)
    if not contract then return 'refund', 'contract_gone' end
    if not CH.TERMINAL[contract.state] then return nil end
    if contract.state == CH.STATE.COMPLETED or (tonumber(contract.slots_claimed) or 0) > 0 then
        return 'completed', contract.state
    end
    if contract.state == CH.STATE.VOIDED then return 'refund', contract.state end
    return 'survived', contract.state
end

--- Remove the rows of jobs that are settled, owe nobody anything and whose
--- contract the store has pruned (Config.Audit.ContractRetentionDays):
--- nothing reads them again, and crimson_rp_rows grew with every job ever
--- posted. A job with a share left stuck and no review item yet (the next
--- start opens one, Protection.boot), or in any state but settled, stays.
---@return integer removed
function Protection.prune()
    load()
    if not loaded then return 0 end
    local removed = 0
    local ids = {}
    for id, job in pairs(jobs) do
        if job.state == 'settled' and not JobLock.held(id)
            and not (job.guard_stuck and not job.guard_review)
            and not (job.target_stuck and not job.target_review) then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    for i = 1, #ids do
        local job = jobs[ids[i]]
        local read, contract = pcall(Storage.readContract, job.contract_id)
        if read and contract == nil and jobs[ids[i]] == job and job.state == 'settled' then
            if pcall(Storage.deleteRpRow, job.id) then
                jobs[ids[i]] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

--- The most jobs one pass settles: each is a payout or a refund. The rest
--- wait for the next tick.
Protection.SETTLES_PER_PASS = 25

--- The tick: settle every job whose contract has ended, and pay what is
--- still owed to anybody in the city. Runs whether the switch is on or off,
--- so turning it off strands nothing; with no job kept it reads nothing.
--- Whether a job's contract is still running comes from the snapshot the
--- other loops share (Projection.liveSnapshot): its contract is read only
--- once it has left that list (it was a read a job, every tick). Every
--- PRUNE_EVERY seconds, the rows of settled jobs on pruned contracts go too
--- (Protection.prune).
---@return integer settled
function Protection.sweep()
    load()
    if not loaded or next(jobs) == nil then return 0 end
    local now = os.time()
    if now - prunedAt >= PRUNE_EVERY then
        prunedAt = now
        Protection.prune()
    end
    local settled = 0
    local ids = {}
    for id in pairs(jobs) do ids[#ids + 1] = id end
    table.sort(ids)
    local running
    for i = 1, #ids do
        local job = jobs[ids[i]]
        -- A row the store would not take, written again first.
        if job and job.unsaved and not JobLock.held(job.id) then save(job) end
        if job and live(job) and not JobLock.held(job.id) and settled < Protection.SETTLES_PER_PASS then
            if running == nil then
                running = false
                if Projection and Projection.liveSnapshot then
                    local ok, list = pcall(Projection.liveSnapshot)
                    if ok and type(list) == 'table' then
                        running = {}
                        for _, c in ipairs(list) do
                            if not CH.TERMINAL[c.state] then running[c.id] = true end
                        end
                    end
                end
            end
            if not (running and running[job.contract_id]) then
                local outcome, why = outcomeOf(Storage.readContract(job.contract_id))
                if outcome then
                    settle(job, outcome, why)
                    settled = settled + 1
                end
            end
        elseif job and job.state == 'settling' then
            payOut(job)
        end
    end
    return settled
end

--- What the jobs hold now, for the conservation checks: money still to be
--- paid out of them, by account.
---@return integer held
function Protection.held()
    load()
    local total = 0
    for _, job in pairs(jobs) do
        if live(job) or job.state == 'charging' then
            total = total + (math.floor(tonumber(job.amount) or 0))
        elseif job.state == 'settling' then
            -- A share left for staff is the review queue's, not held here.
            if not job.guard_paid and not job.guard_stuck then
                total = total + math.floor(tonumber(job.guard_due) or 0)
            end
            if not job.target_paid and not job.target_stuck then
                total = total + math.floor(tonumber(job.target_due) or 0)
            end
        end
    end
    return total
end

--------------------------------------------------------------------------
-- The target
--------------------------------------------------------------------------

--- Post a protection job on a contract on this player.
---@param actor table
---@param payload table { id = contract id, amount, account = the account the dialog showed }
---@return table|false result
---@return string|nil err
---@return table|nil refusal
function Protection.post(actor, payload)
    if not Protection.enabled() then return false, CH.ERR.FEATURE_OFF end
    -- The same for every contract and everybody: a job is a new engagement.
    if appPaused() then return false, CH.ERR.APP_PAUSED end
    load()
    if not loaded then return false, CH.ERR.BUSY end
    local contractId = Util.toId(payload.id)
    local amount = tonumber(payload.amount)
    if not contractId or not amount or amount ~= amount or math.floor(amount) ~= amount then
        return false, CH.ERR.INVALID_INPUT
    end
    local rules = cfg()
    local account = rules.Account == 'cash' and 'cash' or 'bank'
    -- The account the dialog said it is paid from: changed since, refused
    -- rather than taken from another.
    if payload.account ~= account then return false, CH.ERR.TERMS_CHANGED end
    local least, most = math.floor(tonumber(rules.MinReward) or 0), math.floor(tonumber(rules.MaxReward) or 0)
    if amount < least or amount > most then
        return false, CH.ERR.PROTECTION_AMOUNT, { min = least, max = most }
    end

    local contract = Storage.readContract(contractId)
    if not contract or contract.target_cid ~= actor.cid then return false, CH.ERR.NOT_FOUND end
    if CH.TERMINAL[contract.state] or contract.state == CH.STATE.COMPLETING then
        return false, CH.ERR.ALREADY_SETTLED
    end
    if Notify.shownToTarget and not Notify.shownToTarget(contract) then return false, CH.ERR.NOT_FOUND end
    -- On hold by staff: no money moves on it. Told to its own target only.
    if heldByStaff(contract) then return false, CH.ERR.CONTRACT_FROZEN end
    if jobOn(contractId) then return false, CH.ERR.PROTECTION_EXISTS end
    if refundOwed(contractId, actor.cid) then return false, CH.ERR.PROTECTION_REFUND_PENDING end
    local pin = standing(actor.source)
    if not pin then return false, CH.ERR.BUSY end

    local key = 'protection:' .. contractId
    return JobLock.run(key, function()
        -- Written before the money moves: a crash after the charge leaves a
        -- row saying a charge was under way (charging), which the start
        -- leaves for staff rather than guessing.
        local id = Storage.nextId('prot')
        local job = {
            id = id, kind = KIND, contract_id = contractId, target_cid = actor.cid,
            target_name = contract.target_name or actor.name, amount = amount, account = account,
            state = 'charging', pin = pin, created_at = os.time(),
        }
        jobs[id] = job
        if not save(job) then
            jobs[id] = nil
            return false, CH.ERR.BUSY
        end
        -- Asked again after the awaits above, right before the charge: a
        -- freeze, an app pause or an ending landing in them is refused.
        local fresh = Storage.readContract(contractId)
        local late
        if not fresh or CH.TERMINAL[fresh.state] or fresh.state == CH.STATE.COMPLETING then
            late = CH.ERR.ALREADY_SETTLED
        elseif heldByStaff(fresh) then
            late = CH.ERR.CONTRACT_FROZEN
        elseif appPaused() then
            late = CH.ERR.APP_PAUSED
        end
        if late then
            jobs[id] = nil
            pcall(Storage.deleteRpRow, id)
            return false, late
        end
        -- Charged last, after every check (Util.charge reads the balance first).
        if not Util.charge(actor.player, account, amount) then
            jobs[id] = nil
            pcall(Storage.deleteRpRow, id)
            Audit.rejected('protection_short', actor.cid, contractId, { amount = amount, account = account })
            return false, CH.ERR.INSUFFICIENT, { account = account, need = amount }
        end
        job.state = 'open'
        Audit.financial('protection_taken', actor.cid, contractId, { job = id, amount = amount, account = account })
        if not save(job) and not save(job) then
            -- Charged, and the store still says charging. Known here, so
            -- handed back through the settling every refund takes: owed
            -- on the row, given once its claim can be written. A restart
            -- first finds the row charging and leaves it for staff in the
            -- review queue (Protection.boot), never refunded twice.
            Log.always(('protection job %s: %s %d was taken and the row could not be written; '
                .. 'it is handed back to the target.'):format(id, account, amount))
            settle(job, 'refund', 'not_recorded')
            -- Said as it is: their money was taken and is on its way back.
            -- "Busy" read as nothing having happened, and invited a second
            -- try, and a second charge.
            return false, CH.ERR.PROTECTION_NOT_RECORDED
        end
        return Protection.targetView(contract, actor.cid)
    end)
end

--- The target takes an open job back, and its money with it. Not once a
--- guard has taken it: as a contract an operative holds, it stands.
function Protection.cancel(actor, payload)
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.target_cid ~= actor.cid then return false, CH.ERR.NOT_FOUND end
    if job.state == 'taken' then return false, CH.ERR.CONTRACT_TAKEN end
    if job.state ~= 'open' or JobLock.held(job.id) then return false, CH.ERR.ALREADY_SETTLED end
    -- On hold by staff: no money moves on it. Told to its own target only.
    local contract = Storage.readContract(job.contract_id)
    if contract and heldByStaff(contract) then return false, CH.ERR.CONTRACT_FROZEN end
    if job.state ~= 'open' or JobLock.held(job.id) then return false, CH.ERR.ALREADY_SETTLED end
    -- Through the same settling as an ending, so the refund is owed if it
    -- cannot be given now. Nothing yields between the check above and here.
    Audit.action('protection_cancelled', actor.cid, job.contract_id, { job = job.id })
    settle(job, 'refund', 'cancelled_by_target')
    return { cancelled = true }
end

--- The target moves the meeting pin to where they stand now. Also with
--- the feature switched off, while their job is live (as cancel is): the
--- guard hired still works to it and is still owed, and the card still
--- draws the button. Refused feature_off then, every press failed.
function Protection.movePin(actor, payload)
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.target_cid ~= actor.cid or not live(job) then
        if not Protection.enabled() then return false, CH.ERR.FEATURE_OFF end
        return false, CH.ERR.NOT_FOUND
    end
    local pin = standing(actor.source)
    if not pin then return false, CH.ERR.BUSY end
    job.pin = pin
    save(job)
    if job.guard_cid then
        pcall(Notify.toCitizen, job.guard_cid, 'Protection job', 'Your client moved the meeting pin.')
        pcall(Notify.push, job.guard_cid, 'protection')
    end
    return { moved = true }
end

--- What a target's own card says of protection on this contract.
---@return table|nil
function Protection.targetView(contract, viewerCid)
    if contract.target_cid ~= viewerCid then return nil end
    load()
    local job = jobOn(contract.id)
    if not job then return nil end
    local out = { job = job.id, state = job.state == 'taken' and 'taken' or 'open', reward = job.amount }
    -- The guard by name only where an operative who took a contract under
    -- their name is shown to its target (the anonymity switches), and only
    -- one who took the job under theirs.
    if job.state == 'taken' and job.guard_name and job.guard_anon ~= true
        and Util.operativeNamesShown(contract.target_protected == true) then
        out.guardName = job.guard_name
    end
    return out
end

--- The offer on a contract card: what posting a job costs and from where,
--- while the server offers it and none is posted.
local function offerFor(contract)
    if not Protection.enabled() or jobOn(contract.id) then return nil end
    local rules = cfg()
    return { account = rules.Account == 'cash' and 'cash' or 'bank',
             min = math.floor(tonumber(rules.MinReward) or 0),
             max = math.floor(tonumber(rules.MaxReward) or 0) }
end

--- The operatives this target may place a contract on, each with a handle
--- the Place form takes (App.mintTargetHandle): the ones their informant
--- found out on this contract, and the ones on it under their own name where
--- the server shows those names to the target (the anonymity switches; the
--- card already names them, Projection's `operatives`). Never the placer:
--- that is not who this is about. Never one on it anonymously whom no
--- look-up found. Only while the server offers it.
local function counterTargets(contract, viewerCid, hitmen)
    if not Protection.hitOnHitmanEnabled() or not App or not App.mintTargetHandle then
        return nil
    end
    local out, seen = {}, {}
    local function add(cid, label, name)
        if seen[cid] then return end
        seen[cid] = true
        out[#out + 1] = { label = label, name = name, handle = App.mintTargetHandle(viewerCid, cid) }
    end
    local found = Informant and Informant.revealedOperatives
        and Informant.revealedOperatives(contract.id, viewerCid) or {}
    for i = 1, #found do add(found[i].cid, found[i].label, found[i].name) end
    if type(hitmen) == 'table' and Util.operativeNamesShown(contract.target_protected == true) then
        for i = 1, #hitmen do
            local h = hitmen[i]
            if h.state == 'active' and h.anon ~= true and type(h.hitman_name) == 'string'
                and h.hitman_cid ~= viewerCid then
                add(h.hitman_cid, h.alias or 'An operative', h.hitman_name)
            end
        end
    end
    return #out > 0 and out or nil
end

--- Add to a target's card (Projection.contract): their job, the offer, and
--- the operatives they may place a contract on. Nothing for anybody else.
function Protection.extend(out, contract, viewerCid, role, hitmen)
    if role ~= 'target' then return end
    if Protection.enabled() or jobOn(contract.id) then
        out.protection = Protection.targetView(contract, viewerCid)
        if not CH.TERMINAL[contract.state] then out.protectionOffer = offerFor(contract) end
    end
    out.counterTargets = counterTargets(contract, viewerCid, hitmen)
end

--------------------------------------------------------------------------
-- The guard
--------------------------------------------------------------------------

--- The board's Protection tab: the open jobs this player may take, by
--- reward alone, and the jobs they guard, with the target's name and pin.
function Protection.board(actor)
    load()
    local out = { enabled = Protection.enabled(), open = {}, mine = {},
                  maxJobs = math.floor(tonumber(cfg().MaxJobsPerGuard) or 0) }
    local ids = {}
    for id in pairs(jobs) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do
        local job = jobs[ids[i]]
        if job.state == 'taken' and job.guard_cid == actor.cid then
            out.mine[#out.mine + 1] = { job = job.id, reward = job.amount, targetName = job.target_name,
                                        pinSet = job.pin ~= nil }
        elseif out.enabled and job.state == 'open' and job.target_cid ~= actor.cid then
            local contract = Storage.readContract(job.contract_id)
            if contract and not CH.TERMINAL[contract.state] and not partyTo(contract, actor.cid) then
                out.open[#out.open + 1] = { job = job.id, reward = job.amount }
            end
        end
    end
    return out
end

--- Take a job. One guard to a job, never a party to the contract.
local function acceptUnlocked(actor, payload)
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.target_cid == actor.cid then return false, CH.ERR.NOT_FOUND end
    if job.state ~= 'open' or JobLock.held(job.id) then return false, CH.ERR.PROTECTION_TAKEN end
    -- The reward the board showed: a different one is refused, not taken on.
    if tonumber(payload.reward) ~= tonumber(job.amount) then return false, CH.ERR.TERMS_CHANGED end
    local most = math.floor(tonumber(cfg().MaxJobsPerGuard) or 0)
    if guarding(actor.cid) >= most then return false, CH.ERR.PROTECTION_LIMIT, { max = most } end
    local contract = Storage.readContract(job.contract_id)
    if not contract or CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    if partyTo(contract, actor.cid) then return false, CH.ERR.PROTECTION_PARTY end
    -- On hold by staff: nothing is taken on. Not right now, to somebody who
    -- is no party to the contract (as Contracts.accept says it).
    if heldByStaff(contract) then return false, CH.ERR.BAD_STATE end
    -- Anonymously only where an operative may take a contract anonymously.
    local anonymous = payload.anonymous == true
    if anonymous and not Util.anonymityAllowed('hitman', contract.target_protected == true) then
        return false, CH.ERR.ANONYMITY_OFF
    end
    if job.state ~= 'open' or JobLock.held(job.id) then return false, CH.ERR.PROTECTION_TAKEN end
    job.state, job.guard_cid, job.guard_name = 'taken', actor.cid, actor.name
    job.guard_anon, job.taken_at = anonymous or nil, os.time()
    save(job)
    Audit.action('protection_accepted', actor.cid, job.contract_id, { job = job.id, anon = anonymous or nil })
    pcall(Notify.tellOrKeep, job.target_cid, 'Protection', 'Somebody took your protection job. '
        .. 'They have your name and your meeting pin.', { bypassBudget = true })
    pcall(Notify.push, job.target_cid, 'protection')
    -- And the guard, on their phone: hired, by whom, for how much and how it
    -- pays. The board said so for as long as it was open, and nothing after.
    pcall(Notify.tellOrKeep, actor.cid, 'Protection job', ('You are hired to guard %s for $%d. '
        .. 'You are paid if the contract on them ends without being carried out. Set GPS on the '
        .. 'Protection tab takes you to their pin.'):format(tostring(job.target_name or 'them'),
        math.floor(tonumber(job.amount) or 0)), { bypassBudget = true })
    return Protection.board(actor)
end

--- One acceptance per guard at a time, so two taken in one another's awaits
--- cannot both pass MaxJobsPerGuard.
function Protection.accept(actor, payload)
    if not Protection.enabled() then return false, CH.ERR.FEATURE_OFF end
    if appPaused() then return false, CH.ERR.APP_PAUSED end
    local key = 'guard:' .. tostring(actor.cid)
    return JobLock.run(key, acceptUnlocked, actor, payload)
end

--- Where the meeting pin is, to the guard alone, for their map.
function Protection.waypoint(actor, payload)
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.guard_cid ~= actor.cid or job.state ~= 'taken' or not job.pin then
        return false, CH.ERR.NOT_FOUND
    end
    return { x = job.pin.x, y = job.pin.y }
end

--------------------------------------------------------------------------
-- Start and the settings payload
--------------------------------------------------------------------------

--- The start: read every job, and leave for staff, in the review queue,
--- the money a crash left unknown: a charge under way (charging), and a
--- share being paid (paying) or one that raised (stuck) with no item yet.
--- The job leaves the books here (state 'review', or its share stuck), so
--- nothing here pays it, it blocks no new job, and staff settle it with the
--- item's own Refund, Pay or Dismiss.
function Protection.boot()
    load()
    local ids = {}
    for id in pairs(jobs) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do
        local job = jobs[ids[i]]
        if job.state == 'charging' then
            local amount = math.floor(tonumber(job.amount) or 0)
            job.review = leaveForStaff(job, 'charge', 'protection_charge_unknown', amount)
            if job.review then job.state = 'review' end
            save(job)
            Audit.financial('protection_charge_unknown', job.target_cid, job.contract_id,
                { job = job.id, amount = job.amount, account = job.account, review = job.review })
            Log.always(('protection job %s: a charge of %s %s was under way when the server stopped; '
                .. 'left for staff in the review queue: refund the target if it was taken, dismiss '
                .. 'if not.'):format(tostring(job.id), tostring(job.account), tostring(job.amount)))
        elseif job.state == 'settling' or job.state == 'settled' then
            for _, who in ipairs({ 'guard', 'target' }) do
                local amount = math.floor(tonumber(job[who .. '_due']) or 0)
                if job[who .. '_paying'] and not job[who .. '_paid'] then
                    job[who .. '_paying'] = nil
                    job[who .. '_stuck'] = true
                    job[who .. '_review'] = leaveForStaff(job, who, 'protection_payout_unconfirmed',
                        amount, { restarted = true })
                    save(job)
                    Audit.financial('protection_payout_unconfirmed', who == 'guard' and job.guard_cid
                        or job.target_cid, job.contract_id,
                        { job = job.id, amount = amount, account = job.account, restarted = true })
                    Log.always(('protection job %s: paying %s %d was under way when the server '
                        .. 'stopped; left for staff in the review queue, never paid again.')
                        :format(tostring(job.id), tostring(job.account), amount))
                elseif job[who .. '_stuck'] and not job[who .. '_review'] and amount > 0 then
                    job[who .. '_review'] = leaveForStaff(job, who, 'protection_payout_unconfirmed',
                        amount)
                    if job[who .. '_review'] then save(job) end
                end
            end
        end
    end
end

--- Whether this player guards a live job now (taken, its contract not
--- ended): from memory, no read.
local function guardsLiveJob(cid)
    if type(cid) ~= 'string' then return false end
    for _, job in pairs(jobs) do
        if job.state == 'taken' and job.guard_cid == cid then return true end
    end
    return false
end

--- What the page needs to know to draw the Protection tab at all. With
--- the feature switched off, still drawn for a guard on a live job: their
--- job, its pin and Set GPS are on it, and they are still owed. Without it
--- they lost the tab they were told to use.
---@param out table the page's settings
---@param viewerCid string|nil who the page is for
function Protection.settings(out, viewerCid)
    if type(out) ~= 'table' then return end
    local guarding = false
    if not Protection.enabled() and viewerCid ~= nil then
        load()
        guarding = guardsLiveJob(viewerCid)
    end
    out.protection = (Protection.enabled() or guarding) or nil
    out.hitOnHitman = Protection.hitOnHitmanEnabled() or nil
end

--- How many jobs are kept (the tests).
function Protection.all()
    load()
    local out = {}
    for _, job in pairs(jobs) do out[#out + 1] = job end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

return Protection
