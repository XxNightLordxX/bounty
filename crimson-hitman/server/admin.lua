--- Staff commands (§4.1 of the improvements document).
---
--- The audit log records everything and nothing surfaced it in game, so a
--- staff member handling "the script ate my gun" needed database access.
--- These are the four things staff actually need, and no more: reading a
--- contract's history, closing one with a full refund, dealing with an
--- escrow line that was interrupted mid-release, and — separately gated —
--- finding out who is behind an anonymous party.
---
--- Every command is ACE-gated and every use is written to the audit log,
--- including the ones that only read. Looking is exceptional; a lookup that
--- leaves no trace is a lookup nobody can review.

local Util = CrimsonBoot.requireShared('util')

local Admin = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify, App, RateLimit, Death, Photo
local Informant, Kidnap, Mugshot, Photos, Timing, Review, Settings

function Admin.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    -- Optional, and only for its counters: the diagnosis reports how many
    -- completions are waiting on proof, which is otherwise invisible.
    Death = deps.death
    -- And the photo allowlist, which the diagnosis reports: an empty one
    -- refuses every kill photo, and nothing else on the report said so.
    Photo = deps.photo
    -- The kill photos kept for clients, which a staff void deletes.
    Photos = deps.photos

    -- Taken from the wiring like every other collaborator, rather than
    -- required here. `CrimsonBoot.require('server.app')` and the path the
    -- rest of the suite loads it by are different keys for the same file,
    -- so requiring it again hands back a SECOND copy of the module — one
    -- whose handler table nothing ever registered into. The diagnosis
    -- would then report every handler as unregistered while the real ones
    -- worked, which is a diagnosis lying in the other direction.
    App = deps.app
    RateLimit = deps.ratelimit

    -- Only the timer refresh needs these, and only to age their clocks.
    Informant, Kidnap, Mugshot = deps.informant, deps.kidnap, deps.mugshot
    -- How long the maintenance jobs take, which the diagnosis lists.
    Timing = deps.timing
    -- The review queue: money no rule here could settle, which /ch-stuck
    -- lists and /ch-review resolves.
    Review = deps.review
    -- What staff changed from the admin panel, which the diagnosis lists.
    Settings = deps.settings
end

--- How many of the slowest maintenance jobs the diagnosis lists.
local SLOWEST_SHOWN = 5

--- The slowest maintenance jobs, with their numbers. A resource that is
--- heavy on resmon says only that it is; this says which of its jobs.
local function reportTiming(say)
    if not (Timing and Timing.slowest) then return end
    local slowest = Timing.slowest(SLOWEST_SHOWN)
    local over = tonumber(Config.Diagnostics and Config.Diagnostics.SlowJobMs) or 0
    if #slowest == 0 then
        say('maintenance jobs: not timed yet (the first tick runs a few seconds after start)')
        return
    end
    say(('maintenance jobs, slowest first (ms over the last %d runs; warning above %s):')
        :format(Timing.WINDOW, over > 0 and (tostring(over) .. ' ms') or 'off'))
    for i = 1, #slowest do
        local job = slowest[i]
        say(('  %-28s max %7.2f  avg %7.2f  last %7.2f  runs %d%s'):format(
            job.name, job.max, job.avg, job.last, job.runs,
            (over > 0 and job.max > over) and '  SLOW' or ''))
    end
end

--------------------------------------------------------------------------
-- Permission
--------------------------------------------------------------------------

--- True when this caller may run a command at this level.
---
--- The server console (source 0) is always allowed: it is the operator, and
--- an owner locked out of their own recovery tools by a missing ACE has no
--- way back in.
---@param src number
---@param ace string
---@return boolean
--- `strict` refuses the extra ACEs and accepts only the named one. The
--- extras exist so an owner is not locked out of a diagnosis they have not
--- granted themselves yet; that reasoning does not carry to a command that
--- WRITES, and `command` — which most admin groups already hold — would
--- otherwise hand every one of them a button that skews live timers.
---@param src number
---@param ace string
---@param strict boolean|nil
---@return boolean
function Admin.allowed(src, ace, strict)
    if src == 0 then return true end
    -- A BOOL native: FXServer answers a granted ACE with the integer 1, not
    -- true, so this tests truthiness. `== true` refused everybody in game.
    if IsPlayerAceAllowed(src, ace) then return true end
    if strict then return false end

    -- Nobody holds crimson.admin until somebody grants it, and the first
    -- thing an owner needs is the command that says why their app is
    -- empty. An ACE their admin group already carries opens the same door.
    for _, extra in ipairs(Config.Admin.ExtraAces or {}) do
        if IsPlayerAceAllowed(src, extra) then return true end
    end
    return false
end

--- What to grant somebody who was refused, said in full.
---
--- "Not authorised." is true and useless. An owner reading it has no way to
--- know which ACE, or where to put it.
---@param ace string
---@return string
function Admin.howToAuthorise(ace)
    -- The console route matters more than the ACE for the one command an
    -- owner needs before anything is set up. Somebody locked out in game
    -- and told only about server.cfg has to restart their server to find
    -- out why their app is empty; the console answers now.
    return ('Not authorised. Right now: run it in the server console, which '
        .. 'never refuses — name a player, %s <playerid>. To have it in game: '
        .. 'add_ace group.admin %s allow — pasted into the console to grant it '
        .. 'until the next restart, or put in server.cfg to keep it.'):format(
        tostring(Config.Admin.Commands.diagnose), ace)
end

--- Resolve who ran a command, for the audit row. The console has no citizen
--- id, and recording one would be a lie.
local function callerCid(src)
    if src == 0 then return nil end
    local actor = Identity.resolve(src)
    return actor and actor.cid or nil
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

--- Everything that happened to one contract, in order.
---@return table[]|nil rows
---@return string|nil err
function Admin.timeline(contractId)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CH.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CH.ERR.NOT_FOUND end

    -- Audit writes are queued and flushed on the tick, so a staff member
    -- investigating something that just happened would not see it. Flush
    -- first: a timeline missing the last ten seconds is the ten seconds
    -- they are asking about.
    Audit.flush()

    local rows = Storage.auditForContract(contractId, Config.Admin.TimelineRows) or {}
    return {
        contract = {
            id = contract.id, state = contract.state, mode = contract.mode,
            created_at = contract.created_at, deadline_at = contract.deadline_at,
            resolved_at = contract.resolved_at, resolution = contract.resolution,
            slots = contract.payout_slots, claimed = contract.slots_claimed,
            -- Names, not citizen ids: this view is for reading a history,
            -- and the identity lookup is a separate, separately gated command.
            target = contract.target_name,
            creator = contract.anon_creator and '(anonymous)' or contract.creator_name,
        },
        escrow = Storage.readEscrow(contractId),
        hitmen = Storage.readHitmen(contractId),
        events = rows,
    }
end

--- A held line nothing can hand back: no contract row to name a client,
--- and the line does not say who it was taken from. Only escrow written
--- before lines recorded that; /ch-settle takes a citizen id for these.
local function namesNobody(line)
    return line.state == CH.ESCROW_STATE.HELD and not line.owed_to and not line.releasing_to
        and not line.taken_from and not (line.portion == CH.PORTION.STAKE and line.staker)
end

--- How a held line owed to somebody, neither left for staff (Escrow.parked)
--- nor queued for anyone, waits for staff (Escrow.leftForStaff), or nil:
--- 'stalled' for a give that stopped part-way on the running server (it
--- still names whom it was going to, so whether it moved anything cannot be
--- told); 'unqueued' for a queue entry that raised before it was written, or
--- one a login retry cleared under a staff pay that reused it, of which
--- nothing was given; 'stalled_claim' for one a claim owed and raised before
--- paying, leaving its contract COMPLETING with no claim running, of which
--- nothing was given either. Nothing gives any of them until the next start
--- queues it or leaves it for staff, so it is listed and settled as a line
--- left for staff already. Never one a call in this process holds or is
--- about to queue, nor one a claim running on its contract has just owed and
--- is about to pay.
---@param queues table|nil see Escrow.queued
---@return string|nil how 'stalled' | 'stalled_claim' | 'unqueued'
local function stalled(line, queues)
    if line.state ~= CH.ESCROW_STATE.HELD then return nil end
    local how = Escrow.leftForStaff(line, queues)
    return how ~= 'parked' and how or nil
end

