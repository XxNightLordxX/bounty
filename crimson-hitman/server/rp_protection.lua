--- Target counterplay (README Roleplay features): bodyguard contracts
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
--- a refusal costs nothing; a payout claims its share before it moves
--- (paying), is paid through Util.credit, and one that cannot be given
--- (the player away, or their account refused) stays owed on the row and is
--- tried again on the tick while they are in the city. A give that raised
--- with nothing arriving is tried again; one that cannot be told apart from
--- a payment is left for staff, never paid twice. Every step is audited.
---
--- The hit on the hitman. A target whose informant found out who an
--- operative is (server/informant.lua) is offered, on that card, to place a
--- contract on them: the Place form opens with them chosen, through the
--- same target handle the form's own list mints (App.mintTargetHandle), and
--- everything after is the normal place flow and its rules.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Protection = {}

local Storage, Identity, Audit, Notify, App, Informant

local KIND = 'protection'

--- Every job, by id, as kept in the store. Read once.
local jobs = {}
local loaded = false

--- Jobs being worked on right now (posting, taking, cancelling, paying),
--- so two requests never act on one at once. [id] = true
local busy = {}

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
    jobs, busy, loaded = {}, {}, false
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

local function save(job)
    local ok, err = pcall(Storage.writeRpRow, job)
    if not ok then
        Audit.rejected('protection_not_written', job.target_cid, job.contract_id,
            { job = job.id, error = tostring(err) })
        return false
    end
    return true
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

--- How many live jobs this player guards.
local function guarding(cid)
    local n = 0
    for _, job in pairs(jobs) do
        if job.guard_cid == cid and job.state == 'taken' then n = n + 1 end
    end
    return n
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
    local amount = math.floor(tonumber(job[dueKey]) or 0)
    if amount <= 0 or job[paidKey] or job[stuckKey] or job[who .. '_paying'] then
        return job[paidKey] == true or amount <= 0
    end
    local cid = who == 'guard' and job.guard_cid or job.target_cid
    local actor = Identity.byCitizenId(cid)
    if not actor or not actor.player then return false end

    job[who .. '_paying'] = true
    local credited, raised, arrived = Util.credit(actor.player, job.account, amount)
    job[who .. '_paying'] = nil
    if credited then
        job[paidKey] = true
        save(job)
        Audit.financial(who == 'guard' and 'protection_paid' or 'protection_refunded', cid, job.contract_id,
            { job = job.id, amount = amount, account = job.account })
        return true
    end
    if raised and not (arrived == 0) then
        -- Part of it, or no way to tell: never given again blind.
        job[stuckKey] = true
        save(job)
        Audit.financial('protection_payout_unconfirmed', cid, job.contract_id,
            { job = job.id, amount = amount, account = job.account, arrived = arrived, error = raised })
        Log.always(('protection job %s: paying %s %d raised and could not be checked; left for '
            .. 'staff to settle by hand (audit protection_payout_unconfirmed).')
            :format(tostring(job.id), job.account, amount))
        return false
    end
    if not job[who .. '_owed_said'] then
        job[who .. '_owed_said'] = true
        save(job)
        Audit.financial('protection_owed', cid, job.contract_id,
            { job = job.id, amount = amount, account = job.account })
    end
    return false
end

