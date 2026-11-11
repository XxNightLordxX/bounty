--- Staff tools on one contract, from the admin panel's contract view
--- (server/panel.lua answers the page; this does the work).
---
---   * Notes: private notes on any contract ('ticket #42, waiting on clip'),
---     many per contract, each with its author and time. Kept in the store
---     (memory, records.json, crimson_contract_staff) and in the log
---     (staff_note). Shown only in the panel's contract view, never to a
---     player.
---   * Taking one operative off a live contract without ending it for
---     anybody else, with a reason, optionally barring them (on any of their
---     characters) from taking it again. Through the walk-away's own path
---     (Contracts.abandon, opts.staff): their stake goes to the client
---     exactly as a walk-away hands it over, unless staff choose to give it
---     back. Logged as staff_remove_hitman.
---   * Replacing what a player wrote on a contract (its reason) through the
---     same checks a player's text gets (Contracts.reasonFor:
---     Config.Reason.MaxLength, MaxDigits, PatternDenylist and lb-phone's
---     blacklist), with a reason. The original stays in the log
---     (staff_text_edit); players see the new text marked 'edited by staff'
---     (Projection: staffEdited).
---
--- The edits and removals are read once at the start and kept here, so a
--- card asks a table, not the store, whether its text was edited or its
--- viewer barred.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')
local Holds = CrimsonBoot.require('server.holds')
local L = CrimsonBoot.requireShared('locale').t

local StaffContract = {}

local Storage, Audit, Notify, Contracts, Identity

--- Contracts whose text staff replaced: [contractId] = { [field] = true }.
local edited = {}
--- The operatives staff took off each contract: [contractId] = { row, ... }
--- (kind 'removal', as the store keeps them).
local removals = {}

--- What a player says to the operative staff took off a contract, and the
--- title it goes under. Never who did it or why.
StaffContract.REMOVED_TITLE = L('staffcontract.taken_off_a_contract')
StaffContract.REMOVED_TEXT = L('staffcontract.staff_removed_you_from_a_contract')

--- The texts on a contract staff may replace, and the checks each goes
--- through. A contract keeps one piece of player text: its reason.
StaffContract.FIELDS = { reason = true }

local function remember(row)
    if row.kind == 'edit' and row.field then
        edited[row.contract_id] = edited[row.contract_id] or {}
        edited[row.contract_id][row.field] = true
    elseif row.kind == 'removal' then
        local list = removals[row.contract_id] or {}
        list[#list + 1] = row
        removals[row.contract_id] = list
    end
end

local function forget(row)
    local list = removals[row.contract_id]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i].id == row.id then table.remove(list, i) end
    end
    if #list == 0 then removals[row.contract_id] = nil end
end

---@param deps table { storage, audit, notify, contracts, identity }
function StaffContract.init(deps)
    Storage, Audit, Notify, Contracts, Identity =
        deps.storage, deps.audit, deps.notify, deps.contracts, deps.identity
    edited, removals = {}, {}
    if Storage.readContractStaffMarks then
        local ok, rows = pcall(Storage.readContractStaffMarks)
        if ok then
            for _, row in ipairs(rows or {}) do remember(row) end
        else
            Log.always(('staff records on contracts could not be read (%s): no contract shows '
                .. '"edited by staff", and nobody staff barred from one is barred, until the next '
                .. 'start reads them'):format(Util.dbError(rows)))
        end
    end
    -- Read by contracts.lua: whose stake staff gave back, who may not take
    -- a contract again.
    Contracts.staffContract = StaffContract
end

--------------------------------------------------------------------------
-- What the rest of the resource asks
--------------------------------------------------------------------------

--- Whether staff replaced text on this contract: true, or nil (so a card
--- carries the key only where it is so).
---@param contractId string
---@return boolean|nil
function StaffContract.edited(contractId)
    return (contractId and edited[contractId] and next(edited[contractId]) ~= nil) or nil
end

--- Whether staff took this player off this contract and barred them from
--- taking it again, on this character or another of the account's.
---@param contractId string
---@param cid string|nil
---@param account string|nil
---@return boolean
function StaffContract.barred(contractId, cid, account)
    for _, row in ipairs(removals[contractId] or {}) do
        if row.blocked == true and ((cid and row.subject_cid == cid)
            or (account and row.subject_account and Identity.sameAccount(row.subject_account, account))) then
            return true
        end
    end
    return false
end

