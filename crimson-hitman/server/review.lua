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
---
--- Three kinds carry the whole record of a payment whose recording write the
--- database did not confirm (S12): the server writes it again once the
--- database answers, with a statement that cannot change a row already
--- there, and settles the item from what is then stored (Review.decide,
--- the deciders registered by Contracts and Bailout). Never on absence: a
--- write that went unanswered may still land, and lands on what the server
--- wrote. On mysql the item is kept on this machine (resource KVP) before
--- the write is sent (Review.prepare), so a restart loses no record.

local Util = CrimsonBoot.requireShared('util')
local Log = CrimsonBoot.requireShared('log')

local Review = {}

local Storage, Escrow, Audit

Review.STATE = { OPEN = 'open', RESOLVING = 'resolving', RESOLVED = 'resolved' }

--- What each kind of item is, said to staff beside it, and what settles it.
---
--- Three kinds are opened with the whole record of what was being written
--- (`known.decide`): the server writes it again once the database answers
--- and settles the item by itself (Review.decide), and Refund or Pay does
--- the same at once. An item opened before this version has no such record
--- and keeps the advice after "older one".
Review.KINDS = {
    bailout_unrecorded = 'a buyout was charged, and the store would neither record it nor say '
        .. 'whether it had. The server records it, or refunds it once the contract has ended '
        .. 'without it, by itself once the database answers; Refund does the same now, and waits '
        .. 'while the contract is still open. An older one without that record: if the contract '
        .. 'shows the buyout (queued or bought out), dismiss; if not, refund the payer',
    bailout_refund_stranded = 'a buyout premium handed back reached nobody: refund the payer '
        .. 'what did not arrive',
    bailout_settle_raised = 'a queued buyout kept raising as it was settled, and the server '
        .. 'stopped trying: if the contract is bought out and the client has not had the premium, '
        .. 'pay the creator; if it ended another way, refund the payer',
    owe_id_exhausted = 'money owed to a player could not be put on the books (the store had no '
        .. 'line id left): pay them',
    anonymity_fee_refund_failed = 'an anonymity fee owed back could not be credited: refund '
        .. 'what did not arrive',
    escrow_take_unverified = 'escrow was taken and the store would not say whether it was '
        .. 'written. The server hands every line it took back to whom it came from by itself '
        .. 'once the database answers; Refund does the same now. An older one without that '
        .. 'record: lines the store has now are held or handed back already, so only what it '
        .. 'does not have is given',
    escrow_take_raised = 'taking a line of escrow raised, so whether it left the player is not '
        .. 'known: check what they have, and refund it if it left them',
    escrow_rollback_failed = 'escrow taken for a contract that was not placed could not be given '
        .. 'back: refund what did not arrive',
    contract_unrecorded = 'a contract\'s escrow was taken, and the store would neither write the '
        .. 'contract nor say whether it had. The server places it, with its escrow, by itself once '
        .. 'the database answers, and tells the client; Refund does the same now. No anonymity '
        .. 'fee was taken for it. An older one without that record: its escrow is handed back by '
        .. 'the server, so refund only the anonymity fee it names, where the contract does not exist',
    escrow_settle_lost = 'a payout reached its recipient, and something else settled its line as '
        .. 'well: check nobody was paid it twice, then dismiss',
}

--- What settles an item that carries its whole record (`known.decide`), by
--- kind: fn(item) -> 'done', note | 'wait', why | 'staff', why. Registered
--- by the modules that wrote the record (Contracts.init, Bailout.init).
--- 'done' has moved what was owed through the guarded moves that already
--- exist and closes the item; 'wait' leaves it for the next tick; 'staff'
--- leaves it open for staff, as an item without a record is.
Review.DECIDERS = {}

--- Items the store would not take when they were opened, kept here and
--- written by the maintenance tick once it does (Review.retryUnwritten).
--- The events that open one are mostly the store failing, so the first
--- write is the one most likely to be refused.
local unwritten = {}

--- Items being resolved in this process, so two asks for one item cannot
--- both run.
local busy = {}

--- Items the server settles by itself once the store answers (Review.decide),
--- by id: open, carrying their whole record, and not dismissed.
local undecided = {}  -- { [id] = item }