--- Pay what a settled job still owes, and close it once nothing is owed.
local function payOut(job)
    if job.state ~= 'settling' then return end
    if busy[job.id] then return end
    busy[job.id] = true
    local ok, err = pcall(function()
        local guardDone = payShare(job, 'guard')
        local targetDone = payShare(job, 'target')
        if guardDone and targetDone then
            job.state = 'settled'
            job.settled_at = os.time()
            save(job)
        end
    end)
    busy[job.id] = nil
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
    local amount = math.floor(tonumber(job.amount) or 0)
    local guardDue = 0
    if job.state == 'taken' and job.guard_cid then
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
    job.outcome = outcome
    job.ended_why = why
    job.state = 'settling'
    job.ended_at = os.time()
    save(job)
    Audit.financial('protection_settled', job.target_cid, job.contract_id,
        { job = job.id, outcome = outcome, why = why, guard_due = guardDue, target_due = amount - guardDue })

    if job.guard_cid then
        local words = guardDue > 0 and ('The job is over. You were paid $%d.'):format(guardDue)
            or 'The job is over. It paid you nothing.'
        if outcome == 'completed' and guardDue > 0 then
            words = ('The job is over: the contract on them was carried out. You were paid $%d of it.')
                :format(guardDue)
        elseif outcome == 'completed' then
            words = 'The job is over: the contract on them was carried out. It paid you nothing.'
        elseif outcome == 'survived' then
            words = ('The job is over: they made it. You were paid $%d.'):format(guardDue)
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

--- The tick: settle every job whose contract has ended, and pay what is
--- still owed to anybody in the city. Runs whether the switch is on or off,
--- so turning it off strands nothing.
---@return integer settled
function Protection.sweep()
    load()
    if not loaded then return 0 end
    local settled = 0
    local ids = {}
    for id in pairs(jobs) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do
        local job = jobs[ids[i]]
        if job and live(job) and not busy[job.id] then
            local outcome, why = outcomeOf(Storage.readContract(job.contract_id))
            if outcome then
                settle(job, outcome, why)
                settled = settled + 1
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
            if not job.guard_paid then total = total + math.floor(tonumber(job.guard_due) or 0) end
            if not job.target_paid then total = total + math.floor(tonumber(job.target_due) or 0) end
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
    if jobOn(contractId) then return false, CH.ERR.PROTECTION_EXISTS end
    local pin = standing(actor.source)
    if not pin then return false, CH.ERR.BUSY end

    local key = 'protection:' .. contractId
    if busy[key] then return false, CH.ERR.BUSY end
    busy[key] = true
    local ok, result, err, refusal = pcall(function()
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
        -- Charged last, after every check (Util.charge reads the balance first).
        if not Util.charge(actor.player, account, amount) then
            jobs[id] = nil
            pcall(Storage.deleteRpRow, id)
            Audit.rejected('protection_short', actor.cid, contractId, { amount = amount, account = account })
            return false, CH.ERR.INSUFFICIENT, { account = account, need = amount }
        end
        job.state = 'open'
        if not save(job) then
            -- Charged, and the row still says charging: the start leaves it
            -- for staff. Said now, in full.
            Log.always(('protection job %s: %s %d was taken and the row could not be written; '
                .. 'left for staff (audit protection_taken).'):format(id, account, amount))
        end
        Audit.financial('protection_taken', actor.cid, contractId, { job = id, amount = amount, account = account })
        return Protection.targetView(contract, actor.cid)
    end)
    busy[key] = nil
    if not ok then error(result, 0) end
    return result, err, refusal
end

--- The target takes an open job back, and its money with it. Not once a
--- guard has taken it: as a contract an operative holds, it stands.
function Protection.cancel(actor, payload)
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.target_cid ~= actor.cid then return false, CH.ERR.NOT_FOUND end
    if job.state == 'taken' then return false, CH.ERR.CONTRACT_TAKEN end
    if job.state ~= 'open' or busy[job.id] then return false, CH.ERR.ALREADY_SETTLED end
    -- Through the same settling as an ending, so the refund is owed if it
    -- cannot be given now. Nothing yields between the check and here.
    Audit.action('protection_cancelled', actor.cid, job.contract_id, { job = job.id })
    settle(job, 'refund', 'cancelled_by_target')
    return { cancelled = true }
end

--- The target moves the meeting pin to where they stand now.
function Protection.movePin(actor, payload)
    if not Protection.enabled() then return false, CH.ERR.FEATURE_OFF end
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.target_cid ~= actor.cid or not live(job) then return false, CH.ERR.NOT_FOUND end
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

