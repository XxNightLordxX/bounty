--- Staff freezes: a player's contracts put on hold from the admin panel.
---
--- Staff freeze a player (Players, in /hitmanadmin) for a staff situation or
--- an RP dispute. While they are frozen, every live contract (active or
--- accepted) they are party to, as the target, the placer or an active
--- operative, is on hold: nothing on it is accepted, completed, paid out,
--- handed over, bought out, informed on, tipped, amended, cancelled with a
--- refund or expired, and nothing is charged, refunded or moved. Each is
--- refused with CH.ERR.CONTRACT_FROZEN. A frozen player cannot place or take
--- a contract, and a contract on them cannot be placed.
---
--- The clocks reuse the pause every contract already has. The deadline
--- stops the way a party logging off stops it (Storage.startPause), and is
--- banked when the hold ends (Storage.endPause), as the expiry pass banks
--- one. The lifetime, which runs through every other pause, stops too: the
--- time a contract was on hold is added back to it when the hold ends. A
--- contract two frozen players are party to is on hold until the last of
--- them is released, and its lifetime is given back the whole span once.
---
--- There is no timer: a freeze ends only when staff unfreeze. It is kept by
--- the store (crimson_freezes on mysql, records.json on json), so it holds
--- across a restart.
---
--- Anonymity: nothing here says which party is frozen. The frozen player is
--- told their contracts are on hold; every other party of each contract is
--- told that contract is, in the same words whoever caused it; a card says
--- On hold and nothing else.

local Log = CrimsonBoot.requireShared('log')
local Util = CrimsonBoot.requireShared('util')

local Freeze = {}

local Storage, Audit, Notify, Kidnap

local frozen = {}   -- [cid] = { cid, name, reason, by_cid, frozen_at }
local count = 0

--- What players are told. Plain, and never which party.
Freeze.TEXT = {
    title       = 'On hold',
    held        = 'This contract is on hold by staff.',
    released    = 'This contract is no longer on hold.',
    you         = 'Staff have put your contracts on hold.',
    youReleased = 'Your contracts are no longer on hold.',
}

--- The states a hold applies to. A contract mid-completion finishes as it
--- began: it is already being paid, and stopping there strands the money.
local LIVE = { [CH.STATE.ACTIVE] = true, [CH.STATE.ACCEPTED] = true }

local REASON_MAX = 120

---@param deps table { storage, audit, notify, kidnap }
function Freeze.init(deps)
    Storage, Audit, Notify, Kidnap = deps.storage, deps.audit, deps.notify, deps.kidnap
    Freeze.reload()
end

--- Read every freeze from the store again. Done once at the start.
function Freeze.reload()
    frozen, count = {}, 0
    if not (Storage and Storage.readFreezes) then return end
    local ok, rows = pcall(Storage.readFreezes)
    if not ok then
        Log.always(('staff freezes could not be read from the store (%s); nobody reads as frozen '
            .. 'until the next start'):format(Util.dbError(rows)))
        return
    end
    for _, row in ipairs(rows or {}) do
        if row.cid then
            row.frozen_at = tonumber(row.frozen_at) or os.time()
            frozen[row.cid] = row
            count = count + 1
        end
    end
end

--- The freeze on a player, or nil.
---@param cid string|nil
---@return table|nil
function Freeze.of(cid)
    if cid == nil or count == 0 then return nil end
    return frozen[cid]
end

---@return integer
function Freeze.count() return count end

