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

local Storage, Identity, Contracts, Escrow, Audit, Notify

function Admin.init(deps)
    Storage, Identity, Contracts, Escrow, Audit, Notify =
        deps.storage, deps.identity, deps.contracts, deps.escrow, deps.audit, deps.notify
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
function Admin.allowed(src, ace)
    if src == 0 then return true end
    if IsPlayerAceAllowed(src, ace) == true then return true end

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
    return ('Not authorised. Add this to server.cfg and restart, or paste it '
        .. 'into the server console:  add_ace group.admin %s allow'):format(ace)
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

--- Escrow lines that were mid-release when the server stopped.
---
--- Recovery returns these to `held` rather than leaving them unreachable,
--- which means they may have been paid already. Only a person can tell.
---@return table[] lines
function Admin.interrupted()
    Audit.flush()

    local out = {}
    local contracts = Storage.allContracts()

    for i = 1, #contracts do
        local rows = Storage.auditForContract(contracts[i].id, Config.Admin.TimelineRows) or {}
        for j = 1, #rows do
            local detail = rows[j].detail or {}
            if rows[j].action == 'release_interrupted' and detail.line then
                local line = Storage.readEscrowLine(detail.line)
                -- Only still-open ones: a line settled since is not a
                -- question anybody needs to answer.
                if line and line.state ~= CB.ESCROW_STATE.SETTLED then
                    out[#out + 1] = {
                        line = detail.line,
                        contract = contracts[i].id,
                        amount = line.amount,
                        source = line.source,
                        item = line.item,
                        portion = line.portion,
                        intended = rows[j].actor_cid,
                        at = rows[j].ts,
                    }
                end
            end
        end
    end

    return out
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

    local ok, err = Contracts.resolve(contractId, CB.STATE.CANCELLED,
        contract.creator_cid, nil, 'voided_by_staff')
    if not ok then return false, err end

    Audit.financial('admin_void', callerCid(src), contractId,
        { reason = Util.sanitizeText(reason, 120) or 'none given' })

    Notify.toCitizen(contract.creator_cid, 'Contract voided',
        'Staff closed your contract. Your escrow has been returned.')

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
    local recipient = disposition == 'pay'
        and (line.owed_to or line.releasing_to or line.settled_to)
        or contract.creator_cid
    if not recipient then return false, CB.ERR.INVALID_INPUT end

    -- Through the normal release path, filtered to this one line, so the
    -- compare-and-set and the never-destroy-property rules still apply.
    local _, result = Escrow.release(line.contract_id, recipient,
        { line = lineId }, 'admin_' .. disposition)

    Audit.financial('admin_settle_line', callerCid(src), line.contract_id,
        { line = lineId, disposition = disposition, recipient = recipient,
          settled = result and result.settled or 0 })

    return (result and result.settled or 0) > 0, nil
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

    Audit.action('admin_identify', callerCid(src), contractId,
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

--- Report why the app is not showing something.
---
--- Three separate causes have produced the same symptom on a live server —
--- an empty target list and an empty item picker — and none of them left
--- anything behind to look at: a setting an older config did not have, an
--- ox_inventory export that does not answer, and a rate limit the app's own
--- opening sequence spent before the player touched anything.
---
--- Every one of those was found by guessing. This asks the server instead.
---@param source number the player to run the checks as
---@return string[] lines
function Admin.diagnose(source)
    local out = {}
    local function say(line) out[#out + 1] = line end

    say('--- crimson-bounty diagnosis ---')
    say(('storage: %s'):format(tostring(Config.Database.Mode)))

    local actor = Identity.resolve(source)
    if not actor then
        say('identity: COULD NOT RESOLVE this player. Nothing else can work.')
        return out
    end
    say(('identity: %s (%s)'):format(tostring(actor.name), tostring(actor.cid)))

    -- Targeting -----------------------------------------------------------
    say(('browse all: %s   nearby: %s   min query: %s'):format(
        tostring(Config.Targeting.AllowBrowseAll),
        tostring(Config.Targeting.AllowNearby),
        tostring(Config.Targeting.MinQueryLength)))

    local online = Identity.online()
    say(('online: %d player(s)'):format(#online))
    local others = 0
    for i = 1, #online do
        local candidate = online[i]
        if candidate.cid ~= actor.cid
            and not Identity.sameAccount(candidate.account, actor.account) then
            others = others + 1
        end
    end
    say(('targetable by you: %d  (yourself and your own account are never listed)')
        :format(others))

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

    if others == 0 and #online > 0 then
        say('  -> the list is empty because everyone online shares your account, '
            .. 'or you are the only one here. Try with a second player.')
    end

    -- Inventory -----------------------------------------------------------
    local App = require('server.app')
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
        tostring(itemSource.enabled), tostring(weaponSource.enabled)))
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

    -- Rate limits ---------------------------------------------------------
    -- Checked last and reported without spending anything a caller needs:
    -- a diagnosis that exhausts the bucket it is diagnosing is no use.
    local buckets = { 'load', 'search', 'wallet' }
    local parts = {}
    for i = 1, #buckets do
        local rule = Config.Cooldowns[buckets[i]]
        parts[#parts + 1] = ('%s=%s'):format(buckets[i],
            rule and ('%d/%ds'):format(rule.burst, rule.per) or 'MISSING')
    end
    say(('rate limits: %s'):format(table.concat(parts, '  ')))
    say(('  keyed on: %s'):format(tostring(Config.RateLimit.Key)))

    say('--- end ---')
    return out
end

return Admin