--- The operatives this target's informant found out on this contract, each
--- with a handle the Place form takes (App.mintTargetHandle). Never the
--- placer: that is not who this is about. Only while the server offers it.
local function counterTargets(contract, viewerCid)
    if not Protection.hitOnHitmanEnabled() or not Informant or not Informant.revealedOperatives then
        return nil
    end
    if not App or not App.mintTargetHandle then return nil end
    local found = Informant.revealedOperatives(contract.id, viewerCid)
    if #found == 0 then return nil end
    local out = {}
    for i = 1, #found do
        out[#out + 1] = { label = found[i].label, name = found[i].name,
                          handle = App.mintTargetHandle(viewerCid, found[i].cid) }
    end
    return out
end

--- Add to a target's card (Projection.contract): their job, the offer, and
--- the operatives they may place a contract on. Nothing for anybody else.
function Protection.extend(out, contract, viewerCid, role)
    if role ~= 'target' then return end
    if Protection.enabled() or jobOn(contract.id) then
        out.protection = Protection.targetView(contract, viewerCid)
        if not CH.TERMINAL[contract.state] then out.protectionOffer = offerFor(contract) end
    end
    out.counterTargets = counterTargets(contract, viewerCid)
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
function Protection.accept(actor, payload)
    if not Protection.enabled() then return false, CH.ERR.FEATURE_OFF end
    load()
    local job = type(payload.job) == 'string' and jobs[payload.job] or nil
    if not job or job.target_cid == actor.cid then return false, CH.ERR.NOT_FOUND end
    if job.state ~= 'open' or busy[job.id] then return false, CH.ERR.PROTECTION_TAKEN end
    -- The reward the board showed: a different one is refused, not taken on.
    if tonumber(payload.reward) ~= tonumber(job.amount) then return false, CH.ERR.TERMS_CHANGED end
    local most = math.floor(tonumber(cfg().MaxJobsPerGuard) or 0)
    if guarding(actor.cid) >= most then return false, CH.ERR.PROTECTION_LIMIT, { max = most } end
    local contract = Storage.readContract(job.contract_id)
    if not contract or CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    if partyTo(contract, actor.cid) then return false, CH.ERR.PROTECTION_PARTY end
    -- Anonymously only where an operative may take a contract anonymously.
    local anonymous = payload.anonymous == true
    if anonymous and not Util.anonymityAllowed('hitman', contract.target_protected == true) then
        return false, CH.ERR.ANONYMITY_OFF
    end
    if job.state ~= 'open' or busy[job.id] then return false, CH.ERR.PROTECTION_TAKEN end
    job.state, job.guard_cid, job.guard_name = 'taken', actor.cid, actor.name
    job.guard_anon, job.taken_at = anonymous or nil, os.time()
    save(job)
    Audit.action('protection_accepted', actor.cid, job.contract_id, { job = job.id, anon = anonymous or nil })
    pcall(Notify.tellOrKeep, job.target_cid, 'Protection', 'Somebody took your protection job. '
        .. 'They have your name and your meeting pin.', { bypassBudget = true })
    pcall(Notify.push, job.target_cid, 'protection')
    return Protection.board(actor)
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

--- The start: read every job, and say of each one a crash left mid-charge.
function Protection.boot()
    load()
    for _, job in pairs(jobs) do
        if job.state == 'charging' then
            Audit.financial('protection_charge_unknown', job.target_cid, job.contract_id,
                { job = job.id, amount = job.amount, account = job.account })
            Log.always(('protection job %s: a charge of %s %s was under way when the server stopped; '
                .. 'check whether it was taken and settle it by hand.')
                :format(tostring(job.id), tostring(job.account), tostring(job.amount)))
        end
    end
end

--- What the page needs to know to draw the Protection tab at all.
function Protection.settings(out)
    if type(out) ~= 'table' then return end
    out.protection = Protection.enabled() or nil
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