--- Every interrupted release still open, and who it was paying.
---
--- Read in one pass over the log's release_interrupted rows. It asked the
--- log once per contract, which on the json and memory stores is a scan of
--- the whole log each time: a thousand contracts against a month of audit
--- froze the server for over a second per run.
---
--- Who it was paying is a citizen id, and on an anonymous contract that is
--- exactly what staff without the identity permission may not see. Shown
--- as the party's role to them; shown as the id, and recorded, to staff
--- who hold it.
---@param src number|nil who is asking
---@param quiet boolean|nil leave no audit row: the admin panel's overview
--- counts these every ten seconds while it is open, and its contract view
--- writes a row of its own
function Admin.interrupted(src, quiet)
    Audit.flush()

    local canIdentify = src == nil or src == 0
        or Admin.allowed(src, Config.Admin.IdentityAce, true)
    local rows = Storage.auditByAction('release_interrupted', 1000) or {}
    local out, seen, contracts = {}, {}, {}

    local function contractOf(contractId)
        local contract = contracts[contractId]
        if contract == nil then
            contract = Storage.readContract(contractId) or false
            contracts[contractId] = contract
        end
        return contract or nil
    end

    -- Lines left for staff (Escrow.parked): a give that kept raising with
    -- nothing arriving, raised with only part of it or no telling what
    -- arrived (Escrow.deliver), or was under way when the server stopped
    -- (Escrow.parkInterrupted, at the next start). Still held and owed to
    -- the player they were for, and given to nobody until staff settle them.
    -- First, so a line that was also caught mid-release once is shown for
    -- what it is now. Read from the escrow itself: the log's rows are pruned
    -- after Config.Audit.RetentionDays, and nothing else ever picks such a
    -- line up again, so listed from the rows it went unseen for good. What
    -- arrived is on the line; the rows still kept say when it was parked,
    -- and why.
    local parkedAt, parkedWhy = {}, {}
    for _, row in ipairs(Storage.auditByAction('escrow_deliver_parked', 1000) or {}) do
        local detail = row.detail or {}
        if detail.line then
            parkedAt[detail.line] = row.ts
            parkedWhy[detail.line] = (detail.stopped and 'stopped')
                or (detail.interrupted and 'interrupted')
                or (detail.unknown and 'unknown') or 'raised'
        end
    end
    -- Not one a call here holds (Escrow.inFlight): another staff settle
    -- claims it and unparks it in the write after, and listed in between it
    -- read as still waiting for staff while that settle gave it.
    local parked = Storage.parkedEscrow
        and Storage.parkedEscrow(Escrow.DELIVER_RAISE_LIMIT) or {}
    for _, line in ipairs(parked) do
        if not seen[line.id] and Escrow.parked(line) and not Escrow.inFlight(line.id) then
            seen[line.id] = true
            local intended = line.owed_to or line.releasing_to
            if not canIdentify then
                intended = Admin.partyRole(contractOf(line.contract_id), intended)
            end
            out[#out + 1] = {
                line = line.id, contract = line.contract_id, amount = line.amount,
                source = line.source, item = line.item, quantity = line.quantity,
                portion = line.portion, intended = intended, at = parkedAt[line.id],
                raised = tonumber(line.deliver_raises) or 0, why = parkedWhy[line.id],
                arrived = tonumber(line.deliver_arrived), before = tonumber(line.deliver_before),
            }
        end
    end

    -- Held, owed lines nothing gives until the next start (stalled), read
    -- from the escrow itself, so none is ever in nobody's sight meanwhile.
    -- One still naming whom a give was going to may have reached them
    -- ('stalled'); one that does not was given nothing ('unqueued', or
    -- 'stalled_claim' on a contract a claim that raised left COMPLETING).
    local queues = {}
    for _, line in ipairs(Storage.owedHeldEscrow and Storage.owedHeldEscrow() or {}) do
        local how = not seen[line.id] and stalled(line, queues)
        if how then
            seen[line.id] = true
            local intended = line.owed_to
            if not canIdentify then
                intended = Admin.partyRole(contractOf(line.contract_id), intended)
            end
            out[#out + 1] = {
                line = line.id, contract = line.contract_id, amount = line.amount,
                source = line.source, item = line.item, quantity = line.quantity,
                portion = line.portion, intended = intended,
                why = how,
                raised = tonumber(line.deliver_raises) or 0,
                arrived = tonumber(line.deliver_arrived), before = tonumber(line.deliver_before),
            }
        end
    end

    -- Lines left `releasing` with no call here holding them (Escrow.inFlight,
    -- which counts every claim from before it is made, and nothing else
    -- decides it): the call that claimed them raised, and nothing settles or
    -- puts them back until the next start. Read again, so one a call has
    -- settled or put back since the listing read it is not shown. /ch-settle
    -- parks one first, as that start would (Escrow.parkStuck).
    for _, found in ipairs(Storage.releasingEscrow and Storage.releasingEscrow() or {}) do
        local line = not seen[found.id] and not Escrow.inFlight(found.id)
            and Storage.readEscrowLine(found.id)
        if line and line.state == CH.ESCROW_STATE.RELEASING and not Escrow.inFlight(line.id) then
            seen[line.id] = true
            local intended = line.releasing_to or line.owed_to
            if not canIdentify or intended == nil then
                intended = Admin.partyRole(contractOf(line.contract_id), intended)
            end
            out[#out + 1] = {
                line = line.id, contract = line.contract_id, amount = line.amount,
                source = line.source, item = line.item, quantity = line.quantity,
                portion = line.portion, intended = intended, why = 'releasing',
                raised = tonumber(line.deliver_raises) or 0,
                arrived = tonumber(line.deliver_arrived), before = tonumber(line.deliver_before),
            }
        end
    end

    -- Lines of a closed contract whose ending raised before it handed them
    -- over, with nothing running on it any more (Contracts.endingOwes): the
    -- maintenance tick finishes that ending as the next start would
    -- (Contracts.finishEndings), and /ch-settle refuses them until it has.
    -- Listed so staff see why, and not as theirs to settle. Before the log's
    -- rows, so one of them is shown for what it is now. Not one a call here
    -- holds, nor one of a contract a claim or an ending (that finishing one
    -- included) is running on.
    local stranded = Storage.strandedEscrow and Storage.strandedEscrow(1000) or {}
    for _, line in ipairs(stranded) do
        if not seen[line.id] and Contracts.endingOwes(line) and not Escrow.inFlight(line.id)
            and not Escrow.claimRunning(line.contract_id) then
            seen[line.id] = true
            out[#out + 1] = {
                line = line.id, contract = line.contract_id, amount = line.amount,
                source = line.source, item = line.item, quantity = line.quantity,
                portion = line.portion, why = 'ending_unfinished', unfinished = true,
            }
        end
    end

    for i = #rows, 1, -1 do
        local row = rows[i]
        local detail = row.detail or {}
        local lineId = detail.line
        -- The newest row for a line is the one that counts.
        if lineId and not seen[lineId] then
            seen[lineId] = true
            local line = Storage.readEscrowLine(lineId)
            local contract = line and contractOf(line.contract_id or row.contract_id)
            -- Only still-open ones: a line settled since is not a question
            -- anybody needs to answer. Held, and held by no call here: one a
            -- release or retry is giving now is that call's. And not a line
            -- of a contract still live: put back with nothing given, it is
            -- that contract's own again, which /ch-settle refuses (/ch-void
            -- closes the contract). Nor of one an ending is still closing
            -- (Escrow.claimRunning), whose lines are its own until it returns.
            if line and line.state == CH.ESCROW_STATE.HELD and not Escrow.inFlight(lineId)
                and not (contract and not CH.TERMINAL[contract.state])
                and not Escrow.claimRunning(line.contract_id or row.contract_id) then
                local contractId = line.contract_id or row.contract_id
                -- Whom it is owed to now, read off the line as /ch-settle
                -- does: a return queued since is owed to the client, while
                -- the row still names whom the interrupted give was for.
                -- The row is only for a line that names nobody.
                local intended = line.owed_to or line.releasing_to or row.actor_cid
                -- What settles it, as /ch-settle decides (Admin.settleLine):
                -- 'queued' for one queued for whom it is owed since, which
                -- needs nothing; 'pay_or_return' where something names whom
                -- a pay goes to; 'return' where nothing does, as the row
                -- recovery writes now for a line that named nobody, which
                -- only a return settles (a pay has nobody to go to); and
                -- 'return_owner' for one of a contract never stored that
                -- does not say whose it is.
                local settles = 'return'
                if line.owed_to and Escrow.queued(line, queues) then
                    settles = 'queued'
                elseif not contract and namesNobody(line) then
                    settles = 'return_owner'
                elseif intended then
                    settles = 'pay_or_return'
                end
                if not canIdentify or intended == nil then
                    intended = Admin.partyRole(contractOf(contractId), intended)
                end
                out[#out + 1] = {
                    line = lineId,
                    contract = contractId,
                    amount = line.amount,
                    source = line.source,
                    item = line.item,
                    portion = line.portion,
                    intended = intended,
                    at = row.ts,
                    settles = settles,
                }
            end
        end
    end

    -- Escrow of a contract that was never stored, from before lines said
    -- whose they were (Contracts.recoverNeverPlaced): held, and naming
    -- nobody to hand it back to. Not an interrupted payment, but the same
    -- question for staff, and the boot told them to look here for it. Not
    -- one a call here holds: a staff return giving it, say; nor one of a
    -- contract a create here is still placing (Escrow.claimRunning), which
    -- reads as never stored until its row is written.
    for _, line in ipairs(Storage.orphanEscrow and Storage.orphanEscrow() or {}) do
        if not seen[line.id] and namesNobody(line) and not Escrow.inFlight(line.id)
            and not Escrow.claimRunning(line.contract_id) then
            seen[line.id] = true
            out[#out + 1] = {
                line = line.id,
                contract = line.contract_id,
                amount = line.amount,
                source = line.source,
                item = line.item,
                portion = line.portion,
                orphan = true,
            }
        end
    end

    if not quiet then
        Audit.staff(canIdentify and 'admin_stuck_identified' or 'admin_stuck', callerCid(src), nil,
            { lines = #out })
    end
    return out
end

--- How many of a player's contracts one listing shows. Newest first, so a
--- dispute is almost always in the first few.
local CONTRACT_LIST_ROWS = 15

--- A player's contracts, newest first, with the ids the other commands take.
---
--- Nothing in game showed a contract id, and every command that settles a
--- dispute — timeline, void, whois — starts from one. Closed contracts are
--- included while they are kept, because the disputes staff hear most are
--- about contracts that vanished: expired, voided or bought out.
---
--- A list of the contracts somebody placed or took would unmask every one
--- they did anonymously, which is what whois is separately gated for. Staff
--- without that permission see the player's anonymous parts left out, and
--- nothing to say anything was.
---@param src number|nil who is asking
---@param subject number|string a player id, or a citizen id for somebody offline
---@return table[]|nil rows { id, state, role, target, created_at, resolution }
---@return string|nil err
function Admin.contractsOf(src, subject)
    local cid
    local playerId = tonumber(subject)
    if playerId then
        local actor = Identity.resolve(playerId)
        if not actor then return nil, CH.ERR.NOT_FOUND end
        cid = actor.cid
    elseif type(subject) == 'string' and #subject <= 64 and subject:match('^[%w_%-]+$') then
        cid = subject
    else
        return nil, CH.ERR.INVALID_INPUT
    end

    local canIdentify = src == nil or src == 0
        or Admin.allowed(src, Config.Admin.IdentityAce, true)
    local out = {}
    for _, contract in ipairs(Storage.contractsInvolving(cid) or {}) do
        local role, anonymous
        if contract.target_cid == cid then
            role, anonymous = 'target', false
        elseif contract.creator_cid == cid then
            role, anonymous = 'client', contract.anon_creator == true
        else
            local row = Storage.readHitman(contract.id, cid)
            role, anonymous = 'hitman', row ~= nil and row.anon == true
        end
        if canIdentify or not anonymous then
            out[#out + 1] = {
                id = contract.id, state = contract.state, role = role,
                anonymous = anonymous, target = contract.target_name,
                created_at = contract.created_at, resolution = contract.resolution,
            }
        end
    end

    table.sort(out, function(a, b)
        if (a.created_at or 0) ~= (b.created_at or 0) then
            return (a.created_at or 0) > (b.created_at or 0)
        end
        return a.id > b.id
    end)
    for i = #out, CONTRACT_LIST_ROWS + 1, -1 do out[i] = nil end

    Audit.staff(canIdentify and 'admin_contracts_identified' or 'admin_contracts',
        callerCid(src), nil, { subject = cid, rows = #out })
    return out
end

--- A party to a contract by role, for staff who may not see who they are.
function Admin.partyRole(contract, cid)
    if not cid then return '(nobody)' end
    if not contract then return '(a player)' end
    if cid == contract.creator_cid then return 'the client' end
    if cid == contract.target_cid then return 'the target' end
    return 'an operative'
end

--------------------------------------------------------------------------
-- Acting
--------------------------------------------------------------------------

--- Whether boot recovery is still running (App.ready). Staff commands are
--- registered before it starts, and on mysql every step of it waits on the
--- store, so a settle typed then ran in the middle of it: recovery put back,
--- from what it had read, a line a staff pay was giving, then queued it
--- again, and it was paid twice. Nothing that moves escrow by hand runs
--- until recovery has finished; nor ever, when it raised (App.recoveryFailed):
--- what the last shutdown left is then not settled, and only a restart once
--- the logged cause is fixed runs it again.
---@return string|nil why 'recovering' | 'recovery_failed', or nil when it has finished
local function recovering()
    if App == nil or App.ready ~= false then return nil end
    return App.recoveryFailed and 'recovery_failed' or 'recovering'
end

--- Whether boot recovery is still running ('recovering') or raised
--- ('recovery_failed'), or nil once it has finished: what refuses a staff
--- write, from a command or from the admin panel alike.
---@return string|nil
function Admin.recovery()
    return recovering()
end

--------------------------------------------------------------------------
-- What the staff tools say
--------------------------------------------------------------------------
--
-- The commands (server/bridges.lua) and the admin panel (server/panel.lua)
-- answer a void, a settle and a review resolved in these words, so staff
-- read the same thing whichever they used.

--- While boot recovery runs (App.ready): what a write would act on is not
--- decided yet.
Admin.RECOVERING = 'Still recovering from the restart: nothing is settled, voided or listed '
    .. 'until that has finished. Try again in a moment.'

--- And once recovery has raised (App.recoveryFailed): it never finishes in
--- this process, so waiting a moment changes nothing.
Admin.RECOVERY_FAILED = 'Recovery failed at the last start (the server console says why): '
    .. 'nothing is settled, voided or listed, and the app stays closed. Fix the logged cause, '
    .. 'then restart the resource.'

--- What a staff write says while recovery has not finished, or nil once
--- it has.
---@return string|nil
function Admin.notRecovered()
    local waiting = recovering()
    if waiting == 'recovery_failed' then return Admin.RECOVERY_FAILED end
    if waiting == 'recovering' then return Admin.RECOVERING end
    return nil
end

--- What a void says (Admin.void).
---@param id any the contract id as staff gave it
---@param ok boolean
---@param err string|nil
---@return string
function Admin.voidAnswer(id, ok, err)
    local names = Config.Admin.Commands
    if err == 'recovering' then return Admin.RECOVERING end
    if err == 'recovery_failed' then return Admin.RECOVERY_FAILED end
    -- Mid-claim with no claim running (Admin.void): the void waits for
    -- the restart that puts it back to accepted.
    if err == 'stalled_claim' then
        return ('Could not void it: contract %s is mid-claim with no claim running (a '
            .. 'stalled claim: the claim paying a collection raised part-way), and only the next '
            .. 'start puts it back. Pay each line /%s lists for it as a stalled claim with /%s '
            .. '<line> pay, then restart the resource: recovery puts the contract back to accepted '
            .. '(or completes it, if that was its last collection), and /%s %s closes it then.')
            :format(tostring(id), names.stuck, names.settle, names.void, tostring(id))
    end
    return ok and 'Contract voided; escrow returned to the creator.'
        or ('Could not void it: ' .. tostring(err))
end

--- What a settle says (Admin.settleLine).
---@param ok boolean
---@param err string|nil
---@param detail any
---@return string
function Admin.settleAnswer(ok, err, detail)
    local names = Config.Admin.Commands
    if err == 'recovering' then return Admin.RECOVERING end
    if err == 'recovery_failed' then return Admin.RECOVERY_FAILED end
    if err == 'live' then
        return ('Not settled: contract %s is still live and this line is its own (a payout '
            .. 'its next claim pays, a bonus or a stake), not one left for you. /%s %s closes a live '
            .. 'contract and returns its escrow; /%s settles only what /%s lists.')
            :format(tostring(detail), names.void, tostring(detail), names.settle, names.stuck)
    end
    -- Closed, by an ending that raised before it handed this over
    -- (Admin.settleLine): the maintenance tick finishes it.
    if err == 'ending_unfinished' then
        return ('Not settled: ending unfinished; it settles itself within a minute. '
            .. 'Contract %s closed, but its ending raised before it handed this line over; the '
            .. 'server finishes that ending as a restart would (a stake by why it ended, the rest '
            .. 'back to the client), so there is nothing for you to settle. Nothing moved.')
            :format(tostring(detail))
    end
    if ok and err == 'queued' and detail == 'refused' then
        return ('Queued: they are in the city, but the give was refused (no room in their '
            .. 'pockets, their account would not take it, or their inventory could not be read), '
            .. 'so it goes on their retry queue and is tried again while they are in the city and '
            .. 'at their next login; see /%s.'):format(names.stuck)
    end
    if ok and err == 'queued' then
        return 'Queued: they are not in the city, so it is delivered at their next login.'
    end
    if ok and err == 'requeued' then
        return ('Re-queued after a failed give: giving it raised an error with nothing '
            .. 'arriving, so it goes back on their retry queue and is tried again while they are '
            .. 'in the city and at their next login; three such raises leave it for staff (see /%s).')
            :format(names.stuck)
    end
    if err == 'parked' then
        return ('Not settled: giving it raised again, so it is left for staff again; '
            .. 'see /%s.'):format(names.stuck)
    end
    if err == 'already_queued' then
        return ('Already queued for %s: it is theirs, given while they are in the city '
            .. 'or at their next login. Nothing to settle.'):format(tostring(detail))
    end
    if err == 'pay_only' then
        return ('Not settled: nothing of it was given (owed to %s and in no retry queue), '
            .. 'so only /%s <line> pay settles it, to them.'):format(tostring(detail), names.settle)
    end
    if err == 'owes_less' then
        return ('Not settled: the line now owes only %s, less than that amount; '
            .. 'check again (/%s).'):format(tostring(detail), names.stuck)
    end
    if err == 'not_left' then
        return ('Not settled: it is no longer left for staff, as something settled or '
            .. 'moved it since it was read; see /%s.'):format(names.stuck)
    end
    if err == 'raised' then
        return ('Not settled: settling it raised an error (logged as admin_settle_raised, '
            .. 'and in the console). Anything it left mid-give is left for staff; see /%s.')
            :format(names.stuck)
    end
    if err == CH.ERR.LOCKED then
        return ('Not settled: something else is giving or settling it right now (a '
            .. 'release, a login retry, the claim on its contract, another settle), or it is owed '
            .. 'to somebody else; nothing moved. Check again with /%s.'):format(names.stuck)
    end
    return ok and 'Line settled.' or ('Could not settle it: ' .. tostring(err))
end

--- What resolving a review item says (Admin.resolveReview).
---@param id any the item id as staff gave it
---@param ok boolean
---@param err string|nil
---@param detail any
---@return string
function Admin.reviewAnswer(id, ok, err, detail)
    local names = Config.Admin.Commands
    if err == 'recovering' then return Admin.RECOVERING end
    if err == 'recovery_failed' then return Admin.RECOVERY_FAILED end
    if ok then
        local r = detail or {}
        if r.action == 'dismiss' then
            return 'Dismissed. Nothing was given.' .. (r.continued
                and ' It had been decided so before a stop, and is finished now.' or '')
        end
        return ('Resolved: %d line(s) given, %d owed and given while they are in '
            .. 'the city or at their next login, %d left for /%s (giving raised). %s')
            :format(r.settled or 0, r.pending or 0, r.parked or 0, names.stuck,
                r.continued and 'It had been decided before a stop and was finished as decided, '
                    .. 'not as asked now.' or '')
    end
    local why = {
        [CH.ERR.NOT_FOUND] = 'No review item has that id.',
        [CH.ERR.ALREADY_SETTLED] = 'Already resolved; nothing was given again.',
        [CH.ERR.BUSY] = 'It is being resolved right now. Look again in a moment.',
        [CH.ERR.LOCKED] = 'Something else resolved or began resolving it meanwhile; look again.',
        note_required = 'Say why: /' .. names.review .. ' <id> dismiss <note>.',
        no_party = 'Name who it goes to: a citizen id, or a role the item names.',
        which_money = 'It records more than one kind of money: say which (cash, bank or dirty).',
        nothing_recorded = 'It records nothing of that to give; use pay, or items for goods.',
        over_recorded = ('That is more than it records (%s); refund at most that.')
            :format(tostring(detail)),
        raised = ('Resolving it raised an error (in the console). It is left being resolved, '
            .. 'with the decision on it: /%s %s finishes it.')
            :format(names.review, tostring(id)),
    }
    return why[err] or ('Usage: /%s [all] | /%s <id> refund <citizenid|role> <amount> '
        .. '[cash|bank|dirty] | refund <citizenid|role> items | pay <citizenid|role> | '
        .. 'dismiss <note>'):format(names.review, names.review)
end

--- Close a contract and return everything to the creator.
---
--- Routed through Contracts.resolve like every other ending, so stakes
--- settle, the remainder returns and the parties are told. A staff void is
--- not a special case in the money paths and must never become one.
---@return boolean ok
---@return string|nil err 'recovering' / 'recovery_failed' until boot recovery has
--- finished, and 'stalled_claim' for a contract mid-claim with no claim running
function Admin.void(src, contractId, reason)
    local waiting = recovering()
    if waiting then return false, waiting end
    contractId = Util.toId(contractId)
    if not contractId then return false, CH.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end

    -- Mid-claim (COMPLETING) is no state a void closes: only the claim's own
    -- end, or the next start, takes it back to accepted. With a claim running
    -- on it (Escrow.claimRunning) the void below is refused as locked, and
    -- goes through once the claim is done. With none, a claim raised part-way
    -- and left it so (a stalled claim), and answered `locked` it read as busy
    -- for ever. Not put back here: which collection that claim paid is
    -- recovery's to decide, with nothing else running. Staff pay what
    -- /ch-stuck lists for it as a stalled claim and restart the resource;
    -- recovery puts it back to accepted (or completes it, when every
    -- collection was paid), and the void closes it then. Read again with no
    -- claim counted: a claim that finished during the read above had moved
    -- it on already.
    if contract.state == CH.STATE.COMPLETING and not Escrow.claimRunning(contractId) then
        contract = Storage.readContract(contractId) or contract
        if contract.state == CH.STATE.COMPLETING and not Escrow.claimRunning(contractId) then
            return false, 'stalled_claim'
        end
        if CH.TERMINAL[contract.state] then return false, CH.ERR.ALREADY_SETTLED end
    end

    -- VOIDED, not CANCELLED. The state machine has declared VOIDED terminal
    -- and reachable from ACTIVE and ACCEPTED since it was written, commented
    -- "admin", and nothing had ever set it: this command, the only thing
    -- that should, resolved as though the creator had cancelled.
    --
    -- Which is not cosmetic. Cancelling and re-listing is otherwise free, so
    -- a creator whose own contract went CANCELLED cannot list anything for
    -- Config.Amendments.CancelCooldownSeconds. A staff member voiding a
    -- contract to FIX something therefore rate-limited the person they were
    -- helping, for a cancellation they did not make.
    --
    -- Everything else is unchanged: resolve treats every terminal alike
    -- except BAILED_OUT and EXPIRED, so the escrow still comes back to the
    -- creator in full and the hitmen still get their stakes.
    local ok, err = Contracts.resolve(contractId, CH.STATE.VOIDED,
        contract.creator_cid, nil, 'voided_by_staff')
    if not ok then return false, err end

    Audit.financial('admin_void', callerCid(src), contractId,
        { reason = Util.sanitizeText(reason, 120) or 'none given' })

    -- A collection paid before the void left its kill photo waiting for the
    -- client. A contract staff had to close is not one whose photo should
    -- sit there for the retention days, so it goes now, as if the client
    -- had deleted it; one they already saved is on their phone, not here.
    if Photos then Photos.forgetContract(contractId) end

    Notify.toCitizen(contract.creator_cid, 'Contract voided',
        'Staff closed your contract. Your escrow has been returned.',
        { bypassBudget = true })

    return true
end

--- The log written now, and on json to the disk as well, rather than at the
--- next tick: a staff settlement is the record of money moved by hand, and
--- a crash inside the flush interval lost it with the queue.
local function logNow()
    Audit.flush()
    if Storage.flush then pcall(Storage.flush) end
end

--- Whom a line is owed to, as /ch-stuck names them to `src`: a role to
--- staff who may not see who is behind an anonymous party.
local function partyFor(src, contract, cid)
    local canIdentify = src == nil or src == 0
        or Admin.allowed(src, Config.Admin.IdentityAce, true)
    if canIdentify and cid then return cid end
    return Admin.partyRole(contract, cid)
end

--- A staff settle that raised (Admin.settleLine): logged with the error, and
--- a line it left `releasing` left for staff at once, as the next start
--- would (Escrow.parkStuck): what of it arrived cannot be told. Raised on,
--- it went unlogged, stuck `releasing` and listed by nothing until then.
---@return boolean ok false
---@return string err 'raised'
local function settleRaised(who, line, disposition, recipient, err)
    local parkRan, stuck = pcall(Escrow.parkStuck, line.id)
    Audit.financial('admin_settle_raised', who, line.contract_id,
        { line = line.id, disposition = disposition, recipient = recipient,
          error = tostring(err), parked = (parkRan and stuck) or nil,
          park_error = not parkRan and tostring(stuck) or nil, review = true })
    logNow()
    print(('[crimson-hitman] settling escrow line %s (%s) raised: %s'):format(
        tostring(line.id), disposition, tostring(err)))
    return false, 'raised'
end

--- Settle one interrupted line deliberately: either to the person it was
--- being paid to, or back to the contract's creator, or, for a line left for
--- staff (Escrow.parked), as already delivered to the person it was being
--- paid to, giving nothing.
---
--- `owner` is a citizen id, for `return` only, and only on a line that
--- names nobody (namesNobody): staff found out whose it was, since nothing
--- on the server can say. For `pay` it is an amount instead (`pay <amount>`,
--- a quantity for an item), only on a line left for staff and at most what
--- it still owes: exactly that much is given, and the rest is counted on
--- the line as arrived. Where what arrived could not be told (a give the
--- server stopped part-way, before the line recorded what of it arrived),
--- what the line says arrived may be short, and staff who checked give the
--- rest this way rather than overpay by the part it does not know of.
---@param disposition string 'pay' | 'return' | 'delivered'
---@param owner string|number|nil
---@return boolean ok
---@return string|nil err
---@return string|integer|nil detail whose queue it is in ('already_queued'), whom only a
--- pay settles it to ('pay_only'), what it owes ('owes_less'), the live contract it
--- belongs to ('live'), the closed contract whose ending has still to hand it over
--- ('ending_unfinished'), or for 'queued' why it was not given: 'away' (not in the
--- city) or 'refused' (the give was refused). 'recovering' while boot recovery runs,
--- and 'recovery_failed' once it has raised.
function Admin.settleLine(src, lineId, disposition, owner)
    local waiting = recovering()
    if waiting then return false, waiting end
    lineId = Util.toLineId(lineId)
    if not lineId then return false, CH.ERR.INVALID_INPUT end
    if disposition ~= 'pay' and disposition ~= 'return' and disposition ~= 'delivered' then
        return false, CH.ERR.INVALID_INPUT
    end
    -- A whole number, one or more, written as digits.
    local amount
    if disposition == 'pay' and owner ~= nil then
        amount = math.tointeger(type(owner) == 'number' and owner
            or (type(owner) == 'string' and owner:match('^%d+$') and tonumber(owner)) or nil)
        if not amount or amount < 1 then return false, CH.ERR.INVALID_INPUT end
        owner = nil
    end
    if owner ~= nil and (disposition ~= 'return' or type(owner) ~= 'string' or #owner > 64
        or not owner:match('^[%w_%-]+$')) then
        return false, CH.ERR.INVALID_INPUT
    end

    local line = Storage.readEscrowLine(lineId)
    if not line then return false, CH.ERR.NOT_FOUND end
    if line.state == CH.ESCROW_STATE.SETTLED then return false, CH.ERR.ALREADY_SETTLED end

    -- A line `releasing` that no call here holds (Escrow.inFlight) was left
    -- so by one that raised after its claim, and /ch-stuck lists it: what
    -- the next start would do is done now (Escrow.parkStuck), and it is
    -- settled as it then stands. One a call still holds is that call's.
    if line.state == CH.ESCROW_STATE.RELEASING then
        if not Escrow.parkStuck(lineId) then return false, CH.ERR.LOCKED end
        line = Storage.readEscrowLine(lineId)
        if not line or line.state ~= CH.ESCROW_STATE.HELD then return false, CH.ERR.LOCKED end
    end

    -- A contract that was never stored has no row, and its lines still say
    -- whose they are (Contracts.recoverNeverPlaced leaves one caught
    -- mid-payment for staff, as recovery does any other). One that does not
    -- goes where staff say, and nowhere else does: anywhere else, a citizen
    -- id typed here would take the line from the one it names. A line owed
    -- to somebody names them too: a review item's pay is written under the
    -- contract it is about, which may never have been stored (a take that
    -- could not be confirmed), and left for staff it was listed by /ch-stuck
    -- and refused here as not found, with nothing else that ever gives it.
    local contract = Storage.readContract(line.contract_id)
    if owner then
        if contract or not namesNobody(line) then return false, CH.ERR.INVALID_INPUT end
    elseif not contract and not line.taken_from and not line.owed_to then
        return false, CH.ERR.NOT_FOUND
    end

    -- Who it goes to, read off the line itself. Pay and delivered go to
    -- whom it is owed: a line left for staff is owed to whom its give was
    -- for, and one a restart found mid-give to whom that give was going
    -- (Escrow.parkInterrupted), a staff return included, which is the only
    -- party it can have reached and the one /ch-stuck names. Taken from the
    -- log's release_interrupted row first, a return the server stopped after
    -- the client's credit was refused for delivered and pay, and once the log
    -- let the row go, a pay gave the hitman the same money as well.
    -- `releasing_to` is written before the money moves, so a line caught
    -- mid-release still names who it was going to. Only a line that names
    -- nobody, written before lines did, goes to whom the log names: the
    -- line decides, and a pay never goes to a party it no longer names.
    --
    -- Return goes to whoever put the line up. A stake is the hitman's own
    -- money: returned "to the creator", an interrupted stake was handed to
    -- the one party it was never theirs to take. A line owed to somebody
    -- has no payer this can name.
    --
    -- A held line owed to somebody that nothing gives (stalled) is settled
    -- as one left for staff: the next start would queue it or leave it so.
    local queues = {}
    local left = Escrow.leftForStaff(line, queues)
    local parked = left ~= false

    -- Queued for whom it is owed to (a 'return' to an offline client, say):
    -- theirs already, given at their next login or while they are in the
    -- city, so there is nothing to settle and the answer says whose it is.
    -- Refused as locked because the log's release_interrupted row named
    -- somebody else, staff told by /ch-stuck to pay it were turned away
    -- from a line that needed nothing.
    if not parked and Escrow.queued(line, queues) then
        return false, 'already_queued', partyFor(src, contract, line.owed_to)
    end

    -- Owed to somebody, and neither left for staff nor queued: a call here
    -- holds it, or is about to queue it (Escrow.inFlight); a claim running on
    -- its contract has just owed it and is about to pay it (COMPLETING); or it
    -- is a stake's split its stake does not stand behind yet. That call's,
    -- or the next start's. Treated as left for staff, a `return` in the
    -- moment between a claim owing the hitman's payout and paying it handed
    -- it to the client, and the claim reported it paid.
    if not parked and line.owed_to then return false, CH.ERR.LOCKED end

    -- Any other line of a contract still live (ACTIVE, ACCEPTED, COMPLETING)
    -- is that contract's own: a collection its next claim pays, a bonus, a
    -- hitman's stake. Only a line left for staff (Escrow.leftForStaff:
    -- parked, or stalled in any of its ways) is settled here, or one of a
    -- contract closed or never stored. Owed to nobody, a `return` handed the
    -- client the 5,000 a hitman was about to claim, before or while the claim
    -- owed it to them, and the claim paid nothing. /ch-void closes a live
    -- contract and returns its escrow through every rule an ending keeps. A
    -- closed contract never opens again, so one read closed stays so for the
    -- settle below.
    if not parked and contract and not CH.TERMINAL[contract.state] then
        return false, 'live', contract.id
    end

    -- Closed, by an ending still running on it (Contracts.resolve, counted
    -- with the claims, Escrow.claimRunning): it writes the closed state
    -- before it moves the escrow, and its lines are its own until it
    -- returns. Settled here in between, a `return` of a hitman's stake an
    -- expiry was about to forfeit handed it back to them, and the client lost
    -- the forfeit. Asked after the contract was read: an ending that closed
    -- it is counted from before its write.
    if not parked and Escrow.claimRunning(line.contract_id) then return false, CH.ERR.LOCKED end

    -- Closed, with no ending running on it any more, and still holding a
    -- line only its ending hands over (Contracts.endingOwes): the ending
    -- raised between writing the closed state and moving the escrow. Its
    -- line is not one left for staff: settled here, a `return` of a stake an
    -- expiry was forfeiting handed it back to the hitman. The maintenance
    -- tick finishes that ending as the next start would
    -- (Contracts.finishEndings), within a minute, and the command says so.
    if not parked and contract and CH.TERMINAL[contract.state] and Contracts.endingOwes(line) then
        return false, 'ending_unfinished', contract.id
    end

    -- Nothing of it was given (Escrow.NEVER_GIVEN: owed, in no retry queue,
    -- and naming no give that may have run, or owed by a claim that raised
    -- before paying it), so it is paid to whom it is owed, which gives it or
    -- queues it again, and settled no other way: handed back, a hitman's
    -- payout that had only lost its queue entry went to the client; called
    -- delivered, it settled with nothing given.
    if Escrow.NEVER_GIVEN[left] and disposition ~= 'pay' then
        return false, 'pay_only', partyFor(src, contract, line.owed_to)
    end

    -- What it still owes as read, on the record of every settle (below).
    local owed = Escrow.stillOwed(line)
    if amount and (not parked or amount > owed) then
        return false, CH.ERR.INVALID_INPUT
    end
    local recipient
    if disposition == 'pay' or disposition == 'delivered' then
        recipient = line.owed_to or line.releasing_to
        if not recipient then
            local rows = Storage.auditByAction('release_interrupted', 1000) or {}
            for i = #rows, 1, -1 do
                if (rows[i].detail or {}).line == lineId then recipient = rows[i].actor_cid; break end
            end
        end
    elseif line.portion == CH.PORTION.OWED then
        return false, CH.ERR.INVALID_INPUT
    elseif owner then
        recipient = owner
    elseif line.portion == CH.PORTION.STAKE then
        recipient = line.staker
    else
        recipient = contract and contract.creator_cid or line.taken_from
    end
    if not recipient then return false, CH.ERR.INVALID_INPUT end

    -- Owed to somebody else: settling it to another would take it off them.
    -- A line left for staff is owed to whoever its give was for and queued
    -- for nobody, and handing it back instead is exactly the question staff
    -- were left. Asked again of the line as the release claims it (its
    -- guard, below): another settle can have queued it, or left it owed to
    -- somebody else, since this read.
    local function owedElsewhere(l)
        return l.owed_to ~= nil and l.owed_to ~= recipient
            and not (parked and disposition == 'return')
    end
    if owedElsewhere(line) then return false, CH.ERR.LOCKED end

    -- Already with them: staff checked and found it there, after a give that
    -- raised or a restart in the middle of one (Escrow.deliver,
    -- Escrow.parkInterrupted). Settled to whom it was going, giving nothing,
    -- through a claim counted in flight like every release, so it cannot
    -- settle a line something else is paying, and nothing here takes it
    -- from under it (Escrow.settleDelivered). Only a line left for staff
    -- whose give may have run: any other is given by the normal paths, and
    -- settling one unpaid would lose it. Checked again on the line as
    -- claimed, as a pay is.
    --
    -- Recorded on the line by the settle itself (settled_by_staff, who, and
    -- settled_at), and the log written at once: a line that left escrow and
    -- reached nobody here, with its only record a row in the audit queue,
    -- had no record at all after a crash inside the flush interval.
    if disposition == 'delivered' then
        if not parked then return false, CH.ERR.INVALID_INPUT end
        local who = callerCid(src)
        local ran, settled, claim = pcall(Escrow.settleDelivered, lineId, recipient,
            { disposition = disposition, by = who or 'console' })
        if not ran then return settleRaised(who, line, disposition, recipient, settled) end
        local why = claim and claim.why
        Audit.financial('admin_settle_line', who, line.contract_id,
            { line = lineId, disposition = disposition, recipient = recipient,
              settled = settled and 1 or 0, pending = 0, given = 0,
              owed = claim and claim.owed or owed, refused = why,
              arrived = line.deliver_arrived, before = line.deliver_before })
        if claim and claim.lost then
            Audit.financial('escrow_settle_lost', recipient, line.contract_id, { line = lineId })
            if Review then
                Review.open({
                    kind = 'escrow_settle_lost', contract_id = line.contract_id,
                    cids = { recipient = recipient },
                    items = { { id = line.id, source = line.source, amount = line.amount,
                                item = line.item, quantity = line.quantity } },
                    known = { delivered = 'staff found it with them', by = who or 'console' },
                })
            end
        end
        logNow()
        if settled then return true, nil end
        if why == 'queued' then
            return false, 'already_queued', partyFor(src, contract, claim.owed_to)
        end
        if why == 'pay_only' then
            return false, 'pay_only', partyFor(src, contract, claim.owed_to)
        end
        if why == 'not_left' then return false, 'not_left' end
        return false, CH.ERR.LOCKED
    end

    -- A line whose give kept raising waits for exactly this: staff who have
    -- checked whether it already reached them. Its count starts again, so
    -- the release below tries it: in the release's own write once it has
    -- claimed the line (`unpark`), never before, so a raise in between
    -- leaves it still left for staff and listed. Every try is checked
    -- (Escrow.deliver): a give that raises after the item arrived settles
    -- the line, and one that raises before is counted afresh, so paying it
    -- gives it once. A part that already arrived stays on the line, and
    -- only the rest is given; with an amount, exactly that much (`give`).
    local unparked = parked or nil
    local who = callerCid(src)

    -- On the record, and the log written, before anything moves. Written
    -- after the release, a raise part-way through it (a lookup in
    -- Escrow.deliver, a dropped connection) left money given and nothing
    -- saying staff had settled it, or for how much. What came of it
    -- follows in admin_settle_result.
    Audit.financial('admin_settle_line', who, line.contract_id,
        { line = lineId, disposition = disposition, recipient = recipient,
          named_by_staff = owner and true or nil, unparked = unparked,
          amount = amount, owed = owed })
    logNow()

    -- Through the normal release path, filtered to this one line, so the
    -- compare-and-set and the never-destroy-property rules still apply, and
    -- checked again on the line as it claims it (`unpark`, the guard). A
    -- raise in it is logged, and a line it left `releasing` left for staff
    -- (settleRaised).
    local ran, raised, result = pcall(Escrow.release, line.contract_id, recipient,
        { line = lineId, unpark = unparked, ran = unparked and disposition == 'return' or nil,
          give = amount }, 'admin_' .. disposition,
        function(claimed) return not owedElsewhere(claimed) end)
    if not ran then return settleRaised(who, line, disposition, recipient, raised) end
    local settled = result.settled or 0
    local pending = result.pending or 0
    local again = result.parked or 0
    local requeued = result.requeued or 0

    -- What it actually gave, and what the line owed as it was claimed: the
    -- read above may be older than another settle that moved it since.
    Audit.financial('admin_settle_result', who, line.contract_id,
        { line = lineId, disposition = disposition, recipient = recipient,
          settled = settled, pending = pending, parked = again > 0 and again or nil,
          requeued = requeued > 0 and requeued or nil,
          refused = result.why or ((result.refused or 0) > 0 and 'owed_elsewhere') or nil,
          given = result.given, owed = result.owed })
    logNow()

    -- Queued is done: it is theirs, delivered at their next login. It was
    -- reported as "Could not settle it", so staff settled it again. A give
    -- that raised again left it for staff once more, which the release also
    -- counts as pending; called queued, staff waited for a login that gives
    -- nothing a line left for staff. One that raised with nothing arriving
    -- went back on the queue, and is said to have, rather than called
    -- queued for a player who is in the city. So is one refused to a player
    -- who is in the city (pockets full, an account that would not take it).
    if settled > 0 then return true, nil end
    if result.why == 'queued' then
        return false, 'already_queued', partyFor(src, contract, result.owed_to)
    end
    if result.why == 'pay_only' then
        return false, 'pay_only', partyFor(src, contract, result.owed_to)
    end
    if result.why == 'owes_less' then return false, 'owes_less', result.owed end
    if result.why == 'locked' then return false, CH.ERR.LOCKED end
    if result.why then return false, 'not_left' end
    if again > 0 then return false, 'parked' end
    if requeued > 0 then return true, 'requeued' end
    if pending > 0 then return true, 'queued', (result.away or 0) > 0 and 'away' or 'refused' end
    return false, CH.ERR.LOCKED
end

--------------------------------------------------------------------------
-- The review queue
--------------------------------------------------------------------------

--- An item's record as staff without the identity permission are shown it.
---
--- Copied, with every citizen id of a party the item names (its roles, and
--- whom a resolution gave to) put as that party's place on the contract,
--- wherever it is written: the resolution itself, what was known, a note.
--- Resolved on an anonymous contract, `resolution.cid` was the citizen id it
--- paid, and every reader of the history saw who was behind the party. And
--- no metadata: a weapon's `registered` is its owner's character name, which
--- Escrow strips from a weapon handed over for the same reason (handedOver).
---@param value any
---@param names table [cid] = how it is shown
local function shownWithout(value, names)
    if type(value) == 'string' then
        for cid, label in pairs(names) do
            value = value:gsub(cid:gsub('%W', '%%%0'), (label:gsub('%%', '%%%%')))
        end
        return value
    end
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, inner in pairs(value) do
        if k ~= 'metadata' then out[k] = shownWithout(inner, names) end
    end
    return out
end

--- The review queue as staff read it (server/review.lua): the open items,
--- or with `all` the latest ones resolved too.
---
--- Each names its parties by role, with who each is to staff who may see
--- that and the party's place on the contract to staff who may not, as
--- /ch-stuck names whom a line is owed to. A resolution takes the role, so
--- staff who may not see who is behind an anonymous party still settle one.
--- To staff who may not, nothing else in an item names anybody either
--- (shownWithout): /ch-review all and the panel's history print it as it
--- comes from here.
---@param src number|nil who is asking
---@param all boolean|nil
---@return table[] rows { id, kind, about, contract, parties = { { role, who } }, amount,
--- account, items, known, now, state, created_at, resolution, resolved_by, resolved_at,
--- unwritten }
function Admin.reviews(src, all)
    if not Review then return {} end
    local canIdentify = src == nil or src == 0
        or Admin.allowed(src, Config.Admin.IdentityAce, true)
    local contracts = {}
    local function contractOf(id)
        if not id then return nil end
        if contracts[id] == nil then
            local ok, found = pcall(Storage.readContract, id)
            contracts[id] = ok and found or false
        end
        return contracts[id] or nil
    end

    local out = {}
    for _, item in ipairs(Review.list(all, 50)) do
        local parties, roles, names = {}, {}, {}
        local contract = contractOf(item.contract_id)
        for role in pairs(type(item.cids) == 'table' and item.cids or {}) do roles[#roles + 1] = role end
        table.sort(roles)
        for _, role in ipairs(roles) do
            local cid = item.cids[role]
            if type(cid) == 'string' and cid ~= '' then names[cid] = Admin.partyRole(contract, cid) end
            parties[#parties + 1] = {
                role = role,
                who = canIdentify and cid or Admin.partyRole(contract, cid),
            }
        end
        local resolution = item.resolution
        local paid = type(resolution) == 'table' and resolution.cid or nil
        if type(paid) == 'string' and paid ~= '' and not names[paid] then
            names[paid] = Admin.partyRole(contract, paid)
        end
        local items, known = item.items, item.known
        if not canIdentify then
            items, known = shownWithout(items, names), shownWithout(known, names)
            resolution = shownWithout(resolution, names)
        end
        out[#out + 1] = {
            id = item.id, kind = item.kind, about = Review.KINDS[item.kind],
            contract = item.contract_id, parties = parties, amount = item.amount,
            account = item.account, items = items, known = known, now = item.now,
            state = item.state, created_at = item.created_at, resolution = resolution,
            resolved_by = item.resolved_by, resolved_at = item.resolved_at,
            unwritten = item.unwritten,
        }
    end
    Audit.staff(canIdentify and 'admin_review_identified' or 'admin_review', callerCid(src), nil,
        { items = #out, all = all or nil })
    return out
end

--- Resolve one review item (Review.resolve): `refund <cid|role> <amount>
--- [cash|bank|dirty]`, `refund <cid|role> items`, `pay <cid|role>`, or
--- `dismiss <note>`. Waits for boot recovery, as /ch-settle does: a
--- resolution moves money, and recovery may still be putting back a line an
--- earlier one left.
---@param src number
---@param id string
---@param args string[] the words after the id
---@return boolean ok
---@return string|nil err
---@return any detail
function Admin.resolveReview(src, id, args)
    local waiting = recovering()
    if waiting then return false, waiting end
    if not Review then return false, CH.ERR.NOT_FOUND end
    args = type(args) == 'table' and args or {}
    local action = type(args[1]) == 'string' and args[1]:lower() or nil
    local decision = { action = action }
    if action == 'dismiss' then
        decision.note = table.concat(args, ' ', 2)
    elseif action == 'pay' then
        decision.who = args[2]
    elseif action == 'refund' then
        decision.who = args[2]
        if type(args[3]) == 'string' and args[3]:lower() == 'items' then
            decision.goods = true
        else
            if type(args[3]) ~= 'string' or not args[3]:match('^%d+$') then
                return false, CH.ERR.INVALID_INPUT
            end
            decision.amount = tonumber(args[3])
            if args[4] ~= nil then
                local account = tostring(args[4]):lower()
                if not CH.MONEY_SOURCES[account] then return false, 'which_money' end
                decision.account = account
            end
        end
    else
        return false, CH.ERR.INVALID_INPUT
    end

    local who = callerCid(src) or (src == 0 and 'console') or ('player ' .. tostring(src))
    local ran, ok, err, detail = pcall(Review.resolve, id, decision, who)
    if not ran then
        -- Left `resolving`, with the decision on it: the next ask, or the
        -- next start, finishes it from the lines it already wrote.
        Audit.financial('review_resolve_raised', who, nil,
            { review = id, action = action, error = tostring(ok) })
        logNow()
        print(('[crimson-hitman] resolving review %s raised: %s'):format(tostring(id), tostring(ok)))
        return false, 'raised'
    end
    return ok, err, detail
end

--- Who is behind an anonymous party on a contract.
---
--- Gated by its own ACE and logged as its own audit row, because the point
--- of anonymity is that looking is exceptional. A staff member who cannot
--- justify the lookup should not make it, and the record is what makes that
--- reviewable.
---@return table|nil identities
---@return string|nil err
function Admin.identify(src, contractId)
    contractId = Util.toId(contractId)
    if not contractId then return nil, CH.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CH.ERR.NOT_FOUND end

    local hitmen = Storage.readHitmen(contractId)
    local operatives = {}
    for i = 1, #hitmen do
        operatives[#operatives + 1] = {
            alias = hitmen[i].alias,
            cid = hitmen[i].hitman_cid,
            name = hitmen[i].hitman_name,
            anonymous = hitmen[i].anon == true,
            state = hitmen[i].state,
        }
    end

    Audit.staff('admin_identify', callerCid(src), contractId,
        { anon_creator = contract.anon_creator == true, hitmen = #operatives })

    return {
        creator = { cid = contract.creator_cid, name = contract.creator_name,
                    anonymous = contract.anon_creator == true },
        target  = { cid = contract.target_cid, name = contract.target_name },
        hitmen = operatives,
    }
end

--------------------------------------------------------------------------
-- Diagnosis
--------------------------------------------------------------------------

--- A config switch, with its type when that is the thing that is wrong.
---
--- The app's own check is `== true`, which in Lua is an identity test: the
--- string "true" and the number 1 both switch item escrow off while a report
--- built from tostring() says "true" and looks completely healthy. A
--- diagnosis that can agree with a broken server is worse than none, and
--- this one could.
---@param value any
---@return string
local function describeSwitch(value)
    if type(value) == 'boolean' then return tostring(value) end
    if value == nil then return 'not set (reads as OFF)' end
    return ('%s (a %s, not a boolean — this reads as OFF)')
        :format(tostring(value), type(value))
end

--- Report why the app is not showing something.
---
--- Three separate causes have produced the same symptom on a live server —
--- an empty target list and an empty item picker — and none of them left
--- anything behind to look at: a setting an older config did not have, an
--- ox_inventory export that does not answer, and a rate limit the app's own
--- opening sequence spent before the player touched anything.
---
--- Every one of those was found by guessing. This asks the server instead.
---@param source number who ran it. 0 is the server console.
---@param subjectId number|string|nil a player id to run the player-specific
--- checks as. Defaults to the caller. The console has no character of its
--- own, so an owner running this there names somebody who is in the city.
---@param later fun(line: string)|nil where a check that has to wait for an
--- answer (whether the public photo address reaches this resource) says
--- what it found, after the report. Without it that check is not made.
---@return string[] lines
function Admin.diagnose(source, subjectId, later)
    local out = {}
    local function say(line) out[#out + 1] = line end

    say('--- crimson-hitman diagnosis ---')
    say(('storage: %s'):format(tostring(Config.Database.Mode)))

    -- How contracts are completed, server-wide and first: "my kill did not
    -- pay" has its whole answer here on a server that ships live transfer
    -- only, and everything about photos further down applies only where a
    -- kill can pay. Contracts placed before a switch keep their own rule,
    -- so the ones still running under the other are counted.
    local placing = Util.placingRule()
    local other = 0
    local okLive, live = pcall(Storage.liveContracts)
    for _, c in ipairs(okLive and live or {}) do
        if Util.fulfilmentRule(c) ~= placing then other = other + 1 end
    end
    -- Whether a kill photo can be taken at all: under 'alive' only while a
    -- contract placed under 'either' is still live. The photo section below
    -- gives no advice when none can, since every line of it is about
    -- setting up something nothing uses.
    local photosUsed = placing == CH.FULFILMENT_RULE.EITHER or other > 0
    -- Neither line below carries the '->' this report marks something to
    -- act on with: there is nothing to do about a setting that is unused.
    if placing == CH.FULFILMENT_RULE.ALIVE then
        say('completion: alive (Config.Completion.Fulfilment): live transfer only. A '
            .. 'contract is completed by a handover to the client; a kill never completes one')
        if other > 0 then
            say(('  the kill photo settings (Config.Completion.PhotoStorage and the other '
                .. 'Photo* settings, ExtraPhotoHosts, ProofWindowSeconds) and Config.Bonus are '
                .. 'not used by new contracts. %d live contract(s) were placed under \'either\' '
                .. 'and can still be completed by a kill until they end; those still use them.')
                :format(other))
        else
            say('  no kill photo is taken, so the kill photo settings '
                .. '(Config.Completion.PhotoStorage and the other Photo* settings, '
                .. 'ExtraPhotoHosts, ProofWindowSeconds) and Config.Bonus are not used, beyond '
                .. 'photos taken before and still waiting for or kept by their clients')
        end
    else
        say('completion: either (Config.Completion.Fulfilment): a kill, verified with a '
            .. 'photo, or a handover to the client completes a contract')
        if other > 0 then
            say(('  %d live contract(s) were placed under \'alive\' and are completed only by '
                .. 'a handover until they end'):format(other))
        end
    end

    -- Writes that did not read back as what was written.
    --
    -- The store prints the first three and then stops, deliberately, so a
    -- disk that is failing does not fill the console — which leaves an
    -- operator with no way to find out it is still happening. The counter
    -- was written for this report and the report never asked for it, so the
    -- comment above it described a behaviour that did not exist.
    local mismatched = Storage.readBackMismatches and Storage.readBackMismatches() or 0
    if mismatched > 0 then
        say(('  %d WRITE(S) READ BACK DIFFERENTLY.'):format(mismatched))
        say('    -> the engine accepted every one of them, so nothing is known '
            .. 'to be lost yet. If contracts stop surviving restarts, this is '
            .. 'the first thing to believe.')
    end

    -- Fulfilments waiting on a proof that has not arrived. A number that
    -- only grows is a completion path that is not completing.
    if Death and Death.pendingCount then
        local waiting = Death.pendingCount()
        if waiting > 0 then
            say(('  %d completion(s) waiting on proof.'):format(waiting))
        end
    end
    -- Hits on downed players kept for their death reports: a number that
    -- stays high is a client sending events at somebody on the ground.
    if Death and Death.keptDownHits then
        local kept = Death.keptDownHits()
        if kept > 0 then
            say(('  %d hit(s) on downed players kept for their death reports.'):format(kept))
        end
    end

    -- Contracts the store could not load. They are not on the board and
    -- their escrow cannot be returned automatically, so they belong at the
    -- top of any report about why something is missing.
    local held = Storage.quarantined and Storage.quarantined() or {}
    if #held > 0 then
        say(('  %d CONTRACT(S) COULD NOT BE LOADED:'):format(#held))
        for i = 1, #held do
            say(('    %s (%s)'):format(held[i].id, held[i].reason))
        end
        say('    -> restore those files from a backup and restart, or settle '
            .. 'them by hand and take their ids out of data/store.json')
    end

    -- Money no rule could settle, waiting for staff (server/review.lua).
    local reviewing = Review and Review.openCount() or 0
    if reviewing > 0 then
        say(('  %d MONEY EVENT(S) WAIT IN THE REVIEW QUEUE.'):format(reviewing))
        say(('    -> /%s lists them with what is known, and /%s resolves each')
            :format(tostring(Config.Admin.Commands.stuck), tostring(Config.Admin.Commands.review)))
    end

    -- Settings changed from the admin panel, which are in force over
    -- config.lua: an owner reading their config.lua and seeing one value
    -- while the server runs another needs to be told here.
    local active = Settings and Settings.active() or {}
    if #active > 0 then
        say(('admin panel settings in force over config.lua: %d'):format(#active))
        for _, row in ipairs(active) do
            say(('  %s = %s  (by %s, %s)%s'):format(row.key, Settings.describe(row.value),
                tostring(row.by or '?'), row.at and os.date('%Y-%m-%d %H:%M', row.at) or '?',
                row.ignored and ('  -> NOT APPLIED: ' .. row.ignored .. '; reset it in the panel')
                    or ''))
        end
    else
        say('admin panel settings: none; config.lua is in force as it stands')
    end

    -- Server-wide, so before the player checks, which can stop early.
    reportTiming(say)

    -- Who the player-specific checks run as.
    --
    -- This used to be the caller and only the caller, which made the whole
    -- command useless from the server console: console is source 0, resolves
    -- to nobody, and the report stopped at the second line. The console is
    -- also the one place an owner can always run it, ACE or not — so the one
    -- tool for "why is my app empty" was unreachable from the one place that
    -- never refuses. It takes a player id now.
    local subject = tonumber(subjectId) or (source ~= 0 and source or nil)

    local actor = subject and Identity.resolve(subject) or nil
    if not actor then
        if subjectId then
            say(('identity: player %s is not connected, or this server cannot '
                .. 'describe them.'):format(tostring(subjectId)))
        elseif source == 0 then
            say('identity: run from the console, which has no character of its own.')
        else
            say('identity: COULD NOT RESOLVE this player. Nothing else can work.')
        end
        say(('  -> name somebody who is in the city:  %s <playerid>')
            :format(tostring(Config.Admin.Commands.diagnose)))
        say('  the server-wide checks below still ran.')
    else
        say(('identity: %s (%s)'):format(tostring(actor.name), tostring(actor.cid)))
    end

    -- Targeting -----------------------------------------------------------
    say(('browse all: %s   nearby: %s   min query: %s'):format(
        tostring(Config.Targeting.AllowBrowseAll),
        tostring(Config.Targeting.AllowNearby),
        tostring(Config.Targeting.MinQueryLength)))

    local online = Identity.online()
    say(('online: %d player(s)'):format(#online))

    -- How many of them this resource could actually describe. A roster that
    -- is short because the framework could not read somebody is the exact
    -- symptom this command exists for, and it is invisible from the count
    -- alone.
    local connected = #(GetPlayers() or {})
    if connected > #online then
        say(('  -> %d of %d connected players could not be described by the '
            .. 'framework and are left out of every list'):format(
            connected - #online, connected))
    end

    local others = 0
    if actor then
        for i = 1, #online do
            local candidate = online[i]
            if candidate.cid ~= actor.cid
                and not Identity.sameAccount(candidate.account, actor.account) then
                others = others + 1
            end
        end
        say(('targetable by you: %d  (yourself and your own account are never listed)')
            :format(others))
    end

    -- An account this server cannot read used to exclude everybody, since
    -- two unknowns compared equal. Worth naming: it is invisible otherwise
    -- and it emptied the whole list.
    local unknown = 0
    for i = 1, #online do
        if online[i].account == nil then unknown = unknown + 1 end
    end
    if unknown > 0 then
        say(('  account unreadable for %d of %d online — check your server has '
            .. 'licence identifiers enabled'):format(unknown, #online))
    end

    if actor and others == 0 and #online > 0 then
        say('  -> the list is empty because everyone online shares your account, '
            .. 'or you are the only one here. Try with a second player.')
    end

    -- Inventory -----------------------------------------------------------
    if not actor then
        -- The config half is still worth saying: a server that has item
        -- escrow switched off shows an empty picker to everybody, and that
        -- is answerable without a player.
        local itemOff = Config.Sources.item or {}
        local weaponOff = Config.Sources.weapon or {}
        say(('item escrow: %s   weapon escrow: %s'):format(
            describeSwitch(itemOff.enabled), describeSwitch(weaponOff.enabled)))
        if itemOff.enabled ~= true or weaponOff.enabled ~= true then
            say('  -> the app tells players this server takes money only. If you '
                .. 'did not mean that, your config.lua predates '
                .. 'Config.Sources.item and .weapon.')
        end
        say('  name a player to test the ox_inventory reads themselves.')
        say('--- end ---')
        return out
    end

    local carried, readOk = App.readInventory(actor)
    local count = 0
    for _ in pairs(carried or {}) do count = count + 1 end

    say(('inventory read: %s'):format(
        readOk and tostring(App.inventorySource) or 'NO EXPORT ANSWERED'))
    say(('  slots seen: %d'):format(count))
    -- Read defensively: a config that never had these is exactly the case
    -- worth reporting, and a diagnosis that throws diagnoses nothing.
    local itemSource = Config.Sources.item or {}
    local weaponSource = Config.Sources.weapon or {}

    say(('  item escrow: %s   weapon escrow: %s'):format(
        describeSwitch(itemSource.enabled), describeSwitch(weaponSource.enabled)))
    if itemSource.enabled ~= true or weaponSource.enabled ~= true then
        say('  -> the app tells players this server takes money only. If you did '
            .. 'not mean that, your config.lua predates Config.Sources.item and '
            .. '.weapon.')
    end
    say(('  offerable to you: %d item(s), %d weapon(s)'):format(
        #App.escrowableItems(actor, carried), #App.escrowableWeapons(actor, carried)))
    if not readOk then
        say('  -> ox_inventory answered neither read. Items and weapons cannot be '
            .. 'offered; money still works.')
    elseif count == 0 then
        say('  -> you are carrying nothing. Pick something up and run this again.')
    end

    -- Death detection -----------------------------------------------------
    --
    -- An elimination pays only on a target this resource can see is dead.
    -- When nothing can answer that, isTrulyDead returns false for everybody
    -- and every photo of a genuine kill is refused as "the target was
    -- revived" — a kill that simply never works, with the fault two
    -- resources away and nothing naming it.
    local dead, lastStand, resolved, answeredBy = Identity.deathState(subject)
    if resolved then
        -- Which one answered: a medical resource's exports, or qbx_core's
        -- metadata. qbx_medical is always the second, since its IsDead and
        -- IsLaststand are client exports only.
        say(('death state: readable (dead=%s, last stand=%s), from %s')
            :format(tostring(dead), tostring(lastStand),
                answeredBy == 'metadata' and 'QBox metadata' or tostring(answeredBy)))
    else
        say('death state: NOTHING COULD ANSWER')
        say('  -> no configured death provider responded and this player has no '
            .. 'QBox metadata to fall back on. Eliminations cannot be verified: '
            .. 'every photo of a real kill is refused. Deliveries alive are '
            .. 'refused too, for the same reason.')
        local providers = {}
        for _, provider in ipairs(Config.Completion.DeathStateProviders or {}) do
            providers[#providers + 1] = ('%s(%s)')
                :format(provider.resource, tostring(GetResourceState(provider.resource)))
        end
        say(('  providers tried: %s'):format(
            #providers > 0 and table.concat(providers, ', ') or 'none configured'))
    end

    -- The gate ------------------------------------------------------------
    --
    -- Every request passes through it and nothing above tests it. Resolving
    -- a player is only its first step; the blocked-jobs check
    -- (Config.BlockedJobTypes / BlockedJobNames) is its second, and a player
    -- refused there has no app, or one that answers nothing, with no other
    -- symptom.
    local gateOk, gateActor, gateErr = pcall(Identity.gate, subject)
    if not gateOk then
        say(('gate: THREW  %s'):format(tostring(gateActor)))
        say('  -> every request from this player is refused. Nothing can work.')
    elseif not gateActor then
        say(('gate: REFUSES this player (%s)'):format(tostring(gateErr)))
        -- Which job, and which setting it matched. This used to name a
        -- Config.Blacklist that does not exist, and an admin who searched
        -- config.lua for it found only EscrowBlacklist, which is unrelated.
        local barredName, held
        if actor then barredName, held = Identity.barredBy(actor) end
        if barredName then
            -- barredBy names the job they are working by its label, and
            -- neither setting is keyed by label: they take the job's name
            -- and its type, so those are what is printed.
            local job = actor.job or {}
            if held then
                job = { name = barredName }
                for _, holding in ipairs(Identity.heldJobs(actor)) do
                    if holding.name == barredName then job = holding end
                end
            end
            local jobType = job.type and tostring(job.type):lower() or nil
            local jobName = job.name and tostring(job.name):lower() or nil
            -- In the order Identity.isBlockedJob checks them.
            local matched = 'Config.BlockedJobTypes or Config.BlockedJobNames'
            if jobType and Config.BlockedJobTypes[jobType] then
                matched = ('Config.BlockedJobTypes (%s)'):format(jobType)
            elseif jobName and Config.BlockedJobNames[jobName] then
                matched = ('Config.BlockedJobNames (%s)'):format(jobName)
            end
            say(('  -> barred by the %s job%s%s: it matches %s'):format(
                tostring(jobName or barredName),
                jobType and (' (type ' .. jobType .. ')') or '',
                held and ', which they hold but are not working' or '',
                matched))
            if Config.BlockOffDuty and (held or job.onduty == false) then
                say('     off duty still counts while Config.BlockOffDuty is on')
            end
            say('  -> ' .. (Config.HideAppFromBlockedJobs == false
                    and 'the app is installed but answers nothing for them'
                    or 'the app is hidden from their phone')
                .. ', by design. Nothing else below will look wrong.')
        end
    else
        say('gate: passes')
    end

    -- The handlers themselves ---------------------------------------------
    --
    -- Everything above reads what the handlers read. This runs them. The
    -- difference is not academic: a report can confirm every setting and
    -- every export a handler depends on and still miss the one line that
    -- throws, and then it says "healthy" about a server whose app shows
    -- nothing. Only the real call can answer whether the real call works.
    local probes = { 'list', 'mine', 'browseTargets', 'rewardOptions' }
    local payloads = {
        list = { page = 1 },
        browseTargets = { scope = 'all' },
    }

    say('handlers:')
    for i = 1, #probes do
        local probeName = probes[i]
        local fn = App and App.handlers and App.handlers[probeName]
        if not fn then
            say(('  %s: NOT REGISTERED'):format(probeName))
        else
            local ok, result, resultErr = pcall(fn, actor, payloads[probeName] or {})
            if not ok then
                -- The whole error, including where it threw. This is the
                -- line that was previously going nowhere an operator could
                -- reach: the player saw a shrug and the console said
                -- nothing at all.
                say(('  %s: THREW  %s'):format(probeName, tostring(result)))
            elseif result == false or result == nil then
                say(('  %s: refused (%s)'):format(probeName, tostring(resultErr)))
            else
                local size
                if type(result) == 'table' then
                    if result.people then size = ('%d people'):format(#result.people)
                    elseif result.contracts then size = ('%d contracts'):format(#result.contracts)
                    elseif result.items then size = ('%d items, %d weapons')
                        :format(#result.items, #(result.weapons or {}))
                    end
                end
                say(('  %s: ok%s'):format(probeName, size and ('  ' .. size) or ''))
            end
        end
    end

    -- Photo storage and hosts --------------------------------------------
    --
    -- Which of the two ways kill photos are taken and kept, because what to
    -- check next depends on it: the host allowlist only matters on 'host',
    -- and on 'server' a "no host allowed, every photo refused" line sent
    -- owners to fix an image host they do not use.
    --
    -- And none of it where no kill photo can be taken (photosUsed, above):
    -- it told an owner on the shipped 'alive' to set a public address or an
    -- upload host, right under the line saying those settings are unused.
    local storage = Photo and Photo.storage and Photo.storage() or 'server'
    if not photosUsed then
        say('photo settings: not used (live transfer only); nothing here needs setting up')
    elseif storage == 'host' then
        say('photo storage: host (lb-phone\'s camera uploads to the phone\'s image host; '
            .. 'this server keeps the link)')
    else
        say('photo storage: server (taken in the app and kept in data/photos; no image '
            .. 'host is used)')
    end
    -- How a photo kept on this server reaches the client's phone's Photos,
    -- which keeps links, never pictures. A link this server serves needs a
    -- public https address and lb-phone's own allow list to take it; with
    -- neither, the page uses lb-phone's upload if the phone has one, and
    -- otherwise keeps the photo in the app. Each line says which, so "my
    -- client could not save the photo" has an answer here.
    if photosUsed and storage == 'server' and Photos and Photos.publicBase then
        local base, from = Photos.publicBase()
        if base and type(GetPasswordHash) ~= 'function' then
            say(('photo links: none (this server build has no GetPasswordHash, so it cannot '
                .. 'make a link nobody can guess; %s is not used)'):format(base))
        elseif base then
            say(('photo links: %s/p/... (from %s)'):format(base, from))
            local allowed, host = Photos.galleryAllows(base .. '/p/x.webp')
            if allowed == true then
                say(('  lb-phone\'s upload allow list takes %s: yes'):format(host))
            elseif allowed == nil then
                say(('  could not read lb-phone\'s config to check that it takes %s. Make sure '
                    .. 'it is in Config.UploadWhitelistedHostnames in lb-phone\'s config.')
                    :format(host))
            else
                say(('  -> lb-phone\'s upload allow list does NOT take %s, so phones may refuse '
                    .. 'to save these photos. Add "%s" to Config.UploadWhitelistedHostnames in '
                    .. 'lb-phone\'s config.'):format(host, host))
            end
            -- Whether it leads here at all. Everything above can be right
            -- and every link still dead: no '/<resource>' on the address, a
            -- proxy that does not pass it on, a bad certificate. Asked of
            -- the address itself, and answered after this report.
            if later and Photos.checkReach then
                say('  checking that this address reaches this resource; the answer follows')
                local resource = GetCurrentResourceName()
                Photos.checkReach(base, function(reached, status, marked, err)
                    if reached then
                        later(('photo links: %s reaches this resource: yes'):format(base))
                    elseif status == 0 then
                        later(('photo links: -> this server could not load %s/p/... (%s). If '
                            .. 'phones cannot either, every photo saved to Photos by link is a '
                            .. 'broken picture. Check the address, its certificate and its DNS. '
                            .. 'Some networks cannot reach their own public address from inside, '
                            .. 'so try a link from a phone before changing anything.')
                            :format(base, err or 'no answer'))
                    else
                        later(('photo links: -> %s/p/... answered %d%s, not this resource, so '
                            .. 'every photo saved to Photos by link would be a broken picture. '
                            .. 'The address has to lead to this server\'s /%s/ (web_baseUrl, or '
                            .. 'Config.Completion.PhotoPublicUrl ending in /%s), and any proxy in '
                            .. 'front has to pass that path on.')
                            :format(base, status, marked and ' from this resource' or '',
                                resource, resource))
                    end
                end)
            end
        else
            say(('photo links: none (%s)'):format(tostring(from)))
            say('  -> photos saved to Photos go through lb-phone\'s own upload if the phone '
                .. 'has one, and are kept in the app if not. To serve them from this server '
                .. 'with no image host, set Config.Completion.PhotoPublicUrl or web_baseUrl '
                .. '(Qbox Nucleus: set web_baseUrl "<name>.server.qbox.re").')
        end
    end
    -- What the photos on disk come to: an owner who never hears from the
    -- kept ones would otherwise only find them by looking at the folder.
    if Photos and Photos.totals then
        local okTotals, totals = pcall(Photos.totals)
        okTotals = okTotals and type(totals) == 'table'
        if okTotals and ((photosUsed and storage == 'server')
                or totals.waiting.count + totals.kept.count + totals.served.count > 0) then
            local function size(bytes)
                return ('%.1f MB'):format((tonumber(bytes) or 0) / 1048576)
            end
            say(('photos on disk%s: %d waiting (%s), %d kept in the app (%s), %d served to '
                .. 'phones\' Photos (%s)'):format(photosUsed and '' or ' (taken before)',
                totals.waiting.count, size(totals.waiting.bytes),
                totals.kept.count, size(totals.kept.bytes),
                totals.served.count, size(totals.served.bytes)))
            if Config.Completion.KeptPhotoDays then
                say(('  kept photos are deleted after %s day(s) (Config.Completion.KeptPhotoDays)')
                    :format(tostring(Config.Completion.KeptPhotoDays)))
            elseif totals.kept.count > 0 then
                say('  kept photos stay until their owner deletes them; '
                    .. 'Config.Completion.KeptPhotoDays puts a limit on that')
            end
        end
    end
    if photosUsed and storage == 'host' and Photo and Photo.allowedHosts then
        local okHosts, hosts = pcall(Photo.allowedHosts)
        hosts = okHosts and type(hosts) == 'table' and hosts or {}
        say(('photo hosts: %d%s'):format(#hosts,
            #hosts > 0 and (' (' .. table.concat(hosts, ', ') .. ')') or ''))
        if #hosts == 0 then
            say('  -> no upload host is allowed: every kill photo will be refused. Add the '
                .. 'phone\'s image host to Config.Completion.ExtraPhotoHosts (for Fivemanage: '
                .. 'fivemanage.com, fmfile.com)')
        end
    end

    -- Rate limits ---------------------------------------------------------
    -- Checked last and reported without spending anything a caller needs:
    -- a diagnosis that exhausts the bucket it is diagnosing is no use.
    -- Every bucket, not the three the app opens with. A player reporting
    -- that most buttons say "slow down" is describing the buckets behind
    -- the buttons, and those were the ones this never printed — so the
    -- report agreed the server was fine while every action a player took
    -- was being refused by a rule nobody could see.
    local buckets = { 'load', 'search', 'wallet', 'create', 'accept', 'amend',
                      'informant', 'bailout', 'photo', 'photoSubmit', 'photoView',
                      'photoDecide', 'message',
                      'progress', 'death', 'mugshot', 'image', 'diagnostic' }
    local parts, missing = {}, 0
    for i = 1, #buckets do
        local rule = Config.Cooldowns[buckets[i]]
        if not rule then missing = missing + 1 end
        -- %s, not %d: a rule of half a second is a real setting, and %d
        -- threw on it and took the whole diagnosis down with it.
        parts[#parts + 1] = ('%s=%s'):format(buckets[i],
            type(rule) == 'table' and ('%s/%ss'):format(tostring(rule.burst), tostring(rule.per))
                or 'MISSING')
    end
    say(('rate limits: %s'):format(table.concat(parts, '  ')))
    if missing > 0 then
        say(('  -> %d bucket(s) your config does not set; those actions fall '
            .. 'back to %s/%ss, which may be stricter or looser than intended')
            :format(missing, RateLimit and RateLimit.FALLBACK.burst or 10,
                    RateLimit and RateLimit.FALLBACK.per or 10))
    end
    say(('  keyed on: %s'):format(tostring(Config.RateLimit.Key)))

    if Config.Debug then
        say('debug: ON — page faults print their full stack to this console. '
            .. 'Leave it off on a busy server; the reports are recorded either way.')
    end

    -- What the app itself has reported.
    --
    -- Everything above this line is the server's view. The app runs in a
    -- browser on the player's machine, where nothing was ever visible from
    -- here: a page that threw on every render looked, from the server, like
    -- a player who had stopped using the app. These are the faults the page
    -- caught and sent back.
    local faults = App and App.recentPageFaults and App.recentPageFaults() or {}
    if #faults == 0 then
        say('app faults: none reported by any player\'s page this session.')
    else
        say(('app faults: %d reported by players\' pages, newest first:')
            :format(#faults))
        for i = 1, math.min(#faults, 5) do
            local fault = faults[i]
            say(('  %s  %s  build %s  %s'):format(
                os.date('%H:%M:%S', fault.at), fault.cid or 'unknown',
                fault.build or '?', fault.what))
            if fault.where then say(('      at %s'):format(fault.where)) end
        end
        say('  -> a fault here is a bug in this resource, not in the player\'s '
            .. 'game. The build number says which copy of the page they are '
            .. 'running, which is the first thing to check.')
    end

    -- And ask the named player's open app what it has seen.
    --
    -- Everything above is what the page has already volunteered. This asks
    -- for the rest: the requests it made, what came back, and anything it
    -- caught. The answer does not arrive in this report — it comes back
    -- through the ordinary reporting path a moment later and lands in the
    -- console and the audit log — so the report says so rather than leaving
    -- a reader waiting for something that is not coming.
    if subject then
        if App and App.expectDump then App.expectDump(subject) end
        TriggerClientEvent('crimson-hitman:askDiagnostics', subject)
        say(('  asked player %s\'s app for its own log; if it is open, the '
            .. 'answer follows in this console within a second or two.')
            :format(tostring(subject)))
    end

    say('--- end ---')
    return out
end

--------------------------------------------------------------------------
-- Testing
--------------------------------------------------------------------------

--- Bring every wait in the resource forward to now.
---
--- Testing this app means waiting. A slot cooldown is ten minutes, a target
--- cannot be re-listed for thirty, the same creator cannot re-list them for
--- two hours, a headshot will not re-render for five, and a rate-limit
--- bucket that has just been spent takes its full window back. None of that
--- is wrong on a live server and all of it makes a test server unusable:
--- the person checking whether their config works spends the afternoon
--- watching clocks instead.
---
--- So this ages every one of those gates past its window rather than
--- disabling any of them. What it deliberately does NOT touch:
---
---   * limits that are counts, not waits — informant purchases per
---     contract, slots per hitman. Those are the rules being tested.
---   * countdowns in progress. A kidnap countdown is a hold on a live
---     player and finishing one from a console is a delivery the hitman
---     did not make.
---   * anything a contract's escrow depends on. Deadlines are extended,
---     never brought forward: this must not be able to resolve a contract
---     and move money.
---
--- Every run is written to the audit log. A server where somebody quietly
--- reset the cooldowns is a server whose history stops explaining itself.
---@param src number
---@return string[] lines
function Admin.refreshTimers(src)
    local now = os.time()
    local counts = {}

    counts.buckets = RateLimit and RateLimit.resetAll() or 0
    counts.flood = App and App.resetFloodCounters() or 0
    counts.informant = Informant and Informant.expireRerollLocks() or 0
    counts.rearm = Kidnap and Kidnap.clearRearmCooldowns() or 0
    counts.mugshots = Mugshot and Mugshot.clearRefreshFloor() or 0
    counts.respawn = Death and Death.clearRespawnImmunity() or 0
    counts.sessions = Identity.ageSessions()

    -- How far back a resolved contract has to be moved for every cooldown
    -- keyed on it to have lapsed. The longest of them, plus a second, so
    -- the comparison is past the boundary rather than exactly on it.
    local back = math.max(
        tonumber(Config.Limits.TargetCooldownAfterResolveSeconds) or 0,
        tonumber(Config.Limits.SameCreatorSameTargetCooldownSeconds) or 0,
        tonumber(Config.Amendments.CancelCooldownSeconds) or 0,
        tonumber(Config.Immunity.AfterBailoutSeconds) or 0) + 1

    counts.deadlines, counts.resolved, counts.slots, counts.proposals = 0, 0, 0, 0

    local contracts = Storage.allContracts()
    for i = 1, #contracts do
        -- As it stands now, not as the list had it (see below). One gone
        -- since has nothing left to refresh.
        local contract = Storage.readContract(contracts[i].id) or {}
        local live = contract.state == CH.STATE.ACTIVE
            or contract.state == CH.STATE.ACCEPTED
            or contract.state == CH.STATE.COMPLETING

        if live then
            -- Column by column, each against the row as it is now. The row
            -- was read a pass ago, and every store call since is a yield on
            -- mysql: writing it back whole put back whatever a claim, a
            -- buyout or an amendment had changed in the meantime, a
            -- contract settled a moment before live again among them.
            --
            -- The lifetime first: the deadline is clamped to it, so setting
            -- the deadline against a stale ceiling would clamp it straight
            -- back to the value being refreshed.
            --
            -- Only ever later. Both were set to now plus the defaults, so a
            -- deadline the client had extended to forty hours came back to
            -- three, and the expiry that followed forfeited the hitman's
            -- stake to the creator: a console command moving money, which
            -- is the one thing this must not do.
            local lifetime = now + (tonumber(Config.Limits.ContractLifetimeSeconds) or 0)
            if (contract.expires_at or 0) < lifetime then
                Storage.setContractFields(contract.id, { expires_at = lifetime })
            end

            -- A running pause is banked, then ended, by its own write. Left
            -- running it would be paid out as an extension on top of the
            -- deadline granted here; dropped, the time it had banked went
            -- with it.
            local fresh = Storage.readContract(contract.id)
            local since = fresh and fresh.paused_since
            if since then
                Storage.endPause(contract.id, since, math.max(0, now - since))
            end

            local default = now + (tonumber(Config.Limits.DefaultDeadlineSeconds) or 0)
            Contracts.moveDeadline(contract.id, function(current)
                local target = math.min(default, current.expires_at or default)
                return math.max(current.deadline_at or 0, target)
            end)
            counts.deadlines = counts.deadlines + 1

            local hitmen = Storage.readHitmen(contract.id)
            for h = 1, #hitmen do
                local hitman = hitmen[h]
                if hitman.last_claim_at then
                    Storage.updateHitman(hitman.id, {
                        last_claim_at = now - ((tonumber(Config.Limits.SlotCooldownSeconds) or 0) + 1),
                    })
                    counts.slots = counts.slots + 1
                end
            end

            local open = Storage.readOpenAmendments(contract.id)
            for a = 1, #open do
                -- Re-read, for the same reason: one answered while the
                -- proposals before it were written would be put back open.
                local proposal = Storage.readAmendment(open[a].id)
                if proposal and proposal.outcome == 'open' then
                    proposal.expires_at = now + (tonumber(Config.Amendments.ProposalExpirySeconds) or 0)
                    Storage.writeAmendment(proposal)
                    counts.proposals = counts.proposals + 1
                end
            end
        elseif contract.resolved_at then
            -- The one field, not the row read a pass ago.
            Storage.setContractFields(contract.id, { resolved_at = now - back })
            counts.resolved = counts.resolved + 1
        end
    end

    -- The expiry pass caches the soonest deadline it needs to wake for. It
    -- was computed against the old ones, so without this the next pass is
    -- skipped and the refresh looks like it did nothing.
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end

    Audit.staff('admin_timers_refreshed', callerCid(src), nil, counts)
    Audit.flush()

    return {
        ('Timers refreshed. %d rate-limit bucket(s) and %d flood counter(s) cleared.')
            :format(counts.buckets, counts.flood),
        ('%d live contract(s) given a full deadline and lifetime; %d slot cooldown(s) '
            .. 'and %d amendment proposal(s) refreshed.')
            :format(counts.deadlines, counts.slots, counts.proposals),
        ('%d resolved contract(s) aged past every re-list cooldown (%ds).')
            :format(counts.resolved, back),
        ('%d informant reroll lock(s), %d handover re-arm cooldown(s), %d headshot '
            .. 'refresh floor(s), %d respawn immunity window(s) and %d new-player '
            .. 'session window(s) cleared.')
            :format(counts.informant, counts.rearm, counts.mugshots, counts.respawn,
                    counts.sessions),
        ('The one wait left is total playtime (%s hours), which is read from your '
            .. 'framework and is not this resource\'s to move.')
            :format(tostring(Config.Immunity.MinTargetPlaytimeHours)),
        'Purchase and slot COUNTS are untouched, and no countdown was advanced.',
    }
end

return Admin
