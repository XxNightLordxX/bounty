--- The review queue: money no rule here can settle by itself.
---
--- Some money events end in a question nothing can answer safely without a
--- person looking: a buyout charged whose record the store would neither
--- take nor read back, a refund that reached nobody, escrow taken whose
--- write could not be confirmed, a payout handed over that something else
--- then settled as well. Each used to leave an audit row and nothing else,
--- and audit rows are pruned after Config.Audit.RetentionDays: a question
--- nobody had answered by then was gone, and the money in it with it.
---
--- Each is an item here instead, kept in every storage mode until staff
--- resolve it: who was involved, how much or which goods, what could be
--- told (what arrived, the error), and once resolved how, by whom and when.
--- /ch-stuck lists the open ones and /ch-review resolves one.
---
--- A resolution that gives anything gives it the way every payout here
--- does: an escrow line owed to whom staff named, under an id that comes
--- from the item, handed over by Escrow.release (Util.credit and
--- ox_inventory, with their raise handling; owed at the next login to
--- somebody away; left for staff in /ch-stuck if a give raises without
--- telling what arrived). So it is given at most once however often it is
--- asked for: a second ask finds the item resolved, and a crash part-way
--- leaves it `resolving` with the decision written on it, which the next
--- ask or the next start finishes from the lines it already wrote.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Review = {}

local Storage, Escrow, Audit

Review.STATE = { OPEN = 'open', RESOLVING = 'resolving', RESOLVED = 'resolved' }

--- What each kind of item is, said to staff beside it, and what settles it.
Review.KINDS = {
    bailout_unrecorded = 'a buyout was charged, and the store would neither record it nor say '
        .. 'whether it had: if the contract shows the buyout (queued or bought out), dismiss; '
        .. 'if not, refund the payer',
    bailout_refund_stranded = 'a buyout premium handed back reached nobody: refund the payer '
        .. 'what did not arrive',
    owe_id_exhausted = 'money owed to a player could not be put on the books (the store had no '
        .. 'line id left): pay them',
    anonymity_fee_refund_failed = 'an anonymity fee owed back could not be credited: refund '
        .. 'what did not arrive',
    escrow_take_unverified = 'escrow was taken and the store would not say whether it was '
        .. 'written: lines the store has now are held or handed back already, so refund only '
        .. 'what it does not have',
    escrow_take_raised = 'taking a line of escrow raised, so whether it left the player is not '
        .. 'known: check what they have, and refund it if it left them',
    escrow_rollback_failed = 'escrow taken for a contract that was not placed could not be given '
        .. 'back: refund what did not arrive',
    contract_unrecorded = 'a contract\'s escrow was taken, and the store would neither write the '
        .. 'contract nor say whether it had: its escrow is handed back by the server, so refund '
        .. 'only the anonymity fee, if one was taken, where the contract does not exist',
    escrow_settle_lost = 'a payout reached its recipient, and something else settled its line as '
        .. 'well: check nobody was paid it twice, then dismiss',
}

--- Items the store would not take when they were opened, kept here and
--- written by the maintenance tick once it does (Review.retryUnwritten).
--- The events that open one are mostly the store failing, so the first
--- write is the one most likely to be refused.
local unwritten = {}

--- Items being resolved in this process, so two asks for one item cannot
--- both run.
local busy = {}

function Review.init(deps)
    Storage, Escrow, Audit = deps.storage, deps.escrow, deps.audit
    unwritten, busy = {}, {}
end