--- The contract each undecided contract_unrecorded holds as claiming
--- (Escrow.holdClaim), by item id, so the recovery sweeps and /ch-settle
--- leave the escrow of a contract the server may still place alone: handed
--- back at boot, the decider then placed a contract holding nothing.
local holding = {}  -- { [id] = contractId }

--- When a decider's raise was last said, by item id (at most once an hour).
local raiseSaid = {}

--- The store's open items with a record could not be read at boot: read
--- again by the next Review.decide.
local unread = false

--------------------------------------------------------------------------
-- Kept on this machine (resource KVP)
--------------------------------------------------------------------------

--- An item kept in FXServer's KVP store, outside the database and the
--- resource folder: `reviewKept:<mode>:<id>`. One is written the moment a
--- payment's recording write is about to be sent on mysql (Review.prepare)
--- and whenever a store refuses an item (Review.open), and deleted once the
--- write is answered or the item is in the store. A restart in between
--- loads it again (Review.init).
local KEPT = 'reviewKept:'

local function keptKey(id, mode)
    return KEPT .. tostring(mode or Config.Database.Mode) .. ':' .. tostring(id)
end

local function keep(item)
    if type(SetResourceKvp) ~= 'function' then return false end
    local encoded, text = pcall(json.encode, item)
    if not encoded or type(text) ~= 'string' then return false end
    return (pcall(SetResourceKvp, keptKey(item.id), text))
end

local function forget(id)
    if type(DeleteResourceKvp) == 'function' then pcall(DeleteResourceKvp, keptKey(id)) end
end