--- Whether staff took this hitman off this stint of this contract and chose
--- to give their stake back: then it is theirs whatever ends the contract
--- (Contracts' walkedAway).
---@param contractId string
---@param cid string
---@param stint number|nil the hitman row's accepted_at
---@return boolean
function StaffContract.stakeReturned(contractId, cid, stint)
    for _, row in ipairs(removals[contractId] or {}) do
        if row.stake_returned == true and row.subject_cid == cid
            and (stint == nil or tonumber(row.stint) == tonumber(stint)) then
            return true
        end
    end
    return false
end

--- Every record on one contract, oldest first, as the store keeps them.
---@param contractId string
---@return table[]
function StaffContract.records(contractId)
    if not Storage.readContractStaff then return {} end
    return Storage.readContractStaff(contractId) or {}
end

--------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------

local function newRow(contractId, kind, staff, fields)
    local id = Util.mintId(Storage.nextId, 'cs', function(candidate)
        for _, row in ipairs(StaffContract.records(contractId)) do
            if row.id == candidate then return true end
        end
        return false
    end)
    if not id then return nil end
    local row = {
        id = id, contract_id = contractId, kind = kind,
        author_cid = staff.cid, author_name = staff.name and Util.sanitizeText(tostring(staff.name), 128) or nil,
        created_at = os.time(), stake_returned = false, blocked = false,
    }
    for k, v in pairs(fields or {}) do row[k] = v end
    return row
end

--- The longest note, in characters (the column holds 500), and the most
--- notes one contract holds: a bound on what its view and its export read,
--- far past what a ticket needs. Fixed rather than settings: config.lua is
--- kept to one short file, and neither is a rule of the game.
StaffContract.NOTE_MAX_LENGTH = 300
StaffContract.NOTES_PER_CONTRACT = 100

local function noteLimits()
    return StaffContract.NOTE_MAX_LENGTH, StaffContract.NOTES_PER_CONTRACT
end
StaffContract.noteLimits = noteLimits

--- Add a private note to a contract.
---@param staff table { cid, name }
---@param contractId string
---@param text any
---@return boolean ok
---@return string|nil err 'empty' | 'too_long' | 'too_many' | not_found
---@return table|nil row, or { max } for too_long and too_many
function StaffContract.addNote(staff, contractId, text)
    local maxLength, perContract = noteLimits()
    local body = Util.sanitizeText(text, maxLength + 1)
    if not body then return false, 'empty' end
    if utf8.len(body) > maxLength then return false, 'too_long', { max = maxLength } end
    if not Storage.readContract(contractId) then return false, CH.ERR.NOT_FOUND end
    local notes = 0
    for _, row in ipairs(StaffContract.records(contractId)) do
        if row.kind == 'note' then notes = notes + 1 end
    end
    if notes >= perContract then return false, 'too_many', { max = perContract } end

    local row = newRow(contractId, 'note', staff, { body = body })
    if not row then return false, CH.ERR.SERVER_ERROR end
    Storage.addContractStaff(row)
    Audit.staff('staff_note', staff.cid, contractId, { note = body, note_id = row.id })
    return true, nil, row
end

--- Take one operative off a live contract (the admin panel's Remove).
---
--- The walk-away's own path (Contracts.abandon with opts.staff): the same
--- compare and set orders it against every ending, the contract goes back
--- on the board when nobody is left holding it, and the client and the
--- other operatives are told an operative left in exactly a walk-away's
--- words. Their stake goes to the client, as a walk-away hands it over,
--- unless staff choose to give it back (`returnStake`). The record is
--- written first, so the choice of where the stake goes, and the bar, are
--- read by every path from then on (a repair, an ending, a restart); a
--- removal that is refused takes its record back out.
---@param staff table { cid, name }
---@param contractId string
---@param hitmanId string the hitman row's id
---@param reason string
---@param opts table { block = boolean, returnStake = boolean }
---@return boolean ok
---@return string|nil err
---@return table|nil detail { alias, stake, forfeited, returned, remaining, blocked }
function StaffContract.removeHitman(staff, contractId, hitmanId, reason, opts)
    opts = opts or {}
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    if CH.TERMINAL[contract.state] or contract.state == CH.STATE.COMPLETING then
        return false, CH.ERR.BAD_STATE, { state = contract.state }
    end
    local hitmen = Storage.readHitmen(contractId) or {}
    local hitman
    for _, row in ipairs(hitmen) do
        if row.id == hitmanId then hitman = row end
    end
    -- The operative first, then the hold: asked the other way round, a
    -- removal of an operative id that does not exist answered "on hold" on
    -- exactly the contracts a frozen player is on, anonymous ones too.
    if not hitman then return false, 'no_operative' end
    if hitman.state ~= 'active' then return false, 'not_active', { state = hitman.state } end
    if Holds.on(contract, hitmen, 'staff') then return false, CH.ERR.CONTRACT_FROZEN end

    local row = newRow(contractId, 'removal', staff, {
        body = reason, subject_cid = hitman.hitman_cid, subject_account = hitman.hitman_account,
        stint = tonumber(hitman.accepted_at), stake_returned = opts.returnStake == true,
        blocked = opts.block == true,
    })
    if not row then return false, CH.ERR.SERVER_ERROR end
    Storage.addContractStaff(row)
    remember(row)

    local ok, err, detail = Contracts.abandon({ cid = hitman.hitman_cid }, contractId,
        { staff = true, returnStake = opts.returnStake == true, holdStake = opts.holdStake == true })
    if not ok then
        forget(row)
        local gone, why = pcall(Storage.deleteContractStaff, row.id)
        if not gone then
            Log.always(('a refused staff removal on contract %s left its record (%s)')
                :format(contractId, Util.dbError(why)))
        end
        return false, err
    end
    detail = detail or {}

    Audit.staff('staff_remove_hitman', staff.cid, contractId, {
        hitman = hitman.hitman_cid, alias = hitman.alias, reason = reason,
        stake = detail.stake or 0,
        stake_to = (detail.returned or 0) > 0 and 'operative'
            or (detail.forfeited or 0) > 0 and 'client' or nil,
        blocked = opts.block == true or nil, record = row.id,
    })
    Notify.tellOrKeep(hitman.hitman_cid, StaffContract.REMOVED_TITLE, StaffContract.REMOVED_TEXT,
        { bypassBudget = true }, contractId)
    detail.alias = hitman.alias
    detail.blocked = opts.block == true
    detail.record, detail.hitmanId = row.id, hitman.id
    return true, nil, detail
end

--- Take back a removal's record (its bar and its choice of where the stake
--- goes): a staff reassignment that put the operative back on the contract
--- after its new hitman was refused (server/staff_reassign.lua).
---@param contractId string
---@param recordId string the removal's record (removeHitman's detail.record)
---@return boolean
function StaffContract.liftRemoval(contractId, recordId)
    local found
    for _, row in ipairs(removals[contractId] or {}) do
        if row.id == recordId then found = row end
    end
    if not found then return false end
    forget(found)
    local gone, why = pcall(Storage.deleteContractStaff, recordId)
    if not gone then
        Log.always(('a staff removal taken back on contract %s left its record (%s)')
            :format(contractId, Util.dbError(why)))
    end
    return true
