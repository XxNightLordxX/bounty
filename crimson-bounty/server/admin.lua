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

local Util = require_shared('util')

local Admin = {}

local Storage, Identity, Contracts, Escrow, Audit, Notify, App, RateLimit, Death, Photo
local Informant, Kidnap, Mugshot

function Admin.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
    -- Optional, and only for its counters: the diagnosis reports how many
    -- completions are waiting on proof, which is otherwise invisible.
    Death = deps.death
    -- And the photo allowlist, which the diagnosis reports: an empty one
    -- refuses every kill photo, and nothing else on the report said so.
    Photo = deps.photo

    -- Taken from the wiring like every other collaborator, rather than
    -- required here. `require('server.app')` and the path the rest of the
    -- suite loads it by are different keys for the same file, so requiring
    -- it again hands back a SECOND copy of the module — one whose handler
    -- table nothing ever registered into. The diagnosis would then report
    -- every handler as unregistered while the real ones worked, which is a
    -- diagnosis lying in the other direction.
    App = deps.app
    RateLimit = deps.ratelimit

    -- Only the timer refresh needs these, and only to age their clocks.
    Informant, Kidnap, Mugshot = deps.informant, deps.kidnap, deps.mugshot
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
    if IsPlayerAceAllowed(src, ace) == true then return true end
    if strict then return false end

    -- Nobody holds crimson.admin until somebody grants it, and the first
    -- thing an owner needs is the command that says why their app is
    -- empty. An ACE their admin group already carries opens the same door.
    for _, extra in ipairs(Config.Admin.ExtraAces or {}) do
        if IsPlayerAceAllowed(src, extra) == true then return true end
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
    if not contractId then return nil, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CB.ERR.NOT_FOUND end

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
        hunters = Storage.readHunters(contractId),
        events = rows,
    }
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
function Admin.interrupted(src)
    Audit.flush()

    local canIdentify = src == nil or src == 0
        or Admin.allowed(src, Config.Admin.IdentityAce, true)
    local rows = Storage.auditByAction('release_interrupted', 1000) or {}
    local out, seen, contracts = {}, {}, {}

    for i = #rows, 1, -1 do
        local row = rows[i]
        local detail = row.detail or {}
        local lineId = detail.line
        -- The newest row for a line is the one that counts.
        if lineId and not seen[lineId] then
            seen[lineId] = true
            local line = Storage.readEscrowLine(lineId)
            -- Only still-open ones: a line settled since is not a question
            -- anybody needs to answer.
            if line and line.state ~= CB.ESCROW_STATE.SETTLED then
                local contractId = line.contract_id or row.contract_id
                local contract = contracts[contractId]
                if contract == nil then
                    contract = Storage.readContract(contractId) or false
                    contracts[contractId] = contract
                end
                local intended = row.actor_cid
                if not canIdentify then
                    intended = Admin.partyRole(contract or nil, intended)
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
                }
            end
        end
    end

    Audit.staff(canIdentify and 'admin_stuck_identified' or 'admin_stuck', callerCid(src), nil,
        { lines = #out })
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

--- Close a contract and return everything to the creator.
---
--- Routed through Contracts.resolve like every other ending, so stakes
--- settle, the remainder returns and the parties are told. A staff void is
--- not a special case in the money paths and must never become one.
---@return boolean ok
---@return string|nil err
function Admin.void(src, contractId, reason)
    contractId = Util.toId(contractId)
    if not contractId then return false, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return false, CB.ERR.NOT_FOUND end
    if CB.TERMINAL[contract.state] then return false, CB.ERR.ALREADY_SETTLED end

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
    -- creator in full and the hunters still get their stakes.
    local ok, err = Contracts.resolve(contractId, CB.STATE.VOIDED,
        contract.creator_cid, nil, 'voided_by_staff')
    if not ok then return false, err end

    Audit.financial('admin_void', callerCid(src), contractId,
        { reason = Util.sanitizeText(reason, 120) or 'none given' })

    Notify.toCitizen(contract.creator_cid, 'Contract voided',
        'Staff closed your contract. Your escrow has been returned.',
        { bypassBudget = true })

    return true
end

--- Settle one interrupted line deliberately: either to the person it was
--- being paid to, or back to the contract's creator.
---@param disposition string 'pay' | 'return'
---@return boolean ok
---@return string|nil err
function Admin.settleLine(src, lineId, disposition)
    lineId = Util.toLineId(lineId)
    if not lineId then return false, CB.ERR.INVALID_INPUT end
    if disposition ~= 'pay' and disposition ~= 'return' then
        return false, CB.ERR.INVALID_INPUT
    end

    local line = Storage.readEscrowLine(lineId)
    if not line then return false, CB.ERR.NOT_FOUND end
    if line.state == CB.ESCROW_STATE.SETTLED then return false, CB.ERR.ALREADY_SETTLED end

    local contract = Storage.readContract(line.contract_id)
    if not contract then return false, CB.ERR.NOT_FOUND end

    -- Who it goes to. `settled_to` is who the interrupted release was
    -- paying; without one there is nobody to pay and it can only go back.
    -- `releasing_to` is written before the money moves, so a line caught
    -- mid-release at a shutdown still names who it was going to.
    --
    -- Pay goes to whom the interrupted release was paying, as the log
    -- recorded it when it was interrupted. owed_to and releasing_to are
    -- rewritten by every later release, so a 'return' that queued for an
    -- offline creator made a 'pay' after it go to the creator too.
    --
    -- Return goes to whoever put the line up. A stake is the hunter's own
    -- money: returned "to the creator", an interrupted stake was handed to
    -- the one party it was never theirs to take. A line owed to somebody
    -- has no payer this can name.
    local recipient
    if disposition == 'pay' then
        local recorded
        local rows = Storage.auditByAction('release_interrupted', 1000) or {}
        for i = #rows, 1, -1 do
            if (rows[i].detail or {}).line == lineId then recorded = rows[i].actor_cid; break end
        end
        recipient = recorded or line.owed_to or line.releasing_to or line.settled_to
    elseif line.portion == CB.PORTION.STAKE then
        recipient = line.staker
    elseif line.portion == CB.PORTION.OWED then
        return false, CB.ERR.INVALID_INPUT
    else
        recipient = contract.creator_cid
    end
    if not recipient then return false, CB.ERR.INVALID_INPUT end

    -- Already queued for somebody by an earlier settle: settling it again
    -- to somebody else would take it off them.
    if line.owed_to and line.owed_to ~= recipient then return false, CB.ERR.LOCKED end

    -- Through the normal release path, filtered to this one line, so the
    -- compare-and-set and the never-destroy-property rules still apply.
    local _, result = Escrow.release(line.contract_id, recipient,
        { line = lineId }, 'admin_' .. disposition)
    local settled = result and result.settled or 0
    local pending = result and result.pending or 0

    Audit.financial('admin_settle_line', callerCid(src), line.contract_id,
        { line = lineId, disposition = disposition, recipient = recipient,
          settled = settled, pending = pending })

    -- Queued is done: it is theirs, delivered at their next login. It was
    -- reported as "Could not settle it", so staff settled it again.
    if settled > 0 then return true, nil end
    if pending > 0 then return true, 'queued' end
    return false, CB.ERR.LOCKED
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
    if not contractId then return nil, CB.ERR.INVALID_INPUT end

    local contract = Storage.readContract(contractId)
    if not contract then return nil, CB.ERR.NOT_FOUND end

    local hunters = Storage.readHunters(contractId)
    local operatives = {}
    for i = 1, #hunters do
        operatives[#operatives + 1] = {
            alias = hunters[i].alias,
            cid = hunters[i].hunter_cid,
            name = hunters[i].hunter_name,
            anonymous = hunters[i].anon == true,
            state = hunters[i].state,
        }
    end

    Audit.staff('admin_identify', callerCid(src), contractId,
        { anon_creator = contract.anon_creator == true, hunters = #operatives })

    return {
        creator = { cid = contract.creator_cid, name = contract.creator_name,
                    anonymous = contract.anon_creator == true },
        target  = { cid = contract.target_cid, name = contract.target_name },
        hunters = operatives,
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
---@return string[] lines
function Admin.diagnose(source, subjectId)
    local out = {}
    local function say(line) out[#out + 1] = line end

    say('--- crimson-bounty diagnosis ---')
    say(('storage: %s'):format(tostring(Config.Database.Mode)))

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
    local dead, lastStand, resolved = Identity.deathState(subject)
    if resolved then
        say(('death state: readable (dead=%s, last stand=%s)')
            :format(tostring(dead), tostring(lastStand)))
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
    -- a player is only its first step; the job blacklist is its second, and
    -- a player refused there gets an empty app with no other symptom.
    local gateOk, gateActor, gateErr = pcall(Identity.gate, subject)
    if not gateOk then
        say(('gate: THREW  %s'):format(tostring(gateActor)))
        say('  -> every request from this player is refused. Nothing can work.')
    elseif not gateActor then
        say(('gate: REFUSES this player (%s)'):format(tostring(gateErr)))
        say('  -> their job is on Config.Blacklist, so the app is empty for them '
            .. 'by design. Nothing else below will look wrong.')
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

    -- Photo hosts ---------------------------------------------------------
    if Photo and Photo.allowedHosts then
        local okHosts, hosts = pcall(Photo.allowedHosts)
        hosts = okHosts and type(hosts) == 'table' and hosts or {}
        say(('photo hosts: %d%s'):format(#hosts,
            #hosts > 0 and (' (' .. table.concat(hosts, ', ') .. ')') or ''))
        if #hosts == 0 then
            say('  -> no upload host is allowed: every kill photo will be refused. Check '
                .. 'lb-phone\'s upload config or set Config.Completion.ExtraPhotoHosts')
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
                      'informant', 'bailout', 'photo', 'photoSubmit', 'message',
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
        TriggerClientEvent('crimson-bounty:askDiagnostics', subject)
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
---     contract, slots per hunter. Those are the rules being tested.
---   * countdowns in progress. A kidnap countdown is a hold on a live
---     player and finishing one from a console is a delivery the hunter
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
        local contract = contracts[i]
        local live = contract.state == CB.STATE.ACTIVE
            or contract.state == CB.STATE.ACCEPTED
            or contract.state == CB.STATE.COMPLETING

        if live then
            -- The lifetime first: the deadline is clamped to it, so setting
            -- the deadline against a stale ceiling would clamp it straight
            -- back to the value being refreshed.
            --
            -- Only ever later. Both were set to now plus the defaults, so a
            -- deadline the client had extended to forty hours came back to
            -- three, and the expiry that followed forfeited the hunter's
            -- stake to the creator: a console command moving money, which
            -- is the one thing this must not do. A paused deadline counts
            -- with the pause it has banked, since clearing the pause below
            -- would otherwise take that time away.
            contract.expires_at = math.max(contract.expires_at or 0,
                now + (tonumber(Config.Limits.ContractLifetimeSeconds) or 0))
            local standing = contract.deadline_at or 0
            if contract.paused_since and contract.deadline_at then
                standing = contract.deadline_at + math.max(0, now - contract.paused_since)
            end
            local deadline = math.max(standing, now + (tonumber(Config.Limits.DefaultDeadlineSeconds) or 0))
            if deadline > contract.expires_at then deadline = contract.expires_at end
            contract.deadline_at = deadline
            -- A pause that began before the refresh would be paid out as an
            -- extension on top of the deadline just granted.
            contract.paused_since = nil
            Storage.writeContract(contract)
            -- The clock moves only through its own writes.
            Storage.resetClock(contract.id, deadline)
            counts.deadlines = counts.deadlines + 1

            local hunters = Storage.readHunters(contract.id)
            for h = 1, #hunters do
                local hunter = hunters[h]
                if hunter.last_claim_at then
                    Storage.updateHunter(hunter.id, {
                        last_claim_at = now - ((tonumber(Config.Limits.SlotCooldownSeconds) or 0) + 1),
                    })
                    counts.slots = counts.slots + 1
                end
            end

            local open = Storage.readOpenAmendments(contract.id)
            for a = 1, #open do
                local proposal = open[a]
                proposal.expires_at = now + (tonumber(Config.Amendments.ProposalExpirySeconds) or 0)
                Storage.writeAmendment(proposal)
                counts.proposals = counts.proposals + 1
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