--- Every item kept on this machine, by the mode it was kept for.
---@return table<string, table[]>
local function keptByMode()
    local out = {}
    if type(StartFindKvp) ~= 'function' or type(FindKvp) ~= 'function' then return out end
    local ok, handle = pcall(StartFindKvp, KEPT)
    if not ok or not handle or handle == -1 then return out end
    while true do
        local key = FindKvp(handle)
        if not key then break end
        local mode = key:sub(#KEPT + 1):match('^([^:]+):')
        local text = GetResourceKvpString and GetResourceKvpString(key)
        local decoded, item = pcall(json.decode, text or '')
        if mode and decoded and type(item) == 'table' and item.id then
            out[mode] = out[mode] or {}
            out[mode][#out[mode] + 1] = item
        end
    end
    if type(EndFindKvp) == 'function' then pcall(EndFindKvp, handle) end
    return out
end

--- The items this machine keeps for storage modes other than `mode`, for
--- main.lua's refuseModeSwitch: a payment kept for mysql mode is money that
--- mode still owes, and a start in another would carry it nowhere.
---@param mode string
---@return table<string, table[]>
function Review.keptElsewhere(mode)
    local out = {}
    for kept, items in pairs(keptByMode()) do
        if kept ~= mode then out[kept] = items end
    end
    return out
end

function Review.init(deps)
    Storage, Escrow, Audit = deps.storage, deps.escrow, deps.audit
    unwritten, busy, undecided, holding, raiseSaid, unread = {}, {}, {}, {}, {}, false
    if Storage and Storage.remote and type(SetResourceKvp) ~= 'function' then
        Log.always('resource KVP is not available here, so a payment caught by a database that '
            .. 'stops answering is not kept across a restart')
    end
    -- What this machine kept for this mode: written once the store answers
    -- (Review.retryUnwritten), and settled by the server first where it
    -- carries its record (Review.recoverSystem, before boot recovery).
    for _, item in ipairs(keptByMode()[tostring(Config.Database.Mode)] or {}) do
        item.known = type(item.known) == 'table' and item.known or {}
        item.known.restored = true
        unwritten[#unwritten + 1] = item
    end
end

--- Whether an item is one the server settles by itself.
local function decidable(item)
    return type(item) == 'table' and item.state == Review.STATE.OPEN
        and type(item.known) == 'table' and item.known.decide == true
        and Review.DECIDERS[item.kind] ~= nil
end

--- Put an item on the server's list, holding its contract where it says to.
local function track(item)
    if not decidable(item) then return end
    undecided[item.id] = item
    if item.known.hold and item.contract_id and not holding[item.id] and Escrow
        and Escrow.holdClaim then
        Escrow.holdClaim(item.contract_id)
        holding[item.id] = item.contract_id
    end
end

--- Take an item off the server's list, letting its contract go.
local function untrack(id)
    undecided[id] = nil
    raiseSaid[id] = nil
    if holding[id] then
        if Escrow and Escrow.letClaim then Escrow.letClaim(holding[id]) end
        holding[id] = nil
    end
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

--- An item as it is kept: the spec's fields, its errors trimmed and its goods
--- held to what the store's column takes. Never raises.
local function build(spec, id)
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
    -- and lost at the next restart. Kept with the biggest goods' metadata
    -- left out instead, one at a time until it fits: a note or a container's
    -- contents goes, and a weapon's serial, registration and attachments
    -- beside it stay, since a refund or a pay gives the goods back from
    -- this record (goodsOf). Each one left out says so (metadata_omitted),
    -- and staff are told before and after they give it. The ids, sources,
    -- names and counts are all still there, and lookNow reads only the ids.
    local items = spec.items
    local limit = Storage.MAX_TEXT_BYTES
    if limit and type(items) == 'table' then
        local function size(value)
            local encoded, text = pcall(json.encode, value)
            return (encoded and type(text) == 'string') and #text or math.huge
        end
        if size(items) > limit then
            local trimmed, heavy, weight = {}, {}, {}
            for i, entry in ipairs(items) do
                trimmed[i] = copyOf(entry)
                if type(trimmed[i]) == 'table' and trimmed[i].metadata ~= nil then
                    heavy[#heavy + 1] = i
                    weight[i] = size(trimmed[i].metadata)
                end
            end
            table.sort(heavy, function(a, b)
                if weight[a] ~= weight[b] then return weight[a] > weight[b] end
                return a < b
            end)
            for _, i in ipairs(heavy) do
                if size(trimmed) <= limit then break end
                trimmed[i].metadata = nil
                trimmed[i].metadata_omitted = true
            end
            items = trimmed
        end
    end

    return {
        id = id,
        kind = tostring(spec.kind),
        contract_id = spec.contract_id,
        cids = copyOf(spec.cids) or {},
        amount = tonumber(spec.amount) and math.floor(tonumber(spec.amount)) or nil,
        account = spec.account,
        items = copyOf(items),
        known = known,
        created_at = tonumber(spec.created_at) or os.time(),
        state = Review.STATE.OPEN,
    }
end

--- The item a payment's recording write would leave for staff if it raised,
--- made before that write is sent (S12).
---
--- Called after the money is taken and before the write that records it,
--- with nothing that yields between the charge and this: on mysql it is
--- kept on this machine at once (resource KVP), so a restart while the write
--- waits on a database that has stopped answering still has it, and the
--- next start settles it (Review.recoverSystem). Never before the charge:
--- an item for money never taken would have the server pay it.
---
--- Review.discard(item) once the write has answered; Review.open(item),
--- with what went wrong in `known`, where it raised.
---@param spec table as Review.open takes it
---@return table item
function Review.prepare(spec)
    local item = build(spec, Util.randomId('rv'))
    if Storage.remote then keep(item) end
    item.prepared = true
    return item
end

--- The write a prepared item stood for was answered: nothing to keep.
---@param item table|nil from Review.prepare
function Review.discard(item)
    if type(item) == 'table' and item.id then forget(item.id) end
end

--- Leave a money event for staff.
---
--- Never raises: it is called from the paths where something already went
--- wrong, often the store itself, and a second failure there must not hide
--- the first. An item the store will not take is kept in this process and
--- on this machine (resource KVP, in json and mysql mode), and written by
--- the tick once the store answers, and printed whole meanwhile.
---
--- A prepared item (Review.prepare) keeps its id. One that carries its whole
--- record (`known.decide`) is on the server's list from now on: settled by
--- the server itself once the store answers (Review.decide).
---@param spec table { kind, contract_id, cids = { role = cid }, amount, account, items, known }
---@return string id
function Review.open(spec)
    local id = spec.prepared and spec.id or nil
    -- A store that is not answering (Storage.healthy, where the store has
    -- one) is not asked whether an id is taken.
    if not id and Storage.healthy and not Storage.healthy() then id = Util.randomId('rv') end
    if not id then
        local minted, fresh = pcall(Util.mintId, Util.randomId, 'rv', function(candidate)
            return Storage.readReview(candidate) ~= nil
        end)
        -- A store that cannot be read cannot say an id is taken; one drawn
        -- from eleven random characters is not, as near as makes no difference.
        id = minted and fresh or Util.randomId('rv')
    end

    local item = build(spec, id)
    local decide = item.known.decide == true
    local stuck = tostring(Config.Admin.Commands.stuck)

    local wrote, err = pcall(Storage.writeReview, item)
    if wrote then
        forget(id)
        if decide then
            Log.always(('review %s (%s) on contract %s: the database did not confirm it; the '
                .. 'server settles it itself once the database answers (/%s)')
                :format(id, item.kind, tostring(item.contract_id), stuck))
        else
            Log.always(('left for staff: review %s (%s) on contract %s; see /%s')
                :format(id, item.kind, tostring(item.contract_id), stuck))
        end
    else
        unwritten[#unwritten + 1] = item
        -- Not in memory mode, whose items would name contracts gone at the
        -- next start.
        local kept = Config.Database.Mode ~= 'memory' and keep(item)
        local encoded, text = pcall(json.encode, item)
        Log.always(('left for staff: review %s (%s) on contract %s, but the store would '
            .. 'not take it (%s); it is kept %s and written once the store answers. Until then '
            .. 'it is not in the store: %s')
            :format(id, item.kind, tostring(item.contract_id), Util.dbError(err),
                kept and 'in this process and on this machine (resource KVP)' or 'in this process',
                encoded and text or '(could not be encoded)'))
    end
    track(item)
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
            forget(item.id)
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

--- How a citizen id staff typed is checked (Admin.knownCitizenId, handed
--- over by Admin.init): the form the server keeps it in, or nil when nobody
--- here has it. Until it is, a decision names its party by role alone.
local knownCitizenId = nil

--- Check typed citizen ids with `fn`: (typed, lines) -> cid|nil.
---@param fn function|nil
function Review.useResolver(fn)
    knownCitizenId = type(fn) == 'function' and fn or nil
end

--- The roles an item records, in order, as one line of text.
local function rolesOf(item)
    local roles = {}
    for role in pairs(type(item.cids) == 'table' and item.cids or {}) do roles[#roles + 1] = role end
    table.sort(roles)
    return table.concat(roles, ', ')
end

--- The citizen id a decision names: a role the item records ('payer',
--- 'creator', ...; in any case), or the citizen id of somebody this server
--- has, as typed or in capitals (knownCitizenId). A role is how staff who
--- may not see who is behind an anonymous party still resolve one. Any
--- other word was taken as a citizen id as it stood: 'client', 'Payer' or
--- 'target01' resolved the item to a line owed and queued for an id no
--- character has, which nothing ever gave and nothing could move. Whom the
--- item's own escrow lines were taken from counts as known.
---@return string|nil cid
local function partyOf(item, who)
    if type(who) ~= 'string' or who == '' then return nil end
    local cids = type(item.cids) == 'table' and item.cids or {}
    if cids[who] then return cids[who] end
    if cids[who:lower()] then return cids[who:lower()] end
    if not knownCitizenId then return nil end
    local lines = {}
    if item.contract_id then
        local ok, found = pcall(Storage.readEscrow, item.contract_id)
        if ok then lines = found or {} end
    end
    return (knownCitizenId(who, lines))
end

--- The escrow lines an item names that the store has now, held or handed
--- back already: money that is there, so not missing (W130). An item whose
--- take landed after all, its lines then handed back by the server, said to
--- staff that it recorded them, and Pay or Refund gave them a second time.
--- Only the line itself counts: the same id, holding the same thing.
---@return table<string, boolean> present by line id
local function inStore(item)
    local present = {}
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table' and entry.id then
            local line = Storage.readEscrowLine(entry.id)
            if line and line.source == entry.source and line.item == entry.item
                and (tonumber(line.amount) or 0) == (tonumber(entry.amount) or 0) then
                present[entry.id] = true
            end
        end
    end
    return present
end

--- Whether an entry is one the store already has (inStore).
local function there(entry, present)
    return present ~= nil and entry.id ~= nil and present[entry.id] == true
end

--- The money an item records in one source: its own amount where it is in
--- that account, and every line or good it names in it, less the lines the
--- store has (`present`, inStore) where that is given.
local function recordedIn(item, source, present)
    local total = 0
    if item.account == source then total = total + (tonumber(item.amount) or 0) end
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table' and entry.source == source and not there(entry, present) then
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

--- What an item records beyond money: items and weapons, each as it was,
--- less the lines the store has (`present`).
local function goodsOf(item, present)
    local out = {}
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table'
            and (entry.source == CH.SOURCE.ITEM or entry.source == CH.SOURCE.WEAPON)
            and entry.item and not there(entry, present) then
            out[#out + 1] = {
                source = entry.source, item = entry.item,
                quantity = entry.source == CH.SOURCE.WEAPON and 1
                    or math.max(1, math.floor(tonumber(entry.quantity) or 1)),
                metadata = copyOf(entry.metadata),
                -- Kept without it (build): given back without it too.
                bare = entry.metadata_omitted == true or nil,
            }
        end
    end
    return out
end

--- Everything an item records: its money less what is known to have
--- arrived already, every line of money it names that the store does not
--- have (`present`), and every such good.
local function everythingIn(item, present)
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
            and (tonumber(entry.amount) or 0) > 0 and not there(entry, present) then
            out[#out + 1] = { source = entry.source, amount = math.floor(tonumber(entry.amount)),
                              item = entry.item }
        end
    end
    for _, good in ipairs(goodsOf(item, present)) do out[#out + 1] = good end
    return out
end

--- What a decision gives, checked against the item, as the resolution that
--- is written on it before anything moves.
---
--- Never what the store has already: a line the item names that is held or
--- handed back is not given again, and an item all of whose lines are there
--- is answered 'nothing_missing' (W130).
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
    if not cid then return nil, 'no_party', rolesOf(item) end

    local present = inStore(item)
    local entries
    if action == 'pay' then
        entries = everythingIn(item, present)
    elseif decision.goods then
        entries = goodsOf(item, present)
    else
        -- A whole number of dollars, at most what the item records in that
        -- money: a slip of the keyboard is refused rather than paid.
        local amount = math.tointeger(tonumber(decision.amount))
        if not amount or amount < 1 then return nil, CH.ERR.INVALID_INPUT end
        local source = decision.account or onlySource(item)
        if not CH.MONEY_SOURCES[source] then return nil, 'which_money' end
        local recorded = recordedIn(item, source, present)
        if recorded <= 0 then
            if recordedIn(item, source) > 0 then return nil, 'nothing_missing' end
            return nil, 'nothing_recorded', source
        end
        if amount > recorded then return nil, 'over_recorded', recorded end
        entries = { { source = source, amount = amount } }
    end
    if #entries == 0 then
        if next(present) ~= nil then return nil, 'nothing_missing' end
        return nil, 'nothing_recorded'
    end

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
        -- Goods the record kept without their metadata (build), counted for
        -- the answer staff are given.
        if entry.bare then result.bare = (result.bare or 0) + 1 end
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

--- Whether an item is one the store would not take yet (Review.open).
local function isUnwritten(id)
    for i = 1, #unwritten do
        if unwritten[i].id == id then return true end
    end
    return false
end

--- An item that carries its whole record, settled now by Refund or Pay as
--- the server would settle it (its decider), whatever was typed: never on
--- what the store does not show (DESIGN O7). nil when its record cannot
--- settle it ('staff'), which is then resolved by hand as one without.
local function settleNow(id, item, decision, staff)
    local verdict, note = Review.DECIDERS[item.kind](item)
    if verdict == 'wait' then return false, 'not_yet', note end
    if verdict ~= 'done' then
        untrack(id)
        return nil
    end
    Storage.setReviewState(id, Review.STATE.OPEN, Review.STATE.RESOLVED, {
        resolution = { action = 'settled', asked = decision.action, note = note },
        resolved_by = staff, resolved_at = os.time(),
    })
    forget(id)
    untrack(id)
    Audit.financial('review_resolved', Util.toCitizenId(staff), item.contract_id, {
        review = id, kind = item.kind, action = 'settled', asked = decision.action, by = staff,
        note = note,
    })
    flushNow()
    local typed = decision.amount ~= nil or decision.goods == true or decision.account ~= nil
    return true, nil, { action = 'settled', note = note, ignored = typed or nil }
end

local function resolveUnlocked(id, decision, staff, opts)
    local item = Storage.readReview(id)
    if not item then
        -- Listed, and not in the store yet (W138): resolvable once it is.
        if isUnwritten(id) then return false, 'unwritten' end
        return false, CH.ERR.NOT_FOUND
    end
    if item.state == Review.STATE.RESOLVED then return false, CH.ERR.ALREADY_SETTLED end
    item = copyOf(item)

    if decidable(item) and type(decision) == 'table'
        and (decision.action == 'refund' or decision.action == 'pay') then
        local ok, err, detail = settleNow(id, item, decision, staff)
        if ok ~= nil then return ok, err, detail end
    end

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
        -- Left part-way by a crash or a raise: the decision on it stands.
        -- Staff (opts.strict: /ch-review and the panel) finish it by asking
        -- for nothing else: another action's words carried out the stored
        -- one, money moving under a button labelled Dismiss (W137).
        if opts and opts.strict and decision ~= nil then
            local stored = type(item.resolution) == 'table' and item.resolution or {}
            return false, 'being_resolved', { action = stored.action, by = item.resolved_by }
        end
        plan = copyOf(item.resolution) or { action = 'dismiss', lines = {} }
        staff = item.resolved_by or staff
        continued = true
    end

    local result = carryOut(item, plan)
    local final = copyOf(plan)
    final.result = result
    Storage.setReviewState(id, Review.STATE.RESOLVING, Review.STATE.RESOLVED,
        { resolution = final, resolved_by = staff, resolved_at = os.time() })
    -- Resolved by staff: off the server's list, its contract let go.
    forget(id)
    untrack(id)

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
--- to have arrived and what the store already has. Resolving twice gives
--- nothing the second time; one left part-way is finished as it was
--- decided (a nil decision asks for exactly that).
---
--- An item that carries its whole record (`known.decide`) takes refund or
--- pay as "settle it now as the server would" (its decider): the amount
--- typed is not used, and 'not_yet' says why it cannot be yet.
---@param id string
---@param decision table|nil { action = 'refund'|'pay'|'dismiss', who, amount, account, goods, note }
---@param staff string who resolved it, for the record ('console' at the server console)
---@param opts table|nil { strict = true }: an item left part-way is finished only by a nil decision
---@return boolean ok
---@return string|nil err
---@return any detail on success { action, settled, pending, parked, bare, continued } or
--- { action = 'settled', note, ignored }
function Review.resolve(id, decision, staff, opts)
    id = Util.toId(id)
    if not id then return false, CH.ERR.INVALID_INPUT end
    if busy[id] then return false, CH.ERR.BUSY end
    busy[id] = true
    local ran, ok, err, detail = pcall(resolveUnlocked, id, decision, staff or 'console', opts)
    busy[id] = nil
    if not ran then error(ok, 0) end
    return ok, err, detail
end

--- An item's state as the store has it, for words worded from what happened:
--- 'open', 'resolving', 'resolved', 'unwritten' (listed, not in the store yet),
--- or nil when there is none or the store would not say.
---@param id any
---@return string|nil state
---@return table|nil item
function Review.stateOf(id)
    id = Util.toId(id)
    if not id then return nil end
    local ok, item = pcall(Storage.readReview, id)
    if ok and item then return item.state, copyOf(item) end
    if isUnwritten(id) then return 'unwritten' end
    return nil
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
        forget(id)
        untrack(id)
        pcall(Audit.financial, 'review_resolved', nil, nil,
            { review = id, action = 'auto', by = 'server', note = note })
        return true
    end
    -- Still unwritten: it never needs writing now.
    for i = #unwritten, 1, -1 do
        if unwritten[i].id == id then
            table.remove(unwritten, i)
            forget(id)
            untrack(id)
            return true
        end
    end
    return false
end

--- Close an item by the server once every line it names is in the store,
--- held or handed back (Contracts.retryStuckCreates, for the take a create
--- could not confirm): nothing it records is missing then (W130).
---@param id string|nil
---@param note string
---@return boolean closed
function Review.settleWhenStored(id, note)
    if not id then return false end
    local ok, item = pcall(Storage.readReview, id)
    if not ok or not item or item.state ~= Review.STATE.OPEN then return false end
    local named, present = 0, inStore(item)
    for _, entry in ipairs(type(item.items) == 'table' and item.items or {}) do
        if type(entry) == 'table' and entry.id then
            named = named + 1
            if not present[entry.id] then return false end
        end
    end
    if named == 0 then return false end
    return Review.settleBySystem(id, note)
end

--------------------------------------------------------------------------
-- Settled by the server (S12, DESIGN §2.2)
--------------------------------------------------------------------------

--- Close an item its decider settled, or take it off the list where there
--- is nothing left to close (resolved or gone meanwhile).
local function closeDecided(id, item, note)
    if Review.settleBySystem(id, note) then
        Log.always(('review %s (%s) settled by the server: %s'):format(id, item.kind, tostring(note)))
        return true
    end
    local ok, stored = pcall(Storage.readReview, id)
    if ok and (not stored or stored.state ~= Review.STATE.OPEN) then untrack(id) end
    return false
end

--- Put the store's open items that carry their record on the list. Marked
--- `unread` when the store would not say, and asked again by the next pass.
local function readStored()
    local ok, rows = pcall(Storage.reviewItems, true, 1000)
    unread = not ok
    if not ok then return false, rows end
    for _, row in ipairs(rows or {}) do
        if decidable(row) and not undecided[row.id] then track(copyOf(row)) end
    end
    return true
end

--- Settle every item on the server's list that it can now. A maintenance
--- tick job, and run once at boot by Review.recoverSystem.
---
--- Each under the item's own key (`busy`, as a staff resolution is), in its
--- own pcall: 'done' closes it (settleBySystem, open -> resolved), 'wait'
--- keeps it, 'staff' leaves it open for staff and off the list; a raise
--- keeps it, said at most once an hour. Every step a decider takes is
--- idempotent, so one stopped part-way is decided again from the start.
---@return integer settled
function Review.decide()
    if Storage.healthy and not Storage.healthy() then return 0 end
    if unread then readStored() end
    local ids = {}
    for id in pairs(undecided) do ids[#ids + 1] = id end
    table.sort(ids)
    local settled = 0
    for _, id in ipairs(ids) do
        local item = undecided[id]
        if item and not busy[id] then
            busy[id] = true
            local ran, verdict, note = pcall(Review.DECIDERS[item.kind], item)
            busy[id] = nil
            if not ran then
                local now = os.time()
                if not raiseSaid[id] or now - raiseSaid[id] >= 3600 then
                    raiseSaid[id] = now
                    Log.always(('review %s (%s) on contract %s: settling it raised (%s); it is '
                        .. 'tried again on the next tick'):format(id, item.kind,
                        tostring(item.contract_id), Util.dbError(verdict)))
                end
            elseif verdict == 'done' then
                if closeDecided(id, item, note) then settled = settled + 1 end
            elseif verdict == 'staff' then
                untrack(id)
                Log.always(('review %s (%s) on contract %s is left for staff: %s (/%s)')
                    :format(id, item.kind, tostring(item.contract_id), tostring(note),
                        tostring(Config.Admin.Commands.stuck)))
            end
        end
    end
    return settled
end

--- At boot, before recovery (main.lua): every open item that carries its
--- record, from the store and from this machine's KVP, on the server's
--- list, each contract_unrecorded holding its contract as claiming so
--- recovery leaves that escrow for the decider, then decided once.
---@return integer settled
function Review.recoverSystem()
    local read, err = readStored()
    for _, item in ipairs(unwritten) do
        if decidable(item) and not undecided[item.id] then track(item) end
    end
    local settled = Review.decide()
    if not read then error(err, 0) end
    return settled
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