end

--- The checks a player's text gets, for the text staff typed.
local function checkedText(source, text)
    local mode = Config.Reason.Mode
    if mode == 'preset' then
        for i, preset in ipairs(Config.Reason.Presets or {}) do
            if preset == text then
                return Contracts.reasonFor({ source = source }, { reasonPreset = i })
            end
        end
        return nil, CH.ERR.REASON_REFUSED, { rule = 'preset' }
    end
    return Contracts.reasonFor({ source = source }, { reason = text })
end

local function editUnlocked(staff, contractId, field, text, why)
    local contract = Storage.readContract(contractId)
    if not contract then return false, CH.ERR.NOT_FOUND end
    local new, err, refusal = checkedText(staff.source, text)
    if err then return false, err, refusal end
    if new == nil or new == '' then return false, CH.ERR.REASON_REFUSED, { rule = 'empty' } end
    local old = contract.reason
    if new == old then return false, 'unchanged' end
    if not Storage.setReason(contractId, new) then return false, CH.ERR.BAD_STATE end

    local row = newRow(contractId, 'edit', staff, { field = field, body = why })
    if row then
        local wrote, writeErr = pcall(Storage.addContractStaff, row)
        if wrote then
            remember(row)
        else
            Log.always(('contract %s: its text was replaced by staff, and the "edited by staff" mark '
                .. 'could not be kept (%s)'):format(contractId, Util.dbError(writeErr)))
        end
    end
    -- The original kept for staff, here and nowhere a player reads.
    Audit.staff('staff_text_edit', staff.cid, contractId,
        { field = field, old = old, new = new, reason = why, record = row and row.id or nil })

    -- Every party's card moves on to the new text; the board's at its next read.
    local fresh = Storage.readContract(contractId) or contract
    local cids = {}
    for _, h in ipairs(Storage.readHitmen(contractId) or {}) do
        if h.state == 'active' then cids[#cids + 1] = h.hitman_cid end
    end
    if not CH.TERMINAL[fresh.state] then Notify.pushParties(fresh, cids, 'edited') end
    return true, nil, { field = field, old = old, new = new }
end

--- Replace what a player wrote on a contract (its reason), through the
--- same checks a player's text gets, with a reason for the edit. One at a
--- time with the placer's own Edit, on the key it holds.
---@param staff table { cid, name, source }
---@param contractId string
---@param field string 'reason'
---@param text string
---@param why string
---@return boolean ok
---@return string|nil err
---@return table|nil detail { field, old, new }, or the refusal's { rule }
function StaffContract.editText(staff, contractId, field, text, why)
    if not StaffContract.FIELDS[field] then return false, 'bad_field' end
    if Config.Reason.Mode ~= 'freetext' and Config.Reason.Mode ~= 'preset' then
        return false, 'no_text'
    end
    return Contracts.serialized({ 'contract:' .. contractId }, editUnlocked, staff, contractId,
        field, text, why)
end

return StaffContract