--- A copy, so nothing read from the in-process stores is changed under them.
local function copyOf(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copyOf(v) end
    return out
end

--- The log written now, and on json to the disk as well, rather than at the
--- next tick: a resolution is money moved by hand.
local function flushNow()
    pcall(Audit.flush)
    if Storage.flush then pcall(Storage.flush) end
end

--------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------

--- Who an item is mostly about, for its audit row: the first party it names.
local function firstParty(cids)
    for _, role in ipairs({ 'payer', 'creator', 'from', 'owed', 'recipient' }) do
        if cids[role] then return cids[role] end
    end
    return (next(cids)) and cids[next(cids)] or nil
end

--- Leave a money event for staff.
---
--- Never raises: it is called from the paths where something already went
--- wrong, often the store itself, and a second failure there must not hide
--- the first. An item the store will not take is kept in this process and
--- written by the tick once it does, and printed whole meanwhile, so the
--- console has it even if the process goes before the store comes back.
---@param spec table { kind, contract_id, cids = { role = cid }, amount, account, items, known }
---@return string id
function Review.open(spec)
    local minted, id = pcall(Util.mintId, Util.randomId, 'rv', function(candidate)
        return Storage.readReview(candidate) ~= nil
    end)
    -- A store that cannot be read cannot say an id is taken; one drawn from
    -- eleven random characters is not, as near as makes no difference.
    if not minted or not id then id = Util.randomId('rv') end

    -- What went wrong, as the store said it: oxmysql's message carries the
    -- whole statement and every value it was sent, players' data included,
    -- and a whole one could be more than the item's own column holds. Its
    -- own words and the start of the statement (Util.dbError).
    local known = copyOf(spec.known or {})
    for _, key in ipairs({ 'error', 'read_error' }) do
        if known[key] ~= nil and type(known[key]) ~= 'boolean' then
            known[key] = Util.dbError(known[key])
        end
    end

    -- On mysql the goods go into one TEXT column (Storage.MAX_TEXT_BYTES).
    -- An item too big for it was never written, kept only in this process
    -- and lost at the next restart. Kept without the goods' metadata
    -- instead: the ids, sources, names and counts staff decide by are
    -- all still there, and lookNow reads only the ids.
    local items = spec.items
    local limit = Storage.MAX_TEXT_BYTES
    if limit and type(items) == 'table' then
        local encoded, text = pcall(json.encode, items)
        if not encoded or type(text) ~= 'string' or #text > limit then
            local trimmed = {}
            for i, entry in ipairs(items) do
                local copy = copyOf(entry)
                if type(copy) == 'table' and copy.metadata ~= nil then
                    copy.metadata = nil
                    copy.metadata_omitted = true
                end
                trimmed[i] = copy
            end
            items = trimmed
        end
    end

    local item = {
        id = id,
        kind = tostring(spec.kind),
        contract_id = spec.contract_id,
        cids = spec.cids or {},
        amount = tonumber(spec.amount) and math.floor(tonumber(spec.amount)) or nil,
        account = spec.account,
        items = items,
        known = known,
        created_at = os.time(),
        state = Review.STATE.OPEN,
    }

    local wrote, err = pcall(Storage.writeReview, item)
    if wrote then
        Log.always(('left for staff: review %s (%s) on contract %s; see /%s')
            :format(id, item.kind, tostring(item.contract_id), tostring(Config.Admin.Commands.stuck)))
    else
        unwritten[#unwritten + 1] = item
        local encoded, text = pcall(json.encode, item)
        Log.always(('left for staff: review %s (%s) on contract %s, but the store would '
            .. 'not take it (%s); it is kept here and written once the store answers. Until then '
            .. 'it exists only in this process: %s')
            :format(id, item.kind, tostring(item.contract_id), Util.dbError(err),
                encoded and text or '(could not be encoded)'))
    end
    pcall(Audit.financial, 'review_opened', firstParty(item.cids), item.contract_id,
        { review = id, kind = item.kind, amount = item.amount, written = wrote or nil })
    return id
end

--- Write the items the store would not take when they were opened. Run by
--- the maintenance tick.
---@return integer written
function Review.retryUnwritten()
    if #unwritten == 0 then return 0 end
    local keep, written = {}, 0
    for i = 1, #unwritten do
        local item = unwritten[i]
        if pcall(Storage.writeReview, item) then
            written = written + 1
            Log.always(('review %s (%s) is in the store now; see /%s')
                :format(item.id, item.kind, tostring(Config.Admin.Commands.stuck)))
        else
            keep[#keep + 1] = item
        end
    end
    unwritten = keep
    return written
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

--- What the store says now about an item's question, where it can say: the
--- state of its contract, and of each escrow line it names. Read when it is
--- listed, so staff decide on the present rather than on the moment it was
--- opened. nil fields where the store would not answer.
local function lookNow(item)
    local now = {}
    if item.contract_id then
        local ok, contract = pcall(Storage.readContract, item.contract_id)
        if ok then
            now.contract = contract and contract.state or 'none'
            if contract and item.kind == 'bailout_unrecorded' then
                now.buyout = (contract.bailout_queued_at ~= nil and 'queued')
                    or (contract.state == CH.STATE.BAILED_OUT and 'bought_out') or 'none'
            end
        end
    end
    local present, settled, missing, asked = 0, 0, 0, false
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table' and entry.id then
            asked = true
            local ok, line = pcall(Storage.readEscrowLine, entry.id)
            if not ok then
                asked = false
                break
            end
            if not line then
                missing = missing + 1
            elseif line.state == CH.ESCROW_STATE.SETTLED then
                settled = settled + 1
            else
                present = present + 1
            end
        end
    end
    if asked then now.lines = { held = present, settled = settled, missing = missing } end
    return now
end

--- The open items (and any left part-way resolved), oldest first; or, with
--- `all`, every item, newest first. Each a copy, with `now` (lookNow), and
--- the ones the store has not taken yet first, marked `unwritten`.
---@param all boolean|nil
---@param limit integer|nil
---@return table[]
function Review.list(all, limit)
    local out = {}
    for i = 1, #unwritten do
        local item = copyOf(unwritten[i])
        item.unwritten = true
        out[#out + 1] = item
    end
    for _, row in ipairs(Storage.reviewItems(not all, limit or 50) or {}) do
        local item = copyOf(row)
        item.now = lookNow(item)
        out[#out + 1] = item
    end
    return out
end

--- How many are open, for /ch-diag and the boot report.
---@return integer
function Review.openCount()
    local ok, rows = pcall(Storage.reviewItems, true, 1000)
    return (ok and #(rows or {}) or 0) + #unwritten
end

--------------------------------------------------------------------------
-- Resolving
--------------------------------------------------------------------------

--- The citizen id a decision names: a role the item records ('payer',
--- 'creator', ...), or a citizen id typed out. A role is how staff who may
--- not see who is behind an anonymous party still resolve one.
local function partyOf(item, who)
    if type(who) ~= 'string' or who == '' then return nil end
    local cids = type(item.cids) == 'table' and item.cids or {}
    if cids[who] then return cids[who] end
    return Util.toCitizenId(who)
end

--- The money an item records in one source: its own amount where it is in
--- that account, and every line or good it names in it.
local function recordedIn(item, source)
    local total = 0
    if item.account == source then total = total + (tonumber(item.amount) or 0) end
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table' and entry.source == source then
            total = total + (tonumber(entry.amount) or 0)
        end
    end
    return total
end

--- The one money source an item records, or nil where it records none or
--- several (then a refund has to say which).
local function onlySource(item)
    local found
    for source in pairs(CH.MONEY_SOURCES) do
        if recordedIn(item, source) > 0 then
            if found then return nil end
            found = source
        end
    end
    return found
end

--- What an item records beyond money: items and weapons, each as it was.
local function goodsOf(item)
    local out = {}
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table'
            and (entry.source == CH.SOURCE.ITEM or entry.source == CH.SOURCE.WEAPON)
            and entry.item then
            out[#out + 1] = {
                source = entry.source, item = entry.item,
                quantity = entry.source == CH.SOURCE.WEAPON and 1
                    or math.max(1, math.floor(tonumber(entry.quantity) or 1)),
                metadata = copyOf(entry.metadata),
            }
        end
    end
    return out
end

--- Everything an item records: its money less what is known to have
--- arrived already, every line of money it names, and every good.
local function everythingIn(item)
    local out = {}
    local amount = tonumber(item.amount) or 0
    if amount > 0 and CH.MONEY_SOURCES[item.account] then
        local arrived = math.max(0, math.floor(tonumber(item.known and item.known.arrived) or 0))
        if amount - arrived > 0 then
            out[#out + 1] = { source = item.account, amount = amount - arrived }
        end
    end
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table' and CH.MONEY_SOURCES[entry.source]
            and (tonumber(entry.amount) or 0) > 0 then
            out[#out + 1] = { source = entry.source, amount = math.floor(tonumber(entry.amount)),
                              item = entry.item }
        end
    end
    for _, good in ipairs(goodsOf(item)) do out[#out + 1] = good end
    return out
end

--- What a decision gives, checked against the item, as the resolution that
--- is written on it before anything moves.
---@param decision table { action, who, amount, account, goods, note }
---@return table|nil plan
---@return string|nil err
---@return any detail
local function planFor(item, decision)
    if type(decision) ~= 'table' then return nil, CH.ERR.INVALID_INPUT end
    local action = decision.action
    local note = Util.sanitizeText(decision.note, 200)

    if action == 'dismiss' then
        -- Nothing moves, so the note is the whole record of why.
        if not note or note == '' then return nil, 'note_required' end
        return { action = 'dismiss', note = note, lines = {} }
    end
    if action ~= 'refund' and action ~= 'pay' then return nil, CH.ERR.INVALID_INPUT end

    local cid = partyOf(item, decision.who)
    if not cid then return nil, 'no_party' end

    local entries
    if action == 'pay' then
        entries = everythingIn(item)
    elseif decision.goods then
        entries = goodsOf(item)
    else
        -- A whole number of dollars, at most what the item records in that
        -- money: a slip of the keyboard is refused rather than paid.
        local amount = math.tointeger(tonumber(decision.amount))
        if not amount or amount < 1 then return nil, CH.ERR.INVALID_INPUT end
        local source = decision.account or onlySource(item)
        if not CH.MONEY_SOURCES[source] then return nil, 'which_money' end
        local recorded = recordedIn(item, source)
        if recorded <= 0 then return nil, 'nothing_recorded', source end
        if amount > recorded then return nil, 'over_recorded', recorded end
        entries = { { source = source, amount = amount } }
    end
    if #entries == 0 then return nil, 'nothing_recorded' end

    -- Ids from the item, so writing them again lands on the same lines.
    for i = 1, #entries do entries[i].id = item.id .. ':' .. i end
    return { action = action, cid = cid, lines = entries, note = note }
end

--- Give what a plan says, through escrow lines owed to whom it names.
---
--- A line already written is not written again, and one already given is
--- not given again: so a plan carried out a second time, after a crash or a
--- raise part-way, gives only what the first did not.
---@return table result { settled, pending, parked }
local function carryOut(item, plan)
    local result = { settled = 0, pending = 0, parked = 0 }
    if plan.action == 'dismiss' then return result end
    local contractId = item.contract_id or item.id

    for _, entry in ipairs(plan.lines or {}) do
        local line = Storage.readEscrowLine(entry.id)
        if not line then
            line = {
                id = entry.id, contract_id = contractId,
                -- Outside the payout slots, owed to one named person, as a
                -- buyout's premium is (Bailout.owe): nothing else pays it.
                slot = 0, portion = CH.PORTION.OWED, owed_to = plan.cid,
                source = entry.source, amount = entry.amount,
                item = entry.item, quantity = entry.quantity, metadata = copyOf(entry.metadata),
                state = CH.ESCROW_STATE.HELD,
                -- Handed back to whom it came from, a weapon goes back as it
                -- was, registration and all (Escrow.deliver).
                taken_from = plan.action == 'refund' and plan.cid or nil,
            }
            if line.source == CH.SOURCE.DIRTY and not line.item then
                line.item = Config.Sources.dirty.item
            end
            Storage.writeEscrow(contractId, { line })
            -- Queued before it is given, as a buyout's premium is: a crash
            -- between the two leaves it owed and queued, given at the next
            -- login, rather than owed and in nobody's queue.
            Storage.queuePending(plan.cid, contractId, entry.id)
            Escrow.noteWaiting(plan.cid, true)
            line = Storage.readEscrowLine(entry.id) or line
        end

        if line.state == CH.ESCROW_STATE.SETTLED then
            result.settled = result.settled + 1
        elseif Escrow.parked(line) then
            result.parked = result.parked + 1
        elseif line.state == CH.ESCROW_STATE.HELD and line.owed_to == plan.cid then
            local _, moved = Escrow.release(contractId, plan.cid, { line = entry.id },
                'review_' .. plan.action)
            moved = moved or {}
            result.settled = result.settled + (moved.settled or 0)
            result.parked = result.parked + (moved.parked or 0)
            result.pending = result.pending + math.max(0, (moved.pending or 0) - (moved.parked or 0))
                + (moved.skipped or 0)
        else
            -- Being given by another call (a login retry): theirs to finish.
            result.pending = result.pending + 1
        end
    end
    return result
end

local function resolveUnlocked(id, decision, staff)
    local item = Storage.readReview(id)
    if not item then return false, CH.ERR.NOT_FOUND end
    if item.state == Review.STATE.RESOLVED then return false, CH.ERR.ALREADY_SETTLED end
    item = copyOf(item)

    local plan, continued
    if item.state == Review.STATE.OPEN then
        local planned, why, detail = planFor(item, decision)
        if not planned then return false, why, detail end
        -- The decision is written on the item before anything moves, and
        -- only one resolution can write it: a second ask, or a crash after
        -- this, finds it `resolving` and carries out this one.
        if not Storage.setReviewState(id, Review.STATE.OPEN, Review.STATE.RESOLVING,
            { resolution = planned, resolved_by = staff }) then
            local again = Storage.readReview(id)
            if again and again.state == Review.STATE.RESOLVED then
                return false, CH.ERR.ALREADY_SETTLED
            end
            return false, CH.ERR.LOCKED
        end
        plan = planned
    else
        -- Left part-way by a crash or a raise: the decision on it stands,
        -- whatever is asked now, and is finished.
        plan = copyOf(item.resolution) or { action = 'dismiss', lines = {} }
        staff = item.resolved_by or staff
        continued = true
    end

    local result = carryOut(item, plan)
    local final = copyOf(plan)
    final.result = result
    Storage.setReviewState(id, Review.STATE.RESOLVING, Review.STATE.RESOLVED,
        { resolution = final, resolved_by = staff, resolved_at = os.time() })

    -- Who resolved it is the actor, as on a staff settle (admin_settle_line);
    -- the console has no citizen id, and recording one would be a lie.
    Audit.financial('review_resolved', Util.toCitizenId(staff), item.contract_id, {
        review = id, kind = item.kind, action = plan.action, by = staff, to = plan.cid,
        lines = #(plan.lines or {}), settled = result.settled, pending = result.pending,
        parked = result.parked > 0 and result.parked or nil, note = plan.note,
        continued = continued,
    })
    flushNow()
    result.action, result.continued = plan.action, continued
    return true, nil, result
end

--- Resolve an item: refund a party, pay one, or dismiss it with a note.
---
--- `decision.who` is a citizen id or a role the item records ('payer',
--- 'creator', ...). A refund gives `amount` of one money source the item
--- records (at most what it records there), or with `goods` every item and
--- weapon it records; a pay gives everything it records, less what is known
--- to have arrived. Resolving twice gives nothing the second time; one left
--- part-way is finished as it was decided, whatever is asked now.
---@param id string
---@param decision table { action = 'refund'|'pay'|'dismiss', who, amount, account, goods, note }
---@param staff string who resolved it, for the record ('console' at the server console)
---@return boolean ok
---@return string|nil err
---@return any detail on success { action, settled, pending, parked, continued }
function Review.resolve(id, decision, staff)
    id = Util.toId(id)
    if not id then return false, CH.ERR.INVALID_INPUT end
    if busy[id] then return false, CH.ERR.BUSY end
    busy[id] = true
    local ran, ok, err, detail = pcall(resolveUnlocked, id, decision, staff or 'console')
    busy[id] = nil
    if not ran then error(ok, 0) end
    return ok, err, detail
end

--- Close an item the server itself settled after all (Contracts, once the
--- store answers again for a contract it could not place). Only an open
--- one: an item staff are already resolving is theirs.
---@param id string|nil
---@param note string
---@return boolean closed
function Review.settleBySystem(id, note)
    if not id then return false end
    local ok, moved = pcall(Storage.setReviewState, id, Review.STATE.OPEN, Review.STATE.RESOLVED,
        { resolution = { action = 'auto', note = note }, resolved_by = 'server',
          resolved_at = os.time() })
    if ok and moved then
        pcall(Audit.financial, 'review_resolved', nil, nil,
            { review = id, action = 'auto', by = 'server', note = note })
        return true
    end
    -- Still unwritten: it never needs writing now.
    for i = #unwritten, 1, -1 do
        if unwritten[i].id == id then
            table.remove(unwritten, i)
            return true
        end
    end
    return false
end

--- Finish every item a crash left part-way resolved, as it was decided. Run
--- at boot, after recovery has dealt with the escrow lines those left.
---@return integer finished
function Review.recover()
    local finished = 0
    for _, row in ipairs(Storage.reviewItems(true, 1000) or {}) do
        if row.state == Review.STATE.RESOLVING then
            local ok = Review.resolve(row.id, nil, row.resolved_by)
            if ok then finished = finished + 1 end
        end
    end
    if finished > 0 then
        Log.debug(('recovery: finished %d review(s) the last shutdown left '
            .. 'part-way resolved'):format(finished))
    end
    return finished
end

return Review