--- Every freeze, oldest first.
---@return table[]
function Freeze.list()
    local out = {}
    for _, row in pairs(frozen) do out[#out + 1] = row end
    table.sort(out, function(a, b)
        if a.frozen_at ~= b.frozen_at then return a.frozen_at < b.frozen_at end
        return tostring(a.cid) < tostring(b.cid)
    end)
    return out
end

--- The frozen parties of a live contract, or nil when it is not on hold:
--- { { cid, row, role = 'target' | 'client' | 'operative', anonymous } }.
--- Free while nobody is frozen; otherwise one read of its operatives unless
--- the caller has them.
---@param contract table|nil
---@param hitmen table[]|nil
---@return table[]|nil
function Freeze.partiesOf(contract, hitmen)
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

--- Whether a contract is on hold.
---@param contract table|nil
---@param hitmen table[]|nil
---@return boolean
function Freeze.holds(contract, hitmen)
    return Freeze.partiesOf(contract, hitmen) ~= nil
end

--- When a contract's hold began (os.time()), or nil when it is not on hold.
---@return integer|nil
function Freeze.heldSince(contract, hitmen)
    local parties = Freeze.partiesOf(contract, hitmen)
    if not parties then return nil end
    local since
    for i = 1, #parties do
        local at = parties[i].row.frozen_at
        if not since or at < since then since = at end
    end
    return since
end

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
--- whoever caused it. The target only once they are shown the contract.
local function tellParties(contract, text, skip)
    local hitmen = Storage.readHitmen(contract.id) or {}
    local told = { [skip or false] = true }
    local function tell(cid, named)
        if not cid or told[cid] or frozen[cid] then return end
        told[cid] = true
        Notify.toCitizen(cid, Freeze.TEXT.title, text,
            { bypassBudget = true, contractId = named and contract.id or nil })
        Notify.push(cid, 'hold', named and contract.id or nil)
    end
    tell(contract.creator_cid, true)
    if Notify.shownToTarget(contract) then tell(contract.target_cid, false) end
    for i = 1, #hitmen do
        if hitmen[i].state == 'active' then tell(hitmen[i].hitman_cid, true) end
    end
end

local function cleanReason(reason)
    if type(reason) ~= 'string' then return nil end
    reason = reason:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if reason == '' then return nil end
    return reason:sub(1, REASON_MAX)
end

--- Freeze a player. Every live contract they are party to goes on hold now.
---@param staffCid string|nil who froze them, for the audit row
---@param cid string the player
---@param reason string|nil
---@param name string|nil how staff know them, for the list
---@return boolean ok
---@return string|nil err 'already_frozen' | CH.ERR.SERVER_ERROR
function Freeze.freeze(staffCid, cid, reason, name)
    if type(cid) ~= 'string' or cid == '' then return false, CH.ERR.INVALID_INPUT end
    if frozen[cid] then return false, 'already_frozen' end
    reason = cleanReason(reason)
    local now = os.time()

    -- Which of their contracts were on hold already, through somebody else:
    -- their parties were told then, and are not told again.
    local contracts = liveOf(cid)
    local already = {}
    for i = 1, #contracts do already[contracts[i].id] = Freeze.holds(contracts[i]) end

    local row = { cid = cid, name = type(name) == 'string' and name:sub(1, 128) or nil,
                  reason = reason, by_cid = staffCid, frozen_at = now }
    local wrote, err = pcall(Storage.writeFreeze, row)
    if not wrote then
        Log.always(('a staff freeze could not be written (%s); nothing was put on hold')
            :format(Util.dbError(err)))
        return false, CH.ERR.SERVER_ERROR
    end
    frozen[cid] = row
    count = count + 1

    for i = 1, #contracts do
        local contract = contracts[i]
        -- The deadline stops as a party logging off stops it. Not one that
        -- has already gone with the clock running: that contract is late
        -- already, and pausing it would give the time back.
        local overdue = not contract.paused_since and contract.deadline_at ~= nil
            and now > contract.deadline_at
        if not contract.paused_since and not overdue then
            pcall(Storage.startPause, contract.id, now)
        end
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

    Notify.toCitizen(cid, Freeze.TEXT.title, Freeze.TEXT.you, { bypassBudget = true })
    Notify.push(cid, 'hold')
    for i = 1, #contracts do
        if not already[contracts[i].id] then tellParties(contracts[i], Freeze.TEXT.held) end
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
function Freeze.unfreeze(staffCid, cid, reason)
    local row = type(cid) == 'string' and frozen[cid] or nil
    if not row then return false, 'not_frozen' end
    reason = cleanReason(reason)
    local now = os.time()

    local removed, err = pcall(Storage.deleteFreeze, cid)
    if not removed then
        Log.always(('a staff freeze could not be removed (%s); the player stays on hold')
            :format(Util.dbError(err)))
        return false, CH.ERR.SERVER_ERROR
    end
    frozen[cid] = nil
    count = count - 1

    local released = {}
    for _, contract in ipairs(liveOf(cid)) do
        local others = Freeze.heldSince(contract)
        -- The part of this player's hold no other hold still covers: all of
        -- it when nobody else holds the contract, and otherwise only what
        -- came before the earliest one left, which is given back with that.
        local back = others and math.max(0, others - row.frozen_at) or math.max(0, now - row.frozen_at)
        if back > 0 and contract.expires_at then
            pcall(Storage.setContractFields, contract.id,
                { expires_at = (tonumber(contract.expires_at) or now) + back })
        end
        if not others then
            local since = contract.paused_since
            if since then pcall(Storage.endPause, contract.id, since, math.max(0, now - since)) end
            released[#released + 1] = contract
        end
    end

    Audit.staff('unfreeze_player', staffCid, nil, { subject = cid, reason = reason })
    Audit.flush()

    Notify.toCitizen(cid, Freeze.TEXT.title, Freeze.TEXT.youReleased, { bypassBudget = true })
    Notify.push(cid, 'hold')
    for i = 1, #released do tellParties(released[i], Freeze.TEXT.released, cid) end
    -- A party away now starts the presence pause again on the next pass.
    if type(MarkPresenceChanged) == 'function' then MarkPresenceChanged() end
    if type(MarkContractsChanged) == 'function' then MarkContractsChanged() end
    return true
end

return Freeze
